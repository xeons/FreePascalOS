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
  The page heap (HEAP_CHECKS=pages): every block on pages of its own,
  ending right before a page nobody may touch.

  Each block is a reservation of its own (CallReserveMemory): enough
  pages for a 16-byte header and the block, committed read-write, and
  one more page left reserved after them, so the block's end is the end
  of its last page (rounded up to the heap's 16-byte alignment; those
  few bytes hold PageHeapSlackFill and are checked when the block is
  freed). A write or read past the end touches the reserved page and
  raises an access violation at the faulting instruction itself, with
  the program's own back trace - EAccessViolation where SysUtils is
  used.

  A freed block's pages are decommitted at once (no access: a use after
  free faults the same way) and the reservation waits in a queue of the
  PageHeapQuarantineCount most recently freed before it is released, so
  its addresses are not reused soon. Freeing a block twice, or a stray
  pointer, finds no committed header and is reported.

  Every block costs at least two pages of address space and one of
  memory, and two system calls: this is for finding a bug, not for
  running every day.
}

const
  PageHeapPageSize = 4096;
  PageHeapAlignment = 16;
  PageHeapMagic = LongWord($9A6EB10C);
  PageHeapSlackFill = Byte($FD);
  PageHeapAllocationFill = Byte($A5);
  PageHeapQuarantineCount = 1024;
  PageHeapLargestRequest = High(PtrUInt) div 4;

type
  TPageHeapHeader = record
    Magic: LongWord;
    Reserved: LongWord;
    RequestedSize: PtrUInt;
  end;
  PPageHeapHeader = ^TPageHeapHeader;

const
  NoFreedByPages: THeapCheckFreedBy = (nil, nil, nil, nil, nil, nil, nil, nil);

var
  PageHeapQuarantine: array[0..PageHeapQuarantineCount - 1] of Pointer;
  PageHeapQuarantineNext: SizeInt = 0;
  PageHeapLock: LongInt = LockFree;

function PageHeapRoundUp(Value, Unit_: PtrUInt): PtrUInt;
begin
  PageHeapRoundUp := (Value + Unit_ - 1) and not (Unit_ - 1);
end;

function PageHeapHeaderOf(Block: Pointer): PPageHeapHeader;
begin
  PageHeapHeaderOf := PPageHeapHeader(Block) - 1;
end;

{ The reservation a block lies in: its header is always on its first
  page. }
function PageHeapBaseOf(Block: Pointer): Pointer;
begin
  PageHeapBaseOf := Pointer(PtrUInt(PageHeapHeaderOf(Block)) and not PtrUInt(PageHeapPageSize - 1));
end;

{ The pages holding the header and Size bytes. }
function PageHeapDataBytes(Size: PtrUInt): PtrUInt;
begin
  PageHeapDataBytes := PageHeapRoundUp(SizeOf(TPageHeapHeader) + PageHeapRoundUp(Size, PageHeapAlignment),
    PageHeapPageSize);
end;

{ True if the header of Block is on a committed page (it may be read). }
function PageHeapHeaderIsCommitted(Block: Pointer): Boolean;
var
  Information: TAbiMemoryInformation;
begin
  PageHeapHeaderIsCommitted := (SystemCall(CallQueryMemory, QWord(PageHeapHeaderOf(Block)),
    QWord(@Information), 0, 0, 0, 0) >= 0) and (Information.State = MemoryStateCommitted) and
    ((Information.Protection and MemoryWrite) <> 0);
end;

function PageHeapAllocate(Size: PtrUInt): Pointer;
var
  DataBytes: PtrUInt;
  Base: Int64;
  Block: PByte;
  Header: PPageHeapHeader;
begin
  PageHeapAllocate := nil;
  if Size > PageHeapLargestRequest then
    HandleError(203);
  DataBytes := PageHeapDataBytes(Size);
  { The data pages, then the page that stays reserved. }
  Base := SystemCall(CallReserveMemory, DataBytes + PageHeapPageSize, 0, 0, 0, 0, 0);
  if Base <= 0 then
    Exit;
  if SystemCall(CallCommitMemory, QWord(Base), DataBytes, MemoryReadWrite, 0, 0, 0) < 0 then
  begin
    SystemCall(CallFreeMemory, QWord(Base), 0, 0, 0, 0, 0);
    Exit;
  end;
  Block := PByte(Base) + DataBytes - PageHeapRoundUp(Size, PageHeapAlignment);
  Header := PageHeapHeaderOf(Block);
  Header^.Magic := PageHeapMagic;
  Header^.RequestedSize := Size;
  FillChar(Block[Size], PageHeapRoundUp(Size, PageHeapAlignment) - Size, PageHeapSlackFill);
  PageHeapAllocate := Block;
end;

{ Stops the program unless Block is a live page heap block. }
procedure PageHeapCheckBlock(Block: Pointer; Problem: PChar);
begin
  if ((PtrUInt(Block) and (PageHeapAlignment - 1)) <> 0) or not PageHeapHeaderIsCommitted(Block) or
     (PageHeapHeaderOf(Block)^.Magic <> PageHeapMagic) then
    ReportBadHeapPointer(Problem, Block, 0, NoFreedByPages);
end;

function PageHeapFreeMem(Block: Pointer): PtrUInt;
var
  Header: PPageHeapHeader;
  Size: PtrUInt;
  Offset: PtrUInt;
  Base: Pointer;
  Leaving: Pointer;
begin
  if Block = nil then
    Exit(0);
  PageHeapCheckBlock(Block, 'freeing a pointer that is not an allocated heap block (freed before, or a stray pointer)');
  Header := PageHeapHeaderOf(Block);
  Size := Header^.RequestedSize;
  PageHeapFreeMem := Size;
  { Writes past the end that stayed within the alignment's slack. }
  Offset := Size;
  while (Offset < PageHeapRoundUp(Size, PageHeapAlignment)) and (PByte(Block)[Offset] = PageHeapSlackFill) do
    Inc(Offset);
  if Offset < PageHeapRoundUp(Size, PageHeapAlignment) then
    ReportDamagedHeapBlock('memory was written past the end of a block', Block, Size, Offset,
      PByte(Block)[Offset], PageHeapSlackFill, NoFreedByPages);
  Header^.Magic := 0;

  Base := PageHeapBaseOf(Block);
  SystemCall(CallDecommitMemory, QWord(Base), PageHeapDataBytes(Size), 0, 0, 0, 0);
  AcquireWordLock(PageHeapLock);
  Leaving := PageHeapQuarantine[PageHeapQuarantineNext];
  PageHeapQuarantine[PageHeapQuarantineNext] := Base;
  PageHeapQuarantineNext := (PageHeapQuarantineNext + 1) mod PageHeapQuarantineCount;
  ReleaseWordLock(PageHeapLock);
  if Leaving <> nil then
    SystemCall(CallFreeMemory, QWord(Leaving), 0, 0, 0, 0, 0);
end;

function PageHeapGetMem(Size: PtrUInt): Pointer;
begin
  PageHeapGetMem := PageHeapAllocate(Size);
  if PageHeapGetMem <> nil then
    FillChar(PageHeapGetMem^, Size, PageHeapAllocationFill);
end;

function PageHeapAllocMem(Size: PtrUInt): Pointer;
begin
  { Freshly committed pages are zero. }
  PageHeapAllocMem := PageHeapAllocate(Size);
end;

function PageHeapFreeMemSize(Block: Pointer; Size: PtrUInt): PtrUInt;
begin
  PageHeapFreeMemSize := PageHeapFreeMem(Block);
end;

function PageHeapMemSize(Block: Pointer): PtrUInt;
begin
  PageHeapCheckBlock(Block, 'asking the size of a pointer that is not an allocated heap block');
  PageHeapMemSize := PageHeapHeaderOf(Block)^.RequestedSize;
end;

{ Always moves, so a pointer kept into the old block faults. }
function PageHeapReAllocMem(var Block: Pointer; Size: PtrUInt): Pointer;
var
  Moved: Pointer;
  OldSize: PtrUInt;
begin
  if Size = 0 then
  begin
    if Block <> nil then
      PageHeapFreeMem(Block);
    Block := nil;
    Exit(nil);
  end;
  if Block = nil then
  begin
    Block := PageHeapGetMem(Size);
    Exit(Block);
  end;
  PageHeapCheckBlock(Block, 'resizing a pointer that is not an allocated heap block');
  OldSize := PageHeapHeaderOf(Block)^.RequestedSize;
  Moved := PageHeapAllocate(Size);
  if Moved = nil then
    Exit(nil);
  if OldSize < Size then
  begin
    Move(Block^, Moved^, OldSize);
    FillChar(PByte(Moved)[OldSize], Size - OldSize, PageHeapAllocationFill);
  end
  else
    Move(Block^, Moved^, Size);
  PageHeapFreeMem(Block);
  Block := Moved;
  PageHeapReAllocMem := Moved;
end;

const
  PageHeapMemoryManager: TMemoryManager = (
    NeedLock: False;
    GetMem: @PageHeapGetMem;
    FreeMem: @PageHeapFreeMem;
    FreeMemSize: @PageHeapFreeMemSize;
    AllocMem: @PageHeapAllocMem;
    ReAllocMem: @PageHeapReAllocMem;
    MemSize: @PageHeapMemSize;
    InitThread: nil;
    DoneThread: nil;
    RelocateHeap: nil;
    GetHeapStatus: @SysGetHeapStatus;
    GetFPCHeapStatus: @SysGetFPCHeapStatus;
  );
