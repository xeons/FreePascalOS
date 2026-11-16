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
  Sizes for people: 1536 -> "1.5K", 3221225472 -> "3.0G" (powers of
  1024, as ls -h and df -h print them), and parsing of sizes with
  suffixes such as "10K" or "2M" (head -c, truncate -s).
}
unit Util.Sizes;

{$mode objfpc}{$H+}

interface

function FormatHumanSize(Size: QWord): string;
{ Accepts a decimal number with an optional suffix K, M, G, T (powers of
  1024) or KB, MB, GB, TB (powers of 1000). }
function ParseSize(const Text: string; out Size: QWord): Boolean;

implementation

uses
  SysUtils,
  Util.Numbers;

function FormatHumanSize(Size: QWord): string;
const
  Units: array[0..6] of Char = ('B', 'K', 'M', 'G', 'T', 'P', 'E');
var
  UnitIndex: Integer;
  Tenths: QWord;
  Divisor: QWord;
begin
  if Size < 1024 then
    Exit(IntToStr(Size));

  UnitIndex := 0;
  Divisor := 1;
  while (Size div Divisor >= 1024) and (UnitIndex < 6) do
  begin
    Divisor := Divisor * 1024;
    Inc(UnitIndex);
  end;
  { Round up, as GNU tools do, to one decimal below 10 and to whole
    numbers above. }
  Tenths := (Size * 10 + Divisor - 1) div Divisor;
  if Tenths >= 100 then
    Result := IntToStr((Tenths + 9) div 10)
  else
    Result := IntToStr(Tenths div 10) + '.' + Char(Ord('0') + Tenths mod 10);
  Result := Result + Units[UnitIndex];
end;

function ParseSize(const Text: string; out Size: QWord): Boolean;
var
  DigitCount: Integer;
  Suffix: string;
  Multiplier: QWord;
  Base: QWord;
  Value: QWord;
begin
  Size := 0;
  DigitCount := 0;
  while (DigitCount < Length(Text)) and (Text[DigitCount + 1] in ['0'..'9']) do
    Inc(DigitCount);
  if (DigitCount = 0) or not ParseUnsignedDecimal(Copy(Text, 1, DigitCount), Value) then
    Exit(False);

  Multiplier := 1;
  Suffix := UpperCase(Copy(Text, DigitCount + 1, MaxInt));
  if Suffix <> '' then
  begin
    Base := 1024;
    if (Length(Suffix) = 2) and (Suffix[2] = 'B') then
      Base := 1000
    else if Length(Suffix) <> 1 then
      Exit(False);
    case Suffix[1] of
      'K': Multiplier := Base;
      'M': Multiplier := Base * Base;
      'G': Multiplier := Base * Base * Base;
      'T': Multiplier := Base * Base * Base * Base;
    else
      Exit(False);
    end;
  end;
  Size := Value * Multiplier;
  Result := True;
end;

end.
