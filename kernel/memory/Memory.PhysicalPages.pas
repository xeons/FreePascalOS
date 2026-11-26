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
  it into a single free list (linked both ways, so any free page can be
  taken off it), so allocating and freeing a page are both constant time
  operations.

  Contiguous runs. Next to the free list, a bitmap with a bit per page
  frame (Memory.FrameRuns) says which frames are free, so a run of
  physically contiguous pages - with an alignment, a boundary it must
  not cross and an address range, as devices need for DMA buffers
  (Io.Dma) - is found by scanning the bitmap a word at a time, and its
  frames are taken off the free list one by one in constant time
  (AllocatePhysicalRun, FreePhysicalRun). Single pages below an address
  (32-bit devices) come from the bitmap too.

  The database and the bitmap are placed together in the first usable
  memory region large enough to hold them, and are reached through the
  physical memory window.

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

  The reserve (Memory.Reserves). Below the critical watermark, a page for
  a process's memory, a mapped file or a section (IsProcessPageUsage) is
  refused unless the reserve access query (set by the process manager)
  says the current thread may use the reserve - a kernel thread or an
  essential process, which may go down to half the watermark; kernel
  allocations of every other use may take the last page. A refusal is
  counted as a failed allocation (and in ReserveRefusalCount), so the
  faulting program's out-of-memory handling starts at once while the
  kernel and the user's shell still have memory to work with.
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

  { Whether the current thread may take pages from the reserve. }
  TReserveAccessQuery = function: Boolean;

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
  run. Each page is freed on its own with FreePhysicalPage (or all of
  them with FreePhysicalRun). }
function AllocateZeroedContiguousPhysicalPages(PageCount: QWord; Limit: TPhysicalAddress;
  Usage: TPageUsage): TPhysicalAddress;

type
  { What a contiguous run must be like (AllocatePhysicalRun). }
  TPhysicalRunConstraints = record
    PageCount: QWord;
    { The first page's address is a multiple of this (a power of two;
      0 or anything below a page: page aligned). }
    AlignmentBytes: QWord;
    { The run does not cross a multiple of this (a power of two; 0:
      no boundary). }
    BoundaryBytes: QWord;
    { The run lies in [LowestAddress, Limit]: its first byte at or above
      LowestAddress, its last at or below Limit. }
    LowestAddress: TPhysicalAddress;
    Limit: TPhysicalAddress;
  end;

{ Constraints for PageCount pages anywhere, page aligned. }
procedure SetPhysicalRunConstraints(out Constraints: TPhysicalRunConstraints; PageCount: QWord);
{ A run of physically contiguous pages as Constraints describe, the
  lowest there is, filled with zeros if Zeroed; its first page's
  address, or zero if there is none (after letting the freed pages the
  heap checks hold back go). Each page has one holder, as from
  AllocatePhysicalPage. }
function AllocatePhysicalRun(constref Constraints: TPhysicalRunConstraints; Usage: TPageUsage;
  Zeroed: Boolean): TPhysicalAddress;
{ Frees PageCount pages from First (a run, or any pages one after the
  other), each as FreePhysicalPage does. }
procedure FreePhysicalRun(First: TPhysicalAddress; PageCount: QWord);
{ The longest run of free pages there is now. }
function LongestFreePhysicalRun: QWord;

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
{ For the self tests: watches the page's next entry into the quarantine
  (Memory.PageQuarantine). }
procedure WatchPhysicalPageQuarantine(PhysicalAddress: TPhysicalAddress);
{ Whether the watched page went into the quarantine since, and whether
  it has left it again (checked, to the free list). }
procedure GetPhysicalPageQuarantineWatch(out Entered, Departed: Boolean);

{ The free page counts below which memory is short (low) and very short
  (critical); Critical is kept at most Low. }
procedure SetMemoryWatermarks(LowPages, CriticalPages: QWord);
procedure GetMemoryWatermarks(out LowPages, CriticalPages: QWord);
function CurrentMemoryPressure: TMemoryPressureLevel;
procedure SetMemoryPressureCallback(Callback: TMemoryPressureCallback);
{ The pressure was dealt with: the callback runs again the next time an
  allocation finds memory short. }
procedure AcknowledgeMemoryPressure;
{ Allocations that found no free page, since the start (refusals for
  the reserve included). }
function FailedPageAllocationCount: QWord;
{ Allocations of processes' pages refused for the reserve. }
function ReserveRefusalCount: QWord;
{ Who may use the reserve (nil: everyone, as before the process manager
  starts). }
procedure SetReserveAccessQuery(Query: TReserveAccessQuery);
{ True for the uses that are processes' pages (held to the reserve). }
function IsProcessPageUsage(Usage: TPageUsage): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Memory.HeapChecks,
  Memory.PageQuarantine,
  Memory.FrameRuns,
  Memory.Reserves,
  Debug.Output;

const
  { The free list's links are 32-bit frame numbers (16 TiB of RAM). }
  NoNextFrame = QWord(High(LongWord));

  { Memory below 1 MiB is never handed out. It is where firmware tables
    live on PCs and where secondary processors start executing. }
  LowestAllocatableAddress = QWord($100000);
  LowFrameCount = LowestAllocatableAddress shr PageShift;

type
  TPageFrame = record
    { The free list's neighbours (NoNextFrame at its ends). }
    NextFreeFrame: LongWord;
    PreviousFreeFrame: LongWord;
    Usage: TPageUsage;
    { Holders besides the first. }
    ExtraReferences: LongWord;
  end;
  PPageFrame = ^TPageFrame;

var
  FrameDatabase: PPageFrame;
  { Which frames are on the free list (see the unit comment). }
  FreeFrames: TFrameBitmap;
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
  ReserveRefusals: QWord;
  ReserveAccessQuery: TReserveAccessQuery = nil;

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
  FrameDatabase[Frame].NextFreeFrame := LongWord(FreeListHead);
  FrameDatabase[Frame].PreviousFreeFrame := LongWord(NoNextFrame);
  if FreeListHead <> NoNextFrame then
    FrameDatabase[FreeListHead].PreviousFreeFrame := LongWord(Frame);
  FreeListHead := Frame;
  MarkFrameFree(FreeFrames, Frame);
  Inc(FreePageCount);
end;

{ Takes a free frame off the free list (database lock held). }
procedure UnlinkFreeFrame(Frame: QWord);
var
  Next: QWord;
  Previous: QWord;
begin
  Next := FrameDatabase[Frame].NextFreeFrame;
  Previous := FrameDatabase[Frame].PreviousFreeFrame;
  if Previous = NoNextFrame then
    FreeListHead := Next
  else
    FrameDatabase[Previous].NextFreeFrame := LongWord(Next);
  if Next <> NoNextFrame then
    FrameDatabase[Next].PreviousFreeFrame := LongWord(Previous);
  FrameDatabase[Frame].NextFreeFrame := LongWord(NoNextFrame);
  FrameDatabase[Frame].PreviousFreeFrame := LongWord(NoNextFrame);
  MarkFrameUsed(FreeFrames, Frame);
  Dec(FreePageCount);
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
  BitmapBytes: QWord;
  DatabaseAddress: TPhysicalAddress;
  RegionIndex: QWord;
  Region: PMemoryRegion;
begin
  InitializeSpinLock(DatabaseLock);

  FrameCount := FindHighestRamAddress(BootInformation) shr PageShift;
  if FrameCount = 0 then
    KernelPanicWithCode(PanicInvalidBootInformation, 'memory map contains no RAM', 0, 0, 0, 0);
  { The free list links frames by 32-bit numbers. }
  if FrameCount >= NoNextFrame then
    FrameCount := NoNextFrame - 1;

  DatabaseBytes := RoundUpToPage(FrameCount * SizeOf(TPageFrame));
  BitmapBytes := RoundUpToPage(FrameBitmapWords(FrameCount) * SizeOf(QWord));
  DatabaseAddress := FindPlaceForDatabase(BootInformation, DatabaseBytes + BitmapBytes);
  if DatabaseAddress = 0 then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'no room for the page frame database', DatabaseBytes + BitmapBytes, 0, 0, 0);

  FrameDatabase := PPageFrame(PhysicalToVirtual(DatabaseAddress));
  InitializeFrameBitmap(FreeFrames, PQWord(PhysicalToVirtual(DatabaseAddress + DatabaseBytes)), FrameCount);

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

  SetFrameUsage(DatabaseAddress shr PageShift, (DatabaseBytes + BitmapBytes) shr PageShift,
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

function IsProcessPageUsage(Usage: TPageUsage): Boolean;
begin
  Result := Usage in [PageUsageUserMemory, PageUsageProgramImage, PageUsageSection];
end;

{ The free pages a process page must leave: the reserve's floor, or 0
  when the caller may take any (asked outside the lock, and only when
  memory is near the reserve). }
function ReserveFloorFor(Usage: TPageUsage): QWord;
var
  Query: TReserveAccessQuery;
begin
  Result := 0;
  if not IsProcessPageUsage(Usage) or (FreePageCount > CriticalWatermarkPages) then
    Exit;
  Query := ReserveAccessQuery;
  if not Assigned(Query) then
    Exit;
  Result := UserPageFloor(CriticalWatermarkPages, Query());
end;

function AllocatePhysicalPage(Usage: TPageUsage): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Frame: QWord;
  Released: QWord;
  MustSignal: Boolean;
  Floor: QWord;
begin
  Floor := ReserveFloorFor(Usage);
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  if (Floor > 0) and (FreePageCount <= Floor) then
  begin
    Inc(ReserveRefusals);
    MustSignal := ShouldSignalPressureLocked(True);
    ReleaseSpinLock(DatabaseLock, PreviousLevel);
    if MustSignal then
      SignalPressure;
    Exit(0);
  end;
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

  UnlinkFreeFrame(Frame);
  ChangeFrameUsage(Frame, Usage);
  FrameDatabase[Frame].ExtraReferences := 0;
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

{ The first frame past the frames whose page ends at or below Limit. }
function EndFrameBelow(Limit: TPhysicalAddress): QWord;
begin
  if Limit >= FrameCount * PageSize then
    Exit(FrameCount);
  Result := (Limit + 1) shr PageShift;
end;

procedure SetPhysicalRunConstraints(out Constraints: TPhysicalRunConstraints; PageCount: QWord);
begin
  Constraints.PageCount := PageCount;
  Constraints.AlignmentBytes := PageSize;
  Constraints.BoundaryBytes := 0;
  Constraints.LowestAddress := 0;
  Constraints.Limit := High(QWord);
end;

{ The frame request for Constraints; False if they cannot be met by any
  run (alignment or boundary not a power of two, a boundary below a
  page or smaller than the run). }
function FrameRequestFor(constref Constraints: TPhysicalRunConstraints; out Request: TFrameRunRequest): Boolean;
var
  Alignment: QWord;
begin
  Result := False;
  Alignment := Constraints.AlignmentBytes;
  if Alignment < PageSize then
    Alignment := PageSize;
  if (Alignment and (Alignment - 1)) <> 0 then
    Exit;
  if (Constraints.BoundaryBytes <> 0) and
     (((Constraints.BoundaryBytes and (Constraints.BoundaryBytes - 1)) <> 0) or
      (Constraints.BoundaryBytes < PageSize)) then
    Exit;
  Request.PageCount := Constraints.PageCount;
  Request.AlignmentPages := Alignment shr PageShift;
  Request.BoundaryPages := Constraints.BoundaryBytes shr PageShift;
  Request.LowestFrame := (Constraints.LowestAddress + PageSize - 1) shr PageShift;
  if Constraints.LowestAddress > High(QWord) - PageSize then
    Request.LowestFrame := FrameCount;
  { Memory below 1 MiB is never handed out. }
  if Request.LowestFrame < LowFrameCount then
    Request.LowestFrame := LowFrameCount;
  Request.EndFrame := EndFrameBelow(Constraints.Limit);
  Result := FrameRunRequestIsValid(Request);
end;

{ Lets every page the heap checks hold back go to the free list (database
  lock held), so a run search sees all free memory. True if there were
  any. }
function DrainQuarantineLocked: Boolean;
var
  Released: QWord;
begin
  Result := False;
  while ReleaseOldestFrame(FreedPageQuarantine, Released) do
  begin
    ReleaseQuarantinedFrameLocked(Released);
    Result := True;
  end;
end;

{ Finds and takes the run (database lock held); NoNextFrame if none. }
function TakeFrameRunLocked(constref Request: TFrameRunRequest; Usage: TPageUsage): QWord;
var
  First: QWord;
  Frame: QWord;
begin
  if not FindFreeFrameRun(FreeFrames, Request, First) then
  begin
    if not DrainQuarantineLocked or not FindFreeFrameRun(FreeFrames, Request, First) then
      Exit(NoNextFrame);
  end;
  Frame := First;
  while Frame < First + Request.PageCount do
  begin
    UnlinkFreeFrame(Frame);
    ChangeFrameUsage(Frame, Usage);
    FrameDatabase[Frame].ExtraReferences := 0;
    Inc(Frame);
  end;
  Result := First;
end;

function AllocatePhysicalRun(constref Constraints: TPhysicalRunConstraints; Usage: TPageUsage;
  Zeroed: Boolean): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Request: TFrameRunRequest;
  First: QWord;
  MustSignal: Boolean;
begin
  Result := 0;
  if not FrameRequestFor(Constraints, Request) then
    Exit;
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  First := TakeFrameRunLocked(Request, Usage);
  if First <> NoNextFrame then
    Result := First shl PageShift;
  MustSignal := ShouldSignalPressureLocked(Result = 0);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
  if MustSignal then
    SignalPressure;
  if (Result <> 0) and Zeroed then
    ZeroMemory(PhysicalToVirtual(Result), Constraints.PageCount * PageSize);
end;

procedure FreePhysicalRun(First: TPhysicalAddress; PageCount: QWord);
var
  Index: QWord;
begin
  Index := 0;
  while Index < PageCount do
  begin
    FreePhysicalPage(First + Index * PageSize);
    Inc(Index);
  end;
end;

function LongestFreePhysicalRun: QWord;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  Result := LongestFreeFrameRun(FreeFrames);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

function AllocateZeroedPhysicalPageBelow(Limit: TPhysicalAddress; Usage: TPageUsage): TPhysicalAddress;
var
  Constraints: TPhysicalRunConstraints;
begin
  SetPhysicalRunConstraints(Constraints, 1);
  Constraints.Limit := Limit;
  Result := AllocatePhysicalRun(Constraints, Usage, True);
end;

function AllocateZeroedContiguousPhysicalPages(PageCount: QWord; Limit: TPhysicalAddress;
  Usage: TPageUsage): TPhysicalAddress;
var
  Constraints: TPhysicalRunConstraints;
begin
  Result := 0;
  if PageCount = 0 then
    Exit;
  SetPhysicalRunConstraints(Constraints, PageCount);
  Constraints.Limit := Limit;
  Result := AllocatePhysicalRun(Constraints, Usage, True);
end;

{ The last holder freed Frame (now PageUsageQuarantined, database lock
  not held): fills it, puts it in the quarantine and lets the oldest
  page there go back to the free list once its fill checked out. The
  oldest page leaves the ring, is checked and is freed in one hold of
  the lock: checked after the lock was let go, it was for a while
  neither in the ring nor free, still marked held back, while other
  processors went on freeing and taking pages (Memory.PageQuarantine). }
procedure QuarantineFreedFrame(Frame: QWord);
var
  PreviousLevel: TPriorityLevel;
  Released: QWord;
begin
  FillFreedPage(PhysicalToVirtual(Frame shl PageShift));
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  { Held back pages count as free memory. }
  Inc(FreePageCount);
  if QuarantineFrame(FreedPageQuarantine, Frame, Released) then
    ReleaseQuarantinedFrameLocked(Released);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

procedure WatchPhysicalPageQuarantine(PhysicalAddress: TPhysicalAddress);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  WatchQuarantineFrame(FreedPageQuarantine, PhysicalAddress shr PageShift);
  ReleaseSpinLock(DatabaseLock, PreviousLevel);
end;

procedure GetPhysicalPageQuarantineWatch(out Entered, Departed: Boolean);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DatabaseLock);
  GetQuarantineWatch(FreedPageQuarantine, Entered, Departed);
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

function ReserveRefusalCount: QWord;
begin
  Result := ReserveRefusals;
end;

procedure SetReserveAccessQuery(Query: TReserveAccessQuery);
begin
  ReserveAccessQuery := Query;
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
