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
  The heap checks of the kernel heap (see Memory.HeapChecks for what
  they are for and how they are switched on).

  A small block goes through these states:

    free         on its class's free list, holding HeapFreeFill; checked
                 when it is handed out (CheckFreeBlockBeforeReuse)
    allocated    the requested bytes hold HeapAllocationFill until the
                 owner writes them, the rest of the block HeapGuardFill;
                 the guard is checked when it is freed
    quarantined  filled with HeapFreeFill again and waiting in the
                 quarantine; its fill is checked when it leaves

  Freeing a block that is free or quarantined is a double free; the
  quarantine remembers who freed each block, so the report names both.

  The quarantines have their own lock, taken without the heap lock held;
  blocks leaving the quarantine are handed back to the allocator as a
  chain, which puts them on its free lists.
}
unit Memory.KernelHeapChecks;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.KernelHeapBlocks;

procedure InitializeKernelHeapQuarantine;

{ A block carved from a fresh page: it holds the free fill from now on. }
procedure FillNewFreeBlock(Block: PBlockHeader);
{ A free block about to be handed out must still hold the free fill. }
procedure CheckFreeBlockBeforeReuse(Block: PBlockHeader);
{ Fills a block just handed out (its RequestedBytes set). }
procedure FillNewSmallBlock(Block: PBlockHeader);

{ Checks the guard of a block being freed and fills it with the free
  fill; with the quarantine it is marked quarantined. }
procedure PrepareFreedSmallBlock(Block: PBlockHeader; Caller: QWord);
{ Puts a freed small block into the quarantine. Returns the blocks that
  had to leave it to make room, checked, as a chain through NextFree
  (nil if none). }
function QuarantineSmallBlock(Block: PBlockHeader; Caller: QWord): PBlockHeader;
{ Keeps the address range of a freed large block from reuse for a while
  (its pages are already gone). }
procedure QuarantineAddressRange(StartAddress, PageCount: QWord);
{ Empties both quarantines: frees the address ranges and returns the
  small blocks, checked, as a chain. }
function ReleaseWholeQuarantine: PBlockHeader;

procedure ReportDoubleFree(Block: Pointer; Magic: LongWord; Caller: QWord); noreturn;

procedure WriteKernelHeapQuarantineSummary;

{ For the heap check self test (Kernel.HeapCheckTest). True if the small
  block Block is waiting in the quarantine. }
function KernelHeapBlockIsQuarantined(Block: Pointer): Boolean;
{ True if a heap check would find the small block Block damaged: the
  guard of an allocated block or the fill of a quarantined one changed.
  Offset is the first changed byte, from the start of the block. }
function FindKernelHeapDamage(Block: Pointer; out Offset: QWord): Boolean;

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.VirtualRanges,
  Memory.HeapChecks,
  Memory.HeapQuarantine,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Debug.Output;

const
  { Small blocks are at most 2 KiB, so the byte limit is what usually
    bounds the quarantine: freed memory is reused after about half a
    megabyte more has been freed. }
  QuarantinedBlockLimit = 1024;
  QuarantinedByteLimit = 512 * 1024;
  { Address ranges cost no memory, only address space (of the 1 TiB
    dynamic region). }
  QuarantinedRangeLimit = 256;
  QuarantinedAddressSpaceLimit = QWord(4) * 1024 * 1024 * 1024;

var
  QuarantinedBlocks: TQuarantine;
  QuarantinedRanges: TQuarantine;
  QuarantineLock: TSpinLock;

procedure InitializeKernelHeapQuarantine;
begin
  InitializeSpinLock(QuarantineLock);
  InitializeQuarantine(QuarantinedBlocks, QuarantinedBlockLimit, QuarantinedByteLimit);
  InitializeQuarantine(QuarantinedRanges, QuarantinedRangeLimit, QuarantinedAddressSpaceLimit);
end;

procedure FillNewFreeBlock(Block: PBlockHeader);
begin
  FillMemory(BlockData(Block), UsableBytesOfClass(Block^.SizeClass), HeapFreeFill);
end;

procedure CheckFreeBlockBeforeReuse(Block: PBlockHeader);
var
  UsableBytes: QWord;
  Offset: QWord;
begin
  UsableBytes := UsableBytesOfClass(Block^.SizeClass);
  Offset := FindByteNotEqual(BlockData(Block), UsableBytes, HeapFreeFill);
  if Offset < UsableBytes then
    ReportDamagedBlock('kernel heap: memory was written after it was freed (found when it was reused)',
      BlockData(Block), UsableBytes, Offset, BlockData(Block)[Offset], HeapFreeFill, 0);
end;

procedure FillNewSmallBlock(Block: PBlockHeader);
var
  UsableBytes: QWord;
  RequestedBytes: QWord;
begin
  UsableBytes := UsableBytesOfClass(Block^.SizeClass);
  RequestedBytes := Block^.RequestedBytes;
  FillMemory(BlockData(Block), RequestedBytes, HeapAllocationFill);
  FillMemory(BlockData(Block) + RequestedBytes, UsableBytes - RequestedBytes, HeapGuardFill);
end;

{ Offset (from the block's start) of the first changed byte of the
  guard after the requested bytes; the usable size if it is intact. }
function FindDamagedGuard(Block: PBlockHeader): QWord;
var
  UsableBytes: QWord;
  RequestedBytes: QWord;
begin
  UsableBytes := UsableBytesOfClass(Block^.SizeClass);
  RequestedBytes := Block^.RequestedBytes;
  Result := RequestedBytes + FindByteNotEqual(BlockData(Block) + RequestedBytes,
    UsableBytes - RequestedBytes, HeapGuardFill);
end;

procedure PrepareFreedSmallBlock(Block: PBlockHeader; Caller: QWord);
var
  UsableBytes: QWord;
  GuardOffset: QWord;
begin
  UsableBytes := UsableBytesOfClass(Block^.SizeClass);
  if Block^.RequestedBytes > UsableBytes then
    ReportBadFree('kernel heap: the header of a block was overwritten', BlockData(Block),
      Block^.Magic, Caller, 0);
  GuardOffset := FindDamagedGuard(Block);
  if GuardOffset < UsableBytes then
    ReportDamagedBlock('kernel heap: memory was written past the end of a block',
      BlockData(Block), Block^.RequestedBytes, GuardOffset, BlockData(Block)[GuardOffset],
      HeapGuardFill, Caller);

  FillMemory(BlockData(Block), UsableBytes, HeapFreeFill);
  if KernelHeapCheckLevel = HeapChecksQuarantine then
    Block^.Magic := HeaderMagicQuarantined;
end;

{ A block leaving the quarantine must have an intact header and still
  hold the free fill. }
procedure CheckLeavingBlock(const Entry: TQuarantineEntry);
var
  Block: PBlockHeader;
  Offset: QWord;
begin
  Block := BlockOfData(Entry.Block);
  if (Block^.Magic <> HeaderMagicQuarantined) or (Block^.SizeClass >= SizeClassCount) then
    ReportBadFree('kernel heap: the header of a freed block was overwritten while it was in the quarantine',
      Entry.Block, Block^.Magic, 0, Entry.FreedBy);
  Offset := FindByteNotEqual(Entry.Block, Entry.ByteCount, HeapFreeFill);
  if Offset < Entry.ByteCount then
    ReportDamagedBlock('kernel heap: memory was written after it was freed',
      Entry.Block, Entry.ByteCount, Offset, PByte(Entry.Block)[Offset], HeapFreeFill, Entry.FreedBy);
end;

{ Takes the oldest block out, checked, and adds it to Chain. Called
  with the quarantine lock held. }
procedure ReleaseOldestBlock(var Chain: PBlockHeader);
var
  Entry: TQuarantineEntry;
  Block: PBlockHeader;
begin
  if not TakeOldestFromQuarantine(QuarantinedBlocks, Entry) then
    Exit;
  CheckLeavingBlock(Entry);
  Block := BlockOfData(Entry.Block);
  Block^.NextFree := Chain;
  Chain := Block;
end;

function QuarantineSmallBlock(Block: PBlockHeader; Caller: QWord): PBlockHeader;
var
  PreviousLevel: TPriorityLevel;
  Entry: TQuarantineEntry;
begin
  Result := nil;
  Entry.Block := BlockData(Block);
  Entry.ByteCount := UsableBytesOfClass(Block^.SizeClass);
  Entry.FreedBy := Caller;

  PreviousLevel := AcquireSpinLock(QuarantineLock);
  while QuarantineIsFullFor(QuarantinedBlocks, Entry.ByteCount) do
    ReleaseOldestBlock(Result);
  AddToQuarantine(QuarantinedBlocks, Entry);
  ReleaseSpinLock(QuarantineLock, PreviousLevel);
end;

procedure QuarantineAddressRange(StartAddress, PageCount: QWord);
var
  PreviousLevel: TPriorityLevel;
  Entry: TQuarantineEntry;
  Oldest: TQuarantineEntry;
begin
  Entry.Block := Pointer(StartAddress);
  Entry.ByteCount := PageCount * PageSize;
  Entry.FreedBy := 0;

  PreviousLevel := AcquireSpinLock(QuarantineLock);
  while QuarantineIsFullFor(QuarantinedRanges, Entry.ByteCount) do
  begin
    TakeOldestFromQuarantine(QuarantinedRanges, Oldest);
    FreeVirtualRange(QWord(Oldest.Block), Oldest.ByteCount div PageSize);
  end;
  AddToQuarantine(QuarantinedRanges, Entry);
  ReleaseSpinLock(QuarantineLock, PreviousLevel);
end;

function ReleaseWholeQuarantine: PBlockHeader;
var
  PreviousLevel: TPriorityLevel;
  Entry: TQuarantineEntry;
begin
  Result := nil;
  PreviousLevel := AcquireSpinLock(QuarantineLock);
  while QuarantinedBlocks.Count > 0 do
    ReleaseOldestBlock(Result);
  while TakeOldestFromQuarantine(QuarantinedRanges, Entry) do
    FreeVirtualRange(QWord(Entry.Block), Entry.ByteCount div PageSize);
  ReleaseSpinLock(QuarantineLock, PreviousLevel);
end;

procedure ReportDoubleFree(Block: Pointer; Magic: LongWord; Caller: QWord);
var
  PreviousLevel: TPriorityLevel;
  Entry: TQuarantineEntry;
begin
  PreviousLevel := AcquireSpinLock(QuarantineLock);
  FindInQuarantine(QuarantinedBlocks, Block, Entry);
  ReleaseSpinLock(QuarantineLock, PreviousLevel);
  ReportBadFree('kernel memory freed twice', Block, Magic, Caller, Entry.FreedBy);
end;

procedure WriteKernelHeapQuarantineSummary;
begin
  DebugWriteTag('heap');
  DebugWriteDecimal(QuarantinedBlocks.Count);
  DebugWrite(' freed blocks (');
  DebugWriteDecimal(QuarantinedBlocks.Bytes);
  DebugWrite(' bytes) and ');
  DebugWriteDecimal(QuarantinedRanges.Count);
  DebugWriteLine(' address ranges in the heap check quarantine');
end;

function KernelHeapBlockIsQuarantined(Block: Pointer): Boolean;
begin
  Result := BlockOfData(Block)^.Magic = HeaderMagicQuarantined;
end;

function FindKernelHeapDamage(Block: Pointer; out Offset: QWord): Boolean;
var
  Header: PBlockHeader;
  UsableBytes: QWord;
begin
  Header := BlockOfData(Block);
  UsableBytes := UsableBytesOfClass(Header^.SizeClass);
  if Header^.Magic = HeaderMagicQuarantined then
    Offset := FindByteNotEqual(Block, UsableBytes, HeapFreeFill)
  else
    Offset := FindDamagedGuard(Header);
  Result := Offset < UsableBytes;
end;

end.
