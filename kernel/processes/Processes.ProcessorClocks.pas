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
  Processor-time clocks (CLOCK_PROCESS_CPUTIME_ID, CLOCK_THREAD_CPUTIME_ID,
  clock_getcpuclockid, pthread_getcpuclockid; CallGetProcessorClock).

  A thread's time is what it has run, exact to the clock (charged at
  every switch, Kernel.ProcessorTime); a process's is the sum over its
  threads, the ended ones included. The clock of a given process or
  thread has the Linux encoding: not (Id shl 3) plus
  PosixClockCpuScheduled, plus PosixClockCpuPerThread for a thread; Id 0
  means the caller. A thread's clock can be read for the threads of the
  caller's own process, a process's for any running process.
}
unit Processes.ProcessorClocks;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.Thread;

type
  TProcessorClockKind = (ProcessorClockProcess, ProcessorClockThread);

{ True if ClockId is a processor-time clock: which kind, and the process
  or thread id it is of (0: the caller). }
function DecodeProcessorClock(ClockId: Int64; out Kind: TProcessorClockKind; out Id: QWord): Boolean;

{ The time of the calling process, all of it and its part in user mode. }
procedure ReadProcessTimes(Process: PProcess; out RunNanoseconds, UserNanoseconds: QWord);
function ReadThreadTime(Thread: PThread): QWord;
{ The thread of the calling process with that id (0: the caller) has run
  Nanoseconds; False if there is none. }
function ReadOwnThreadTime(ThreadId: QWord; out Nanoseconds: QWord): Boolean;

function PerformGetProcessorClock(ClockId: Int64; TimeAddress, ResolutionAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.ProcessorTime,
  Processes.UserAccess;

const
  NanosecondsPerSecond = 1000000000;
  ClockKindBits = 7;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function DecodeProcessorClock(ClockId: Int64; out Kind: TProcessorClockKind; out Id: QWord): Boolean;
begin
  Kind := ProcessorClockProcess;
  Id := 0;
  Result := True;
  if ClockId = PosixClockProcessTime then
    Exit;
  if ClockId = PosixClockThreadTime then
  begin
    Kind := ProcessorClockThread;
    Exit;
  end;
  Result := False;
  if ClockId >= 0 then
    Exit;
  case ClockId and ClockKindBits of
    PosixClockCpuScheduled: Kind := ProcessorClockProcess;
    PosixClockCpuScheduled or PosixClockCpuPerThread: Kind := ProcessorClockThread;
  else
    Exit;
  end;
  { not (ClockId shr 3), shifting arithmetically: the low bits off first,
    so the division is exact. }
  Id := QWord(not ((ClockId - (ClockId and ClockKindBits)) div 8));
  Result := True;
end;

{ The user part SplitRunTime estimates from the ratio of the clock ticks
  can jump ahead when that ratio moves toward user mode, which would let
  ITIMER_VIRTUAL expire before its time. The time reported is kept
  between the last one and the last one plus the processor time since. }
procedure ReadProcessTimes(Process: PProcess; out RunNanoseconds, UserNanoseconds: QWord);
var
  Times: TThreadTimes;
  KernelNanoseconds: QWord;
  Estimate: QWord;
  Limit: QWord;
  PreviousLevel: TPriorityLevel;
begin
  GetProcessTimes(Process, Times);
  RunNanoseconds := Times.RunNanoseconds;
  SplitRunTime(Times, Estimate, KernelNanoseconds);
  PreviousLevel := AcquireSpinLock(Process^.Posix.UserTimeLock);
  with Process^.Posix do
  begin
    if RunNanoseconds < ReportedRunNanoseconds then
      RunNanoseconds := ReportedRunNanoseconds;
    Limit := ReportedUserNanoseconds + (RunNanoseconds - ReportedRunNanoseconds);
    if Estimate > Limit then
      Estimate := Limit;
    if Estimate < ReportedUserNanoseconds then
      Estimate := ReportedUserNanoseconds;
    ReportedUserNanoseconds := Estimate;
    ReportedRunNanoseconds := RunNanoseconds;
  end;
  ReleaseSpinLock(Process^.Posix.UserTimeLock, PreviousLevel);
  UserNanoseconds := Estimate;
end;

function ReadThreadTime(Thread: PThread): QWord;
var
  Times: TThreadTimes;
begin
  GetThreadTimes(@Thread^.ControlBlock, Times);
  Result := Times.RunNanoseconds;
end;

type
  TThreadTimeSearch = record
    ThreadId: QWord;
    Nanoseconds: QWord;
    Found: Boolean;
  end;
  PThreadTimeSearch = ^TThreadTimeSearch;

{ Runs under the thread list lock. }
procedure ReadMatchingThread(Thread: PThread; Context: Pointer);
var
  Search: PThreadTimeSearch;
begin
  Search := PThreadTimeSearch(Context);
  if Search^.Found or (Thread^.ControlBlock.ThreadId <> Search^.ThreadId) then
    Exit;
  Search^.Nanoseconds := ReadThreadTime(Thread);
  Search^.Found := True;
end;

function ReadOwnThreadTime(ThreadId: QWord; out Nanoseconds: QWord): Boolean;
var
  Search: TThreadTimeSearch;
begin
  if (ThreadId = 0) or (ThreadId = CurrentThreadObject^.ControlBlock.ThreadId) then
  begin
    Nanoseconds := ReadThreadTime(CurrentThreadObject);
    Exit(True);
  end;
  Search.ThreadId := ThreadId;
  Search.Nanoseconds := 0;
  Search.Found := False;
  VisitProcessThreads(CurrentProcess, @ReadMatchingThread, @Search);
  Nanoseconds := Search.Nanoseconds;
  Result := Search.Found;
end;

{ The run time of process Id (0: the caller). }
function ReadProcessTime(Id: QWord; out Nanoseconds: QWord): Boolean;
var
  Process: PProcess;
  UserNanoseconds: QWord;
begin
  Nanoseconds := 0;
  if (Id = 0) or (Id = CurrentProcess^.ProcessId) then
  begin
    ReadProcessTimes(CurrentProcess, Nanoseconds, UserNanoseconds);
    Exit(True);
  end;
  LockProcessRegistryShared;
  Process := FindRunningProcessLocked(Id);
  Result := Process <> nil;
  if Result then
    ReadProcessTimes(Process, Nanoseconds, UserNanoseconds);
  UnlockProcessRegistry;
end;

function StoreTime(Address: QWord; Nanoseconds: QWord): LongInt;
var
  Time: TAbiPreciseTime;
begin
  Time.Seconds := Int64(Nanoseconds div NanosecondsPerSecond);
  Time.Nanoseconds := LongWord(Nanoseconds mod NanosecondsPerSecond);
  Time.Reserved := 0;
  Result := CopyToUser(Address, @Time, SizeOf(Time));
end;

function PerformGetProcessorClock(ClockId: Int64; TimeAddress, ResolutionAddress: QWord): Int64;
var
  Kind: TProcessorClockKind;
  Id: QWord;
  Nanoseconds: QWord;
  Found: Boolean;
  Error: LongInt;
begin
  if not DecodeProcessorClock(ClockId, Kind, Id) then
    Exit(Failure(ErrorInvalidArgument));
  if Kind = ProcessorClockProcess then
    Found := ReadProcessTime(Id, Nanoseconds)
  else
    Found := ReadOwnThreadTime(Id, Nanoseconds);
  if not Found then
    Exit(Failure(ErrorNotFound));
  if TimeAddress <> 0 then
  begin
    Error := StoreTime(TimeAddress, Nanoseconds);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  { Charged at every switch from the fine clock: a nanosecond. }
  if ResolutionAddress <> 0 then
  begin
    Error := StoreTime(ResolutionAddress, 1);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Result := 0;
end;

end.
