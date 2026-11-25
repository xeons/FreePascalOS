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
  Copying to and from user memory on x86-64, surviving bad addresses.

  The system call layer checks a user range against the process's
  regions before it copies, but another thread of the process may free
  the memory in between. The copy routines (UserAccess.s) are small leaf
  functions that touch no stack while they copy; the calling thread is
  marked (UserCopyActive) while it is inside one. If a page fault on a
  user address cannot be resolved while the mark is set and the faulting
  instruction is inside one of the routines, the exception handler makes
  the routine return -1 (RecoverFromUserCopyFault). A fault elsewhere
  while the mark is set (an interrupt handler following a bad pointer in
  the middle of a copy) is a kernel bug, reported as one.

  With SMAP (supervisor mode access prevention) available, it is turned
  on: the processor then refuses every kernel access to user pages, and
  the copy routines allow it only for their own duration (STAC / CLAC).
  So any place that touched user memory directly would fault at once;
  the interrupt entry closes the window for the handlers it runs
  (Kernel.Arch.InterruptEntry).
}
unit Kernel.Arch.UserCopy;

{$mode objfpc}
{$asmmode intel}

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

{ Turns SMAP on if the processor has it (once, at start). }
procedure InitializeUserCopy;
{ True if the processor refuses kernel accesses to user pages outside
  the copy routines (SMAP). }
function UserMemoryIsProtected: Boolean;
{ False only while this processor has the window to user memory open
  (RFLAGS.AC set under SMAP). }
function UserMemoryProtectionIsOnHere: Boolean;

{ For the page fault handler: if the current thread faulted on a user
  address inside a copy routine, redirects it and returns True. }
function RecoverFromUserCopyFault(Frame: PTrapFrame; FaultAddress: QWord): Boolean;

implementation

uses
  Kernel.Arch.Cpu,
  Debug.Output,
  Kernel.Threads,
  Kernel.Scheduler;

const
  UserSpaceLimit = QWord($0000800000000000);
  ControlRegister4Smap = QWord(1) shl 21;
  { CPUID leaf 7, subleaf 0: EBX bit 20. }
  CpuidSmapBit = LongWord(1) shl 20;
  FlagsAlignmentCheck = QWord($40000);

var
  { Read by the copy routines and the interrupt entry: STAC/CLAC exist
    only with SMAP. }
  SmapEnabled: Byte; external name 'ArchSmapEnabled';

function ArchUserCopyBytes(Destination, Source: Pointer; Length: QWord): Int64; external name 'ArchUserCopyBytes';
function ArchUserCopyString(Destination, Source: PChar; Capacity: QWord): Int64;
  external name 'ArchUserCopyString';
procedure ArchUserCopyBytesStart; external name 'ArchUserCopyBytes';
procedure ArchUserCopyBytesEnd; external name 'ArchUserCopyBytesEnd';
procedure ArchUserCopyStringStart; external name 'ArchUserCopyString';
procedure ArchUserCopyStringEnd; external name 'ArchUserCopyStringEnd';
procedure ArchUserCopyFault; external name 'ArchUserCopyFault';

procedure InitializeUserCopy;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax < 7 then
    Exit;
  ExecuteCpuid(7, 0, Registers);
  if (Registers.Ebx and CpuidSmapBit) = 0 then
    Exit;
  WriteControlRegister4(ReadControlRegister4 or ControlRegister4Smap);
  SmapEnabled := 1;
  DebugBeginMessage;
  DebugWriteTag('cpu');
  DebugWriteLine('SMAP on: the kernel reaches user memory only through checked copies');
  DebugEndMessage;
end;

function UserMemoryIsProtected: Boolean;
begin
  Result := SmapEnabled <> 0;
end;

function ReadFlags: QWord; assembler; nostackframe;
asm
  pushfq
  pop rax
end;

function UserMemoryProtectionIsOnHere: Boolean;
begin
  Result := (SmapEnabled = 0) or ((ReadFlags and FlagsAlignmentCheck) = 0);
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
  if not IsInside(Frame^.Rip, @ArchUserCopyBytesStart, @ArchUserCopyBytesEnd) and
     not IsInside(Frame^.Rip, @ArchUserCopyStringStart, @ArchUserCopyStringEnd) then
    Exit;
  { The routines push nothing, so the stack pointer is still at the
    return address: ArchUserCopyFault returns UserCopyFaulted. }
  Frame^.Rax := QWord(UserCopyFaulted);
  Frame^.Rip := QWord(@ArchUserCopyFault);
  { Leave user accesses forbidden again (clears RFLAGS.AC). }
  Frame^.Rflags := Frame^.Rflags and not FlagsAlignmentCheck;
  Result := True;
end;

end.
