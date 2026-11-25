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
  Times as the archive formats keep them: the packed DOS date and time
  of zip headers (two-second steps, 1980 to 2107, no time zone: taken
  as UTC here) to and from Unix seconds.
}
unit Archive.Times;

{$mode objfpc}
{$H+}

interface

const
  SecondsPerDay = 86400;

{ Unix seconds of a DOS date (high word) and time (low word). }
function DosDateTimeToUnix(DosDate, DosTime: Word): Int64;
{ The DOS date and time of Unix seconds, held to 1980-01-01 and
  2107-12-31 23:59:58. }
procedure UnixToDosDateTime(UnixTime: Int64; out DosDate, DosTime: Word);

{ Days since 1970-01-01 of a date in the proleptic Gregorian calendar. }
function DaysFromCivil(Year, Month, Day: Integer): Int64;
procedure CivilFromDays(Days: Int64; out Year, Month, Day: Integer);

implementation

function FloorDivide(Numerator, Denominator: Int64): Int64;
begin
  Result := Numerator div Denominator;
  if (Numerator mod Denominator <> 0) and ((Numerator < 0) <> (Denominator < 0)) then
    Dec(Result);
end;

function DaysFromCivil(Year, Month, Day: Integer): Int64;
var
  Era, YearOfEra, DayOfYear, DayOfEra: Int64;
  ShiftedYear: Int64;
begin
  ShiftedYear := Year;
  if Month <= 2 then
    Dec(ShiftedYear);
  Era := FloorDivide(ShiftedYear, 400);
  YearOfEra := ShiftedYear - Era * 400;
  if Month > 2 then
    DayOfYear := (153 * (Month - 3) + 2) div 5 + Day - 1
  else
    DayOfYear := (153 * (Month + 9) + 2) div 5 + Day - 1;
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

procedure CivilFromDays(Days: Int64; out Year, Month, Day: Integer);
var
  Shifted, Era, DayOfEra, YearOfEra, DayOfYear, MonthPart: Int64;
begin
  Shifted := Days + 719468;
  Era := FloorDivide(Shifted, 146097);
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

function DosDateTimeToUnix(DosDate, DosTime: Word): Int64;
var
  Year, Month, Day, Hour, Minute, Second: Integer;
begin
  Year := 1980 + (DosDate shr 9);
  Month := (DosDate shr 5) and 15;
  Day := DosDate and 31;
  if (Month < 1) or (Month > 12) then
    Month := 1;
  if Day < 1 then
    Day := 1;
  Hour := DosTime shr 11;
  Minute := (DosTime shr 5) and 63;
  Second := (DosTime and 31) * 2;
  Result := DaysFromCivil(Year, Month, Day) * SecondsPerDay + Hour * 3600 + Minute * 60 + Second;
end;

procedure UnixToDosDateTime(UnixTime: Int64; out DosDate, DosTime: Word);
const
  EarliestDosTime = Int64(315532800);    { 1980-01-01 00:00:00 }
  LatestDosTime = Int64(4354819198);     { 2107-12-31 23:59:58 }
var
  Days, SecondOfDay: Int64;
  Year, Month, Day: Integer;
begin
  if UnixTime < EarliestDosTime then
    UnixTime := EarliestDosTime;
  if UnixTime > LatestDosTime then
    UnixTime := LatestDosTime;
  Days := FloorDivide(UnixTime, SecondsPerDay);
  SecondOfDay := UnixTime - Days * SecondsPerDay;
  CivilFromDays(Days, Year, Month, Day);
  DosDate := Word(((Year - 1980) shl 9) or (Month shl 5) or Day);
  DosTime := Word(((SecondOfDay div 3600) shl 11) or (((SecondOfDay div 60) mod 60) shl 5) or
    ((SecondOfDay mod 60) div 2));
end;

end.
