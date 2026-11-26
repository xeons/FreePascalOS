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
  The values of the number, range, date and time input types (HTML
  Standard 2.3.4, 2.3.5 and 4.10.5.1): the microsyntaxes (valid
  floating-point numbers, month, date, week, time and local date and
  time strings), each type's conversion between its value and a number
  (valueAsNumber: milliseconds since the epoch for date, week and
  datetime-local, since midnight for time, months since January 1970
  for month) and back, the value sanitization algorithms (an invalid
  value becomes empty; a range is clamped to its minimum and maximum
  and rounded to its step, its default the middle), and the steps
  (default step, step scale factor, step base) stepUp and stepDown use.
  Dates are proleptic Gregorian, years from 1 on with four or more
  digits.
}
unit Web.Dom.InputValues;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Math, Web.Dom;

const
  MillisecondsPerDay = 86400000;

type
  TInputStep = record
    { False: step="any" (no allowed value step). }
    Allowed: Boolean;
    { In the type's numbers (scale factor applied). }
    Step: Double;
    Base: Double;
  end;

{ A valid floating-point number (no white space, no leading +). }
function ParseFloatingPointNumber(const Text: string; out Value: Double): Boolean;
{ The best representation of Value as a floating-point number (as
  JavaScript's Number to string). }
function FloatingPointNumberText(Value: Double): string;

{ Whether the type has a numeric value (number, range, the date and time
  types). }
function IsNumericInputType(const TypeName: string): Boolean;
{ Whether the type's text, as the user types it, may sanitize to less
  (number and the date and time types): the user's edit is kept apart. }
function IsSanitizedEditType(const TypeName: string): Boolean;
{ The date types whose valueAsDate applies (date, month, week, time). }
function HasDateValue(const TypeName: string): Boolean;

{ The type's value as a number; False when it does not convert. }
function InputValueToNumber(const TypeName, Value: string; out Number: Double): Boolean;
{ The value a number gives for the type ('' when it has none). }
function NumberToInputValue(const TypeName: string; Number: Double): string;
{ valueAsDate's time value for the type (False: null). }
function InputValueToDateTime(const TypeName, Value: string; out Milliseconds: Double): Boolean;
function DateTimeToInputValue(const TypeName: string; Milliseconds: Double): string;

{ The value sanitization algorithm for Input of type TypeName. }
function SanitizeNumericValue(Input: TElement; const TypeName, Value: string): string;

{ min and max as numbers (False when absent or invalid). }
function InputMinimum(Input: TElement; const TypeName: string; out Value: Double): Boolean;
function InputMaximum(Input: TElement; const TypeName: string; out Value: Double): Boolean;
function InputAllowedStep(Input: TElement; const TypeName: string): TInputStep;

implementation

uses
  Web.Atoms;

const
  DefaultRangeMinimum = 0;
  DefaultRangeMaximum = 100;
  { The default step base of week: Monday 1969-12-29. }
  DefaultWeekStepBase = -259200000;

function IsDigit(Character: Char): Boolean; inline;
begin
  Result := (Character >= '0') and (Character <= '9');
end;

function ParseFloatingPointNumber(const Text: string; out Value: Double): Boolean;
var
  Index, DigitsBefore, DigitsAfter, ExponentDigits: Integer;
  Settings: TFormatSettings;
begin
  Value := 0;
  Index := 1;
  if (Index <= Length(Text)) and (Text[Index] = '-') then
    Inc(Index);
  DigitsBefore := 0;
  while (Index <= Length(Text)) and IsDigit(Text[Index]) do
  begin
    Inc(DigitsBefore);
    Inc(Index);
  end;
  DigitsAfter := 0;
  if (Index <= Length(Text)) and (Text[Index] = '.') then
  begin
    Inc(Index);
    while (Index <= Length(Text)) and IsDigit(Text[Index]) do
    begin
      Inc(DigitsAfter);
      Inc(Index);
    end;
    if DigitsAfter = 0 then
      Exit(False);
  end;
  if DigitsBefore + DigitsAfter = 0 then
    Exit(False);
  if (Index <= Length(Text)) and (Text[Index] in ['e', 'E']) then
  begin
    Inc(Index);
    if (Index <= Length(Text)) and (Text[Index] in ['-', '+']) then
      Inc(Index);
    ExponentDigits := 0;
    while (Index <= Length(Text)) and IsDigit(Text[Index]) do
    begin
      Inc(ExponentDigits);
      Inc(Index);
    end;
    if ExponentDigits = 0 then
      Exit(False);
  end;
  if Index <= Length(Text) then
    Exit(False);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  if not TryStrToFloat(Text, Value, Settings) then
    Exit(False);
  Result := not IsInfinite(Value) and not IsNan(Value);
  if Value = 0 then
    Value := 0;
end;

function FloatingPointNumberText(Value: Double): string;
var
  Settings: TFormatSettings;
  Precision: Integer;
  Back: Double;
begin
  if IsNan(Value) then
    Exit('NaN');
  if Value = 0 then
    Exit('0');
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  if (Abs(Value) < 1E15) and (Frac(Value) = 0) then
    Exit(IntToStr(Trunc(Value)));
  Result := '';
  for Precision := 1 to 17 do
  begin
    Result := FloatToStrF(Value, ffGeneral, Precision, 0, Settings);
    if TryStrToFloat(Result, Back, Settings) and (Back = Value) then
      Break;
  end;
  { ffGeneral writes 1E-7 style exponents: JavaScript writes 1e-7. }
  Result := LowerCase(Result);
  Result := StringReplace(Result, 'e+', 'e+', []);
  if (Pos('e', Result) > 0) and (Pos('e-', Result) = 0) and (Pos('e+', Result) = 0) then
    Result := StringReplace(Result, 'e', 'e+', []);
end;

function IsNumericInputType(const TypeName: string): Boolean;
begin
  Result := (TypeName = 'number') or (TypeName = 'range') or (TypeName = 'date') or (TypeName = 'month') or
    (TypeName = 'week') or (TypeName = 'time') or (TypeName = 'datetime-local');
end;

function IsSanitizedEditType(const TypeName: string): Boolean;
begin
  Result := IsNumericInputType(TypeName) and (TypeName <> 'range');
end;

function HasDateValue(const TypeName: string): Boolean;
begin
  Result := (TypeName = 'date') or (TypeName = 'month') or (TypeName = 'week') or (TypeName = 'time');
end;

{ ---- the calendar ---- }

function IsLeapYear(Year: Int64): Boolean;
begin
  Result := ((Year mod 4 = 0) and (Year mod 100 <> 0)) or (Year mod 400 = 0);
end;

function DaysInMonth(Year: Int64; Month: Integer): Integer;
const
  Days: array[1..12] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  Result := Days[Month];
  if (Month = 2) and IsLeapYear(Year) then
    Result := 29;
end;

{ Days since 1970-01-01 of a proleptic Gregorian date. }
function DaysFromCivil(Year: Int64; Month, Day: Integer): Int64;
var
  Era, YearOfEra, DayOfYear, DayOfEra, ShiftedMonth: Int64;
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
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

procedure CivilFromDays(Days: Int64; out Year: Int64; out Month, Day: Integer);
var
  Era, DayOfEra, YearOfEra, DayOfYear, ShiftedMonth: Int64;
begin
  Days := Days + 719468;
  if Days >= 0 then
    Era := Days div 146097
  else
    Era := (Days - 146096) div 146097;
  DayOfEra := Days - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  Year := YearOfEra + Era * 400;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  ShiftedMonth := (5 * DayOfYear + 2) div 153;
  Day := DayOfYear - (153 * ShiftedMonth + 2) div 5 + 1;
  if ShiftedMonth < 10 then
    Month := ShiftedMonth + 3
  else
    Month := ShiftedMonth - 9;
  if Month <= 2 then
    Inc(Year);
end;

{ Monday is 0. }
function WeekdayOf(Days: Int64): Integer;
begin
  { 1970-01-01 was a Thursday (3). }
  Result := (Days mod 7 + 7 + 3) mod 7;
end;

function WeeksInYear(Year: Int64): Integer;
var
  JanuaryFirst: Integer;
begin
  JanuaryFirst := WeekdayOf(DaysFromCivil(Year, 1, 1));
  if (JanuaryFirst = 3) or ((JanuaryFirst = 2) and IsLeapYear(Year)) then
    Result := 53
  else
    Result := 52;
end;

{ Days since the epoch of the Monday of the year's week 1 (the week with
  its Thursday). }
function FirstWeekMonday(Year: Int64): Int64;
var
  JanuaryFourth: Int64;
begin
  JanuaryFourth := DaysFromCivil(Year, 1, 4);
  Result := JanuaryFourth - WeekdayOf(JanuaryFourth);
end;

{ ---- the microsyntaxes ---- }

{ Count digits at Index (moved past them) into Value. }
function TakeDigits(const Text: string; var Index: Integer; Count: Integer; out Value: Int64): Boolean;
var
  Taken: Integer;
begin
  Value := 0;
  Taken := 0;
  while (Index <= Length(Text)) and IsDigit(Text[Index]) and ((Count < 0) or (Taken < Count)) do
  begin
    if Value < 100000000000 then
      Value := Value * 10 + Ord(Text[Index]) - Ord('0');
    Inc(Index);
    Inc(Taken);
  end;
  if Count < 0 then
    Result := Taken >= 4
  else
    Result := Taken = Count;
end;

function TakeCharacter(const Text: string; var Index: Integer; Character: Char): Boolean;
begin
  Result := (Index <= Length(Text)) and (Text[Index] = Character);
  if Result then
    Inc(Index);
end;

function ParseMonthComponent(const Text: string; var Index: Integer; out Year: Int64; out Month: Integer): Boolean;
var
  Value: Int64;
begin
  Month := 0;
  Result := TakeDigits(Text, Index, -1, Year) and (Year > 0) and TakeCharacter(Text, Index, '-') and
    TakeDigits(Text, Index, 2, Value) and (Value >= 1) and (Value <= 12);
  if Result then
    Month := Value;
end;

function ParseDateComponent(const Text: string; var Index: Integer; out Days: Int64): Boolean;
var
  Year, Value: Int64;
  Month: Integer;
begin
  Days := 0;
  Result := ParseMonthComponent(Text, Index, Year, Month) and TakeCharacter(Text, Index, '-') and
    TakeDigits(Text, Index, 2, Value) and (Value >= 1) and (Value <= DaysInMonth(Year, Month));
  if Result then
    Days := DaysFromCivil(Year, Month, Value);
end;

function ParseTimeComponent(const Text: string; var Index: Integer; out Milliseconds: Double): Boolean;
var
  Hours, Minutes, Seconds, Fraction: Int64;
  FractionDigits: Integer;
begin
  Milliseconds := 0;
  if not (TakeDigits(Text, Index, 2, Hours) and (Hours <= 23) and TakeCharacter(Text, Index, ':') and
    TakeDigits(Text, Index, 2, Minutes) and (Minutes <= 59)) then
    Exit(False);
  Seconds := 0;
  Fraction := 0;
  if TakeCharacter(Text, Index, ':') then
  begin
    if not (TakeDigits(Text, Index, 2, Seconds) and (Seconds <= 59)) then
      Exit(False);
    if TakeCharacter(Text, Index, '.') then
    begin
      FractionDigits := 0;
      while (Index <= Length(Text)) and IsDigit(Text[Index]) and (FractionDigits < 3) do
      begin
        Fraction := Fraction * 10 + Ord(Text[Index]) - Ord('0');
        Inc(FractionDigits);
        Inc(Index);
      end;
      if FractionDigits = 0 then
        Exit(False);
      while FractionDigits < 3 do
      begin
        Fraction := Fraction * 10;
        Inc(FractionDigits);
      end;
    end;
  end;
  Milliseconds := ((Hours * 60 + Minutes) * 60 + Seconds) * 1000 + Fraction;
  Result := True;
end;

function ParseWhole(const TypeName, Text: string; out Number: Double): Boolean;
var
  Index: Integer;
  Year, Week, Days: Int64;
  Month: Integer;
  Time: Double;
begin
  Number := 0;
  Index := 1;
  if TypeName = 'date' then
  begin
    Result := ParseDateComponent(Text, Index, Days);
    Number := Days * Double(MillisecondsPerDay);
  end
  else if TypeName = 'month' then
  begin
    Result := ParseMonthComponent(Text, Index, Year, Month);
    Number := (Year - 1970) * 12 + Month - 1;
  end
  else if TypeName = 'week' then
  begin
    Result := TakeDigits(Text, Index, -1, Year) and (Year > 0) and TakeCharacter(Text, Index, '-') and
      TakeCharacter(Text, Index, 'W') and TakeDigits(Text, Index, 2, Week) and (Week >= 1) and
      (Week <= WeeksInYear(Year));
    if Result then
      Number := (FirstWeekMonday(Year) + (Week - 1) * 7) * Double(MillisecondsPerDay);
  end
  else if TypeName = 'time' then
  begin
    Result := ParseTimeComponent(Text, Index, Time);
    Number := Time;
  end
  else if TypeName = 'datetime-local' then
  begin
    Result := ParseDateComponent(Text, Index, Days) and (TakeCharacter(Text, Index, 'T') or
      TakeCharacter(Text, Index, ' ')) and ParseTimeComponent(Text, Index, Time);
    Number := Days * Double(MillisecondsPerDay) + Time;
  end
  else
    Exit(ParseFloatingPointNumber(Text, Number));
  Result := Result and (Index > Length(Text));
end;

function InputValueToNumber(const TypeName, Value: string; out Number: Double): Boolean;
begin
  Result := ParseWhole(TypeName, Value, Number);
end;

function Pad(Value: Int64; Width: Integer): string;
begin
  Result := IntToStr(Value);
  while Length(Result) < Width do
    Result := '0' + Result;
end;

function FloorDiv(Value, Divisor: Double): Double;
begin
  Result := Floor(Value / Divisor);
end;

{ The shortest valid time string of a time of day. }
function TimeText(Milliseconds: Int64): string;
var
  Hours, Minutes, Seconds, Fraction: Int64;
begin
  Fraction := Milliseconds mod 1000;
  Seconds := (Milliseconds div 1000) mod 60;
  Minutes := (Milliseconds div 60000) mod 60;
  Hours := Milliseconds div 3600000;
  Result := Pad(Hours, 2) + ':' + Pad(Minutes, 2);
  if (Seconds <> 0) or (Fraction <> 0) then
    Result := Result + ':' + Pad(Seconds, 2);
  if Fraction <> 0 then
  begin
    Result := Result + '.' + Pad(Fraction, 3);
    while Result[Length(Result)] = '0' do
      SetLength(Result, Length(Result) - 1);
  end;
end;

function DateText(Days: Int64): string;
var
  Year: Int64;
  Month, Day: Integer;
begin
  CivilFromDays(Days, Year, Month, Day);
  if Year < 1 then
    Exit('');
  Result := Pad(Year, 4) + '-' + Pad(Month, 2) + '-' + Pad(Day, 2);
end;

function NumberToInputValue(const TypeName: string; Number: Double): string;
var
  Days, Year, Week, Milliseconds: Int64;
  Month, Day: Integer;
  Months: Int64;
begin
  Result := '';
  if IsNan(Number) or IsInfinite(Number) then
    Exit;
  if TypeName = 'date' then
    Result := DateText(Trunc(FloorDiv(Number, MillisecondsPerDay)))
  else if TypeName = 'month' then
  begin
    Months := Trunc(Floor(Number));
    Year := 1970 + Trunc(Floor(Months / 12));
    Month := Months - (Year - 1970) * 12 + 1;
    if Year >= 1 then
      Result := Pad(Year, 4) + '-' + Pad(Month, 2);
  end
  else if TypeName = 'week' then
  begin
    Days := Trunc(FloorDiv(Number, MillisecondsPerDay));
    { The Thursday of the week decides its year. }
    Days := Days - WeekdayOf(Days) + 3;
    CivilFromDays(Days, Year, Month, Day);
    if Year < 1 then
      Exit;
    Week := (Days - 3 - FirstWeekMonday(Year)) div 7 + 1;
    Result := Pad(Year, 4) + '-W' + Pad(Week, 2);
  end
  else if TypeName = 'time' then
  begin
    Milliseconds := Trunc(Number - FloorDiv(Number, MillisecondsPerDay) * MillisecondsPerDay);
    Result := TimeText(Milliseconds);
  end
  else if TypeName = 'datetime-local' then
  begin
    Days := Trunc(FloorDiv(Number, MillisecondsPerDay));
    Milliseconds := Trunc(Number - Days * Double(MillisecondsPerDay));
    Result := DateText(Days);
    if Result <> '' then
      Result := Result + 'T' + TimeText(Milliseconds);
  end
  else
    Result := FloatingPointNumberText(Number);
end;

function InputValueToDateTime(const TypeName, Value: string; out Milliseconds: Double): Boolean;
var
  Months: Double;
  Year: Int64;
  Month: Integer;
begin
  Milliseconds := 0;
  if not HasDateValue(TypeName) or not ParseWhole(TypeName, Value, Milliseconds) then
    Exit(False);
  if TypeName = 'month' then
  begin
    Months := Milliseconds;
    Year := 1970 + Trunc(Floor(Months / 12));
    Month := Trunc(Months) - (Year - 1970) * 12 + 1;
    Milliseconds := DaysFromCivil(Year, Month, 1) * Double(MillisecondsPerDay);
  end;
  Result := True;
end;

function DateTimeToInputValue(const TypeName: string; Milliseconds: Double): string;
var
  Year: Int64;
  Month, Day: Integer;
begin
  if IsNan(Milliseconds) or IsInfinite(Milliseconds) then
    Exit('');
  if TypeName = 'month' then
  begin
    CivilFromDays(Trunc(FloorDiv(Milliseconds, MillisecondsPerDay)), Year, Month, Day);
    Exit(NumberToInputValue('month', (Year - 1970) * 12 + Month - 1));
  end;
  Result := NumberToInputValue(TypeName, Milliseconds);
end;

{ ---- minimum, maximum and step ---- }

function AttributeNumber(Input: TElement; Attribute: LongWord; const TypeName: string; out Value: Double): Boolean;
begin
  Value := 0;
  Result := Input.HasAttributeAtom(Attribute) and ParseWhole(TypeName, Input.AttributeValueOf(Attribute), Value);
end;

function InputMinimum(Input: TElement; const TypeName: string; out Value: Double): Boolean;
begin
  Result := AttributeNumber(Input, AtomMin, TypeName, Value);
  if not Result and (TypeName = 'range') then
  begin
    Value := DefaultRangeMinimum;
    Result := True;
  end;
end;

function InputMaximum(Input: TElement; const TypeName: string; out Value: Double): Boolean;
var
  Minimum: Double;
begin
  Result := AttributeNumber(Input, AtomMax, TypeName, Value);
  if not Result and (TypeName = 'range') then
  begin
    Value := DefaultRangeMaximum;
    Result := True;
  end;
  { A range whose maximum is below its minimum has its minimum as maximum. }
  if (TypeName = 'range') and InputMinimum(Input, TypeName, Minimum) and (Value < Minimum) then
    Value := Minimum;
end;

procedure StepDefaults(const TypeName: string; out DefaultStep, ScaleFactor: Double);
begin
  DefaultStep := 1;
  ScaleFactor := 1;
  if TypeName = 'date' then
    ScaleFactor := MillisecondsPerDay
  else if TypeName = 'week' then
    ScaleFactor := 7 * Double(MillisecondsPerDay)
  else if (TypeName = 'time') or (TypeName = 'datetime-local') then
  begin
    DefaultStep := 60;
    ScaleFactor := 1000;
  end;
end;

function InputAllowedStep(Input: TElement; const TypeName: string): TInputStep;
var
  DefaultStep, ScaleFactor, Parsed: Double;
  Text: string;
begin
  StepDefaults(TypeName, DefaultStep, ScaleFactor);
  Result.Allowed := True;
  Result.Step := DefaultStep * ScaleFactor;
  if Input.HasAttributeAtom(AtomStep) then
  begin
    Text := Input.AttributeValueOf(AtomStep);
    if LowerCase(Trim(Text)) = 'any' then
      Result.Allowed := False
    else if ParseFloatingPointNumber(Trim(Text), Parsed) and (Parsed > 0) then
    begin
      Result.Step := Parsed * ScaleFactor;
      { Whole days, weeks and months for those types. }
      if (TypeName = 'date') or (TypeName = 'week') or (TypeName = 'month') then
        Result.Step := Max(ScaleFactor, Round(Parsed) * ScaleFactor);
    end;
  end;
  if AttributeNumber(Input, AtomMin, TypeName, Parsed) then
    Result.Base := Parsed
  else if AttributeNumber(Input, AtomValue, TypeName, Parsed) then
    Result.Base := Parsed
  else if TypeName = 'week' then
    Result.Base := DefaultWeekStepBase
  else
    Result.Base := 0;
end;

{ ---- sanitization ---- }

function SanitizeRange(Input: TElement; const Value: string): string;
var
  Number, Minimum, Maximum, Steps, Lower, Upper: Double;
  Step: TInputStep;
begin
  InputMinimum(Input, 'range', Minimum);
  InputMaximum(Input, 'range', Maximum);
  if not ParseFloatingPointNumber(Value, Number) then
    Number := Minimum + (Maximum - Minimum) / 2;
  if Number < Minimum then
    Number := Minimum;
  if Number > Maximum then
    Number := Maximum;
  Step := InputAllowedStep(Input, 'range');
  if Step.Allowed and (Step.Step > 0) then
  begin
    Steps := (Number - Step.Base) / Step.Step;
    if Abs(Steps - Round(Steps)) > 1E-9 then
    begin
      { The nearest value on the step, the higher of two equally near. }
      Lower := Step.Base + Floor(Steps) * Step.Step;
      Upper := Lower + Step.Step;
      if (Upper <= Maximum) and ((Upper - Number <= Number - Lower) or (Lower < Minimum)) then
        Number := Upper
      else if Lower >= Minimum then
        Number := Lower;
    end;
  end;
  Result := FloatingPointNumberText(Number);
end;

function SanitizeNumericValue(Input: TElement; const TypeName, Value: string): string;
var
  Number: Double;
begin
  if TypeName = 'range' then
    Exit(SanitizeRange(Input, Value));
  if not ParseWhole(TypeName, Value, Number) then
    Exit('');
  { A local date and time is normalized (T, the shortest time). }
  if TypeName = 'datetime-local' then
    Exit(NumberToInputValue(TypeName, Number));
  Result := Value;
end;

end.
