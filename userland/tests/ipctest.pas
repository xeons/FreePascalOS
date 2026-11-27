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
  ipctest - checks the objects programs work together with

  ipctest

  Events (automatic and manual reset), waiting on several handles and
  timeouts, semaphores (counts, the limit, bad arguments, timeouts, one
  in a wait for all with an event, waiters in other threads woken by a
  release of several), waiting for all of several handles (automatic reset ones
  consumed only once all are ready), timers (once and periodic, and how
  close to their time they keep at 5 and 15 ms), short sleeps, a pipe's
  read and write ends and the console as waitable handles, channels (data, a handle carried in a message, a message too
  large for the buffer, a full queue, the other end closing), ports, and
  a section shared with a second process: this program starts itself
  with --child, which connects to its port, receives the section and an
  event in a message, checks and changes the section, and signals the
  event.

  Each check prints a line; the exit status is 1 if any failed.
}
program IpcTest;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  SysUtils,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes,
  Sys.Semaphores,
  Sys.Streams,
  Sys.Threads,
  Sys.Time;

const
  PortName: PChar = 'ipctest';
  SectionBytes = 64 * 1024;
  PatternCount = SectionBytes div SizeOf(LongWord);
  ChildMark = $C0FFEE;
  ChildTimeout = 10000;
  { Io.Pipes.PipeBufferSize. }
  PipeCapacity = 4096;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Name: PChar; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteString(StandardOutput, Format('ipctest: pass: %s'#10, [Name]))
  else
  begin
    WriteString(StandardOutput, Format('ipctest: FAIL: %s'#10, [Name]));
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

function CreateSemaphoreAndClose(InitialCount, Limit: LongInt): Boolean;
var
  Semaphore: Int64;
begin
  Semaphore := CreateSemaphore(InitialCount, Limit);
  Result := Semaphore >= 0;
  if Result then
    CloseHandle(Semaphore);
end;

function TimedOut(WaitResult: Int64): Boolean;
begin
  Result := WaitResult = -ErrorTimedOut;
end;

procedure TestEvents;
var
  Automatic: Int64;
  Manual: Int64;
  Third: Int64;
  NotWaitable: Int64;
  AlwaysReady: Int64;
begin
  Automatic := CreateEvent(False, False);
  Manual := CreateEvent(True, False);
  Third := CreateEvent(False, False);
  Check('events created', (Automatic >= 0) and (Manual >= 0) and (Third >= 0));
  Check('unsignaled: a wait times out', TimedOut(WaitForHandles([Automatic], 0)));
  SetEvent(Automatic);
  Check('automatic reset: one wait', WaitForHandles([Automatic], 0) = 0);
  Check('automatic reset: consumed', TimedOut(WaitForHandles([Automatic], 0)));
  SetEvent(Manual);
  Check('manual reset: stays signaled', (WaitForHandles([Manual], 0) = 0) and (WaitForHandles([Manual], 0) = 0));
  ResetEvent(Manual);
  Check('manual reset: reset', TimedOut(WaitForHandles([Manual], 20)));
  SetEvent(Third);
  Check('several handles: the signaled one', WaitForHandles([Automatic, Manual, Third], 1000) = 2);
  AlwaysReady := KernelOpen('/bin/ipctest', OpenRead);
  Check('a file is always ready', WaitForHandles([AlwaysReady], 0) = 0);
  KernelClose(AlwaysReady);
  NotWaitable := CreateSection(4096);
  Check('a handle that cannot be waited on', WaitForHandles([NotWaitable], 0) = -ErrorUnsupported);
  CloseHandle(NotWaitable);
  Check('a bad handle', WaitForHandles([60], 0) = -ErrorBadHandle);
  CloseHandle(Automatic);
  CloseHandle(Manual);
  CloseHandle(Third);
end;

procedure TestTimers;
var
  Timer: Int64;
  Start: Int64;
  Count: Integer;
begin
  Timer := CreateTimer(False);
  Check('timer created', Timer >= 0);
  Check('a timer not armed is not signaled', TimedOut(WaitForHandles([Timer], 30)));
  SetTimer(Timer, 100, 0);
  Check('one shot: not before its time', TimedOut(WaitForHandles([Timer], 20)));
  Check('one shot: at its time', WaitForHandles([Timer], 2000) = 0);
  Check('one shot: only once', TimedOut(WaitForHandles([Timer], 200)));
  Start := Int64(UptimeMilliseconds);
  SetTimer(Timer, 30, 30);
  Count := 0;
  while (Count < 4) and (WaitForHandles([Timer], 2000) = 0) do
    Inc(Count);
  Check('periodic: four times, about 30 ms apart',
    (Count = 4) and (Int64(UptimeMilliseconds) - Start >= 100) and (Int64(UptimeMilliseconds) - Start < 2000));
  SetTimer(Timer, 0, 0);
  Check('stopped', TimedOut(WaitForHandles([Timer], 100)));
  CloseHandle(Timer);
  { Closed while armed: the kernel stops it. }
  Timer := CreateTimer(False);
  SetTimer(Timer, 10, 10);
  CloseHandle(Timer);
end;

{ Waiting for all: satisfied only when every handle is signaled at once,
  and only then are the automatic reset ones consumed. }
procedure TestWaitForAll;
var
  Automatic: Int64;
  Manual: Int64;
  Early: Int64;
  Late: Int64;
  Start: Int64;
  Handles: array[0..1] of Int64;
begin
  Automatic := CreateEvent(False, False);
  Manual := CreateEvent(True, False);
  Check('all: none signaled', WaitForAllHandles([Automatic, Manual], 0) = ErrorTimedOut);
  SetEvent(Automatic);
  Check('all: one of two signaled is not enough', WaitForAllHandles([Automatic, Manual], 0) = ErrorTimedOut);
  Check('all: the automatic reset one was not consumed', WaitForHandles([Automatic], 0) = 0);
  SetEvent(Automatic);
  SetEvent(Manual);
  Check('all: both signaled', WaitForAllHandles([Automatic, Manual], 0) = ErrorNone);
  Check('all: then the automatic reset one is consumed', TimedOut(WaitForHandles([Automatic], 0)));
  Check('all: and the manual reset one stays signaled', WaitForHandles([Manual], 0) = 0);
  Start := Int64(UptimeMilliseconds);
  Check('all: a timeout', WaitForAllHandles([Automatic, Manual], 30) = ErrorTimedOut);
  Check('all: after its time', Int64(UptimeMilliseconds) - Start >= 29);
  Check('all: a manual reset one is left as it was', WaitForHandles([Manual], 0) = 0);

  { Two timers due at different times: the wait ends with the later one,
    and the earlier one's signal waited for it. }
  Early := CreateTimer(False);
  Late := CreateTimer(False);
  Start := Int64(UptimeMilliseconds);
  SetTimer(Early, 20, 0);
  SetTimer(Late, 60, 0);
  Check('all: two timers', WaitForAllHandles([Early, Late], 5000) = ErrorNone);
  Check('all: not before the later one', Int64(UptimeMilliseconds) - Start >= 59);
  Check('all: both timers consumed together', TimedOut(WaitForHandles([Early], 0)) and
    TimedOut(WaitForHandles([Late], 0)));
  SetTimer(Early, 10, 0);
  Check('all: a timer and an event', WaitForAllHandles([Early, Manual], 5000) = ErrorNone);
  Handles[0] := Automatic;
  Check('all: an unknown flag', KernelWaitForHandles(@Handles[0], 1, 0, $80) = -ErrorInvalidArgument);
  CloseHandle(Early);
  CloseHandle(Late);
  CloseHandle(Automatic);
  CloseHandle(Manual);
end;

{ --- Semaphores --- }

const
  SemaphoreWaiterCount = 3;

var
  { What the waiter threads saw, by thread. }
  SemaphoreWaitResults: array[0..SemaphoreWaiterCount - 1] of LongInt;
  SharedSemaphore: Int64;

function SemaphoreWaiterMain(Argument: Pointer): LongInt;
var
  Index: PtrInt;
begin
  Index := PtrInt(Argument);
  SemaphoreWaitResults[Index] := WaitForHandle(SharedSemaphore, 10000);
  Result := 0;
end;

function SemaphoreCountIs(Semaphore: Int64; Expected: LongInt): Boolean;
begin
  Result := GetSemaphoreCount(Semaphore) = Expected;
end;

procedure TestSemaphoreCounts;
var
  Semaphore: Int64;
  Event: Int64;
  Previous: LongInt;
  Start: Int64;
begin
  Semaphore := CreateSemaphore(2, 3);
  Check('semaphore: created', Semaphore >= 0);
  Check('semaphore: the handle kind', KernelGetHandleKind(Semaphore) = HandleKindSemaphore);
  Check('semaphore: starts at its count', SemaphoreCountIs(Semaphore, 2));
  Check('semaphore: a wait takes one', (WaitForHandle(Semaphore, 0) = ErrorNone) and SemaphoreCountIs(Semaphore, 1));
  Check('semaphore: and another', (WaitForHandle(Semaphore, 0) = ErrorNone) and SemaphoreCountIs(Semaphore, 0));
  Check('semaphore: at zero a wait times out', WaitForHandle(Semaphore, 0) = ErrorTimedOut);
  Start := Int64(UptimeMilliseconds);
  Check('semaphore: a timed wait times out', WaitForHandle(Semaphore, 30) = ErrorTimedOut);
  Check('semaphore: after its time', Int64(UptimeMilliseconds) - Start >= 29);
  Check('semaphore: release one (count was 0)',
    (ReleaseSemaphore(Semaphore, 1, Previous) = ErrorNone) and (Previous = 0));
  Check('semaphore: release two (count was 1)',
    (ReleaseSemaphore(Semaphore, 2, Previous) = ErrorNone) and (Previous = 1) and SemaphoreCountIs(Semaphore, 3));
  Check('semaphore: past the limit fails', ReleaseSemaphore(Semaphore, 1, Previous) = ErrorOverflow);
  Check('semaphore: and changes nothing', SemaphoreCountIs(Semaphore, 3));
  Check('semaphore: a huge release fails', ReleaseSemaphore(Semaphore, MaximumSemaphoreLimit, Previous) = ErrorOverflow);
  Check('semaphore: release of 0', ReleaseSemaphore(Semaphore, 0, Previous) = ErrorInvalidArgument);
  Check('semaphore: release of -1', ReleaseSemaphore(Semaphore, -1, Previous) = ErrorInvalidArgument);
  Check('semaphore: three waits empty it', (WaitForHandle(Semaphore, 0) = ErrorNone) and
    (WaitForHandle(Semaphore, 0) = ErrorNone) and (WaitForHandle(Semaphore, 0) = ErrorNone) and
    (WaitForHandle(Semaphore, 0) = ErrorTimedOut));

  Check('semaphore: limit 0 refused', CreateSemaphore(0, 0) = -ErrorInvalidArgument);
  Check('semaphore: count above the limit refused', CreateSemaphore(4, 3) = -ErrorInvalidArgument);
  Check('semaphore: negative count refused', CreateSemaphore(-1, 3) = -ErrorInvalidArgument);
  Check('semaphore: the largest limit', CreateSemaphoreAndClose(MaximumSemaphoreLimit, MaximumSemaphoreLimit));
  Event := CreateEvent(False, False);
  Check('semaphore: release of an event handle', ReleaseSemaphore(Event, 1, Previous) = ErrorBadHandle);
  Check('semaphore: count of an event handle', GetSemaphoreCount(Event) = -ErrorBadHandle);
  CloseHandle(Event);
  CloseHandle(Semaphore);
end;

{ Waiting for a semaphore with an event: one count is taken only when
  both are ready; waiting for either: the semaphore's place. }
procedure TestSemaphoreWithEvent;
var
  Semaphore: Int64;
  Event: Int64;
  Previous: LongInt;
  Start: Int64;
begin
  Semaphore := CreateSemaphore(1, 5);
  Event := CreateEvent(False, False);
  Check('semaphore and event: all, the event not signaled', WaitForAllHandles([Semaphore, Event], 0) = ErrorTimedOut);
  Check('semaphore and event: the count was not taken', SemaphoreCountIs(Semaphore, 1));
  Start := Int64(UptimeMilliseconds);
  Check('semaphore and event: all, a timeout', WaitForAllHandles([Semaphore, Event], 30) = ErrorTimedOut);
  Check('semaphore and event: after its time', Int64(UptimeMilliseconds) - Start >= 29);
  SetEvent(Event);
  Check('semaphore and event: all, both ready', WaitForAllHandles([Semaphore, Event], 0) = ErrorNone);
  Check('semaphore and event: one count taken', SemaphoreCountIs(Semaphore, 0));
  Check('semaphore and event: the event consumed', TimedOut(WaitForHandles([Event], 0)));
  SetEvent(Event);
  Check('semaphore and event: all, the semaphore at zero', WaitForAllHandles([Semaphore, Event], 0) = ErrorTimedOut);
  Check('semaphore and event: the event left signaled', WaitForHandles([Event], 0) = 0);
  ReleaseSemaphore(Semaphore, 1, Previous);
  Check('semaphore and event: any, the semaphore', WaitForHandles([Event, Semaphore], 0) = 1);
  Check('semaphore and event: any, then neither', TimedOut(WaitForHandles([Event, Semaphore], 0)));
  CloseHandle(Event);
  CloseHandle(Semaphore);
end;

{ Three threads wait on an empty semaphore; one release of three lets
  all of them through, and the count ends at zero. }
procedure TestSemaphoreWaiters;
var
  Threads: array[0..SemaphoreWaiterCount - 1] of Int64;
  Index: Integer;
  ExitCode: LongInt;
  Previous: LongInt;
  AllWoke: Boolean;
  Semaphore: TSemaphore;
begin
  SharedSemaphore := CreateSemaphore(0, SemaphoreWaiterCount);
  for Index := 0 to SemaphoreWaiterCount - 1 do
  begin
    SemaphoreWaitResults[Index] := -1;
    Threads[Index] := CreateThread(@SemaphoreWaiterMain, Pointer(PtrInt(Index)));
  end;
  SleepMilliseconds(50);
  Check('semaphore waiters: still waiting', SemaphoreWaitResults[0] = -1);
  Check('semaphore waiters: one release of three',
    (ReleaseSemaphore(SharedSemaphore, SemaphoreWaiterCount, Previous) = ErrorNone) and (Previous = 0));
  AllWoke := True;
  for Index := 0 to SemaphoreWaiterCount - 1 do
  begin
    if (Threads[Index] < 0) or (WaitForThread(Threads[Index], 10000, ExitCode) <> 0) then
      AllWoke := False
    else if SemaphoreWaitResults[Index] <> ErrorNone then
      AllWoke := False;
    if Threads[Index] >= 0 then
      CloseThreadHandle(Threads[Index]);
  end;
  Check('semaphore waiters: all three got one', AllWoke);
  Check('semaphore waiters: none left over', SemaphoreCountIs(SharedSemaphore, 0));
  CloseHandle(SharedSemaphore);

  Semaphore := TSemaphore.Create(1, 1);
  try
    Check('TSemaphore: acquire', Semaphore.Acquire(0));
    Check('TSemaphore: then empty', not Semaphore.Acquire(10));
    Check('TSemaphore: release', Semaphore.Release);
    Check('TSemaphore: not past its limit', not Semaphore.Release);
    Check('TSemaphore: count', Semaphore.Count = 1);
  finally
    Semaphore.Free;
  end;
end;

{ Timers and sleeps keep to the millisecond rather than to a 10 ms
  clock tick. The bounds leave room for a slow emulator; a tick-bound
  clock would take twice as long or more. }
procedure TestTimerAccuracy;
var
  Timer: Int64;
  Start: Int64;
  Elapsed: Int64;
  Count: Integer;
begin
  Timer := CreateTimer(False);
  Start := Int64(UptimeMilliseconds);
  SetTimer(Timer, 5, 0);
  Check('5 ms timer: goes off', WaitForHandles([Timer], 2000) = 0);
  Elapsed := Int64(UptimeMilliseconds) - Start;
  Check('5 ms timer: in about 5 ms', (Elapsed >= 4) and (Elapsed < 50));

  Start := Int64(UptimeMilliseconds);
  SetTimer(Timer, 5, 5);
  Count := 0;
  while (Count < 20) and (WaitForHandles([Timer], 2000) = 0) do
    Inc(Count);
  Elapsed := Int64(UptimeMilliseconds) - Start;
  SetTimer(Timer, 0, 0);
  Check('5 ms periodic timer: twenty times in about 100 ms', (Count = 20) and (Elapsed >= 99) and (Elapsed < 250));

  Start := Int64(UptimeMilliseconds);
  SetTimer(Timer, 15, 15);
  Count := 0;
  while (Count < 10) and (WaitForHandles([Timer], 2000) = 0) do
    Inc(Count);
  Elapsed := Int64(UptimeMilliseconds) - Start;
  SetTimer(Timer, 0, 0);
  Check('15 ms periodic timer: ten times in about 150 ms', (Count = 10) and (Elapsed >= 149) and (Elapsed < 300));
  CloseHandle(Timer);

  Start := Int64(UptimeMilliseconds);
  for Count := 1 to 10 do
    SleepMilliseconds(2);
  Elapsed := Int64(UptimeMilliseconds) - Start;
  Check('ten sleeps of 2 ms: about 20 ms', (Elapsed >= 19) and (Elapsed < 90));
end;

procedure TestPipe;
var
  ReadEnd: Int64;
  WriteEnd: Int64;
  Byte_: Byte;
begin
  Check('pipe created', CreatePipe(ReadEnd, WriteEnd) = ErrorNone);
  Check('empty pipe: not readable', TimedOut(WaitForHandles([ReadEnd], 0)));
  Byte_ := 7;
  KernelWrite(WriteEnd, @Byte_, 1);
  Check('pipe with data: readable', WaitForHandles([ReadEnd], 0) = 0);
  KernelRead(ReadEnd, @Byte_, 1);
  Check('read empty again: not readable', TimedOut(WaitForHandles([ReadEnd], 0)));
  KernelClose(WriteEnd);
  Check('writer gone: readable (end of file)', WaitForHandles([ReadEnd], 0) = 0);
  KernelClose(ReadEnd);
end;

{ A pipe's write end is ready while there is room, or no reader. }
procedure TestPipeWriteEnd;
var
  ReadEnd: Int64;
  WriteEnd: Int64;
  Buffer: array[0..PipeCapacity - 1] of Byte;
begin
  Check('pipe for writing created', CreatePipe(ReadEnd, WriteEnd) = ErrorNone);
  Check('empty pipe: writable', WaitForHandles([WriteEnd], 0) = 0);
  FillChar(Buffer, SizeOf(Buffer), 1);
  Check('filled', KernelWrite(WriteEnd, @Buffer[0], PipeCapacity) = PipeCapacity);
  Check('full pipe: not writable', TimedOut(WaitForHandles([WriteEnd], 0)));
  Check('full pipe: readable and not writable at once',
    WaitForAllHandles([ReadEnd, WriteEnd], 0) = ErrorTimedOut);
  KernelRead(ReadEnd, @Buffer[0], 100);
  Check('drained a little: writable again', WaitForHandles([WriteEnd], 0) = 0);
  Check('readable and writable at once', WaitForAllHandles([ReadEnd, WriteEnd], 0) = ErrorNone);
  KernelWrite(WriteEnd, @Buffer[0], 100);
  Check('full again: not writable', TimedOut(WaitForHandles([WriteEnd], 0)));
  KernelClose(ReadEnd);
  Check('reader gone: writable (the write fails at once)', WaitForHandles([WriteEnd], 0) = 0);
  KernelClose(WriteEnd);
end;

{ The console can be waited on (whether input is there depends on who
  runs the test). }
procedure TestConsole;
var
  Console: Int64;
  Result_: Int64;
begin
  Console := KernelOpen('/dev/console', OpenRead);
  Check('console opened', Console >= 0);
  Result_ := WaitForHandles([Console], 0);
  Check('the console can be waited on', (Result_ = 0) or TimedOut(Result_));
  KernelClose(Console);
end;

procedure TestChannels;
var
  First: Int64;
  Second: Int64;
  Event: Int64;
  Buffer: array[0..127] of Char;
  Handles: array[0..3] of Int64;
  Length: QWord;
  HandleCount: QWord;
  Sent: Integer;
  Error: LongInt;
begin
  Check('channel created', CreateChannel(First, Second) = ErrorNone);
  Check('empty: would block', ReceiveMessage(Second, @Buffer[0], SizeOf(Buffer), Length, Handles, HandleCount) =
    ErrorWouldBlock);
  Event := CreateEvent(False, False);
  Check('send with a handle', SendMessage(First, PChar('hello'), 5, [Event]) = ErrorNone);
  Check('the other end is readable', WaitForHandles([Second], 0) = 0);
  Error := ReceiveMessage(Second, @Buffer[0], SizeOf(Buffer), Length, Handles, HandleCount);
  Check('received', (Error = ErrorNone) and (Length = 5) and (Buffer[0] = 'h') and (Buffer[4] = 'o') and
    (HandleCount = 1) and (Handles[0] >= 0) and (Handles[0] <> Event));
  SetEvent(Handles[0]);
  Check('the handle received is the same event', WaitForHandles([Event], 0) = 0);
  CloseHandle(Handles[0]);
  FillChar(Buffer, SizeOf(Buffer), 'x');
  SendMessage(First, @Buffer[0], 100, []);
  Error := ReceiveMessage(Second, @Buffer[0], 10, Length, Handles, HandleCount);
  Check('too long for the buffer: says what it needs', (Error = ErrorMessageTooLong) and (Length = 100));
  Check('then it fits', (ReceiveMessage(Second, @Buffer[0], SizeOf(Buffer), Length, Handles, HandleCount) =
    ErrorNone) and (Length = 100));
  Sent := 0;
  while SendMessage(First, @Buffer[0], 1, []) = ErrorNone do
    Inc(Sent);
  Check('a full queue: would block', Sent = MaximumQueuedMessages);
  CloseHandle(First);
  Sent := 0;
  while ReceiveMessage(Second, @Buffer[0], SizeOf(Buffer), Length, Handles, HandleCount) = ErrorNone do
    Inc(Sent);
  Check('what was sent is still received', Sent = MaximumQueuedMessages);
  Check('then the closed end shows', (ReceiveMessage(Second, @Buffer[0], SizeOf(Buffer), Length, Handles,
    HandleCount) = ErrorBrokenPipe) and (WaitForHandles([Second], 0) = 0));
  Check('sending to a closed end', SendMessage(Second, @Buffer[0], 1, []) = ErrorBrokenPipe);
  CloseHandle(Second);
  CloseHandle(Event);
end;

{ The parent's side of the shared section test. }
procedure TestSharedSection;
var
  Port: Int64;
  Section: Int64;
  Event: Int64;
  Pixels: PLongWord;
  Index: Integer;
  Child: Int64;
  Channel: Int64;
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  ExitCode: LongInt;
  Correct: Boolean;
begin
  Port := CreatePort(PortName);
  Check('port created', Port >= 0);
  Check('a port name is taken once', CreatePort(PortName) = -ErrorExists);
  Check('connecting to no port', ConnectPort('no-such-port') = -ErrorNotFound);
  Section := CreateSection(SectionBytes);
  Pixels := MapSection(Section, 0, SectionBytes);
  Check('section created and mapped', (Section >= 0) and (Pixels <> nil));
  if Pixels = nil then
    Exit;
  for Index := 0 to PatternCount - 1 do
    Pixels[Index] := LongWord(Index) * 3;
  Event := CreateEvent(False, False);
  Arguments[0] := 'ipctest';
  Arguments[1] := '--child';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Child := StartProgram('/bin/ipctest', @Arguments[0], Options);
  Check('child started', Child >= 0);
  Check('a connection arrives at the port', WaitForHandles([Port], ChildTimeout) = 0);
  Channel := AcceptConnection(Port);
  Check('accepted', Channel >= 0);
  Check('section and event sent', SendMessage(Channel, PChar('section'), 7, [Section, Event]) = ErrorNone);
  Check('the child signals the event', WaitForHandles([Event, Child], ChildTimeout) = 0);
  Check('the child changed the shared memory', Pixels[PatternCount - 1] = ChildMark);
  Correct := True;
  for Index := 0 to PatternCount - 2 do
    Correct := Correct and (Pixels[Index] = LongWord(Index) * 3);
  Check('the rest is as written', Correct);
  Check('the process handle is signaled when it ends', WaitForHandles([Child], ChildTimeout) = 0);
  Check('the child passed its checks', (WaitForProgramWithTimeout(Child, 0, ExitCode) = ErrorNone) and
    (ExitCode = 0));
  UnmapSection(Pixels);
  CloseHandle(Channel);
  CloseHandle(Section);
  CloseHandle(Event);
  CloseHandle(Port);
  CloseHandle(Child);
  Check('the port name is free once closed', ConnectPort(PortName) = -ErrorNotFound);
end;

{ The child: connect, receive the section and event, check, change,
  signal. Exit status 0 if all was as expected. }
function RunChild: LongInt;
var
  Channel: Int64;
  Buffer: array[0..15] of Char;
  Handles: array[0..3] of Int64;
  Length: QWord;
  HandleCount: QWord;
  Pixels: PLongWord;
  Index: Integer;
begin
  Result := 1;
  Channel := ConnectPort(PortName);
  if Channel < 0 then
    Exit(2);
  if (WaitForMessage(Channel, @Buffer[0], SizeOf(Buffer), Length, Handles, HandleCount, ChildTimeout) <> ErrorNone)
     or (HandleCount <> 2) or (Length <> 7) then
    Exit(3);
  Pixels := MapSection(Handles[0], 0, SectionBytes);
  if Pixels = nil then
    Exit(4);
  for Index := 0 to PatternCount - 2 do
    if Pixels[Index] <> LongWord(Index) * 3 then
      Exit(5);
  Pixels[PatternCount - 1] := ChildMark;
  SetEvent(Handles[1]);
  UnmapSection(Pixels);
  Result := 0;
end;

begin
  if (ParamCount = 1) and TextIsEqual(PChar(ParamStr(1)), '--child') then
    Halt(RunChild);
  TestEvents;
  TestWaitForAll;
  TestSemaphoreCounts;
  TestSemaphoreWithEvent;
  TestSemaphoreWaiters;
  TestTimers;
  TestTimerAccuracy;
  TestPipe;
  TestPipeWriteEnd;
  TestConsole;
  TestChannels;
  TestSharedSection;
  WriteString(StandardOutput, Format('ipctest: %d of %d checks passed'#10, [Checks - Failures,
    Checks]));
  if Failures > 0 then
    Halt(1);
end.
