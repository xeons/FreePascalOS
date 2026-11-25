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
  Devices that can wake the machine, from their _PRW.

  A device that may wake the machine from a sleep state has a _PRW:
  the general purpose event its wake signal raises (an integer, a GPE
  of the FADT's blocks; or a package of a GPE block device and an index,
  whose index is taken), the deepest sleep state it can wake from, and
  the power resources it needs on to do so. Every device (with or
  without a _HID: PCI functions have an _ADR) is looked at.

  What kind of device it is decides whether it wakes by default: the
  power and sleep buttons (PNP0C0C, PNP0C0E) and the lid (PNP0C0D) by
  their ids; a PCI function by its _ADR under a root bridge (its bus
  from _BBN) whose class the caller looks up, or, failing that, by the
  names firmware gives them (XHC, EHC, UHC, USB for USB controllers;
  LAN, GLAN, NIC, ETH for network cards).

  Arming one for a sleep state: its power resources on (_ON), then
  _DSW(1, state, 0), or the older _PSW(1); disarming the reverse (_DSW
  or _PSW with 0). The GPE is the caller's to enable.

  Plain Pascal over the interpreter (the host test tools/AcpiPowerTest
  reads a table's wake devices with it).
}
unit Firmware.AcpiWakeDevices;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

const
  AcpiWakePathLength = 64;
  MaximumWakePowerResources = 4;

  { TAcpiWakeDevice.Kind (the ABI's WakeSource* values). }
  AcpiWakeOther = 0;
  AcpiWakePowerButton = 1;
  AcpiWakeSleepButton = 2;
  AcpiWakeLid = 3;
  AcpiWakeUsb = 4;
  AcpiWakeNetwork = 5;

type
  TAcpiWakeDevice = record
    Node: PAmlNode;
    Path: array[0..AcpiWakePathLength - 1] of Char;
    GpeNumber: LongWord;
    { From a GPE block device rather than the FADT's blocks. }
    GpeOfBlockDevice: Boolean;
    DeepestSleepState: Byte;
    Kind: LongWord;
    { A PCI function under a root bridge: where it is. }
    IsPciFunction: Boolean;
    PciSegment: Word;
    PciBus: Byte;
    PciDevice: Byte;
    PciFunction: Byte;
    PowerResources: array[0..MaximumWakePowerResources - 1] of PAmlNode;
    PowerResourceCount: Integer;
  end;

{ The devices with a usable _PRW (up to Length(Devices)); returns how
  many. }
function ListAcpiWakeDevices(var Devices: array of TAcpiWakeDevice): Integer;
{ Arms (Enable) or disarms the device for sleep state TargetState. False
  if it has neither _DSW nor _PSW (nothing to tell it, which is fine). }
function ArmAcpiWakeDevice(constref Device: TAcpiWakeDevice; Enable: Boolean; TargetState: Byte): Boolean;
{ The kind a PCI class (class code, subclass) stands for. }
function WakeKindOfPciClass(ClassCode, Subclass: Byte): LongWord;

implementation

uses
  Runtime.Memory,
  Firmware.AmlValues,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiDeviceWalk;

const
  MaximumDepth = 24;
  PciClassNetwork = $02;
  PciClassSerialBus = $0C;
  PciSubclassUsb = $03;

function WakeKindOfPciClass(ClassCode, Subclass: Byte): LongWord;
begin
  if (ClassCode = PciClassSerialBus) and (Subclass = PciSubclassUsb) then
    Result := AcpiWakeUsb
  else if ClassCode = PciClassNetwork then
    Result := AcpiWakeNetwork
  else
    Result := AcpiWakeOther;
end;

function ResolveNode(const Value: TAmlValue): PAmlNode;
begin
  case Value.Kind of
    AmlNodeReference:
      Result := PAmlNode(Value.Node);
    AmlNamePath:
      Result := LookupNameString(PAmlNode(Value.Node), Value.Bytes^.Data, Value.Bytes^.Length);
    AmlString:
      Result := LookupText(NamespaceRoot, PChar(Value.Bytes^.Data));
  else
    Result := nil;
  end;
end;

function NameStartsWith(Node: PAmlNode; Prefix: PChar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while Prefix[Index] <> #0 do
  begin
    if (Index > 3) or (Node^.Name[Index] <> Prefix[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function KindByName(Node: PAmlNode): LongWord;
begin
  if NameStartsWith(Node, 'XHC') or NameStartsWith(Node, 'EHC') or NameStartsWith(Node, 'UHC') or
     NameStartsWith(Node, 'USB') then
    Result := AcpiWakeUsb
  else if NameStartsWith(Node, 'LAN') or NameStartsWith(Node, 'GLAN') or NameStartsWith(Node, 'NIC') or
     NameStartsWith(Node, 'ETH') then
    Result := AcpiWakeNetwork
  else
    Result := AcpiWakeOther;
end;

function IsPciRootBridge(Node: PAmlNode): Boolean;
begin
  Result := DeviceHasId(Node, 'PNP0A03') or DeviceHasId(Node, 'PNP0A08');
end;

{ A PCI function right under a root bridge: its address. }
procedure FindPciAddress(Node: PAmlNode; var Device: TAcpiWakeDevice);
var
  Address: QWord;
  Parent: PAmlNode;
begin
  Parent := Node^.Parent;
  if (Parent = nil) or (FindChild(Node, SegmentOf('_ADR')) = nil) or not IsPciRootBridge(Parent) then
    Exit;
  Address := ChildInteger(Node, '_ADR', High(QWord));
  if (Address = High(QWord)) or ((Address shr 16) > 31) or ((Address and $FFFF) > 7) then
    Exit;
  Device.IsPciFunction := True;
  Device.PciSegment := Word(ChildInteger(Parent, '_SEG', 0));
  Device.PciBus := Byte(ChildInteger(Parent, '_BBN', 0));
  Device.PciDevice := Byte(Address shr 16);
  Device.PciFunction := Byte(Address and $FFFF);
end;

function ClassifyDevice(Node: PAmlNode): LongWord;
begin
  if DeviceHasId(Node, 'PNP0C0C') then
    Result := AcpiWakePowerButton
  else if DeviceHasId(Node, 'PNP0C0E') then
    Result := AcpiWakeSleepButton
  else if DeviceHasId(Node, 'PNP0C0D') then
    Result := AcpiWakeLid
  else
    Result := KindByName(Node);
end;

{ The event of _PRW's first element: a GPE number, or a package of a
  block device and an index. }
function ReadWakeEvent(const Event: TAmlValue; var Device: TAcpiWakeDevice): Boolean;
var
  Number: QWord;
begin
  Result := False;
  if Event.Kind = AmlPackage then
  begin
    if (Event.Package^.Count < 2) or not ValueToInteger(Event.Package^.Elements[1], True, Number) then
      Exit;
    Device.GpeOfBlockDevice := True;
  end
  else if not ValueToInteger(Event, True, Number) then
    Exit;
  if Number > $FF then
    Exit;
  Device.GpeNumber := LongWord(Number);
  Result := True;
end;

function DescribeWakeDevice(Node: PAmlNode; out Device: TAcpiWakeDevice): Boolean;
var
  Wake: TAmlValue;
  Elements: PAmlValue;
  Count: LongWord;
  Index: LongWord;
  State: QWord;
  Resource: PAmlNode;
begin
  ZeroMemory(@Device, SizeOf(Device));
  Result := False;
  if not EvaluateChild(Node, '_PRW', Wake) then
    Exit;
  if (Wake.Kind = AmlPackage) and (Wake.Package^.Count >= 2) then
  begin
    Elements := Wake.Package^.Elements;
    Count := Wake.Package^.Count;
    if ReadWakeEvent(Elements[0], Device) and ValueToInteger(Elements[1], True, State) and (State <= 5) then
    begin
      Device.Node := Node;
      BuildPath(Node, Device.Path);
      Device.DeepestSleepState := Byte(State);
      Index := 2;
      while (Index < Count) and (Device.PowerResourceCount < MaximumWakePowerResources) do
      begin
        Resource := ResolveNode(Elements[Index]);
        if (Resource <> nil) and (Resource^.Kind = NodePowerResource) then
        begin
          Device.PowerResources[Device.PowerResourceCount] := Resource;
          Inc(Device.PowerResourceCount);
        end;
        Inc(Index);
      end;
      Device.Kind := ClassifyDevice(Node);
      FindPciAddress(Node, Device);
      Result := True;
    end;
  end;
  ReleaseValue(Wake);
end;

procedure CollectWakeDevices(Scope: PAmlNode; Depth: Integer; var Devices: array of TAcpiWakeDevice;
  var Count: Integer);
var
  Child: PAmlNode;
begin
  if Depth >= MaximumDepth then
    Exit;
  Child := Scope^.FirstChild;
  while Child <> nil do
  begin
    if Child^.Kind in [NodeDevice, NodeProcessor, NodeThermalZone] then
    begin
      if (Count <= High(Devices)) and (FindChild(Child, SegmentOf('_PRW')) <> nil) and
         DescribeWakeDevice(Child, Devices[Count]) then
        Inc(Count);
      CollectWakeDevices(Child, Depth + 1, Devices, Count);
    end
    else if Child^.Kind = NodeScope then
      CollectWakeDevices(Child, Depth + 1, Devices, Count);
    Child := Child^.NextSibling;
  end;
end;

function ListAcpiWakeDevices(var Devices: array of TAcpiWakeDevice): Integer;
begin
  Result := 0;
  if NamespaceRoot <> nil then
    CollectWakeDevices(NamespaceRoot, 0, Devices, Result);
end;

procedure TurnOnPowerResources(constref Device: TAcpiWakeDevice);
var
  Index: Integer;
  Ignored: TAmlValue;
begin
  for Index := 0 to Device.PowerResourceCount - 1 do
    if EvaluatePath(Device.PowerResources[Index], '_ON', nil, 0, Ignored) then
      ReleaseValue(Ignored);
end;

function ArmAcpiWakeDevice(constref Device: TAcpiWakeDevice; Enable: Boolean; TargetState: Byte): Boolean;
var
  Arguments: array[0..2] of TAmlValue;
  Ignored: TAmlValue;
  EnableValue: QWord;
begin
  if Enable then
  begin
    TurnOnPowerResources(Device);
    EnableValue := 1;
  end
  else
    EnableValue := 0;
  Arguments[0] := MakeInteger(EnableValue);
  Arguments[1] := MakeInteger(TargetState);
  Arguments[2] := MakeInteger(0);
  if FindChild(Device.Node, SegmentOf('_DSW')) <> nil then
    Result := EvaluatePath(Device.Node, '_DSW', @Arguments[0], 3, Ignored)
  else if FindChild(Device.Node, SegmentOf('_PSW')) <> nil then
    Result := EvaluatePath(Device.Node, '_PSW', @Arguments[0], 1, Ignored)
  else
    Exit(False);
  if Result then
    ReleaseValue(Ignored);
end;

end.
