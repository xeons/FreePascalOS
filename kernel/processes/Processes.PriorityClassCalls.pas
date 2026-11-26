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
  A process's priority class (CallSetPriorityClass, the rules in
  Kernel.PriorityClasses), and what follows from it: its threads' base
  priority, and whether it is one of the processes the user drives the
  system with - which may use the memory kept in reserve
  (Memory.Reserves for pages, Memory.CommitCharge for commitments), so
  the desktop and the task manager still work when an ordinary program
  has taken everything else.
}
unit Processes.PriorityClassCalls;

{$mode objfpc}

interface

uses
  Processes.Process;

{ (ProcessId, Class): see CallSetPriorityClass. }
function PerformSetPriorityClass(ProcessId: QWord; PriorityClass: QWord): Int64;
{ True if Process may use the memory reserves: its class is Interactive
  or System, or it is the initial program. }
function ProcessIsEssential(Process: PProcess): Boolean;
{ Tells Process's address space whether it may use the commit reserve
  (after its class changed, or a new space was made for it). }
procedure ApplyMemoryReserveAccess(Process: PProcess);
{ For Memory.Reserves: whether the current thread's page allocations
  may use the reserve (kernel threads and essential processes). }
function CurrentThreadMayUseMemoryReserve: Boolean;

implementation

uses
  Abi.SystemCalls,
  Kernel.Mutex,
  Kernel.Scheduler,
  Kernel.PriorityClasses,
  Objects.Manager,
  Processes.AddressSpace,
  Processes.Thread,
  Processes.UserThread,
  Processes.SecurityCalls;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function ProcessIsEssential(Process: PProcess): Boolean;
begin
  Result := (Process <> nil) and
    (IsEssentialPriorityClass(Process^.PriorityClass) or Process^.NeverEndForMemory);
end;

procedure ApplyMemoryReserveAccess(Process: PProcess);
var
  Space: PAddressSpace;
begin
  Space := ReferencePublishedSpace(Process^.AddressSpace);
  if Space = nil then
    Exit;
  SetCommitReserveAccess(Space, ProcessIsEssential(Process));
  ReleaseAddressSpaceReference(Space);
end;

function CurrentThreadMayUseMemoryReserve: Boolean;
var
  Thread: PThread;
begin
  if CurrentThread = nil then
    Exit(True);
  Thread := CurrentThreadObject;
  if (Thread = nil) or (Thread^.Process = nil) or not Thread^.Process^.IsUserProcess then
    Exit(True);
  Result := ProcessIsEssential(Thread^.Process);
end;

function MayControl(Caller, Target: PProcess): Boolean;
var
  CallerUserId: LongWord;
begin
  CallerUserId := Caller^.Credentials.EffectiveUserId;
  Result := (CallerUserId = RootUserId) or (Caller = Target) or
    (CallerUserId = Target^.Credentials.RealUserId) or (CallerUserId = Target^.Credentials.EffectiveUserId);
end;

function PerformSetPriorityClass(ProcessId: QWord; PriorityClass: QWord): Int64;
var
  Caller: PProcess;
  Target: PProcess;
  CallerIsRoot: Boolean;
  Previous: LongWord;
begin
  Caller := CurrentProcess;
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNoSuchProcess));
  Previous := Target^.PriorityClass;
  if PriorityClass = PriorityClassQuery then
  begin
    DereferenceObject(Target);
    Exit(Previous);
  end;
  CallerIsRoot := Caller^.Credentials.EffectiveUserId = RootUserId;
  if not IsValidPriorityClass(PriorityClass) then
    Result := Failure(ErrorInvalidArgument)
  else if not MayControl(Caller, Target) or
     not MaySetPriorityClass(CallerIsRoot, Caller^.PriorityClass, LongWord(PriorityClass)) then
    Result := Failure(ErrorNotPermitted)
  else
  begin
    AcquireMutex(Target^.Lock);
    Target^.PriorityClass := LongWord(PriorityClass);
    ReleaseMutex(Target^.Lock);
    SetProcessThreadPriorities(Target, ProcessThreadPriority(Target));
    ApplyMemoryReserveAccess(Target);
    Result := Previous;
  end;
  DereferenceObject(Target);
end;

end.
