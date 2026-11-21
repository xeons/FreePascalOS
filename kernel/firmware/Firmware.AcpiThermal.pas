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
  ACPI thermal zones: ThermalZone objects anywhere in the namespace
  (usually under \_TZ), each with
    _TMP  its temperature now,
    _PSV  the passive trip point (slow the processors down above it),
    _CRT  the critical trip point (shut down above it),
    _HOT  the point to hibernate at (shown, not acted on),
    _TZP  how often to read it, in tenths of a second (0: it notifies
          instead, which is not followed: such zones are read every
          10 s).
  Temperatures are in tenths of a kelvin. Readings outside -73 C to
  177 C (2000 to 4500) are taken for firmware that does not know.

  Plain Pascal over the interpreter, built by the host test
  (tools/AcpiPowerTest); the kernel's Io.AcpiPower reads them under the
  interpreter's lock.
}
unit Firmware.AcpiThermal;

{$mode objfpc}

interface

uses
  Firmware.AmlNamespace;

const
  AcpiThermalPathLength = 64;
  { A trip point the zone does not have. }
  AcpiNoTemperature = -1;

type
  TAcpiThermalZone = record
    Node: PAmlNode;
    Path: array[0..AcpiThermalPathLength - 1] of Char;
    { Tenths of a kelvin, AcpiNoTemperature if absent. }
    PassiveDeciKelvin: LongInt;
    CriticalDeciKelvin: LongInt;
    HotDeciKelvin: LongInt;
    { _TZP, tenths of a second (0 if absent or 0). }
    PollDeciseconds: LongWord;
  end;

{ The thermal zones, their trip points read; returns how many (at most
  Length(Zones)). }
function ListAcpiThermalZones(var Zones: array of TAcpiThermalZone): Integer;
{ The zone's _TMP; False if it fails or makes no sense. }
function ReadAcpiZoneTemperature(Node: PAmlNode; out DeciKelvin: LongInt): Boolean;
function DeciKelvinToMilliCelsius(DeciKelvin: LongInt): LongInt;

implementation

uses
  Runtime.Memory,
  Firmware.AmlValues,
  Firmware.AcpiDeviceWalk;

const
  LowestSensibleDeciKelvin = 2000;
  HighestSensibleDeciKelvin = 4500;
  MaximumDepth = 24;

function SensibleTemperature(Value: QWord): Boolean;
begin
  Result := (Value >= LowestSensibleDeciKelvin) and (Value <= HighestSensibleDeciKelvin);
end;

function TripPoint(Node: PAmlNode; Name: PChar): LongInt;
var
  Value: QWord;
begin
  Value := ChildInteger(Node, Name, 0);
  if SensibleTemperature(Value) then
    Result := LongInt(Value)
  else
    Result := AcpiNoTemperature;
end;

procedure DescribeZone(Node: PAmlNode; var Zone: TAcpiThermalZone);
var
  Poll: QWord;
begin
  ZeroMemory(@Zone, SizeOf(Zone));
  Zone.Node := Node;
  BuildPath(Node, Zone.Path);
  Zone.PassiveDeciKelvin := TripPoint(Node, '_PSV');
  Zone.CriticalDeciKelvin := TripPoint(Node, '_CRT');
  Zone.HotDeciKelvin := TripPoint(Node, '_HOT');
  Poll := ChildInteger(Node, '_TZP', 0);
  if Poll > High(LongWord) then
    Poll := 0;
  Zone.PollDeciseconds := LongWord(Poll);
end;

procedure CollectZones(Scope: PAmlNode; Depth: Integer; var Zones: array of TAcpiThermalZone;
  var Count: Integer);
var
  Child: PAmlNode;
begin
  if Depth >= MaximumDepth then
    Exit;
  Child := Scope^.FirstChild;
  while Child <> nil do
  begin
    if Child^.Kind = NodeThermalZone then
    begin
      if Count <= High(Zones) then
      begin
        DescribeZone(Child, Zones[Count]);
        Inc(Count);
      end;
    end
    else if Child^.Kind in [NodeScope, NodeDevice, NodeProcessor] then
      CollectZones(Child, Depth + 1, Zones, Count);
    Child := Child^.NextSibling;
  end;
end;

function ListAcpiThermalZones(var Zones: array of TAcpiThermalZone): Integer;
begin
  Result := 0;
  if NamespaceRoot <> nil then
    CollectZones(NamespaceRoot, 0, Zones, Result);
end;

function ReadAcpiZoneTemperature(Node: PAmlNode; out DeciKelvin: LongInt): Boolean;
var
  Value: QWord;
begin
  DeciKelvin := AcpiNoTemperature;
  Value := ChildInteger(Node, '_TMP', 0);
  Result := SensibleTemperature(Value);
  if Result then
    DeciKelvin := LongInt(Value);
end;

function DeciKelvinToMilliCelsius(DeciKelvin: LongInt): LongInt;
begin
  Result := DeciKelvin * 100 - 273150;
end;

end.
