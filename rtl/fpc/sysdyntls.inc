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
  Dynamic thread-local storage: each thread's blocks for the libraries
  loaded with LoadLibrary after the program started, which the static
  layout next to the thread pointer has no room for. A thread's block of
  a library is made the first time the thread touches it, so threads
  that already ran when the library came get theirs too.

  Two kinds of library have them:

    * ELF modules with a PT_TLS segment (__thread, thread_local): their
      TLS module id is TlsDynamicModuleTag + their module handle
      (Processes.ImageLoader), which __tls_get_addr and the AArch64
      descriptor resolver (__tlsdesc_dynamic) look for here; the block
      starts as a copy of the module's image (CallGetModuleTls),
    * Free Pascal libraries with threadvars (registered by si_dll, see
      SysRegisterLibrary): their threadvars get offsets with
      ThreadvarDynamicFlag set, which SysRelocateThreadVar sends here;
      the block starts zeroed, as threadvars do in a new thread.

  Each thread has one vector (in the thread control block's runtime word
  ThreadBlockDynamicVectorOffset) of block pointers: entries 0 to
  DynamicModuleLimit - 1 by ELF module handle, the rest for threadvar
  libraries. What each entry's block looks like (a template) is kept
  once for the process. Libraries are never unloaded, so an entry, once
  filled, stays valid: there is no generation to check, and the AArch64
  resolver finds a filled entry without calling anything.

  Vectors and blocks come from the kernel (as the threadvar block does:
  the heap itself uses threadvars) marked as the thread's own
  (AllocateForThread), so the kernel frees them if the thread is ended
  from outside; a thread ending normally frees them in
  ReleaseDynamicTls.
}

const
  { The vector: its capacity, then the entries, in one page. }
  DynamicVectorEntries = 511;
  DynamicModuleLimit = 256;
  DynamicThreadvarLibraryLimit = DynamicVectorEntries - DynamicModuleLimit;

  { A threadvar offset of a library: the flag, the library's number
    (shifted by ThreadvarLibraryShift) and the offset in its block. }
  ThreadvarDynamicFlag = DWord($80000000);
  ThreadvarLibraryShift = 20;
  ThreadvarLibraryMask = DWord($7FF);
  ThreadvarOffsetMask = DWord($FFFFF);
  ThreadvarLibraryBlockLimit = ThreadvarOffsetMask + 1;
  { Blocks come from the kernel in whole pages. }
  DynamicTlsAlignmentLimit = 4096;

type
  TDynamicTlsTemplate = record
    { Set (last) once the rest is filled in. }
    IsKnown: Boolean;
    Size: PtrUInt;
    { Copied into each new block: ImageSize bytes from Image. }
    Image: Pointer;
    ImageSize: PtrUInt;
  end;

  PDynamicVector = ^TDynamicVector;
  TDynamicVector = record
    Capacity: PtrUInt;
    Blocks: array[0..DynamicVectorEntries - 1] of Pointer;
  end;

var
  DynamicTlsTemplates: array[0..DynamicVectorEntries - 1] of TDynamicTlsTemplate;
  DynamicTlsLock: LongInt = 0;
  ThreadvarLibraryCount: LongInt = 0;

function AllocateThreadPages(Size: PtrUInt): Pointer;
var
  Address: Int64;
begin
  Address := SystemCall(CallAllocateMemory, Size, AllocateForThread, 0, 0, 0, 0);
  if Address <= 0 then
    RunError(226);
  AllocateThreadPages := Pointer(Address);
end;

function ThreadDynamicVector: PDynamicVector;
var
  Vector: PDynamicVector;
begin
  Vector := PDynamicVector(ReadDynamicVector);
  if Vector = nil then
  begin
    Vector := PDynamicVector(AllocateThreadPages(SizeOf(TDynamicVector)));
    Vector^.Capacity := DynamicVectorEntries;
    WriteDynamicVector(Vector);
  end;
  ThreadDynamicVector := Vector;
end;

{ Makes the calling thread's block of entry Index (its template known). }
function MakeDynamicBlock(Index: PtrUInt): Pointer;
var
  Vector: PDynamicVector;
  Block: Pointer;
  Size: PtrUInt;
begin
  Vector := ThreadDynamicVector;
  Size := DynamicTlsTemplates[Index].Size;
  if Size = 0 then
    Size := 1;
  Block := AllocateThreadPages(Size);
  if DynamicTlsTemplates[Index].ImageSize > 0 then
    Move(DynamicTlsTemplates[Index].Image^, Block^, DynamicTlsTemplates[Index].ImageSize);
  Vector^.Blocks[Index] := Block;
  MakeDynamicBlock := Block;
end;

{ The calling thread's block of entry Index, made if need be. }
function DynamicBlock(Index: PtrUInt): Pointer;
var
  Vector: PDynamicVector;
begin
  Vector := PDynamicVector(ReadDynamicVector);
  if (Vector <> nil) and (Vector^.Blocks[Index] <> nil) then
    DynamicBlock := Vector^.Blocks[Index]
  else
    DynamicBlock := MakeDynamicBlock(Index);
end;

{ Learns what the blocks of the ELF module Handle look like, once. }
procedure LearnModuleTls(Handle: PtrUInt);
var
  Information: TAbiModuleTls;
begin
  AcquireWordLock(DynamicTlsLock);
  if not DynamicTlsTemplates[Handle].IsKnown then
  begin
    if (SystemCall(CallGetModuleTls, Handle, QWord(@Information), 0, 0, 0, 0) < 0) or
       (Information.Alignment > DynamicTlsAlignmentLimit) then
    begin
      ReleaseWordLock(DynamicTlsLock);
      RunError(226);
    end;
    DynamicTlsTemplates[Handle].Size := Information.BlockSize;
    DynamicTlsTemplates[Handle].Image := Pointer(Information.ImageAddress);
    DynamicTlsTemplates[Handle].ImageSize := Information.ImageSize;
    ReadWriteBarrier;
    DynamicTlsTemplates[Handle].IsKnown := True;
  end;
  ReleaseWordLock(DynamicTlsLock);
end;

{ The address of a variable of an ELF module with dynamic TLS. }
function DynamicTlsAddress(Handle: PtrUInt; Offset: PtrUInt): Pointer;
begin
  if Handle >= DynamicModuleLimit then
    RunError(226);
  if not DynamicTlsTemplates[Handle].IsKnown then
    LearnModuleTls(Handle);
  DynamicTlsAddress := DynamicBlock(Handle) + Offset;
end;

{ Called by __tlsdesc_dynamic when the thread's block is not there yet:
  the variable's address. }
function ResolveDynamicTlsDescriptor(Argument: QWord): PtrUInt;
begin
  ResolveDynamicTlsDescriptor := PtrUInt(DynamicTlsAddress(
    PtrUInt((Argument shr TlsDynamicHandleShift) and TlsDynamicHandleMask), PtrUInt(Argument and $FFFFFFFF)));
end;

{ The address of a threadvar of a library (Offset has
  ThreadvarDynamicFlag set). }
function ThreadvarLibraryAddress(Offset: DWord): Pointer;
var
  Index: PtrUInt;
begin
  Index := DynamicModuleLimit + ((Offset shr ThreadvarLibraryShift) and ThreadvarLibraryMask);
  if (Index >= DynamicVectorEntries) or not DynamicTlsTemplates[Index].IsKnown then
    RunError(226);
  ThreadvarLibraryAddress := DynamicBlock(Index) + (Offset and ThreadvarOffsetMask);
end;

{ A new entry for a threadvar library whose blocks are Size bytes;
  returns its library number (for the offsets), or -1 if there are too
  many. }
function AddThreadvarLibrary(Size: PtrUInt): LongInt;
var
  Index: PtrUInt;
begin
  AcquireWordLock(DynamicTlsLock);
  if ThreadvarLibraryCount >= DynamicThreadvarLibraryLimit then
    AddThreadvarLibrary := -1
  else
  begin
    AddThreadvarLibrary := ThreadvarLibraryCount;
    Index := DynamicModuleLimit + PtrUInt(ThreadvarLibraryCount);
    DynamicTlsTemplates[Index].Size := Size;
    DynamicTlsTemplates[Index].Image := nil;
    DynamicTlsTemplates[Index].ImageSize := 0;
    ReadWriteBarrier;
    DynamicTlsTemplates[Index].IsKnown := True;
    Inc(ThreadvarLibraryCount);
  end;
  ReleaseWordLock(DynamicTlsLock);
end;

{ Frees the calling thread's vector and blocks (it is ending). }
procedure ReleaseDynamicTls;
var
  Vector: PDynamicVector;
  Index: PtrUInt;
begin
  Vector := PDynamicVector(ReadDynamicVector);
  if Vector = nil then
    Exit;
  WriteDynamicVector(nil);
  for Index := 0 to DynamicVectorEntries - 1 do
    if Vector^.Blocks[Index] <> nil then
      SystemCall(CallFreeMemory, QWord(Vector^.Blocks[Index]), 0, 0, 0, 0, 0);
  SystemCall(CallFreeMemory, QWord(Vector), 0, 0, 0, 0, 0);
end;
