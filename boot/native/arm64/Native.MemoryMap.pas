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
  Physical memory for the native boot stub, from the device tree.

  RAM is what the /memory nodes say. Parts of it are claimed: reserved
  for good (the /memreserve/ entries, the nodes of /reserved-memory, the
  framebuffer, the first 512 KiB where a Raspberry Pi's firmware keeps
  its own code), occupied for the boot only (the stub's own image and the
  firmware's copy of the tree, usable by the kernel afterwards), the RAM
  disk, and everything the stub allocates (kernel image, boot data,
  translation tables), each with the kind the kernel's memory map gives
  it. Allocations are first fit, page aligned and zeroed, from what no
  claim covers.

  ExportMemoryMap writes the result as the boot information's regions:
  RAM no claim covers is usable, claimed RAM has the claim's kind, and
  reserved pieces are left out of the window (VisitMappedMemory) so they
  are never normal cacheable memory.
}
unit Native.MemoryMap;

{$mode objfpc}

interface

uses
  Boot.Information,
  DeviceTree.Blob;

const
  NativePageSize = 4096;
  { Claimed only while the stub runs. }
  MemoryRegionBootOnly = 0;

type
  TMappedMemoryVisitor = procedure(PhysicalStart, SizeInBytes: QWord);

{ Reads the RAM ranges, the reservations and /reserved-memory. }
function InitializeMemoryMap(constref Tree: TDeviceTree): Boolean;
{ Claims [Start, Start + Size) with Kind (page aligned outwards). }
procedure ClaimMemory(Start, Size: QWord; Kind: LongWord);
{ PageCount zeroed pages of Kind, or 0 if there is no room. }
function AllocatePages(PageCount: QWord; Kind: LongWord): QWord;
function PagesFor(ByteCount: QWord): QWord;
{ The RAM regions as the boot information's memory map. }
procedure ExportMemoryMap(var BootInformation: TBootInformation);
{ Every piece of RAM that is not reserved (what the window maps). }
procedure VisitMappedMemory(Visitor: TMappedMemoryVisitor);
function TotalMemoryBytes: QWord;

implementation

uses
  Runtime.Memory,
  DeviceTree.Addresses;

const
  MaximumRamRanges = 32;
  MaximumClaims = 96;
  { A Raspberry Pi's firmware keeps its ARM stub (TF-A on the Pi 5) here. }
  FirmwareLowMemorySize = $80000;

type
  TRange = record
    Start: QWord;
    Finish: QWord;
    Kind: LongWord;
  end;

var
  RamRanges: array[0..MaximumRamRanges - 1] of TRange;
  RamCount: Integer = 0;
  Claims: array[0..MaximumClaims - 1] of TRange;
  ClaimCount: Integer = 0;

function PagesFor(ByteCount: QWord): QWord;
begin
  Result := (ByteCount + NativePageSize - 1) div NativePageSize;
end;

function RoundDown(Value: QWord): QWord;
begin
  Result := Value and not QWord(NativePageSize - 1);
end;

function RoundUp(Value: QWord): QWord;
begin
  Result := RoundDown(Value + NativePageSize - 1);
end;

procedure AddRamRange(Start, Size: QWord);
var
  Index: Integer;
  Position: Integer;
  Finish: QWord;
begin
  Finish := RoundDown(Start + Size);
  Start := RoundUp(Start);
  if (Finish <= Start) or (RamCount >= MaximumRamRanges) then
    Exit;
  { Kept sorted by start. }
  Position := RamCount;
  for Index := 0 to RamCount - 1 do
    if RamRanges[Index].Start > Start then
    begin
      Position := Index;
      Break;
    end;
  Index := RamCount;
  while Index > Position do
  begin
    RamRanges[Index] := RamRanges[Index - 1];
    Dec(Index);
  end;
  RamRanges[Position].Start := Start;
  RamRanges[Position].Finish := Finish;
  RamRanges[Position].Kind := MemoryRegionUsable;
  Inc(RamCount);
end;

procedure ClaimMemory(Start, Size: QWord; Kind: LongWord);
var
  Index: Integer;
  Position: Integer;
  Finish: QWord;
begin
  if (Size = 0) or (ClaimCount >= MaximumClaims) then
    Exit;
  Finish := RoundUp(Start + Size);
  Start := RoundDown(Start);
  Position := ClaimCount;
  for Index := 0 to ClaimCount - 1 do
    if Claims[Index].Start > Start then
    begin
      Position := Index;
      Break;
    end;
  Index := ClaimCount;
  while Index > Position do
  begin
    Claims[Index] := Claims[Index - 1];
    Dec(Index);
  end;
  Claims[Position].Start := Start;
  Claims[Position].Finish := Finish;
  Claims[Position].Kind := Kind;
  Inc(ClaimCount);
end;

procedure ReadMemoryNodes(constref Tree: TDeviceTree);
var
  Node: LongInt;
  Depth: Integer;
  Index: LongWord;
  Start: QWord;
  Size: QWord;
begin
  Depth := 0;
  Node := FirstChildNode(Tree, RootNode(Tree));
  while Node <> NoNode do
  begin
    if NodeHasDeviceType(Tree, Node, 'memory') and NodeIsEnabled(Tree, Node) then
    begin
      Index := 0;
      while NodeRegisterPhysical(Tree, Node, Index, Start, Size) do
      begin
        AddRamRange(Start, Size);
        Inc(Index);
      end;
    end;
    Node := NextSiblingNode(Tree, Node);
  end;
end;

procedure ReadReservations(constref Tree: TDeviceTree);
var
  Index: LongWord;
  Start: QWord;
  Size: QWord;
  Reserved: LongInt;
  Node: LongInt;
begin
  Index := 0;
  while GetMemoryReservation(Tree, Index, Start, Size) do
  begin
    ClaimMemory(Start, Size, MemoryRegionReserved);
    Inc(Index);
  end;
  { Nodes with a fixed "reg"; dynamically placed ones (size and
    alloc-ranges only) were never placed, as no Linux runs here. }
  Reserved := FindChildNode(Tree, RootNode(Tree), 'reserved-memory', 15);
  Node := FirstChildNode(Tree, Reserved);
  while Node <> NoNode do
  begin
    if NodeIsEnabled(Tree, Node) then
    begin
      Index := 0;
      while NodeRegisterPhysical(Tree, Node, Index, Start, Size) do
      begin
        ClaimMemory(Start, Size, MemoryRegionReserved);
        Inc(Index);
      end;
    end;
    Node := NextSiblingNode(Tree, Node);
  end;
end;

function InitializeMemoryMap(constref Tree: TDeviceTree): Boolean;
begin
  RamCount := 0;
  ClaimCount := 0;
  ReadMemoryNodes(Tree);
  ReadReservations(Tree);
  ClaimMemory(0, FirmwareLowMemorySize, MemoryRegionReserved);
  Result := RamCount > 0;
end;

function TotalMemoryBytes: QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to RamCount - 1 do
    Result := Result + (RamRanges[Index].Finish - RamRanges[Index].Start);
end;

{ The first claim that ends after Position, or -1. }
function NextClaimAfter(Position: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to ClaimCount - 1 do
    if Claims[Index].Finish > Position then
      Exit(Index);
  Result := -1;
end;

function AllocatePages(PageCount: QWord; Kind: LongWord): QWord;
var
  RangeIndex: Integer;
  Candidate: QWord;
  Size: QWord;
  Claim: Integer;
begin
  Result := 0;
  if PageCount = 0 then
    Exit;
  Size := PageCount * NativePageSize;
  for RangeIndex := 0 to RamCount - 1 do
  begin
    Candidate := RamRanges[RangeIndex].Start;
    while Candidate + Size <= RamRanges[RangeIndex].Finish do
    begin
      { Claims are sorted by start: the first one ending after the
        candidate is the only one that can be in the way. }
      Claim := NextClaimAfter(Candidate);
      if (Claim < 0) or (Claims[Claim].Start >= Candidate + Size) then
      begin
        ClaimMemory(Candidate, Size, Kind);
        ZeroMemory(Pointer(Candidate), Size);
        Exit(Candidate);
      end;
      if Claims[Claim].Finish > Candidate then
        Candidate := Claims[Claim].Finish;
    end;
  end;
end;

procedure AddRegion(var BootInformation: TBootInformation; Start, Finish: QWord; Kind: LongWord);
var
  Last: PMemoryRegion;
begin
  if Finish <= Start then
    Exit;
  if Kind = MemoryRegionBootOnly then
    Kind := MemoryRegionUsable;
  if BootInformation.MemoryRegionCount > 0 then
  begin
    Last := @BootInformation.MemoryRegions[BootInformation.MemoryRegionCount - 1];
    if (Last^.Kind = Kind) and (Last^.PhysicalStart + Last^.PageCount * NativePageSize = Start) then
    begin
      Last^.PageCount := Last^.PageCount + (Finish - Start) div NativePageSize;
      Exit;
    end;
  end;
  if BootInformation.MemoryRegionCount >= MaximumMemoryRegions then
    Exit;
  Last := @BootInformation.MemoryRegions[BootInformation.MemoryRegionCount];
  Last^.PhysicalStart := Start;
  Last^.PageCount := (Finish - Start) div NativePageSize;
  Last^.Kind := Kind;
  Last^.Padding := 0;
  Inc(BootInformation.MemoryRegionCount);
end;

procedure ExportMemoryMap(var BootInformation: TBootInformation);
var
  RangeIndex: Integer;
  Position: QWord;
  Finish: QWord;
  Claim: Integer;
  PieceStart: QWord;
  PieceFinish: QWord;
begin
  BootInformation.MemoryRegionCount := 0;
  for RangeIndex := 0 to RamCount - 1 do
  begin
    Position := RamRanges[RangeIndex].Start;
    Finish := RamRanges[RangeIndex].Finish;
    while Position < Finish do
    begin
      Claim := NextClaimAfter(Position);
      if (Claim < 0) or (Claims[Claim].Start >= Finish) then
      begin
        AddRegion(BootInformation, Position, Finish, MemoryRegionUsable);
        Break;
      end;
      PieceStart := Claims[Claim].Start;
      if PieceStart < Position then
        PieceStart := Position;
      AddRegion(BootInformation, Position, PieceStart, MemoryRegionUsable);
      PieceFinish := Claims[Claim].Finish;
      if PieceFinish > Finish then
        PieceFinish := Finish;
      AddRegion(BootInformation, PieceStart, PieceFinish, Claims[Claim].Kind);
      Position := PieceFinish;
    end;
  end;
end;

procedure VisitMappedMemory(Visitor: TMappedMemoryVisitor);
var
  Snapshot: TBootInformation;
  Index: QWord;
  Region: PMemoryRegion;
begin
  { A snapshot: the visitor may allocate (translation tables). }
  ExportMemoryMap(Snapshot);
  Index := 0;
  while Index < Snapshot.MemoryRegionCount do
  begin
    Region := @Snapshot.MemoryRegions[Index];
    if Region^.Kind <> MemoryRegionReserved then
      Visitor(Region^.PhysicalStart, Region^.PageCount * NativePageSize);
    Inc(Index);
  end;
end;

end.
