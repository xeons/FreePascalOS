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
  UserCopyFaulted. The Cortex-A72 (ARMv8.0) has no PAN, the AArch64
  counterpart of SMAP; with PAN the copies would clear it around the
  loop.
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
{ For the page fault handler: if the current thread faulted on a user
  address inside a copy routine, redirects it and returns True. }
function RecoverFromUserCopyFault(Frame: PTrapFrame; FaultAddress: QWord): Boolean;

implementation

uses
  Kernel.Threads,
  Kernel.Scheduler;

const
  UserSpaceLimit = QWord($0000800000000000);

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
  Result := True;
end;

end.
