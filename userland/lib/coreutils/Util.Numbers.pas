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
  Numbers in command line arguments and input, on strings.

  These accept exactly what the tools have always accepted: decimal
  digits only, an optional sign for signed numbers, surrounding spaces
  allowed. SysUtils' TryStrToInt also takes "$FF",
  "0x1F" and other forms the tools must reject.
}
unit Util.Numbers;

{$mode objfpc}{$H+}

interface

{ An optionally signed decimal integer; the whole text must be a number
  (surrounding spaces allowed). }
function ParseDecimal(const Text: string; out Value: Int64): Boolean;
{ An unsigned decimal integer (an optional '+'); the whole text must be
  a number (surrounding spaces allowed). }
function ParseUnsignedDecimal(const Text: string; out Value: QWord): Boolean;
{ Hexadecimal digits (no prefix), the whole text. }
function ParseHexadecimalDigits(const Text: string; out Value: QWord): Boolean;
{ A size written WIDTHxHEIGHT ("1024x768"), both above 0. }
function ParseWidthAndHeight(const Text: string; out Width, Height: LongWord): Boolean;
{ A decimal number with up to three places after the point ("1.5"), in
  thousandths. }
function ParseThousandths(const Text: string; out Value: QWord): Boolean;

{ Value in octal, at least Digits digits (zero filled): what Sys.Format's
  "%04o" printed, which SysUtils' Format cannot. }
function OctalText(Value: QWord; Digits: Integer): string;
{ Bytes in lower case hexadecimal, two digits each. }
function HexText(const Bytes: array of Byte; Count: Integer): string;

implementation

const
  Spaces = [' ', #9, #10, #11, #12, #13];
  DecimalDigits = ['0'..'9'];

{ The character at Index (from 1), #0 past the end: the parsing stops
  there, and at a #0 inside the text, as it always has. }
function CharacterAt(const Text: string; Index: Integer): Char;
begin
  if Index <= Length(Text) then
    Result := Text[Index]
  else
    Result := #0;
end;

{ Spaces, an optional '+' and digits from Index on, then spaces to the
  end; Index ends after them. }
function ParseUnsignedFrom(const Text: string; Index: Integer; out Value: QWord): Boolean;
var
  SawDigit: Boolean;
  Digit: QWord;
begin
  Value := 0;
  SawDigit := False;
  while CharacterAt(Text, Index) in Spaces do
    Inc(Index);
  if CharacterAt(Text, Index) = '+' then
    Inc(Index);
  while CharacterAt(Text, Index) in DecimalDigits do
  begin
    Digit := Ord(Text[Index]) - Ord('0');
    if Value > (High(QWord) - Digit) div 10 then
      Exit(False); { overflow }
    Value := Value * 10 + Digit;
    SawDigit := True;
    Inc(Index);
  end;
  while CharacterAt(Text, Index) in Spaces do
    Inc(Index);
  Result := SawDigit and (CharacterAt(Text, Index) = #0);
end;

function ParseUnsignedDecimal(const Text: string; out Value: QWord): Boolean;
begin
  Result := ParseUnsignedFrom(Text, 1, Value);
end;

function ParseDecimal(const Text: string; out Value: Int64): Boolean;
var
  Index: Integer;
  Magnitude: QWord;
  IsNegative: Boolean;
begin
  Value := 0;
  Index := 1;
  while CharacterAt(Text, Index) in Spaces do
    Inc(Index);
  IsNegative := CharacterAt(Text, Index) = '-';
  if IsNegative then
    Inc(Index);
  Result := ParseUnsignedFrom(Text, Index, Magnitude);
  if not Result then
    Exit;
  if IsNegative then
  begin
    if Magnitude > QWord(High(Int64)) + 1 then
      Exit(False);
    Value := -Int64(Magnitude - 1) - 1;
  end
  else
  begin
    if Magnitude > QWord(High(Int64)) then
      Exit(False);
    Value := Int64(Magnitude);
  end;
end;

function HexadecimalDigit(Character: Char; out Digit: QWord): Boolean;
begin
  Result := True;
  case Character of
    '0'..'9': Digit := Ord(Character) - Ord('0');
    'a'..'f': Digit := Ord(Character) - Ord('a') + 10;
    'A'..'F': Digit := Ord(Character) - Ord('A') + 10;
  else
    Digit := 0;
    Result := False;
  end;
end;

function ParseHexadecimalDigits(const Text: string; out Value: QWord): Boolean;
var
  Index: Integer;
  Digit: QWord;
begin
  Value := 0;
  Index := 1;
  while HexadecimalDigit(CharacterAt(Text, Index), Digit) do
  begin
    if (Value shr 60) <> 0 then
      Exit(False); { overflow }
    Value := (Value shl 4) or Digit;
    Inc(Index);
  end;
  Result := (Index > 1) and (CharacterAt(Text, Index) = #0);
end;

{ Digits from Index on, at least one, up to a value of High(LongWord),
  above 0; Index ends after them. }
function ParseDimension(const Text: string; var Index: Integer; out Value: LongWord): Boolean;
var
  Number: QWord;
  SawDigit: Boolean;
begin
  Value := 0;
  Number := 0;
  SawDigit := False;
  while CharacterAt(Text, Index) in DecimalDigits do
  begin
    Number := Number * 10 + QWord(Ord(Text[Index]) - Ord('0'));
    if Number > High(LongWord) then
      Exit(False);
    SawDigit := True;
    Inc(Index);
  end;
  Value := LongWord(Number);
  Result := SawDigit and (Value > 0);
end;

function ParseWidthAndHeight(const Text: string; out Width, Height: LongWord): Boolean;
var
  Index: Integer;
begin
  Width := 0;
  Height := 0;
  Index := 1;
  if not ParseDimension(Text, Index, Width) or not (CharacterAt(Text, Index) in ['x', 'X']) then
    Exit(False);
  Inc(Index);
  Result := ParseDimension(Text, Index, Height) and (CharacterAt(Text, Index) = #0);
end;

function ParseThousandths(const Text: string; out Value: QWord): Boolean;
var
  Index: Integer;
  Scale: QWord;
begin
  Value := 0;
  Index := 1;
  if not (CharacterAt(Text, Index) in DecimalDigits) then
    Exit(False);
  while CharacterAt(Text, Index) in DecimalDigits do
  begin
    Value := Value * 10 + QWord(Ord(Text[Index]) - Ord('0'));
    Inc(Index);
  end;
  Value := Value * 1000;
  if CharacterAt(Text, Index) = '.' then
  begin
    Inc(Index);
    Scale := 100;
    while CharacterAt(Text, Index) in DecimalDigits do
    begin
      Value := Value + QWord(Ord(Text[Index]) - Ord('0')) * Scale;
      Scale := Scale div 10;
      Inc(Index);
    end;
  end;
  Result := CharacterAt(Text, Index) = #0;
end;

function OctalText(Value: QWord; Digits: Integer): string;
begin
  Result := '';
  repeat
    Result := Char(Ord('0') + (Value and 7)) + Result;
    Value := Value shr 3;
  until Value = 0;
  while Length(Result) < Digits do
    Result := '0' + Result;
end;

function HexText(const Bytes: array of Byte; Count: Integer): string;
const
  HexDigits: array[0..15] of Char = '0123456789abcdef';
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, 2 * Count);
  for Index := 0 to Count - 1 do
  begin
    Result[2 * Index + 1] := HexDigits[Bytes[Index] shr 4];
    Result[2 * Index + 2] := HexDigits[Bytes[Index] and 15];
  end;
end;

end.
