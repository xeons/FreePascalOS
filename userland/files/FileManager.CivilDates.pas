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
  Calendar days as numbers: the days since 1970-01-01 of a year, month
  and day and back (the proleptic Gregorian calendar, any year), the
  weekday of a day, and the start of a day, week, month or year as Unix
  seconds for a time zone given as its offset from UTC.

  What search's "modified:" ranges, grouping by date and the gallery's
  months are worked out with. Plain arithmetic, checked on the host
  (make files-test).
}
unit FileManager.CivilDates;

{$mode objfpc}
{$H+}

interface

type
  TCivilDate = record
    Year: LongInt;
    Month: LongInt;
    Day: LongInt;
  end;

const
  SecondsPerDay = 86400;
  MonthNames: array[1..12] of string = ('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December');

{ Days since 1970-01-01 (negative before). }
function DaysFromCivil(Year, Month, Day: LongInt): Int64;
function CivilFromDays(Days: Int64): TCivilDate;
{ 0 Monday .. 6 Sunday. }
function WeekdayOfDays(Days: Int64): LongInt;
{ The local day a Unix time falls on (days since 1970-01-01, local). }
function LocalDayOf(UnixTime: Int64; LocalOffset: LongInt): Int64;
{ The Unix time a local day starts at. }
function StartOfLocalDay(Days: Int64; LocalOffset: LongInt): Int64;
{ The local date of a Unix time. }
function LocalDateOf(UnixTime: Int64; LocalOffset: LongInt): TCivilDate;
{ Reads "YYYY-MM-DD" (or "YYYY/MM/DD"); False if it is not one. }
function ParseIsoDate(const Text: string; out Date: TCivilDate): Boolean;

implementation

uses
  SysUtils;

function FloorDivide(Value, Divisor: Int64): Int64;
begin
  Result := Value div Divisor;
  if (Value mod Divisor <> 0) and ((Value < 0) <> (Divisor < 0)) then
    Dec(Result);
end;

function DaysFromCivil(Year, Month, Day: LongInt): Int64;
var
  Era: Int64;
  YearOfEra: Int64;
  DayOfYear: Int64;
  DayOfEra: Int64;
  ShiftedMonth: Int64;
  ShiftedYear: Int64;
begin
  ShiftedYear := Year;
  if Month <= 2 then
    Dec(ShiftedYear);
  Era := FloorDivide(ShiftedYear, 400);
  YearOfEra := ShiftedYear - Era * 400;
  if Month > 2 then
    ShiftedMonth := Month - 3
  else
    ShiftedMonth := Month + 9;
  DayOfYear := (153 * ShiftedMonth + 2) div 5 + Day - 1;
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

function CivilFromDays(Days: Int64): TCivilDate;
var
  Shifted: Int64;
  Era: Int64;
  DayOfEra: Int64;
  YearOfEra: Int64;
  DayOfYear: Int64;
  MonthPart: Int64;
  Year: Int64;
begin
  Shifted := Days + 719468;
  Era := FloorDivide(Shifted, 146097);
  DayOfEra := Shifted - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  Year := YearOfEra + Era * 400;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  MonthPart := (5 * DayOfYear + 2) div 153;
  Result.Day := DayOfYear - (153 * MonthPart + 2) div 5 + 1;
  if MonthPart < 10 then
    Result.Month := MonthPart + 3
  else
    Result.Month := MonthPart - 9;
  if Result.Month <= 2 then
    Inc(Year);
  Result.Year := Year;
end;

function WeekdayOfDays(Days: Int64): LongInt;
begin
  { 1970-01-01 was a Thursday (3, counting from Monday). }
  Result := (FloorDivide(Days, 1) + 3) mod 7;
  if Result < 0 then
    Result := Result + 7;
end;

function LocalDayOf(UnixTime: Int64; LocalOffset: LongInt): Int64;
begin
  Result := FloorDivide(UnixTime + LocalOffset, SecondsPerDay);
end;

function StartOfLocalDay(Days: Int64; LocalOffset: LongInt): Int64;
begin
  Result := Days * SecondsPerDay - LocalOffset;
end;

function LocalDateOf(UnixTime: Int64; LocalOffset: LongInt): TCivilDate;
begin
  Result := CivilFromDays(LocalDayOf(UnixTime, LocalOffset));
end;

function ParseIsoDate(const Text: string; out Date: TCivilDate): Boolean;
var
  Parts: TStringArray;
begin
  Date := Default(TCivilDate);
  Parts := StringReplace(Text, '/', '-', [rfReplaceAll]).Split(['-']);
  Result := (Length(Parts) = 3) and TryStrToInt(Parts[0], Date.Year) and TryStrToInt(Parts[1], Date.Month) and
    TryStrToInt(Parts[2], Date.Day) and (Date.Month >= 1) and (Date.Month <= 12) and (Date.Day >= 1) and
    (Date.Day <= 31) and (Length(Parts[0]) = 4);
end;

end.
