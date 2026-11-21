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
  Physical page allocator built on a page frame database.

  The page frame database is an array with one small record per physical
  page, indexed by page frame number (physical address div PageSize). It
  records what each page is used for, and free pages are chained through
  it into a single free list, so allocating and freeing a page are both
  constant time operations.

  The database itself is placed in the first usable memory region large
  enough to hold it, and is reached through the physical memory window.

  A page can be shared, mapped in several address spaces at once (the
  pages of program and library images, Processes.ImageSections). Every
  extra holder takes a reference (ReferencePhysicalPage); freeing the
  page drops one, and only the last holder's free returns it to the free
  list.

  With the heap checks' quarantine on ("heapchecks"), a freed page is
  filled and held back from reuse for a while, and checked for writes
  after the free when it is let go (Memory.PageQuarantine).

  Memory pressure. Two watermarks of free pages, low and critical, are
  set from the RAM there is (SetMemoryWatermarks changes them). When an
  allocation leaves fewer free pages than the low watermark, or fails,
  the pressure callback runs once (outside the allocator's lock, at
  whatever level the allocation ran) until the pressure is acknowledged
  (AcknowledgeMemoryPressure); Memory.Pressure registers it, and wakes
  the thread that asks the caches to shrink. Every failed allocation is
  counted, so a caller can tell whether a failure was for want of
  memory (FailedPageAllocationCount before and after).
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
    { Driver buffers and anything else of the kernel's. }
    PageUsageGeneral,
    { A process's own pages: its heap, stacks, data, the copies it made
      of shared pages it wrote to. }
    PageUsageUserMemory,
    { The pages of mapped files - programs, libraries and files mapped
      with CallMapHandle - shared by every process that maps them
      (Processes.MappedFiles, Processes.ImageSections). }
    PageUsageProgramImage,
    { Memory shared between processes (Objects.Sections). }
    PageUsageSection,
    { Disk blocks kept in memory (Io.BlockCache). }
    PageUsageBlockCache,
    { Freed, filled, and held back from reuse for a while
      (Memory.PageQuarantine, with "heapchecks"). }
    PageUsageQuarantined
  );

  { How many pages each use has, for the system's memory figures. }
  TPageUsageCounts = array[TPageUsage] of QWord;

  TPhysicalMemoryStatistics = record
    TotalUsablePages: QWord;
    FreePages: QWord;
    HighestPageFrameNumber: QWord;
  end;

  { How short of free pages the system is: above the low watermark,
    below it, below the critical one. }
  TMemoryPressureLevel = (MemoryPressureNone, MemoryPressureLow, MemoryPressureCritical);

  { Runs when free pages fall below the low watermark or an allocation
    fails, once until AcknowledgeMemoryPressure. Any priority level up to
    DispatchLevel (it may be called with spin locks held elsewhere), so
    it may only queue a deferred call or set a flag. }
  TMemoryPressureCallback = procedure;

procedure InitializePhysicalMemory(const BootInformation: TBootInformation);

{ Returns the physical address of a free page, or zero if none is left. }
function AllocatePhysicalPage(Usage: TPageUsage): TPhysicalAddress;

{ Like AllocatePhysicalPage, but the page is filled with zeros. }
function AllocateZeroedPhysicalPage(Usage: TPageUsage): TPhysicalAddress;

{ A zeroed page that ends at or below Limit (for devices that only take
  32-bit addresses, say), or zero if there is none. Slower: it searches
  the free list. }
function AllocateZeroedPhysicalPageBelow(Limit: TPhysicalAddress; Usage: TPageUsage): TPhysicalAddress;

{ PageCount zeroed pages one after the other in physical memory, the last
  ending at or below Limit, for devices that need one buffer bigger than
  a page. Returns the first page's address, or zero if there is no such
  run. Slow (it searches the database and the free list): for drivers
  starting up. Each page is freed on its own with FreePhysicalPage. }
function AllocateZeroedContiguousPhysicalPages(PageCount: QWord; Limit: TPhysicalAddress;
  Usage: TPageUsage): TPhysicalAddress;

{ Gives the page back, or drops one reference if it is shared. }
procedure FreePhysicalPage(PhysicalAddress: TPhysicalAddress);

{ One more holder of an allocated page. }
procedure ReferencePhysicalPage(PhysicalAddress: TPhysicalAddress);
{ True if more than one holder has the page. }
function PhysicalPageIsShared(PhysicalAddress: TPhysicalAddress): Boolean;
{ How many holders the page has (1 for a page with one owner). }
function PhysicalPageHolderCount(PhysicalAddress: TPhysicalAddress): QWord;

function PageUsageOf(PhysicalAddress: TPhysicalAddress): TPageUsage;

{ Takes PageCount consecutive pages of RAM below 1 MiB (never handed out
  otherwise; secondary processors start in such a page). Returns the
  physical address of the first, or 0 if there is no such run. }
function ClaimLowPhysicalPages(PageCount: QWord): TPhysicalAddress;

procedure GetPhysicalMemoryStatistics(out Statistics: TPhysicalMemoryStatistics);
{ The pages of each use (PageUsageReserved counts every page that is not
  RAM the kernel owns, holes in the memory map included). }
procedure GetPageUsageCounts(out Counts: TPageUsageCounts);

procedure WritePhysicalMemorySummary;

{ For the self tests: the offset of the first byte of a quarantined page
  that is no longer the fill, or NoDamage. }
function QuarantinedPageDamage(PhysicalAddress: TPhysicalAddress): Int64;

{ The free page counts below which memory is short (low) and very short
  (critical); Critical is kept at most Low. }
procedure SetMemoryWatermarks(LowPages, CriticalPages: QWord);
procedure GetMemoryWatermarks(out LowPages, CriticalPages: QWord);
function CurrentMemoryPressure: TMemoryPressureLevel;
procedure SetMemoryPressureCallback(Callback: TMemoryPressureCallback);
{ The pressure was dealt with: the callback runs again the next time an
  allocation finds memory short. }
procedure AcknowledgeMemoryPressure;
{ Allocations that found no free page, since the start. }
function FailedPageAllocationCount: QWord;

implementation

uses
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Memory.HeapChecks,
  Memory.PageQuarantine,
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
    { Holders besides the first. }
    ExtraReferences: LongWord;
  end;
  PPageFrame = ^TPageFrame;

var
  FrameDatabase: PPageFrame;
  FrameCount: QWord;
  FreeListHead: QWord;
  FreePageCount: QWord;
  UsablePageCount: QWord;
  DatabaseLock: TSpinLock;
  { Kept with every change of a page's use, under the database lock. }
  UsageCounts: TPageUsageCounts;
  { Freed pages held back (under the database lock). }
  FreedPageQuarantine: TPageQuarantine;
  { Memory pressure (see the unit comment). }
  LowWatermarkPages: QWord;
  CriticalWatermarkPages: QWord;
  PressureCallback: TMemoryPressureCallback;
  PressureSignaled: Boolean;
  FailedAllocations: QWord;

{ Counts every page's use once the database is built; from then on the
  counts follow each change. }
procedure CountFrameUsages;
var
  Usage: TPageUsage;
  Frame: QWord;
begin
  for Usage := Low(TPageUsage) to High(TPageUsage) do
    UsageCounts[Usage] := 0;
  Frame := 0;
  while Frame < FrameCount do
  begin
    Inc(UsageCounts[FrameDatabase[Frame].Usage]);
    Inc(Frame);
  end;
end;

{ Gives a page another use, keeping the counts (database lock held). }
procedure ChangeFrameUsage(Frame: QWord; Usage: TPageUsage);
begin
  Dec(UsageCounts[FrameDatabase[Frame].Usage]);
  FrameDatabase[Frame].Usage := Usage;
  Inc(UsageCounts[Usage]);
end;

function IsRamRegion(Kind: LongWord): Boolean;
begin
  case Kind of
    MemoryRegionUsable,
    MemoryRegionKernelImage,
    MemoryRegionBootData,
    MemoryRegionBootPageTables,
    MemoryRegionRamDisk:
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
    { The RAM disk's storage, a driver's for good (Drivers.RamDisk). }
    MemoryRegionRamDisk: Result := PageUsageGeneral;
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
    FrameDatabase[Frame].ExtraReferences := 0;
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

{ The low watermark is 1/64 of RAM, at least 1 MiB and at most 64 MiB;
  the critical one half of it. }
procedure ChooseDefaultWatermarks;
const
  SmallestLowWatermark = (1024 * 1024) div PageSize;
  LargestLowWatermark = (64 * 1024 * 1024) div PageSize;
var
  Low: QWord;
begin
  Low := UsablePageCount div 64;
  if Low < SmallestLowWatermark then
    Low := SmallestLowWatermark;
  if Low > LargestLowWatermark then
    Low := LargestLowWatermark;
  LowWatermarkPages := Low;
  CriticalWatermarkPages := Low div 2;
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
  CountFrameUsages;
  ClearPageQuarantine(FreedPageQuarantine);
  ChooseDefaultWatermarks;
end;

{ A quarantined frame, checked, goes to the free list (database lock
  held). Held back pages count as free already. }
procedure ReleaseQuarantinedFrameLocked(Frame: QWord);
var
  Damage: Int64;
begin
  Damage := FindFreedPageDamage(PhysicalToVirtual(Frame shl PageShift));
  if Damage <> NoDamage then
    ReportFreedPageDamage(Frame shl PageShift, Damage);
  ChangeFrameUsage(Frame, PageUsageFree);
  Dec(FreePageCount);
  PushFreeFrame(Frame);
end;

{ True if the pressure callback should run now: memory is short (or an
  allocation failed) and it has not run since the last acknowledgement
  (database lock held). }
function ShouldSignalPressureLocked(Failed: Boolean): Boolean;
begin
  if Failed then
    Inc(FailedAllocations);
  Result := False;
  if PressureSignaled or not Assigned(PressureCallback) then
    Exit;
  if Failed or (FreePageCount < LowWatermarkPages) then
  begin
    PressureSignaled := True;
    Result := True;
  end;
end;

procedure SignalPressure;
var
  Callback: TMemoryPressureCallback;
begin
  Callback := PressureCallback;
  if Assigned(Callback) then
    Callback;
end;

function AllocatePhysicalPage(Usage: TPageUsage): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
  Released: QWord;
  MustSignal: Boolean;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  { Out of free pages: the oldest held back one goes first. }
  if (FreeListHead = NoNextFrame) and ReleaseOldestFrame(FreedPageQuarantine, Released) then
    ReleaseQuarantinedFrameLocked(Released);

  Frame := FreeListHead;
  if Frame = NoNextFrame then
  begin
    MustSignal := ShouldSignalPressureLocked(True);
    ReleaseSpinLock(DatabaseLock, PreviousLevel);
    if MustSignal then
      SignalPressure;
    Exit(0);
  end;

  FreeListHead := FrameDatabase[Frame].NextFreeFrame;
  FrameDatabase[Frame].NextFreeFrame := NoNextFrame;
  ChangeFrameUsage(Frame, Usage);
  FrameDatabase[Frame].ExtraReferences := 0;
  Dec(FreePageCount);
  MustSignal := ShouldSignalPressureLocked(False);

  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if MustSignal then
    SignalPressure;
  Result := Frame shl PageShift;
end;

function AllocateZeroedPhysicalPage(Usage: TPageUsage): TPhysicalAddress;
begin
  Result := AllocatePhysicalPage(Usage);
  if Result <> 0 then
    ZeroMemory(PhysicalToVirtual(Result), PageSize);
end;

function AllocateZeroedPhysicalPageBelow(Limit: TPhysicalAddress; Usage: TPageUsage): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
  Previous: QWord;
  MustSignal: Boolean;
begin
  Result := 0;
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  Previous := NoNextFrame;
  Frame := FreeListHead;
  { Compared by the page's last byte, so Limit can be the top of memory. }
  while (Frame <> NoNextFrame) and ((Frame shl PageShift) + (PageSize - 1) > Limit) do
  begin
    Previous := Frame;
    Frame := FrameDatabase[Frame].NextFreeFrame;
  end;
  if Frame <> NoNextFrame then
  begin
    if Previous = NoNextFrame then
      FreeListHead := FrameDatabase[Frame].NextFreeFrame
    else
      FrameDatabase[Previous].NextFreeFrame := FrameDatabase[Frame].NextFreeFrame;
    FrameDatabase[Frame].NextFreeFrame := NoNextFrame;
    ChangeFrameUsage(Frame, Usage);
    FrameDatabase[Frame].ExtraReferences := 0;
    Dec(FreePageCount);
    Result := Frame shl PageShift;
  end;
  MustSignal := ShouldSignalPressureLocked(Result = 0);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if MustSignal then
    SignalPressure;
  if Result <> 0 then
    ZeroMemory(PhysicalToVirtual(Result), PageSize);
end;

{ The first frame of PageCount free frames in a row, the last ending at or
  below Limit, or NoNextFrame (database lock held). }
function FindFreeFrameRun(PageCount: QWord; Limit: TPhysicalAddress): QWord;
var
  Frame: QWord;
  RunStart: QWord;
  RunLength: QWord;
begin
  Result := NoNextFrame;
  RunStart := LowFrameCount;
  RunLength := 0;
  Frame := LowFrameCount;
  while (Frame < FrameCount) and ((Frame shl PageShift) + (PageSize - 1) <= Limit) do
  begin
    if FrameDatabase[Frame].Usage = PageUsageFree then
    begin
      if RunLength = 0 then
        RunStart := Frame;
      Inc(RunLength);
      if RunLength = PageCount then
        Exit(RunStart);
    end
    else
      RunLength := 0;
    Inc(Frame);
  end;
end;

{ Takes every frame from First to Last off the free list, in one walk
  (database lock held; they are all free). }
procedure UnlinkFreeFrames(First, Last: QWord);
var
  Frame: QWord;
  Previous: QWord;
  Next: QWord;
begin
  Previous := NoNextFrame;
  Frame := FreeListHead;
  while Frame <> NoNextFrame do
  begin
    Next := FrameDatabase[Frame].NextFreeFrame;
    if (Frame >= First) and (Frame <= Last) then
    begin
      if Previous = NoNextFrame then
        FreeListHead := Next
      else
        FrameDatabase[Previous].NextFreeFrame := Next;
      FrameDatabase[Frame].NextFreeFrame := NoNextFrame;
      Dec(FreePageCount);
    end
    else
      Previous := Frame;
    Frame := Next;
  end;
end;

function AllocateZeroedContiguousPhysicalPages(PageCount: QWord; Limit: TPhysicalAddress;
  Usage: TPageUsage): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  First: QWord;
  Frame: QWord;
  MustSignal: Boolean;
begin
  Result := 0;
  if PageCount = 0 then
    Exit;
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  First := FindFreeFrameRun(PageCount, Limit);
  if First <> NoNextFrame then
  begin
    UnlinkFreeFrames(First, First + PageCount - 1);
    for Frame := First to First + PageCount - 1 do
    begin
      ChangeFrameUsage(Frame, Usage);
      FrameDatabase[Frame].ExtraReferences := 0;
    end;
    Result := First shl PageShift;
  end;
  MustSignal := ShouldSignalPressureLocked(Result = 0);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if MustSignal then
    SignalPressure;
  if Result <> 0 then
    ZeroMemory(PhysicalToVirtual(Result), PageCount * PageSize);
end;

{ The last holder freed Frame (now PageUsageQuarantined, database lock
  not held): fills it, puts it in the quarantine and lets the oldest
  page there go back to the free list once its fill checked out. }
procedure QuarantineFreedFrame(Frame: QWord);
var
  PreviousLevel: TPriorityLevel;
  Released: QWord;
  WasReleased: Boolean;
  Damage: Int64;
begin
  FillFreedPage(PhysicalToVirtual(Frame shl PageShift));
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  WasReleased := QuarantineFrame(FreedPageQuarantine, Frame, Released);
  { Held back pages count as free memory. }
  Inc(FreePageCount);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if not WasReleased then
    Exit;
  { Checked outside the lock; the frame is still PageUsageQuarantined,
    so nobody else takes it meanwhile. }
  Damage := FindFreedPageDamage(PhysicalToVirtual(Released shl PageShift));
  if Damage <> NoDamage then
    ReportFreedPageDamage(Released shl PageShift, Damage);
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  ChangeFrameUsage(Released, PageUsageFree);
  Dec(FreePageCount);
  PushFreeFrame(Released);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function QuarantinedPageDamage(PhysicalAddress: TPhysicalAddress): Int64;
begin
  Result := FindFreedPageDamage(PhysicalToVirtual(PhysicalAddress and not PageOffsetMask));
end;

procedure FreePhysicalPage(PhysicalAddress: TPhysicalAddress);
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
  MustQuarantine: Boolean;
begin
  Frame := PhysicalAddress shr PageShift;
  if (Frame >= FrameCount) or ((PhysicalAddress and PageOffsetMask) <> 0) then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'freeing an invalid physical page address', PhysicalAddress, 0, 0, 0);

  PreviousLevel := AcquireSpinLock(DatabaseLock);

  case FrameDatabase[Frame].Usage of
    PageUsageFree, PageUsageQuarantined:
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

  MustQuarantine := False;
  if FrameDatabase[Frame].ExtraReferences > 0 then
    Dec(FrameDatabase[Frame].ExtraReferences)
  else if KernelHeapCheckLevel = HeapChecksQuarantine then
  begin
    ChangeFrameUsage(Frame, PageUsageQuarantined);
    MustQuarantine := True;
  end
  else
  begin
    ChangeFrameUsage(Frame, PageUsageFree);
    PushFreeFrame(Frame);
  end;
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if MustQuarantine then
    QuarantineFreedFrame(Frame);
end;

function CheckedFrame(PhysicalAddress: TPhysicalAddress): QWord;
begin
  Result := PhysicalAddress shr PageShift;
  if (Result >= FrameCount) or ((PhysicalAddress and PageOffsetMask) <> 0) then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'invalid physical page address', PhysicalAddress, 0, 0, 0);
end;

procedure ReferencePhysicalPage(PhysicalAddress: TPhysicalAddress);
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
begin
  Frame := CheckedFrame(PhysicalAddress);
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  if FrameDatabase[Frame].Usage in [PageUsageFree, PageUsageQuarantined] then
  begin
    ReleaseSpinLock(DatabaseLock, PreviousLevel);
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'referencing a free physical page', PhysicalAddress, 0, 0, 0);
  end;
  Inc(FrameDatabase[Frame].ExtraReferences);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function PhysicalPageIsShared(PhysicalAddress: TPhysicalAddress): Boolean;
begin
  Result := FrameDatabase[CheckedFrame(PhysicalAddress)].ExtraReferences > 0;
end;

function PhysicalPageHolderCount(PhysicalAddress: TPhysicalAddress): QWord;
begin
  Result := QWord(FrameDatabase[CheckedFrame(PhysicalAddress)].ExtraReferences) + 1;
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
      ChangeFrameUsage(Frame, PageUsageGeneral);
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

procedure GetPageUsageCounts(out Counts: TPageUsageCounts);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  Counts := UsageCounts;
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

procedure SetMemoryWatermarks(LowPages, CriticalPages: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  if CriticalPages > LowPages then
    CriticalPages := LowPages;
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  LowWatermarkPages := LowPages;
  CriticalWatermarkPages := CriticalPages;
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

procedure GetMemoryWatermarks(out LowPages, CriticalPages: QWord);
begin
  LowPages := LowWatermarkPages;
  CriticalPages := CriticalWatermarkPages;
end;

function CurrentMemoryPressure: TMemoryPressureLevel;
var
  FreeNow: QWord;
begin
  FreeNow := FreePageCount;
  if FreeNow < CriticalWatermarkPages then
    Result := MemoryPressureCritical
  else if FreeNow < LowWatermarkPages then
    Result := MemoryPressureLow
  else
    Result := MemoryPressureNone;
end;

procedure SetMemoryPressureCallback(Callback: TMemoryPressureCallback);
begin
  PressureCallback := Callback;
end;

procedure AcknowledgeMemoryPressure;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  PressureSignaled := False;
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function FailedPageAllocationCount: QWord;
begin
  Result := FailedAllocations;
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
