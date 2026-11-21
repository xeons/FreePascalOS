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
  The order people expect names in: runs of digits compare by the
  number they make, so "file 2" comes before "file 10", and letters
  compare without regard to case ("apple" before "Banana").

  Names that are the same that way are told apart by the number of
  leading zeros ("7" before "07"), then by case, then byte by byte, so
  two different names never compare equal. Bytes of UTF-8 characters
  beyond ASCII compare as they are. Plain text logic, checked on the
  host (make files-test).
}
unit Controls.NaturalOrder;

{$mode objfpc}
{$H+}

interface

{ Negative if First goes before Second, positive after, 0 only when
  they are the same text. }
function NaturalCompare(const First, Second: string): LongInt;

implementation

function IsDigit(Character: Char): Boolean; inline;
begin
  Result := (Character >= '0') and (Character <= '9');
end;

function FoldCase(Character: Char): Char; inline;
begin
  if (Character >= 'A') and (Character <= 'Z') then
    Result := Chr(Ord(Character) + 32)
  else
    Result := Character;
end;

function Sign(Value: LongInt): LongInt; inline;
begin
  if Value < 0 then
    Result := -1
  else if Value > 0 then
    Result := 1
  else
    Result := 0;
end;

{ Compares the digit runs starting at FirstIndex and SecondIndex (both
  moved past them): by value, ignoring leading zeros. ZeroDifference is
  set to the difference in leading zeros the first time runs are equal
  in value but not in zeros (for the tie-break). }
function CompareDigitRuns(const First, Second: string; var FirstIndex, SecondIndex: LongInt;
  var ZeroDifference: LongInt): LongInt;
var
  FirstZeros: LongInt;
  SecondZeros: LongInt;
  FirstStart: LongInt;
  SecondStart: LongInt;
  FirstLength: LongInt;
  SecondLength: LongInt;
  Offset: LongInt;
begin
  FirstZeros := 0;
  while (FirstIndex <= Length(First)) and (First[FirstIndex] = '0') do
  begin
    Inc(FirstZeros);
    Inc(FirstIndex);
  end;
  SecondZeros := 0;
  while (SecondIndex <= Length(Second)) and (Second[SecondIndex] = '0') do
  begin
    Inc(SecondZeros);
    Inc(SecondIndex);
  end;
  FirstStart := FirstIndex;
  while (FirstIndex <= Length(First)) and IsDigit(First[FirstIndex]) do
    Inc(FirstIndex);
  SecondStart := SecondIndex;
  while (SecondIndex <= Length(Second)) and IsDigit(Second[SecondIndex]) do
    Inc(SecondIndex);
  FirstLength := FirstIndex - FirstStart;
  SecondLength := SecondIndex - SecondStart;
  { More significant digits is a larger number. }
  if FirstLength <> SecondLength then
    Exit(Sign(FirstLength - SecondLength));
  for Offset := 0 to FirstLength - 1 do
    if First[FirstStart + Offset] <> Second[SecondStart + Offset] then
      Exit(Sign(Ord(First[FirstStart + Offset]) - Ord(Second[SecondStart + Offset])));
  if (ZeroDifference = 0) and (FirstZeros <> SecondZeros) then
    ZeroDifference := Sign(FirstZeros - SecondZeros);
  Result := 0;
end;

{ Case first difference, then bytes: the last tie-breaks. }
function CompareExactly(const First, Second: string): LongInt;
var
  Index: LongInt;
begin
  Index := 1;
  while (Index <= Length(First)) and (Index <= Length(Second)) do
  begin
    if First[Index] <> Second[Index] then
      { Capitals first ("A" before "a"), as their codes go. }
      Exit(Sign(Ord(First[Index]) - Ord(Second[Index])));
    Inc(Index);
  end;
  Result := Sign(Length(First) - Length(Second));
end;

function NaturalCompare(const First, Second: string): LongInt;
var
  FirstIndex: LongInt;
  SecondIndex: LongInt;
  ZeroDifference: LongInt;
  FirstCharacter: Char;
  SecondCharacter: Char;
begin
  FirstIndex := 1;
  SecondIndex := 1;
  ZeroDifference := 0;
  while (FirstIndex <= Length(First)) and (SecondIndex <= Length(Second)) do
  begin
    if IsDigit(First[FirstIndex]) and IsDigit(Second[SecondIndex]) then
    begin
      Result := CompareDigitRuns(First, Second, FirstIndex, SecondIndex, ZeroDifference);
      if Result <> 0 then
        Exit;
      Continue;
    end;
    FirstCharacter := FoldCase(First[FirstIndex]);
    SecondCharacter := FoldCase(Second[SecondIndex]);
    if FirstCharacter <> SecondCharacter then
    begin
      { A digit goes before a letter, as in plain byte order. }
      Exit(Sign(Ord(FirstCharacter) - Ord(SecondCharacter)));
    end;
    Inc(FirstIndex);
    Inc(SecondIndex);
  end;
  { The shorter (a prefix of the other) first. }
  if FirstIndex <= Length(First) then
    Exit(1);
  if SecondIndex <= Length(Second) then
    Exit(-1);
  if ZeroDifference <> 0 then
    Exit(ZeroDifference);
  Result := CompareExactly(First, Second);
end;

end.
