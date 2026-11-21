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
  The hang watch: a diagnostic for systems that stop making progress.

  With the kernel option hangdump=SECONDS, a system thread watches how
  often processes start and end. If neither happens for that long while
  user processes exist, it writes every user thread to the kernel log -
  its process, name, state, what it waits on, how long it has run, where
  in the program it last entered the kernel and the system call it is
  in - and what every processor is running, then waits for progress
  again.
  The tests turn it on, so a hang explains itself in the log.

  Whether the option is given or not, it also watches processes that
  were told to end (killed, or crashed): ending takes no longer than
  reaching the next safe point, so one still there after
  OverdueEndingSeconds is stuck where the kernel cannot reach it, and
  its threads are written to the log the same way, once ("[ending]").
}
unit Processes.HangWatch;

{$mode objfpc}

interface

{ Starts the watch: overdue endings always, quiet systems if the
  hangdump option asks for it. }
procedure StartHangWatch;

implementation

uses
  Runtime.Text,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.SystemCallEntry,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.Options,
  Kernel.Clock,
  Processes.Process,
  Processes.Thread,
  Debug.Output;

const
  CheckIntervalMilliseconds = 1000;
  WatchThreadPriority = 24;
  OverdueEndingSeconds = 10;

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

{ Where the thread last came from user mode: the frame at the top of its
  kernel stack (for a thread running on another processor this is only
  as fresh as its last interrupt or system call). }
procedure DescribeUserState(Thread: PThread);
var
  UserFrame: PTrapFrame;
  CallFrame: PTrapFrame;
begin
  UserFrame := PTrapFrame(Thread^.ControlBlock.StackTop - SizeOf(TTrapFrame));
  CallFrame := PTrapFrame(Thread^.SystemCallFrame);
  DebugBeginMessage;
  DebugWriteTag('hang');
  DebugWrite('      user rip 0x');
  DebugWriteHex(TrapFrameInstructionPointer(UserFrame), 1);
  DebugWrite(', rsp 0x');
  DebugWriteHex(TrapFrameStackPointer(UserFrame), 1);
  if CallFrame <> nil then
  begin
    DebugWrite(', in system call ');
    DebugWriteDecimal(SystemCallNumber(CallFrame));
  end
  else
    DebugWrite(', not in a system call');
  DebugWriteLine('');
  DebugEndMessage;
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
  DebugWrite(' "');
  DebugWrite(@Block^.Name[0]);
  DebugWrite('" ');
  DebugWrite(StateName(Block^.State));
  if Block^.IsOnWaitList then
    DebugWrite(', on a wait list');
  if Block^.WaitBlockCount > 0 then
    DebugWrite(', waiting on events');
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
  if Thread^.IsUserThread then
    DescribeUserState(Thread);
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

var
  KernelTextEnd: Byte; external name 'KernelTextEnd';

{ The words on the interrupted stack that point into the kernel's code:
  mostly return addresses, so a rough call chain. }
procedure WriteLikelyCallers(Processor: PProcessor);
const
  KernelTextStart = QWord($FFFFFFFF80000000);
var
  Index: LongWord;
  Value: QWord;
begin
  if Processor^.InterruptedStackWords = 0 then
    Exit;
  DebugWrite(', called from');
  for Index := 0 to Processor^.InterruptedStackWords - 1 do
  begin
    Value := Processor^.InterruptedStack[Index];
    if (Value >= KernelTextStart) and (Value < QWord(@KernelTextEnd)) then
    begin
      DebugWrite(' 0x');
      DebugWriteHex(Value, 1);
    end;
  end;
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
    DebugWrite(@Processor^.RunningThread^.Name[0]);
    DebugWrite(' (thread ');
    DebugWriteDecimal(Processor^.RunningThread^.ThreadId);
    DebugWrite(', ran ');
    DebugWriteDecimal(Processor^.RunningThread^.RunTicks);
    DebugWrite(' ticks), last at 0x');
    DebugWriteHex(Processor^.InterruptedAddress, 1);
    WriteLikelyCallers(Processor);
    DebugWriteLine('');
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

{ A process told to end OverdueEndingSeconds ago or more that is still
  here, not reported yet: its threads, once. }
procedure ReportIfEndingOverdue(Process: PProcess; Context: Pointer);
var
  Described: Boolean;
begin
  if not Process^.IsUserProcess or not Process^.TerminationRequested or Process^.HasExited or
     Process^.OverdueEndingReported then
    Exit;
  if UptimeMilliseconds - Process^.TerminationRequestedAt < OverdueEndingSeconds * 1000 then
    Exit;
  Process^.OverdueEndingReported := True;
  DebugBeginMessage;
  DebugWriteTag('ending');
  DebugWrite('process ');
  DebugWriteDecimal(Process^.ProcessId);
  DebugWrite(' ');
  DebugWrite(@Process^.Name[0]);
  DebugWrite(' was told to end ');
  DebugWriteDecimal((UptimeMilliseconds - Process^.TerminationRequestedAt) div 1000);
  DebugWriteLine(' s ago and is still here:');
  DebugEndMessage;
  Described := False;
  DescribeProcess(Process, @Described);
  PBoolean(Context)^ := True;
end;

procedure ReportOverdueEndings;
var
  AnyReported: Boolean;
begin
  AnyReported := False;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@ReportIfEndingOverdue, @AnyReported);
  UnlockProcessRegistry;
  if AnyReported then
  begin
    DebugBeginMessage;
    DescribeProcessors;
    DebugEndMessage;
  end;
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
    ReportOverdueEndings;
    if LimitSeconds = 0 then
      Continue;
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

procedure StartHangWatch;
var
  Seconds: QWord;
begin
  LimitSeconds := 0;
  if GetKernelOptionNumber('hangdump', Seconds) then
    LimitSeconds := Seconds;
  CreateSystemThread(@WatchMain, nil, WatchThreadPriority, 'HangWatch', False);
end;

end.
