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

  An address space is a page table root plus a sorted list of regions:
  ranges of user addresses with fixed attributes. Pages of most regions
  are provided on demand: the first touch of an address in such a region
  raises a page fault, and the fault resolver maps a fresh zero filled
  page. Pages of program images are mapped eagerly by the loader, from
  the image's shared pages (Processes.ImageSections): read-only pages are
  simply shared, writable ones are copy on write - the first write, by
  the program or by the kernel (relocations, WriteIntoAddressSpace),
  gives the process its own copy of that page.

  Layout:

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
  Memory.Layout,
  Kernel.SpinLock;

const
  UserImageBase = QWord($0000000000400000);
  UserAllocationBase = QWord($0000100000000000);
  UserAllocationLimit = QWord($00007E0000000000);
  UserLibraryBase = QWord($00007F0000000000);
  UserStackTop = QWord($00007FFFFFFFF000);
  UserStackReserve = QWord(8) * 1024 * 1024;
  MaximumRegions = 1024;

  { The reserve at the bottom of a stack, and how far above it the stack
    pointer must be before a used reserve is armed again. }
  StackReserveSize = 64 * 1024;
  StackReserveRearmDistance = 64 * 1024;
  StackGuardSize = QWord(256) * 1024 * 1024;

  RegionReadable = LongWord(1) shl 0;
  RegionWritable = LongWord(1) shl 1;
  RegionExecutable = LongWord(1) shl 2;

type
  TRegionKind = (RegionKindImage, RegionKindStack, RegionKindAllocation,
    { A thread's thread control block and static thread-local storage. }
    RegionKindThreadData,
    { Address space below a stack that is never mapped. }
    RegionKindStackGuard,
    { Device memory, mapped when the region was made. }
    RegionKindDevice,
    { A section's pages, mapped when the region was made. }
    RegionKindSection);

  TUserRegion = record
    Start: QWord;
    Length: QWord;
    Attributes: LongWord;
    Kind: TRegionKind;
    CommitsOnDemand: Boolean;
    { Stacks: the bottom ReserveBytes are only provided once a stack
      overflow opened them (ReserveInUse). }
    ReserveBytes: QWord;
    ReserveInUse: Boolean;
  end;
  PUserRegion = ^TUserRegion;

  PAddressSpace = ^TAddressSpace;
  TAddressSpace = record
    Root: TPhysicalAddress;
    Regions: PUserRegion;
    RegionCount: Integer;
    NextLibraryAddress: QWord;
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
  end;

{ All routines returning LongInt return 0 on success or an Abi error code. }

function CreateAddressSpace(out Space: PAddressSpace): LongInt;
procedure DestroyAddressSpace(Space: PAddressSpace);
procedure GetAddressSpaceUsage(Space: PAddressSpace; out Usage: TAddressSpaceUsage);

function AddRegion(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
{ Finds room for Length bytes at or above Base and below Limit. }
function FindFreeRange(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;

{ Run time allocations (backing for the user heap). }
function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;

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
  Abi.SystemCalls,
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

function CreateAddressSpace(out Space: PAddressSpace): LongInt;
begin
  Space := PAddressSpace(AllocateZeroedKernelMemory(SizeOf(TAddressSpace)));
  if Space = nil then
    Exit(ErrorOutOfMemory);
  Space^.Regions := PUserRegion(AllocateZeroedKernelMemory(MaximumRegions * SizeOf(TUserRegion)));
  Space^.Root := CreateAddressSpaceRoot;
  if (Space^.Regions = nil) or (Space^.Root = 0) then
  begin
    FreeKernelMemory(Space^.Regions);
    FreeKernelMemory(Space);
    Space := nil;
    Exit(ErrorOutOfMemory);
  end;
  Space^.NextLibraryAddress := UserLibraryBase;
  InitializeSpinLock(Space^.Lock);
  Result := ErrorNone;
end;

procedure DestroyAddressSpace(Space: PAddressSpace);
begin
  if Space = nil then
    Exit;
  { Every user page and page table is released along with the root. }
  DestroyAddressSpaceRoot(Space^.Root);
  FreeKernelMemory(Space^.Regions);
  FreeKernelMemory(Space);
end;

procedure GetAddressSpaceUsage(Space: PAddressSpace; out Usage: TAddressSpaceUsage);
var
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  Usage.VirtualBytes := 0;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  for Index := 0 to Space^.RegionCount - 1 do
    if Space^.Regions[Index].Kind <> RegionKindStackGuard then
      Usage.VirtualBytes := Usage.VirtualBytes + Space^.Regions[Index].Length;
  Usage.ResidentPages := Space^.CommittedPages;
  Usage.SharedPages := Space^.SharedPages;
  Usage.PeakResidentPages := Space^.PeakCommittedPages;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ --- Regions --------------------------------------------------------- }

function RangesOverlap(FirstStart, FirstLength, SecondStart, SecondLength: QWord): Boolean;
begin
  Result := (FirstStart < SecondStart + SecondLength) and (SecondStart < FirstStart + FirstLength);
end;

function FindRegionIndex(Space: PAddressSpace; Address: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Space^.RegionCount - 1 do
  begin
    if (Address >= Space^.Regions[Index].Start) and
       (Address - Space^.Regions[Index].Start < Space^.Regions[Index].Length) then
      Exit(Index);
  end;
  Result := -1;
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
  Index: Integer;
  InsertAt: Integer;
begin
  if (Length = 0) or ((Start and PageOffsetMask) <> 0) or ((Length and PageOffsetMask) <> 0) or
     (Start >= UserSpaceLimit) or (Length > UserSpaceLimit - Start) or (Start = 0) then
    Exit(ErrorInvalidArgument);
  if Space^.RegionCount >= MaximumRegions then
    Exit(ErrorOutOfMemory);

  InsertAt := Space^.RegionCount;
  for Index := 0 to Space^.RegionCount - 1 do
  begin
    if RangesOverlap(Start, Length, Space^.Regions[Index].Start, Space^.Regions[Index].Length) then
      Exit(ErrorExists);
    if (InsertAt = Space^.RegionCount) and (Space^.Regions[Index].Start > Start) then
      InsertAt := Index;
  end;

  { Keep the list sorted by start address. }
  Index := Space^.RegionCount;
  while Index > InsertAt do
  begin
    Space^.Regions[Index] := Space^.Regions[Index - 1];
    Dec(Index);
  end;
  Space^.Regions[InsertAt].Start := Start;
  Space^.Regions[InsertAt].Length := Length;
  Space^.Regions[InsertAt].Attributes := Attributes;
  Space^.Regions[InsertAt].Kind := Kind;
  Space^.Regions[InsertAt].CommitsOnDemand := CommitsOnDemand;
  Space^.Regions[InsertAt].ReserveInUse := False;
  if (Kind = RegionKindStack) and CommitsOnDemand then
    Space^.Regions[InsertAt].ReserveBytes := StackReserveFor(Length)
  else
    Space^.Regions[InsertAt].ReserveBytes := 0;
  Inc(Space^.RegionCount);
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

function FindFreeRange(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;
var
  Index: Integer;
  Candidate: QWord;
begin
  Start := 0;
  Candidate := Base;
  { Regions are sorted, so one pass finds the first gap that fits. }
  for Index := 0 to Space^.RegionCount - 1 do
  begin
    if Space^.Regions[Index].Start + Space^.Regions[Index].Length <= Candidate then
      Continue;
    if Space^.Regions[Index].Start >= Candidate + Length then
      Break;
    Candidate := Space^.Regions[Index].Start + Space^.Regions[Index].Length;
  end;
  Result := (Candidate + Length <= Limit) and (Candidate + Length > Candidate);
  if Result then
    Start := Candidate;
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

{ Finds room for GuardBytes + Length and adds a region for the upper
  Length bytes. }
function AddStackGuardLocked(Space: PAddressSpace; StackStart: QWord): LongInt; forward;
procedure RemoveRegionAtLocked(Space: PAddressSpace; Index: Integer); forward;

function AllocateWithGuard(Space: PAddressSpace; Length, GuardBytes: QWord; Kind: TRegionKind;
  out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Start := 0;
  Length := RoundUpToPage(Length);
  if Length = 0 then
    Exit(ErrorInvalidArgument);
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not FindFreeRange(Space, GuardBytes + Length, UserAllocationBase, UserAllocationLimit, Start) then
    Result := ErrorOutOfMemory
  else
  begin
    Start := Start + GuardBytes;
    Result := AddRegionLocked(Space, Start, Length, RegionReadable or RegionWritable, Kind, True);
    if (Result = ErrorNone) and (Kind = RegionKindStack) then
    begin
      Result := AddStackGuardLocked(Space, Start);
      if Result <> ErrorNone then
        RemoveRegionAtLocked(Space, FindRegionIndex(Space, Start));
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
begin
  Result := AllocateWithGuard(Space, Length, 0, RegionKindAllocation, Start);
end;

function AllocateGuardedUserMemory(Space: PAddressSpace; Length: QWord; Kind: TRegionKind;
  out Start: QWord): LongInt;
begin
  if Kind = RegionKindStack then
    Result := AllocateWithGuard(Space, Length, StackGuardSize, Kind, Start)
  else
    Result := AllocateWithGuard(Space, Length, PageSize, Kind, Start);
end;

{ Removes the region starting at Start; AnyKind allows other kinds than
  run time allocations. }
{ Gives back the pages of region Index and takes it out of the list. }
procedure RemoveRegionAtLocked(Space: PAddressSpace; Index: Integer);
var
  Released: QWord;
begin
  if Index < 0 then
    Exit;
  Released := ReleaseRegionPages(Space, Space^.Regions[Index].Start, Space^.Regions[Index].Length);
  { A section's pages were all counted as shared. (Image regions, the
    other shared kind, go only with the whole address space.) }
  if Space^.Regions[Index].Kind = RegionKindSection then
    Space^.SharedPages := Space^.SharedPages - Released;
  while Index + 1 < Space^.RegionCount do
  begin
    Space^.Regions[Index] := Space^.Regions[Index + 1];
    Inc(Index);
  end;
  Dec(Space^.RegionCount);
end;

function RemoveRegion(Space: PAddressSpace; Start: QWord; AnyKind: Boolean): LongInt;
var
  Index: Integer;
  PreviousLevel: TPriorityLevel;
  IsStack: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := FindRegionIndex(Space, Start);
  if (Index < 0) or (Space^.Regions[Index].Start <> Start) or
     (not AnyKind and not (Space^.Regions[Index].Kind in [RegionKindAllocation, RegionKindDevice,
       RegionKindSection])) then
  begin
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    Exit(ErrorInvalidArgument);
  end;

  IsStack := Space^.Regions[Index].Kind = RegionKindStack;
  RemoveRegionAtLocked(Space, Index);
  { A stack's guard goes with it. }
  if IsStack and (Start >= StackGuardSize) then
  begin
    Index := FindRegionIndex(Space, Start - StackGuardSize);
    if (Index >= 0) and (Space^.Regions[Index].Kind = RegionKindStackGuard) and
       (Space^.Regions[Index].Start + Space^.Regions[Index].Length = Start) then
      RemoveRegionAtLocked(Space, Index);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  Result := ErrorNone;
end;

function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;
begin
  Result := RemoveRegion(Space, Start, False);
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
  if not FindFreeRange(Space, Length, UserAllocationBase, UserAllocationLimit, Start) then
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
      RemoveRegionAtLocked(Space, FindRegionIndex(Space, Start));
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
  if not FindFreeRange(Space, Length, UserAllocationBase, UserAllocationLimit, Start) then
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
      RemoveRegionAtLocked(Space, FindRegionIndex(Space, Start));
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
  Index: Integer;
begin
  PageAddress := RoundDownToPage(Address);

  if TranslateInAddressSpace(Space^.Root, PageAddress, ExistingPhysical) then
  begin
    { Already there (two image segments sharing a page): widen the
      attributes to cover both. }
    Index := FindRegionIndex(Space, PageAddress);
    if Index >= 0 then
      Attributes := Attributes or Space^.Regions[Index].Attributes;
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
  Index: Integer;
  Attributes: LongWord;
  Copy: TPhysicalAddress;
begin
  Index := FindRegionIndex(Space, PageAddress);
  if Index < 0 then
    Exit(ErrorBadAddress);
  Attributes := Space^.Regions[Index].Attributes;
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
  Index: Integer;
begin
  Index := FindRegionIndex(Space, Address);
  Result := (Index >= 0) and ((Space^.Regions[Index].Attributes and RegionWritable) <> 0);
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
  Index: Integer;
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
    Index := FindRegionIndex(Space, Address);
    if Index >= 0 then
    begin
      Region := @Space^.Regions[Index];
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
  Index: Integer;
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
    Index := FindRegionIndex(Space, Position);
    if (Index < 0) or (Space^.Regions[Index].Kind = RegionKindStackGuard) or
       (NeedWrite and ((Space^.Regions[Index].Attributes and RegionWritable) = 0)) then
    begin
      Result := False;
      Break;
    end;
    Position := Space^.Regions[Index].Start + Space^.Regions[Index].Length;
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
  Index: Integer;
  IsCopyOnWrite: Boolean;
begin
  Window := nil;
  { Device memory is not reached through the physical memory window. }
  Index := FindRegionIndex(Space, Address);
  if (Index >= 0) and (Space^.Regions[Index].Kind = RegionKindDevice) then
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
    Index := FindRegionIndex(Space, Address);
    if (Index < 0) or (Space^.Regions[Index].Kind = RegionKindStackGuard) then
      Exit(ErrorBadAddress);
    Result := CommitPageLocked(Space, Address, Space^.Regions[Index].Attributes);
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
  Index: Integer;
  Region: PUserRegion;
begin
  Result := False;
  RegionStart := 0;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := FindRegionIndex(Space, Address);
  if Index >= 0 then
  begin
    Region := @Space^.Regions[Index];
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
  Index: Integer;
  Region: PUserRegion;
begin
  Result := True;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := FindRegionIndex(Space, RegionStart);
  if (Index >= 0) and (Space^.Regions[Index].Start = RegionStart) then
  begin
    Region := @Space^.Regions[Index];
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

{ The index of the stack region starting at StackStart, or -1. Caller
  holds the lock. }
function StackRegionIndexLocked(Space: PAddressSpace; StackStart: QWord): Integer;
begin
  Result := FindRegionIndex(Space, StackStart);
  if (Result >= 0) and ((Space^.Regions[Result].Start <> StackStart) or
     (Space^.Regions[Result].Kind <> RegionKindStack)) then
    Result := -1;
end;

function OpenStackReserveOfRegion(Space: PAddressSpace; StackStart: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := StackRegionIndexLocked(Space, StackStart);
  Result := (Index >= 0) and not Space^.Regions[Index].ReserveInUse and
    (Space^.Regions[Index].ReserveBytes > 0);
  if Result then
    Space^.Regions[Index].ReserveInUse := True;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function StackReserveTop(Space: PAddressSpace; StackStart: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := StackRegionIndexLocked(Space, StackStart);
  if Index >= 0 then
    Result := Space^.Regions[Index].Start + Space^.Regions[Index].ReserveBytes
  else
    Result := 0;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AddressIsInUsableRegion(Space: PAddressSpace; Address: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Index := FindRegionIndex(Space, Address);
  Result := (Index >= 0) and (Space^.Regions[Index].Kind <> RegionKindStackGuard);
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
