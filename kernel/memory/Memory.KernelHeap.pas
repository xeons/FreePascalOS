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

  The allocator may be called at or below DispatchLevel.
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

procedure WriteKernelHeapSummary;

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.VirtualRanges,
  Memory.PageMapping,
  Memory.Arch.PageTables,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output;

const
  SizeClassCount = 7;
  SizeClassBytes: array[0..SizeClassCount - 1] of QWord = (32, 64, 128, 256, 512, 1024, 2048);
  LargestSmallBlock = 2048;

  HeaderMagicSmallAllocated = LongWord($AB5A110C);
  HeaderMagicLargeAllocated = LongWord($AB1A110C);
  HeaderMagicFree = LongWord($AB0FF4EE);

type
  { Exactly 16 bytes so that the memory after it stays 16-byte aligned. }
  TBlockHeader = record
    Magic: LongWord;
    SizeClass: LongWord;
    { For large blocks: number of mapped pages. For free small blocks:
      the next free block in the same class. }
    case Boolean of
      False: (PageCount: QWord);
      True: (NextFree: Pointer);
  end;
  PBlockHeader = ^TBlockHeader;

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

procedure InitializeKernelHeap;
var
  ClassIndex: Integer;
begin
  InitializeSpinLock(HeapLock);
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
    Block^.Magic := HeaderMagicFree;
    Block^.SizeClass := LongWord(ClassIndex);
    Block^.NextFree := SizeClasses[ClassIndex].FreeList;
    SizeClasses[ClassIndex].FreeList := Block;
    Offset := Offset + BlockSize;
  end;

  Inc(SizeClasses[ClassIndex].PagesOwned);
  Result := True;
end;

function AllocateSmallBlock(ClassIndex: Integer): Pointer;
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

  Block^.Magic := HeaderMagicSmallAllocated;
  Block^.PageCount := 0;

  ReleaseSpinLock(HeapLock, PreviousLevel);
  Result := Pointer(Block + 1);
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

  Result := Pointer(Block + 1);
end;

function AllocateKernelMemory(ByteCount: QWord): Pointer;
var
  TotalBytes: QWord;
  ClassIndex: Integer;
begin
  if ByteCount = 0 then
    Exit(nil);

  TotalBytes := ByteCount + SizeOf(TBlockHeader);
  if TotalBytes <= LargestSmallBlock then
  begin
    ClassIndex := SizeClassFor(TotalBytes);
    Result := AllocateSmallBlock(ClassIndex);
  end
  else
    Result := AllocateLargeBlock(TotalBytes);
end;

function AllocateZeroedKernelMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocateKernelMemory(ByteCount);
  if Result <> nil then
    ZeroMemory(Result, ByteCount);
end;

procedure FreeSmallBlock(Block: PBlockHeader);
var
  PreviousLevel: TPriorityLevel;
  ClassIndex: LongWord;
begin
  ClassIndex := Block^.SizeClass;
  if ClassIndex >= SizeClassCount then
    KernelPanicWithCode(PanicHeapCorruption, 'kernel heap block has an invalid size class',
      QWord(Block), ClassIndex, 0, 0);

  PreviousLevel := AcquireSpinLock(HeapLock);
  Block^.Magic := HeaderMagicFree;
  Block^.NextFree := SizeClasses[ClassIndex].FreeList;
  SizeClasses[ClassIndex].FreeList := Block;
  Dec(SizeClasses[ClassIndex].BlocksInUse);
  ReleaseSpinLock(HeapLock, PreviousLevel);
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
  FreeVirtualRange(StartAddress, PageCount);
end;

procedure FreeKernelMemory(Block: Pointer);
var
  Header: PBlockHeader;
begin
  if Block = nil then
    Exit;

  Header := PBlockHeader(Block) - 1;
  case Header^.Magic of
    HeaderMagicSmallAllocated:
      FreeSmallBlock(Header);
    HeaderMagicLargeAllocated:
      FreeLargeBlock(Header);
    HeaderMagicFree:
      KernelPanicWithCode(PanicHeapCorruption, 'kernel memory freed twice',
        QWord(Block), 0, 0, 0);
  else
    KernelPanicWithCode(PanicHeapCorruption,
      'freeing a pointer that did not come from the kernel heap',
      QWord(Block), Header^.Magic, 0, 0);
  end;
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
  DebugEndMessage;
end;

end.
