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
  User address spaces.

  An address space is a page table root plus its regions: ranges of
  user addresses with fixed attributes, kept in a balanced tree ordered
  by address (Processes.RegionTree), so finding the region of a fault,
  adding one and finding room for one take logarithmic time however
  many there are. Their number is bounded only by the address space and
  the process's region limit (RegionLimit, DefaultRegionLimit unless
  changed with CallSetProcessLimit). Pages of most regions
  are provided on demand: the first touch of an address in such a region
  raises a page fault, and the fault resolver maps a fresh zero filled
  page. Pages of program images are mapped eagerly by the loader, from
  the image's shared pages (Processes.ImageSections): read-only pages are
  simply shared, writable ones are copy on write - the first write, by
  the program or by the kernel (relocations, WriteIntoAddressSpace),
  gives the process its own copy of that page.

  Layout (with the kernel option aslr=off; otherwise each part lies at
  a random place of a window of its own, Processes.AddressLayout, kept
  in the space's Layout):

    0000_0000_0040_0000   program image
    0000_1000_0000_0000   memory allocated at run time (heap blocks)
    0000_7F00_0000_0000   shared libraries
    0000_7FFF_FF7F_F000   stack (8 MiB reserved, grows down from the top)

  Stacks end in a reserve (StackReserveSize, less for small stacks) that
  is not provided on demand: touching it is a stack overflow. The
  exception dispatcher then opens the reserve (OpenStackReserve), so the
  exception record and the program's handling of it still fit, and the
  reserve is armed again (RearmStackReserve) once the thread's stack is
  well clear of it.

  Device memory (a framebuffer) is mapped into a process as a region of
  its own, all its pages mapped at once and marked as the device's
  (MappingDevice): unmapping it frees nothing. The program frees it like
  memory it allocated.

  Run time allocations, reservations (Processes.VirtualMemory) and file
  mappings may be split into several regions - pieces committed,
  decommitted or given another protection apart from the rest
  (Processes.RegionEditing) - all with the allocation's start as their
  AllocationBase; freeing that start frees every piece. A page the
  program may not touch (no access, a guard) stays mapped for the kernel
  only (MappingNoAccess), so changing the protection back finds it.

  File backed regions (images, file mappings: Backing, a TMappedFile of
  Processes.MappedFiles) get their pages from the file's mapped pages
  when first touched; reading a page the file has not read yet sleeps,
  so the fault resolver leaves the spin lock for it and the touch is
  tried again. Private ones map the pages copy on write.

  Commit charge: the pages of private memory the space may come to use
  (RegionChargePages: committed allocations, stacks, thread data,
  writable images, writable private file mappings) are counted in
  CommitChargePages, against CommitLimitPages (0: none), and in the
  system's total (Memory.CommitCharge).

  A section (memory shared between processes, Objects.Sections) is
  mapped the same way, its pages mapped at once, each with a reference
  of its own: unmapping gives the references back, and the pages go once
  nothing maps them and the section is gone.

  Below every stack lies a guard (StackGuardSize of address space, a
  region of kind RegionKindStackGuard that is never mapped and costs no
  memory), so nothing else is ever placed there: a frame too large for
  the reserve, up to the guard's size, lands in the guard - where it is
  taken for a stack overflow - and never in other memory.

  The kernel reads and writes user memory either directly (for the
  current process, after ValidateUserRange) or through the physical
  memory window (WriteIntoAddressSpace and friends), which works for any
  address space and is what the program loader uses.
}
unit Processes.AddressSpace;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Memory.Layout,
  Kernel.SpinLock,
  Processes.UserRegions,
  Processes.RegionTree,
  Processes.AddressLayout;

const
  { The fixed layout (aslr=off); a space's own is in its Layout. }
  UserImageBase = FixedImageBase;
  UserAllocationBase = FixedAllocationBase;
  UserAllocationLimit = AllocationAreaLimit;
  UserLibraryBase = FixedLibraryBase;
  UserStackTop = FixedStackTop;
  UserStackReserve = MainStackReserve;

  { The regions a process may have unless it changes its limit, and the
    most any process may set (each costs a little kernel memory). }
  DefaultRegionLimit = DefaultProcessRegionLimit;
  RegionLimitCeiling = ProcessRegionLimitCeiling;

  { The reserve at the bottom of a stack, and how far above it the stack
    pointer must be before a used reserve is armed again. }
  StackReserveSize = 64 * 1024;
  StackReserveRearmDistance = 64 * 1024;
  StackGuardSize = QWord(256) * 1024 * 1024;

  RegionReadable = LongWord(1) shl 0;
  RegionWritable = LongWord(1) shl 1;
  RegionExecutable = LongWord(1) shl 2;

type
  PAddressSpace = ^TAddressSpace;
  TAddressSpace = record
    Root: TPhysicalAddress;
    Regions: TRegionTree;
    { The most regions there may be (a process limit). }
    RegionLimit: LongWord;
    { The regions' sizes, guards left out. }
    VirtualBytes: QWord;
    NextLibraryAddress: QWord;
    { Where its program, libraries, stacks and allocations go (random
      unless aslr=off). }
    Layout: TAddressLayout;
    { The pages mapped (the resident set), the ones among them that are
      shared - mapped from a program image or a section, which other
      processes may map too - and the most there ever were. }
    CommittedPages: QWord;
    SharedPages: QWord;
    PeakCommittedPages: QWord;
    { The commit charge (see above), and its limit (0: none). }
    CommitChargePages: QWord;
    CommitLimitPages: QWord;
    { Memory may be made executable after it was written
      (CallSetMemoryPolicy); without it nothing but program images and
      files mapped executable is. }
    AllowsDynamicCode: Boolean;
    { The threads of a process share the space: region changes, page
      commits and lookups happen under this lock (held briefly, at
      dispatch level, so no thread is preempted halfway through). }
    Lock: TSpinLock;
  end;

  { What a process's memory amounts to (GetAddressSpaceUsage). }
  TAddressSpaceUsage = record
    { The regions' sizes, guards left out: what the program may touch. }
    VirtualBytes: QWord;
    ResidentPages: QWord;
    SharedPages: QWord;
    PeakResidentPages: QWord;
    RegionCount: LongWord;
    RegionLimit: LongWord;
    CommitChargePages: QWord;
    CommitLimitPages: QWord;
  end;

{ All routines returning LongInt return 0 on success or an Abi error code. }

{ False with the kernel option aslr=off: every process then gets the
  fixed layout. }
function AddressSpaceRandomizationIsOn: Boolean;
{ A random number below Limit, for the layout (Kernel.Random). }
function LayoutRandom(Limit: QWord): QWord;

function CreateAddressSpace(out Space: PAddressSpace): LongInt;
procedure DestroyAddressSpace(Space: PAddressSpace);
procedure GetAddressSpaceUsage(Space: PAddressSpace; out Usage: TAddressSpaceUsage);

function AddRegion(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
{ Adds a region as Template describes it (file backed ones: the region
  holds the caller's reference to the backing on success). }
function AddRegionRecord(Space: PAddressSpace; const Template: TUserRegion): LongInt;
{ Changes the most regions Space may have (existing ones stay). }
procedure SetRegionLimit(Space: PAddressSpace; Limit: LongWord);
{ Changes the most pages Space may have committed (0: no limit; what is
  committed already stays). }
procedure SetCommitLimit(Space: PAddressSpace; LimitPages: QWord);
{ The space's commit charge, in pages (for a policy on running out of
  memory, with Memory.CommitCharge's total). }
function CommitChargeOf(Space: PAddressSpace): QWord;
{ The resident pages of file backed regions that some other mapping
  maps too (another process running the same program, say). Walks the
  page tables: for diagnostics, not for every snapshot. }
function CountPagesMappedElsewhere(Space: PAddressSpace): QWord;

{ Finds room for Length bytes at or above Base and below Limit. }
function FindFreeRange(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;

{ Run time allocations (backing for the user heap). }
function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;
{ A run time allocation that belongs to the thread OwnerThreadId (its
  threadvar block): freed like any other, or given back by
  ReleaseThreadOwnedMemory when the thread ends. }
function AllocateThreadOwnedUserMemory(Space: PAddressSpace; Length: QWord; OwnerThreadId: QWord;
  out Start: QWord): LongInt;
{ Frees the allocation starting at Start if it still belongs to the
  thread OwnerThreadId (it may have been freed, and its addresses used
  again, since). }
procedure ReleaseThreadOwnedMemory(Space: PAddressSpace; Start: QWord; OwnerThreadId: QWord);
{ Frees every allocation that still belongs to the thread OwnerThreadId
  (a thread that made several: dynamic TLS blocks). }
procedure ReleaseAllThreadOwnedMemory(Space: PAddressSpace; OwnerThreadId: QWord);

{ Allocates Length bytes of on-demand memory of the given kind with an
  unmapped guard page below it (thread stacks). }
function AllocateGuardedUserMemory(Space: PAddressSpace; Length: QWord; Kind: TRegionKind;
  out Start: QWord): LongInt;
{ Releases the region starting at Start, whatever its kind. }
function ReleaseUserRegion(Space: PAddressSpace; Start: QWord): LongInt;
{ Maps Length bytes of device memory at Physical (both page aligned)
  into the run time allocation area, writable if Writable, with writes
  combined if WriteCombining (else uncached). }
function MapDeviceIntoAddressSpace(Space: PAddressSpace; Physical: TPhysicalAddress; Length: QWord;
  Writable, WriteCombining: Boolean; out Start: QWord): LongInt;
{ Maps PageCount pages (Pages[0..PageCount-1], each referenced again)
  into the run time allocation area, writable if Writable. }
function MapPagesIntoAddressSpace(Space: PAddressSpace; Pages: PPhysicalAddress; PageCount: QWord;
  Writable: Boolean; out Start: QWord): LongInt;

{ Maps a zero filled page at Address with the given attributes. If a page
  is already there its attributes are combined with Attributes. }
function CommitPage(Space: PAddressSpace; Address: QWord; Attributes: LongWord): LongInt;
{ If Address lies in the armed reserve of the stack region starting at
  StackStart, opens the reserve and returns True and the region's start. }
function OpenStackReserve(Space: PAddressSpace; Address: QWord; StackStart: QWord;
  out RegionStart: QWord): Boolean;
{ Arms the opened reserve of the stack starting at RegionStart again if
  StackPointer is far enough above it, giving its pages back. Returns
  True if the reserve is armed (again). }
function RearmStackReserve(Space: PAddressSpace; RegionStart, StackPointer: QWord): Boolean;
{ Opens the reserve of the stack region starting at StackStart if it is
  armed (an overflow by a frame that jumped past it); True if it did. }
function OpenStackReserveOfRegion(Space: PAddressSpace; StackStart: QWord): Boolean;
{ The first address above the reserve of the stack region starting at
  StackStart, or 0 if there is no such region. }
function StackReserveTop(Space: PAddressSpace; StackStart: QWord): QWord;
{ True if Address lies in a region other than a stack guard. }
function AddressIsInUsableRegion(Space: PAddressSpace; Address: QWord): Boolean;
{ Adds the guard below the stack region starting at StackStart (the
  main thread's; thread stacks get theirs with
  AllocateGuardedUserMemory). }
function AddStackGuard(Space: PAddressSpace; StackStart: QWord): LongInt;
{ Maps the shared page Physical at Address (taking a reference to it):
  read-only, or copy on write if Attributes include RegionWritable. }
function MapSharedPage(Space: PAddressSpace; Address: QWord; Physical: TPhysicalAddress;
  Attributes: LongWord): LongInt;

{ Called on a page fault in user space; True if a page was provided. }
function ResolveUserPageFault(Space: PAddressSpace; Address: QWord; ErrorCode: QWord): Boolean;
{ The same, also telling whether the fault was the first touch of a
  guard page (HitGuard; the guard is gone from the page then). }
function ResolveUserPageFaultWithGuard(Space: PAddressSpace; Address: QWord; ErrorCode: QWord;
  out HitGuard: Boolean): Boolean;
{ Makes sure the page of a file backed region holding Address has been
  read from its file (it may sleep). 0 or an Abi error. }
function PageInBackedAddress(Space: PAddressSpace; Address: QWord): LongInt;

{ True if [Address, Address + Length) lies entirely in regions of Space,
  writable ones if NeedWrite is set. }
function ValidateUserRange(Space: PAddressSpace; Address, Length: QWord; NeedWrite: Boolean): Boolean;

{ Copies between kernel memory and any address space, providing on-demand
  pages as needed. }
function WriteIntoAddressSpace(Space: PAddressSpace; Address: QWord; Source: Pointer;
  Length: QWord): LongInt;
function ReadFromAddressSpace(Space: PAddressSpace; Address: QWord; Destination: Pointer;
  Length: QWord): LongInt;
{ A kernel pointer to the page holding Address, made writable (provided
  if not touched yet, copied if copy on write). For the loader, writing
  many values into pages it just mapped: the pointer stays valid only as
  long as nothing unmaps the page. }
function WritablePageWindow(Space: PAddressSpace; Address: QWord; out Window: PByte): LongInt;

{ --- For Processes.VirtualMemory: the caller holds Space^.Lock --------- }

function FindRegionLocked(Space: PAddressSpace; Address: QWord): PUserRegion;
function FindRegionAtOrAboveLocked(Space: PAddressSpace; Address: QWord): PUserRegion;
{ Room in the run time allocation area. }
function FindAllocationRangeLocked(Space: PAddressSpace; Length, Hint: QWord; out Start: QWord): Boolean;
{ Adds a region as Template describes it, charged (ErrorOutOfMemory
  over the commit or region limit). On success the region holds the
  reference to Template.Backing the caller had. }
function AddRegionRecordLocked(Space: PAddressSpace; const Template: TUserRegion): LongInt;
{ Removes the region starting at Start, or every piece of the
  allocation starting there. False if there is none. }
function RemoveAllocationLocked(Space: PAddressSpace; Start: QWord): Boolean;
{ The page table attributes the pages of Region get. }
function RegionMapping(Region: PUserRegion): LongWord;
{ Removes just the region (piece) starting at Start, with its pages
  (munmap, Processes.MemoryMapping). }
procedure RemoveAllocationPieceLocked(Space: PAddressSpace; Start: QWord);
{ Cuts the region holding Address there (nothing if it starts there or
  no region holds it). ErrorOutOfMemory over the region limit. }
function SplitRegionLocked(Space: PAddressSpace; Address: QWord): LongInt;
{ Joins alike pieces in and next to [First, Finish). }
procedure MergeRegionsLocked(Space: PAddressSpace; First, Finish: QWord);
{ The pages Region counts against the commit charge. }
function RegionChargePages(const Region: TUserRegion): QWord;
{ Counts Pages more against the charge; ErrorOutOfMemory over the
  limit (nothing counted then). }
function ChargeCommitLocked(Space: PAddressSpace; Pages: QWord): LongInt;
procedure UnchargeCommitLocked(Space: PAddressSpace; Pages: QWord);
{ Unmaps and gives back the pages of [Start, Start + Length). }
procedure ReleaseRegionPagesLocked(Space: PAddressSpace; Start, Length: QWord);
{ Maps the present pages of [Start, Start + Length), which lies in one
  region, again with that region's protection. }
procedure ApplyRegionProtectionLocked(Space: PAddressSpace; Start, Length: QWord);

implementation

uses
  Runtime.Memory,
  Kernel.Options,
  Kernel.Random,
  Kernel.PriorityLevel,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.CommitCharge,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Processes.RegionEditing,
  Processes.MappedFiles;

const
  PageFaultWasPresent = 1;
  PageFaultWasWrite = 2;
  PageFaultFromUser = 4;
  PageFaultWasFetch = 16;
  { PageInWindow: the page must be read from its file first, which the
    caller does without the spin lock. }
  PageInNeeded = -1;

{ --- Creation and destruction ---------------------------------------- }

{ Keeps the peak up to date after a page was mapped (space lock held). }
procedure NoteCommittedPagesGrew(Space: PAddressSpace);
begin
  if Space^.CommittedPages > Space^.PeakCommittedPages then
    Space^.PeakCommittedPages := Space^.CommittedPages;
end;

{ Gives a node up with the reference its region held to its backing
  (Processes.MappedFiles defers the destruction at dispatch level). }
procedure FreeRegionNode(Node: PRegionNode);
begin
  if Node^.Region.Backing <> nil then
    ReleaseMappedFile(PMappedFile(Node^.Region.Backing), Node^.Region.BackingIsPrivate);
  FreeKernelMemory(Node);
end;

{ True if a thread may sleep here (reading a file's page). }
function CanSleep: Boolean;
begin
  Result := (CurrentPriorityLevel = PassiveLevel) and InterruptsAreEnabled;
end;

type
  TRandomizationSetting = (RandomizationNotRead, RandomizationOn, RandomizationOff);

var
  RandomizationSetting: TRandomizationSetting = RandomizationNotRead;

function AddressSpaceRandomizationIsOn: Boolean;
var
  Value: array[0..7] of Char;
begin
  if RandomizationSetting = RandomizationNotRead then
  begin
    RandomizationSetting := RandomizationOn;
    if GetKernelOptionValue('aslr', @Value[0], SizeOf(Value)) and
       ((Value[0] = 'o') and (Value[1] = 'f') and (Value[2] = 'f') and (Value[3] = #0)) then
      RandomizationSetting := RandomizationOff;
  end;
  Result := RandomizationSetting = RandomizationOn;
end;

function LayoutRandom(Limit: QWord): QWord;
begin
  Result := RandomBelow(Limit);
end;

function CreateAddressSpace(out Space: PAddressSpace): LongInt;
begin
  Space := PAddressSpace(AllocateZeroedKernelMemory(SizeOf(TAddressSpace)));
  if Space = nil then
    Exit(ErrorOutOfMemory);
  Space^.Root := CreateAddressSpaceRoot;
  if Space^.Root = 0 then
  begin
    FreeKernelMemory(Space);
    Space := nil;
    Exit(ErrorOutOfMemory);
  end;
  InitializeRegionTree(Space^.Regions);
  Space^.RegionLimit := DefaultRegionLimit;
  ChooseAddressLayout(AddressSpaceRandomizationIsOn, @LayoutRandom, Space^.Layout);
  Space^.NextLibraryAddress := Space^.Layout.LibraryWindowStart;
  InitializeSpinLock(Space^.Lock);
  Result := ErrorNone;
end;

procedure DestroyAddressSpace(Space: PAddressSpace);
begin
  if Space = nil then
    Exit;
  { Every user page and page table is released along with the root. }
  DestroyAddressSpaceRoot(Space^.Root);
  ClearRegionTree(Space^.Regions, @FreeRegionNode);
  ChangeSystemCommitCharge(-Int64(Space^.CommitChargePages));
  FreeKernelMemory(Space);
  DrainMappedFileReleases;
end;

procedure GetAddressSpaceUsage(Space: PAddressSpace; out Usage: TAddressSpaceUsage);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Usage.VirtualBytes := Space^.VirtualBytes;
  Usage.ResidentPages := Space^.CommittedPages;
  Usage.SharedPages := Space^.SharedPages;
  Usage.PeakResidentPages := Space^.PeakCommittedPages;
  Usage.RegionCount := Space^.Regions.Count;
  Usage.RegionLimit := Space^.RegionLimit;
  Usage.CommitChargePages := Space^.CommitChargePages;
  Usage.CommitLimitPages := Space^.CommitLimitPages;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

procedure SetCommitLimit(Space: PAddressSpace; LimitPages: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Space^.CommitLimitPages := LimitPages;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function CommitChargeOf(Space: PAddressSpace): QWord;
begin
  Result := Space^.CommitChargePages;
end;

type
  TElsewhereCount = record
    Space: PAddressSpace;
    Count: QWord;
  end;
  PElsewhereCount = ^TElsewhereCount;

procedure CountRegionPagesMappedElsewhere(Region: PUserRegion; Context: Pointer);
var
  Counter: PElsewhereCount;
  Offset: QWord;
  Physical: TPhysicalAddress;
begin
  if Region^.Backing = nil then
    Exit;
  Counter := PElsewhereCount(Context);
  Offset := 0;
  while Offset < Region^.Length do
  begin
    { The mapped file holds one reference, this mapping another. }
    if TranslateInAddressSpace(Counter^.Space^.Root, Region^.Start + Offset, Physical) and
       (PageUsageOf(Physical) = PageUsageProgramImage) and (PhysicalPageHolderCount(Physical) >= 3) then
      Inc(Counter^.Count);
    Offset := Offset + PageSize;
  end;
end;

function CountPagesMappedElsewhere(Space: PAddressSpace): QWord;
var
  PreviousLevel: TPriorityLevel;
  Counter: TElsewhereCount;
begin
  Counter.Space := Space;
  Counter.Count := 0;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  VisitRegions(Space^.Regions, @CountRegionPagesMappedElsewhere, @Counter);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  Result := Counter.Count;
end;

{ --- Commit charge ---------------------------------------------------- }

function RegionChargePages(const Region: TUserRegion): QWord;
var
  Pages: QWord;
begin
  Pages := Region.Length div PageSize;
  Result := 0;
  case Region.Kind of
    RegionKindAllocation, RegionKindStack, RegionKindThreadData:
      if Region.CommitsOnDemand then
        Result := Pages;
    RegionKindImage:
      if (Region.Attributes and RegionWritable) <> 0 then
        Result := Pages;
    RegionKindFileMapping:
      if Region.BackingIsPrivate and ((Region.Attributes and RegionWritable) <> 0) then
        Result := Pages;
  end;
end;

function ChargeCommitLocked(Space: PAddressSpace; Pages: QWord): LongInt;
begin
  if Pages = 0 then
    Exit(ErrorNone);
  if (Space^.CommitLimitPages <> 0) and (Space^.CommitChargePages + Pages > Space^.CommitLimitPages) then
    Exit(ErrorOutOfMemory);
  Space^.CommitChargePages := Space^.CommitChargePages + Pages;
  ChangeSystemCommitCharge(Int64(Pages));
  Result := ErrorNone;
end;

procedure UnchargeCommitLocked(Space: PAddressSpace; Pages: QWord);
begin
  if Pages > Space^.CommitChargePages then
    Pages := Space^.CommitChargePages;
  Space^.CommitChargePages := Space^.CommitChargePages - Pages;
  ChangeSystemCommitCharge(-Int64(Pages));
end;

procedure SetRegionLimit(Space: PAddressSpace; Limit: LongWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Space^.RegionLimit := Limit;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ --- Regions --------------------------------------------------------- }

{ The region holding Address, or nil. Caller holds the lock. }
function FindRegionLocked(Space: PAddressSpace; Address: QWord): PUserRegion;
begin
  Result := FindRegion(Space^.Regions, Address);
end;

function FindRegionAtOrAboveLocked(Space: PAddressSpace; Address: QWord): PUserRegion;
begin
  Result := FindRegionAtOrAbove(Space^.Regions, Address);
end;

{ The region starting exactly at Start, or nil. Caller holds the lock. }
function RegionStartingAtLocked(Space: PAddressSpace; Start: QWord): PUserRegion;
begin
  Result := FindRegion(Space^.Regions, Start);
  if (Result <> nil) and (Result^.Start <> Start) then
    Result := nil;
end;

{ A quarter of a small stack, at most StackReserveSize, at least a page. }
function StackReserveFor(Length: QWord): QWord;
begin
  Result := RoundDownToPage(Length div 4);
  if Result > StackReserveSize then
    Result := StackReserveSize;
  if Result < PageSize then
    Result := PageSize;
end;

function AddRegionRecordLocked(Space: PAddressSpace; const Template: TUserRegion): LongInt;
var
  Node: PRegionNode;
  Start: QWord;
  Length: QWord;
begin
  Start := Template.Start;
  Length := Template.Length;
  if (Length = 0) or ((Start and PageOffsetMask) <> 0) or ((Length and PageOffsetMask) <> 0) or
     (Start >= UserSpaceLimit) or (Length > UserSpaceLimit - Start) or (Start = 0) then
    Exit(ErrorInvalidArgument);
  if Space^.Regions.Count >= Space^.RegionLimit then
    Exit(ErrorOutOfMemory);
  if RangeOverlapsRegion(Space^.Regions, Start, Length) then
    Exit(ErrorExists);

  Node := PRegionNode(AllocateZeroedKernelMemory(SizeOf(TRegionNode)));
  if Node = nil then
    Exit(ErrorOutOfMemory);
  Node^.Region := Template;
  if (Template.Kind = RegionKindStack) and Template.CommitsOnDemand then
    Node^.Region.ReserveBytes := StackReserveFor(Length);
  Result := ChargeCommitLocked(Space, RegionChargePages(Node^.Region));
  if Result <> ErrorNone then
  begin
    FreeKernelMemory(Node);
    Exit;
  end;
  InsertRegionNode(Space^.Regions, Node);
  if Template.Kind <> RegionKindStackGuard then
    Space^.VirtualBytes := Space^.VirtualBytes + Length;
  Result := ErrorNone;
end;

function AddRegionLocked(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
var
  Template: TUserRegion;
begin
  FillMemory(@Template, SizeOf(Template), 0);
  Template.Start := Start;
  Template.Length := Length;
  Template.Attributes := Attributes;
  Template.Kind := Kind;
  Template.CommitsOnDemand := CommitsOnDemand;
  Result := AddRegionRecordLocked(Space, Template);
end;

function AddRegion(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := AddRegionLocked(Space, Start, Length, Attributes, Kind, CommitsOnDemand);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AddRegionRecord(Space: PAddressSpace; const Template: TUserRegion): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := AddRegionRecordLocked(Space, Template);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function FindFreeRangeLocked(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;
begin
  Result := FindFreeGap(Space^.Regions, Length, Base, Limit, Start);
end;

function FindFreeRange(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := FindFreeRangeLocked(Space, Length, Base, Limit, Start);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ Room in the run time allocation area, first fit from Hint upwards,
  then from the area's start (a random hint must not make memory run
  out sooner). Caller holds the lock. }
function FindAllocationRangeLocked(Space: PAddressSpace; Length, Hint: QWord; out Start: QWord): Boolean;
begin
  if (Hint < UserAllocationBase) or (Hint >= UserAllocationLimit) then
    Hint := UserAllocationBase;
  Result := FindFreeRangeLocked(Space, Length, Hint, UserAllocationLimit, Start);
  if not Result and (Hint > UserAllocationBase) then
    Result := FindFreeRangeLocked(Space, Length, UserAllocationBase, UserAllocationLimit, Start);
end;

{ Unmaps and frees the pages of [Start, Start + Length); returns how
  many there were. Pages of mapped files and sections were counted as
  shared. }
function ReleaseRegionPages(Space: PAddressSpace; Start, Length: QWord): QWord;
var
  Offset: QWord;
  RunLength: LongWord;
  RunIndex: LongWord;
  PhysicalPages: TPhysicalPageRun;
  Usage: TPageUsage;
begin
  Result := 0;
  Offset := 0;
  while Offset < Length do
  begin
    RunLength := MaximumPagesPerRun;
    if (Length - Offset + PageSize - 1) div PageSize < RunLength then
      RunLength := LongWord((Length - Offset + PageSize - 1) div PageSize);
    UnmapPageRunInAddressSpace(Space^.Root, Start + Offset, RunLength, PhysicalPages);
    for RunIndex := 0 to RunLength - 1 do
      if PhysicalPages[RunIndex] <> 0 then
      begin
        Usage := PageUsageOf(PhysicalPages[RunIndex]);
        if ((Usage = PageUsageProgramImage) or (Usage = PageUsageSection)) and (Space^.SharedPages > 0) then
          Dec(Space^.SharedPages);
        FreePhysicalPage(PhysicalPages[RunIndex]);
        Dec(Space^.CommittedPages);
        Inc(Result);
      end;
    Offset := Offset + QWord(RunLength) * PageSize;
  end;
end;

procedure ReleaseRegionPagesLocked(Space: PAddressSpace; Start, Length: QWord);
begin
  ReleaseRegionPages(Space, Start, Length);
end;

{ Gives back the pages of the region starting at Start and takes it out
  of the tree (nothing if there is none). Caller holds the lock. }
procedure RemoveRegionLocked(Space: PAddressSpace; Start: QWord);
var
  Node: PRegionNode;
begin
  Node := RemoveRegionNode(Space^.Regions, Start);
  if Node = nil then
    Exit;
  ReleaseRegionPages(Space, Node^.Region.Start, Node^.Region.Length);
  UnchargeCommitLocked(Space, RegionChargePages(Node^.Region));
  if Node^.Region.Kind <> RegionKindStackGuard then
    Space^.VirtualBytes := Space^.VirtualBytes - Node^.Region.Length;
  FreeRegionNode(Node);
end;

procedure RemoveAllocationPieceLocked(Space: PAddressSpace; Start: QWord);
begin
  RemoveRegionLocked(Space, Start);
end;

function RemoveAllocationLocked(Space: PAddressSpace; Start: QWord): Boolean;
var
  Region: PUserRegion;
  Position: QWord;
begin
  Region := RegionStartingAtLocked(Space, Start);
  if Region = nil then
    Exit(False);
  Result := True;
  if Region^.AllocationBase <> Start then
  begin
    RemoveRegionLocked(Space, Start);
    Exit;
  end;
  { The pieces lie one after another. }
  Position := Start;
  repeat
    Region := RegionStartingAtLocked(Space, Position);
    if (Region = nil) or (Region^.AllocationBase <> Start) then
      Break;
    Position := Region^.Start + Region^.Length;
    RemoveRegionLocked(Space, Region^.Start);
  until False;
end;

function SplitRegionLocked(Space: PAddressSpace; Address: QWord): LongInt;
var
  Region: PUserRegion;
  Node: PRegionNode;
begin
  Region := FindRegionLocked(Space, Address);
  if (Region = nil) or (Region^.Start = Address) then
    Exit(ErrorNone);
  if Space^.Regions.Count >= Space^.RegionLimit then
    Exit(ErrorOutOfMemory);
  Node := PRegionNode(AllocateZeroedKernelMemory(SizeOf(TRegionNode)));
  if Node = nil then
    Exit(ErrorOutOfMemory);
  SplitRegionAt(Space^.Regions, Address, Node);
  if Node^.Region.Backing <> nil then
    ReferenceMappedFile(PMappedFile(Node^.Region.Backing), Node^.Region.BackingIsPrivate);
  Result := ErrorNone;
end;

procedure MergeRegionsLocked(Space: PAddressSpace; First, Finish: QWord);
begin
  MergeRange(Space^.Regions, First, Finish, @FreeRegionNode);
end;

function AddStackGuardLocked(Space: PAddressSpace; StackStart: QWord): LongInt; forward;

{ Finds room for GuardBytes + Length and adds a region for the upper
  Length bytes (with a stack guard below it for stacks). }
function AllocateWithGuard(Space: PAddressSpace; Length, GuardBytes: QWord; Kind: TRegionKind;
  OwnerThreadId: QWord; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Hint: QWord;
begin
  Start := 0;
  if (Length = 0) or (Length > UserAllocationLimit - UserAllocationBase) then
    Exit(ErrorInvalidArgument);
  Length := RoundUpToPage(Length);
  { Thread stacks and thread data each go to a place of their own;
    heap chunks and the like follow one another from the allocation
    base. }
  if Kind in [RegionKindStack, RegionKindThreadData] then
    Hint := ChooseThreadMemoryAddress(Space^.Layout, @LayoutRandom)
  else
    Hint := Space^.Layout.AllocationBase;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  { The guard needs a region too. }
  if (Kind = RegionKindStack) and (Space^.Regions.Count + 1 >= Space^.RegionLimit) then
    Result := ErrorOutOfMemory
  else if not FindAllocationRangeLocked(Space, GuardBytes + Length, Hint, Start) then
    Result := ErrorOutOfMemory
  else
  begin
    Start := Start + GuardBytes;
    Result := AddRegionLocked(Space, Start, Length, RegionReadable or RegionWritable, Kind, True);
    { Heap memory may be decommitted or protected in parts. }
    if (Result = ErrorNone) and (Kind = RegionKindAllocation) then
      RegionStartingAtLocked(Space, Start)^.AllocationBase := Start;
    if (Result = ErrorNone) and (Kind = RegionKindStack) then
    begin
      Result := AddStackGuardLocked(Space, Start);
      if Result <> ErrorNone then
        RemoveRegionLocked(Space, Start);
    end;
    if (Result = ErrorNone) and (OwnerThreadId <> 0) then
    begin
      Region := RegionStartingAtLocked(Space, Start);
      Region^.OwnerThreadId := OwnerThreadId;
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    Start := 0;
end;

function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
begin
  Result := AllocateWithGuard(Space, Length, 0, RegionKindAllocation, 0, Start);
end;

function AllocateThreadOwnedUserMemory(Space: PAddressSpace; Length: QWord; OwnerThreadId: QWord;
  out Start: QWord): LongInt;
begin
  Result := AllocateWithGuard(Space, Length, 0, RegionKindAllocation, OwnerThreadId, Start);
end;

function AllocateGuardedUserMemory(Space: PAddressSpace; Length: QWord; Kind: TRegionKind;
  out Start: QWord): LongInt;
begin
  if Kind = RegionKindStack then
    Result := AllocateWithGuard(Space, Length, StackGuardSize, Kind, 0, Start)
  else
    Result := AllocateWithGuard(Space, Length, PageSize, Kind, 0, Start);
end;

{ Removes the region starting at Start; AnyKind allows other kinds than
  run time allocations, device memory and sections. }
function RemoveRegion(Space: PAddressSpace; Start: QWord; AnyKind: Boolean): LongInt;
var
  Region: PUserRegion;
  PreviousLevel: TPriorityLevel;
  IsStack: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := RegionStartingAtLocked(Space, Start);
  if (Region = nil) or
     (not AnyKind and not (Region^.Kind in [RegionKindAllocation, RegionKindDevice, RegionKindSection,
       RegionKindFileMapping])) then
  begin
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    Exit(ErrorInvalidArgument);
  end;

  IsStack := Region^.Kind = RegionKindStack;
  RemoveAllocationLocked(Space, Start);
  { A stack's guard goes with it. }
  if IsStack and (Start >= StackGuardSize) then
  begin
    Region := RegionStartingAtLocked(Space, Start - StackGuardSize);
    if (Region <> nil) and (Region^.Kind = RegionKindStackGuard) and
       (Region^.Length = StackGuardSize) then
      RemoveRegionLocked(Space, Start - StackGuardSize);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if CurrentPriorityLevel = PassiveLevel then
    DrainMappedFileReleases;
  Result := ErrorNone;
end;

function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;
begin
  Result := RemoveRegion(Space, Start, False);
end;

procedure ReleaseThreadOwnedMemory(Space: PAddressSpace; Start: QWord; OwnerThreadId: QWord);
var
  Region: PUserRegion;
  PreviousLevel: TPriorityLevel;
begin
  if (Start = 0) or (OwnerThreadId = 0) then
    Exit;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := RegionStartingAtLocked(Space, Start);
  if (Region <> nil) and (Region^.Kind = RegionKindAllocation) and (Region^.OwnerThreadId = OwnerThreadId) then
    RemoveAllocationLocked(Space, Start);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

const
  OwnedRegionBatch = 32;

type
  TOwnedRegionSearch = record
    OwnerThreadId: QWord;
    Starts: array[0..OwnedRegionBatch - 1] of QWord;
    Count: Integer;
  end;
  POwnedRegionSearch = ^TOwnedRegionSearch;

procedure NoteOwnedRegion(Region: PUserRegion; Context: Pointer);
var
  Search: POwnedRegionSearch;
begin
  Search := POwnedRegionSearch(Context);
  if (Region^.Kind = RegionKindAllocation) and (Region^.OwnerThreadId = Search^.OwnerThreadId) and
     ((Region^.AllocationBase = 0) or (Region^.AllocationBase = Region^.Start)) and
     (Search^.Count < OwnedRegionBatch) then
  begin
    Search^.Starts[Search^.Count] := Region^.Start;
    Inc(Search^.Count);
  end;
end;

procedure ReleaseAllThreadOwnedMemory(Space: PAddressSpace; OwnerThreadId: QWord);
var
  Search: TOwnedRegionSearch;
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  if OwnerThreadId = 0 then
    Exit;
  Search.OwnerThreadId := OwnerThreadId;
  { The tree must not change while it is walked: a batch at a time. }
  repeat
    Search.Count := 0;
    PreviousLevel := AcquireSpinLock(Space^.Lock);
    VisitRegions(Space^.Regions, @NoteOwnedRegion, @Search);
    for Index := 0 to Search.Count - 1 do
      RemoveAllocationLocked(Space, Search.Starts[Index]);
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
  until Search.Count < OwnedRegionBatch;
end;

function ReleaseUserRegion(Space: PAddressSpace; Start: QWord): LongInt;
begin
  Result := RemoveRegion(Space, Start, True);
end;

function MapDeviceIntoAddressSpace(Space: PAddressSpace; Physical: TPhysicalAddress; Length: QWord;
  Writable, WriteCombining: Boolean; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Attributes: LongWord;
  Mapping: LongWord;
  Offset: QWord;
begin
  Start := 0;
  if (Length = 0) or ((Length and PageOffsetMask) <> 0) or ((Physical and PageOffsetMask) <> 0) then
    Exit(ErrorInvalidArgument);
  Attributes := RegionReadable;
  Mapping := MappingUser or MappingDevice;
  if Writable then
  begin
    Attributes := Attributes or RegionWritable;
    Mapping := Mapping or MappingWritable;
  end;
  if WriteCombining then
    Mapping := Mapping or MappingWriteCombining
  else
    Mapping := Mapping or MappingUncached;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not FindAllocationRangeLocked(Space, Length, Space^.Layout.AllocationBase, Start) then
    Result := ErrorOutOfMemory
  else
    Result := AddRegionLocked(Space, Start, Length, Attributes, RegionKindDevice, False);
  if Result = ErrorNone then
  begin
    Offset := 0;
    while Offset < Length do
    begin
      if not MapPageInAddressSpace(Space^.Root, Start + Offset, Physical + Offset, Mapping) then
      begin
        Result := ErrorOutOfMemory;
        Break;
      end;
      Offset := Offset + PageSize;
    end;
    if Result <> ErrorNone then
      RemoveRegionLocked(Space, Start);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    Start := 0;
end;

function MapPagesIntoAddressSpace(Space: PAddressSpace; Pages: PPhysicalAddress; PageCount: QWord;
  Writable: Boolean; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Attributes: LongWord;
  Mapping: LongWord;
  Index: QWord;
  Length: QWord;
begin
  Start := 0;
  if PageCount = 0 then
    Exit(ErrorInvalidArgument);
  Length := PageCount shl PageShift;
  Attributes := RegionReadable;
  Mapping := MappingUser;
  if Writable then
  begin
    Attributes := Attributes or RegionWritable;
    Mapping := Mapping or MappingWritable;
  end;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not FindAllocationRangeLocked(Space, Length, Space^.Layout.AllocationBase, Start) then
    Result := ErrorOutOfMemory
  else
    Result := AddRegionLocked(Space, Start, Length, Attributes, RegionKindSection, False);
  if Result = ErrorNone then
  begin
    for Index := 0 to PageCount - 1 do
    begin
      if not MapPageInAddressSpace(Space^.Root, Start + (Index shl PageShift), Pages[Index], Mapping) then
      begin
        Result := ErrorOutOfMemory;
        Break;
      end;
      { Released (as an ordinary page) when the region goes. }
      ReferencePhysicalPage(Pages[Index]);
      Inc(Space^.CommittedPages);
      Inc(Space^.SharedPages);
      NoteCommittedPagesGrew(Space);
    end;
    if Result <> ErrorNone then
      RemoveRegionLocked(Space, Start);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    Start := 0;
end;

{ --- Pages ----------------------------------------------------------- }

function MappingAttributesFor(Attributes: LongWord): LongWord;
begin
  Result := MappingUser;
  if (Attributes and RegionWritable) <> 0 then
    Result := Result or MappingWritable;
  if (Attributes and RegionExecutable) <> 0 then
    Result := Result or MappingExecutable;
end;

{ How a page of Region is mapped: as its attributes say, or for the
  kernel only when the program may not touch it. }
function RegionMapping(Region: PUserRegion): LongWord;
begin
  if Region^.IsGuard or ((Region^.Attributes and RegionReadable) = 0) then
    Result := MappingUser or MappingNoAccess
  else
    Result := MappingAttributesFor(Region^.Attributes);
end;

{ Maps a fresh zero filled page for Region at PageAddress. }
function CommitPageLocked(Space: PAddressSpace; PageAddress: QWord; Region: PUserRegion): LongInt;
var
  PhysicalAddress: TPhysicalAddress;
begin
  PhysicalAddress := AllocateZeroedPhysicalPage(PageUsageUserMemory);
  if PhysicalAddress = 0 then
    Exit(ErrorOutOfMemory);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, PhysicalAddress, RegionMapping(Region)) then
  begin
    FreePhysicalPage(PhysicalAddress);
    Exit(ErrorOutOfMemory);
  end;
  Inc(Space^.CommittedPages);
  NoteCommittedPagesGrew(Space);
  Result := ErrorNone;
end;

function CommitPage(Space: PAddressSpace; Address: QWord; Attributes: LongWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Existing: TPhysicalAddress;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  if Region = nil then
    Result := ErrorBadAddress
  else if TranslateInAddressSpace(Space^.Root, RoundDownToPage(Address), Existing) then
    Result := ErrorNone
  else
    Result := CommitPageLocked(Space, RoundDownToPage(Address), Region);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ Maps the file's page Physical for the backed Region at PageAddress,
  taking a reference to it: copy on write if the region is private (the
  mark stays when it is read-only, so a later change of protection
  still copies), read-only shared otherwise. }
function MapBackedPageLocked(Space: PAddressSpace; PageAddress: QWord; Region: PUserRegion;
  Physical: TPhysicalAddress): LongInt;
var
  Mapping: LongWord;
begin
  Mapping := RegionMapping(Region);
  if Region^.BackingIsPrivate then
    Mapping := (Mapping and not MappingWritable) or MappingCopyOnWrite
  else
    Mapping := Mapping and not MappingWritable;
  ReferencePhysicalPage(Physical);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, Physical, Mapping) then
  begin
    FreePhysicalPage(Physical);
    Exit(ErrorOutOfMemory);
  end;
  Inc(Space^.CommittedPages);
  Inc(Space^.SharedPages);
  NoteCommittedPagesGrew(Space);
  Result := ErrorNone;
end;

{ The file page behind PageAddress of the backed Region. }
function BackingPageIndex(Region: PUserRegion; PageAddress: QWord): QWord;
begin
  Result := (Region^.BackingOffset + (PageAddress - Region^.Start)) div PageSize;
end;

function MapSharedPage(Space: PAddressSpace; Address: QWord; Physical: TPhysicalAddress;
  Attributes: LongWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Mapping: LongWord;
begin
  Mapping := MappingAttributesFor(Attributes);
  if (Attributes and RegionWritable) <> 0 then
    Mapping := Mapping or MappingCopyOnWrite;
  ReferencePhysicalPage(Physical);
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if MapPageInAddressSpace(Space^.Root, RoundDownToPage(Address), Physical, Mapping) then
  begin
    Inc(Space^.CommittedPages);
    Inc(Space^.SharedPages);
    NoteCommittedPagesGrew(Space);
    Result := ErrorNone;
  end
  else
    Result := ErrorOutOfMemory;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    FreePhysicalPage(Physical);
end;

{ Gives the process its own, writable copy of a copy on write page (or,
  if it is a private page nobody else holds any more, just makes it
  writable). A page of a mapped file or image section is always copied,
  so a process's own pages are always PageUsageUserMemory. }
function BreakCopyOnWriteLocked(Space: PAddressSpace; PageAddress: QWord;
  Shared: TPhysicalAddress): LongInt;
var
  Region: PUserRegion;
  Copy: TPhysicalAddress;
  WasShared: Boolean;
begin
  Region := FindRegionLocked(Space, PageAddress);
  if Region = nil then
    Exit(ErrorBadAddress);
  WasShared := PageUsageOf(Shared) <> PageUsageUserMemory;
  if WasShared or PhysicalPageIsShared(Shared) then
  begin
    Copy := AllocatePhysicalPage(PageUsageUserMemory);
    if Copy = 0 then
      Exit(ErrorOutOfMemory);
    CopyMemory(PhysicalToVirtual(Copy), PhysicalToVirtual(Shared), PageSize);
  end
  else
    Copy := Shared;
  { Unmapping invalidates the old translation everywhere; the copy then
    replaces this space's reference to the shared page. }
  UnmapPageInAddressSpace(Space^.Root, PageAddress);
  if Copy <> Shared then
    FreePhysicalPage(Shared);
  { The process's own page from now on, whether copied or not. }
  if WasShared and (Space^.SharedPages > 0) then
    Dec(Space^.SharedPages);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, Copy, RegionMapping(Region)) then
  begin
    FreePhysicalPage(Copy);
    Dec(Space^.CommittedPages);
    Exit(ErrorOutOfMemory);
  end;
  Result := ErrorNone;
end;

procedure ApplyRegionProtectionLocked(Space: PAddressSpace; Start, Length: QWord);
var
  Region: PUserRegion;
  Mapping: LongWord;
  PageMapping: LongWord;
  Offset: QWord;
  Physical: TPhysicalAddress;
  IsCopyOnWrite: Boolean;
begin
  Region := FindRegionLocked(Space, Start);
  if (Region = nil) or (Region^.Kind = RegionKindDevice) then
    Exit;
  Mapping := RegionMapping(Region);
  Offset := 0;
  while Offset < Length do
  begin
    if QueryPageInAddressSpace(Space^.Root, Start + Offset, Physical, IsCopyOnWrite) then
    begin
      Physical := RoundDownToPage(Physical);
      PageMapping := Mapping;
      { A shared page stays marked, so a write still copies it. }
      if IsCopyOnWrite then
        PageMapping := (PageMapping and not MappingWritable) or MappingCopyOnWrite
      else if (Region^.Backing <> nil) and not Region^.BackingIsPrivate then
        PageMapping := PageMapping and not MappingWritable;
      UnmapPageInAddressSpace(Space^.Root, Start + Offset);
      if not MapPageInAddressSpace(Space^.Root, Start + Offset, Physical, PageMapping) then
      begin
        { No page table for it any more cannot happen (the page was
          just there); count it gone rather than leak the count. }
        FreePhysicalPage(Physical);
        Dec(Space^.CommittedPages);
      end;
    end;
    Offset := Offset + PageSize;
  end;
end;

{ True if the region allows the access the fault code describes. }
function AccessAllowed(Region: PUserRegion; ErrorCode: QWord): Boolean;
begin
  Result := not Region^.IsGuard and ((Region^.Attributes and RegionReadable) <> 0) and
    (((ErrorCode and PageFaultWasWrite) = 0) or ((Region^.Attributes and RegionWritable) <> 0)) and
    (((ErrorCode and PageFaultWasFetch) = 0) or ((Region^.Attributes and RegionExecutable) <> 0));
end;

{ Takes the guard off the page at PageAddress (the whole region if it
  cannot be split for lack of regions). }
procedure ClearGuardLocked(Space: PAddressSpace; PageAddress: QWord);
var
  Region: PUserRegion;
begin
  if (SplitRegionLocked(Space, PageAddress) = ErrorNone) and
     (SplitRegionLocked(Space, PageAddress + PageSize) = ErrorNone) then
  begin
    Region := FindRegionLocked(Space, PageAddress);
    Region^.IsGuard := False;
    ApplyRegionProtectionLocked(Space, PageAddress, PageSize);
  end
  else
  begin
    Region := FindRegionLocked(Space, PageAddress);
    Region^.IsGuard := False;
    ApplyRegionProtectionLocked(Space, Region^.Start, Region^.Length);
  end;
  MergeRegionsLocked(Space, PageAddress, PageAddress + PageSize);
end;

function ResolveUserPageFaultWithGuard(Space: PAddressSpace; Address: QWord; ErrorCode: QWord;
  out HitGuard: Boolean): Boolean;
var
  Region: PUserRegion;
  PreviousLevel: TPriorityLevel;
  PhysicalAddress: TPhysicalAddress;
  PageAddress: QWord;
  IsCopyOnWrite: Boolean;
  Backing: PMappedFile;
  BackingIsPrivate: Boolean;
  PageIndex: QWord;
begin
  Result := False;
  HitGuard := False;
  if (Space = nil) or (Address >= UserSpaceLimit) then
    Exit;
  PageAddress := RoundDownToPage(Address);
  Backing := nil;
  BackingIsPrivate := False;
  PageIndex := 0;

  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  if Region = nil then
    { Nothing there. }
  else if Region^.IsGuard then
  begin
    { A guard's first touch by the program: the exception tells it, and
      the page is an ordinary one from now on. }
    if (ErrorCode and PageFaultFromUser) <> 0 then
    begin
      ClearGuardLocked(Space, PageAddress);
      HitGuard := True;
    end;
  end
  else if not AccessAllowed(Region, ErrorCode) then
    { A protection violation. }
  else if (ErrorCode and PageFaultWasPresent) <> 0 then
  begin
    { A write to a present page is fine if it is a copy on write one
      (or another thread just copied it). }
    if ((ErrorCode and PageFaultWasWrite) <> 0) and
       QueryPageInAddressSpace(Space^.Root, PageAddress, PhysicalAddress, IsCopyOnWrite) then
    begin
      if IsCopyOnWrite then
        Result := BreakCopyOnWriteLocked(Space, PageAddress, RoundDownToPage(PhysicalAddress)) = ErrorNone
      else
        Result := True;
    end;
  end
  else if TranslateInAddressSpace(Space^.Root, PageAddress, PhysicalAddress) then
    { Another thread of the process provided the page meanwhile. }
    Result := True
  else if Region^.Backing <> nil then
  begin
    PageIndex := BackingPageIndex(Region, PageAddress);
    if ResidentMappedFilePage(PMappedFile(Region^.Backing), PageIndex, PhysicalAddress) then
      Result := MapBackedPageLocked(Space, PageAddress, Region, PhysicalAddress) = ErrorNone
    else
    begin
      { Read from the file without the lock; the touch is then tried
        again and finds the page. }
      Backing := PMappedFile(Region^.Backing);
      BackingIsPrivate := Region^.BackingIsPrivate;
      ReferenceMappedFile(Backing, BackingIsPrivate);
    end;
  end
  { An armed stack reserve is not provided: that is a stack overflow,
    for the exception dispatcher. }
  else if Region^.CommitsOnDemand and
     ((Address >= Region^.Start + Region^.ReserveBytes) or Region^.ReserveInUse) then
    Result := CommitPageLocked(Space, PageAddress, Region) = ErrorNone;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);

  if Backing <> nil then
  begin
    if CanSleep then
      Result := LoadMappedFilePage(Backing, PageIndex) = ErrorNone;
    ReleaseMappedFile(Backing, BackingIsPrivate);
  end;
end;

function ResolveUserPageFault(Space: PAddressSpace; Address: QWord; ErrorCode: QWord): Boolean;
var
  HitGuard: Boolean;
begin
  Result := ResolveUserPageFaultWithGuard(Space, Address, ErrorCode, HitGuard);
end;

function PageInBackedAddress(Space: PAddressSpace; Address: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Backing: PMappedFile;
  BackingIsPrivate: Boolean;
  PageIndex: QWord;
begin
  Backing := nil;
  BackingIsPrivate := False;
  PageIndex := 0;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  if (Region <> nil) and (Region^.Backing <> nil) then
  begin
    Backing := PMappedFile(Region^.Backing);
    BackingIsPrivate := Region^.BackingIsPrivate;
    PageIndex := BackingPageIndex(Region, RoundDownToPage(Address));
    ReferenceMappedFile(Backing, BackingIsPrivate);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Backing = nil then
    Exit(ErrorBadAddress);
  Result := LoadMappedFilePage(Backing, PageIndex);
  ReleaseMappedFile(Backing, BackingIsPrivate);
end;

function ValidateUserRange(Space: PAddressSpace; Address, Length: QWord; NeedWrite: Boolean): Boolean;
var
  Position: QWord;
  Finish: QWord;
  Region: PUserRegion;
  PreviousLevel: TPriorityLevel;
begin
  Result := False;
  if Space = nil then
    Exit;
  if Length = 0 then
    Exit(True);
  if (Address >= UserSpaceLimit) or (Length > UserSpaceLimit - Address) then
    Exit;

  Position := Address;
  Finish := Address + Length;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := True;
  while Position < Finish do
  begin
    Region := FindRegionLocked(Space, Position);
    { Stack guards, reserved and no-access pages and guards have no
      read access. }
    if (Region = nil) or Region^.IsGuard or ((Region^.Attributes and RegionReadable) = 0) or
       (NeedWrite and ((Region^.Attributes and RegionWritable) = 0)) then
    begin
      Result := False;
      Break;
    end;
    Position := Region^.Start + Region^.Length;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ Returns a kernel pointer to Address in Space, providing the page if it
  is an on-demand page that has not been touched yet, and giving the
  process its own copy first if it is to be written and copy on write.
  PageInNeeded if the page must be read from its file first. }
function PageInWindow(Space: PAddressSpace; Address: QWord; ForWrite: Boolean;
  out Window: PByte): LongInt;
var
  PhysicalAddress: TPhysicalAddress;
  Region: PUserRegion;
  IsCopyOnWrite: Boolean;
begin
  Window := nil;
  { Device memory is not reached through the physical memory window. }
  Region := FindRegionLocked(Space, Address);
  if (Region <> nil) and (Region^.Kind = RegionKindDevice) then
    Exit(ErrorBadAddress);
  if ForWrite and QueryPageInAddressSpace(Space^.Root, Address, PhysicalAddress, IsCopyOnWrite) and
     IsCopyOnWrite then
  begin
    Result := BreakCopyOnWriteLocked(Space, RoundDownToPage(Address), RoundDownToPage(PhysicalAddress));
    if Result <> ErrorNone then
      Exit;
  end;
  if not TranslateInAddressSpace(Space^.Root, Address, PhysicalAddress) then
  begin
    if (Region = nil) or (Region^.Kind = RegionKindStackGuard) or
       ((Region^.Backing = nil) and not Region^.CommitsOnDemand and (Region^.Kind = RegionKindAllocation)) then
      Exit(ErrorBadAddress);
    if Region^.Backing <> nil then
    begin
      if not ResidentMappedFilePage(PMappedFile(Region^.Backing),
         BackingPageIndex(Region, RoundDownToPage(Address)), PhysicalAddress) then
        Exit(PageInNeeded);
      Result := MapBackedPageLocked(Space, RoundDownToPage(Address), Region, PhysicalAddress);
      if Result <> ErrorNone then
        Exit;
      { Mapped copy on write: a write copies it now. }
      Exit(PageInWindow(Space, Address, ForWrite, Window));
    end;
    Result := CommitPageLocked(Space, RoundDownToPage(Address), Region);
    if Result <> ErrorNone then
      Exit;
    if not TranslateInAddressSpace(Space^.Root, Address, PhysicalAddress) then
      Exit(ErrorBadAddress);
  end;
  Window := PByte(PhysicalToVirtual(PhysicalAddress));
  Result := ErrorNone;
end;

{ PageInWindow under the lock, reading the page from its file without
  the lock when it must (and if this thread may sleep). Returns with the
  lock held on success. }
function PageInWindowLocking(Space: PAddressSpace; Address: QWord; ForWrite: Boolean;
  out Window: PByte; out PreviousLevel: TPriorityLevel): LongInt;
begin
  repeat
    PreviousLevel := AcquireSpinLock(Space^.Lock);
    Result := PageInWindow(Space, Address, ForWrite, Window);
    if Result = ErrorNone then
      Exit;
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    if Result <> PageInNeeded then
      Exit;
    if not CanSleep then
      Exit(ErrorBadAddress);
    Result := PageInBackedAddress(Space, Address);
  until Result <> ErrorNone;
end;

function TransferWithAddressSpace(Space: PAddressSpace; Address: QWord; KernelBuffer: PByte;
  Length: QWord; IsWrite: Boolean): LongInt;
var
  Window: PByte;
  ChunkBytes: QWord;
  PreviousLevel: TPriorityLevel;
begin
  while Length > 0 do
  begin
    ChunkBytes := PageSize - (Address and PageOffsetMask);
    if ChunkBytes > Length then
      ChunkBytes := Length;
    { The page must not go away while it is being copied. }
    Result := PageInWindowLocking(Space, Address, IsWrite, Window, PreviousLevel);
    if Result <> ErrorNone then
      Exit;
    if IsWrite then
    begin
      if KernelBuffer <> nil then
        CopyMemory(Window, KernelBuffer, ChunkBytes)
      else
        ZeroMemory(Window, ChunkBytes);
    end
    else
      CopyMemory(KernelBuffer, Window, ChunkBytes);
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    if KernelBuffer <> nil then
      KernelBuffer := KernelBuffer + ChunkBytes;
    Address := Address + ChunkBytes;
    Length := Length - ChunkBytes;
  end;
  Result := ErrorNone;
end;

function WriteIntoAddressSpace(Space: PAddressSpace; Address: QWord; Source: Pointer;
  Length: QWord): LongInt;
begin
  Result := TransferWithAddressSpace(Space, Address, PByte(Source), Length, True);
end;

function ReadFromAddressSpace(Space: PAddressSpace; Address: QWord; Destination: Pointer;
  Length: QWord): LongInt;
begin
  Result := TransferWithAddressSpace(Space, Address, PByte(Destination), Length, False);
end;

function WritablePageWindow(Space: PAddressSpace; Address: QWord; out Window: PByte): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := PageInWindowLocking(Space, RoundDownToPage(Address), True, Window, PreviousLevel);
  if Result = ErrorNone then
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function OpenStackReserve(Space: PAddressSpace; Address: QWord; StackStart: QWord;
  out RegionStart: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  Result := False;
  RegionStart := 0;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  if Region <> nil then
  begin
    if (Region^.Kind = RegionKindStack) and (Region^.Start = StackStart) and not Region^.ReserveInUse and
       (Address < Region^.Start + Region^.ReserveBytes) then
    begin
      Region^.ReserveInUse := True;
      RegionStart := Region^.Start;
      Result := True;
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function RearmStackReserve(Space: PAddressSpace; RegionStart, StackPointer: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  Result := True;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := RegionStartingAtLocked(Space, RegionStart);
  if Region <> nil then
  begin
    if Region^.ReserveInUse then
    begin
      if StackPointer >= Region^.Start + Region^.ReserveBytes + StackReserveRearmDistance then
      begin
        ReleaseRegionPages(Space, Region^.Start, Region^.ReserveBytes);
        Region^.ReserveInUse := False;
      end
      else
        Result := False;
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ The stack region starting at StackStart, or nil. Caller holds the
  lock. }
function StackRegionLocked(Space: PAddressSpace; StackStart: QWord): PUserRegion;
begin
  Result := RegionStartingAtLocked(Space, StackStart);
  if (Result <> nil) and (Result^.Kind <> RegionKindStack) then
    Result := nil;
end;

function OpenStackReserveOfRegion(Space: PAddressSpace; StackStart: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := StackRegionLocked(Space, StackStart);
  Result := (Region <> nil) and not Region^.ReserveInUse and (Region^.ReserveBytes > 0);
  if Result then
    Region^.ReserveInUse := True;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function StackReserveTop(Space: PAddressSpace; StackStart: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := StackRegionLocked(Space, StackStart);
  if Region <> nil then
    Result := Region^.Start + Region^.ReserveBytes
  else
    Result := 0;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AddressIsInUsableRegion(Space: PAddressSpace; Address: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  Result := (Region <> nil) and (Region^.Kind <> RegionKindStackGuard);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AddStackGuardLocked(Space: PAddressSpace; StackStart: QWord): LongInt;
begin
  if StackStart < StackGuardSize + PageSize then
    Exit(ErrorInvalidArgument);
  Result := AddRegionLocked(Space, StackStart - StackGuardSize, StackGuardSize, 0,
    RegionKindStackGuard, False);
end;

function AddStackGuard(Space: PAddressSpace; StackStart: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := AddStackGuardLocked(Space, StackStart);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

end.
