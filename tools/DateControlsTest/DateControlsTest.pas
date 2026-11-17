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
  DateControlsTest: the plain logic behind the calendar, the date and
  time picker and the numeric up/down box, on the host.

    DateControlsTest

  Calendar dates (Controls.CalendarDates: leap years, day numbers, days
  of the week, the month grid's first day, ISO week numbers, moving by
  months), where the calendar's parts go (Controls.CalendarLayout),
  date and time patterns and their fields (Controls.DateFormats:
  stepping, typing) and numbers (Controls.NumericValues: rounding,
  clamping, showing, reading). Every check prints a line; the exit code
  is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program DateControlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Drawing.Rectangles,
  Controls.CalendarDates,
  Controls.CalendarLayout,
  Controls.DateFormats,
  Controls.NumericValues;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[date] pass: ', Name)
  else
  begin
    WriteLn('[date] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function Day(Year, Month, DayOfMonth: LongInt): TCalendarDate;
begin
  Result := MakeCalendarDate(Year, Month, DayOfMonth);
end;

function IsDay(const Date: TCalendarDate; Year, Month, DayOfMonth: LongInt): Boolean;
begin
  Result := SameDate(Date, Day(Year, Month, DayOfMonth));
end;

procedure TestLeapYearsAndMonths;
begin
  Check('2024 is a leap year', IsLeapYearOf(2024));
  Check('2023 is not a leap year', not IsLeapYearOf(2023));
  Check('1900 is not a leap year (a century)', not IsLeapYearOf(1900));
  Check('2000 is a leap year (a fourth century)', IsLeapYearOf(2000));
  Check('2100 is not a leap year', not IsLeapYearOf(2100));
  Check('February 2024 has 29 days', DaysInMonthOf(2024, 2) = 29);
  Check('February 2026 has 28 days', DaysInMonthOf(2026, 2) = 28);
  Check('April has 30 days, December 31', (DaysInMonthOf(2026, 4) = 30) and (DaysInMonthOf(2026, 12) = 31));
  Check('2024-02-29 is a date, 2026-02-29 is not', IsValidDate(Day(2024, 2, 29)) and not IsValidDate(Day(2026, 2, 29)));
  Check('month 13 is no date', not IsValidDate(Day(2026, 13, 1)));
end;

procedure TestDayNumbers;
var
  Number: LongInt;
  RoundTrips: Boolean;
begin
  Check('1970-01-01 is day 0', DayNumberOf(Day(1970, 1, 1)) = 0);
  Check('1969-12-31 is day -1', DayNumberOf(Day(1969, 12, 31)) = -1);
  Check('2000-03-01 is day 11017', DayNumberOf(Day(2000, 3, 1)) = 11017);
  Check('day 20408 is 2025-11-16', IsDay(DateOfDayNumber(20408), 2025, 11, 16));
  RoundTrips := True;
  Number := -800000;
  while Number <= 800000 do
  begin
    if DayNumberOf(DateOfDayNumber(Number)) <> Number then
      RoundTrips := False;
    Inc(Number, 97);
  end;
  Check('day numbers go to dates and back (1 to 4160)', RoundTrips);
  Check('1970-01-01 was a Thursday', DayOfWeekOf(Day(1970, 1, 1)) = 4);
  Check('2026-11-16 is a Monday', DayOfWeekOf(Day(2026, 11, 16)) = 1);
  Check('2000-01-01 was a Saturday', DayOfWeekOf(Day(2000, 1, 1)) = 6);
  Check('1900-01-01 was a Monday', DayOfWeekOf(Day(1900, 1, 1)) = 1);
  Check('dates compare by year, month, day',
    (CompareDates(Day(2026, 1, 31), Day(2026, 2, 1)) < 0) and (CompareDates(Day(2027, 1, 1), Day(2026, 12, 31)) > 0));
end;

procedure TestMovingDates;
begin
  Check('a day after 2024-02-28 is the 29th', IsDay(AddDays(Day(2024, 2, 28), 1), 2024, 2, 29));
  Check('a day after 2026-12-31 is the new year', IsDay(AddDays(Day(2026, 12, 31), 1), 2027, 1, 1));
  Check('a month after 2024-01-31 is 2024-02-29', IsDay(AddMonths(Day(2024, 1, 31), 1), 2024, 2, 29));
  Check('a month before 2026-03-31 is 2026-02-28', IsDay(AddMonths(Day(2026, 3, 31), -1), 2026, 2, 28));
  Check('thirteen months after 2026-12-15 is 2028-01-15', IsDay(AddMonths(Day(2026, 12, 15), 13), 2028, 1, 15));
  Check('a month before January is December', IsDay(AddMonths(Day(2026, 1, 10), -1), 2025, 12, 10));
  Check('a year after 2024-02-29 is 2025-02-28', IsDay(AddYears(Day(2024, 2, 29), 1), 2025, 2, 28));
  Check('a date before the limit is clamped to it',
    IsDay(ClampDate(Day(2026, 1, 1), Day(2026, 6, 1), Day(2026, 12, 31)), 2026, 6, 1));
  Check('a date after the limit is clamped to it',
    IsDay(ClampDate(Day(2027, 1, 1), Day(2026, 6, 1), Day(2026, 12, 31)), 2026, 12, 31));
  Check('no limit is no limit', DateWithin(Day(1, 1, 1), NoCalendarDate, NoCalendarDate));
end;

procedure TestIsoWeeks;
var
  WeekYear: LongInt;
begin
  Check('2026-01-01 (a Thursday) is in week 1 of 2026',
    (IsoWeekOf(Day(2026, 1, 1), WeekYear) = 1) and (WeekYear = 2026));
  Check('2027-01-01 (a Friday) is in week 53 of 2026',
    (IsoWeekOf(Day(2027, 1, 1), WeekYear) = 53) and (WeekYear = 2026));
  Check('2021-01-03 (a Sunday) is in week 53 of 2020',
    (IsoWeekOf(Day(2021, 1, 3), WeekYear) = 53) and (WeekYear = 2020));
  Check('2024-12-30 (a Monday) is in week 1 of 2025',
    (IsoWeekOf(Day(2024, 12, 30), WeekYear) = 1) and (WeekYear = 2025));
  Check('2026-11-16 is in week 47', IsoWeekNumber(Day(2026, 11, 16)) = 47);
  Check('2026-11-22 (Sunday) is still week 47, 2026-11-23 week 48',
    (IsoWeekNumber(Day(2026, 11, 22)) = 47) and (IsoWeekNumber(Day(2026, 11, 23)) = 48));
  Check('2020-12-31 is in week 53', IsoWeekNumber(Day(2020, 12, 31)) = 53);
end;

procedure TestMonthGrid;
begin
  { November 2026 starts on a Sunday. }
  Check('Nov 2026, weeks from Monday: 6 days of October first', GridLeadingDays(2026, 11, 1) = 6);
  Check('Nov 2026, weeks from Sunday: none of October', GridLeadingDays(2026, 11, 0) = 0);
  Check('Nov 2026, weeks from Saturday: one day of October', GridLeadingDays(2026, 11, 6) = 1);
  Check('Nov 2026 from Monday: the first cell is 2026-10-26', IsDay(GridCellDate(2026, 11, 1, 0), 2026, 10, 26));
  Check('Nov 2026 from Monday: cell 6 is the first', IsDay(GridCellDate(2026, 11, 1, 6), 2026, 11, 1));
  Check('Nov 2026 from Monday: the last cell is 2026-12-06', IsDay(GridCellDate(2026, 11, 1, GridDays - 1), 2026, 12, 6));
  Check('Nov 2026 from Monday: the 16th is in cell 21', GridIndexOfDate(2026, 11, 1, Day(2026, 11, 16)) = 21);
  Check('a date beyond the grid is in no cell', GridIndexOfDate(2026, 11, 1, Day(2027, 1, 1)) = -1);
  { February 2021 starts on a Monday and fills four weeks exactly. }
  Check('Feb 2021 from Monday starts with no leading days', GridLeadingDays(2021, 2, 1) = 0);
  Check('March 2026 from Monday: Sunday the 1st after six days of February', GridLeadingDays(2026, 3, 1) = 6);
  Check('columns from Monday: the last is Sunday', (GridColumnDay(1, 0) = 1) and (GridColumnDay(1, 6) = 0));
end;

procedure TestIsoText;
var
  Date: TCalendarDate;
begin
  Check('2026-03-05 as text', DateToIsoText(Day(2026, 3, 5)) = '2026-03-05');
  Check('text read back', TryIsoTextToDate('2024-02-29', Date) and IsDay(Date, 2024, 2, 29));
  Check('not a date as text', not TryIsoTextToDate('2026-02-30', Date));
  Check('not the form', not TryIsoTextToDate('2026/02/01', Date));
end;

procedure TestCalendarLayout;
var
  Metrics: TCalendarMetrics;
  Layout: TCalendarLayout;
  Cell: LongInt;
  Last: TRectangle;
  Width: LongInt;
  Height: LongInt;
begin
  Metrics.LineHeight := 14;
  Metrics.Gap := 2;
  Metrics.WeekColumnWidth := 0;
  Metrics.ShowsDays := True;
  Metrics.ShowsToday := True;
  Layout := ComputeCalendarLayout(MakeRectangle(0, 0, 200, 180), Metrics);
  Check('days layout: seven columns, six rows', (Layout.Columns = 7) and (Layout.Rows = 6));
  Check('the first cell starts at the grid', (CalendarCellBounds(Layout, 0).Left = Layout.Grid.Left) and
    (CalendarCellBounds(Layout, 0).Top = Layout.Grid.Top));
  Last := CalendarCellBounds(Layout, GridDays - 1);
  Check('the last cell ends at the grid', (Last.Right = Layout.Grid.Right) and (Last.Bottom = Layout.Grid.Bottom));
  Check('the previous button is at the left, the next at the right',
    (Layout.Previous.Left < Layout.Title.Left) and (Layout.Next.Left > Layout.Title.Right - 1));
  Check('a point in the previous button finds it',
    CalendarPartAt(Layout, Layout.Previous.Left + 1, Layout.Previous.Top + 1, Cell) = CalendarPartPrevious);
  Check('a point in cell 9 finds it',
    (CalendarPartAt(Layout, CalendarCellBounds(Layout, 9).Left + 1, CalendarCellBounds(Layout, 9).Top + 1, Cell) =
    CalendarPartCell) and (Cell = 9));
  Check('the footer is the today line', CalendarPartAt(Layout, 100, 178, Cell) = CalendarPartToday);
  Metrics.ShowsDays := False;
  Layout := ComputeCalendarLayout(MakeRectangle(0, 0, 200, 180), Metrics);
  Check('months layout: four by three', (Layout.Columns = MonthColumns) and (Layout.Rows = MonthRows));
  Metrics.ShowsDays := True;
  Metrics.WeekColumnWidth := 20;
  CalendarSizeFor(Metrics, 24, 18, Width, Height);
  Check('the size for cells holds them and the week numbers', (Width = 2 * 2 + 20 + 7 * 24) and
    (Height = (14 + 8) + (14 + 4) + 6 * 18 + 2 + (14 + 6)));
end;

procedure TestPatterns;
var
  Fields: TDateTimeFields;
  Parts: TDateTimeParts;
begin
  Fields := ParseDateTimePattern(ShortDatePattern);
  Check('yyyy-MM-dd: five fields', Length(Fields) = 5);
  Check('yyyy-MM-dd: year, literal, month, literal, day', (Fields[0].Kind = FieldYear) and
    (Fields[1].Kind = FieldLiteral) and (Fields[1].Literal = '-') and (Fields[2].Kind = FieldMonthNumber) and
    (Fields[4].Kind = FieldDay));
  Parts := MakeDateTimeParts(2026, 3, 5, 14, 7, 9);
  Check('short date shown', FormatDateTimeParts(Fields, Parts) = '2026-03-05');
  Check('long date shown',
    FormatDateTimeParts(ParseDateTimePattern(LongDatePattern), Parts) = 'Thursday, 5 March 2026');
  Check('long time shown', FormatDateTimeParts(ParseDateTimePattern(LongTimePattern), Parts) = '14:07:09');
  Check('twelve hours with AM and PM',
    FormatDateTimeParts(ParseDateTimePattern('h:mm tt'), Parts) = '2:07 PM');
  Check('midnight is 12 AM', FormatDateTimeParts(ParseDateTimePattern('hh tt'),
    MakeDateTimeParts(2026, 3, 5, 0, 0, 0)) = '12 AM');
  Check('quoted text is shown as it is',
    FormatDateTimeParts(ParseDateTimePattern('''Day'' d ''of'' MMM yy'), Parts) = 'Day 5 of Mar 26');
  Check('the day of the week is not edited', not FieldIsEditable(FieldWeekdayName));
end;

procedure TestStepping;
var
  Parts: TDateTimeParts;
begin
  Parts := MakeDateTimeParts(2026, 1, 31, 23, 59, 0);
  Check('the day wraps within the month', StepField(Parts, FieldDay, 1).Date.Day = 1);
  Check('the day wraps back to the last', StepField(MakeDateTimeParts(2026, 2, 1, 0, 0, 0), FieldDay, -1).Date.Day = 28);
  Check('a month on from January 31: February 28', IsDay(StepField(Parts, FieldMonthNumber, 1).Date, 2026, 2, 28));
  Check('the month wraps from December to January (same year)',
    IsDay(StepField(MakeDateTimeParts(2026, 12, 5, 0, 0, 0), FieldMonthName, 1).Date, 2026, 1, 5));
  Check('a year back from 2024-02-29: 2023-02-28',
    IsDay(StepField(MakeDateTimeParts(2024, 2, 29, 0, 0, 0), FieldYear, -1).Date, 2023, 2, 28));
  Check('the hour wraps from 23 to 0', StepField(Parts, FieldHour24, 1).Hour = 0);
  Check('the minute wraps from 59 to 0 (the hour stays)',
    (StepField(Parts, FieldMinute, 1).Minute = 0) and (StepField(Parts, FieldMinute, 1).Hour = 23));
  Check('AM and PM swap the halves of the day', StepField(Parts, FieldDayPeriod, 1).Hour = 11);
  Check('a twelve hour field goes round the whole day', StepField(MakeDateTimeParts(2026, 1, 1, 11, 0, 0),
    FieldHour12, 1).Hour = 12);
  Check('setting 12 o''clock in the afternoon keeps PM',
    SetFieldNumber(MakeDateTimeParts(2026, 1, 1, 15, 0, 0), FieldHour12, 12).Hour = 12);
  Check('the year stops at 9999', StepField(MakeDateTimeParts(9999, 1, 1, 0, 0, 0), FieldYear, 1).Date.Year = 9999);
end;

procedure TestTyping;
var
  Typing: TFieldTyping;
  Parts: TDateTimeParts;
  Complete: Boolean;
begin
  Parts := MakeDateTimeParts(2024, 2, 10, 8, 30, 0);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldDay, 3, Complete);
  Check('a 3 typed in the day: 3, more may come', (Parts.Date.Day = 3) and not Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldDay, 1, Complete);
  Check('then a 1: 31 kept within February (29), and the day is full', (Parts.Date.Day = 29) and Complete);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldMonthNumber, 4, Complete);
  Check('a 4 typed in the month is April, full at once', (Parts.Date.Month = 4) and Complete);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldMonthNumber, 1, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldMonthNumber, 2, Complete);
  Check('1 then 2 in the month is December', (Parts.Date.Month = 12) and Complete);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 2, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 0, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 2, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 7, Complete);
  Check('2027 typed in the year', (Parts.Date.Year = 2027) and Complete);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 3, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldYear, 1, Complete);
  Parts := FinishFieldTyping(Typing, Parts, FieldYear);
  Check('31 typed in the year and left: 2031', Parts.Date.Year = 2031);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldHour24, 2, Complete);
  Check('a 2 in the hour waits for more', (Parts.Hour = 2) and not Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldHour24, 5, Complete);
  Check('a 5 after it would be 25: it starts again at 5, and is full', (Parts.Hour = 5) and Complete);
  StartFieldTyping(Typing);
  Parts := TypeFieldDigit(Typing, Parts, FieldMinute, 0, Complete);
  Parts := TypeFieldDigit(Typing, Parts, FieldMinute, 7, Complete);
  Check('0 then 7 in the minute: 07', (Parts.Minute = 7) and Complete);
end;

procedure TestNumbers;
var
  Format: TNumberFormat;
  Value: Double;
begin
  Format := MakeNumberFormat(2, False, False);
  Check('2.675 rounds to 2.68 (two places)', Abs(RoundToFormat(2.675, Format) - 2.68) < 1E-9);
  Check('-1.005 rounds to -1.01 (halves away from zero)', Abs(RoundToFormat(-1.005, Format) + 1.01) < 1E-9);
  Check('no places: 2.5 rounds to 3', RoundToFormat(2.5, MakeNumberFormat(0, False, False)) = 3);
  Check('places are kept within 0 to 9', (MakeNumberFormat(12, False, False).DecimalPlaces = 9) and
    (MakeNumberFormat(-1, False, False).DecimalPlaces = 0));
  Check('clamped to the maximum', ClampValue(120, 0, 100) = 100);
  Check('clamped to the minimum', ClampValue(-5, 0, 100) = 0);
  Check('a step up by 0.25', Abs(StepValue(1, 0.25, 1, 0, 10, Format) - 1.25) < 1E-9);
  Check('ten steps down stop at the minimum', StepValue(3, 1, -10, 0, 10, Format) = 0);
  Check('a step up stops at the maximum', StepValue(9.5, 1, 1, 0, 10, Format) = 10);
  Check('shown with two places', FormatNumber(3.5, Format) = '3.50');
  Check('shown below one', FormatNumber(0.05, Format) = '0.05');
  Check('negative shown', FormatNumber(-0.5, Format) = '-0.50');
  Check('thousands separated', FormatNumber(1234567.891, MakeNumberFormat(2, False, True)) = '1,234,567.89');
  Check('no separator below a thousand', FormatNumber(999, MakeNumberFormat(0, False, True)) = '999');
  Check('a thousand exactly', FormatNumber(-1000, MakeNumberFormat(0, False, True)) = '-1,000');
  Check('hexadecimal', FormatNumber(255, MakeNumberFormat(2, True, False)) = 'FF');
  Check('hexadecimal zero', FormatNumber(0, MakeNumberFormat(0, True, False)) = '0');
  Check('read with a thousands separator', TryParseNumber(' 1,234.5 ', Format, Value) and (Value = 1234.5));
  Check('read negative', TryParseNumber('-12', Format, Value) and (Value = -12));
  Check('not a number', not TryParseNumber('12a', Format, Value));
  Check('nothing is not a number', not TryParseNumber('', Format, Value));
  Check('two points are not a number', not TryParseNumber('1.2.3', Format, Value));
  Check('hexadecimal read with 0x', TryParseNumber('0x1F', MakeNumberFormat(0, True, False), Value) and (Value = 31));
  Check('hexadecimal read with $', TryParseNumber('$ff', MakeNumberFormat(0, True, False), Value) and (Value = 255));
  Check('hexadecimal not read as decimal', not TryParseNumber('1F', Format, Value));
  Check('number characters: digits and the point with places',
    IsNumberCharacter(Ord('7'), Format) and IsNumberCharacter(Ord('.'), Format) and
    not IsNumberCharacter(Ord('.'), MakeNumberFormat(0, False, False)) and not IsNumberCharacter(Ord('x'), Format));
  Check('number characters: hexadecimal digits', IsNumberCharacter(Ord('c'), MakeNumberFormat(0, True, False)) and
    not IsNumberCharacter(Ord('g'), MakeNumberFormat(0, True, False)));
end;

begin
  TestLeapYearsAndMonths;
  TestDayNumbers;
  TestMovingDates;
  TestIsoWeeks;
  TestMonthGrid;
  TestIsoText;
  TestCalendarLayout;
  TestPatterns;
  TestStepping;
  TestTyping;
  TestNumbers;
  WriteLn('[date] ', Checks - Failures, ' passed, ', Failures, ' failed');
  if Failures > 0 then
    Halt(1);
end.
