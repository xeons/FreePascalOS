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
  The text of the trash: what a ".trashinfo" file says about an item
  moved to the trash (Util.Trash), in the layout other systems' desktops
  use too:

    [Trash Info]
    Path=/home/alice/My%20notes.txt
    DeletionDate=2026-11-21T10:20:30

  Path is where the item was, percent-encoded (bytes other than letters,
  digits and "-._~/" as %XX); DeletionDate is the local time it was
  moved there. Also the name an item gets in the trash: its own, or
  with a number ("notes.2.txt") when that is taken. Plain text logic,
  checked on the host (make files-test).
}
unit Util.TrashInfo;

{$mode objfpc}
{$H+}

interface

const
  TrashInfoExtension = '.trashinfo';
  TrashInfoHeading = '[Trash Info]';

type
  TTrashNameTaken = function(const Name: string): Boolean of object;

function PercentEncodePath(const Path: string): string;
{ False if Text has a malformed escape. }
function PercentDecodePath(const Text: string; out Path: string): Boolean;
{ "2026-11-21T10:20:30" for a local time given as seconds since 1970
  (the local clock, not UTC). }
function TrashDateText(LocalSeconds: Int64): string;
{ The local seconds of such a text; False if it is not one. }
function ParseTrashDate(const Text: string; out LocalSeconds: Int64): Boolean;
function FormatTrashInfo(const OriginalPath: string; LocalSeconds: Int64): string;
{ Reads a .trashinfo's text; False if it has no Path. }
function ParseTrashInfo(const Text: string; out OriginalPath: string; out LocalSeconds: Int64): Boolean;
{ Name, or "stem.N.ext" with the first N from 2 that IsTaken refuses. }
function FreeTrashName(const Name: string; IsTaken: TTrashNameTaken): string;

implementation

uses
  SysUtils;

const
  Unreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'];
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
  SecondsPerDay = 86400;

function PercentEncodePath(const Path: string): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 1 to Length(Path) do
    if Path[Index] in Unreserved then
      Result := Result + Path[Index]
    else
      Result := Result + '%' + HexDigits[Ord(Path[Index]) shr 4] + HexDigits[Ord(Path[Index]) and 15];
end;

function HexValue(Character: Char): LongInt;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function PercentDecodePath(const Text: string; out Path: string): Boolean;
var
  Index: LongInt;
  High: LongInt;
  Low: LongInt;
begin
  Path := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    if Text[Index] = '%' then
    begin
      if Index + 2 > Length(Text) then
        Exit(False);
      High := HexValue(Text[Index + 1]);
      Low := HexValue(Text[Index + 2]);
      if (High < 0) or (Low < 0) then
        Exit(False);
      Path := Path + Chr(High * 16 + Low);
      Inc(Index, 3);
    end
    else
    begin
      Path := Path + Text[Index];
      Inc(Index);
    end;
  end;
  Result := True;
end;

{ Days since 1970-01-01 to a civil date, and back (Gregorian). }
procedure CivilFromDays(Days: Int64; out Year, Month, Day: LongInt);
var
  Shifted: Int64;
  Era: Int64;
  DayOfEra: Int64;
  YearOfEra: Int64;
  DayOfYear: Int64;
  MonthPart: Int64;
begin
  Shifted := Days + 719468;
  if Shifted >= 0 then
    Era := Shifted div 146097
  else
    Era := (Shifted - 146096) div 146097;
  DayOfEra := Shifted - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  MonthPart := (5 * DayOfYear + 2) div 153;
  Day := DayOfYear - (153 * MonthPart + 2) div 5 + 1;
  if MonthPart < 10 then
    Month := MonthPart + 3
  else
    Month := MonthPart - 9;
  Year := YearOfEra + Era * 400;
  if Month <= 2 then
    Inc(Year);
end;

function DaysFromCivil(Year, Month, Day: LongInt): Int64;
var
  Era: Int64;
  YearOfEra: Int64;
  DayOfYear: Int64;
  ShiftedMonth: Int64;
begin
  if Month <= 2 then
    Dec(Year);
  if Year >= 0 then
    Era := Year div 400
  else
    Era := (Year - 399) div 400;
  YearOfEra := Year - Era * 400;
  if Month > 2 then
    ShiftedMonth := Month - 3
  else
    ShiftedMonth := Month + 9;
  DayOfYear := (153 * ShiftedMonth + 2) div 5 + Day - 1;
  Result := Era * 146097 + YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear - 719468;
end;

function TrashDateText(LocalSeconds: Int64): string;
var
  Days: Int64;
  Rest: Int64;
  Year: LongInt;
  Month: LongInt;
  Day: LongInt;
begin
  Days := LocalSeconds div SecondsPerDay;
  Rest := LocalSeconds mod SecondsPerDay;
  if Rest < 0 then
  begin
    Dec(Days);
    Rest := Rest + SecondsPerDay;
  end;
  CivilFromDays(Days, Year, Month, Day);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d', [Year, Month, Day, Rest div 3600, (Rest div 60) mod 60,
    Rest mod 60]);
end;

function ParseTrashDate(const Text: string; out LocalSeconds: Int64): Boolean;
var
  Year: LongInt;
  Month: LongInt;
  Day: LongInt;
  Hour: LongInt;
  Minute: LongInt;
  Second: LongInt;
begin
  LocalSeconds := 0;
  Result := (Length(Text) >= 19) and (Text[5] = '-') and (Text[8] = '-') and (Text[11] = 'T') and
    TryStrToInt(Copy(Text, 1, 4), Year) and TryStrToInt(Copy(Text, 6, 2), Month) and
    TryStrToInt(Copy(Text, 9, 2), Day) and TryStrToInt(Copy(Text, 12, 2), Hour) and
    TryStrToInt(Copy(Text, 15, 2), Minute) and TryStrToInt(Copy(Text, 18, 2), Second) and
    (Month >= 1) and (Month <= 12) and (Day >= 1) and (Day <= 31);
  if Result then
    LocalSeconds := DaysFromCivil(Year, Month, Day) * SecondsPerDay + Hour * 3600 + Minute * 60 + Second;
end;

function FormatTrashInfo(const OriginalPath: string; LocalSeconds: Int64): string;
begin
  Result := TrashInfoHeading + #10 + 'Path=' + PercentEncodePath(OriginalPath) + #10 + 'DeletionDate=' +
    TrashDateText(LocalSeconds) + #10;
end;

function ParseTrashInfo(const Text: string; out OriginalPath: string; out LocalSeconds: Int64): Boolean;
var
  Lines: TStringArray;
  Line: string;
  Trimmed: string;
  InSection: Boolean;
begin
  OriginalPath := '';
  LocalSeconds := 0;
  Result := False;
  InSection := False;
  Lines := StringReplace(Text, #13, '', [rfReplaceAll]).Split([#10]);
  for Line in Lines do
  begin
    Trimmed := Trim(Line);
    if (Trimmed <> '') and (Trimmed[1] = '[') then
      InSection := Trimmed = TrashInfoHeading
    else if InSection and (Copy(Trimmed, 1, 5) = 'Path=') then
      Result := PercentDecodePath(Copy(Trimmed, 6, Length(Trimmed)), OriginalPath) and (OriginalPath <> '')
    else if InSection and (Copy(Trimmed, 1, 13) = 'DeletionDate=') then
      ParseTrashDate(Copy(Trimmed, 14, Length(Trimmed)), LocalSeconds);
  end;
end;

function FreeTrashName(const Name: string; IsTaken: TTrashNameTaken): string;
var
  Dot: LongInt;
  Stem: string;
  Extension: string;
  Number: LongInt;
begin
  if not IsTaken(Name) then
    Exit(Name);
  Dot := Length(Name);
  while (Dot > 1) and (Name[Dot] <> '.') do
    Dec(Dot);
  if Dot > 1 then
  begin
    Stem := Copy(Name, 1, Dot - 1);
    Extension := Copy(Name, Dot, Length(Name));
  end
  else
  begin
    Stem := Name;
    Extension := '';
  end;
  Number := 2;
  repeat
    Result := Stem + '.' + IntToStr(Number) + Extension;
    Inc(Number);
  until not IsTaken(Result) or (Number > 100000);
end;

end.
