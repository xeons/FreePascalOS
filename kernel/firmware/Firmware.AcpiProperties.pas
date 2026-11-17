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
  Device properties from a device's _DSD (device specific data).

  _DSD is a package of pairs: a UUID (a 16-byte buffer, as ToUUID makes
  it) and a package whose format the UUID names. The one read here is
  the device properties UUID daffd814-6eba-4d8c-8a91-bc9bbf4aa301: a
  package of two-element packages, a property name (a string) and its
  value (an integer, a string, a buffer, or a package of them), such as

    Package ("local-mac-address", Buffer (6) holding the address)
    Package ("phy-mode", "rgmii-rxid")

  (written here with parentheses for the braces ASL uses)

  Plain Pascal over the interpreter's values, so the host test
  (tools/AcpiDeviceTest) builds it too.
}
unit Firmware.AcpiProperties;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlValues;

{ The value of property Name in Dsd (what _DSD returned); False if it has
  no such property. Value is a view into Dsd: not to be released. }
function FindDeviceProperty(constref Dsd: TAmlValue; Name: PChar; out Value: TAmlValue): Boolean;
function DevicePropertyInteger(constref Dsd: TAmlValue; Name: PChar; out Number: QWord): Boolean;
{ A buffer's bytes, a string's characters or a package of integers (one
  byte each), up to Capacity; Length says how many there were. }
function DevicePropertyBytes(constref Dsd: TAmlValue; Name: PChar; Data: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
{ A string property, zero terminated, cut to Capacity - 1 characters. }
function DevicePropertyText(constref Dsd: TAmlValue; Name: PChar; Text: PChar; Capacity: LongWord): Boolean;

implementation

uses
  Runtime.Memory;

const
  DevicePropertiesUuid: array[0..15] of Byte = (
    $14, $D8, $FF, $DA, $BA, $6E, $8C, $4D, $8A, $91, $BC, $9B, $BF, $4A, $A3, $01);

function TextLength(Text: PChar): LongWord;
begin
  Result := 0;
  while Text[Result] <> #0 do
    Inc(Result);
end;

function IsDevicePropertiesUuid(constref Value: TAmlValue): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Value.Kind <> AmlBuffer) or (ValueLength(Value) <> 16) then
    Exit;
  for Index := 0 to 15 do
    if ValueData(Value)[Index] <> DevicePropertiesUuid[Index] then
      Exit;
  Result := True;
end;

{ True if Value is a string equal to Name (a trailing zero allowed). }
function NameMatches(constref Value: TAmlValue; Name: PChar): Boolean;
var
  Length: LongWord;
  Index: LongWord;
  Data: PByte;
begin
  Result := False;
  if Value.Kind <> AmlString then
    Exit;
  Length := TextLength(Name);
  Data := ValueData(Value);
  if ValueLength(Value) < Length then
    Exit;
  if (ValueLength(Value) > Length) and (Data[Length] <> 0) then
    Exit;
  for Index := 1 to Length do
    if Char(Data[Index - 1]) <> Name[Index - 1] then
      Exit;
  Result := True;
end;

function FindInPropertyList(constref List: TAmlValue; Name: PChar; out Value: TAmlValue): Boolean;
var
  Index: LongWord;
  Pair: TAmlValue;
begin
  Result := False;
  if List.Kind <> AmlPackage then
    Exit;
  for Index := 1 to List.Package^.Count do
  begin
    Pair := List.Package^.Elements[Index - 1];
    if (Pair.Kind = AmlPackage) and (Pair.Package^.Count >= 2) and
       NameMatches(Pair.Package^.Elements[0], Name) then
    begin
      Value := Pair.Package^.Elements[1];
      Exit(True);
    end;
  end;
end;

function FindDeviceProperty(constref Dsd: TAmlValue; Name: PChar; out Value: TAmlValue): Boolean;
var
  Index: LongWord;
begin
  Result := False;
  ZeroMemory(@Value, SizeOf(Value));
  if Dsd.Kind <> AmlPackage then
    Exit;
  Index := 0;
  while Index + 1 < Dsd.Package^.Count do
  begin
    if IsDevicePropertiesUuid(Dsd.Package^.Elements[Index]) and
       FindInPropertyList(Dsd.Package^.Elements[Index + 1], Name, Value) then
      Exit(True);
    Index := Index + 2;
  end;
end;

function DevicePropertyInteger(constref Dsd: TAmlValue; Name: PChar; out Number: QWord): Boolean;
var
  Value: TAmlValue;
begin
  Number := 0;
  Result := FindDeviceProperty(Dsd, Name, Value) and (Value.Kind = AmlInteger);
  if Result then
    Number := Value.Integer;
end;

function DevicePropertyBytes(constref Dsd: TAmlValue; Name: PChar; Data: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
var
  Value: TAmlValue;
  Index: LongWord;
  Element: TAmlValue;
begin
  Length := 0;
  Result := False;
  if not FindDeviceProperty(Dsd, Name, Value) then
    Exit;
  case Value.Kind of
    AmlBuffer, AmlString:
      begin
        Length := ValueLength(Value);
        for Index := 1 to Length do
          if Index <= Capacity then
            Data[Index - 1] := ValueData(Value)[Index - 1];
        Result := True;
      end;
    AmlPackage:
      begin
        Length := Value.Package^.Count;
        for Index := 1 to Length do
        begin
          Element := Value.Package^.Elements[Index - 1];
          if Element.Kind <> AmlInteger then
            Exit;
          if Index <= Capacity then
            Data[Index - 1] := Byte(Element.Integer);
        end;
        Result := True;
      end;
  end;
end;

function DevicePropertyText(constref Dsd: TAmlValue; Name: PChar; Text: PChar; Capacity: LongWord): Boolean;
var
  Value: TAmlValue;
  Length: LongWord;
  Index: LongWord;
begin
  Result := False;
  if Capacity = 0 then
    Exit;
  Text[0] := #0;
  if not FindDeviceProperty(Dsd, Name, Value) or (Value.Kind <> AmlString) then
    Exit;
  Length := ValueLength(Value);
  if Length > Capacity - 1 then
    Length := Capacity - 1;
  for Index := 1 to Length do
    Text[Index - 1] := Char(ValueData(Value)[Index - 1]);
  Text[Length] := #0;
  Result := True;
end;

end.
