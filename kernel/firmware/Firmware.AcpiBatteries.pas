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
  ACPI control method batteries (devices PNP0C0A):
    _STA  bit 4: a battery is in the slot;
    _BIX  (ACPI 4.0) or _BIF: what the battery is - the unit of its
          figures (0: mW and mWh, 1: mA and mAh), its design capacity,
          its last full charge, technology, design voltage, model,
          serial number, type (chemistry) and maker;
    _BST  what it does now - state (bit 0 discharging, 1 charging, 2
          critical), present rate, remaining capacity, present voltage.
  A figure the battery does not know is FFFFFFFFh.

  Plain Pascal over the interpreter, built by the host test
  (tools/AcpiPowerTest); the kernel's Io.AcpiPower reads them under the
  interpreter's lock.
}
unit Firmware.AcpiBatteries;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

const
  AcpiBatteryTextLength = 32;
  AcpiBatteryUnknown = $FFFFFFFF;
  AcpiBatteryPresent = $10;

type
  TAcpiBatteryText = array[0..AcpiBatteryTextLength - 1] of Char;

  TAcpiBattery = record
    Node: PAmlNode;
    Path: array[0..63] of Char;
    Present: Boolean;
    { From _BIX or _BIF (False: neither answered). }
    HasInformation: Boolean;
    PowerUnit: LongWord;
    DesignCapacity: LongWord;
    LastFullCapacity: LongWord;
    Technology: LongWord;
    DesignVoltage: LongWord;
    Model: TAcpiBatteryText;
    Serial: TAcpiBatteryText;
    BatteryType: TAcpiBatteryText;
    Maker: TAcpiBatteryText;
    { From _BST. }
    HasStatus: Boolean;
    State: LongWord;
    PresentRate: LongWord;
    RemainingCapacity: LongWord;
    PresentVoltage: LongWord;
  end;

{ The battery devices; returns how many (at most Length(Nodes)). }
function ListAcpiBatteries(var Nodes: array of PAmlNode): Integer;
{ Reads one battery's _STA, _BIX or _BIF, and _BST. }
procedure ReadAcpiBattery(Node: PAmlNode; out Battery: TAcpiBattery);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Firmware.AmlValues,
  Firmware.AcpiDeviceWalk;

const
  BatteryId = 'PNP0C0A';

type
  TAmlNodeList = array[0..1023] of PAmlNode;
  PPAmlNodeList = ^TAmlNodeList;

  TBatteryList = record
    Nodes: PPAmlNodeList;
    Capacity: Integer;
    Count: Integer;
  end;
  PBatteryList = ^TBatteryList;

procedure CollectBattery(var Description: TAcpiDeviceDescription; Context: Pointer);
var
  List: PBatteryList;
  Index: Integer;
  IsBattery: Boolean;
begin
  List := PBatteryList(Context);
  IsBattery := TextIsEqual(@Description.HardwareId[0], BatteryId);
  for Index := 0 to Description.CompatibleIdCount - 1 do
    if TextIsEqual(@Description.CompatibleIds[Index][0], BatteryId) then
      IsBattery := True;
  if IsBattery and (List^.Count < List^.Capacity) then
  begin
    List^.Nodes^[List^.Count] := Description.Node;
    Inc(List^.Count);
  end;
  ReleaseValue(Description.Properties);
end;

function ListAcpiBatteries(var Nodes: array of PAmlNode): Integer;
var
  List: TBatteryList;
begin
  List.Nodes := PPAmlNodeList(@Nodes[0]);
  List.Capacity := Length(Nodes);
  List.Count := 0;
  WalkAcpiDevices(@CollectBattery, @List);
  Result := List.Count;
end;

{ Element Index of a package as a number (Unknown if it is not one). }
function ElementNumber(const Package: TAmlValue; Index: LongWord): LongWord;
var
  Element: PAmlValue;
begin
  Result := AcpiBatteryUnknown;
  if (Package.Kind <> AmlPackage) or (Index >= Package.Package^.Count) then
    Exit;
  Element := @Package.Package^.Elements[Index];
  if Element^.Kind = AmlInteger then
    Result := LongWord(Element^.Integer and $FFFFFFFF);
end;

{ Element Index as text (strings, and buffers of characters). }
procedure ElementText(const Package: TAmlValue; Index: LongWord; out Text: TAcpiBatteryText);
var
  Element: PAmlValue;
  Data: PByte;
  Length: LongWord;
  Position: LongWord;
begin
  ZeroMemory(@Text, SizeOf(Text));
  if (Package.Kind <> AmlPackage) or (Index >= Package.Package^.Count) then
    Exit;
  Element := @Package.Package^.Elements[Index];
  if not (Element^.Kind in [AmlString, AmlBuffer]) then
    Exit;
  Data := ValueData(Element^);
  Length := ValueLength(Element^);
  Position := 0;
  while (Position < Length) and (Position < AcpiBatteryTextLength - 1) and (Data[Position] <> 0) do
  begin
    if (Data[Position] >= 32) and (Data[Position] < 127) then
      Text[Position] := Char(Data[Position])
    else
      Text[Position] := '?';
    Inc(Position);
  end;
end;

{ _BIX's elements are _BIF's, shifted (after its revision, and with
  the cycle count and the measurement figures between the voltage and
  the texts). }
procedure ReadInformation(Node: PAmlNode; var Battery: TAcpiBattery);
const
  ExtendedTextStart = 16;
  PlainTextStart = 9;
var
  Value: TAmlValue;
  First: LongWord;
  TextStart: LongWord;
begin
  if EvaluateChild(Node, '_BIX', Value) and (Value.Kind = AmlPackage) and (Value.Package^.Count >= 20) then
  begin
    First := 1;
    TextStart := ExtendedTextStart;
  end
  else
  begin
    ReleaseValue(Value);
    if not EvaluateChild(Node, '_BIF', Value) or (Value.Kind <> AmlPackage) or (Value.Package^.Count < 13) then
    begin
      ReleaseValue(Value);
      Exit;
    end;
    First := 0;
    TextStart := PlainTextStart;
  end;
  Battery.HasInformation := True;
  Battery.PowerUnit := ElementNumber(Value, First);
  Battery.DesignCapacity := ElementNumber(Value, First + 1);
  Battery.LastFullCapacity := ElementNumber(Value, First + 2);
  Battery.Technology := ElementNumber(Value, First + 3);
  Battery.DesignVoltage := ElementNumber(Value, First + 4);
  ElementText(Value, TextStart, Battery.Model);
  ElementText(Value, TextStart + 1, Battery.Serial);
  ElementText(Value, TextStart + 2, Battery.BatteryType);
  ElementText(Value, TextStart + 3, Battery.Maker);
  ReleaseValue(Value);
end;

procedure ReadStatus(Node: PAmlNode; var Battery: TAcpiBattery);
var
  Value: TAmlValue;
begin
  if EvaluateChild(Node, '_BST', Value) and (Value.Kind = AmlPackage) and (Value.Package^.Count >= 4) then
  begin
    Battery.HasStatus := True;
    Battery.State := ElementNumber(Value, 0);
    Battery.PresentRate := ElementNumber(Value, 1);
    Battery.RemainingCapacity := ElementNumber(Value, 2);
    Battery.PresentVoltage := ElementNumber(Value, 3);
  end;
  ReleaseValue(Value);
end;

procedure ReadAcpiBattery(Node: PAmlNode; out Battery: TAcpiBattery);
var
  Status: QWord;
begin
  ZeroMemory(@Battery, SizeOf(Battery));
  Battery.Node := Node;
  BuildPath(Node, Battery.Path);
  Status := ChildInteger(Node, '_STA', $1F);
  Battery.Present := (Status and AcpiBatteryPresent) <> 0;
  if not Battery.Present then
    Exit;
  ReadInformation(Node, Battery);
  ReadStatus(Node, Battery);
end;

end.
