{
  The hang watch: a diagnostic for systems that stop making progress.

  With the kernel option hangdump=SECONDS, a system thread watches how
  often processes start and end. If neither happens for that long while
  user processes exist, it writes every user thread to the kernel log -
  its process, name, state, what it waits on and how long it has run -
  and what every processor is running, then waits for progress again.
  The tests turn it on, so a hang explains itself in the log.
}
unit Processes.HangWatch;

{$mode objfpc}

interface

{ Starts the watch if the hangdump option asks for it. }
procedure StartHangWatch;

implementation

uses
  Runtime.Text,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.Options,
  Processes.Process,
  Processes.Thread,
  Debug.Output;

const
  CheckIntervalMilliseconds = 1000;
  WatchThreadPriority = 24;

var
  LimitSeconds: QWord;

function StateName(State: TThreadState): PChar;
begin
  case State of
    ThreadStateInitialized: Result := 'new';
    ThreadStateReady: Result := 'ready';
    ThreadStateRunning: Result := 'running';
    ThreadStateWaiting: Result := 'waiting';
    ThreadStateTerminated: Result := 'ended';
  else
    Result := '?';
  end;
end;

procedure DescribeThread(Thread: PThread; Context: Pointer);
var
  Block: PThreadControlBlock;
begin
  Block := @Thread^.ControlBlock;
  { One message per line: the process registry and thread list locks
    are held, which must be taken before the debug output's. }
  DebugBeginMessage;
  DebugWriteTag('hang');
  DebugWrite('    thread ');
  DebugWriteDecimal(Block^.ThreadId);
  DebugWrite(' ');
  DebugWrite(StateName(Block^.State));
  if Block^.IsOnWaitList then
    DebugWrite(', on a wait list');
  if Block^.IsOnSleepQueue then
    DebugWrite(', with a timeout');
  if Block^.WaitIsAlertable then
    DebugWrite(', alertable');
  if Block^.AlertPending then
    DebugWrite(', alerted');
  if Thread^.SuspendCount > 0 then
    DebugWrite(', suspended');
  DebugWrite(', priority ');
  DebugWriteDecimal(Block^.Priority);
  DebugWrite(', last on processor ');
  DebugWriteDecimal(Block^.LastProcessorIndex);
  DebugWrite(', ran ');
  DebugWriteDecimal(Block^.RunTicks);
  DebugWriteLine(' ticks');
  DebugEndMessage;
end;

procedure DescribeProcess(Process: PProcess; Context: Pointer);
begin
  if not Process^.IsUserProcess then
    Exit;
  PBoolean(Context)^ := True;
  DebugBeginMessage;
  DebugWriteTag('hang');
  DebugWrite('  process ');
  DebugWriteDecimal(Process^.ProcessId);
  DebugWrite(' ');
  DebugWrite(@Process^.Name[0]);
  if Process^.StopRequested then
    DebugWrite(' (stop requested)');
  if Process^.TerminationRequested then
    DebugWrite(' (ending)');
  DebugWriteLine('');
  DebugEndMessage;
  VisitProcessThreads(Process, @DescribeThread, nil);
end;

procedure DescribeProcessors;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if not Processor^.IsOnline then
      Continue;
    DebugWriteTag('hang');
    DebugWrite('  processor ');
    DebugWriteDecimal(Index);
    DebugWrite(' runs ');
    DebugWriteLine(@Processor^.RunningThread^.Name[0]);
  end;
end;

{ Returns False if there was no user process to describe. }
function DumpUserThreads(Seconds: QWord): Boolean;
begin
  Result := False;
  DebugBeginMessage;
  DebugWriteTag('hang');
  DebugWrite('No process started or ended for ');
  DebugWriteDecimal(Seconds);
  DebugWriteLine(' s:');
  DebugEndMessage;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@DescribeProcess, @Result);
  UnlockProcessRegistry;
  DebugBeginMessage;
  DescribeProcessors;
  DebugEndMessage;
end;

procedure WatchMain(Context: Pointer);
var
  LastCount: QWord;
  QuietSeconds: QWord;
  Reported: Boolean;
begin
  LastCount := ProcessChangeCount;
  QuietSeconds := 0;
  Reported := False;
  while True do
  begin
    SleepMilliseconds(CheckIntervalMilliseconds);
    if ProcessChangeCount <> LastCount then
    begin
      LastCount := ProcessChangeCount;
      QuietSeconds := 0;
      Reported := False;
      Continue;
    end;
    Inc(QuietSeconds);
    if (QuietSeconds >= LimitSeconds) and not Reported then
      Reported := DumpUserThreads(QuietSeconds);
  end;
end;

{ The decimal number in Text, or 0. }
function DecimalValue(Text: PChar): QWord;
begin
  Result := 0;
  while Text^ in ['0'..'9'] do
  begin
    Result := Result * 10 + QWord(Ord(Text^) - Ord('0'));
    Inc(Text);
  end;
end;

procedure StartHangWatch;
var
  Value: array[0..15] of Char;
begin
  if not GetKernelOptionValue('hangdump', @Value[0], SizeOf(Value)) then
    Exit;
  LimitSeconds := DecimalValue(@Value[0]);
  if LimitSeconds = 0 then
    Exit;
  CreateSystemThread(@WatchMain, nil, WatchThreadPriority, 'HangWatch', False);
end;

end.
