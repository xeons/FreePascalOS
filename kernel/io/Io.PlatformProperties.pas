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
  A platform device's named properties, wherever they came from: an
  ACPI device's _DSD (Firmware.AcpiProperties) or a device tree node's
  own properties, which share most names ("local-mac-address",
  "clock-frequency", "phy-mode"). A driver serving both kinds of machine
  reads them here.

  Device tree integers are one cell (32 bits) or two (64 bits); byte
  properties are the value as it is; text properties are zero
  terminated strings.
}
unit Io.PlatformProperties;

{$mode objfpc}

interface

uses
  Io.PlatformDevices;

function PlatformPropertyInteger(Device: PPlatformDevice; Name: PChar; out Number: QWord): Boolean;
{ Up to Capacity bytes; Length says how many the property has. }
function PlatformPropertyBytes(Device: PPlatformDevice; Name: PChar; Data: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
{ Zero terminated, cut to Capacity - 1 characters. }
function PlatformPropertyText(Device: PPlatformDevice; Name: PChar; Text: PChar; Capacity: LongWord): Boolean;
function PlatformHasProperty(Device: PPlatformDevice; Name: PChar): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  DeviceTree.Blob,
  Firmware.AmlValues,
  Firmware.AcpiProperties,
  Firmware.DeviceTree;

function FindNodeProperty(Device: PPlatformDevice; Name: PChar; out Prop: TDeviceTreeProperty): Boolean;
begin
  Result := (Device^.DeviceTreeNode <> NoDeviceTreeNode) and
    FindProperty(SystemDeviceTree^, Device^.DeviceTreeNode, Name, Prop);
end;

function PlatformPropertyInteger(Device: PPlatformDevice; Name: PChar; out Number: QWord): Boolean;
var
  Prop: TDeviceTreeProperty;
begin
  Number := 0;
  if Device^.DeviceTreeNode = NoDeviceTreeNode then
    Exit(DevicePropertyInteger(Device^.Properties, Name, Number));
  Result := FindNodeProperty(Device, Name, Prop) and ((Prop.Length = 4) or (Prop.Length = 8));
  if Result then
    Number := ReadCells(Prop.Value, Prop.Length div 4);
end;

function PlatformPropertyBytes(Device: PPlatformDevice; Name: PChar; Data: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
var
  Prop: TDeviceTreeProperty;
  Count: LongWord;
begin
  Length := 0;
  if Device^.DeviceTreeNode = NoDeviceTreeNode then
    Exit(DevicePropertyBytes(Device^.Properties, Name, Data, Capacity, Length));
  Result := FindNodeProperty(Device, Name, Prop);
  if not Result then
    Exit;
  Length := Prop.Length;
  Count := Prop.Length;
  if Count > Capacity then
    Count := Capacity;
  CopyMemory(Data, Prop.Value, Count);
end;

function PlatformPropertyText(Device: PPlatformDevice; Name: PChar; Text: PChar; Capacity: LongWord): Boolean;
var
  Value: PChar;
begin
  if Device^.DeviceTreeNode = NoDeviceTreeNode then
    Exit(DevicePropertyText(Device^.Properties, Name, Text, Capacity));
  Value := ReadTextProperty(SystemDeviceTree^, Device^.DeviceTreeNode, Name);
  Result := (Value <> nil) and (Capacity > 0);
  if Result then
    CopyText(Text, Value, Capacity);
end;

function PlatformHasProperty(Device: PPlatformDevice; Name: PChar): Boolean;
var
  Prop: TDeviceTreeProperty;
  Value: TAmlValue;
begin
  if Device^.DeviceTreeNode = NoDeviceTreeNode then
    Result := FindDeviceProperty(Device^.Properties, Name, Value)
  else
    Result := FindNodeProperty(Device, Name, Prop);
end;

end.
