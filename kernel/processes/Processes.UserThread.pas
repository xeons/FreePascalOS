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
  Threads of user processes.

  A user process has one or more threads sharing its address space and
  handles. Each thread has:

    * its own kernel stack (every thread does; system calls and
      interrupts run on it),
    * its own user stack, a region of the process with an unmapped guard
      page below it,
    * its own thread data region (Processes.ThreadStorage): the thread
      control block and a fresh copy of the static thread-local storage,
      reached through the thread pointer (%fs base), which the scheduler
      loads on every switch to the thread.

  Ending: a thread that exits releases its user stack (and the stack's
  guard), its thread data and the memory it allocated for itself
  (AllocateForThread: the runtime's threadvar block),
  leaves the address space and wakes those waiting for it. The process
  counts its active threads; the thread that brings the count to zero is
  the last one and ends the process (Processes.UserProcess). Ending the
  whole process from one thread marks it for termination, so the other
  threads end themselves at their next safe point (see
  Processes.Termination).
}
unit Processes.UserThread;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.Thread;

const
  UserThreadPriority = 8;

{ The thread priority for a nice value (-20 .. 19). }
function ThreadPriorityForNice(Nice: LongInt): LongWord;

{ Starts a user thread in Process at EntryPoint with the given stack
  pointer and Argument in the first argument register. StackStart is the
  start of the thread's stack region, which the thread releases when it
  exits; on failure the caller still owns it. With ReturnReference the
  caller receives a reference to the thread. Returns ErrorNone or an Abi
  error code. }
function StartUserThread(Process: PProcess; EntryPoint, StackPointer, Argument, StackStart: QWord;
  Name: PChar; ReturnReference: Boolean; out Thread: PThread): LongInt;

{ Ends the user side of the calling thread: releases its stack and
  thread data, leaves the address space and signals its exit. Returns
  True if it was the last active thread of its process, which must then
  end the process. The caller finishes with TerminateCurrentThread. }
function LeaveCurrentUserThread(ExitCode: LongInt): Boolean;

{ Waits until Thread has exited (or TimeoutMilliseconds pass, or the
  waiting thread is alerted). Returns ErrorNone, ErrorTimedOut or
  ErrorInterrupted. }
function WaitForThreadExit(Thread: PThread; TimeoutMilliseconds: QWord;
  out ExitCode: LongInt): LongInt;

implementation

uses
  Runtime.Atomic,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.Arch.UserMode,
  Kernel.Arch.ContextSwitch,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Processes.AddressSpace,
  Processes.ThreadStorage,
  Processes.UserProcess;

type
  TUserThreadStart = record
    EntryPoint: QWord;
    StackPointer: QWord;
    Argument: QWord;
    StackStart: QWord;
    ThreadDataStart: QWord;
    ThreadPointer: QWord;
  end;
  PUserThreadStart = ^TUserThreadStart;

{ Loads the calling thread's thread pointer. Interrupts stay off until
  the thread is in user mode, so no switch can come in between. }
procedure SetOwnThreadPointer(ThreadPointer: QWord);
begin
  DisableInterrupts;
  CurrentThread^.UserThreadPointer := ThreadPointer;
  ArchSetUserThreadPointer(ThreadPointer);
end;

procedure UserThreadStart(Context: Pointer);
var
  Start: TUserThreadStart;
  Thread: PThread;
begin
  Start := PUserThreadStart(Context)^;
  FreeKernelMemory(Context);

  Thread := CurrentThreadObject;
  Thread^.IsUserThread := True;
  Thread^.UserStackStart := Start.StackStart;
  Thread^.ThreadDataStart := Start.ThreadDataStart;
  RecordThreadId(Thread^.Process, Start.ThreadPointer, Thread^.ControlBlock.ThreadId);

  { A thread started while its process is being ended never runs: the
    alert that ends the others' waits may have gone out before it was
    listed, and its first wait would then never end. Listed before it
    started, it is alerted by any request made after this check. }
  if Thread^.Process^.TerminationRequested then
    ExitCurrentThread(Thread^.Process^.TerminationCode);

  SetOwnThreadPointer(Start.ThreadPointer);
  ArchEnterUserMode(Start.EntryPoint, Start.StackPointer, Start.Argument);
end;

function ThreadPriorityForNice(Nice: LongInt): LongWord;
begin
  { Nice 0 is the usual user priority; every 4 steps is one priority. }
  Result := LongWord(LongInt(UserThreadPriority) - Nice div 4);
end;

function StartUserThread(Process: PProcess; EntryPoint, StackPointer, Argument, StackStart: QWord;
  Name: PChar; ReturnReference: Boolean; out Thread: PThread): LongInt;
var
  Start: PUserThreadStart;
begin
  Thread := nil;
  Start := PUserThreadStart(AllocateZeroedKernelMemory(SizeOf(TUserThreadStart)));
  if Start = nil then
    Exit(ErrorOutOfMemory);
  Result := CreateThreadStorage(Process, Start^.ThreadDataStart, Start^.ThreadPointer);
  if Result <> ErrorNone then
  begin
    FreeKernelMemory(Start);
    Exit;
  end;
  Start^.EntryPoint := EntryPoint;
  Start^.StackPointer := StackPointer;
  Start^.Argument := Argument;
  Start^.StackStart := StackStart;

  { Counted before it starts: it may exit at once. The creator is itself
    an active thread (or the process has not started yet), so the count
    cannot reach zero in between. }
  AtomicIncrement(Process^.ActiveUserThreads);
  { Every thread runs at the priority its process's nice value gives. }
  Thread := CreateThreadInProcess(Process, @UserThreadStart, Start,
    ThreadPriorityForNice(Process^.Credentials.Nice), Name,
    ReturnReference);
  if Thread = nil then
  begin
    AtomicDecrement(Process^.ActiveUserThreads);
    ReleaseThreadStorage(Process, Start^.ThreadDataStart);
    FreeKernelMemory(Start);
    Exit(ErrorOutOfMemory);
  end;
  Result := ErrorNone;
end;

{ Switches the calling thread to the kernel's address space, so the
  process's can be freed even while this thread still runs. }
procedure LeaveAddressSpace;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  CurrentThread^.AddressSpaceRoot := KernelPageTableRoot;
  ActivateAddressSpace(KernelPageTableRoot);
  CurrentThread^.UserThreadPointer := 0;
  ArchSetUserThreadPointer(0);
  RestoreInterrupts(WereEnabled);
end;

function LeaveCurrentUserThread(ExitCode: LongInt): Boolean;
var
  Thread: PThread;
  Process: PProcess;
begin
  Thread := CurrentThreadObject;
  Process := Thread^.Process;

  { Unmapping the stack is safe: this thread runs on its kernel stack. }
  if Thread^.UserStackStart <> 0 then
    ReleaseUserRegion(Process^.AddressSpace, Thread^.UserStackStart);
  ReleaseThreadStorage(Process, Thread^.ThreadDataStart);
  { The threadvar block, if the runtime did not free it (the thread was
    ended from outside, which skips the runtime's own ending). }
  if Thread^.HasSeveralOwnedAllocations then
    ReleaseAllThreadOwnedMemory(Process^.AddressSpace, Thread^.ControlBlock.ThreadId)
  else
    ReleaseThreadOwnedMemory(Process^.AddressSpace, Thread^.OwnedAllocationStart, Thread^.ControlBlock.ThreadId);
  Thread^.UserStackStart := 0;
  Thread^.ThreadDataStart := 0;
  Thread^.OwnedAllocationStart := 0;
  LeaveAddressSpace;

  Thread^.ExitCode := ExitCode;
  SignalEvent(Thread^.ExitEvent);
  Result := AtomicDecrement(Process^.ActiveUserThreads) = 0;
end;

function WaitForThreadExit(Thread: PThread; TimeoutMilliseconds: QWord;
  out ExitCode: LongInt): LongInt;
begin
  ExitCode := 0;
  case WaitForEventWithOptions(Thread^.ExitEvent, TimeoutMilliseconds, True) of
    WaitSignaled:
      begin
        ExitCode := Thread^.ExitCode;
        Result := ErrorNone;
      end;
    WaitTimedOut: Result := ErrorTimedOut;
  else
    Result := ErrorInterrupted;
  end;
end;

end.
