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
  Calendar dates: the plain arithmetic behind the calendar and the date
  picker, with nothing of the screen in it (it builds for the host too,
  and is checked there).

  A date is a year, a month (1 to 12) and a day of the proleptic
  Gregorian calendar; a date whose year is 0 means none (no lower or
  upper limit, say). Days are counted from 1970-01-01 (DayNumberOf) to
  compare and move dates. Days of the week go from 0, Sunday, to 6,
  Saturday. Weeks are numbered as ISO 8601 does: weeks start on Monday
  and week 1 is the one with the year's first Thursday.

  A month is shown as a grid of six weeks, seven days each, starting on
  the first day of the week chosen (FirstDayOfWeek): the days before the
  first of the month and after its last come from the months either
  side.
}
unit Controls.CalendarDates;

{$mode objfpc}
{$H+}

interface

type
  TCalendarDate = record
    Year: LongInt;
    Month: LongInt;
    Day: LongInt;
  end;

const
  DaysInWeek = 7;
  GridWeeks = 6;
  GridDays = GridWeeks * DaysInWeek;
  DayNames: array[0..6] of string = ('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
    'Saturday');
  MonthNames: array[1..12] of string = ('January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December');

function MakeCalendarDate(Year, Month, Day: LongInt): TCalendarDate;
function NoCalendarDate: TCalendarDate;
function IsNoDate(const Date: TCalendarDate): Boolean;
function IsLeapYearOf(Year: LongInt): Boolean;
function DaysInMonthOf(Year, Month: LongInt): LongInt;
{ A real date: the month 1 to 12, the day within it. }
function IsValidDate(const Date: TCalendarDate): Boolean;
{ Days since 1970-01-01 (negative before it). }
function DayNumberOf(const Date: TCalendarDate): LongInt;
function DateOfDayNumber(DayNumber: LongInt): TCalendarDate;
{ 0 = Sunday to 6 = Saturday. }
function DayOfWeekOf(const Date: TCalendarDate): LongInt;
{ Negative if First is before Second, 0 if the same day, positive after. }
function CompareDates(const First, Second: TCalendarDate): LongInt;
function SameDate(const First, Second: TCalendarDate): Boolean;
function AddDays(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
{ Months later (earlier if negative), the day kept or, if that month is
  shorter, its last. }
function AddMonths(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
function AddYears(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
{ The ISO 8601 week (1 to 53) the date is in, and the year that week
  belongs to (the days of week 1 may be late December's, of week 52 or
  53 early January's). }
function IsoWeekOf(const Date: TCalendarDate; out WeekYear: LongInt): LongInt;
function IsoWeekNumber(const Date: TCalendarDate): LongInt;
{ Within the limits (a limit that is no date is none). }
function DateWithin(const Date, Minimum, Maximum: TCalendarDate): Boolean;
function ClampDate(const Date, Minimum, Maximum: TCalendarDate): TCalendarDate;

{ How many days of the previous month the grid of Year-Month starts
  with (0 to 6), weeks starting on FirstDayOfWeek. }
function GridLeadingDays(Year, Month, FirstDayOfWeek: LongInt): LongInt;
{ The date in cell Index (0 to GridDays - 1, row by row) of the grid. }
function GridCellDate(Year, Month, FirstDayOfWeek, Index: LongInt): TCalendarDate;
{ The cell Year-Month's grid shows Date in; -1 if it is not shown. }
function GridIndexOfDate(Year, Month, FirstDayOfWeek: LongInt; const Date: TCalendarDate): LongInt;
{ The day of the week of column Column (0 to 6). }
function GridColumnDay(FirstDayOfWeek, Column: LongInt): LongInt;

{ "2026-11-16". }
function DateToIsoText(const Date: TCalendarDate): string;
{ Reads YYYY-MM-DD; False if it is not a real date. }
function TryIsoTextToDate(const Text: string; out Date: TCalendarDate): Boolean;

implementation

function MakeCalendarDate(Year, Month, Day: LongInt): TCalendarDate;
begin
  Result.Year := Year;
  Result.Month := Month;
  Result.Day := Day;
end;

function NoCalendarDate: TCalendarDate;
begin
  Result := MakeCalendarDate(0, 0, 0);
end;

function IsNoDate(const Date: TCalendarDate): Boolean;
begin
  Result := Date.Year = 0;
end;

function IsLeapYearOf(Year: LongInt): Boolean;
begin
  Result := ((Year mod 4 = 0) and (Year mod 100 <> 0)) or (Year mod 400 = 0);
end;

function DaysInMonthOf(Year, Month: LongInt): LongInt;
const
  Lengths: array[1..12] of LongInt = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  if (Month < 1) or (Month > 12) then
    Exit(0);
  Result := Lengths[Month];
  if (Month = 2) and IsLeapYearOf(Year) then
    Result := 29;
end;

function IsValidDate(const Date: TCalendarDate): Boolean;
begin
  Result := (Date.Month >= 1) and (Date.Month <= 12) and (Date.Day >= 1) and
    (Date.Day <= DaysInMonthOf(Date.Year, Date.Month));
end;

{ Division rounding towards minus infinity, for years before 1. }
function FloorDivide(Value, Divisor: LongInt): LongInt;
begin
  Result := Value div Divisor;
  if (Value mod Divisor <> 0) and ((Value < 0) <> (Divisor < 0)) then
    Dec(Result);
end;

{ Days from civil dates (the era arithmetic of H. Hinnant's algorithm):
  years counted from March, so the leap day comes last. }
function DayNumberOf(const Date: TCalendarDate): LongInt;
var
  Year: LongInt;
  Era: LongInt;
  YearOfEra: LongInt;
  DayOfYear: LongInt;
  DayOfEra: LongInt;
  ShiftedMonth: LongInt;
begin
  Year := Date.Year;
  if Date.Month <= 2 then
    Dec(Year);
  Era := FloorDivide(Year, 400);
  YearOfEra := Year - Era * 400;
  if Date.Month > 2 then
    ShiftedMonth := Date.Month - 3
  else
    ShiftedMonth := Date.Month + 9;
  DayOfYear := (153 * ShiftedMonth + 2) div 5 + Date.Day - 1;
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

function DateOfDayNumber(DayNumber: LongInt): TCalendarDate;
var
  Shifted: LongInt;
  Era: LongInt;
  DayOfEra: LongInt;
  YearOfEra: LongInt;
  DayOfYear: LongInt;
  ShiftedMonth: LongInt;
begin
  Shifted := DayNumber + 719468;
  Era := FloorDivide(Shifted, 146097);
  DayOfEra := Shifted - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  ShiftedMonth := (5 * DayOfYear + 2) div 153;
  Result.Day := DayOfYear - (153 * ShiftedMonth + 2) div 5 + 1;
  if ShiftedMonth < 10 then
    Result.Month := ShiftedMonth + 3
  else
    Result.Month := ShiftedMonth - 9;
  Result.Year := YearOfEra + Era * 400;
  if Result.Month <= 2 then
    Inc(Result.Year);
end;

function DayOfWeekOf(const Date: TCalendarDate): LongInt;
begin
  { 1970-01-01 was a Thursday. }
  Result := (DayNumberOf(Date) + 4) mod DaysInWeek;
  if Result < 0 then
    Inc(Result, DaysInWeek);
end;

function CompareDates(const First, Second: TCalendarDate): LongInt;
begin
  Result := First.Year - Second.Year;
  if Result = 0 then
    Result := First.Month - Second.Month;
  if Result = 0 then
    Result := First.Day - Second.Day;
end;

function SameDate(const First, Second: TCalendarDate): Boolean;
begin
  Result := CompareDates(First, Second) = 0;
end;

function AddDays(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
begin
  Result := DateOfDayNumber(DayNumberOf(Date) + Count);
end;

function AddMonths(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
var
  MonthIndex: LongInt;
  Length: LongInt;
begin
  MonthIndex := Date.Year * 12 + (Date.Month - 1) + Count;
  Result.Year := FloorDivide(MonthIndex, 12);
  Result.Month := MonthIndex - Result.Year * 12 + 1;
  Result.Day := Date.Day;
  Length := DaysInMonthOf(Result.Year, Result.Month);
  if Result.Day > Length then
    Result.Day := Length;
end;

function AddYears(const Date: TCalendarDate; Count: LongInt): TCalendarDate;
begin
  Result := AddMonths(Date, Count * 12);
end;

function IsoWeekOf(const Date: TCalendarDate; out WeekYear: LongInt): LongInt;
var
  Thursday: TCalendarDate;
  MondayBased: LongInt;
begin
  { The week's Thursday decides the year it belongs to; its place in
    that year gives the number. }
  MondayBased := (DayOfWeekOf(Date) + 6) mod DaysInWeek;
  Thursday := AddDays(Date, 3 - MondayBased);
  WeekYear := Thursday.Year;
  Result := (DayNumberOf(Thursday) - DayNumberOf(MakeCalendarDate(WeekYear, 1, 1))) div DaysInWeek + 1;
end;

function IsoWeekNumber(const Date: TCalendarDate): LongInt;
var
  WeekYear: LongInt;
begin
  Result := IsoWeekOf(Date, WeekYear);
end;

function DateWithin(const Date, Minimum, Maximum: TCalendarDate): Boolean;
begin
  Result := (IsNoDate(Minimum) or (CompareDates(Date, Minimum) >= 0)) and
    (IsNoDate(Maximum) or (CompareDates(Date, Maximum) <= 0));
end;

function ClampDate(const Date, Minimum, Maximum: TCalendarDate): TCalendarDate;
begin
  Result := Date;
  if not IsNoDate(Minimum) and (CompareDates(Result, Minimum) < 0) then
    Result := Minimum;
  if not IsNoDate(Maximum) and (CompareDates(Result, Maximum) > 0) then
    Result := Maximum;
end;

function GridLeadingDays(Year, Month, FirstDayOfWeek: LongInt): LongInt;
begin
  Result := (DayOfWeekOf(MakeCalendarDate(Year, Month, 1)) - FirstDayOfWeek + DaysInWeek) mod DaysInWeek;
end;

function GridCellDate(Year, Month, FirstDayOfWeek, Index: LongInt): TCalendarDate;
begin
  Result := AddDays(MakeCalendarDate(Year, Month, 1), Index - GridLeadingDays(Year, Month, FirstDayOfWeek));
end;

function GridIndexOfDate(Year, Month, FirstDayOfWeek: LongInt; const Date: TCalendarDate): LongInt;
begin
  Result := DayNumberOf(Date) - DayNumberOf(MakeCalendarDate(Year, Month, 1)) +
    GridLeadingDays(Year, Month, FirstDayOfWeek);
  if (Result < 0) or (Result >= GridDays) then
    Result := -1;
end;

function GridColumnDay(FirstDayOfWeek, Column: LongInt): LongInt;
begin
  Result := (FirstDayOfWeek + Column) mod DaysInWeek;
end;

function DigitsOf(Value, Width: LongInt): string;
begin
  Str(Value, Result);
  while Length(Result) < Width do
    Result := '0' + Result;
end;

function DateToIsoText(const Date: TCalendarDate): string;
begin
  Result := DigitsOf(Date.Year, 4) + '-' + DigitsOf(Date.Month, 2) + '-' + DigitsOf(Date.Day, 2);
end;

function TryIsoTextToDate(const Text: string; out Date: TCalendarDate): Boolean;
var
  Code: Integer;
begin
  Result := False;
  Date := NoCalendarDate;
  if (Length(Text) <> 10) or (Text[5] <> '-') or (Text[8] <> '-') then
    Exit;
  Val(Copy(Text, 1, 4), Date.Year, Code);
  if Code <> 0 then
    Exit;
  Val(Copy(Text, 6, 2), Date.Month, Code);
  if Code <> 0 then
    Exit;
  Val(Copy(Text, 9, 2), Date.Day, Code);
  if Code <> 0 then
    Exit;
  Result := IsValidDate(Date);
end;

end.
