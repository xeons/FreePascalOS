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
  Copying between the kernel and user memory on AArch64 (the copy loops
  are in UserAccess.s).

  A copy that faults on a user address (memory another thread just
  freed) continues at ArchUserCopyFault, which makes the routine return
  UserCopyFaulted. With PAN, the AArch64 counterpart of SMAP
  (Kernel.Arch.ProcessorProtection), the copies clear it around the
  loop, and a faulting copy gets it set again on its way out.
}
unit Kernel.Arch.UserCopy;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

const
  UserCopyFaulted = -1;
  UserCopyTooLong = -2;

{ Copies Length bytes; 0, or UserCopyFaulted. }
function ArchCopyUserMemory(Destination, Source: Pointer; Length: QWord): Int64;
{ Copies a zero terminated string of at most Capacity bytes including the
  terminator; the string's length, UserCopyTooLong (Capacity bytes were
  copied without a terminator) or UserCopyFaulted. }
function ArchCopyUserString(Destination, Source: PChar; Capacity: QWord): Int64;
procedure InitializeUserCopy;
{ True if the processor refuses kernel accesses to user pages outside
  the copy routines (PAN). }
function UserMemoryIsProtected: Boolean;
{ False only while this processor has the window to user memory open
  (PSTATE.PAN clear under PAN). }
function UserMemoryProtectionIsOnHere: Boolean;
{ For the page fault handler: if the current thread faulted on a user
  address inside a copy routine, redirects it and returns True. }
function RecoverFromUserCopyFault(Frame: PTrapFrame; FaultAddress: QWord): Boolean;

implementation

uses
  Kernel.Threads,
  Kernel.Scheduler;

const
  UserSpaceLimit = QWord($0000800000000000);
  SavedStatePan = QWord(1) shl 22;

var
  ArchPanEnabled: Byte; external name 'ArchPanEnabled';

function ArchUserCopyBytes(Destination, Source: Pointer; Length: QWord): Int64; external name 'ArchUserCopyBytes';
function ArchUserCopyString(Destination, Source: PChar; Capacity: QWord): Int64;
  external name 'ArchUserCopyString';
procedure ArchUserCopyBytesStart; external name 'ArchUserCopyBytes';
procedure ArchUserCopyBytesEnd; external name 'ArchUserCopyBytesEnd';
procedure ArchUserCopyStringStart; external name 'ArchUserCopyString';
procedure ArchUserCopyStringEnd; external name 'ArchUserCopyStringEnd';
procedure ArchUserCopyFault; external name 'ArchUserCopyFault';

procedure InitializeUserCopy;
begin
end;

function UserMemoryIsProtected: Boolean;
begin
  Result := ArchPanEnabled <> 0;
end;

function ArchReadPrivilegedAccessNever: QWord; external name 'ArchReadPrivilegedAccessNever';

function UserMemoryProtectionIsOnHere: Boolean;
begin
  Result := (ArchPanEnabled = 0) or ((ArchReadPrivilegedAccessNever and SavedStatePan) <> 0);
end;

function ArchCopyUserMemory(Destination, Source: Pointer; Length: QWord): Int64;
var
  Thread: PThreadControlBlock;
begin
  if Length = 0 then
    Exit(0);
  Thread := CurrentThread;
  Thread^.UserCopyActive := True;
  Result := ArchUserCopyBytes(Destination, Source, Length);
  Thread^.UserCopyActive := False;
end;

function ArchCopyUserString(Destination, Source: PChar; Capacity: QWord): Int64;
var
  Thread: PThreadControlBlock;
begin
  if Capacity = 0 then
    Exit(UserCopyTooLong);
  Thread := CurrentThread;
  Thread^.UserCopyActive := True;
  Result := ArchUserCopyString(Destination, Source, Capacity);
  Thread^.UserCopyActive := False;
end;

function IsInside(Address: QWord; StartRoutine, EndRoutine: Pointer): Boolean;
begin
  Result := (Address >= QWord(StartRoutine)) and (Address < QWord(EndRoutine));
end;

function RecoverFromUserCopyFault(Frame: PTrapFrame; FaultAddress: QWord): Boolean;
var
  Thread: PThreadControlBlock;
begin
  Result := False;
  if FaultAddress >= UserSpaceLimit then
    Exit;
  Thread := CurrentThread;
  if (Thread = nil) or not Thread^.UserCopyActive then
    Exit;
  if not IsInside(Frame^.Elr, @ArchUserCopyBytesStart, @ArchUserCopyBytesEnd) and
     not IsInside(Frame^.Elr, @ArchUserCopyStringStart, @ArchUserCopyStringEnd) then
    Exit;
  Frame^.Elr := QWord(@ArchUserCopyFault);
  { The copy had PAN cleared; the code after it must not. }
  if ArchPanEnabled <> 0 then
    Frame^.Spsr := Frame^.Spsr or SavedStatePan;
  Result := True;
end;

end.
