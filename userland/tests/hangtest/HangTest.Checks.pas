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
  hangtest --check: every way of getting stuck, ended every way.

  For each mode a copy of hangtest is started in a group of its own
  and, once stuck, is
    * ended outright (what kill -9 and the task manager's End now do):
      it must be gone within EndMilliseconds with status 137;
    * asked to end (kill, the task manager's End): a program that does
      not take requests must be gone the same way with 143, one with a
      window that serves it (window-idle) with 0;
  and some modes once more with -i (requests taken and ignored), as the
  task manager does it: asked, still there a second later, ended
  outright, gone with 137. Whatever the copy started (a child, a lock's
  holder) is ended with its group afterwards; ending a group as a whole
  (kill -9 of a group) is checked on its own. Prints a line per check
  ("ok MODE HOW STATUS" or "FAIL MODE HOW ...") and "N checks, F
  failed"; exits with 1 if any failed.
}
unit HangTest.Checks;

{$mode objfpc}{$H+}

interface

{ Runs the checks (with the window modes if WithWindows: they need the
  display server) and returns the program's exit status. }
function RunChecks(WithWindows: Boolean): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Notifications,
  Sys.Objects,
  Sys.Processes,
  Sys.ProcessList,
  Sys.Streams,
  Sys.Time;

type
  TEndWay = (EndOutright, EndAsked, EndEscalated);

const
  KernelWaitModes: array[0..15] of string = ('spin', 'spin-threads', 'sleep', 'event', 'wait-handles', 'lock',
    'deadlock', 'thread-join', 'child-wait', 'pipe-read', 'pipe-write', 'fifo-open', 'file-lock', 'channel',
    'suspended', 'allocate');
  SocketModes: array[0..4] of string = ('tcp-receive', 'tcp-receive-thread', 'tcp-accept', 'tcp-connect',
    'udp-receive');
  WindowModes: array[0..3] of string = ('window-idle', 'window-hung', 'window-spin', 'window-lock');
  { Checked once more ignoring requests, as the task manager ends them. }
  EscalatedModes: array[0..5] of string = ('spin-threads', 'sleep', 'deadlock', 'pipe-read', 'tcp-receive',
    'suspended');
  WayNames: array[TEndWay] of string = ('ended', 'asked', 'escalated');

  ReadyMilliseconds = 10000;
  { How long ending may take: the kernel acts at the next safe point. }
  EndMilliseconds = 5000;
  { How long a program that ignores requests is given before it is
    ended outright (the task manager waits longer). }
  RefusalMilliseconds = 1000;
  StatusOutright = 137;
  StatusAsked = 143;

var
  CheckCount: LongInt;
  FailureCount: LongInt;

procedure Report(const Line: string; Passed: Boolean);
begin
  Inc(CheckCount);
  if Passed then
    PrintString('ok ' + Line + #10)
  else
  begin
    Inc(FailureCount);
    PrintString('FAIL ' + Line + #10);
  end;
  FlushStream(StandardOutput);
end;

{ Reads the copy's output until it says it is ready. }
function WaitUntilReady(Output: Int64): Boolean;
var
  Seen: string;
  Buffer: array[0..255] of Char;
  Count: Int64;
  Deadline: QWord;
  Now: QWord;
begin
  Seen := '';
  Deadline := UptimeMilliseconds + ReadyMilliseconds;
  repeat
    Now := UptimeMilliseconds;
    if Now >= Deadline then
      Exit(False);
    if WaitForHandle(Output, Int64(Deadline - Now)) <> ErrorNone then
      Exit(False);
    Count := ReadFile(Output, @Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Exit(False);
    SetString(Seen, PChar(@Buffer[0]), Count);
  until Pos('hangtest: ready', Seen) > 0;
  Result := True;
end;

{ Starts "hangtest [-i] Mode" in a new group, its output on a pipe. }
function StartStuckCopy(const Mode: string; IgnoreRequests: Boolean; out Output: Int64): Int64;
var
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  WriteEnd: Int64;
  Count: LongInt;
begin
  Output := -1;
  if CreatePipe(Output, WriteEnd) <> 0 then
    Exit(-ErrorOutOfMemory);
  Count := 0;
  Arguments[Count] := 'hangtest';
  Inc(Count);
  if IgnoreRequests then
  begin
    Arguments[Count] := '-i';
    Inc(Count);
  end;
  Arguments[Count] := PChar(Mode);
  Arguments[Count + 1] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteEnd;
  Options.GroupId := GroupNew;
  Result := StartProgram('/bin/hangtest', @Arguments[0], Options);
  CloseHandle(WriteEnd);
end;

function Describe(const Mode: string; Way: TEndWay): string;
begin
  Result := Mode + ' ' + WayNames[Way];
end;

{ Ends the copy Way's way; the status it ended with, or -1 if it did
  not end (or, escalated, if it ended before it was ended outright). }
function EndCopy(Process: Int64; Way: TEndWay): LongInt;
var
  ProcessId: QWord;
  Status: LongInt;
begin
  ProcessId := QWord(ProcessIdOf(Process));
  case Way of
    EndOutright:
      TerminateProgram(ProcessId, StatusOutright);
    EndAsked:
      AskProcessToEnd(ProcessId, EndReasonAsked);
    EndEscalated:
      begin
        AskProcessToEnd(ProcessId, EndReasonAsked);
        if WaitForProgramWithTimeout(Process, RefusalMilliseconds, Status) <> ErrorTimedOut then
          Exit(-1);
        TerminateProgram(ProcessId, StatusOutright);
      end;
  end;
  if WaitForProgramWithTimeout(Process, EndMilliseconds, Status) <> ErrorNone then
    Exit(-1);
  Result := Status;
end;

procedure CheckMode(const Mode: string; Way: TEndWay; Expected: LongInt);
var
  Process: Int64;
  Output: Int64;
  ProcessId: QWord;
  Status: LongInt;
begin
  Process := StartStuckCopy(Mode, Way = EndEscalated, Output);
  if Process < 0 then
  begin
    Report(Describe(Mode, Way) + ' (not started)', False);
    Exit;
  end;
  ProcessId := QWord(ProcessIdOf(Process));
  if not WaitUntilReady(Output) then
  begin
    TerminateProcessGroup(ProcessId, StatusOutright);
    Report(Describe(Mode, Way) + ' (never ready)', False);
    CloseHandle(Output);
    Exit;
  end;
  { Into the wait it announced. }
  SleepMilliseconds(300);
  Status := EndCopy(Process, Way);
  { What it started (a child, a lock's holder) goes with its group; one
    that did not end is ended too, so the next check starts clean. }
  TerminateProcessGroup(ProcessId, StatusOutright);
  CloseHandle(Output);
  if Status < 0 then
    Report(Describe(Mode, Way) + ' did not end', False)
  else
    Report(Describe(Mode, Way) + ' ' + IntToStr(Status), Status = Expected);
end;

procedure CheckModes(const Modes: array of string; AskedStatus: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to High(Modes) do
  begin
    CheckMode(Modes[Index], EndOutright, StatusOutright);
    CheckMode(Modes[Index], EndAsked, AskedStatus);
  end;
end;

{ A copy waiting for its own child, ended as a group (kill -9 of a
  group): both processes go, the copy with 137. }
procedure CheckGroupEnded;
var
  Process: Int64;
  Output: Int64;
  ProcessId: QWord;
  Ended: Int64;
  Status: LongInt;
  Details: TProcessDetails;
  Snapshot: TProcessSnapshot;
  Index: LongInt;
  Left: LongInt;
begin
  Process := StartStuckCopy('child-wait', False, Output);
  if Process < 0 then
  begin
    Report('group (not started)', False);
    Exit;
  end;
  ProcessId := QWord(ProcessIdOf(Process));
  WaitUntilReady(Output);
  SleepMilliseconds(300);
  Ended := TerminateProcessGroup(ProcessId, StatusOutright);
  if WaitForProgramWithTimeout(Process, EndMilliseconds, Status) <> ErrorNone then
    Status := -1;
  CloseHandle(Output);
  { Its child goes at its next safe point too. }
  SleepMilliseconds(500);
  Left := 0;
  InitializeProcessSnapshot(Snapshot);
  if TakeProcessSnapshot(Snapshot) = ErrorNone then
    for Index := 0 to Snapshot.Count - 1 do
    begin
      Details := Snapshot.Entries[Index];
      if Details.GroupId = ProcessId then
        Inc(Left);
    end;
  FreeProcessSnapshot(Snapshot);
  Report(Format('group ended %d status %d left %d', [Ended, Status, Left]),
    (Ended = 2) and (Status = StatusOutright) and (Left = 0));
end;

function RunChecks(WithWindows: Boolean): LongInt;
var
  Index: LongInt;
begin
  CheckCount := 0;
  FailureCount := 0;
  CheckModes(KernelWaitModes, StatusAsked);
  CheckModes(SocketModes, StatusAsked);
  for Index := 0 to High(EscalatedModes) do
    CheckMode(EscalatedModes[Index], EndEscalated, StatusOutright);
  CheckGroupEnded;
  if WithWindows then
  begin
    CheckMode(WindowModes[0], EndOutright, StatusOutright);
    CheckMode(WindowModes[0], EndAsked, 0);
    for Index := 1 to High(WindowModes) do
    begin
      CheckMode(WindowModes[Index], EndOutright, StatusOutright);
      CheckMode(WindowModes[Index], EndEscalated, StatusOutright);
    end;
  end;
  PrintString(Format('%d checks, %d failed'#10, [CheckCount, FailureCount]));
  FlushStream(StandardOutput);
  if FailureCount = 0 then
    Result := 0
  else
    Result := 1;
end;

end.
