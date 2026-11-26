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
  Self test of the parts of signals and timers that need no program
  (the C test suite, toolchain/ctest, runs the rest): the signal queue
  of a process made for the test (the order entries come out in, a
  timer's entry queued at most once and not counted, the queue's limit,
  a removed timer entry taking its signal's pending bit with it), the
  schedule of a periodic timer (missed periods, the end of the clock,
  the overrun's ceiling), the processor-time clock ids, and the signals
  processor exceptions become.
}
unit Kernel.SignalSelfTest;

{$mode objfpc}

interface

procedure RunSignalSelfTest;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.SelfTest,
  Processes.PosixState,
  Processes.Process,
  Processes.SignalQueue,
  Processes.TimerSchedules,
  Processes.ProcessorClocks,
  Processes.AlternateSignalStacks;

function Information(Signal: LongInt; Value: Int64): TAbiSignalInformation;
begin
  ZeroMemory(@Result, SizeOf(Result));
  Result.Signal := LongWord(Signal);
  Result.Code := SignalFromQueue;
  Result.Value := Value;
end;

procedure Append(Process: PProcess; Signal: LongInt; Value: Int64);
var
  Entry: PQueuedSignal;
begin
  Entry := AllocateQueuedSignal(Information(Signal, Value));
  Check(Entry <> nil, 'no memory for a queued signal');
  Check(AppendQueuedSignalLocked(Process, Entry), 'a queued signal was refused');
end;

function TakeValue(Process: PProcess; Signal: LongInt): Int64;
var
  Entry: PQueuedSignal;
begin
  Result := -1;
  Entry := TakeQueuedSignalLocked(Process, Signal);
  if Entry = nil then
    Exit;
  Result := Entry^.Information.Value;
  FreeQueuedSignals(Entry);
end;

procedure TestQueue;
var
  Process: PProcess;
  TimerEntry: TQueuedSignal;
  Index: LongInt;
  Spare: PQueuedSignal;
begin
  Process := PProcess(AllocateZeroedKernelMemory(SizeOf(TProcess)));
  Check(Process <> nil, 'no memory for the test process');
  Append(Process, 40, 1);
  Append(Process, 36, 2);
  Append(Process, 40, 3);
  Check(Process^.Posix.QueuedCount = 3, 'the queue does not count its entries');
  Check(TakeValue(Process, 40) = 1, 'the oldest entry of a signal is not taken first');
  Check(SignalIsQueuedLocked(Process, 40), 'a second entry of the signal is gone');
  Check(TakeValue(Process, 40) = 3, 'the second entry of a signal is wrong');
  Check(TakeValue(Process, 40) = -1, 'a signal no longer queued was taken');
  Check(TakeValue(Process, 36) = 2, 'another signal was lost');
  Check(Process^.Posix.QueuedCount = 0, 'the count does not come back to 0');

  ZeroMemory(@TimerEntry, SizeOf(TimerEntry));
  TimerEntry.Information := Information(SignalAlarm, 7);
  TimerEntry.Timer := @TimerEntry;
  Check(AppendQueuedSignalLocked(Process, @TimerEntry) and AppendQueuedSignalLocked(Process, @TimerEntry),
    'a timer entry was refused');
  Check(Process^.Posix.QueuedCount = 0, 'a timer entry counts against the limit');
  Process^.Posix.PendingSignals := QWord(1) shl (SignalAlarm - 1);
  RemoveQueuedSignalLocked(Process, @TimerEntry);
  Check(not TimerEntry.IsQueued and (Process^.Posix.QueueHead = nil), 'a timer entry stayed queued');
  Check(Process^.Posix.PendingSignals = 0, 'a removed timer entry left its signal pending');

  for Index := 1 to MaximumQueuedSignals do
    Append(Process, 50, Index);
  Spare := AllocateQueuedSignal(Information(50, 0));
  Check(not AppendQueuedSignalLocked(Process, Spare), 'the queue took more than its limit');
  FreeQueuedSignals(Spare);
  FreeQueuedSignals(RemoveAllQueuedSignalsLocked(Process));
  Check((Process^.Posix.QueuedCount = 0) and (Process^.Posix.QueueHead = nil) and
    (Process^.Posix.QueueTail = nil), 'emptying the queue left entries');
  FreeKernelMemory(Process);
end;

procedure TestSchedules;
var
  Missed: QWord;
begin
  Check((NextDueTime(100, 10, 105, Missed) = 110) and (Missed = 0), 'the next period is wrong');
  Check((NextDueTime(100, 10, 135, Missed) = 140) and (Missed = 3), 'missed periods are not counted');
  Check((NextDueTime(100, 10, 110, Missed) = 120) and (Missed = 1), 'a period due now is not passed');
  Check(NextDueTime(High(QWord) - 5, 10, 0, Missed) = NeverDueTime, 'a period past the clock came');
  Check(AddOverrun(HighestTimerOverrun - 1, 5) = HighestTimerOverrun, 'the overrun passed its ceiling');
  Check(AddOverrun(High(QWord), 2) = HighestTimerOverrun, 'the overrun wrapped');
end;

procedure TestClockIds;
var
  Kind: TProcessorClockKind;
  Id: QWord;
begin
  Check(DecodeProcessorClock(PosixClockProcessTime, Kind, Id) and (Kind = ProcessorClockProcess) and (Id = 0),
    'CLOCK_PROCESS_CPUTIME_ID');
  Check(DecodeProcessorClock(PosixClockThreadTime, Kind, Id) and (Kind = ProcessorClockThread) and (Id = 0),
    'CLOCK_THREAD_CPUTIME_ID');
  Check(DecodeProcessorClock((not Int64(123)) * 8 + PosixClockCpuScheduled, Kind, Id) and
    (Kind = ProcessorClockProcess) and (Id = 123), 'a process clock id');
  Check(DecodeProcessorClock((not Int64(77)) * 8 + PosixClockCpuScheduled + PosixClockCpuPerThread, Kind, Id) and
    (Kind = ProcessorClockThread) and (Id = 77), 'a thread clock id');
  Check(not DecodeProcessorClock(PosixClockMonotonic, Kind, Id), 'the monotonic clock taken for processor time');
  Check(not DecodeProcessorClock((not Int64(5)) * 8 + 1, Kind, Id), 'a bad processor clock id was taken');
end;

procedure TestExceptionSignals;
begin
  Check(SignalOfException(ExceptionStackOverflow) = SignalSegmentation, 'a stack overflow is not SIGSEGV');
  Check(SignalOfException(ExceptionAccessViolation) = SignalSegmentation, 'an access violation is not SIGSEGV');
  Check(SignalOfException(ExceptionIntegerDivide) = SignalFloatingPoint, 'a division by zero is not SIGFPE');
  Check(SignalOfException(ExceptionIllegalInstruction) = SignalIllegalInstruction, 'not SIGILL');
end;

procedure RunSignalSelfTest;
begin
  TestQueue;
  TestSchedules;
  TestClockIds;
  TestExceptionSignals;
  ReportPassed('signal queues, timer schedules and processor clock ids');
end;

end.
