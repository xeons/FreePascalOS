{
  Physical page allocator built on a page frame database.

  The page frame database is an array with one small record per physical
  page, indexed by page frame number (physical address div PageSize). It
  records what each page is used for, and free pages are chained through
  it into a single free list, so allocating and freeing a page are both
  constant time operations.

  The database itself is placed in the first usable memory region large
  enough to hold it, and is reached through the physical memory window.
}
unit Memory.PhysicalPages;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information,
  Memory.Layout;

type
  TPageUsage = (
    PageUsageFree,
    PageUsageReserved,      { firmware, devices, or otherwise not RAM we own }
    PageUsageKernelImage,
    PageUsageBootData,      { loader data still needed by the kernel }
    PageUsagePageTable,
    PageUsageFrameDatabase,
    PageUsageKernelHeap,
    PageUsageKernelStack,
    PageUsageGeneral
  );

  TPhysicalMemoryStatistics = record
    TotalUsablePages: QWord;
    FreePages: QWord;
    HighestPageFrameNumber: QWord;
  end;

procedure InitializePhysicalMemory(const BootInformation: TBootInformation);

{ Returns the physical address of a free page, or zero if none is left. }
function AllocatePhysicalPage(Usage: TPageUsage): TPhysicalAddress;

{ Like AllocatePhysicalPage, but the page is filled with zeros. }
function AllocateZeroedPhysicalPage(Usage: TPageUsage): TPhysicalAddress;

procedure FreePhysicalPage(PhysicalAddress: TPhysicalAddress);

function PageUsageOf(PhysicalAddress: TPhysicalAddress): TPageUsage;

{ Takes PageCount consecutive pages of RAM below 1 MiB (never handed out
  otherwise; secondary processors start in such a page). Returns the
  physical address of the first, or 0 if there is no such run. }
function ClaimLowPhysicalPages(PageCount: QWord): TPhysicalAddress;

procedure GetPhysicalMemoryStatistics(out Statistics: TPhysicalMemoryStatistics);

procedure WritePhysicalMemorySummary;

implementation

uses
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output;

const
  NoNextFrame = High(QWord);

  { Memory below 1 MiB is never handed out. It is where firmware tables
    live on PCs and where secondary processors start executing. }
  LowestAllocatableAddress = QWord($100000);
  LowFrameCount = LowestAllocatableAddress shr PageShift;

type
  TPageFrame = record
    NextFreeFrame: QWord;
    Usage: TPageUsage;
  end;
  PPageFrame = ^TPageFrame;

var
  FrameDatabase: PPageFrame;
  FrameCount: QWord;
  FreeListHead: QWord;
  FreePageCount: QWord;
  UsablePageCount: QWord;
  DatabaseLock: TSpinLock;

function IsRamRegion(Kind: LongWord): Boolean;
begin
  case Kind of
    MemoryRegionUsable,
    MemoryRegionKernelImage,
    MemoryRegionBootData,
    MemoryRegionBootPageTables:
      Result := True;
  else
    Result := False;
  end;
end;

function UsageForRegionKind(Kind: LongWord): TPageUsage;
begin
  case Kind of
    MemoryRegionUsable: Result := PageUsageFree;
    MemoryRegionKernelImage: Result := PageUsageKernelImage;
    MemoryRegionBootData: Result := PageUsageBootData;
    MemoryRegionBootPageTables: Result := PageUsagePageTable;
  else
    Result := PageUsageReserved;
  end;
end;

function RegionEnd(const Region: TMemoryRegion): QWord;
begin
  Result := Region.PhysicalStart + Region.PageCount * PageSize;
end;

function FindHighestRamAddress(const BootInformation: TBootInformation): QWord;
var
  RegionIndex: QWord;
  Region: PMemoryRegion;
begin
  Result := 0;
  RegionIndex := 0;
  while RegionIndex < BootInformation.MemoryRegionCount do
  begin
    Region := @BootInformation.MemoryRegions[RegionIndex];
    if IsRamRegion(Region^.Kind) and (RegionEnd(Region^) > Result) then
      Result := RegionEnd(Region^);
    Inc(RegionIndex);
  end;
end;

{ Finds a usable region that can hold ByteCount bytes above 1 MiB. }
function FindPlaceForDatabase(const BootInformation: TBootInformation;
  ByteCount: QWord): TPhysicalAddress;
var
  RegionIndex: QWord;
  Region: PMemoryRegion;
  CandidateStart: QWord;
begin
  Result := 0;
  RegionIndex := 0;
  while RegionIndex < BootInformation.MemoryRegionCount do
  begin
    Region := @BootInformation.MemoryRegions[RegionIndex];
    Inc(RegionIndex);
    if Region^.Kind <> MemoryRegionUsable then
      Continue;

    CandidateStart := Region^.PhysicalStart;
    if CandidateStart < LowestAllocatableAddress then
      CandidateStart := LowestAllocatableAddress;
    if (CandidateStart < RegionEnd(Region^)) and
       (RegionEnd(Region^) - CandidateStart >= ByteCount) then
      Exit(CandidateStart);
  end;
end;

procedure SetFrameUsage(FirstFrame: QWord; Count: QWord; Usage: TPageUsage);
var
  Frame: QWord;
begin
  Frame := FirstFrame;
  while (Frame < FirstFrame + Count) and (Frame < FrameCount) do
  begin
    FrameDatabase[Frame].Usage := Usage;
    Inc(Frame);
  end;
end;

procedure PushFreeFrame(Frame: QWord);
begin
  FrameDatabase[Frame].Usage := PageUsageFree;
  FrameDatabase[Frame].NextFreeFrame := FreeListHead;
  FreeListHead := Frame;
  Inc(FreePageCount);
end;

var
  { Which pages below 1 MiB were free RAM (ClaimLowPhysicalPages). }
  LowFrameIsFree: array[0..LowFrameCount - 1] of Boolean;

{ Builds the free list from every page still marked free. Walking from
  the top down leaves the lowest addresses at the head of the list. }
procedure BuildFreeList;
var
  Frame: QWord;
  LowestFrame: QWord;
begin
  FreeListHead := NoNextFrame;
  FreePageCount := 0;
  LowestFrame := LowestAllocatableAddress shr PageShift;

  Frame := FrameCount;
  while Frame > LowestFrame do
  begin
    Dec(Frame);
    if FrameDatabase[Frame].Usage = PageUsageFree then
      PushFreeFrame(Frame);
  end;

  { Pages below 1 MiB stay out of the free list for good. }
  Frame := 0;
  while (Frame < LowestFrame) and (Frame < FrameCount) do
  begin
    { Page 0 holds the real mode interrupt table; it is never used. }
    LowFrameIsFree[Frame] := (Frame > 0) and (FrameDatabase[Frame].Usage = PageUsageFree);
    if FrameDatabase[Frame].Usage = PageUsageFree then
      FrameDatabase[Frame].Usage := PageUsageReserved;
    Inc(Frame);
  end;
end;

procedure InitializePhysicalMemory(const BootInformation: TBootInformation);
var
  DatabaseBytes: QWord;
  DatabaseAddress: TPhysicalAddress;
  RegionIndex: QWord;
  Region: PMemoryRegion;
begin
  InitializeSpinLock(DatabaseLock);

  FrameCount := FindHighestRamAddress(BootInformation) shr PageShift;
  if FrameCount = 0 then
    KernelPanicWithCode(PanicInvalidBootInformation, 'memory map contains no RAM', 0, 0, 0, 0);

  DatabaseBytes := RoundUpToPage(FrameCount * SizeOf(TPageFrame));
  DatabaseAddress := FindPlaceForDatabase(BootInformation, DatabaseBytes);
  if DatabaseAddress = 0 then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'no room for the page frame database', DatabaseBytes, 0, 0, 0);

  FrameDatabase := PPageFrame(PhysicalToVirtual(DatabaseAddress));

  { Everything starts out reserved; only RAM regions are then described. }
  SetFrameUsage(0, FrameCount, PageUsageReserved);

  UsablePageCount := 0;
  RegionIndex := 0;
  while RegionIndex < BootInformation.MemoryRegionCount do
  begin
    Region := @BootInformation.MemoryRegions[RegionIndex];
    if IsRamRegion(Region^.Kind) then
    begin
      SetFrameUsage(Region^.PhysicalStart shr PageShift, Region^.PageCount,
        UsageForRegionKind(Region^.Kind));
      UsablePageCount := UsablePageCount + Region^.PageCount;
    end;
    Inc(RegionIndex);
  end;

  SetFrameUsage(DatabaseAddress shr PageShift, DatabaseBytes shr PageShift,
    PageUsageFrameDatabase);

  BuildFreeList;
end;

function AllocatePhysicalPage(Usage: TPageUsage): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);

  Frame := FreeListHead;
  if Frame = NoNextFrame then
  begin
    ReleaseSpinLock(DatabaseLock, PreviousLevel);
    Exit(0);
  end;

  FreeListHead := FrameDatabase[Frame].NextFreeFrame;
  FrameDatabase[Frame].NextFreeFrame := NoNextFrame;
  FrameDatabase[Frame].Usage := Usage;
  Dec(FreePageCount);

  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  Result := Frame shl PageShift;
end;

function AllocateZeroedPhysicalPage(Usage: TPageUsage): TPhysicalAddress;
begin
  Result := AllocatePhysicalPage(Usage);
  if Result <> 0 then
    ZeroMemory(PhysicalToVirtual(Result), PageSize);
end;

procedure FreePhysicalPage(PhysicalAddress: TPhysicalAddress);
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
begin
  Frame := PhysicalAddress shr PageShift;
  if (Frame >= FrameCount) or ((PhysicalAddress and PageOffsetMask) <> 0) then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'freeing an invalid physical page address', PhysicalAddress, 0, 0, 0);

  PreviousLevel := AcquireSpinLock(DatabaseLock);

  case FrameDatabase[Frame].Usage of
    PageUsageFree:
      begin
        ReleaseSpinLock(DatabaseLock, PreviousLevel);
        KernelPanicWithCode(PanicOutOfPhysicalMemory,
          'physical page freed twice', PhysicalAddress, 0, 0, 0);
      end;
    PageUsageReserved, PageUsageKernelImage, PageUsageFrameDatabase:
      begin
        ReleaseSpinLock(DatabaseLock, PreviousLevel);
        KernelPanicWithCode(PanicOutOfPhysicalMemory,
          'freeing a physical page that was never allocated', PhysicalAddress,
          Ord(FrameDatabase[Frame].Usage), 0, 0);
      end;
  end;

  PushFreeFrame(Frame);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function ClaimLowPhysicalPages(PageCount: QWord): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  First: QWord;
  Length: QWord;
  Frame: QWord;
begin
  Result := 0;
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  First := 0;
  Length := 0;
  Frame := 0;
  while (Frame < LowFrameCount) and (Length < PageCount) do
  begin
    if LowFrameIsFree[Frame] then
    begin
      if Length = 0 then
        First := Frame;
      Inc(Length);
    end
    else
      Length := 0;
    Inc(Frame);
  end;
  if (PageCount > 0) and (Length = PageCount) then
  begin
    for Frame := First to First + PageCount - 1 do
    begin
      LowFrameIsFree[Frame] := False;
      FrameDatabase[Frame].Usage := PageUsageGeneral;
    end;
    Result := First shl PageShift;
  end;
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function PageUsageOf(PhysicalAddress: TPhysicalAddress): TPageUsage;
var
  Frame: QWord;
begin
  Frame := PhysicalAddress shr PageShift;
  if Frame >= FrameCount then
    Result := PageUsageReserved
  else
    Result := FrameDatabase[Frame].Usage;
end;

procedure GetPhysicalMemoryStatistics(out Statistics: TPhysicalMemoryStatistics);
begin
  Statistics.TotalUsablePages := UsablePageCount;
  Statistics.FreePages := FreePageCount;
  Statistics.HighestPageFrameNumber := FrameCount - 1;
end;

procedure WritePhysicalMemorySummary;
begin
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWriteSize(UsablePageCount * PageSize);
  DebugWrite(' of RAM, ');
  DebugWriteSize(FreePageCount * PageSize);
  DebugWrite(' free, frame database of ');
  DebugWriteDecimal(FrameCount);
  DebugWriteLine(' pages');
  DebugEndMessage;
end;

end.
