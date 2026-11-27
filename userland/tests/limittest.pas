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
  limittest

  The limits of a process and that what it gives back really goes
  (CallGetProcessResources):

    * 2000 threads started and joined, 50 at a time, then 200 more ended
      from outside while they wait (their threadvar blocks go too), with
      the region count and committed memory back where they were;
    * 5000 regions allocated at once (more than the region table used to
      hold) and freed, and large heap blocks allocated and freed in a
      loop, back to the baseline again;
    * 3000 handles open at once (pipes, events and sockets), numbered
      densely from the lowest free one, a closed number used again
      first, all closed and the count back to where it was;
    * lowered limits for handles and regions turning further handles
      and regions away, and raised again;
    * a child process given 600 handles under the same numbers
      (ProcessPassHandles), which finds and signals every one; a thread
      handle and a closed handle refused.

  This program starts itself with --child N for the last part. Each
  check prints a line; the exit status is 1 if any failed.
}
program LimitTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Processes;

const
  ThreadTotal = 2000;
  ThreadBatch = 50;
  EndedThreadTotal = 200;
  RegionTotal = 5000;
  HeapRounds = 400;
  PipeTotal = 1000;
  EventTotal = 500;
  SocketTotal = 500;
  PassedTotal = 600;
  { What the heap may keep for later (free chunks it holds on to), in
    regions and pages, without that being a leak: a leak here would be
    thousands. }
  RegionSlack = 16;
  PageSlack = 1024;
  ThreadTimeout = 10000;
  ChildTimeout = 30000;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('limittest: pass: ', Name)
  else
  begin
    WriteLn('limittest: FAIL: ', Name);
    Inc(Failures);
  end;
end;

function Resources: TAbiProcessResources;
begin
  FillChar(Result, SizeOf(Result), 0);
  if KernelGetProcessResources(0, Result) < 0 then
    WriteLn('limittest: CallGetProcessResources failed');
end;

function Describe(const Usage: TAbiProcessResources): string;
begin
  Result := Format('%d regions, %d pages, %d handles', [Usage.RegionCount, Usage.CommittedPages,
    Usage.HandleCount]);
end;

procedure CheckBackToBaseline(const What: string; const Baseline: TAbiProcessResources);
var
  Now: TAbiProcessResources;
begin
  Now := Resources;
  WriteLn('limittest: ', What, ': before ', Describe(Baseline), '; after ', Describe(Now));
  Check(What + ': regions back to the baseline', Now.RegionCount <= Baseline.RegionCount + RegionSlack);
  Check(What + ': committed memory back to the baseline',
    Now.CommittedPages <= Baseline.CommittedPages + PageSlack);
  Check(What + ': handles back to the baseline', Now.HandleCount = Baseline.HandleCount);
end;

{ --- Threads ------------------------------------------------------------ }

threadvar
  ThreadMark: Integer;

function CountingThread(Parameter: Pointer): PtrInt;
var
  Block: Pointer;
begin
  { A threadvar and a little heap memory, as real threads have. }
  ThreadMark := PtrInt(Parameter);
  GetMem(Block, 200);
  FreeMem(Block);
  Result := ThreadMark;
end;

function WaitingThread(Parameter: Pointer): PtrInt;
var
  Event: Int64;
begin
  ThreadMark := 1;
  Event := Int64(PtrInt(Parameter));
  KernelWaitForHandles(@Event, 1, InfiniteWait, 0);
  Result := 0;
end;

{ Starts Count threads running Routine and joins them; True if all
  started, ended in time and gave their numbers back. }
function RunThreadBatch(First, Count: Integer): Boolean;
var
  Handles: array[0..ThreadBatch - 1] of TThreadID;
  Index: Integer;
begin
  Result := True;
  for Index := 0 to Count - 1 do
  begin
    Handles[Index] := BeginThread(@CountingThread, Pointer(PtrInt(First + Index)));
    if Handles[Index] = 0 then
      Result := False;
  end;
  for Index := 0 to Count - 1 do
    if Handles[Index] <> 0 then
    begin
      if WaitForThreadTerminate(Handles[Index], ThreadTimeout) <> DWord(First + Index) then
        Result := False;
      CloseThread(Handles[Index]);
    end;
end;

procedure TestThreads;
var
  Baseline: TAbiProcessResources;
  Started: Integer;
  AllRan: Boolean;
begin
  { The first batch sets up what stays: the main thread's threadvars,
    the heap's first chunks. }
  RunThreadBatch(0, ThreadBatch);
  Baseline := Resources;
  AllRan := True;
  Started := 0;
  while Started < ThreadTotal do
  begin
    if not RunThreadBatch(Started, ThreadBatch) then
      AllRan := False;
    Inc(Started, ThreadBatch);
  end;
  Check(Format('%d threads started and joined', [ThreadTotal]), AllRan);
  CheckBackToBaseline('threads', Baseline);
end;

procedure TestEndedThreads;
var
  Baseline: TAbiProcessResources;
  Event: Int64;
  Handles: array[0..ThreadBatch - 1] of TThreadID;
  Round: Integer;
  Index: Integer;
  AllEnded: Boolean;
begin
  Event := KernelCreateEvent(EventManualReset);
  Baseline := Resources;
  AllEnded := True;
  for Round := 1 to EndedThreadTotal div ThreadBatch do
  begin
    for Index := 0 to ThreadBatch - 1 do
      Handles[Index] := BeginThread(@WaitingThread, Pointer(PtrInt(Event)));
    { Let them reach their wait. }
    KernelSleep(20);
    for Index := 0 to ThreadBatch - 1 do
      if Handles[Index] = 0 then
        AllEnded := False
      else
      begin
        KillThread(Handles[Index]);
        if WaitForThreadTerminate(Handles[Index], ThreadTimeout) = DWord(-1) then
          AllEnded := False;
        CloseThread(Handles[Index]);
      end;
  end;
  Check(Format('%d waiting threads ended from outside', [EndedThreadTotal]), AllEnded);
  CheckBackToBaseline('ended threads', Baseline);
  KernelClose(Event);
end;

{ --- Regions and the heap ---------------------------------------------- }

procedure TestRegions;
var
  Baseline: TAbiProcessResources;
  During: TAbiProcessResources;
  Blocks: array of Int64;
  Index: Integer;
  AllAllocated: Boolean;
  AllFreed: Boolean;
begin
  SetLength(Blocks, RegionTotal);
  Baseline := Resources;
  AllAllocated := True;
  for Index := 0 to RegionTotal - 1 do
  begin
    Blocks[Index] := KernelAllocateMemory(4096 * (1 + Index mod 3));
    if Blocks[Index] <= 0 then
      AllAllocated := False
    else
      { Touched, so it costs a page. }
      PByte(Blocks[Index])^ := 1;
  end;
  During := Resources;
  Check(Format('%d regions allocated at once', [RegionTotal]), AllAllocated);
  Check('the region count grew by as many',
    During.RegionCount >= Baseline.RegionCount + RegionTotal);
  Check('the region count is within the limit', During.RegionCount <= During.RegionLimit);
  AllFreed := True;
  { Every other one first, so the gaps come and go. }
  for Index := 0 to RegionTotal - 1 do
    if (Index mod 2 = 0) and (Blocks[Index] > 0) and (KernelFreeMemory(Pointer(Blocks[Index])) < 0) then
      AllFreed := False;
  for Index := 0 to RegionTotal - 1 do
    if (Index mod 2 = 1) and (Blocks[Index] > 0) and (KernelFreeMemory(Pointer(Blocks[Index])) < 0) then
      AllFreed := False;
  Check('all of them freed', AllFreed);
  Blocks := nil;
  CheckBackToBaseline('regions', Baseline);
end;

procedure TestHeapBlocks;
const
  LiveBlocks = 24;
  Sizes: array[0..3] of PtrUInt = (4 * 1024 * 1024, 2 * 1024 * 1024, 1024 * 1024, 300 * 1024);
var
  Baseline: TAbiProcessResources;
  Live: array[0..LiveBlocks - 1] of PByte;
  Round: Integer;
  Slot: Integer;
begin
  FillChar(Live, SizeOf(Live), 0);
  Baseline := Resources;
  for Round := 0 to HeapRounds - 1 do
  begin
    Slot := (Round * 7) mod LiveBlocks;
    if Live[Slot] <> nil then
      FreeMem(Live[Slot]);
    GetMem(Live[Slot], Sizes[Round mod 4]);
    Live[Slot][0] := 1;
    Live[Slot][Sizes[Round mod 4] - 1] := 1;
  end;
  for Slot := 0 to LiveBlocks - 1 do
    if Live[Slot] <> nil then
      FreeMem(Live[Slot]);
  Check(Format('%d large heap blocks allocated and freed', [HeapRounds]), True);
  CheckBackToBaseline('large heap blocks', Baseline);
end;

{ --- Handles ------------------------------------------------------------ }

procedure TestHandles;
var
  Baseline: TAbiProcessResources;
  During: TAbiProcessResources;
  Handles: array of Int64;
  Count: Integer;
  Index: Integer;
  ReadEnd: Int64;
  WriteEnd: Int64;
  Highest: Int64;
  AllOpened: Boolean;
  Reused: Int64;
begin
  Baseline := Resources;
  SetLength(Handles, 2 * PipeTotal + EventTotal + SocketTotal);
  Count := 0;
  AllOpened := True;
  for Index := 1 to PipeTotal do
    if KernelCreatePipe(ReadEnd, WriteEnd) < 0 then
      AllOpened := False
    else
    begin
      Handles[Count] := ReadEnd;
      Handles[Count + 1] := WriteEnd;
      Inc(Count, 2);
    end;
  for Index := 1 to EventTotal do
  begin
    Handles[Count] := KernelCreateEvent(0);
    if Handles[Count] < 0 then
      AllOpened := False
    else
      Inc(Count);
  end;
  for Index := 1 to SocketTotal do
  begin
    Handles[Count] := KernelCreateSocket(AddressFamilyIPv4, SocketKindDatagram, 0);
    if Handles[Count] < 0 then
      AllOpened := False
    else
      Inc(Count);
  end;
  During := Resources;
  Check(Format('%d handles open at once (pipes, events, sockets)', [Length(Handles)]),
    AllOpened and (Count = Length(Handles)));
  Check('the handle count grew by as many', During.HandleCount = Baseline.HandleCount + LongWord(Count));
  Highest := 0;
  for Index := 0 to Count - 1 do
    if Handles[Index] > Highest then
      Highest := Handles[Index];
  { Numbers stay small: the lowest free ones are handed out. }
  Check('the handles are numbered densely', Highest < Int64(During.HandleCount) + 8);

  { A number closed is the next one handed out. }
  KernelClose(Handles[Count div 2]);
  Reused := KernelCreateEvent(0);
  Check('the lowest free number is used again', Reused = Handles[Count div 2]);
  Handles[Count div 2] := Reused;

  for Index := 0 to Count - 1 do
    KernelClose(Handles[Index]);
  Handles := nil;
  CheckBackToBaseline('handles', Baseline);
end;

procedure TestLimits;
var
  Before: TAbiProcessResources;
  Previous: Int64;
  Events: array[0..9] of Int64;
  Blocks: array[0..3] of Int64;
  Index: Integer;
begin
  Before := Resources;
  Check('the default handle limit', Before.HandleLimit = DefaultProcessHandleLimit);
  Check('the default region limit', Before.RegionLimit = DefaultProcessRegionLimit);

  Previous := KernelSetProcessLimit(ProcessLimitHandles, Before.HandleCount + 5);
  Check('the handle limit lowered', Previous = DefaultProcessHandleLimit);
  for Index := 0 to 9 do
    Events[Index] := KernelCreateEvent(0);
  Check('handles below the limit opened', (Events[0] >= 0) and (Events[4] >= 0));
  Check('the handle past the limit turned away', Events[5] = -ErrorTooManyHandles);
  for Index := 0 to 9 do
    if Events[Index] >= 0 then
      KernelClose(Events[Index]);
  KernelSetProcessLimit(ProcessLimitHandles, DefaultProcessHandleLimit);
  Check('the handle limit raised again', Resources.HandleLimit = DefaultProcessHandleLimit);

  KernelSetProcessLimit(ProcessLimitRegions, Resources.RegionCount + 3);
  for Index := 0 to 3 do
    Blocks[Index] := KernelAllocateMemory(4096);
  Check('regions below the limit allocated', (Blocks[0] > 0) and (Blocks[2] > 0));
  Check('the region past the limit turned away', Blocks[3] = -ErrorOutOfMemory);
  for Index := 0 to 3 do
    if Blocks[Index] > 0 then
      KernelFreeMemory(Pointer(Blocks[Index]));
  KernelSetProcessLimit(ProcessLimitRegions, DefaultProcessRegionLimit);
  Check('the region limit raised again', Resources.RegionLimit = DefaultProcessRegionLimit);

  Check('a limit above its ceiling refused',
    KernelSetProcessLimit(ProcessLimitHandles, ProcessHandleLimitCeiling + 1) = -ErrorInvalidArgument);
  Check('an unknown limit refused', KernelSetProcessLimit(99, 10) = -ErrorInvalidArgument);
end;

{ --- Handles for a child -------------------------------------------------- }

function StartChild(Handles: PInt64; Count: Integer): Int64;
var
  Options: TProcessOptions;
  Arguments: array[0..3] of PChar;
  CountText: string;
begin
  CountText := IntToStr(Count);
  Arguments[0] := 'limittest';
  Arguments[1] := '--child';
  Arguments[2] := PChar(CountText);
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.PassedHandles := Handles;
  Options.PassedHandleCount := Count;
  Result := StartProgram('/bin/limittest', @Arguments[0], Options);
end;

function AllSignaled(const Events: array of Int64): Boolean;
var
  First: Integer;
  Count: Integer;
begin
  Result := True;
  First := 0;
  while First < Length(Events) do
  begin
    Count := Length(Events) - First;
    if Count > MaximumWaitHandles then
      Count := MaximumWaitHandles;
    if KernelWaitForHandles(@Events[First], Count, 0, WaitForAll) < 0 then
      Result := False;
    Inc(First, Count);
  end;
end;

procedure TestPassedHandles;
var
  Baseline: TAbiProcessResources;
  Events: array of Int64;
  Index: Integer;
  Child: Int64;
  Status: LongInt;
  Thread: TThreadID;
  Closed: Int64;
begin
  Baseline := Resources;
  SetLength(Events, PassedTotal);
  for Index := 0 to PassedTotal - 1 do
    Events[Index] := KernelCreateEvent(EventManualReset);
  Child := StartChild(@Events[0], PassedTotal);
  Check(Format('a child started with %d handles passed', [PassedTotal]), Child >= 0);
  if Child >= 0 then
  begin
    Check('the child found every handle under its number',
      (WaitForProgramWithTimeout(Child, ChildTimeout, Status) = ErrorNone) and (Status = 0));
    KernelClose(Child);
  end;
  Check('the child signaled every event it was given', AllSignaled(Events));

  { A thread handle stands for a thread of this process alone. }
  Thread := BeginThread(@CountingThread, nil);
  Check('a thread handle is not passed', StartChild(@Thread, 1) = -ErrorInvalidArgument);
  WaitForThreadTerminate(Thread, ThreadTimeout);
  CloseThread(Thread);
  Closed := KernelCreateEvent(0);
  KernelClose(Closed);
  Check('a closed handle is not passed', StartChild(@Closed, 1) = -ErrorBadHandle);

  for Index := 0 to PassedTotal - 1 do
    KernelClose(Events[Index]);
  CheckBackToBaseline('passed handles', Baseline);
end;

{ The child: finds Expected event handles among its numbers and signals
  each. Exit status 0 if it found exactly that many. }
function RunChild(Expected: Integer): LongInt;
var
  Usage: TAbiProcessResources;
  Handle: Int64;
  Found: Integer;
begin
  Usage := Resources;
  Found := 0;
  Handle := 0;
  while Handle < Usage.HandleLimit do
  begin
    if KernelGetHandleKind(Handle) = HandleKindEvent then
    begin
      if KernelSetEvent(Handle) >= 0 then
        Inc(Found);
    end;
    Inc(Handle);
  end;
  if Found = Expected then
    Result := 0
  else
    Result := 1;
end;

var
  Start: TAbiProcessResources;
begin
  if (ParamCount = 2) and (ParamStr(1) = '--child') then
    Halt(RunChild(StrToIntDef(ParamStr(2), -1)));
  Start := Resources;
  WriteLn('limittest: at the start: ', Describe(Start), ', limits ', Start.RegionLimit, ' regions, ',
    Start.HandleLimit, ' handles');
  TestThreads;
  TestEndedThreads;
  TestRegions;
  TestHeapBlocks;
  TestHandles;
  TestLimits;
  TestPassedHandles;
  WriteLn(Format('limittest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
end.
