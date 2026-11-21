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
{ Changes the most regions Space may have (existing ones stay). }
procedure SetRegionLimit(Space: PAddressSpace; Limit: LongWord);

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

implementation

uses
  Runtime.Memory,
  Kernel.Options,
  Kernel.Random,
  Kernel.PriorityLevel,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.Arch.PageTables;

const
  PageFaultWasPresent = 1;
  PageFaultWasWrite = 2;

{ --- Creation and destruction ---------------------------------------- }

{ Keeps the peak up to date after a page was mapped (space lock held). }
procedure NoteCommittedPagesGrew(Space: PAddressSpace);
begin
  if Space^.CommittedPages > Space^.PeakCommittedPages then
    Space^.PeakCommittedPages := Space^.CommittedPages;
end;

procedure FreeRegionNode(Node: PRegionNode);
begin
  FreeKernelMemory(Node);
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
  FreeKernelMemory(Space);
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
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
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

function AddRegionLocked(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
var
  Node: PRegionNode;
begin
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
  Node^.Region.Start := Start;
  Node^.Region.Length := Length;
  Node^.Region.Attributes := Attributes;
  Node^.Region.Kind := Kind;
  Node^.Region.CommitsOnDemand := CommitsOnDemand;
  if (Kind = RegionKindStack) and CommitsOnDemand then
    Node^.Region.ReserveBytes := StackReserveFor(Length);
  InsertRegionNode(Space^.Regions, Node);
  if Kind <> RegionKindStackGuard then
    Space^.VirtualBytes := Space^.VirtualBytes + Length;
  Result := ErrorNone;
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
  many there were. }
function ReleaseRegionPages(Space: PAddressSpace; Start, Length: QWord): QWord;
var
  Offset: QWord;
  RunLength: LongWord;
  RunIndex: LongWord;
  PhysicalPages: TPhysicalPageRun;
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
        FreePhysicalPage(PhysicalPages[RunIndex]);
        Dec(Space^.CommittedPages);
        Inc(Result);
      end;
    Offset := Offset + QWord(RunLength) * PageSize;
  end;
end;

{ Gives back the pages of the region starting at Start and takes it out
  of the tree (nothing if there is none). Caller holds the lock. }
procedure RemoveRegionLocked(Space: PAddressSpace; Start: QWord);
var
  Node: PRegionNode;
  Released: QWord;
begin
  Node := RemoveRegionNode(Space^.Regions, Start);
  if Node = nil then
    Exit;
  Released := ReleaseRegionPages(Space, Node^.Region.Start, Node^.Region.Length);
  { A section's pages were all counted as shared. (Image regions, the
    other shared kind, go only with the whole address space.) }
  if Node^.Region.Kind = RegionKindSection then
    Space^.SharedPages := Space^.SharedPages - Released;
  if Node^.Region.Kind <> RegionKindStackGuard then
    Space^.VirtualBytes := Space^.VirtualBytes - Node^.Region.Length;
  FreeRegionNode(Node);
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
     (not AnyKind and not (Region^.Kind in [RegionKindAllocation, RegionKindDevice, RegionKindSection])) then
  begin
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    Exit(ErrorInvalidArgument);
  end;

  IsStack := Region^.Kind = RegionKindStack;
  RemoveRegionLocked(Space, Start);
  { A stack's guard goes with it. }
  if IsStack and (Start >= StackGuardSize) then
  begin
    Region := RegionStartingAtLocked(Space, Start - StackGuardSize);
    if (Region <> nil) and (Region^.Kind = RegionKindStackGuard) and
       (Region^.Length = StackGuardSize) then
      RemoveRegionLocked(Space, Start - StackGuardSize);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
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
    RemoveRegionLocked(Space, Start);
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
      RemoveRegionLocked(Space, Search.Starts[Index]);
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

function CommitPageLocked(Space: PAddressSpace; Address: QWord; Attributes: LongWord): LongInt;
var
  PageAddress: QWord;
  PhysicalAddress: TPhysicalAddress;
  ExistingPhysical: TPhysicalAddress;
  Region: PUserRegion;
begin
  PageAddress := RoundDownToPage(Address);

  if TranslateInAddressSpace(Space^.Root, PageAddress, ExistingPhysical) then
  begin
    { Already there (two image segments sharing a page): widen the
      attributes to cover both. }
    Region := FindRegionLocked(Space, PageAddress);
    if Region <> nil then
      Attributes := Attributes or Region^.Attributes;
    UnmapPageInAddressSpace(Space^.Root, PageAddress);
    if not MapPageInAddressSpace(Space^.Root, PageAddress, ExistingPhysical,
      MappingAttributesFor(Attributes)) then
      Exit(ErrorOutOfMemory);
    Exit(ErrorNone);
  end;

  PhysicalAddress := AllocateZeroedPhysicalPage(PageUsageUserMemory);
  if PhysicalAddress = 0 then
    Exit(ErrorOutOfMemory);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, PhysicalAddress, MappingAttributesFor(Attributes)) then
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
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := CommitPageLocked(Space, Address, Attributes);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
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

{ Gives the process its own, writable copy of a copy on write page
  (or, if nobody else holds the page any more, just makes it writable). }
function BreakCopyOnWriteLocked(Space: PAddressSpace; PageAddress: QWord;
  Shared: TPhysicalAddress): LongInt;
var
  Region: PUserRegion;
  Attributes: LongWord;
  Copy: TPhysicalAddress;
begin
  Region := FindRegionLocked(Space, PageAddress);
  if Region = nil then
    Exit(ErrorBadAddress);
  Attributes := Region^.Attributes;
  if PhysicalPageIsShared(Shared) then
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
  Dec(Space^.SharedPages);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, Copy, MappingAttributesFor(Attributes)) then
  begin
    FreePhysicalPage(Copy);
    Dec(Space^.CommittedPages);
    Exit(ErrorOutOfMemory);
  end;
  Result := ErrorNone;
end;

function RegionIsWritableLocked(Space: PAddressSpace; Address: QWord): Boolean;
var
  Region: PUserRegion;
begin
  Region := FindRegionLocked(Space, Address);
  Result := (Region <> nil) and ((Region^.Attributes and RegionWritable) <> 0);
end;

function ResolveCopyOnWriteFault(Space: PAddressSpace; Address: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Physical: TPhysicalAddress;
  IsCopyOnWrite: Boolean;
begin
  Result := False;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if QueryPageInAddressSpace(Space^.Root, RoundDownToPage(Address), Physical, IsCopyOnWrite) then
  begin
    if not IsCopyOnWrite then
      { Another thread of the process copied it meanwhile (the page of a
        writable region is now writable): the write can be retried. }
      Result := RegionIsWritableLocked(Space, Address)
    else
      Result := BreakCopyOnWriteLocked(Space, RoundDownToPage(Address),
        RoundDownToPage(Physical)) = ErrorNone;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function ResolveUserPageFault(Space: PAddressSpace; Address: QWord; ErrorCode: QWord): Boolean;
var
  Region: PUserRegion;
  PreviousLevel: TPriorityLevel;
  PhysicalAddress: TPhysicalAddress;
begin
  Result := False;
  if (Space = nil) or (Address >= UserSpaceLimit) then
    Exit;
  { A write to a present page is fine if it is a copy on write one; any
    other fault on a present page is a protection violation. }
  if (ErrorCode and PageFaultWasPresent) <> 0 then
  begin
    if (ErrorCode and PageFaultWasWrite) <> 0 then
      Result := ResolveCopyOnWriteFault(Space, Address);
    Exit;
  end;

  PreviousLevel := AcquireSpinLock(Space^.Lock);
  { Another thread of the process may have provided the page meanwhile. }
  if TranslateInAddressSpace(Space^.Root, RoundDownToPage(Address), PhysicalAddress) then
    Result := True
  else
  begin
    Region := FindRegionLocked(Space, Address);
    if Region <> nil then
    begin
      { An armed stack reserve is not provided: that is a stack overflow,
        for the exception dispatcher. }
      if Region^.CommitsOnDemand and (((ErrorCode and PageFaultWasWrite) = 0) or
         ((Region^.Attributes and RegionWritable) <> 0)) and
         ((Address >= Region^.Start + Region^.ReserveBytes) or Region^.ReserveInUse) then
        Result := CommitPageLocked(Space, Address, Region^.Attributes) = ErrorNone;
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
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
    if (Region = nil) or (Region^.Kind = RegionKindStackGuard) or
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
  process its own copy first if it is to be written and copy on write. }
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
    if (Region = nil) or (Region^.Kind = RegionKindStackGuard) then
      Exit(ErrorBadAddress);
    Result := CommitPageLocked(Space, Address, Region^.Attributes);
    if Result <> ErrorNone then
      Exit;
    if not TranslateInAddressSpace(Space^.Root, Address, PhysicalAddress) then
      Exit(ErrorBadAddress);
  end;
  Window := PByte(PhysicalToVirtual(PhysicalAddress));
  Result := ErrorNone;
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
    PreviousLevel := AcquireSpinLock(Space^.Lock);
    Result := PageInWindow(Space, Address, IsWrite, Window);
    if Result = ErrorNone then
    begin
      if IsWrite then
      begin
        if KernelBuffer <> nil then
          CopyMemory(Window, KernelBuffer, ChunkBytes)
        else
          ZeroMemory(Window, ChunkBytes);
      end
      else
        CopyMemory(KernelBuffer, Window, ChunkBytes);
    end;
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    if Result <> ErrorNone then
      Exit;
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
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Result := PageInWindow(Space, RoundDownToPage(Address), True, Window);
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
