{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Runs the tests in child processes, as many at once as asked (the
  host's cores by default): each test is forked from the runner (which
  has read the harness already), runs, writes one line to a pipe ("P",
  or "F" and the failure) and exits. A child that crashes (a signal, or
  an exit without its line) fails its test, and one that outlives the
  time limit is killed and fails it too, so neither stops the run.

  Each child is held to a memory cap (RLIMIT_AS; the engine's heap
  limit is half of it, so most runaway tests fail with the engine's
  "Out of memory" error before the address space runs out) and to a CPU
  time limit, so a test cannot take the host down with it: the host is
  shared (no swap), and the number of children at once is also bounded
  by the memory available (see SafeJobCount).
}
unit Test262.Scheduler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Test262.Execution,
  Test262.Harness;

type
  TTestStatus = (tsPassed, tsFailed, tsSkipped);

  TTestResult = record
    Status: TTestStatus;
    Message: string;
  end;

  TResultEvent = procedure(Index: Integer; const Result: TTestResult) of object;

  { Reads the test with the given index (in the child). }
  TTestLoader = function(Index: Integer; out Test: TTestCase): Boolean of object;

  TTestScheduler = class
  private
    FJobs: Integer;
    FTimeLimit: Integer;
    FMemoryCap: Int64;
    FHarness: THarnessLibrary;
    FLoader: TTestLoader;
    procedure RunChild(Index: Integer; WriteEnd: LongInt);
  public
    { MemoryCap: the bytes of address space each test may have. }
    constructor Create(Harness: THarnessLibrary; Loader: TTestLoader; Jobs, TimeLimitSeconds: Integer;
      MemoryCap: Int64);
    { Runs the tests whose indexes are given; OnResult is called in the
      runner as each one finishes (in any order). }
    procedure Run(const Indexes: array of Integer; OnResult: TResultEvent);
  end;

{ The number of processors the host has online. }
function HostProcessorCount: Integer;
{ The bytes of memory the host has available now (MemAvailable). }
function HostAvailableMemory: Int64;
{ Jobs, at most as many as fit in half the available memory at
  MemoryCap each (at least one). }
function SafeJobCount(Jobs: Integer; MemoryCap: Int64): Integer;

implementation

uses
  Classes,
  BaseUnix,
  Unix;

const
  { CPU seconds a child may use beyond the time limit before the kernel
    stops it (the runner kills it at the limit; this is the backstop). }
  CpuTimeMargin = 5;

type
  TChildSlot = record
    Busy: Boolean;
    Pid: TPid;
    ReadEnd: LongInt;
    TestIndex: Integer;
    Deadline: QWord;
    Output: string;
  end;

{ /proc/cpuinfo's "processor" lines (read line by line: files in /proc
  have no size). }
function HostProcessorCount: Integer;
var
  CpuInfo: TextFile;
  Line: string;
begin
  Result := 0;
  AssignFile(CpuInfo, '/proc/cpuinfo');
  {$I-}
  Reset(CpuInfo);
  {$I+}
  if IOResult = 0 then
  begin
    while not Eof(CpuInfo) do
    begin
      ReadLn(CpuInfo, Line);
      if Pos('processor', Line) = 1 then
        Inc(Result);
    end;
    CloseFile(CpuInfo);
  end;
  if Result < 1 then
    Result := 1;
end;

function HostAvailableMemory: Int64;
var
  MemInfo: TextFile;
  Line: string;
  Parts: TStringArray;
begin
  Result := 0;
  AssignFile(MemInfo, '/proc/meminfo');
  {$I-}
  Reset(MemInfo);
  {$I+}
  if IOResult <> 0 then
    Exit;
  while not Eof(MemInfo) do
  begin
    ReadLn(MemInfo, Line);
    if Pos('MemAvailable:', Line) = 1 then
    begin
      Parts := Trim(Copy(Line, Length('MemAvailable:') + 1, MaxInt)).Split([' ']);
      if Length(Parts) > 0 then
        Result := StrToInt64Def(Parts[0], 0) * 1024;
      Break;
    end;
  end;
  CloseFile(MemInfo);
end;

function SafeJobCount(Jobs: Integer; MemoryCap: Int64): Integer;
var
  Available: Int64;
begin
  Result := Jobs;
  Available := HostAvailableMemory;
  if (Available > 0) and (MemoryCap > 0) and (Available div 2 div MemoryCap < Result) then
    Result := Available div 2 div MemoryCap;
  if Result < 1 then
    Result := 1;
end;

constructor TTestScheduler.Create(Harness: THarnessLibrary; Loader: TTestLoader; Jobs, TimeLimitSeconds: Integer;
  MemoryCap: Int64);
begin
  inherited Create;
  FHarness := Harness;
  FLoader := Loader;
  FJobs := Jobs;
  if FJobs < 1 then
    FJobs := 1;
  FTimeLimit := TimeLimitSeconds;
  FMemoryCap := MemoryCap;
end;

procedure WriteAll(Handle: LongInt; const Text: string);
var
  Done, Written: Integer;
begin
  Done := 0;
  while Done < Length(Text) do
  begin
    Written := FpWrite(Handle, Text[Done + 1], Length(Text) - Done);
    if Written <= 0 then
      Exit;
    Inc(Done, Written);
  end;
end;

procedure TTestScheduler.RunChild(Index: Integer; WriteEnd: LongInt);
var
  Test: TTestCase;
  Outcome: TTestOutcome;
  Limit: TRLimit;
  Line: string;
begin
  Limit.rlim_cur := FMemoryCap;
  Limit.rlim_max := FMemoryCap;
  FpSetRLimit(RLIMIT_AS, @Limit);
  Limit.rlim_cur := FTimeLimit + CpuTimeMargin;
  Limit.rlim_max := FTimeLimit + CpuTimeMargin;
  FpSetRLimit(RLIMIT_CPU, @Limit);
  try
    if not FLoader(Index, Test) then
      Line := 'Fcannot read the test'
    else
    begin
      Outcome := ExecuteTest(Test, FHarness, FMemoryCap div 2);
      if Outcome.Passed then
        Line := 'P'
      else
        Line := 'F' + StringReplace(Outcome.Message, #10, ' ', [rfReplaceAll]);
    end;
  except
    on Error: Exception do
      Line := 'Fhost exception ' + Error.ClassName + ': ' + Error.Message;
  end;
  WriteAll(WriteEnd, Line + #10);
  FpClose(WriteEnd);
  FpExit(0);
end;

function ResultOf(const Slot: TChildSlot; WaitStatus: cint): TTestResult;
var
  Line: string;
begin
  Line := Slot.Output;
  if (Line <> '') and (Line[Length(Line)] = #10) then
    SetLength(Line, Length(Line) - 1);
  if Line = 'P' then
  begin
    Result.Status := tsPassed;
    Result.Message := '';
  end
  else if (Line <> '') and (Line[1] = 'F') then
  begin
    Result.Status := tsFailed;
    Result.Message := Copy(Line, 2, Length(Line));
  end
  else
  begin
    Result.Status := tsFailed;
    if WIFSIGNALED(WaitStatus) then
      Result.Message := 'crashed (signal ' + IntToStr(WTERMSIG(WaitStatus)) + ')'
    else
      Result.Message := 'crashed (exit status ' + IntToStr(WEXITSTATUS(WaitStatus)) + ')';
  end;
end;

procedure TTestScheduler.Run(const Indexes: array of Integer; OnResult: TResultEvent);
var
  Slots: array of TChildSlot;
  PollSet: array of TPollFd;
  PollSlot: array of Integer;
  Next, Running, SlotIndex, Count, Ready, Waited: Integer;
  Pipe: TFilDes;
  Pid: TPid;
  Now, Wait: QWord;
  Buffer: array[0..4095] of Char;
  Received: TSsize;
  Status: cint;
  Result_: TTestResult;
begin
  Slots := nil;
  SetLength(Slots, FJobs);
  SetLength(PollSet, FJobs);
  SetLength(PollSlot, FJobs);
  Next := 0;
  Running := 0;
  while (Next <= High(Indexes)) or (Running > 0) do
  begin
    { Start children in the free slots. }
    for SlotIndex := 0 to High(Slots) do
      if not Slots[SlotIndex].Busy and (Next <= High(Indexes)) then
      begin
        if FpPipe(Pipe) <> 0 then
          raise Exception.Create('pipe failed');
        Flush(Output);
        Pid := FpFork;
        if Pid = 0 then
        begin
          FpClose(Pipe[0]);
          RunChild(Indexes[Next], Pipe[1]);
        end;
        FpClose(Pipe[1]);
        if Pid < 0 then
          raise Exception.Create('fork failed');
        Slots[SlotIndex].Busy := True;
        Slots[SlotIndex].Pid := Pid;
        Slots[SlotIndex].ReadEnd := Pipe[0];
        Slots[SlotIndex].TestIndex := Indexes[Next];
        Slots[SlotIndex].Deadline := GetTickCount64 + QWord(FTimeLimit) * 1000;
        Slots[SlotIndex].Output := '';
        Inc(Next);
        Inc(Running);
      end;
    { Wait for output or the nearest deadline. }
    Count := 0;
    Now := GetTickCount64;
    Wait := 1000;
    for SlotIndex := 0 to High(Slots) do
      if Slots[SlotIndex].Busy then
      begin
        PollSet[Count].fd := Slots[SlotIndex].ReadEnd;
        PollSet[Count].events := POLLIN;
        PollSet[Count].revents := 0;
        PollSlot[Count] := SlotIndex;
        Inc(Count);
        if Slots[SlotIndex].Deadline <= Now then
          Wait := 0
        else if Slots[SlotIndex].Deadline - Now < Wait then
          Wait := Slots[SlotIndex].Deadline - Now;
      end;
    if Count = 0 then
      Continue;
    Ready := FpPoll(@PollSet[0], Count, Wait);
    for Waited := 0 to Count - 1 do
    begin
      SlotIndex := PollSlot[Waited];
      if (Ready > 0) and (PollSet[Waited].revents <> 0) then
      begin
        Received := FpRead(Slots[SlotIndex].ReadEnd, Buffer, SizeOf(Buffer));
        if Received > 0 then
        begin
          Slots[SlotIndex].Output := Slots[SlotIndex].Output + Copy(Buffer, 0, Received);
          Continue;
        end;
        { End of file: the child is gone or going. }
        FpClose(Slots[SlotIndex].ReadEnd);
        FpWaitPid(Slots[SlotIndex].Pid, @Status, 0);
        Result_ := ResultOf(Slots[SlotIndex], Status);
      end
      else if GetTickCount64 >= Slots[SlotIndex].Deadline then
      begin
        FpKill(Slots[SlotIndex].Pid, SIGKILL);
        FpClose(Slots[SlotIndex].ReadEnd);
        FpWaitPid(Slots[SlotIndex].Pid, @Status, 0);
        Result_.Status := tsFailed;
        Result_.Message := 'timed out after ' + IntToStr(FTimeLimit) + ' s';
      end
      else
        Continue;
      Slots[SlotIndex].Busy := False;
      Dec(Running);
      OnResult(Slots[SlotIndex].TestIndex, Result_);
    end;
  end;
end;

end.
