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
  Per-thread data of user threads: the thread control block and static
  thread-local storage.

  Every user thread gets one region holding the TLS blocks of the program
  and its startup libraries and the thread control block, which the
  thread pointer points at. On x86-64 (%fs base, "variant II") the
  blocks lie below the control block; on AArch64 (TPIDR_EL0, "variant
  I") they follow it (Processes.Arch.ImageFormat has the layout). Each
  block starts as a fresh copy of the module's TLS image (.tdata)
  followed by zeros (.tbss).

  The control block's layout is part of the ABI (ThreadBlock* in
  Abi.SystemCalls): on x86-64 a pointer to itself, as %fs:0 must hold,
  then a word for the user runtime and the thread id; on AArch64 the
  runtime word and the thread id.
}
unit Processes.ThreadStorage;

{$mode objfpc}

interface

uses
  Processes.Process;

{ Creates the data region of a new thread of Process. On success the
  region starts at RegionStart and the thread pointer to load is
  ThreadPointer. Returns ErrorNone or an Abi error code. }
function CreateThreadStorage(Process: PProcess; out RegionStart, ThreadPointer: QWord): LongInt;

{ Stores the thread id in the control block at ThreadPointer. }
function RecordThreadId(Process: PProcess; ThreadPointer: QWord; ThreadId: QWord): LongInt;

procedure ReleaseThreadStorage(Process: PProcess; RegionStart: QWord);

implementation

uses
  Abi.SystemCalls,
  Memory.Layout,
  Memory.KernelHeap,
  Kernel.Mutex,
  Processes.AddressSpace,
  Processes.UserRegions,
  Processes.ImageLoader,
  Processes.Arch.ImageFormat;

const
  MinimumThreadPointerAlignment = 16;

{ Copies a module's TLS image from the process's own copy of the module
  into the new thread's block. }
function CopyTlsImage(Space: PAddressSpace; Module: PLoadedModule; ThreadPointer: QWord): LongInt;
var
  Buffer: Pointer;
begin
  if Module^.TlsImageSize = 0 then
    Exit(ErrorNone);
  Buffer := AllocateKernelMemory(Module^.TlsImageSize);
  if Buffer = nil then
    Exit(ErrorOutOfMemory);
  Result := ReadFromAddressSpace(Space, Module^.TlsImageAddress, Buffer, Module^.TlsImageSize);
  if Result = ErrorNone then
    Result := WriteIntoAddressSpace(Space, ThreadPointer + QWord(TlsBlockDisplacement(Module^.TlsOffset)),
      Buffer, Module^.TlsImageSize);
  FreeKernelMemory(Buffer);
end;

function FillThreadStorage(Process: PProcess; List: PModuleList; ThreadPointer: QWord): LongInt;
var
  Index: Integer;
{$ifdef CPUX86_64}
  SelfPointer: QWord;
{$endif}
begin
  Result := ErrorNone;
  if List <> nil then
  begin
    for Index := 0 to List^.Count - 1 do
    begin
      if not List^.Modules[Index]^.HasThreadLocalStorage then
        Continue;
      Result := CopyTlsImage(Process^.AddressSpace, List^.Modules[Index], ThreadPointer);
      if Result <> ErrorNone then
        Exit;
    end;
  end;
{$ifdef CPUX86_64}
  SelfPointer := ThreadPointer;
  Result := WriteIntoAddressSpace(Process^.AddressSpace, ThreadPointer + ThreadBlockSelfOffset,
    @SelfPointer, SizeOf(SelfPointer));
{$endif}
end;

function CreateThreadStorage(Process: PProcess; out RegionStart, ThreadPointer: QWord): LongInt;
var
  List: PModuleList;
  Alignment: QWord;
  StaticTlsSize: QWord;
  RegionSize: QWord;
  ThreadPointerOffset: QWord;
begin
  RegionStart := 0;
  ThreadPointer := 0;

  { The module list may grow while another thread loads a library. }
  AcquireMutex(Process^.Lock);
  List := PModuleList(Process^.Modules);
  Alignment := MinimumThreadPointerAlignment;
  StaticTlsSize := 0;
  if List <> nil then
  begin
    if List^.StaticTlsAlignment > Alignment then
      Alignment := List^.StaticTlsAlignment;
    StaticTlsSize := List^.StaticTlsSize;
  end;
  LayOutThreadRegion(StaticTlsSize, Alignment, RegionSize, ThreadPointerOffset);

  Result := AllocateGuardedUserMemory(Process^.AddressSpace, RegionSize, RegionKindThreadData, RegionStart);
  if Result = ErrorNone then
  begin
    ThreadPointer := RegionStart + ThreadPointerOffset;
    Result := FillThreadStorage(Process, List, ThreadPointer);
    if Result <> ErrorNone then
    begin
      ReleaseUserRegion(Process^.AddressSpace, RegionStart);
      RegionStart := 0;
      ThreadPointer := 0;
    end;
  end;
  ReleaseMutex(Process^.Lock);
end;

function RecordThreadId(Process: PProcess; ThreadPointer: QWord; ThreadId: QWord): LongInt;
begin
  Result := WriteIntoAddressSpace(Process^.AddressSpace, ThreadPointer + ThreadBlockIdOffset,
    @ThreadId, SizeOf(ThreadId));
end;

procedure ReleaseThreadStorage(Process: PProcess; RegionStart: QWord);
begin
  if RegionStart <> 0 then
    ReleaseUserRegion(Process^.AddressSpace, RegionStart);
end;

end.
