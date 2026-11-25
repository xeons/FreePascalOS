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
  fork (CallForkProcess), for the C library.

  The child is a new process with a copy of the caller's address space
  (copy on write, Processes.AddressSpaceCopy), every handle of the
  caller under the same number (thread handles left out: they stand for
  the caller's threads), its credentials, working and root directory,
  group, session, controlling terminal, limits, restrictions and signal
  dispositions, and one thread: a copy of the calling thread, which
  goes on from the same system call with the result 0 and the same
  thread pointer, thread data, stack (and its overflow handling) and
  signal mask; the thread block at the thread pointer gets the child
  thread's id. The parent gets the child's id. The parent keeps a
  reference to the child until it waits for it (Processes.ChildWaits).

  fork starts a process like any other way does: it is refused to a
  process restricted from creating processes (RestrictProcessCreation),
  and to a user running as many processes as its limit allows. A child
  that cannot be started gives back its memory and handles at once.

  The module list (what the kernel's loader loaded) is not copied: a C
  program's own dynamic linker keeps its libraries, and CallLoadLibrary
  is not for C programs.
}
unit Processes.Fork;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

function PerformForkProcess(Frame: PTrapFrame): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Mutex,
  Kernel.SpinLock,
  Objects.Manager,
  Processes.Process,
  Processes.Thread,
  Processes.Handles,
  Processes.AddressSpace,
  Processes.AddressSpaceCopy,
  Processes.UserThread,
  Processes.ChildWaits,
  Processes.Signals,
  Processes.Restrictions,
  Processes.LimitCalls,
  Processes.Arch.UserContext;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

procedure CopyProcessFields(Parent, Child: PProcess);
begin
  Child^.ParentProcessId := Parent^.ProcessId;
  CopyText(@Child^.CurrentDirectory[0], @Parent^.CurrentDirectory[0], ProcessPathCapacity);
  CopyText(@Child^.RootDirectory[0], @Parent^.RootDirectory[0], ProcessPathCapacity);
  CopyText(@Child^.CommandLine[0], @Parent^.CommandLine[0], ProcessCommandLineCapacity);
  Child^.GroupId := Parent^.GroupId;
  Child^.SessionId := Parent^.SessionId;
  Child^.Credentials := Parent^.Credentials;
  Child^.ControllingTerminal := Parent^.ControllingTerminal;
  Child^.IgnoresInterrupt := Parent^.IgnoresInterrupt;
  Child^.ExceptionDispatcher := Parent^.ExceptionDispatcher;
  Child^.ProcessCountLimit := Parent^.ProcessCountLimit;
  Child^.OomScoreAdjust := Parent^.OomScoreAdjust;
  Child^.Restrictions := Parent^.Restrictions;
  SetHandleLimit(Child^.Handles, Parent^.Handles.Limit);
  InheritSignalState(Parent, Child);
end;

{ Every handle but thread handles, under the same numbers (those above
  a limit lowered since they were opened too). }
function CopyHandles(Parent, Child: PProcess): LongInt;
var
  Handle: LongWord;
  Bound: LongWord;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Result := ErrorNone;
  AcquireMutex(Parent^.Lock);
  Handle := 0;
  Bound := HandleNumberBound(Parent^.Handles);
  while Handle < Bound do
  begin
    if LookupHandle(Parent^.Handles, Handle, Kind, ObjectBody) and (Kind <> HandleKindThread) then
      if not SetInheritedHandle(Child^.Handles, Integer(Handle), Kind, ObjectBody) then
      begin
        Result := ErrorOutOfMemory;
        Break;
      end;
    Inc(Handle);
  end;
  ReleaseMutex(Parent^.Lock);
end;

{ A child that never ran gives back its memory and handles now, not
  when its parent reaps it. }
procedure ReleaseUnstartedChild(Child: PProcess);
var
  Space: PAddressSpace;
begin
  AcquireMutex(Child^.Lock);
  CloseAllHandles(Child^.Handles);
  PublishAddressSpace(Child^.AddressSpace, nil, Space);
  ReleaseMutex(Child^.Lock);
  DestroyAddressSpace(Space);
end;

function PerformForkProcess(Frame: PTrapFrame): Int64;
var
  Parent: PProcess;
  Child: PProcess;
  Caller: PThread;
  ChildThread: PThread;
  Context: TAbiContext;
  Error: LongInt;
  Space: PAddressSpace;
  Previous: PAddressSpace;
  Start: TForkedThreadStart;
begin
  Parent := CurrentProcess;
  Caller := CurrentThreadObject;
  if CallerRestricted(RestrictProcessCreation) then
    Exit(Failure(ErrorAccessDenied));
  { Its user may run only so many processes at once. }
  if not UserMayStartProcess(Parent^.Credentials.RealUserId, Parent^.ProcessCountLimit) then
    Exit(Failure(ErrorWouldBlock));
  Child := CreateProcessObject(@Parent^.Name[0]);
  if Child = nil then
    Exit(Failure(ErrorOutOfMemory));
  CopyProcessFields(Parent, Child);
  Error := DuplicateAddressSpace(Parent^.AddressSpace, Space);
  if Error = ErrorNone then
  begin
    PublishAddressSpace(Child^.AddressSpace, Space, Previous);
    Child^.PageTableRoot := Space^.Root;
    Error := CopyHandles(Parent, Child);
  end;
  if Error = ErrorNone then
    Error := AddChild(Parent, Child);
  if Error <> ErrorNone then
  begin
    DereferenceObject(Child);
    Exit(Failure(Error));
  end;

  { The child goes on from this system call with the result 0. }
  CaptureUserContext(Frame, Context);
{$ifdef CPUAARCH64}
  Context.X[0] := 0;
{$else}
  Context.Rax := 0;
{$endif}
  { The child's thread goes on with the caller's thread pointer, thread
    data and stack, all copies in the child's space. }
  Start.ThreadPointer := Caller^.ControlBlock.UserThreadPointer;
  Start.ThreadDataStart := Caller^.ThreadDataStart;
  Start.StackStart := Caller^.UserStackStart;
  Start.OpenedStackReserve := Caller^.OpenedStackReserve;
  Start.SignalMask := Caller^.Posix.SignalMask;
  Start.RecordsThreadId := (Caller^.ThreadDataStart <> 0) and
    (RegionStartOf(Parent^.AddressSpace, Start.ThreadPointer) = Caller^.ThreadDataStart);
  RegisterRunningProcess(Child);
  Error := StartForkedUserThread(Child, Context, Start, @Parent^.Name[0], ChildThread);
  if Error <> ErrorNone then
  begin
    UnregisterRunningProcess(Child);
    { Never ran: reaped like a child that ended at once. }
    ReleaseUnstartedChild(Child);
    MarkProcessExited(Child, 127);
    DereferenceObject(Child);
    Exit(Failure(Error));
  end;
  Result := Int64(Child^.ProcessId);
  { The parent's list of children holds the child from here on. }
  DereferenceObject(Child);
end;

end.
