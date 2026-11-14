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

  Every user thread gets one region holding, from low to high addresses,
  the TLS blocks of the program and its startup libraries and then the
  thread control block, which the thread pointer (%fs base) points at:

      region start                                   thread pointer
      | ... library TLS blocks ... | program TLS block | control block |

  This is the x86-64 "variant II" layout: a module's block starts
  TlsOffset bytes below the thread pointer (see Processes.ImageLoader).
  Each block starts as a fresh copy of the module's TLS image (.tdata)
  followed by zeros (.tbss).

  The control block's layout is part of the ABI (ThreadBlock* in
  Abi.SystemCalls): a pointer to itself, as %fs:0 must hold, a word for
  the user runtime and the thread id.
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
  Processes.ImageLoader;

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
    Result := WriteIntoAddressSpace(Space, ThreadPointer - Module^.TlsOffset, Buffer,
      Module^.TlsImageSize);
  FreeKernelMemory(Buffer);
end;

function FillThreadStorage(Process: PProcess; List: PModuleList; ThreadPointer: QWord): LongInt;
var
  Index: Integer;
  SelfPointer: QWord;
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
  SelfPointer := ThreadPointer;
  Result := WriteIntoAddressSpace(Process^.AddressSpace, ThreadPointer + ThreadBlockSelfOffset,
    @SelfPointer, SizeOf(SelfPointer));
end;

function CreateThreadStorage(Process: PProcess; out RegionStart, ThreadPointer: QWord): LongInt;
var
  List: PModuleList;
  Alignment: QWord;
  TlsAreaSize: QWord;
begin
  RegionStart := 0;
  ThreadPointer := 0;

  { The module list may grow while another thread loads a library. }
  AcquireMutex(Process^.Lock);
  List := PModuleList(Process^.Modules);
  Alignment := MinimumThreadPointerAlignment;
  TlsAreaSize := 0;
  if List <> nil then
  begin
    if List^.StaticTlsAlignment > Alignment then
      Alignment := List^.StaticTlsAlignment;
    TlsAreaSize := (List^.StaticTlsSize + Alignment - 1) and not (Alignment - 1);
  end;

  { The region starts on a page, and alignments are at most a page, so
    the thread pointer ends up aligned for every block. }
  Result := AllocateGuardedUserMemory(Process^.AddressSpace, TlsAreaSize + ThreadBlockSize,
    RegionKindThreadData, RegionStart);
  if Result = ErrorNone then
  begin
    ThreadPointer := RegionStart + TlsAreaSize;
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
