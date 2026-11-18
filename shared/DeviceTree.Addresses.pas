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
  Addresses in a device tree: "reg" and "ranges".

  A node's "reg" is in the address space of its parent's bus, in cells
  of the parent's #address-cells and #size-cells (2 and 1 when not
  given). To reach the processor's physical address it goes up through
  each bus's "ranges" (child address, parent address, size): a bus
  without "ranges" cannot be translated through, an empty one maps one
  to one. On a Raspberry Pi 5 the debug UART's reg is 7d001000 in /soc,
  whose ranges move 7c000000 to 10_7c000000.

  PCI buses address with three cells (phys.hi with the space code, then
  a 64-bit address): an address matches a range of the same space code
  (configuration, I/O, 32-bit or 64-bit memory). Wider addresses on
  other buses match when their cells above the low 64 bits are equal.

  "dma-ranges" (the same format) say where a bus's devices see memory
  when they do DMA, and "dma-coherent" (on the device or a node above)
  that they snoop the processors' caches.

  Plain Pascal (DeviceTree.Blob only), shared by the native boot stub,
  the kernel and the host test.
}
unit DeviceTree.Addresses;

{$mode objfpc}
{$pointermath on}
{ Address arithmetic wraps on purpose. }
{$overflowchecks off}
{$rangechecks off}

interface

uses
  DeviceTree.Blob;

const
  MaximumAddressCells = 4;
  DefaultAddressCells = 2;
  DefaultSizeCells = 1;
  { The space code in a PCI address's phys.hi cell (bits 24-25). }
  PciSpaceConfiguration = 0;
  PciSpaceIo = 1;
  PciSpaceMemory32 = 2;
  PciSpaceMemory64 = 3;

type
  TDeviceTreeAddress = record
    CellCount: LongWord;
    Cells: array[0..MaximumAddressCells - 1] of LongWord;
  end;

{ Node's #address-cells and #size-cells: how its children's addresses
  are written. }
function NodeAddressCells(constref Tree: TDeviceTree; Node: LongInt): LongWord;
function NodeSizeCells(constref Tree: TDeviceTree; Node: LongInt): LongWord;

{ CellCount cells at Data as an address. }
procedure ReadAddress(Data: PByte; CellCount: LongWord; out Address: TDeviceTreeAddress);
{ The low 64 bits. }
function AddressValue(constref Address: TDeviceTreeAddress): QWord;
{ The space code of a three-cell (PCI) address. }
function PciAddressSpace(constref Address: TDeviceTreeAddress): LongWord;

{ How many entries Node's "reg" has, and entry Index as its parent's
  bus sees it. }
function RegisterCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
function ReadRegister(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Address: TDeviceTreeAddress; out Size: QWord): Boolean;

{ Address, on the bus below Bus (in Bus's #address-cells), as the
  processor sees it. False if a bus on the way has no "ranges" or no
  range holds it. }
function TranslateAddress(constref Tree: TDeviceTree; Bus: LongInt; constref Address: TDeviceTreeAddress;
  out Physical: QWord): Boolean;
{ Entry Index of Node's "reg" as a physical address. }
function NodeRegisterPhysical(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Physical, Size: QWord): Boolean;

{ Entry Index of Bus's "ranges" (the bus's own address, the processor's
  address, the size): PCI host bridges' windows. }
function ReadRangeEntry(constref Tree: TDeviceTree; Bus: LongInt; Index: LongWord;
  out ChildAddress: TDeviceTreeAddress; out Physical, Size: QWord): Boolean;

{ The nearest node from Node's parent up that has "dma-ranges", or
  NoNode. }
function FindDmaRangesBus(constref Tree: TDeviceTree; Node: LongInt): LongInt;
{ Entry Index of Bus's "dma-ranges": the device sees memory at
  [BusStart, BusStart + Size) that the processor has at PhysicalStart
  (translated through the dma-ranges of the buses above, if they have
  any). }
function ReadDmaRange(constref Tree: TDeviceTree; Bus: LongInt; Index: LongWord;
  out BusStart, PhysicalStart, Size: QWord): Boolean;
{ "dma-coherent" on Node or a node above it. }
function NodeIsDmaCoherent(constref Tree: TDeviceTree; Node: LongInt): Boolean;

implementation

const
  { How many buses up an address is followed at most. }
  MaximumTranslationLevels = 16;

function NodeAddressCells(constref Tree: TDeviceTree; Node: LongInt): LongWord;
begin
  if not ReadCellProperty(Tree, Node, '#address-cells', Result) then
    Result := DefaultAddressCells;
end;

function NodeSizeCells(constref Tree: TDeviceTree; Node: LongInt): LongWord;
begin
  if not ReadCellProperty(Tree, Node, '#size-cells', Result) then
    Result := DefaultSizeCells;
end;

procedure ReadAddress(Data: PByte; CellCount: LongWord; out Address: TDeviceTreeAddress);
var
  Index: LongWord;
begin
  Address.CellCount := CellCount;
  for Index := 0 to MaximumAddressCells - 1 do
    Address.Cells[Index] := 0;
  if CellCount > MaximumAddressCells then
    Address.CellCount := MaximumAddressCells;
  Index := 0;
  while Index < Address.CellCount do
  begin
    Address.Cells[Index] := ReadBigEndian32(Data + Index * 4);
    Inc(Index);
  end;
end;

function AddressValue(constref Address: TDeviceTreeAddress): QWord;
begin
  case Address.CellCount of
    0: Result := 0;
    1: Result := Address.Cells[0];
  else
    Result := (QWord(Address.Cells[Address.CellCount - 2]) shl 32) or Address.Cells[Address.CellCount - 1];
  end;
end;

procedure SetAddressValue(var Address: TDeviceTreeAddress; Value: QWord);
begin
  case Address.CellCount of
    0: ;
    1: Address.Cells[0] := LongWord(Value);
  else
    begin
      Address.Cells[Address.CellCount - 2] := LongWord(Value shr 32);
      Address.Cells[Address.CellCount - 1] := LongWord(Value);
    end;
  end;
end;

function PciAddressSpace(constref Address: TDeviceTreeAddress): LongWord;
begin
  Result := (Address.Cells[0] shr 24) and 3;
end;

function RegisterCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
var
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  EntryCells: LongWord;
begin
  Result := 0;
  if not FindProperty(Tree, Node, 'reg', Prop) then
    Exit;
  Parent := ParentNode(Tree, Node);
  if Parent = NoNode then
    Exit;
  EntryCells := NodeAddressCells(Tree, Parent) + NodeSizeCells(Tree, Parent);
  if EntryCells = 0 then
    Exit;
  Result := PropertyCellCount(Prop) div EntryCells;
end;

function ReadRegister(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Address: TDeviceTreeAddress; out Size: QWord): Boolean;
var
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  AddressCells: LongWord;
  SizeCells: LongWord;
  EntryCells: LongWord;
begin
  Address.CellCount := 0;
  Size := 0;
  Result := False;
  if not FindProperty(Tree, Node, 'reg', Prop) then
    Exit;
  Parent := ParentNode(Tree, Node);
  if Parent = NoNode then
    Exit;
  AddressCells := NodeAddressCells(Tree, Parent);
  SizeCells := NodeSizeCells(Tree, Parent);
  EntryCells := AddressCells + SizeCells;
  if (EntryCells = 0) or (AddressCells > MaximumAddressCells) or
     ((Index + 1) * EntryCells > PropertyCellCount(Prop)) then
    Exit;
  ReadAddress(Prop.Value + Index * EntryCells * 4, AddressCells, Address);
  Size := ReadCells(Prop.Value + (Index * EntryCells + AddressCells) * 4, SizeCells);
  Result := True;
end;

{ Address lies in the range starting at Base (Size bytes). }
function RangeHolds(constref Base, Address: TDeviceTreeAddress; Size: QWord): Boolean;
var
  Index: LongWord;
  Offset: QWord;
begin
  Result := False;
  if Base.CellCount <> Address.CellCount then
    Exit;
  if Address.CellCount = 3 then
  begin
    if PciAddressSpace(Base) <> PciAddressSpace(Address) then
      Exit;
  end
  else if Address.CellCount > 3 then
  begin
    Index := 0;
    while Index + 2 < Address.CellCount do
    begin
      if Base.Cells[Index] <> Address.Cells[Index] then
        Exit;
      Inc(Index);
    end;
  end;
  if AddressValue(Address) < AddressValue(Base) then
    Exit;
  Offset := AddressValue(Address) - AddressValue(Base);
  Result := Offset < Size;
end;

{ Moves Address from the bus below Bus to the bus Bus is on, through
  Bus's ranges (or dma-ranges). }
function TranslateOneLevel(constref Tree: TDeviceTree; Bus, Parent: LongInt; RangesName: PChar;
  var Address: TDeviceTreeAddress): Boolean;
var
  Prop: TDeviceTreeProperty;
  ChildCells: LongWord;
  ParentCells: LongWord;
  SizeCells: LongWord;
  EntryCells: LongWord;
  EntryCount: LongWord;
  Entry: LongWord;
  ChildBase: TDeviceTreeAddress;
  ParentBase: TDeviceTreeAddress;
  Size: QWord;
  Position: PByte;
  Offset: QWord;
begin
  Result := False;
  if not FindProperty(Tree, Bus, RangesName, Prop) then
    Exit;
  ChildCells := NodeAddressCells(Tree, Bus);
  ParentCells := NodeAddressCells(Tree, Parent);
  SizeCells := NodeSizeCells(Tree, Bus);
  if (ChildCells > MaximumAddressCells) or (ParentCells > MaximumAddressCells) then
    Exit;
  if Prop.Length = 0 then
  begin
    { One to one. }
    Offset := AddressValue(Address);
    ReadAddress(nil, 0, ParentBase);
    ParentBase.CellCount := ParentCells;
    SetAddressValue(ParentBase, Offset);
    Address := ParentBase;
    Exit(True);
  end;
  EntryCells := ChildCells + ParentCells + SizeCells;
  if EntryCells = 0 then
    Exit;
  EntryCount := PropertyCellCount(Prop) div EntryCells;
  Entry := 0;
  while Entry < EntryCount do
  begin
    Position := Prop.Value + Entry * EntryCells * 4;
    ReadAddress(Position, ChildCells, ChildBase);
    ReadAddress(Position + ChildCells * 4, ParentCells, ParentBase);
    Size := ReadCells(Position + (ChildCells + ParentCells) * 4, SizeCells);
    if RangeHolds(ChildBase, Address, Size) then
    begin
      Offset := AddressValue(Address) - AddressValue(ChildBase);
      SetAddressValue(ParentBase, AddressValue(ParentBase) + Offset);
      Address := ParentBase;
      Exit(True);
    end;
    Inc(Entry);
  end;
end;

function TranslateAddress(constref Tree: TDeviceTree; Bus: LongInt; constref Address: TDeviceTreeAddress;
  out Physical: QWord): Boolean;
var
  Current: TDeviceTreeAddress;
  Parent: LongInt;
  Level: Integer;
begin
  Physical := 0;
  Result := False;
  Current := Address;
  for Level := 1 to MaximumTranslationLevels do
  begin
    Parent := ParentNode(Tree, Bus);
    if Parent = NoNode then
    begin
      { Bus is the root: its children's addresses are physical. }
      Physical := AddressValue(Current);
      Exit(True);
    end;
    if not TranslateOneLevel(Tree, Bus, Parent, 'ranges', Current) then
      Exit;
    Bus := Parent;
  end;
end;

function NodeRegisterPhysical(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Physical, Size: QWord): Boolean;
var
  Address: TDeviceTreeAddress;
begin
  Physical := 0;
  Result := ReadRegister(Tree, Node, Index, Address, Size) and
    TranslateAddress(Tree, ParentNode(Tree, Node), Address, Physical);
end;

function ReadRangeEntry(constref Tree: TDeviceTree; Bus: LongInt; Index: LongWord;
  out ChildAddress: TDeviceTreeAddress; out Physical, Size: QWord): Boolean;
var
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  ChildCells: LongWord;
  ParentCells: LongWord;
  SizeCells: LongWord;
  EntryCells: LongWord;
  Position: PByte;
  ParentAddress: TDeviceTreeAddress;
begin
  ChildAddress.CellCount := 0;
  Physical := 0;
  Size := 0;
  Result := False;
  Parent := ParentNode(Tree, Bus);
  if (Parent = NoNode) or not FindProperty(Tree, Bus, 'ranges', Prop) then
    Exit;
  ChildCells := NodeAddressCells(Tree, Bus);
  ParentCells := NodeAddressCells(Tree, Parent);
  SizeCells := NodeSizeCells(Tree, Bus);
  EntryCells := ChildCells + ParentCells + SizeCells;
  if (EntryCells = 0) or (ChildCells > MaximumAddressCells) or (ParentCells > MaximumAddressCells) or
     ((Index + 1) * EntryCells > PropertyCellCount(Prop)) then
    Exit;
  Position := Prop.Value + Index * EntryCells * 4;
  ReadAddress(Position, ChildCells, ChildAddress);
  ReadAddress(Position + ChildCells * 4, ParentCells, ParentAddress);
  Size := ReadCells(Position + (ChildCells + ParentCells) * 4, SizeCells);
  Result := TranslateAddress(Tree, Parent, ParentAddress, Physical);
end;

function FindDmaRangesBus(constref Tree: TDeviceTree; Node: LongInt): LongInt;
var
  Level: Integer;
begin
  Result := ParentNode(Tree, Node);
  for Level := 1 to MaximumTranslationLevels do
  begin
    if Result = NoNode then
      Exit;
    if NodeHasProperty(Tree, Result, 'dma-ranges') then
      Exit;
    Result := ParentNode(Tree, Result);
  end;
  Result := NoNode;
end;

function ReadDmaRange(constref Tree: TDeviceTree; Bus: LongInt; Index: LongWord;
  out BusStart, PhysicalStart, Size: QWord): Boolean;
var
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  Above: LongInt;
  ChildCells: LongWord;
  ParentCells: LongWord;
  SizeCells: LongWord;
  EntryCells: LongWord;
  Position: PByte;
  ChildAddress: TDeviceTreeAddress;
  ParentAddress: TDeviceTreeAddress;
  Level: Integer;
begin
  BusStart := 0;
  PhysicalStart := 0;
  Size := 0;
  Result := False;
  Parent := ParentNode(Tree, Bus);
  if (Parent = NoNode) or not FindProperty(Tree, Bus, 'dma-ranges', Prop) then
    Exit;
  ChildCells := NodeAddressCells(Tree, Bus);
  ParentCells := NodeAddressCells(Tree, Parent);
  SizeCells := NodeSizeCells(Tree, Bus);
  EntryCells := ChildCells + ParentCells + SizeCells;
  if (EntryCells = 0) or (ChildCells > MaximumAddressCells) or (ParentCells > MaximumAddressCells) or
     ((Index + 1) * EntryCells > PropertyCellCount(Prop)) then
    Exit;
  Position := Prop.Value + Index * EntryCells * 4;
  ReadAddress(Position, ChildCells, ChildAddress);
  ReadAddress(Position + ChildCells * 4, ParentCells, ParentAddress);
  Size := ReadCells(Position + (ChildCells + ParentCells) * 4, SizeCells);
  BusStart := AddressValue(ChildAddress);
  { Up through the dma-ranges of the buses above, where there are any. }
  for Level := 1 to MaximumTranslationLevels do
  begin
    Above := ParentNode(Tree, Parent);
    if (Above = NoNode) or not NodeHasProperty(Tree, Parent, 'dma-ranges') then
      Break;
    if not TranslateOneLevel(Tree, Parent, Above, 'dma-ranges', ParentAddress) then
      Exit;
    Parent := Above;
  end;
  PhysicalStart := AddressValue(ParentAddress);
  Result := True;
end;

function NodeIsDmaCoherent(constref Tree: TDeviceTree; Node: LongInt): Boolean;
var
  Level: Integer;
begin
  Result := False;
  for Level := 1 to MaximumTranslationLevels do
  begin
    if Node = NoNode then
      Exit;
    if NodeHasProperty(Tree, Node, 'dma-coherent') then
      Exit(True);
    if NodeHasProperty(Tree, Node, 'dma-noncoherent') then
      Exit(False);
    Node := ParentNode(Tree, Node);
  end;
end;

end.
