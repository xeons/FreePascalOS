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
  Date and time formats: a pattern split into the fields a date and
  time picker shows and edits one at a time, with nothing of the screen
  in it (it builds for the host too, and is checked there).

  A pattern is made of letters that stand for parts and of anything
  else, shown as it is (text in single quotes is shown as it is too;
  '' is a quote):

    d dd        the day (dd: two digits)
    ddd dddd    the day of the week (Mon; Monday), shown, not edited
    M MM        the month as a number (MM: two digits)
    MMM MMMM    the month's name (Nov; November)
    yy yyyy     the year (two digits; four; a single y is four)
    H HH        the hour, 0 to 23
    h hh        the hour, 1 to 12, with tt
    m mm        the minute
    s ss        the second
    t tt        AM or PM

  Each editable field steps up and down (wrapping around within its
  range: the day within the month, the month within the year), takes
  typed digits (FieldTyping), and keeps the day within the month when
  the month or the year changes.
}
unit Controls.DateFormats;

{$mode objfpc}
{$H+}

interface

uses
  Controls.CalendarDates;

type
  TDateTimeFieldKind = (FieldLiteral, FieldDay, FieldWeekdayAbbreviation, FieldWeekdayName, FieldMonthNumber,
    FieldMonthAbbreviation, FieldMonthName, FieldShortYear, FieldYear, FieldHour24, FieldHour12, FieldMinute,
    FieldSecond, FieldDayPeriod);

  TDateTimeField = record
    Kind: TDateTimeFieldKind;
    { Two digits always (dd, MM, HH, hh, mm, ss). }
    Padded: Boolean;
    { What a literal shows. }
    Literal: string;
  end;

  TDateTimeFields = array of TDateTimeField;

  TDateTimeParts = record
    Date: TCalendarDate;
    Hour: LongInt;
    Minute: LongInt;
    Second: LongInt;
  end;

  { Digits typed into one field so far. }
  TFieldTyping = record
    Number: LongInt;
    Digits: LongInt;
  end;

const
  ShortDatePattern = 'yyyy-MM-dd';
  LongDatePattern = 'dddd, d MMMM yyyy';
  ShortTimePattern = 'HH:mm';
  LongTimePattern = 'HH:mm:ss';
  MinimumYear = 1;
  MaximumYear = 9999;

function MakeDateTimeParts(Year, Month, Day, Hour, Minute, Second: LongInt): TDateTimeParts;
function ParseDateTimePattern(const Pattern: string): TDateTimeFields;
function FieldText(const Field: TDateTimeField; const Parts: TDateTimeParts): string;
function FormatDateTimeParts(const Fields: TDateTimeFields; const Parts: TDateTimeParts): string;
{ Fields that take keys: not literals, not the day of the week. }
function FieldIsEditable(Kind: TDateTimeFieldKind): Boolean;
function FieldIsDate(Kind: TDateTimeFieldKind): Boolean;
function FieldIsTime(Kind: TDateTimeFieldKind): Boolean;
{ The number a field shows (the month for its names, 0 or 1 for AM and
  PM), and the range it goes over. }
function FieldNumber(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind): LongInt;
procedure FieldRange(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; out Minimum, Maximum: LongInt);
{ Parts with the field set to Number (kept within its range; the day
  kept within the month). }
function SetFieldNumber(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; Number: LongInt): TDateTimeParts;
{ Parts with the field moved Steps up (down if negative), wrapping
  around (the year stops at its limits). }
function StepField(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; Steps: LongInt): TDateTimeParts;
{ How many digits the field takes at most (0: none, AM and PM). }
function FieldDigitCount(Kind: TDateTimeFieldKind): LongInt;
procedure StartFieldTyping(out Typing: TFieldTyping);
{ Digit (0 to 9) typed into the field: the parts with what has been
  typed so far; Complete when the field can take no more digits (the
  picker moves on to the next field). }
function TypeFieldDigit(var Typing: TFieldTyping; const Parts: TDateTimeParts; Kind: TDateTimeFieldKind;
  Digit: LongInt; out Complete: Boolean): TDateTimeParts;
{ The typing in a field is over: a year of one or two digits typed is
  this century's. }
function FinishFieldTyping(const Typing: TFieldTyping; const Parts: TDateTimeParts;
  Kind: TDateTimeFieldKind): TDateTimeParts;
function CompareDateTimeParts(const First, Second: TDateTimeParts): LongInt;

implementation

function MakeDateTimeParts(Year, Month, Day, Hour, Minute, Second: LongInt): TDateTimeParts;
begin
  Result.Date := MakeCalendarDate(Year, Month, Day);
  Result.Hour := Hour;
  Result.Minute := Minute;
  Result.Second := Second;
end;

procedure AddField(var Fields: TDateTimeFields; Kind: TDateTimeFieldKind; Padded: Boolean; const Literal: string);
var
  Count: LongInt;
begin
  Count := Length(Fields);
  { Literals one after another make one. }
  if (Kind = FieldLiteral) and (Count > 0) and (Fields[Count - 1].Kind = FieldLiteral) then
  begin
    Fields[Count - 1].Literal := Fields[Count - 1].Literal + Literal;
    Exit;
  end;
  SetLength(Fields, Count + 1);
  Fields[Count].Kind := Kind;
  Fields[Count].Padded := Padded;
  Fields[Count].Literal := Literal;
end;

procedure AddLetterField(var Fields: TDateTimeFields; Letter: Char; Count: LongInt);
begin
  case Letter of
    'd':
      case Count of
        1: AddField(Fields, FieldDay, False, '');
        2: AddField(Fields, FieldDay, True, '');
        3: AddField(Fields, FieldWeekdayAbbreviation, False, '');
      else
        AddField(Fields, FieldWeekdayName, False, '');
      end;
    'M':
      case Count of
        1: AddField(Fields, FieldMonthNumber, False, '');
        2: AddField(Fields, FieldMonthNumber, True, '');
        3: AddField(Fields, FieldMonthAbbreviation, False, '');
      else
        AddField(Fields, FieldMonthName, False, '');
      end;
    'y':
      if Count = 2 then
        AddField(Fields, FieldShortYear, True, '')
      else
        AddField(Fields, FieldYear, True, '');
    'H': AddField(Fields, FieldHour24, Count >= 2, '');
    'h': AddField(Fields, FieldHour12, Count >= 2, '');
    'm': AddField(Fields, FieldMinute, Count >= 2, '');
    's': AddField(Fields, FieldSecond, Count >= 2, '');
    't': AddField(Fields, FieldDayPeriod, False, '');
  end;
end;

function ParseDateTimePattern(const Pattern: string): TDateTimeFields;
var
  Index: LongInt;
  Count: LongInt;
  Letter: Char;
  Quoted: string;
begin
  Result := nil;
  Index := 1;
  while Index <= Length(Pattern) do
  begin
    Letter := Pattern[Index];
    if Letter in ['d', 'M', 'y', 'H', 'h', 'm', 's', 't'] then
    begin
      Count := 0;
      while (Index <= Length(Pattern)) and (Pattern[Index] = Letter) do
      begin
        Inc(Count);
        Inc(Index);
      end;
      AddLetterField(Result, Letter, Count);
    end
    else if Letter = '''' then
    begin
      Inc(Index);
      Quoted := '';
      while Index <= Length(Pattern) do
      begin
        if Pattern[Index] = '''' then
        begin
          { '' within quotes: a quote. }
          if (Index < Length(Pattern)) and (Pattern[Index + 1] = '''') then
          begin
            Quoted := Quoted + '''';
            Inc(Index, 2);
            Continue;
          end;
          Inc(Index);
          Break;
        end;
        Quoted := Quoted + Pattern[Index];
        Inc(Index);
      end;
      if Quoted = '' then
        Quoted := '''';
      AddField(Result, FieldLiteral, False, Quoted);
    end
    else
    begin
      AddField(Result, FieldLiteral, False, Letter);
      Inc(Index);
    end;
  end;
end;

function NumberText(Value: LongInt; Width: LongInt): string;
begin
  Str(Value, Result);
  while Length(Result) < Width do
    Result := '0' + Result;
end;

function TwelveHour(Hour: LongInt): LongInt;
begin
  Result := Hour mod 12;
  if Result = 0 then
    Result := 12;
end;

function FieldText(const Field: TDateTimeField; const Parts: TDateTimeParts): string;
var
  Width: LongInt;
begin
  Width := 1;
  if Field.Padded then
    Width := 2;
  case Field.Kind of
    FieldLiteral: Result := Field.Literal;
    FieldDay: Result := NumberText(Parts.Date.Day, Width);
    FieldWeekdayAbbreviation: Result := Copy(DayNames[DayOfWeekOf(Parts.Date)], 1, 3);
    FieldWeekdayName: Result := DayNames[DayOfWeekOf(Parts.Date)];
    FieldMonthNumber: Result := NumberText(Parts.Date.Month, Width);
    FieldMonthAbbreviation: Result := Copy(MonthNames[Parts.Date.Month], 1, 3);
    FieldMonthName: Result := MonthNames[Parts.Date.Month];
    FieldShortYear: Result := NumberText(Parts.Date.Year mod 100, 2);
    FieldYear: Result := NumberText(Parts.Date.Year, 4);
    FieldHour24: Result := NumberText(Parts.Hour, Width);
    FieldHour12: Result := NumberText(TwelveHour(Parts.Hour), Width);
    FieldMinute: Result := NumberText(Parts.Minute, Width);
    FieldSecond: Result := NumberText(Parts.Second, Width);
    FieldDayPeriod:
      if Parts.Hour < 12 then
        Result := 'AM'
      else
        Result := 'PM';
  else
    Result := '';
  end;
end;

function FormatDateTimeParts(const Fields: TDateTimeFields; const Parts: TDateTimeParts): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to High(Fields) do
    Result := Result + FieldText(Fields[Index], Parts);
end;

function FieldIsEditable(Kind: TDateTimeFieldKind): Boolean;
begin
  Result := not (Kind in [FieldLiteral, FieldWeekdayAbbreviation, FieldWeekdayName]);
end;

function FieldIsDate(Kind: TDateTimeFieldKind): Boolean;
begin
  Result := Kind in [FieldDay, FieldWeekdayAbbreviation, FieldWeekdayName, FieldMonthNumber, FieldMonthAbbreviation,
    FieldMonthName, FieldShortYear, FieldYear];
end;

function FieldIsTime(Kind: TDateTimeFieldKind): Boolean;
begin
  Result := Kind in [FieldHour24, FieldHour12, FieldMinute, FieldSecond, FieldDayPeriod];
end;

function FieldNumber(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind): LongInt;
begin
  case Kind of
    FieldDay: Result := Parts.Date.Day;
    FieldMonthNumber, FieldMonthAbbreviation, FieldMonthName: Result := Parts.Date.Month;
    FieldShortYear, FieldYear: Result := Parts.Date.Year;
    FieldHour24: Result := Parts.Hour;
    FieldHour12: Result := TwelveHour(Parts.Hour);
    FieldMinute: Result := Parts.Minute;
    FieldSecond: Result := Parts.Second;
    FieldDayPeriod: Result := Parts.Hour div 12;
  else
    Result := 0;
  end;
end;

procedure FieldRange(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; out Minimum, Maximum: LongInt);
begin
  Minimum := 0;
  Maximum := 0;
  case Kind of
    FieldDay:
      begin
        Minimum := 1;
        Maximum := DaysInMonthOf(Parts.Date.Year, Parts.Date.Month);
      end;
    FieldMonthNumber, FieldMonthAbbreviation, FieldMonthName:
      begin
        Minimum := 1;
        Maximum := 12;
      end;
    FieldShortYear, FieldYear:
      begin
        Minimum := MinimumYear;
        Maximum := MaximumYear;
      end;
    FieldHour24: Maximum := 23;
    FieldHour12:
      begin
        Minimum := 1;
        Maximum := 12;
      end;
    FieldMinute, FieldSecond: Maximum := 59;
    FieldDayPeriod: Maximum := 1;
  end;
end;

{ The day kept within its month. }
procedure KeepDayInMonth(var Parts: TDateTimeParts);
var
  Length: LongInt;
begin
  Length := DaysInMonthOf(Parts.Date.Year, Parts.Date.Month);
  if Parts.Date.Day > Length then
    Parts.Date.Day := Length;
  if Parts.Date.Day < 1 then
    Parts.Date.Day := 1;
end;

function SetFieldNumber(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; Number: LongInt): TDateTimeParts;
var
  Minimum: LongInt;
  Maximum: LongInt;
begin
  Result := Parts;
  if not FieldIsEditable(Kind) then
    Exit;
  FieldRange(Parts, Kind, Minimum, Maximum);
  { (A day beyond this month's last is its last.) }
  if Number < Minimum then
    Number := Minimum;
  if Number > Maximum then
    Number := Maximum;
  case Kind of
    FieldDay: Result.Date.Day := Number;
    FieldMonthNumber, FieldMonthAbbreviation, FieldMonthName: Result.Date.Month := Number;
    FieldShortYear, FieldYear: Result.Date.Year := Number;
    FieldHour24: Result.Hour := Number;
    FieldHour12: Result.Hour := (Number mod 12) + 12 * (Parts.Hour div 12);
    FieldMinute: Result.Minute := Number;
    FieldSecond: Result.Second := Number;
    FieldDayPeriod: Result.Hour := Parts.Hour mod 12 + 12 * Number;
  end;
  KeepDayInMonth(Result);
end;

function Wrapped(Value, Minimum, Maximum: LongInt): LongInt;
var
  Span: LongInt;
begin
  Span := Maximum - Minimum + 1;
  Result := (Value - Minimum) mod Span;
  if Result < 0 then
    Inc(Result, Span);
  Inc(Result, Minimum);
end;

function StepField(const Parts: TDateTimeParts; Kind: TDateTimeFieldKind; Steps: LongInt): TDateTimeParts;
var
  Minimum: LongInt;
  Maximum: LongInt;
  Number: LongInt;
begin
  Result := Parts;
  if not FieldIsEditable(Kind) then
    Exit;
  FieldRange(Parts, Kind, Minimum, Maximum);
  case Kind of
    FieldShortYear, FieldYear:
      Result := SetFieldNumber(Parts, Kind, Parts.Date.Year + Steps);
    FieldHour12:
      { The hour goes round the whole day, AM into PM. }
      Result.Hour := Wrapped(Parts.Hour + Steps, 0, 23);
    FieldDayPeriod:
      if Odd(Steps) then
        Result.Hour := (Parts.Hour + 12) mod 24;
  else
    begin
      Number := Wrapped(FieldNumber(Parts, Kind) + Steps, Minimum, Maximum);
      Result := SetFieldNumber(Parts, Kind, Number);
    end;
  end;
end;

function FieldDigitCount(Kind: TDateTimeFieldKind): LongInt;
begin
  case Kind of
    FieldYear: Result := 4;
    FieldDay, FieldMonthNumber, FieldMonthAbbreviation, FieldMonthName, FieldShortYear, FieldHour24, FieldHour12,
    FieldMinute, FieldSecond: Result := 2;
  else
    Result := 0;
  end;
end;

procedure StartFieldTyping(out Typing: TFieldTyping);
begin
  Typing.Number := 0;
  Typing.Digits := 0;
end;

{ The largest a field typed digit by digit can become (the day: 31
  whatever the month, kept within it as it is set). }
function TypingMaximum(Kind: TDateTimeFieldKind): LongInt;
begin
  case Kind of
    FieldDay: Result := 31;
    FieldMonthNumber, FieldMonthAbbreviation, FieldMonthName: Result := 12;
    FieldShortYear: Result := 99;
    FieldYear: Result := MaximumYear;
    FieldHour24: Result := 23;
    FieldHour12: Result := 12;
    FieldMinute, FieldSecond: Result := 59;
  else
    Result := 0;
  end;
end;

function TypedValue(const Typing: TFieldTyping; const Parts: TDateTimeParts; Kind: TDateTimeFieldKind;
  Finished: Boolean): TDateTimeParts;
var
  Number: LongInt;
begin
  Number := Typing.Number;
  case Kind of
    FieldShortYear:
      Number := (Parts.Date.Year div 100) * 100 + Number;
    FieldYear:
      if Finished and (Typing.Digits <= 2) then
        Number := 2000 + Number;
  end;
  { A lone 0 typed so far (on the way to 05) leaves the field as it was
    until the next digit, as 0 is not a day or a month. }
  if (Number = 0) and not (Kind in [FieldHour24, FieldMinute, FieldSecond]) then
    Exit(Parts);
  Result := SetFieldNumber(Parts, Kind, Number);
end;

function TypeFieldDigit(var Typing: TFieldTyping; const Parts: TDateTimeParts; Kind: TDateTimeFieldKind;
  Digit: LongInt; out Complete: Boolean): TDateTimeParts;
var
  Maximum: LongInt;
begin
  Complete := False;
  Result := Parts;
  if FieldDigitCount(Kind) = 0 then
    Exit;
  Maximum := TypingMaximum(Kind);
  { A digit that would go beyond the field starts it again. }
  if Typing.Number * 10 + Digit > Maximum then
    StartFieldTyping(Typing);
  Typing.Number := Typing.Number * 10 + Digit;
  Inc(Typing.Digits);
  Complete := (Typing.Digits >= FieldDigitCount(Kind)) or (Typing.Number * 10 > Maximum);
  Result := TypedValue(Typing, Parts, Kind, Complete);
end;

function FinishFieldTyping(const Typing: TFieldTyping; const Parts: TDateTimeParts;
  Kind: TDateTimeFieldKind): TDateTimeParts;
begin
  if (Typing.Digits = 0) or (Kind <> FieldYear) then
    Exit(Parts);
  Result := TypedValue(Typing, Parts, Kind, True);
end;

function CompareDateTimeParts(const First, Second: TDateTimeParts): LongInt;
begin
  Result := CompareDates(First.Date, Second.Date);
  if Result = 0 then
    Result := First.Hour - Second.Hour;
  if Result = 0 then
    Result := First.Minute - Second.Minute;
  if Result = 0 then
    Result := First.Second - Second.Second;
end;

end.
