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
  Text handling for programs: character classes, comparison, searching,
  number parsing and a growable text buffer.

  Strings are zero terminated UTF-8 (PChar). The basic routines
  (TextLength, TextIsEqual, CopyText, number formatting) come from
  Runtime.Text, which this library also contains.
}
unit Sys.Text;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.Text;

type
  { A string that grows as text is appended. Text is always terminated. }
  TTextBuilder = record
    Text: PChar;
    Length: PtrUInt;
    Capacity: PtrUInt;
  end;

function IsDigit(Character: Char): Boolean;
function IsSpace(Character: Char): Boolean;
function IsLetter(Character: Char): Boolean;
function IsAlphanumeric(Character: Char): Boolean;
function IsUpperCase(Character: Char): Boolean;
function IsLowerCase(Character: Char): Boolean;
function IsPrintable(Character: Char): Boolean;
function ToUpperCase(Character: Char): Char;
function ToLowerCase(Character: Char): Char;

{ Byte-wise ordering: negative, zero or positive. }
function CompareText(First, Second: PChar): Integer;
function CompareTextIgnoringCase(First, Second: PChar): Integer;
function TextStartsWith(Text, Prefix: PChar): Boolean;
function TextEndsWith(Text, Suffix: PChar): Boolean;
{ Index of the first occurrence of Character, or -1. }
function FindCharacter(Text: PChar; Character: Char): PtrInt;
function FindLastCharacter(Text: PChar; Character: Char): PtrInt;
{ Index of the first occurrence of Pattern, or -1. }
function FindText(Text, Pattern: PChar): PtrInt;

{ Parses an optionally signed decimal integer; the whole text must be a
  number (surrounding spaces are allowed). }
function ParseInteger(Text: PChar; out Value: Int64): Boolean;
function ParseUnsigned(Text: PChar; out Value: QWord): Boolean;
{ Hexadecimal digits (no prefix), the whole text. }
function ParseHexadecimal(Text: PChar; out Value: QWord): Boolean;
{ A size written WIDTHxHEIGHT ("1024x768"), both above 0. }
function ParseSize(Text: PChar; out Width, Height: LongWord): Boolean;
{ A decimal number with up to three places after the point ("1.5"), in
  thousandths. }
function ParseThousandths(Text: PChar; out Value: QWord): Boolean;

procedure BeginText(out Builder: TTextBuilder);
procedure AppendText(var Builder: TTextBuilder; Text: PChar);
procedure AppendCharacter(var Builder: TTextBuilder; Character: Char);
procedure AppendBytes(var Builder: TTextBuilder; Bytes: PChar; Count: PtrUInt);
procedure AppendDecimal(var Builder: TTextBuilder; Value: Int64);
{ Gives up ownership of the text (free it with FreeMemory). }
function FinishText(var Builder: TTextBuilder): PChar;
procedure DiscardText(var Builder: TTextBuilder);

implementation

uses
  Runtime.Memory,
  Sys.Memory;

function IsDigit(Character: Char): Boolean;
begin
  Result := (Character >= '0') and (Character <= '9');
end;

function IsSpace(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #10) or
    (Character = #11) or (Character = #12) or (Character = #13);
end;

function IsUpperCase(Character: Char): Boolean;
begin
  Result := (Character >= 'A') and (Character <= 'Z');
end;

function IsLowerCase(Character: Char): Boolean;
begin
  Result := (Character >= 'a') and (Character <= 'z');
end;

function IsLetter(Character: Char): Boolean;
begin
  Result := IsUpperCase(Character) or IsLowerCase(Character);
end;

function IsAlphanumeric(Character: Char): Boolean;
begin
  Result := IsLetter(Character) or IsDigit(Character);
end;

function IsPrintable(Character: Char): Boolean;
begin
  Result := (Character >= ' ') and (Character <> #127);
end;

function ToUpperCase(Character: Char): Char;
begin
  if IsLowerCase(Character) then
    Result := Char(Ord(Character) - 32)
  else
    Result := Character;
end;

function ToLowerCase(Character: Char): Char;
begin
  if IsUpperCase(Character) then
    Result := Char(Ord(Character) + 32)
  else
    Result := Character;
end;

function CompareText(First, Second: PChar): Integer;
var
  Index: PtrUInt;
begin
  Index := 0;
  while (First[Index] <> #0) and (First[Index] = Second[Index]) do
    Inc(Index);
  Result := Integer(Byte(First[Index])) - Integer(Byte(Second[Index]));
end;

function CompareTextIgnoringCase(First, Second: PChar): Integer;
var
  Index: PtrUInt;
begin
  Index := 0;
  while (First[Index] <> #0) and (ToLowerCase(First[Index]) = ToLowerCase(Second[Index])) do
    Inc(Index);
  Result := Integer(Byte(ToLowerCase(First[Index]))) - Integer(Byte(ToLowerCase(Second[Index])));
end;

function TextStartsWith(Text, Prefix: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Prefix[Index] <> #0 do
  begin
    if Text[Index] <> Prefix[Index] then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function TextEndsWith(Text, Suffix: PChar): Boolean;
var
  TextSize: PtrUInt;
  SuffixSize: PtrUInt;
begin
  TextSize := TextLength(Text);
  SuffixSize := TextLength(Suffix);
  Result := (SuffixSize <= TextSize) and TextIsEqual(Text + (TextSize - SuffixSize), Suffix);
end;

function FindCharacter(Text: PChar; Character: Char): PtrInt;
var
  Index: PtrInt;
begin
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if Text[Index] = Character then
      Exit(Index);
    Inc(Index);
  end;
  Result := -1;
end;

function FindLastCharacter(Text: PChar; Character: Char): PtrInt;
var
  Index: PtrInt;
begin
  Result := -1;
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if Text[Index] = Character then
      Result := Index;
    Inc(Index);
  end;
end;

function FindText(Text, Pattern: PChar): PtrInt;
var
  Index: PtrInt;
begin
  if Pattern^ = #0 then
    Exit(0);
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if TextStartsWith(Text + Index, Pattern) then
      Exit(Index);
    Inc(Index);
  end;
  Result := -1;
end;

function ParseThousandths(Text: PChar; out Value: QWord): Boolean;
var
  Position: Integer;
  Scale: QWord;
begin
  Value := 0;
  Position := 0;
  if not IsDigit(Text[0]) then
    Exit(False);
  while IsDigit(Text[Position]) do
  begin
    Value := Value * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  Value := Value * 1000;
  if Text[Position] = '.' then
  begin
    Inc(Position);
    Scale := 100;
    while IsDigit(Text[Position]) do
    begin
      Value := Value + QWord(Ord(Text[Position]) - Ord('0')) * Scale;
      Scale := Scale div 10;
      Inc(Position);
    end;
  end;
  Result := Text[Position] = #0;
end;

function ParseUnsigned(Text: PChar; out Value: QWord): Boolean;
var
  Index: PtrUInt;
  SawDigit: Boolean;
  Digit: QWord;
begin
  Value := 0;
  Index := 0;
  SawDigit := False;
  while IsSpace(Text[Index]) do
    Inc(Index);
  if Text[Index] = '+' then
    Inc(Index);
  while IsDigit(Text[Index]) do
  begin
    Digit := Ord(Text[Index]) - Ord('0');
    if Value > (High(QWord) - Digit) div 10 then
      Exit(False); { overflow }
    Value := Value * 10 + Digit;
    SawDigit := True;
    Inc(Index);
  end;
  while IsSpace(Text[Index]) do
    Inc(Index);
  Result := SawDigit and (Text[Index] = #0);
end;

{ Digits from Text[Index] on, at least one, up to a value of High
  (LongWord); Index ends after them. }
function ParseDimension(Text: PChar; var Index: PtrUInt; out Value: LongWord): Boolean;
var
  Number: QWord;
  SawDigit: Boolean;
begin
  Value := 0;
  Number := 0;
  SawDigit := False;
  while IsDigit(Text[Index]) do
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

function ParseSize(Text: PChar; out Width, Height: LongWord): Boolean;
var
  Index: PtrUInt;
begin
  Width := 0;
  Height := 0;
  Index := 0;
  if not ParseDimension(Text, Index, Width) or ((Text[Index] <> 'x') and (Text[Index] <> 'X')) then
    Exit(False);
  Inc(Index);
  Result := ParseDimension(Text, Index, Height) and (Text[Index] = #0);
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

function ParseHexadecimal(Text: PChar; out Value: QWord): Boolean;
var
  Index: PtrUInt;
  Digit: QWord;
begin
  Value := 0;
  Index := 0;
  while HexadecimalDigit(Text[Index], Digit) do
  begin
    if (Value shr 60) <> 0 then
      Exit(False); { overflow }
    Value := (Value shl 4) or Digit;
    Inc(Index);
  end;
  Result := (Index > 0) and (Text[Index] = #0);
end;

function ParseInteger(Text: PChar; out Value: Int64): Boolean;
var
  Magnitude: QWord;
  IsNegative: Boolean;
begin
  Value := 0;
  while IsSpace(Text^) do
    Inc(Text);
  IsNegative := Text^ = '-';
  if IsNegative then
    Inc(Text);
  Result := ParseUnsigned(Text, Magnitude);
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

{ --- Builder --------------------------------------------------------- }

procedure BeginText(out Builder: TTextBuilder);
begin
  Builder.Capacity := 64;
  Builder.Text := PChar(AllocateMemory(Builder.Capacity));
  Builder.Length := 0;
  if Builder.Text <> nil then
    Builder.Text[0] := #0
  else
    Builder.Capacity := 0;
end;

procedure EnsureCapacity(var Builder: TTextBuilder; Needed: PtrUInt);
var
  NewCapacity: PtrUInt;
begin
  if Needed < Builder.Capacity then
    Exit;
  NewCapacity := Builder.Capacity * 2;
  if NewCapacity < 64 then
    NewCapacity := 64;
  while NewCapacity <= Needed do
    NewCapacity := NewCapacity * 2;
  Builder.Text := PChar(ReallocateMemory(Builder.Text, NewCapacity));
  if Builder.Text = nil then
  begin
    Builder.Capacity := 0;
    Builder.Length := 0;
    Exit;
  end;
  Builder.Capacity := NewCapacity;
end;

procedure AppendBytes(var Builder: TTextBuilder; Bytes: PChar; Count: PtrUInt);
begin
  EnsureCapacity(Builder, Builder.Length + Count + 1);
  if Builder.Text = nil then
    Exit;
  CopyMemory(Builder.Text + Builder.Length, Bytes, Count);
  Builder.Length := Builder.Length + Count;
  Builder.Text[Builder.Length] := #0;
end;

procedure AppendText(var Builder: TTextBuilder; Text: PChar);
begin
  if Text <> nil then
    AppendBytes(Builder, Text, TextLength(Text));
end;

procedure AppendCharacter(var Builder: TTextBuilder; Character: Char);
begin
  AppendBytes(Builder, @Character, 1);
end;

procedure AppendDecimal(var Builder: TTextBuilder; Value: Int64);
var
  NumberText: TNumberText;
begin
  AppendText(Builder, FormatSignedDecimal(Value, NumberText));
end;

function FinishText(var Builder: TTextBuilder): PChar;
begin
  Result := Builder.Text;
  Builder.Text := nil;
  Builder.Length := 0;
  Builder.Capacity := 0;
end;

procedure DiscardText(var Builder: TTextBuilder);
begin
  FreeMemory(Builder.Text);
  Builder.Text := nil;
  Builder.Length := 0;
  Builder.Capacity := 0;
end;

end.
