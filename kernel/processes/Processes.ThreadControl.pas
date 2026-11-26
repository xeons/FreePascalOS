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
  Suspending, resuming, ending and prioritizing threads of a process.

  Like stopping or ending a whole process (Processes.Stopping,
  Processes.Termination), nothing happens to a thread at an arbitrary
  point in the kernel, where it may hold locks. A request marks the
  thread and alerts it; the thread acts on it at its next safe point - a
  system call or interrupt about to return to user mode
  (HoldCurrentThreadIfAsked):

    * suspended: it waits until it has been resumed as often as it was
      suspended; a system call cut short by the suspension runs again,
      so the program does not notice,
    * asked to end: it ends as if it had called CallExitThread (the last
      thread of a process ends the process).

  A thread's priority is its process's (from the nice value) plus an
  offset of -15 .. 15; only root may raise a thread above its process.
}
unit Processes.ThreadControl;

{$mode objfpc}

interface

uses
  Processes.Thread;

{ The safe point for the current thread. Called at PassiveLevel with
  interrupts enabled. }
procedure HoldCurrentThreadIfAsked;
{ Cheap test for the interrupt return path: does the current thread have
  a suspension or an end to act on? }
function CurrentThreadIsAsked: Boolean;
{ True if the current thread is suspended (and not being ended), so an
  interrupted system call should run again afterwards. }
function CurrentThreadSuspendIsPending: Boolean;

{ Return the previous suspend count. }
function SuspendThread(Thread: PThread): LongInt;
function ResumeThread(Thread: PThread): LongInt;
procedure RequestThreadExit(Thread: PThread; ExitCode: LongInt);
{ Returns ErrorNone, ErrorInvalidArgument or ErrorNotPermitted. }
function SetThreadPriorityOffset(Thread: PThread; Offset: LongInt): LongInt;

function PerformSuspendThread(Handle: Int64): Int64;
function PerformResumeThread(Handle: Int64): Int64;
function PerformTerminateThread(Handle: Int64; ExitCode: QWord): Int64;
function PerformSetThreadPriority(Handle: Int64; Offset: Int64): Int64;
function PerformGetThreadPriority(Handle: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Events,
  Kernel.Mutex,
  Kernel.Scheduler,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Objects.Manager,
  Processes.Process,
  Processes.Handles,
  Processes.Security,
  Processes.UserProcess,
  Processes.UserThread;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- The thread itself -------------------------------------------------- }

function CurrentThreadIsAsked: Boolean;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  Result := (Thread <> nil) and Thread^.IsUserThread and
    ((Thread^.SuspendCount > 0) or Thread^.ExitRequested);
end;

function CurrentThreadSuspendIsPending: Boolean;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  Result := (Thread <> nil) and Thread^.IsUserThread and (Thread^.SuspendCount > 0) and
    not Thread^.ExitRequested and not Thread^.Process^.TerminationRequested;
end;

procedure HoldCurrentThreadIfAsked;
var
  Thread: PThread;
  Process: PProcess;
begin
  if not CurrentThreadIsAsked then
    Exit;
  Thread := CurrentThreadObject;
  Process := Thread^.Process;
  while (Thread^.SuspendCount > 0) and not Thread^.ExitRequested and
        not Process^.TerminationRequested do
  begin
    { The suspension alerted this thread; forget that, so the wait
      blocks. Requests to end set their flag before they alert, so they
      are either seen here or end the wait. }
    ClearCurrentThreadAlert;
    if (Thread^.SuspendCount > 0) and not Thread^.ExitRequested and
       not Process^.TerminationRequested then
      WaitForEventWithOptions(Thread^.ResumeEvent, InfiniteTimeout, True);
  end;
  if Thread^.ExitRequested and not Process^.TerminationRequested then
    ExitCurrentThread(Thread^.RequestedExitCode);
end;

{ --- Requests -------------------------------------------------------------- }

function SuspendThread(Thread: PThread): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Thread^.Process^.StopLock);
  Result := Thread^.SuspendCount;
  Inc(Thread^.SuspendCount);
  if Result = 0 then
    ResetEvent(Thread^.ResumeEvent);
  ReleaseSpinLock(Thread^.Process^.StopLock, PreviousLevel);
  AlertThread(@Thread^.ControlBlock);
end;

function ResumeThread(Thread: PThread): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Resumed: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Thread^.Process^.StopLock);
  Result := Thread^.SuspendCount;
  if Result > 0 then
    Dec(Thread^.SuspendCount);
  Resumed := (Result = 1);
  ReleaseSpinLock(Thread^.Process^.StopLock, PreviousLevel);
  if Resumed then
    SignalEvent(Thread^.ResumeEvent);
end;

procedure RequestThreadExit(Thread: PThread; ExitCode: LongInt);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Thread^.Process^.StopLock);
  if not Thread^.ExitRequested then
  begin
    Thread^.RequestedExitCode := ExitCode;
    Thread^.ExitRequested := True;
  end;
  ReleaseSpinLock(Thread^.Process^.StopLock, PreviousLevel);
  { A suspended thread must get to its end. }
  SignalEvent(Thread^.ResumeEvent);
  AlertThread(@Thread^.ControlBlock);
end;

function SetThreadPriorityOffset(Thread: PThread; Offset: LongInt): LongInt;
var
  Process: PProcess;
begin
  if (Offset < ThreadPriorityOffsetLowest) or (Offset > ThreadPriorityOffsetHighest) then
    Exit(ErrorInvalidArgument);
  Process := CurrentProcess;
  if (Offset > 0) and Process^.IsUserProcess and
     (Process^.Credentials.EffectiveUserId <> RootUserId) then
    Exit(ErrorNotPermitted);
  Thread^.PriorityOffset := Offset;
  SetThreadPriority(@Thread^.ControlBlock,
    OffsetPriority(ProcessThreadPriority(Thread^.Process), Offset));
  Result := ErrorNone;
end;

{ --- System calls ----------------------------------------------------------- }

{ A referenced thread of the calling process (CurrentThreadHandle: the
  caller itself), or nil. }
function ReferenceThread(Handle: Int64): PThread;
var
  Caller: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if Handle = CurrentThreadHandle then
  begin
    Result := CurrentThreadObject;
    ReferenceObject(Result);
    Exit;
  end;
  Caller := CurrentProcess;
  AcquireMutex(Caller^.Lock);
  if LookupHandle(Caller^.Handles, Handle, Kind, ObjectBody) and (Kind = HandleKindThread) then
    ReferenceObject(ObjectBody)
  else
    ObjectBody := nil;
  ReleaseMutex(Caller^.Lock);
  Result := PThread(ObjectBody);
end;

function PerformSuspendThread(Handle: Int64): Int64;
var
  Thread: PThread;
begin
  Thread := ReferenceThread(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  Result := SuspendThread(Thread);
  DereferenceObject(Thread);
end;

function PerformResumeThread(Handle: Int64): Int64;
var
  Thread: PThread;
begin
  Thread := ReferenceThread(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  Result := ResumeThread(Thread);
  DereferenceObject(Thread);
end;

function PerformTerminateThread(Handle: Int64; ExitCode: QWord): Int64;
var
  Thread: PThread;
begin
  Thread := ReferenceThread(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  RequestThreadExit(Thread, LongInt(ExitCode));
  DereferenceObject(Thread);
  Result := 0;
end;

function PerformSetThreadPriority(Handle: Int64; Offset: Int64): Int64;
var
  Thread: PThread;
begin
  Thread := ReferenceThread(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Failure(SetThreadPriorityOffset(Thread, LongInt(Offset)));
  DereferenceObject(Thread);
end;

function PerformGetThreadPriority(Handle: Int64): Int64;
var
  Thread: PThread;
begin
  Thread := ReferenceThread(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Thread^.PriorityOffset + ThreadPriorityOffsetBias;
  DereferenceObject(Thread);
end;

end.
