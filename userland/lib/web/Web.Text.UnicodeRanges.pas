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
  The unicode-range descriptor of @font-face (CSS Fonts 4 4.5): a comma
  separated list of U+X, U+X-Y and U+X?? (wildcards) ranges. A face
  with one is used only for the characters in it, so a family split
  into subsets (latin, latin-ext, cyrillic ...) draws each character
  with the subset that has it.
}
unit Web.Text.UnicodeRanges;

{$mode objfpc}
{$H+}

interface

type
  TUnicodeRange = record
    First, Last: LongWord;
  end;
  TUnicodeRangeArray = array of TUnicodeRange;

{ The ranges of a descriptor's text; nil when there are none (the face
  is for every character). }
function ParseUnicodeRanges(const Text: string): TUnicodeRangeArray;
{ Whether CodePoint is in Ranges (nil: everything is). }
function RangesCover(constref Ranges: TUnicodeRangeArray; CodePoint: LongWord): Boolean;

implementation

uses
  SysUtils;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ One U+... item; False when it is not one. }
function ParseItem(const Item: string; out Range: TUnicodeRange): Boolean;
var
  Index, Digit, Digits: Integer;
  First, Last: QWord;
  InSecond: Boolean;
begin
  Result := False;
  if (Length(Item) < 3) or (UpCase(Item[1]) <> 'U') or (Item[2] <> '+') then
    Exit;
  First := 0;
  Last := 0;
  Digits := 0;
  InSecond := False;
  for Index := 3 to Length(Item) do
  begin
    if Item[Index] = '-' then
    begin
      if InSecond or (Digits = 0) then
        Exit;
      InSecond := True;
      Digits := 0;
      Continue;
    end;
    Inc(Digits);
    if Digits > 6 then
      Exit;
    if Item[Index] = '?' then
    begin
      if InSecond then
        Exit;
      First := First * 16;
      Last := Last * 16 + 15;
      Continue;
    end;
    Digit := HexValue(Item[Index]);
    if Digit < 0 then
      Exit;
    if InSecond then
      Last := Last * 16 + QWord(Digit)
    else
    begin
      First := First * 16 + QWord(Digit);
      Last := Last * 16 + QWord(Digit);
    end;
  end;
  if (Digits = 0) or (First > Last) or (First > $10FFFF) then
    Exit;
  if Last > $10FFFF then
    Last := $10FFFF;
  Range.First := First;
  Range.Last := Last;
  Result := True;
end;

function ParseUnicodeRanges(const Text: string): TUnicodeRangeArray;
var
  Items: TStringArray;
  Index: Integer;
  Range: TUnicodeRange;
begin
  Result := nil;
  Items := Text.Split([',']);
  for Index := 0 to High(Items) do
    if ParseItem(Trim(Items[Index]), Range) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Range;
    end;
end;

function RangesCover(constref Ranges: TUnicodeRangeArray; CodePoint: LongWord): Boolean;
var
  Index: Integer;
begin
  if Length(Ranges) = 0 then
    Exit(True);
  for Index := 0 to High(Ranges) do
    if (CodePoint >= Ranges[Index].First) and (CodePoint <= Ranges[Index].Last) then
      Exit(True);
  Result := False;
end;

end.
