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
  Identifying ACPI devices: their hardware id (_HID) and compatible ids
  (_CID), each an EISA id (a packed integer: three letters and four hex
  digits, such as PNP0A08) or a string.
}
unit Firmware.AcpiDeviceIds;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

{ True if Node is a device whose _HID or one of whose _CIDs is Id
  ("PNP0C0C"). }
function DeviceHasId(Node: PAmlNode; Id: PChar): Boolean;
{ An EISA id as its seven characters and a terminating zero. }
procedure EisaIdText(Id: LongWord; Text: PChar);

implementation

uses
  Runtime.Memory,
  Firmware.AmlValues,
  Firmware.AmlInterpreter;

procedure EisaIdText(Id: LongWord; Text: PChar);
const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
var
  Vendor: LongWord;
begin
  Vendor := ((Id and $FF) shl 8) or ((Id shr 8) and $FF);
  Text[0] := Char(((Vendor shr 10) and $1F) + $40);
  Text[1] := Char(((Vendor shr 5) and $1F) + $40);
  Text[2] := Char((Vendor and $1F) + $40);
  Text[3] := HexDigits[(Id shr 20) and $F];
  Text[4] := HexDigits[(Id shr 16) and $F];
  Text[5] := HexDigits[(Id shr 28) and $F];
  Text[6] := HexDigits[(Id shr 24) and $F];
  Text[7] := #0;
end;

function IdMatches(const Value: TAmlValue; Id: PChar): Boolean;
var
  Text: array[0..7] of Char;
begin
  Result := False;
  case Value.Kind of
    AmlInteger:
      EisaIdText(LongWord(Value.Integer), @Text[0]);
    AmlString:
      begin
        if Value.Bytes^.Length <> 7 then
          Exit;
        CopyMemory(@Text[0], Value.Bytes^.Data, 8);
      end;
  else
    Exit;
  end;
  Result := MemoryIsEqual(@Text[0], Id, 7);
end;

function DeviceHasId(Node: PAmlNode; Id: PChar): Boolean;
var
  Value: TAmlValue;
  Index: LongWord;
begin
  Result := False;
  if (Node = nil) or (Node^.Kind <> NodeDevice) then
    Exit;
  if EvaluatePath(Node, '_HID', nil, 0, Value) then
  begin
    Result := IdMatches(Value, Id);
    ReleaseValue(Value);
  end;
  if not Result and EvaluatePath(Node, '_CID', nil, 0, Value) then
  begin
    if Value.Kind = AmlPackage then
    begin
      for Index := 1 to Value.Package^.Count do
        if IdMatches(Value.Package^.Elements[Index - 1], Id) then
          Result := True;
    end
    else
      Result := IdMatches(Value, Id);
    ReleaseValue(Value);
  end;
end;

end.
