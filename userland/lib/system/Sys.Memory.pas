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
  The program heap.

  This is the heap of the runtime library (System's memory manager): the
  same blocks GetMem, New, strings, dynamic arrays and objects use, so a
  program and all its libraries share one heap. It is safe to use from
  every thread. Blocks are 16-byte aligned.

  As everywhere in Free Pascal, running out of memory ends the program
  with runtime error 203 (or raises EOutOfMemory where SysUtils is used)
  rather than returning nil.

  Below the heap, pages straight from the kernel: address space reserved
  without memory, committed and decommitted in parts, protected (read,
  read-write, read-execute, no access, one-shot guards), and files
  mapped into memory. These return 0 or an error code (Sys.Errors).
  Memory is never writable and executable at once; making memory
  executable at all needs AllowDynamicCode first (a compiler at run time
  writes code into read-write pages, then protects them read-execute).
}
unit Sys.Memory;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

function AllocateMemory(ByteCount: QWord): Pointer;
function AllocateZeroedMemory(ByteCount: QWord): Pointer;
procedure FreeMemory(Block: Pointer);
{ Grows or shrinks a block, keeping its contents; may move it. }
function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
{ The usable size of a block. }
function MemoryBlockSize(Block: Pointer): QWord;

{ A heap copy of Text. }
function DuplicateText(Text: PChar): PChar;

const
  { Protections (the kernel's Memory* values). }
  ProtectNoAccess = MemoryNoAccess;
  ProtectRead = MemoryRead;
  ProtectReadWrite = MemoryReadWrite;
  ProtectReadExecute = MemoryReadExecute;
  { Added to another: the first touch raises an access violation and
    takes the guard off that page. }
  ProtectGuard = MemoryGuard;

  { MapFile's flags: shared read-only by default. }
  MapFilePrivate = MapPrivate;
  MapFileWritable = MapWritable;
  MapFileExecutable = MapExecutable;

type
  TMemoryInformation = TAbiMemoryInformation;

{ Reserves ByteCount bytes (whole pages) of address space without
  memory. }
function ReserveMemory(ByteCount: QWord; out Address: Pointer): LongInt;
{ Commits pages of a reservation with a protection: they count against
  the commit limit and are zero until written. }
function CommitMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): LongInt;
{ Gives the memory of those pages back; they stay reserved. }
function DecommitMemory(Address: Pointer; ByteCount: QWord): LongInt;
{ Frees a whole reservation (or allocation, or file mapping) from the
  address ReserveMemory or MapFile gave. }
function ReleaseMemory(Address: Pointer): LongInt;
{ Changes the protection of committed pages; Previous is the first
  page's. }
function ProtectMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord; out Previous: LongWord): LongInt;
{ Describes the run of alike pages around Address. }
function QueryMemory(Address: Pointer; out Information: TMemoryInformation): LongInt;
{ Lets this process make memory executable (or not any more). }
function AllowDynamicCode(Allowed: Boolean): LongInt;
{ Maps ByteCount bytes (0: to the end) of the file open on Handle from
  Offset (page aligned). Read-only shared unless Flags say otherwise; a
  writable shared mapping needs a handle open for writing, and what is
  written to it reaches the file (SyncMemory, unmapping, or within
  seconds); a private one is copy on write. Unmapped with
  ReleaseMemory; it stays valid after the handle is closed. }
function MapFile(Handle: Int64; Offset, ByteCount: QWord; Flags: LongWord; out Address: Pointer): LongInt;
{ Writes what was written to the shared file mappings of the pages
  [Address, Address + ByteCount) back to their files; with
  SyncMemoryWait in Flags it is on the disk when this returns. }
function SyncMemory(Address: Pointer; ByteCount: QWord; Flags: LongWord): LongInt;
{ One byte of PageResidency* bits per page of [Address, Address +
  ByteCount) into Vector. }
function QueryMemoryResidency(Address: Pointer; ByteCount: QWord; Vector: PByte): LongInt;
function GetMappedFileStatistics(out Statistics: TAbiMappedFileStatistics): LongInt;
{ Drops up to PagesWanted pages of mapped files (TrimMappedPagesToo:
  mapped ones too); the pages freed, or a negative error. Root only. }
function TrimMappedFiles(PagesWanted: QWord; Flags: LongWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors;

{ A request for nothing still gets a block, which can be freed. }
function AtLeastOne(ByteCount: QWord): QWord;
begin
  if ByteCount = 0 then
    Result := 1
  else
    Result := ByteCount;
end;

function AllocateMemory(ByteCount: QWord): Pointer;
begin
  Result := GetMem(AtLeastOne(ByteCount));
end;

function AllocateZeroedMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocMem(AtLeastOne(ByteCount));
end;

procedure FreeMemory(Block: Pointer);
begin
  if Block <> nil then
    FreeMem(Block);
end;

function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
begin
  Result := Block;
  ReAllocMem(Result, AtLeastOne(NewByteCount));
end;

function MemoryBlockSize(Block: Pointer): QWord;
begin
  if Block = nil then
    Exit(0);
  Result := MemSize(Block);
end;

function ReserveMemory(ByteCount: QWord; out Address: Pointer): LongInt;
var
  CallResult: Int64;
begin
  Address := nil;
  CallResult := KernelReserveMemory(ByteCount);
  Result := ErrorCodeOf(CallResult);
  if Result = 0 then
    Address := Pointer(CallResult);
end;

function CommitMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelCommitMemory(Address, ByteCount, Protection));
end;

function DecommitMemory(Address: Pointer; ByteCount: QWord): LongInt;
begin
  Result := ErrorCodeOf(KernelDecommitMemory(Address, ByteCount));
end;

function ReleaseMemory(Address: Pointer): LongInt;
begin
  Result := ErrorCodeOf(KernelFreeMemory(Address));
end;

function ProtectMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord; out Previous: LongWord): LongInt;
var
  CallResult: Int64;
begin
  Previous := 0;
  CallResult := KernelProtectMemory(Address, ByteCount, Protection);
  Result := ErrorCodeOf(CallResult);
  if Result = 0 then
    Previous := LongWord(CallResult);
end;

function QueryMemory(Address: Pointer; out Information: TMemoryInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelQueryMemory(Address, Information));
end;

function AllowDynamicCode(Allowed: Boolean): LongInt;
begin
  if Allowed then
    Result := ErrorCodeOf(KernelSetMemoryPolicy(MemoryPolicyAllowDynamicCode))
  else
    Result := ErrorCodeOf(KernelSetMemoryPolicy(0));
end;

function MapFile(Handle: Int64; Offset, ByteCount: QWord; Flags: LongWord; out Address: Pointer): LongInt;
var
  CallResult: Int64;
begin
  Address := nil;
  CallResult := KernelMapHandleWithFlags(Handle, Offset, ByteCount, Flags);
  Result := ErrorCodeOf(CallResult);
  if Result = 0 then
    Address := Pointer(CallResult);
end;

function SyncMemory(Address: Pointer; ByteCount: QWord; Flags: LongWord): LongInt;
begin
  Result := ErrorCodeOf(SystemCall(CallSyncMemory, QWord(Address), ByteCount, Flags, 0, 0, 0));
end;

function QueryMemoryResidency(Address: Pointer; ByteCount: QWord; Vector: PByte): LongInt;
begin
  Result := ErrorCodeOf(SystemCall(CallQueryMemoryResidency, QWord(Address), ByteCount, QWord(Vector), 0, 0, 0));
end;

function GetMappedFileStatistics(out Statistics: TAbiMappedFileStatistics): LongInt;
begin
  FillChar(Statistics, SizeOf(Statistics), 0);
  Result := ErrorCodeOf(SystemCall(CallGetMappedFileStatistics, QWord(@Statistics), 0, 0, 0, 0, 0));
end;

function TrimMappedFiles(PagesWanted: QWord; Flags: LongWord): Int64;
begin
  Result := SystemCall(CallTrimMappedFiles, PagesWanted, Flags, 0, 0, 0, 0);
end;

function DuplicateText(Text: PChar): PChar;
var
  Length: PtrUInt;
begin
  if Text = nil then
    Text := '';
  Length := TextLength(Text);
  Result := PChar(AllocateMemory(Length + 1));
  CopyMemory(Result, Text, Length + 1);
end;

end.
