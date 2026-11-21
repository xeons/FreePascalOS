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
  General purpose kernel memory allocator.

  Small requests are served from size classes (32 bytes up to 2 KiB).
  Each class carves whole physical pages into equal blocks and keeps the
  free blocks on a list. These pages are used through the physical memory
  window, so small allocations never touch the page tables.

  Larger requests get their own run of pages in the kernel dynamic region,
  mapped page by page, so they do not need physically contiguous memory.

  Every block starts with a 16-byte header recording how it was allocated,
  which lets FreeKernelMemory work with nothing but the pointer and catch
  double frees and stray pointers.

  With the kernel option "heapchecks" (Memory.HeapChecks) blocks are
  filled when they are allocated and when they are freed, small blocks
  carry a guard after the requested bytes, and freed small blocks wait
  in a quarantine before they are reused (Memory.KernelHeapChecks). A
  large block's pages are unmapped when it is freed, so a stale pointer
  faults; with the quarantine its address range waits too, so that
  nothing is mapped there again soon.

  The allocator may be called at or below DispatchLevel. When memory
  runs out, an allocation that may wait (at passive level, interrupts
  on) asks the reclaimer (Memory.Pressure sets it: the caches shrink)
  and tries once more; otherwise, and if that fails too, it returns nil
  and the caller copes.
}
unit Memory.KernelHeap;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeKernelHeap;

{ Returns 16-byte aligned memory, or nil if memory ran out. }
function AllocateKernelMemory(ByteCount: QWord): Pointer;
function AllocateZeroedKernelMemory(ByteCount: QWord): Pointer;
procedure FreeKernelMemory(Block: Pointer);

{ Checks and releases every block and address range waiting in the heap
  check quarantine, so that a measurement sees nothing held back. }
procedure FlushKernelHeapQuarantine;

procedure WriteKernelHeapSummary;

type
  { Frees memory for an allocation of PageCount pages that failed;
    returns False where it cannot (wrong level, nothing to free). }
  TKernelHeapReclaimer = function(PageCount: QWord): Boolean;

procedure SetKernelHeapReclaimer(Reclaimer: TKernelHeapReclaimer);

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.VirtualRanges,
  Memory.PageMapping,
  Memory.Arch.PageTables,
  Memory.HeapChecks,
  Memory.KernelHeapBlocks,
  Memory.KernelHeapChecks,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output;

type
  TSizeClass = record
    FreeList: PBlockHeader;
    BlocksInUse: QWord;
    PagesOwned: QWord;
  end;

var
  SizeClasses: array[0..SizeClassCount - 1] of TSizeClass;
  HeapLock: TSpinLock;
  LargeAllocationCount: QWord;
  LargeAllocationPages: QWord;
  HeapReclaimer: TKernelHeapReclaimer;

procedure WriteHeapCheckLevel;
begin
  DebugBeginMessage;
  DebugWriteTag('heap');
  DebugWrite('heap checks: ');
  DebugWriteLine(HeapCheckLevelName(KernelHeapCheckLevel));
  DebugEndMessage;
end;

procedure InitializeKernelHeap;
var
  ClassIndex: Integer;
begin
  InitializeSpinLock(HeapLock);
  { Decided before the first allocation, so that every block is handled
    the same way from allocation to free. }
  InitializeHeapChecks;
  InitializeKernelHeapQuarantine;
  if KernelHeapCheckLevel <> HeapChecksOff then
    WriteHeapCheckLevel;
  for ClassIndex := 0 to SizeClassCount - 1 do
  begin
    SizeClasses[ClassIndex].FreeList := nil;
    SizeClasses[ClassIndex].BlocksInUse := 0;
    SizeClasses[ClassIndex].PagesOwned := 0;
  end;
  LargeAllocationCount := 0;
  LargeAllocationPages := 0;
end;

function SizeClassFor(TotalBytes: QWord): Integer;
var
  ClassIndex: Integer;
begin
  for ClassIndex := 0 to SizeClassCount - 1 do
  begin
    if TotalBytes <= SizeClassBytes[ClassIndex] then
      Exit(ClassIndex);
  end;
  Result := -1;
end;

{ Puts a small block on its class's free list. Called with the heap
  lock held. }
procedure PushFreeSmallBlock(Block: PBlockHeader);
var
  ClassIndex: LongWord;
begin
  ClassIndex := Block^.SizeClass;
  Block^.Magic := HeaderMagicFree;
  Block^.NextFree := SizeClasses[ClassIndex].FreeList;
  SizeClasses[ClassIndex].FreeList := Block;
end;

{ Splits a fresh page into blocks for the class. Called with the heap
  lock held. }
function RefillSizeClass(ClassIndex: Integer): Boolean;
var
  PagePhysical: QWord;
  PageStart: PByte;
  BlockSize: QWord;
  Offset: QWord;
  Block: PBlockHeader;
begin
  PagePhysical := AllocatePhysicalPage(PageUsageKernelHeap);
  if PagePhysical = 0 then
    Exit(False);

  PageStart := PByte(PhysicalToVirtual(PagePhysical));
  BlockSize := SizeClassBytes[ClassIndex];
  Offset := 0;
  while Offset + BlockSize <= PageSize do
  begin
    Block := PBlockHeader(PageStart + Offset);
    Block^.SizeClass := LongWord(ClassIndex);
    if KernelHeapCheckLevel <> HeapChecksOff then
      FillNewFreeBlock(Block);
    PushFreeSmallBlock(Block);
    Offset := Offset + BlockSize;
  end;

  Inc(SizeClasses[ClassIndex].PagesOwned);
  Result := True;
end;

function AllocateSmallBlock(ClassIndex: Integer; ByteCount: QWord): Pointer;
var
  PreviousLevel: TPriorityLevel;
  Block: PBlockHeader;
begin
  PreviousLevel := AcquireSpinLock(HeapLock);

  if SizeClasses[ClassIndex].FreeList = nil then
  begin
    if not RefillSizeClass(ClassIndex) then
    begin
      ReleaseSpinLock(HeapLock, PreviousLevel);
      Exit(nil);
    end;
  end;

  Block := SizeClasses[ClassIndex].FreeList;
  if Block^.Magic <> HeaderMagicFree then
    KernelPanicWithCode(PanicHeapCorruption, 'kernel heap free list is corrupted',
      QWord(Block), Block^.Magic, QWord(ClassIndex), 0);

  SizeClasses[ClassIndex].FreeList := Block^.NextFree;
  Inc(SizeClasses[ClassIndex].BlocksInUse);

  if KernelHeapCheckLevel <> HeapChecksOff then
    CheckFreeBlockBeforeReuse(Block);
  Block^.Magic := HeaderMagicSmallAllocated;
  Block^.RequestedBytes := ByteCount;

  ReleaseSpinLock(HeapLock, PreviousLevel);
  if KernelHeapCheckLevel <> HeapChecksOff then
    FillNewSmallBlock(Block);
  Result := BlockData(Block);
end;

{ Allocates PageCount pages of virtual space backed by physical pages.
  Returns zero on failure. }
function AllocateMappedPages(PageCount: QWord; Usage: TPageUsage): QWord;
var
  StartAddress: QWord;
begin
  StartAddress := AllocateVirtualRange(PageCount);
  if StartAddress = 0 then
    Exit(0);

  if not MapNewPages(StartAddress, PageCount, Usage, MappingWritable) then
  begin
    FreeVirtualRange(StartAddress, PageCount);
    Exit(0);
  end;

  Result := StartAddress;
end;

function AllocateLargeBlock(TotalBytes: QWord): Pointer;
var
  PageCount: QWord;
  StartAddress: QWord;
  Block: PBlockHeader;
  PreviousLevel: TPriorityLevel;
begin
  PageCount := PagesForBytes(TotalBytes);
  StartAddress := AllocateMappedPages(PageCount, PageUsageKernelHeap);
  if StartAddress = 0 then
    Exit(nil);

  Block := PBlockHeader(StartAddress);
  Block^.Magic := HeaderMagicLargeAllocated;
  Block^.SizeClass := 0;
  Block^.PageCount := PageCount;

  PreviousLevel := AcquireSpinLock(HeapLock);
  Inc(LargeAllocationCount);
  LargeAllocationPages := LargeAllocationPages + PageCount;
  ReleaseSpinLock(HeapLock, PreviousLevel);

  { The pages come zeroed; with heap checks they hold junk instead, as
    small blocks do. }
  if KernelHeapCheckLevel <> HeapChecksOff then
    FillMemory(BlockData(Block), PageCount * PageSize - SizeOf(TBlockHeader), HeapAllocationFill);

  Result := BlockData(Block);
end;

procedure SetKernelHeapReclaimer(Reclaimer: TKernelHeapReclaimer);
begin
  HeapReclaimer := Reclaimer;
end;

function TryAllocate(ByteCount, TotalBytes: QWord): Pointer;
begin
  if TotalBytes <= LargestSmallBlock then
    Result := AllocateSmallBlock(SizeClassFor(TotalBytes), ByteCount)
  else
    Result := AllocateLargeBlock(TotalBytes);
end;

function AllocateKernelMemory(ByteCount: QWord): Pointer;
var
  TotalBytes: QWord;
  Reclaimer: TKernelHeapReclaimer;
begin
  if ByteCount = 0 then
    Exit(nil);

  TotalBytes := ByteCount + SizeOf(TBlockHeader);
  Result := TryAllocate(ByteCount, TotalBytes);
  if Result <> nil then
    Exit;
  Reclaimer := HeapReclaimer;
  if Assigned(Reclaimer) and Reclaimer(PagesForBytes(TotalBytes) + 1) then
    Result := TryAllocate(ByteCount, TotalBytes);
end;

function AllocateZeroedKernelMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocateKernelMemory(ByteCount);
  if Result <> nil then
    ZeroMemory(Result, ByteCount);
end;

procedure CheckSizeClass(Block: PBlockHeader);
begin
  if Block^.SizeClass >= SizeClassCount then
    KernelPanicWithCode(PanicHeapCorruption, 'kernel heap block has an invalid size class',
      QWord(Block), Block^.SizeClass, 0, 0);
end;

{ Puts a chain of blocks (linked through NextFree) back on their free
  lists. }
procedure PushFreeSmallBlocks(Chain: PBlockHeader);
var
  PreviousLevel: TPriorityLevel;
  Next: PBlockHeader;
begin
  if Chain = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(HeapLock);
  while Chain <> nil do
  begin
    Next := Chain^.NextFree;
    PushFreeSmallBlock(Chain);
    Chain := Next;
  end;
  ReleaseSpinLock(HeapLock, PreviousLevel);
end;

procedure FreeSmallBlock(Block: PBlockHeader; Caller: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  CheckSizeClass(Block);
  if KernelHeapCheckLevel <> HeapChecksOff then
    PrepareFreedSmallBlock(Block, Caller);

  PreviousLevel := AcquireSpinLock(HeapLock);
  Dec(SizeClasses[Block^.SizeClass].BlocksInUse);
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
    PushFreeSmallBlock(Block);
  ReleaseSpinLock(HeapLock, PreviousLevel);

  { With the quarantine the block waits, and the oldest waiting blocks
    are reused instead. }
  if KernelHeapCheckLevel = HeapChecksQuarantine then
    PushFreeSmallBlocks(QuarantineSmallBlock(Block, Caller));
end;

procedure FreeLargeBlock(Block: PBlockHeader);
var
  PreviousLevel: TPriorityLevel;
  StartAddress: QWord;
  PageCount: QWord;
begin
  StartAddress := QWord(Block);
  PageCount := Block^.PageCount;
  Block^.Magic := HeaderMagicFree;

  PreviousLevel := AcquireSpinLock(HeapLock);
  Dec(LargeAllocationCount);
  LargeAllocationPages := LargeAllocationPages - PageCount;
  ReleaseSpinLock(HeapLock, PreviousLevel);

  UnmapAndFreePages(StartAddress, PageCount);
  if KernelHeapCheckLevel = HeapChecksQuarantine then
    QuarantineAddressRange(StartAddress, PageCount)
  else
    FreeVirtualRange(StartAddress, PageCount);
end;

{ Built with a frame (rbp chain) so that it can find its return
  address. }
{$push}
{$stackframes on}
procedure FreeKernelMemory(Block: Pointer);
var
  Header: PBlockHeader;
  Caller: QWord;
begin
  if Block = nil then
    Exit;

  { The return address in this procedure's frame: who freed the block,
    for the heap check reports. }
  Caller := PQWord(ReadFramePointer + SizeOf(QWord))^;
  Header := PBlockHeader(Block) - 1;
  case Header^.Magic of
    HeaderMagicSmallAllocated:
      FreeSmallBlock(Header, Caller);
    HeaderMagicLargeAllocated:
      FreeLargeBlock(Header);
    HeaderMagicFree, HeaderMagicQuarantined:
      ReportDoubleFree(Block, Header^.Magic, Caller);
  else
    ReportBadFree('freeing a pointer that did not come from the kernel heap',
      Block, Header^.Magic, Caller, 0);
  end;
end;
{$pop}

procedure FlushKernelHeapQuarantine;
begin
  PushFreeSmallBlocks(ReleaseWholeQuarantine);
end;

procedure WriteKernelHeapSummary;
var
  ClassIndex: Integer;
  SmallPages: QWord;
  SmallBlocks: QWord;
begin
  SmallPages := 0;
  SmallBlocks := 0;
  for ClassIndex := 0 to SizeClassCount - 1 do
  begin
    SmallPages := SmallPages + SizeClasses[ClassIndex].PagesOwned;
    SmallBlocks := SmallBlocks + SizeClasses[ClassIndex].BlocksInUse;
  end;

  DebugBeginMessage;
  DebugWriteTag('heap');
  DebugWriteDecimal(SmallBlocks);
  DebugWrite(' small blocks in ');
  DebugWriteDecimal(SmallPages);
  DebugWrite(' pages, ');
  DebugWriteDecimal(LargeAllocationCount);
  DebugWrite(' large allocations in ');
  DebugWriteDecimal(LargeAllocationPages);
  DebugWriteLine(' pages');
  if KernelHeapCheckLevel = HeapChecksQuarantine then
    WriteKernelHeapQuarantineSummary;
  DebugEndMessage;
end;

end.
