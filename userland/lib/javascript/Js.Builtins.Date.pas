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
  Date: time values (milliseconds since 1970 UTC, NaN when invalid)
  with the calendar arithmetic of the specification (proleptic
  Gregorian, no leap seconds), local time through Js.Platform's time
  zone, Date.parse for the ISO format and the formats toString and
  toUTCString produce, and the en-US locale strings.
}
unit Js.Builtins.Date;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Inspect,
  Js.Platform,
  Js.Interpreter;

procedure InstallDate(R: TJsInterpreterRealm);

implementation

const
  MillisecondsPerDay = 86400000.0;
  DayNames: array[0..6] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonthNames: array[0..11] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec');

type
  TJsDate = class(TJsObject)
  public
    Time: Double;
  end;

function NaN_: Double; inline;
begin
  Result := BitsDouble(JsNaN);
end;

{ Calendar arithmetic (ECMA-262 21.4.1) }

function Day(T: Double): Double;
begin
  Result := Floor(T / MillisecondsPerDay);
end;

function TimeWithinDay(T: Double): Double;
begin
  Result := T - Day(T) * MillisecondsPerDay;
end;

function DaysInYear(Year: Double): Integer;
var
  Y: Int64;
begin
  Y := Trunc(Year);
  if (Y mod 4 <> 0) then
    Exit(365);
  if (Y mod 100 <> 0) then
    Exit(366);
  if (Y mod 400 <> 0) then
    Exit(365);
  Result := 366;
end;

function DayFromYear(Year: Double): Double;
begin
  Result := 365 * (Year - 1970) + Floor((Year - 1969) / 4) - Floor((Year - 1901) / 100) + Floor((Year - 1601) / 400);
end;

function TimeFromYear(Year: Double): Double;
begin
  Result := MillisecondsPerDay * DayFromYear(Year);
end;

function YearFromTime(T: Double): Double;
var
  Year: Double;
begin
  Year := Floor(T / (MillisecondsPerDay * 365.2425)) + 1970;
  while TimeFromYear(Year) > T do
    Year := Year - 1;
  while TimeFromYear(Year + 1) <= T do
    Year := Year + 1;
  Result := Year;
end;

function InLeapYear(T: Double): Boolean;
begin
  Result := DaysInYear(YearFromTime(T)) = 366;
end;

function DayWithinYear(T: Double): Integer;
begin
  Result := Trunc(Day(T) - DayFromYear(YearFromTime(T)));
end;

const
  CumulativeDays: array[0..12] of Integer = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365);

function MonthStart(Month: Integer; Leap: Boolean): Integer;
begin
  Result := CumulativeDays[Month];
  if Leap and (Month >= 2) then
    Inc(Result);
end;

function MonthFromTime(T: Double): Integer;
var
  Within: Integer;
  Leap: Boolean;
begin
  Within := DayWithinYear(T);
  Leap := InLeapYear(T);
  Result := 0;
  while (Result < 11) and (Within >= MonthStart(Result + 1, Leap)) do
    Inc(Result);
end;

function DateFromTime(T: Double): Integer;
begin
  Result := DayWithinYear(T) - MonthStart(MonthFromTime(T), InLeapYear(T)) + 1;
end;

function WeekDay(T: Double): Integer;
var
  Value: Int64;
begin
  Value := (Trunc(Day(T)) + 4) mod 7;
  if Value < 0 then
    Inc(Value, 7);
  Result := Value;
end;

function HourFromTime(T: Double): Integer;
begin
  Result := Trunc(TimeWithinDay(T) / 3600000.0) mod 24;
end;

function MinFromTime(T: Double): Integer;
begin
  Result := Trunc(TimeWithinDay(T) / 60000.0) mod 60;
end;

function SecFromTime(T: Double): Integer;
begin
  Result := Trunc(TimeWithinDay(T) / 1000.0) mod 60;
end;

function MsFromTime(T: Double): Integer;
begin
  Result := Trunc(TimeWithinDay(T)) mod 1000;
end;

function MakeTime(Hour, Minute, Second, Millisecond: Double): Double;
begin
  if not (IsFiniteDouble(Hour) and IsFiniteDouble(Minute) and IsFiniteDouble(Second) and IsFiniteDouble(Millisecond)) then
    Exit(NaN_);
  Result := Int(Hour) * 3600000.0 + Int(Minute) * 60000.0 + Int(Second) * 1000.0 + Int(Millisecond);
end;

function MakeDay(Year, Month, Date: Double): Double;
var
  Y, M: Double;
  Leap: Boolean;
  MonthIndex: Integer;
begin
  if not (IsFiniteDouble(Year) and IsFiniteDouble(Month) and IsFiniteDouble(Date)) then
    Exit(NaN_);
  Year := Int(Year);
  Month := Int(Month);
  Date := Int(Date);
  Y := Year + Floor(Month / 12);
  if Abs(Y) > 400000 then
    Exit(NaN_);
  M := Month - Floor(Month / 12) * 12;
  MonthIndex := Trunc(M);
  Leap := DaysInYear(Y) = 366;
  Result := DayFromYear(Y) + MonthStart(MonthIndex, Leap) + Date - 1;
end;

function MakeDate(Day_, Time: Double): Double;
begin
  if not (IsFiniteDouble(Day_) and IsFiniteDouble(Time)) then
    Exit(NaN_);
  Result := Day_ * MillisecondsPerDay + Time;
end;

function TimeClip(Time: Double): Double;
begin
  if not IsFiniteDouble(Time) or (Abs(Time) > 8.64e15) then
    Exit(NaN_);
  Result := Int(Time) + 0;
end;

function LocalOffset(UtcTime: Double): Double;
begin
  Result := JsLocalOffset(UtcTime);
end;

function LocalTime(T: Double): Double;
begin
  Result := T + LocalOffset(T);
end;

function UtcFromLocal(T: Double): Double;
begin
  Result := T - LocalOffset(T - LocalOffset(T));
end;

{ Formatting }

function Pad(Value, Width: Integer): string;
begin
  Result := IntToStr(Abs(Value));
  while Length(Result) < Width do
    Result := '0' + Result;
  if Value < 0 then
    Result := '-' + Result;
end;

function YearText(Year: Double): string;
begin
  if Year < 0 then
    Result := '-' + Pad(Trunc(-Year), 6)
  else
    Result := Pad(Trunc(Year), 4);
end;

function OffsetText(Offset: Double; Colon: Boolean): string;
var
  Minutes: Integer;
  Sign: string;
begin
  Minutes := Round(Offset / 60000.0);
  if Minutes < 0 then
    Sign := '-'
  else
    Sign := '+';
  Minutes := Abs(Minutes);
  if Colon then
    Result := Sign + Pad(Minutes div 60, 2) + ':' + Pad(Minutes mod 60, 2)
  else
    Result := Sign + Pad(Minutes div 60, 2) + Pad(Minutes mod 60, 2);
end;

function DatePart(T: Double): string;
begin
  Result := DayNames[WeekDay(T)] + ' ' + MonthNames[MonthFromTime(T)] + ' ' + Pad(DateFromTime(T), 2) + ' ' +
    YearText(YearFromTime(T));
end;

function TimePart(Utc: Double): string;
var
  T: Double;
begin
  T := LocalTime(Utc);
  Result := Pad(HourFromTime(T), 2) + ':' + Pad(MinFromTime(T), 2) + ':' + Pad(SecFromTime(T), 2) + ' GMT' +
    OffsetText(LocalOffset(Utc), False) + ' (' + JsZoneName(Utc) + ')';
end;

function IsoText(T: Double): string;
var
  Year: Double;
begin
  Year := YearFromTime(T);
  if (Year >= 0) and (Year <= 9999) then
    Result := Pad(Trunc(Year), 4)
  else if Year < 0 then
    Result := '-' + Pad(Trunc(-Year), 6)
  else
    Result := '+' + Pad(Trunc(Year), 6);
  Result := Result + '-' + Pad(MonthFromTime(T) + 1, 2) + '-' + Pad(DateFromTime(T), 2) + 'T' +
    Pad(HourFromTime(T), 2) + ':' + Pad(MinFromTime(T), 2) + ':' + Pad(SecFromTime(T), 2) + '.' +
    Pad(MsFromTime(T), 3) + 'Z';
end;

function UtcText(T: Double): string;
begin
  Result := DayNames[WeekDay(T)] + ', ' + Pad(DateFromTime(T), 2) + ' ' + MonthNames[MonthFromTime(T)] + ' ' +
    YearText(YearFromTime(T)) + ' ' + Pad(HourFromTime(T), 2) + ':' + Pad(MinFromTime(T), 2) + ':' +
    Pad(SecFromTime(T), 2) + ' GMT';
end;

function LocaleDateText(T: Double): string;
begin
  Result := IntToStr(MonthFromTime(T) + 1) + '/' + IntToStr(DateFromTime(T)) + '/' + IntToStr(Trunc(YearFromTime(T)));
end;

function LocaleTimeText(T: Double): string;
var
  Hour: Integer;
  Suffix: string;
begin
  Hour := HourFromTime(T);
  if Hour >= 12 then
    Suffix := 'PM'
  else
    Suffix := 'AM';
  Hour := Hour mod 12;
  if Hour = 0 then
    Hour := 12;
  Result := IntToStr(Hour) + ':' + Pad(MinFromTime(T), 2) + ':' + Pad(SecFromTime(T), 2) + ' ' + Suffix;
end;

{ Parsing }

function ParseIso(const Text: string; out Time: Double): Boolean;
var
  Position: Integer;
  Year, Month, Date, Hour, Minute, Second, Millisecond, OffsetMinutes: Double;
  Sign: Integer;
  HasTime, HasOffset, IsUtc: Boolean;

  function Digits(Count: Integer; out Value: Double): Boolean;
  var
    Index: Integer;
  begin
    Value := 0;
    if Position + Count - 1 > Length(Text) then
      Exit(False);
    for Index := 0 to Count - 1 do
    begin
      if not (Text[Position + Index] in ['0'..'9']) then
        Exit(False);
      Value := Value * 10 + Ord(Text[Position + Index]) - Ord('0');
    end;
    Inc(Position, Count);
    Result := True;
  end;

  function Expect(Character: Char): Boolean;
  begin
    Result := (Position <= Length(Text)) and (Text[Position] = Character);
    if Result then
      Inc(Position);
  end;

var
  Fraction: Double;
  Scale: Double;
  OffsetHours, OffsetPart: Double;
begin
  Result := False;
  Time := NaN_;
  Position := 1;
  Month := 1;
  Date := 1;
  Hour := 0;
  Minute := 0;
  Second := 0;
  Millisecond := 0;
  if (Position <= Length(Text)) and (Text[Position] in ['+', '-']) then
  begin
    if Text[Position] = '-' then
      Sign := -1
    else
      Sign := 1;
    Inc(Position);
    if not Digits(6, Year) then
      Exit;
    Year := Year * Sign;
  end
  else if not Digits(4, Year) then
    Exit;
  if Expect('-') then
  begin
    if not Digits(2, Month) then
      Exit;
    if Expect('-') then
      if not Digits(2, Date) then
        Exit;
  end;
  HasTime := False;
  HasOffset := False;
  IsUtc := False;
  OffsetMinutes := 0;
  if (Position <= Length(Text)) and (Text[Position] in ['T', 't', ' ']) then
  begin
    Inc(Position);
    HasTime := True;
    if not Digits(2, Hour) or not Expect(':') or not Digits(2, Minute) then
      Exit;
    if Expect(':') then
    begin
      if not Digits(2, Second) then
        Exit;
      if Expect('.') or Expect(',') then
      begin
        Fraction := 0;
        Scale := 100;
        if not ((Position <= Length(Text)) and (Text[Position] in ['0'..'9'])) then
          Exit;
        while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
        begin
          Fraction := Fraction + (Ord(Text[Position]) - Ord('0')) * Scale;
          Scale := Scale / 10;
          Inc(Position);
        end;
        Millisecond := Int(Fraction);
      end;
    end;
    if Expect('Z') or Expect('z') then
    begin
      HasOffset := True;
      IsUtc := True;
    end
    else if (Position <= Length(Text)) and (Text[Position] in ['+', '-']) then
    begin
      if Text[Position] = '-' then
        Sign := -1
      else
        Sign := 1;
      Inc(Position);
      if not Digits(2, OffsetHours) then
        Exit;
      Expect(':');
      if not Digits(2, OffsetPart) then
        Exit;
      HasOffset := True;
      OffsetMinutes := Sign * (OffsetHours * 60 + OffsetPart);
    end;
  end;
  if Position <= Length(Text) then
    Exit;
  if (Month < 1) or (Month > 12) or (Date < 1) or (Date > 31) or (Hour > 24) or (Minute > 59) or (Second > 59) or
    ((Hour = 24) and ((Minute > 0) or (Second > 0) or (Millisecond > 0))) then
    Exit;
  Time := MakeDate(MakeDay(Year, Month - 1, Date), MakeTime(Hour, Minute, Second, Millisecond));
  if HasTime and not HasOffset then
    Time := UtcFromLocal(Time)
  else
    Time := Time - OffsetMinutes * 60000.0;
  if IsUtc then;
  Time := TimeClip(Time);
  Result := not IsNaNDouble(Time);
end;

{ The other formats: "Tue Jan 01 2024 10:00:00 GMT+0100 (...)",
  "Tue, 01 Jan 2024 10:00:00 GMT", "Jan 1, 2024", "2024/01/01". }
function ParseLoose(const Text: string; out Time: Double): Boolean;
var
  Words: array of string;
  Index, MonthIndex, Count, Code: Integer;
  Year, Month, Date, Hour, Minute, Second: Double;
  OffsetMinutes: Double;
  HasOffset, HasPm, HasAm: Boolean;
  Word_, Lower: string;
  Parts: TStringArray;
  Value: Integer;
  Number: Double;

  procedure Split;
  var
    Position: Integer;
    Current: string;
  begin
    Words := nil;
    Current := '';
    for Position := 1 to Length(Text) do
    begin
      if Text[Position] in [' ', ',', '(', ')'] then
      begin
        if Current <> '' then
        begin
          SetLength(Words, Length(Words) + 1);
          Words[High(Words)] := Current;
          Current := '';
        end;
        if Text[Position] = '(' then
          Break;
      end
      else
        Current := Current + Text[Position];
    end;
    if Current <> '' then
    begin
      SetLength(Words, Length(Words) + 1);
      Words[High(Words)] := Current;
    end;
  end;

begin
  Result := False;
  Time := NaN_;
  Split;
  Year := NaN_;
  Month := -1;
  Date := -1;
  Hour := 0;
  Minute := 0;
  Second := 0;
  OffsetMinutes := 0;
  HasOffset := False;
  HasPm := False;
  HasAm := False;
  Count := 0;
  for Index := 0 to High(Words) do
  begin
    Word_ := Words[Index];
    Lower := LowerCase(Word_);
    MonthIndex := -1;
    for Value := 0 to 11 do
      if Copy(Lower, 1, 3) = LowerCase(MonthNames[Value]) then
        MonthIndex := Value;
    if (MonthIndex >= 0) and (Length(Lower) >= 3) and not (Lower[1] in ['0'..'9']) then
    begin
      Month := MonthIndex;
      Continue;
    end;
    if (Lower = 'gmt') or (Lower = 'utc') or (Lower = 'z') then
    begin
      HasOffset := True;
      Continue;
    end;
    if (Copy(Lower, 1, 3) = 'gmt') or (Copy(Lower, 1, 3) = 'utc') then
    begin
      Word_ := Copy(Word_, 4, MaxInt);
      Lower := Copy(Lower, 4, MaxInt);
    end;
    if (Length(Word_) = 5) and (Word_[1] in ['+', '-']) then
    begin
      Val(Copy(Word_, 2, 4), Value, Code);
      if Code = 0 then
      begin
        OffsetMinutes := (Value div 100) * 60 + Value mod 100;
        if Word_[1] = '-' then
          OffsetMinutes := -OffsetMinutes;
        HasOffset := True;
        Continue;
      end;
    end;
    if Lower = 'pm' then
    begin
      HasPm := True;
      Continue;
    end;
    if Lower = 'am' then
    begin
      HasAm := True;
      Continue;
    end;
    if Pos(':', Word_) > 0 then
    begin
      Parts := Word_.Split([':']);
      if Length(Parts) >= 2 then
      begin
        Val(Parts[0], Hour, Code);
        if Code <> 0 then
          Exit;
        Val(Parts[1], Minute, Code);
        if Code <> 0 then
          Exit;
        if Length(Parts) >= 3 then
        begin
          Val(Parts[2], Second, Code);
          if Code <> 0 then
            Exit;
        end;
      end;
      Continue;
    end;
    if (Pos('/', Word_) > 0) or ((Pos('-', Word_) > 1)) then
    begin
      if Pos('/', Word_) > 0 then
        Parts := Word_.Split(['/'])
      else
        Parts := Word_.Split(['-']);
      if Length(Parts) = 3 then
      begin
        if Length(Parts[0]) = 4 then
        begin
          Val(Parts[0], Year, Code);
          Val(Parts[1], Number, Code);
          Month := Number - 1;
          Val(Parts[2], Date, Code);
        end
        else
        begin
          Val(Parts[0], Number, Code);
          Month := Number - 1;
          Val(Parts[1], Date, Code);
          Val(Parts[2], Year, Code);
        end;
        Continue;
      end;
      Exit;
    end;
    Val(Word_, Number, Code);
    if Code = 0 then
    begin
      if (Date < 0) and (Number >= 1) and (Number <= 31) and (Length(Word_) <= 2) then
        Date := Number
      else
        Year := Number;
      Inc(Count);
      Continue;
    end;
    { Day names and anything else are ignored. }
  end;
  if IsNaNDouble(Year) or (Month < 0) then
    Exit;
  if Date < 0 then
    Date := 1;
  if HasPm and (Hour < 12) then
    Hour := Hour + 12;
  if HasAm and (Hour = 12) then
    Hour := 0;
  if (Year >= 0) and (Year < 50) and (Count > 0) then
    Year := Year + 2000
  else if (Year >= 50) and (Year < 100) then
    Year := Year + 1900;
  Time := MakeDate(MakeDay(Year, Month, Date), MakeTime(Hour, Minute, Second, 0));
  if HasOffset then
    Time := Time - OffsetMinutes * 60000.0
  else
    Time := UtcFromLocal(Time);
  Time := TimeClip(Time);
  Result := not IsNaNDouble(Time);
end;

function ParseDate(const Text: string): Double;
var
  Trimmed: string;
begin
  Trimmed := Trim(Text);
  if ParseIso(Trimmed, Result) then
    Exit;
  if ParseLoose(Trimmed, Result) then
    Exit;
  Result := NaN_;
end;

{ The constructor }

function ThisDate(R: TJsRealm; Value: TJsValue; out Date: TJsDate): Boolean;
begin
  Date := nil;
  if not JsIsObject(Value) or (JsAsObject(Value).ObjectClass <> ocDate) then
  begin
    R.ThrowTypeError('this is not a Date object.');
    Exit(False);
  end;
  Date := TJsDate(JsAsObject(Value));
  Result := True;
end;

function TimeFromArguments(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer; Utc: Boolean;
  out Time: Double): Boolean;
var
  Parts: array[0..6] of Double;
  Index: Integer;
begin
  Parts[0] := NaN_;
  Parts[1] := 0;
  Parts[2] := 1;
  for Index := 3 to 6 do
    Parts[Index] := 0;
  for Index := 0 to Min(ArgCount, 7) - 1 do
    if not ToDouble(R, Args^[Index], Parts[Index]) then
      Exit(False);
  if not IsNaNDouble(Parts[0]) then
  begin
    Parts[0] := Int(Parts[0]);
    if (Parts[0] >= 0) and (Parts[0] <= 99) then
      Parts[0] := Parts[0] + 1900;
  end;
  Time := MakeDate(MakeDay(Parts[0], Parts[1], Parts[2]), MakeTime(Parts[3], Parts[4], Parts[5], Parts[6]));
  if not Utc then
    Time := UtcFromLocal(Time);
  Time := TimeClip(Time);
  Result := True;
end;

function DateConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Date: TJsDate;
  Prototype: TJsObject;
  Time: Double;
  Value: TJsValue;
  Text: TJsString;
begin
  if NewTarget = JsUndefined then
  begin
    Time := JsCurrentTime();
    Exit(R.NewString(DatePart(LocalTime(Time)) + ' ' + TimePart(Time)));
  end;
  if ArgCount = 0 then
    Time := TimeClip(JsCurrentTime())
  else if ArgCount = 1 then
  begin
    Value := Args^[0];
    if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocDate) then
      Time := TJsDate(JsAsObject(Value)).Time
    else
    begin
      Value := ToPrimitive(R, Value);
      if Value = JsException then
        Exit(JsException);
      if JsIsString(Value) then
      begin
        Text := JsAsString(Value);
        Time := ParseDate(StringToUtf8(R.Heap, Text));
      end
      else
      begin
        if not ToDouble(R, Value, Time) then
          Exit(JsException);
        Time := TimeClip(Time);
      end;
    end;
  end
  else if not TimeFromArguments(R, Args, ArgCount, False, Time) then
    Exit(JsException);
  Prototype := PrototypeFromConstructor(R, NewTarget, inDatePrototype);
  if Prototype = nil then
    Exit(JsException);
  Date := TJsDate(R.NewObjectOfClass(TJsDate, Prototype, ocDate));
  Date.Time := Time;
  Result := JsObjectValue(Date);
end;

function DateNow(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsNumber(Int(JsCurrentTime()));
end;

function DateParse(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Result := JsNumber(ParseDate(StringToUtf8(R.Heap, Text)));
end;

function DateUtc(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Time: Double;
begin
  if not TimeFromArguments(R, Args, ArgCount, True, Time) then
    Exit(JsException);
  Result := JsNumber(Time);
end;

{ Getters: Magic = field + 16 for UTC }
const
  FieldFullYear = 0; FieldMonth = 1; FieldDate = 2; FieldDay = 3; FieldHours = 4; FieldMinutes = 5;
  FieldSeconds = 6; FieldMilliseconds = 7; FieldTime = 8; FieldTimezoneOffset = 9; FieldYear = 10;
  UtcFlag = 16;

function DateGetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Date: TJsDate;
  T: Double;
begin
  if not ThisDate(R, This, Date) then
    Exit(JsException);
  T := Date.Time;
  if IsNaNDouble(T) then
    Exit(JsNaN);
  case Callee.Magic and 15 of
    FieldTime: Exit(JsNumber(T));
    FieldTimezoneOffset: Exit(JsNumber((T - LocalTime(T)) / 60000.0));
  end;
  if (Callee.Magic and UtcFlag) = 0 then
    T := LocalTime(T);
  case Callee.Magic and 15 of
    FieldFullYear: Result := JsNumber(YearFromTime(T));
    FieldYear: Result := JsNumber(YearFromTime(T) - 1900);
    FieldMonth: Result := JsInteger(MonthFromTime(T));
    FieldDate: Result := JsInteger(DateFromTime(T));
    FieldDay: Result := JsInteger(WeekDay(T));
    FieldHours: Result := JsInteger(HourFromTime(T));
    FieldMinutes: Result := JsInteger(MinFromTime(T));
    FieldSeconds: Result := JsInteger(SecFromTime(T));
  else
    Result := JsInteger(MsFromTime(T));
  end;
end;

function DateSetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Date: TJsDate;
  T, NewTime: Double;
  Values: array[0..3] of Double;
  Index, Field: Integer;
  Utc: Boolean;
  Year, Month, Day_, Hour, Minute, Second, Millisecond: Double;
begin
  if not ThisDate(R, This, Date) then
    Exit(JsException);
  Field := Callee.Magic and 15;
  Utc := (Callee.Magic and UtcFlag) <> 0;
  if Field = FieldTime then
  begin
    if not ToDouble(R, Arg(Args, ArgCount, 0), NewTime) then
      Exit(JsException);
    Date.Time := TimeClip(NewTime);
    Exit(JsNumber(Date.Time));
  end;
  for Index := 0 to 3 do
    Values[Index] := NaN_;
  for Index := 0 to Min(ArgCount, 4) - 1 do
    if not ToDouble(R, Args^[Index], Values[Index]) then
      Exit(JsException);
  T := Date.Time;
  if IsNaNDouble(T) then
  begin
    if not (Field in [FieldFullYear, FieldYear]) then
      Exit(JsNaN);
    T := 0;
  end
  else if not Utc then
    T := LocalTime(T);
  Year := YearFromTime(T);
  Month := MonthFromTime(T);
  Day_ := DateFromTime(T);
  Hour := HourFromTime(T);
  Minute := MinFromTime(T);
  Second := SecFromTime(T);
  Millisecond := MsFromTime(T);
  case Field of
    FieldFullYear, FieldYear:
      begin
        Year := Values[0];
        if (Field = FieldYear) and not IsNaNDouble(Year) and (Int(Year) >= 0) and (Int(Year) <= 99) then
          Year := Int(Year) + 1900;
        if ArgCount > 1 then
          Month := Values[1];
        if ArgCount > 2 then
          Day_ := Values[2];
      end;
    FieldMonth:
      begin
        Month := Values[0];
        if ArgCount > 1 then
          Day_ := Values[1];
      end;
    FieldDate:
      Day_ := Values[0];
    FieldHours:
      begin
        Hour := Values[0];
        if ArgCount > 1 then
          Minute := Values[1];
        if ArgCount > 2 then
          Second := Values[2];
        if ArgCount > 3 then
          Millisecond := Values[3];
      end;
    FieldMinutes:
      begin
        Minute := Values[0];
        if ArgCount > 1 then
          Second := Values[1];
        if ArgCount > 2 then
          Millisecond := Values[2];
      end;
    FieldSeconds:
      begin
        Second := Values[0];
        if ArgCount > 1 then
          Millisecond := Values[1];
      end;
  else
    Millisecond := Values[0];
  end;
  NewTime := MakeDate(MakeDay(Year, Month, Day_), MakeTime(Hour, Minute, Second, Millisecond));
  if not Utc then
    NewTime := UtcFromLocal(NewTime);
  Date.Time := TimeClip(NewTime);
  Result := JsNumber(Date.Time);
end;

{ toString 0, toDateString 1, toTimeString 2, toISOString 3, toUTCString 4,
  toLocaleString 5, toLocaleDateString 6, toLocaleTimeString 7 }
function DateFormat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Date: TJsDate;
  T, Local: Double;
begin
  if not ThisDate(R, This, Date) then
    Exit(JsException);
  T := Date.Time;
  if IsNaNDouble(T) then
  begin
    if Callee.Magic = 3 then
      Exit(R.ThrowRangeError('Invalid time value'));
    Exit(R.NewString('Invalid Date'));
  end;
  Local := LocalTime(T);
  case Callee.Magic of
    0: Result := R.NewString(DatePart(Local) + ' ' + TimePart(T));
    1: Result := R.NewString(DatePart(Local));
    2: Result := R.NewString(TimePart(T));
    3: Result := R.NewString(IsoText(T));
    4: Result := R.NewString(UtcText(T));
    5: Result := R.NewString(LocaleDateText(Local) + ', ' + LocaleTimeText(Local));
    6: Result := R.NewString(LocaleDateText(Local));
  else
    Result := R.NewString(LocaleTimeText(Local));
  end;
end;

function DateToJson(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Primitive: TJsValue;
begin
  Target := ToObject(R, This);
  if Target = JsException then
    Exit(JsException);
  Primitive := ToPrimitive(R, Target, ptNumber);
  if Primitive = JsException then
    Exit(JsException);
  if JsIsNumber(Primitive) and not IsFiniteDouble(JsNumberValue(Primitive)) then
    Exit(JsNull);
  Result := R.Call(GetPropertyByKey(R, Target, R.Intern('toISOString')), Target, nil, 0);
end;

function DateToPrimitive(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Hint: TJsValue;
  Names: array[0..1] of TJsAtomName;
  Index: Integer;
  Method, Outcome: TJsValue;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('Date.prototype[Symbol.toPrimitive] called on non-object'));
  Hint := Arg(Args, ArgCount, 0);
  if JsIsString(Hint) and (StringEqualsAscii(JsAsString(Hint), 'string') or
    StringEqualsAscii(JsAsString(Hint), 'default')) then
  begin
    Names[0] := anToString;
    Names[1] := anValueOf;
  end
  else if JsIsString(Hint) and StringEqualsAscii(JsAsString(Hint), 'number') then
  begin
    Names[0] := anValueOf;
    Names[1] := anToString;
  end
  else
    Exit(R.ThrowTypeError('Invalid hint: ' + ValueToPascal(R, Hint)));
  for Index := 0 to 1 do
  begin
    Method := JsAsObject(This).GetValue(R, R.Atom(Names[Index]));
    if Method = JsException then
      Exit(JsException);
    if JsIsCallable(Method) then
    begin
      Outcome := R.Call(Method, This, nil, 0);
      if Outcome = JsException then
        Exit(JsException);
      if not JsIsObject(Outcome) then
        Exit(Outcome);
    end;
  end;
  Result := R.ThrowTypeError('Cannot convert object to primitive value');
end;

function InspectDate(R: TJsRealm; Target: TJsObject; out Text: string): Boolean;
begin
  Result := Target.ObjectClass = ocDate;
  if not Result then
    Exit;
  if IsNaNDouble(TJsDate(Target).Time) then
    Text := 'Invalid Date'
  else
    Text := IsoText(TJsDate(Target).Time);
end;

procedure InstallDate(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;

  procedure Getter(const Name: string; Magic: Integer);
  begin
    DefineMethod(R, Prototype, Name, @DateGetter, 0, Magic);
  end;

  procedure Setter(const Name: string; Magic, Length: Integer);
  begin
    DefineMethod(R, Prototype, Name, @DateSetter, Length, Magic);
  end;

begin
  Prototype := R.Intrinsics[inDatePrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Date', @DateConstructor, 7, Prototype);
  DefineMethod(R, Constructor_, 'now', @DateNow, 0);
  DefineMethod(R, Constructor_, 'parse', @DateParse, 1);
  DefineMethod(R, Constructor_, 'UTC', @DateUtc, 7);
  Getter('getFullYear', FieldFullYear);
  Getter('getYear', FieldYear);
  Getter('getMonth', FieldMonth);
  Getter('getDate', FieldDate);
  Getter('getDay', FieldDay);
  Getter('getHours', FieldHours);
  Getter('getMinutes', FieldMinutes);
  Getter('getSeconds', FieldSeconds);
  Getter('getMilliseconds', FieldMilliseconds);
  Getter('getTime', FieldTime);
  Getter('valueOf', FieldTime);
  Getter('getTimezoneOffset', FieldTimezoneOffset);
  Getter('getUTCFullYear', FieldFullYear or UtcFlag);
  Getter('getUTCMonth', FieldMonth or UtcFlag);
  Getter('getUTCDate', FieldDate or UtcFlag);
  Getter('getUTCDay', FieldDay or UtcFlag);
  Getter('getUTCHours', FieldHours or UtcFlag);
  Getter('getUTCMinutes', FieldMinutes or UtcFlag);
  Getter('getUTCSeconds', FieldSeconds or UtcFlag);
  Getter('getUTCMilliseconds', FieldMilliseconds or UtcFlag);
  Setter('setFullYear', FieldFullYear, 3);
  Setter('setYear', FieldYear, 1);
  Setter('setMonth', FieldMonth, 2);
  Setter('setDate', FieldDate, 1);
  Setter('setHours', FieldHours, 4);
  Setter('setMinutes', FieldMinutes, 3);
  Setter('setSeconds', FieldSeconds, 2);
  Setter('setMilliseconds', FieldMilliseconds, 1);
  Setter('setTime', FieldTime, 1);
  Setter('setUTCFullYear', FieldFullYear or UtcFlag, 3);
  Setter('setUTCMonth', FieldMonth or UtcFlag, 2);
  Setter('setUTCDate', FieldDate or UtcFlag, 1);
  Setter('setUTCHours', FieldHours or UtcFlag, 4);
  Setter('setUTCMinutes', FieldMinutes or UtcFlag, 3);
  Setter('setUTCSeconds', FieldSeconds or UtcFlag, 2);
  Setter('setUTCMilliseconds', FieldMilliseconds or UtcFlag, 1);
  DefineMethod(R, Prototype, 'toString', @DateFormat, 0, 0);
  DefineMethod(R, Prototype, 'toDateString', @DateFormat, 0, 1);
  DefineMethod(R, Prototype, 'toTimeString', @DateFormat, 0, 2);
  DefineMethod(R, Prototype, 'toISOString', @DateFormat, 0, 3);
  DefineMethod(R, Prototype, 'toUTCString', @DateFormat, 0, 4);
  Prototype.DefineData(R, R.Intern('toGMTString'), Prototype.GetValue(R, R.Intern('toUTCString')), PropertyHidden);
  DefineMethod(R, Prototype, 'toLocaleString', @DateFormat, 0, 5);
  DefineMethod(R, Prototype, 'toLocaleDateString', @DateFormat, 0, 6);
  DefineMethod(R, Prototype, 'toLocaleTimeString', @DateFormat, 0, 7);
  DefineMethod(R, Prototype, 'toJSON', @DateToJson, 1);
  DefineSymbolMethod(R, Prototype, wsToPrimitive, '[Symbol.toPrimitive]', @DateToPrimitive, 1, PropertyConfigurable);
  RegisterInspectExtra(@InspectDate);
end;

end.
