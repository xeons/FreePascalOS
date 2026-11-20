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
  QUIC's variable-length integers (RFC 9000 section 16): the two high
  bits of the first byte give the length (1, 2, 4 or 8 bytes), the rest
  is the value in network byte order, at most 2^62 - 1.
}
unit Quic.VariableIntegers;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumVariableInteger = (QWord(1) shl 62) - 1;
  MaximumVariableIntegerLength = 8;

{ 1, 2, 4 or 8: the shortest encoding of Value (Value <= the maximum). }
function VariableIntegerLength(Value: QWord): Integer;
{ Writes the shortest encoding and returns its length. }
function EncodeVariableInteger(Value: QWord; Destination: PByte): Integer;
{ Writes Value in exactly Length bytes (1, 2, 4 or 8; Value must fit). }
procedure EncodeVariableIntegerAs(Value: QWord; Length: Integer; Destination: PByte);
{ The length the first byte announces. }
function EncodedLengthOf(FirstByte: Byte): Integer;
{ The value at Source and its length, or 0 when fewer than that many
  bytes are Available. }
function DecodeVariableInteger(Source: PByte; Available: PtrUInt; out Value: QWord): Integer;

implementation

function VariableIntegerLength(Value: QWord): Integer;
begin
  if Value < 64 then
    Result := 1
  else if Value < 16384 then
    Result := 2
  else if Value < 1073741824 then
    Result := 4
  else
    Result := 8;
end;

procedure EncodeVariableIntegerAs(Value: QWord; Length: Integer; Destination: PByte);
var
  Index: Integer;
  Prefix: Byte;
begin
  case Length of
    1: Prefix := $00;
    2: Prefix := $40;
    4: Prefix := $80;
  else
    Prefix := $C0;
  end;
  for Index := Length - 1 downto 0 do
  begin
    Destination[Index] := Byte(Value and $FF);
    Value := Value shr 8;
  end;
  Destination[0] := (Destination[0] and $3F) or Prefix;
end;

function EncodeVariableInteger(Value: QWord; Destination: PByte): Integer;
begin
  Result := VariableIntegerLength(Value);
  EncodeVariableIntegerAs(Value, Result, Destination);
end;

function EncodedLengthOf(FirstByte: Byte): Integer;
begin
  Result := 1 shl (FirstByte shr 6);
end;

function DecodeVariableInteger(Source: PByte; Available: PtrUInt; out Value: QWord): Integer;
var
  Index: Integer;
begin
  Value := 0;
  if Available = 0 then
    Exit(0);
  Result := EncodedLengthOf(Source[0]);
  if PtrUInt(Result) > Available then
    Exit(0);
  Value := Source[0] and $3F;
  for Index := 1 to Result - 1 do
    Value := (Value shl 8) or Source[Index];
end;

end.
