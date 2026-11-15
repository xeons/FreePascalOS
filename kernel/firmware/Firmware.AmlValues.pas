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
  AML values: what the interpreter computes with and stores.

  Integers are 64-bit, or 32-bit for tables of revision 1
  (AmlIntegerBytes; results are cut to that with AmlMask). Strings and
  buffers keep their bytes in shared, counted storage (TAmlBytes; a
  string's bytes end in a zero not counted in its length); packages
  keep their elements the same way (TAmlPackage). A value record that
  holds storage owns one count of it: RetainValue takes another,
  ReleaseValue gives it back, and storage goes when its count ends.

  References: to a namespace node (RefOf, or a node named in a package),
  and to one element of a package or one byte of a buffer (Index). A
  name in a package that may not exist yet is kept as a name path: its
  text and the scope it was written in, looked up when it is used.
}
unit Firmware.AmlValues;

{$mode objfpc}
{$pointermath on}

interface

type
  TAmlValueKind = (AmlNone, AmlInteger, AmlString, AmlBuffer, AmlPackage, AmlNodeReference,
    AmlElementReference, AmlNamePath);

  PAmlBytes = ^TAmlBytes;
  TAmlBytes = record
    References: LongInt;
    Length: LongWord;
    Data: PByte;
  end;

  PAmlValue = ^TAmlValue;
  PAmlPackage = ^TAmlPackage;
  TAmlPackage = record
    References: LongInt;
    Count: LongWord;
    Elements: PAmlValue;
  end;

  TAmlValue = record
    Kind: TAmlValueKind;
    { The integer; for an element reference, the element's index. }
    Integer: QWord;
    { Strings, buffers and name paths; the buffer an element reference
      points into. }
    Bytes: PAmlBytes;
    { Packages; the package an element reference points into. }
    Package: PAmlPackage;
    { A referenced node; the scope of a name path. }
    Node: Pointer;
  end;

var
  { 4 or 8: the width of integers in the table being run. }
  AmlIntegerBytes: LongWord = 8;

function AmlMask(Value: QWord): QWord;
function AmlOnes: QWord;

function MakeInteger(Value: QWord): TAmlValue;
{ Nil on failure leaves the result AmlNone. }
function MakeString(Text: PByte; Length: LongWord): TAmlValue;
function MakeStringFromText(Text: PChar): TAmlValue;
function MakeBuffer(Length: LongWord): TAmlValue;
function MakeBufferFrom(Data: PByte; Length: LongWord): TAmlValue;
function MakePackage(Count: LongWord): TAmlValue;
function MakeNodeReference(Node: Pointer): TAmlValue;
function MakeNamePath(Text: PByte; Length: LongWord; Scope: Pointer): TAmlValue;

procedure RetainValue(var Value: TAmlValue);
procedure ReleaseValue(var Value: TAmlValue);
{ Another holder of the same value (storage shared). }
function ShareValue(const Value: TAmlValue): TAmlValue;
{ A copy with storage of its own, all the way down. }
function CopyValue(const Value: TAmlValue): TAmlValue;

{ Conversions. Implicit ones (operands) read strings as hexadecimal;
  explicit ones (ToInteger) take "0x" hexadecimal or decimal. }
function ValueToInteger(const Value: TAmlValue; Implicit: Boolean; out Number: QWord): Boolean;
function ValueToBuffer(const Value: TAmlValue): TAmlValue;
{ Integers as hexadecimal digits, buffers as their bytes in hexadecimal
  separated by commas; a string stays as it is. }
function ValueToHexString(const Value: TAmlValue): TAmlValue;
function ValueToDecimalString(const Value: TAmlValue): TAmlValue;
{ For LEqual, LGreater and LLess: -1, 0 or 1 by the first operand's type;
  False if they cannot be compared. }
function CompareValues(const First, Second: TAmlValue; out Order: Integer): Boolean;
{ The bytes of a string, buffer or name path (nil otherwise). }
function ValueData(const Value: TAmlValue): PByte;
function ValueLength(const Value: TAmlValue): LongWord;

implementation

uses
  Runtime.Memory,
  Firmware.AmlHost;

function AmlMask(Value: QWord): QWord;
begin
  if AmlIntegerBytes = 4 then
    Result := Value and $FFFFFFFF
  else
    Result := Value;
end;

function AmlOnes: QWord;
begin
  Result := AmlMask(High(QWord));
end;

{ --- Storage ---------------------------------------------------------------- }

function NewBytes(Length: LongWord): PAmlBytes;
begin
  { One more byte: the zero that ends a string. }
  Result := PAmlBytes(AmlHost.Allocate(SizeOf(TAmlBytes) + Length + 1));
  if Result = nil then
    Exit;
  Result^.References := 1;
  Result^.Length := Length;
  Result^.Data := PByte(Result) + SizeOf(TAmlBytes);
end;

function NewPackage(Count: LongWord): PAmlPackage;
begin
  Result := PAmlPackage(AmlHost.Allocate(SizeOf(TAmlPackage) + Count * SizeOf(TAmlValue)));
  if Result = nil then
    Exit;
  Result^.References := 1;
  Result^.Count := Count;
  Result^.Elements := PAmlValue(PByte(Result) + SizeOf(TAmlPackage));
end;

procedure ReleaseBytes(Bytes: PAmlBytes);
begin
  if Bytes = nil then
    Exit;
  Dec(Bytes^.References);
  if Bytes^.References = 0 then
    AmlHost.Free(Bytes);
end;

procedure ReleasePackage(Package: PAmlPackage);
var
  Index: LongWord;
begin
  if Package = nil then
    Exit;
  Dec(Package^.References);
  if Package^.References > 0 then
    Exit;
  if Package^.Count > 0 then
    for Index := 0 to Package^.Count - 1 do
      ReleaseValue(Package^.Elements[Index]);
  AmlHost.Free(Package);
end;

{ --- Making values ---------------------------------------------------------- }

function EmptyValue: TAmlValue;
begin
  ZeroMemory(@Result, SizeOf(Result));
end;

function MakeInteger(Value: QWord): TAmlValue;
begin
  Result := EmptyValue;
  Result.Kind := AmlInteger;
  Result.Integer := AmlMask(Value);
end;

function MakeString(Text: PByte; Length: LongWord): TAmlValue;
begin
  Result := EmptyValue;
  Result.Bytes := NewBytes(Length);
  if Result.Bytes = nil then
    Exit;
  Result.Kind := AmlString;
  if Length > 0 then
    CopyMemory(Result.Bytes^.Data, Text, Length);
end;

function MakeStringFromText(Text: PChar): TAmlValue;
var
  Length: LongWord;
begin
  Length := 0;
  while Text[Length] <> #0 do
    Inc(Length);
  Result := MakeString(PByte(Text), Length);
end;

function MakeBuffer(Length: LongWord): TAmlValue;
begin
  Result := EmptyValue;
  Result.Bytes := NewBytes(Length);
  if Result.Bytes <> nil then
    Result.Kind := AmlBuffer;
end;

function MakeBufferFrom(Data: PByte; Length: LongWord): TAmlValue;
begin
  Result := MakeBuffer(Length);
  if (Result.Kind = AmlBuffer) and (Length > 0) then
    CopyMemory(Result.Bytes^.Data, Data, Length);
end;

function MakePackage(Count: LongWord): TAmlValue;
begin
  Result := EmptyValue;
  Result.Package := NewPackage(Count);
  if Result.Package <> nil then
    Result.Kind := AmlPackage;
end;

function MakeNodeReference(Node: Pointer): TAmlValue;
begin
  Result := EmptyValue;
  Result.Kind := AmlNodeReference;
  Result.Node := Node;
end;

function MakeNamePath(Text: PByte; Length: LongWord; Scope: Pointer): TAmlValue;
begin
  Result := MakeString(Text, Length);
  if Result.Kind = AmlString then
  begin
    Result.Kind := AmlNamePath;
    Result.Node := Scope;
  end;
end;

{ --- Holding and copying -------------------------------------------------------- }

procedure RetainValue(var Value: TAmlValue);
begin
  if Value.Bytes <> nil then
    Inc(Value.Bytes^.References);
  if Value.Package <> nil then
    Inc(Value.Package^.References);
end;

procedure ReleaseValue(var Value: TAmlValue);
begin
  ReleaseBytes(Value.Bytes);
  ReleasePackage(Value.Package);
  Value := EmptyValue;
end;

function ShareValue(const Value: TAmlValue): TAmlValue;
begin
  Result := Value;
  RetainValue(Result);
end;

function CopyValue(const Value: TAmlValue): TAmlValue;
var
  Index: LongWord;
begin
  case Value.Kind of
    AmlString, AmlBuffer, AmlNamePath:
      begin
        Result := MakeString(Value.Bytes^.Data, Value.Bytes^.Length);
        if Result.Kind <> AmlNone then
        begin
          Result.Kind := Value.Kind;
          Result.Node := Value.Node;
        end;
      end;
    AmlPackage:
      begin
        Result := MakePackage(Value.Package^.Count);
        if (Result.Kind = AmlPackage) and (Value.Package^.Count > 0) then
          for Index := 0 to Value.Package^.Count - 1 do
            Result.Package^.Elements[Index] := CopyValue(Value.Package^.Elements[Index]);
      end;
  else
    Result := ShareValue(Value);
  end;
end;

function ValueData(const Value: TAmlValue): PByte;
begin
  if (Value.Kind in [AmlString, AmlBuffer, AmlNamePath]) and (Value.Bytes <> nil) then
    Result := Value.Bytes^.Data
  else
    Result := nil;
end;

function ValueLength(const Value: TAmlValue): LongWord;
begin
  if (Value.Kind in [AmlString, AmlBuffer, AmlNamePath]) and (Value.Bytes <> nil) then
    Result := Value.Bytes^.Length
  else if Value.Kind = AmlPackage then
    Result := Value.Package^.Count
  else
    Result := 0;
end;

{ --- Conversions ------------------------------------------------------------------ }

function DigitValue(Character: Byte; out Digit: LongWord): Boolean;
begin
  Result := True;
  case Character of
    Ord('0')..Ord('9'): Digit := Character - Ord('0');
    Ord('a')..Ord('f'): Digit := Character - Ord('a') + 10;
    Ord('A')..Ord('F'): Digit := Character - Ord('A') + 10;
  else
    Result := False;
  end;
end;

function StringToInteger(Text: PByte; Length: LongWord; Implicit: Boolean): QWord;
var
  Position: LongWord;
  Base: LongWord;
  Digit: LongWord;
begin
  Result := 0;
  Position := 0;
  while (Position < Length) and (Text[Position] in [Ord(' '), 9]) do
    Inc(Position);
  Base := 16;
  if (Position + 1 < Length) and (Text[Position] = Ord('0')) and (Text[Position + 1] in [Ord('x'), Ord('X')]) then
    Inc(Position, 2)
  else if not Implicit then
    Base := 10;
  while (Position < Length) and DigitValue(Text[Position], Digit) and (Digit < Base) do
  begin
    Result := Result * Base + Digit;
    Inc(Position);
  end;
  Result := AmlMask(Result);
end;

function ValueToInteger(const Value: TAmlValue; Implicit: Boolean; out Number: QWord): Boolean;
var
  Index: LongWord;
  Count: LongWord;
begin
  Number := 0;
  Result := True;
  case Value.Kind of
    AmlInteger:
      Number := Value.Integer;
    AmlString:
      Number := StringToInteger(Value.Bytes^.Data, Value.Bytes^.Length, Implicit);
    AmlBuffer:
      begin
        { The first bytes, least significant first. }
        Count := Value.Bytes^.Length;
        if Count > AmlIntegerBytes then
          Count := AmlIntegerBytes;
        for Index := Count downto 1 do
          Number := (Number shl 8) or Value.Bytes^.Data[Index - 1];
      end;
  else
    Result := False;
  end;
end;

function ValueToBuffer(const Value: TAmlValue): TAmlValue;
var
  Index: LongWord;
begin
  case Value.Kind of
    AmlBuffer:
      Result := ShareValue(Value);
    AmlInteger:
      begin
        Result := MakeBuffer(AmlIntegerBytes);
        if Result.Kind = AmlBuffer then
          for Index := 0 to AmlIntegerBytes - 1 do
            Result.Bytes^.Data[Index] := Byte(Value.Integer shr (Index * 8));
      end;
    AmlString:
      begin
        { With its ending zero, unless it is empty. }
        if Value.Bytes^.Length = 0 then
          Result := MakeBuffer(0)
        else
          Result := MakeBufferFrom(Value.Bytes^.Data, Value.Bytes^.Length + 1);
      end;
  else
    Result := EmptyValue;
  end;
end;

procedure AppendHex(Destination: PByte; var Position: LongWord; Value: QWord; Digits: LongWord);
const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
var
  Digit: LongWord;
begin
  for Digit := Digits downto 1 do
  begin
    Destination[Position] := Ord(HexDigits[(Value shr ((Digit - 1) * 4)) and $F]);
    Inc(Position);
  end;
end;

function ValueToHexString(const Value: TAmlValue): TAmlValue;
var
  Text: array[0..15] of Byte;
  Position: LongWord;
  Index: LongWord;
  Data: PByte;
begin
  case Value.Kind of
    AmlString:
      Result := ShareValue(Value);
    AmlInteger:
      begin
        Position := 0;
        AppendHex(@Text[0], Position, Value.Integer, AmlIntegerBytes * 2);
        Result := MakeString(@Text[0], Position);
      end;
    AmlBuffer:
      begin
        if Value.Bytes^.Length = 0 then
          Exit(MakeString(nil, 0));
        { "0xAB," for each byte, the last without the comma. }
        Result := MakeString(nil, Value.Bytes^.Length * 5 - 1);
        if Result.Kind <> AmlString then
          Exit;
        Data := Result.Bytes^.Data;
        Position := 0;
        for Index := 0 to Value.Bytes^.Length - 1 do
        begin
          if Index > 0 then
          begin
            Data[Position] := Ord(',');
            Inc(Position);
          end;
          Data[Position] := Ord('0');
          Data[Position + 1] := Ord('x');
          Inc(Position, 2);
          AppendHex(Data, Position, Value.Bytes^.Data[Index], 2);
        end;
      end;
  else
    Result := EmptyValue;
  end;
end;

function ValueToDecimalString(const Value: TAmlValue): TAmlValue;
var
  Text: array[0..23] of Byte;
  Reversed: array[0..23] of Byte;
  Count: LongWord;
  Index: LongWord;
  Number: QWord;
begin
  if Value.Kind = AmlString then
    Exit(ShareValue(Value));
  if not ValueToInteger(Value, True, Number) then
    Exit(EmptyValue);
  Count := 0;
  repeat
    Reversed[Count] := Ord('0') + Number mod 10;
    Number := Number div 10;
    Inc(Count);
  until Number = 0;
  for Index := 0 to Count - 1 do
    Text[Index] := Reversed[Count - 1 - Index];
  Result := MakeString(@Text[0], Count);
end;

function CompareValues(const First, Second: TAmlValue; out Order: Integer): Boolean;
var
  Left: QWord;
  Right: QWord;
  Other: TAmlValue;
  Index: LongWord;
  Shorter: LongWord;
begin
  Order := 0;
  Result := False;
  if First.Kind = AmlInteger then
  begin
    if not ValueToInteger(Second, True, Right) then
      Exit;
    Left := First.Integer;
    if Left < Right then
      Order := -1
    else if Left > Right then
      Order := 1;
    Exit(True);
  end;
  if not (First.Kind in [AmlString, AmlBuffer]) then
    Exit;
  { The second as the first's type, then byte by byte. }
  if Second.Kind = First.Kind then
    Other := ShareValue(Second)
  else if First.Kind = AmlBuffer then
    Other := ValueToBuffer(Second)
  else
    Other := ValueToHexString(Second);
  if Other.Kind = AmlNone then
    Exit;
  Shorter := First.Bytes^.Length;
  if Other.Bytes^.Length < Shorter then
    Shorter := Other.Bytes^.Length;
  Index := 0;
  while Index < Shorter do
  begin
    if First.Bytes^.Data[Index] <> Other.Bytes^.Data[Index] then
    begin
      if First.Bytes^.Data[Index] < Other.Bytes^.Data[Index] then
        Order := -1
      else
        Order := 1;
      Break;
    end;
    Inc(Index);
  end;
  if Order = 0 then
    if First.Bytes^.Length < Other.Bytes^.Length then
      Order := -1
    else if First.Bytes^.Length > Other.Bytes^.Length then
      Order := 1;
  ReleaseValue(Other);
  Result := True;
end;

end.
