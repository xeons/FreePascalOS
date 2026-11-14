{
  User address spaces.

  An address space is a page table root plus a sorted list of regions:
  ranges of user addresses with fixed attributes. Pages of most regions
  are provided on demand: the first touch of an address in such a region
  raises a page fault, and the fault resolver maps a fresh zero filled
  page. Pages of program images are mapped eagerly by the loader.

  Layout:

    0000_0000_0040_0000   program image
    0000_1000_0000_0000   memory allocated at run time (heap blocks)
    0000_7F00_0000_0000   shared libraries
    0000_7FFF_FF7F_F000   stack (8 MiB reserved, grows down from the top)

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
  Memory.Layout;

const
  UserImageBase = QWord($0000000000400000);
  UserAllocationBase = QWord($0000100000000000);
  UserAllocationLimit = QWord($00007E0000000000);
  UserLibraryBase = QWord($00007F0000000000);
  UserStackTop = QWord($00007FFFFFFFF000);
  UserStackReserve = QWord(8) * 1024 * 1024;
  MaximumRegions = 1024;

  RegionReadable = LongWord(1) shl 0;
  RegionWritable = LongWord(1) shl 1;
  RegionExecutable = LongWord(1) shl 2;

type
  TRegionKind = (RegionKindImage, RegionKindStack, RegionKindAllocation);

  TUserRegion = record
    Start: QWord;
    Length: QWord;
    Attributes: LongWord;
    Kind: TRegionKind;
    CommitsOnDemand: Boolean;
  end;
  PUserRegion = ^TUserRegion;

  PAddressSpace = ^TAddressSpace;
  TAddressSpace = record
    Root: TPhysicalAddress;
    Regions: PUserRegion;
    RegionCount: Integer;
    NextLibraryAddress: QWord;
    CommittedPages: QWord;
  end;

{ All routines returning LongInt return 0 on success or an Abi error code. }

function CreateAddressSpace(out Space: PAddressSpace): LongInt;
procedure DestroyAddressSpace(Space: PAddressSpace);

function AddRegion(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
  Kind: TRegionKind; CommitsOnDemand: Boolean): LongInt;
{ Finds room for Length bytes at or above Base and below Limit. }
function FindFreeRange(Space: PAddressSpace; Length: QWord; Base, Limit: QWord;
  out Start: QWord): Boolean;

{ Run time allocations (backing for the user heap). }
function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;

{ Maps a zero filled page at Address with the given attributes. If a page
  is already there its attributes are combined with Attributes. }
function CommitPage(Space: PAddressSpace; Address: QWord; Attributes: LongWord): LongInt;

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

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.Arch.PageTables;

const
  PageFaultWasPresent = 1;
  PageFaultWasWrite = 2;

{ --- Creation and destruction ---------------------------------------- }

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

function AddRegion(Space: PAddressSpace; Start, Length: QWord; Attributes: LongWord;
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
  Inc(Space^.RegionCount);
  Result := ErrorNone;
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

procedure ReleaseRegionPages(Space: PAddressSpace; Start, Length: QWord);
var
  Offset: QWord;
  PhysicalAddress: QWord;
begin
  Offset := 0;
  while Offset < Length do
  begin
    PhysicalAddress := UnmapPageInAddressSpace(Space^.Root, Start + Offset);
    if PhysicalAddress <> 0 then
    begin
      FreePhysicalPage(PhysicalAddress);
      Dec(Space^.CommittedPages);
    end;
    Offset := Offset + PageSize;
  end;
end;

function AllocateUserMemory(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
begin
  Start := 0;
  Length := RoundUpToPage(Length);
  if Length = 0 then
    Exit(ErrorInvalidArgument);
  if not FindFreeRange(Space, Length, UserAllocationBase, UserAllocationLimit, Start) then
    Exit(ErrorOutOfMemory);
  Result := AddRegion(Space, Start, Length, RegionReadable or RegionWritable,
    RegionKindAllocation, True);
end;

function FreeUserMemory(Space: PAddressSpace; Start: QWord): LongInt;
var
  Index: Integer;
begin
  Index := FindRegionIndex(Space, Start);
  if (Index < 0) or (Space^.Regions[Index].Start <> Start) or
     (Space^.Regions[Index].Kind <> RegionKindAllocation) then
    Exit(ErrorInvalidArgument);

  ReleaseRegionPages(Space, Space^.Regions[Index].Start, Space^.Regions[Index].Length);
  while Index + 1 < Space^.RegionCount do
  begin
    Space^.Regions[Index] := Space^.Regions[Index + 1];
    Inc(Index);
  end;
  Dec(Space^.RegionCount);
  Result := ErrorNone;
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

function CommitPage(Space: PAddressSpace; Address: QWord; Attributes: LongWord): LongInt;
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

  PhysicalAddress := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if PhysicalAddress = 0 then
    Exit(ErrorOutOfMemory);
  if not MapPageInAddressSpace(Space^.Root, PageAddress, PhysicalAddress, MappingAttributesFor(Attributes)) then
  begin
    FreePhysicalPage(PhysicalAddress);
    Exit(ErrorOutOfMemory);
  end;
  Inc(Space^.CommittedPages);
  Result := ErrorNone;
end;

function ResolveUserPageFault(Space: PAddressSpace; Address: QWord; ErrorCode: QWord): Boolean;
var
  Index: Integer;
  Region: PUserRegion;
begin
  Result := False;
  if (Space = nil) or (Address >= UserSpaceLimit) then
    Exit;
  { A fault on a present page is a protection violation, not a missing page. }
  if (ErrorCode and PageFaultWasPresent) <> 0 then
    Exit;

  Index := FindRegionIndex(Space, Address);
  if Index < 0 then
    Exit;
  Region := @Space^.Regions[Index];
  if not Region^.CommitsOnDemand then
    Exit;
  if ((ErrorCode and PageFaultWasWrite) <> 0) and ((Region^.Attributes and RegionWritable) = 0) then
    Exit;

  Result := CommitPage(Space, Address, Region^.Attributes) = ErrorNone;
end;

function ValidateUserRange(Space: PAddressSpace; Address, Length: QWord; NeedWrite: Boolean): Boolean;
var
  Position: QWord;
  Finish: QWord;
  Index: Integer;
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
  while Position < Finish do
  begin
    Index := FindRegionIndex(Space, Position);
    if Index < 0 then
      Exit;
    if NeedWrite and ((Space^.Regions[Index].Attributes and RegionWritable) = 0) then
      Exit;
    Position := Space^.Regions[Index].Start + Space^.Regions[Index].Length;
  end;
  Result := True;
end;

{ Returns a kernel pointer to Address in Space, providing the page if it
  is an on-demand page that has not been touched yet. }
function PageInWindow(Space: PAddressSpace; Address: QWord; out Window: PByte): LongInt;
var
  PhysicalAddress: TPhysicalAddress;
  Index: Integer;
begin
  Window := nil;
  if not TranslateInAddressSpace(Space^.Root, Address, PhysicalAddress) then
  begin
    Index := FindRegionIndex(Space, Address);
    if Index < 0 then
      Exit(ErrorBadAddress);
    Result := CommitPage(Space, Address, Space^.Regions[Index].Attributes);
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
begin
  while Length > 0 do
  begin
    ChunkBytes := PageSize - (Address and PageOffsetMask);
    if ChunkBytes > Length then
      ChunkBytes := Length;
    Result := PageInWindow(Space, Address, Window);
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

end.
