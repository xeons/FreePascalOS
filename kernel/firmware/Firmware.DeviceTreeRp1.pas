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
  The Raspberry Pi 5's RP1 in its device tree.

  RP1 is a PCIe device (1de4:0001) behind the BCM2712's pcie2. Its
  peripherals are described below the host bridge's node, in a node
  named "rp1" (a "simple-bus"; newer trees put it below "pci@0,0" and
  "dev@0,0" and call it "rp1@0"):

    rp1
        #address-cells = 2, #size-cells = 2
        interrupt-controller, #interrupt-cells = 2
        ranges = C0_4000_0000 -> PCI 0200_0000 0 0 (32-bit memory, 0),
                 size 41_0000h
        ethernet@100000
            reg = C0_4010_0000, size 4000h
            interrupts = 6, level high
        ...

  The peripherals' addresses are RP1's own (its internal bus puts them
  at C0_4000_0000); "ranges" says that window is PCI memory at bus
  address 0 for 41_0000h bytes: BAR1 (4 MiB of peripherals) and BAR2
  (64 KiB of shared memory) right after it, which is where the firmware
  and Linux put them. The interrupts are RP1's own numbers (0-60), each
  raised through MSI-X vector of the same number, with the trigger
  (4: level, 1: edge).

  This unit reads that: the window, a peripheral's register range as an
  offset into it, its RP1 interrupt numbers. The RP1 driver turns the
  offsets into processor addresses through RP1's BARs (wherever they
  actually are) and connects the interrupts.

  Plain Pascal (the shared device tree units), built by the host test.
}
unit Firmware.DeviceTreeRp1;

{$mode objfpc}
{$pointermath on}

interface

uses
  DeviceTree.Blob;

const
  { What the trees have had; used when the node has no "ranges". }
  DefaultRp1ChildBase = QWord($C040000000);
  DefaultRp1WindowSize = QWord($410000);

  { RP1's interrupt numbers: RP1_INT_END. }
  Rp1InterruptCount = 61;

type
  TRp1Window = record
    { The "rp1" node. }
    Node: LongInt;
    { RP1's address of the window's start (C0_4000_0000). }
    ChildBase: QWord;
    { Where the window is on the PCI bus as the tree has it, and its
      space code (DeviceTree.Addresses' PciSpace*). }
    PciAddress: QWord;
    PciSpace: LongWord;
    Size: QWord;
    { The tree gave "ranges" (else the defaults are used). }
    FromRanges: Boolean;
  end;

  TRp1Interrupt = record
    Number: LongWord;
    LevelTriggered: Boolean;
  end;

{ The RP1 node below a PCIe host's node (up to three levels down), or
  NoNode. }
function FindRp1Node(constref Tree: TDeviceTree; HostNode: LongInt): LongInt;
{ The RP1 node's window (the defaults if it has no usable "ranges"). }
procedure ReadRp1Window(constref Tree: TDeviceTree; Rp1Node: LongInt; out Window: TRp1Window);
{ Node is Ancestor or below it. }
function NodeIsWithin(constref Tree: TDeviceTree; Node, Ancestor: LongInt): Boolean;

{ "reg" entry Index of a peripheral (a child of the RP1 node) as an
  offset into the window and a size. False if there is no such entry or
  it is outside the window. }
function Rp1RegisterOffset(constref Tree: TDeviceTree; constref Window: TRp1Window; Node: LongInt;
  Index: LongWord; out Offset, Size: QWord): Boolean;

{ How many interrupts Node lists, and interrupt Index as RP1's number
  and trigger. False if it is not one of RP1's interrupts. }
function Rp1NodeInterruptCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
function ReadRp1Interrupt(constref Tree: TDeviceTree; constref Window: TRp1Window; Node: LongInt;
  Index: LongWord; out Interrupt: TRp1Interrupt): Boolean;

implementation

uses
  DeviceTree.Addresses,
  Firmware.DeviceTreeInterrupts;

const
  MaximumSearchDepth = 3;
  MaximumAncestorSteps = 64;
  TriggerLevelMask = $C;

function NameStartsWithRp1(Name: PChar): Boolean;
begin
  Result := (Name <> nil) and (Name[0] = 'r') and (Name[1] = 'p') and (Name[2] = '1') and
    ((Name[3] = #0) or (Name[3] = '@'));
end;

function SearchBelow(constref Tree: TDeviceTree; Node: LongInt; Depth: Integer): LongInt;
var
  Child: LongInt;
begin
  Result := NoNode;
  if Depth > MaximumSearchDepth then
    Exit;
  Child := FirstChildNode(Tree, Node);
  while Child <> NoNode do
  begin
    if NameStartsWithRp1(NodeName(Tree, Child)) then
      Exit(Child);
    Child := NextSiblingNode(Tree, Child);
  end;
  Child := FirstChildNode(Tree, Node);
  while Child <> NoNode do
  begin
    Result := SearchBelow(Tree, Child, Depth + 1);
    if Result <> NoNode then
      Exit;
    Child := NextSiblingNode(Tree, Child);
  end;
end;

function FindRp1Node(constref Tree: TDeviceTree; HostNode: LongInt): LongInt;
begin
  Result := NoNode;
  if HostNode <> NoNode then
    Result := SearchBelow(Tree, HostNode, 1);
end;

procedure ReadRp1Window(constref Tree: TDeviceTree; Rp1Node: LongInt; out Window: TRp1Window);
var
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  ChildCells: LongWord;
  ParentCells: LongWord;
  SizeCells: LongWord;
  ChildAddress: TDeviceTreeAddress;
  ParentAddress: TDeviceTreeAddress;
begin
  Window.Node := Rp1Node;
  Window.ChildBase := DefaultRp1ChildBase;
  Window.PciAddress := 0;
  Window.PciSpace := PciSpaceMemory32;
  Window.Size := DefaultRp1WindowSize;
  Window.FromRanges := False;
  if Rp1Node = NoNode then
    Exit;
  Parent := ParentNode(Tree, Rp1Node);
  if (Parent = NoNode) or not FindProperty(Tree, Rp1Node, 'ranges', Prop) then
    Exit;
  ChildCells := NodeAddressCells(Tree, Rp1Node);
  ParentCells := NodeAddressCells(Tree, Parent);
  SizeCells := NodeSizeCells(Tree, Rp1Node);
  if (ChildCells = 0) or (ChildCells > MaximumAddressCells) or (ParentCells > MaximumAddressCells) or
     (PropertyCellCount(Prop) < ChildCells + ParentCells + SizeCells) then
    Exit;
  ReadAddress(Prop.Value, ChildCells, ChildAddress);
  ReadAddress(Prop.Value + ChildCells * 4, ParentCells, ParentAddress);
  Window.ChildBase := AddressValue(ChildAddress);
  Window.PciAddress := AddressValue(ParentAddress);
  if ParentCells = 3 then
    Window.PciSpace := PciAddressSpace(ParentAddress);
  Window.Size := ReadCells(Prop.Value + (ChildCells + ParentCells) * 4, SizeCells);
  Window.FromRanges := Window.Size <> 0;
  if not Window.FromRanges then
  begin
    Window.ChildBase := DefaultRp1ChildBase;
    Window.Size := DefaultRp1WindowSize;
  end;
end;

function NodeIsWithin(constref Tree: TDeviceTree; Node, Ancestor: LongInt): Boolean;
var
  Steps: Integer;
begin
  Result := False;
  if Ancestor = NoNode then
    Exit;
  Steps := 0;
  while (Node <> NoNode) and (Steps < MaximumAncestorSteps) do
  begin
    if Node = Ancestor then
      Exit(True);
    Node := ParentNode(Tree, Node);
    Inc(Steps);
  end;
end;

function Rp1RegisterOffset(constref Tree: TDeviceTree; constref Window: TRp1Window; Node: LongInt;
  Index: LongWord; out Offset, Size: QWord): Boolean;
var
  Address: TDeviceTreeAddress;
  Value: QWord;
begin
  Offset := 0;
  Size := 0;
  Result := False;
  if (Window.Node = NoNode) or (ParentNode(Tree, Node) <> Window.Node) then
    Exit;
  if not ReadRegister(Tree, Node, Index, Address, Size) then
    Exit;
  Value := AddressValue(Address);
  if (Value < Window.ChildBase) or (Value - Window.ChildBase >= Window.Size) then
    Exit;
  Offset := Value - Window.ChildBase;
  { A range running past the window's end is cut there. }
  if Size > Window.Size - Offset then
    Size := Window.Size - Offset;
  Result := True;
end;

function Rp1NodeInterruptCount(constref Tree: TDeviceTree; Node: LongInt): LongWord;
begin
  Result := NodeInterruptCount(Tree, Node);
end;

function ReadRp1Interrupt(constref Tree: TDeviceTree; constref Window: TRp1Window; Node: LongInt;
  Index: LongWord; out Interrupt: TRp1Interrupt): Boolean;
var
  Specifier: TDeviceTreeInterrupt;
begin
  Interrupt.Number := 0;
  Interrupt.LevelTriggered := True;
  Result := False;
  if (Window.Node = NoNode) or not ReadNodeInterrupt(Tree, Node, Index, Specifier) then
    Exit;
  if (Specifier.Parent <> Window.Node) or (Specifier.CellCount < 1) then
    Exit;
  Interrupt.Number := Specifier.Cells[0];
  if Specifier.CellCount >= 2 then
    Interrupt.LevelTriggered := (Specifier.Cells[1] and TriggerLevelMask) <> 0;
  Result := Interrupt.Number < Rp1InterruptCount;
end;

end.
