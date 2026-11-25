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
  Interrupts in a device tree.

  A device lists its interrupts in "interrupts" (specifiers of its
  interrupt parent's #interrupt-cells cells) or "interrupts-extended"
  (each with the phandle of its controller first). The interrupt parent
  is the node "interrupt-parent" names, on the device or the nearest
  node above it that has one, else the device's parent.

  A parent with an "interrupt-map" is a nexus, not a controller: the
  child's unit address (its reg, in the nexus's #address-cells) and
  specifier, masked by "interrupt-map-mask", select an entry that names
  the next parent and the specifier there. A PCI host bridge routes its
  slots' INTA-INTD this way; a Raspberry Pi 5's RP1 sits behind one too.

  The kernel's own controller is the GIC: its specifiers are three cells
  (0 for an SPI, 1 for a PPI; the number; the trigger: 1 rising edge,
  2 falling edge, 4 high level, 8 low level), so an SPI n is INTID
  n + 32 (a global system interrupt, as ACPI numbers them on AArch64)
  and a PPI n is INTID n + 16.

  Plain Pascal (the shared device tree units), built by the host test.
}
unit Firmware.DeviceTreeInterrupts;

{$mode objfpc}
{$pointermath on}

interface

uses
  DeviceTree.Blob,
  DeviceTree.Addresses;

const
  MaximumInterruptCells = 4;

type
  TDeviceTreeInterrupt = record
    { The node the specifier is for: a controller, or a nexus until
      ResolveInterrupt has gone through it. }
    Parent: LongInt;
    CellCount: LongWord;
    Cells: array[0..MaximumInterruptCells - 1] of LongWord;
  end;

  TGicInterrupt = record
    Intid: LongWord;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
  end;

{ The interrupt parent of Node, or NoNode. }
function InterruptParentOf(constref Tree: TDeviceTree; Node: LongInt): LongInt;
{ A controller's or nexus's #interrupt-cells (0 if it has none). }
function InterruptCellsOf(constref Tree: TDeviceTree; Node: LongInt): LongWord;

{ How many interrupts Node lists, and interrupt Index as written. }
function NodeInterruptCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
function ReadNodeInterrupt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Interrupt: TDeviceTreeInterrupt): Boolean;

{ Through the interrupt-map of each nexus until a controller, the child
  having unit address ChildAddress at the first nexus. }
function ResolveInterrupt(constref Tree: TDeviceTree; var Interrupt: TDeviceTreeInterrupt;
  constref ChildAddress: TDeviceTreeAddress): Boolean;

function IsGicController(constref Tree: TDeviceTree; Node: LongInt): Boolean;
{ A resolved specifier of a GIC as an INTID. }
function DecodeGicInterrupt(constref Tree: TDeviceTree; constref Interrupt: TDeviceTreeInterrupt;
  out Gic: TGicInterrupt): Boolean;
{ Interrupt Index of Node, resolved (with Node's reg as its unit address)
  and decoded. False if it does not end at the GIC. }
function NodeGicInterrupt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Gic: TGicInterrupt): Boolean;

implementation

const
  MaximumNexusLevels = 8;
  MaximumParentSearch = 64;

  GicSharedInterrupt = 0;
  GicPrivateInterrupt = 1;
  GicFirstShared = 32;
  GicFirstPrivate = 16;
  TriggerRisingEdge = 1;
  TriggerFallingEdge = 2;
  TriggerHighLevel = 4;
  TriggerLowLevel = 8;

function InterruptCellsOf(constref Tree: TDeviceTree; Node: LongInt): LongWord;
begin
  if not ReadCellProperty(Tree, Node, '#interrupt-cells', Result) then
    Result := 0;
end;

function InterruptParentOf(constref Tree: TDeviceTree; Node: LongInt): LongInt;
var
  Phandle: LongWord;
  Step: Integer;
begin
  Result := Node;
  for Step := 1 to MaximumParentSearch do
  begin
    if ReadCellProperty(Tree, Result, 'interrupt-parent', Phandle) then
      Result := FindNodeByPhandle(Tree, Phandle)
    else
      Result := ParentNode(Tree, Result);
    if Result = NoNode then
      Exit;
    if NodeHasProperty(Tree, Result, '#interrupt-cells') then
      Exit;
  end;
  Result := NoNode;
end;

procedure ClearInterrupt(out Interrupt: TDeviceTreeInterrupt);
var
  Index: Integer;
begin
  Interrupt.Parent := NoNode;
  Interrupt.CellCount := 0;
  for Index := 0 to MaximumInterruptCells - 1 do
    Interrupt.Cells[Index] := 0;
end;

procedure ReadSpecifier(Data: PByte; CellCount: LongWord; Parent: LongInt; out Interrupt: TDeviceTreeInterrupt);
var
  Index: LongWord;
begin
  ClearInterrupt(Interrupt);
  Interrupt.Parent := Parent;
  if CellCount > MaximumInterruptCells then
    CellCount := MaximumInterruptCells;
  Interrupt.CellCount := CellCount;
  Index := 0;
  while Index < CellCount do
  begin
    Interrupt.Cells[Index] := ReadBigEndian32(Data + Index * 4);
    Inc(Index);
  end;
end;

{ Walks "interrupts-extended": the cell offset of entry Index, its
  parent and its cell count. }
function FindExtendedEntry(constref Tree: TDeviceTree; constref Prop: TDeviceTreeProperty; Index: LongWord;
  out CellOffset: LongWord; out Parent: LongInt; out CellCount: LongWord): Boolean;
var
  Position: LongWord;
  Entry: LongWord;
  Total: LongWord;
begin
  Result := False;
  CellOffset := 0;
  Parent := NoNode;
  CellCount := 0;
  Total := PropertyCellCount(Prop);
  Position := 0;
  Entry := 0;
  while Position < Total do
  begin
    Parent := FindNodeByPhandle(Tree, PropertyCell(Prop, Position));
    if Parent = NoNode then
      Exit;
    CellCount := InterruptCellsOf(Tree, Parent);
    if Position + 1 + CellCount > Total then
      Exit;
    if Entry = Index then
    begin
      CellOffset := Position + 1;
      Exit(True);
    end;
    Position := Position + 1 + CellCount;
    Inc(Entry);
  end;
end;

function NodeInterruptCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
var
  Prop: TDeviceTreeProperty;
  CellOffset: LongWord;
  Parent: LongInt;
  CellCount: LongWord;
begin
  Result := 0;
  if FindProperty(Tree, Node, 'interrupts-extended', Prop) then
  begin
    while FindExtendedEntry(Tree, Prop, Result, CellOffset, Parent, CellCount) do
      Inc(Result);
    Exit;
  end;
  if not FindProperty(Tree, Node, 'interrupts', Prop) then
    Exit;
  CellCount := InterruptCellsOf(Tree, InterruptParentOf(Tree, Node));
  if CellCount > 0 then
    Result := PropertyCellCount(Prop) div CellCount;
end;

function ReadNodeInterrupt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Interrupt: TDeviceTreeInterrupt): Boolean;
var
  Prop: TDeviceTreeProperty;
  CellOffset: LongWord;
  Parent: LongInt;
  CellCount: LongWord;
begin
  ClearInterrupt(Interrupt);
  Result := False;
  if FindProperty(Tree, Node, 'interrupts-extended', Prop) then
  begin
    if not FindExtendedEntry(Tree, Prop, Index, CellOffset, Parent, CellCount) then
      Exit;
    ReadSpecifier(Prop.Value + CellOffset * 4, CellCount, Parent, Interrupt);
    Exit(True);
  end;
  if not FindProperty(Tree, Node, 'interrupts', Prop) then
    Exit;
  Parent := InterruptParentOf(Tree, Node);
  CellCount := InterruptCellsOf(Tree, Parent);
  if (Parent = NoNode) or (CellCount = 0) or ((Index + 1) * CellCount > PropertyCellCount(Prop)) then
    Exit;
  ReadSpecifier(Prop.Value + Index * CellCount * 4, CellCount, Parent, Interrupt);
  Result := True;
end;

function MaskedCell(constref Mask: TDeviceTreeProperty; HasMask: Boolean; Index, Value: LongWord): LongWord;
begin
  if HasMask and (Index < PropertyCellCount(Mask)) then
    Result := Value and PropertyCell(Mask, Index)
  else
    Result := Value;
end;

{ One step through Nexus's interrupt-map. }
function MapThroughNexus(constref Tree: TDeviceTree; Nexus: LongInt; var Interrupt: TDeviceTreeInterrupt;
  var ChildAddress: TDeviceTreeAddress): Boolean;
var
  Map: TDeviceTreeProperty;
  Mask: TDeviceTreeProperty;
  HasMask: Boolean;
  AddressCells: LongWord;
  InterruptCells: LongWord;
  Total: LongWord;
  Position: LongWord;
  Index: LongWord;
  Matches: Boolean;
  Parent: LongInt;
  ParentAddressCells: LongWord;
  ParentInterruptCells: LongWord;
  Wanted: LongWord;
begin
  Result := False;
  if not FindProperty(Tree, Nexus, 'interrupt-map', Map) then
    Exit;
  HasMask := FindProperty(Tree, Nexus, 'interrupt-map-mask', Mask);
  { The unit address is in the nexus's #address-cells (0 if it has
    none). }
  if not ReadCellProperty(Tree, Nexus, '#address-cells', AddressCells) then
    AddressCells := 0;
  InterruptCells := InterruptCellsOf(Tree, Nexus);
  if (AddressCells > MaximumAddressCells) or (InterruptCells <> Interrupt.CellCount) then
    Exit;
  Total := PropertyCellCount(Map);
  Position := 0;
  while Position + AddressCells + InterruptCells + 1 <= Total do
  begin
    Matches := True;
    Index := 0;
    while Index < AddressCells do
    begin
      if Index < ChildAddress.CellCount then
        Wanted := ChildAddress.Cells[Index]
      else
        Wanted := 0;
      if MaskedCell(Mask, HasMask, Index, Wanted) <> PropertyCell(Map, Position + Index) then
        Matches := False;
      Inc(Index);
    end;
    Index := 0;
    while Index < InterruptCells do
    begin
      if MaskedCell(Mask, HasMask, AddressCells + Index, Interrupt.Cells[Index]) <>
         PropertyCell(Map, Position + AddressCells + Index) then
        Matches := False;
      Inc(Index);
    end;
    Position := Position + AddressCells + InterruptCells;
    Parent := FindNodeByPhandle(Tree, PropertyCell(Map, Position));
    if Parent = NoNode then
      Exit;
    Inc(Position);
    if not ReadCellProperty(Tree, Parent, '#address-cells', ParentAddressCells) then
      ParentAddressCells := 0;
    ParentInterruptCells := InterruptCellsOf(Tree, Parent);
    { Cell counts no specifier has are a broken tree (and are kept from
      making the sums below wrap). }
    if (ParentAddressCells > MaximumAddressCells) or (ParentInterruptCells > MaximumInterruptCells) or
       (QWord(Position) + ParentAddressCells + ParentInterruptCells > Total) then
      Exit;
    if Matches then
    begin
      ReadAddress(Map.Value + Position * 4, ParentAddressCells, ChildAddress);
      ReadSpecifier(Map.Value + (Position + ParentAddressCells) * 4, ParentInterruptCells, Parent, Interrupt);
      Exit(True);
    end;
    Position := Position + ParentAddressCells + ParentInterruptCells;
  end;
end;

function ResolveInterrupt(constref Tree: TDeviceTree; var Interrupt: TDeviceTreeInterrupt;
  constref ChildAddress: TDeviceTreeAddress): Boolean;
var
  Address: TDeviceTreeAddress;
  Level: Integer;
begin
  Address := ChildAddress;
  for Level := 1 to MaximumNexusLevels do
  begin
    if Interrupt.Parent = NoNode then
      Exit(False);
    if NodeHasProperty(Tree, Interrupt.Parent, 'interrupt-controller') then
      Exit(True);
    if not MapThroughNexus(Tree, Interrupt.Parent, Interrupt, Address) then
      Exit(False);
  end;
  Result := False;
end;

function IsGicController(constref Tree: TDeviceTree; Node: LongInt): Boolean;
begin
  Result := NodeIsCompatible(Tree, Node, 'arm,gic-400') or NodeIsCompatible(Tree, Node, 'arm,cortex-a15-gic') or
    NodeIsCompatible(Tree, Node, 'arm,cortex-a9-gic') or NodeIsCompatible(Tree, Node, 'arm,cortex-a7-gic') or
    NodeIsCompatible(Tree, Node, 'arm,gic-v3') or NodeIsCompatible(Tree, Node, 'arm,gic-v2');
end;

function DecodeGicInterrupt(constref Tree: TDeviceTree; constref Interrupt: TDeviceTreeInterrupt;
  out Gic: TGicInterrupt): Boolean;
var
  Trigger: LongWord;
begin
  Gic.Intid := 0;
  Gic.LevelTriggered := True;
  Gic.ActiveLow := False;
  Result := False;
  if (Interrupt.CellCount < 3) or not IsGicController(Tree, Interrupt.Parent) then
    Exit;
  case Interrupt.Cells[0] of
    GicSharedInterrupt: Gic.Intid := Interrupt.Cells[1] + GicFirstShared;
    GicPrivateInterrupt: Gic.Intid := Interrupt.Cells[1] + GicFirstPrivate;
  else
    Exit;
  end;
  Trigger := Interrupt.Cells[2] and $F;
  Gic.LevelTriggered := (Trigger and (TriggerHighLevel or TriggerLowLevel)) <> 0;
  Gic.ActiveLow := (Trigger and (TriggerFallingEdge or TriggerLowLevel)) <> 0;
  if Trigger = 0 then
    Gic.LevelTriggered := True;
  Result := True;
end;

function NodeGicInterrupt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Gic: TGicInterrupt): Boolean;
var
  Interrupt: TDeviceTreeInterrupt;
  Address: TDeviceTreeAddress;
  Size: QWord;
begin
  Gic.Intid := 0;
  Gic.LevelTriggered := True;
  Gic.ActiveLow := False;
  Result := False;
  if not ReadNodeInterrupt(Tree, Node, Index, Interrupt) then
    Exit;
  if not ReadRegister(Tree, Node, 0, Address, Size) then
    Address.CellCount := 0;
  Result := ResolveInterrupt(Tree, Interrupt, Address) and DecodeGicInterrupt(Tree, Interrupt, Gic);
end;

end.
