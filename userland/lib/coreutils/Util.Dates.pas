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
  Reading dates and times written by people (date -d, date -s, touch -d,
  touch -t). Dates and clock times are local times of the zone the
  program shows times in (Sys.LocalTime); "UTC" or "Z" after one makes
  it UTC.

    @SECONDS                 seconds since 1970-01-01
    now, today, yesterday, tomorrow
    YYYY-MM-DD               midnight of that day
    YYYY-MM-DD HH:MM[:SS]    (or with "T" between date and time)
    HH:MM[:SS]               that time today
    N UNIT ago, +N UNIT, -N UNIT   relative to now; UNIT is second,
                             minute, hour, day, week (plural allowed)

  touch -t uses [[CC]YY]MMDDhhmm[.ss].
}
unit Util.Dates;

{$mode objfpc}{$H+}

interface

uses
  Runtime.Time;

function ParseDateText(const Text: string; out Time: TUnixTime): Boolean;
function ParseTouchStamp(const Text: string; out Time: TUnixTime): Boolean;

implementation

uses
  StrUtils,
  Sys.Text,
  Sys.Time,
  Sys.LocalTime,
  Util.Numbers;

const
  SecondsPerDay = 86400;
  { Longer unit names are cut short to this (and so not recognised). }
  UnitNameLimit = 15;

{ The character at Index (from 1), #0 past the end. }
function CharacterAt(const Text: string; Index: Integer): Char;
begin
  if (Index >= 1) and (Index <= Length(Text)) then
    Result := Text[Index]
  else
    Result := #0;
end;

{ Reads Count digits from Start as a number; False if they are not all
  digits. }
function ReadDigits(const Text: string; Start, Count: Integer; out Value: LongInt): Boolean;
var
  Index: Integer;
begin
  Value := 0;
  for Index := Start to Start + Count - 1 do
  begin
    if not IsDigit(CharacterAt(Text, Index)) then
      Exit(False);
    Value := Value * 10 + Ord(Text[Index]) - Ord('0');
  end;
  Result := True;
end;

function WithoutLeadingSpaces(const Text: string): string;
var
  Start: Integer;
begin
  Start := 1;
  while IsSpace(CharacterAt(Text, Start)) do
    Inc(Start);
  Result := Copy(Text, Start, MaxInt);
end;

{ HH:MM[:SS] at the start of Text; Consumed tells how many characters. }
function ParseClock(const Text: string; out Seconds: LongInt; out Consumed: Integer): Boolean;
var
  Hour, Minute, Second: LongInt;
begin
  Consumed := 0;
  Seconds := 0;
  if not ReadDigits(Text, 1, 2, Hour) or (CharacterAt(Text, 3) <> ':') or not ReadDigits(Text, 4, 2, Minute) then
    Exit(False);
  Consumed := 5;
  Second := 0;
  if (CharacterAt(Text, 6) = ':') and ReadDigits(Text, 7, 2, Second) then
    Consumed := 8;
  if (Hour > 23) or (Minute > 59) or (Second > 60) then
    Exit(False);
  Seconds := Hour * 3600 + Minute * 60 + Second;
  Result := True;
end;

{ Local midnight of today. }
function StartOfToday: TUnixTime;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  Result := LocalTimeToUnixTime(Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day, 0, 0, 0);
end;

function UnitSeconds(const Name: string; out Seconds: Int64): Boolean;
var
  Word: string;
begin
  Word := Name;
  if (Length(Word) > 1) and (Word[Length(Word)] = 's') then
    SetLength(Word, Length(Word) - 1);
  Result := True;
  if (Word = 'second') or (Word = 'sec') then
    Seconds := 1
  else if (Word = 'minute') or (Word = 'min') then
    Seconds := 60
  else if Word = 'hour' then
    Seconds := 3600
  else if Word = 'day' then
    Seconds := SecondsPerDay
  else if Word = 'week' then
    Seconds := 7 * SecondsPerDay
  else
    Result := False;
end;

{ "N UNIT ago", "+N UNIT", "-N UNIT" }
function ParseRelative(const Text: string; out Time: TUnixTime): Boolean;
var
  Sign: Int64;
  Amount: Int64;
  UnitName: string;
  Position: Integer;
  Rest: string;
  Multiplier: Int64;
begin
  Result := False;
  Sign := 1;
  Position := 1;
  if CharacterAt(Text, Position) = '+' then
    Inc(Position)
  else if CharacterAt(Text, Position) = '-' then
  begin
    Sign := -1;
    Inc(Position);
  end;
  if not IsDigit(CharacterAt(Text, Position)) then
    Exit;
  Amount := 0;
  while IsDigit(CharacterAt(Text, Position)) do
  begin
    Amount := Amount * 10 + Ord(Text[Position]) - Ord('0');
    Inc(Position);
  end;
  Rest := WithoutLeadingSpaces(Copy(Text, Position, MaxInt));
  Position := 1;
  while IsLetter(CharacterAt(Rest, Position)) and (Position <= UnitNameLimit) do
    Inc(Position);
  UnitName := Copy(Rest, 1, Position - 1);
  if not UnitSeconds(UnitName, Multiplier) then
    Exit;
  Rest := WithoutLeadingSpaces(Copy(Rest, Position, MaxInt));
  if StartsStr('ago', Rest) then
  begin
    Sign := -Sign;
    Rest := WithoutLeadingSpaces(Copy(Rest, 4, MaxInt));
  end;
  if Rest <> '' then
    Exit;
  Time := CurrentTime + Sign * Amount * Multiplier;
  Result := True;
end;

{ YYYY-MM-DD [HH:MM[:SS]] [UTC|Z] after the date's ten characters. }
function ParseCalendarDate(const Text: string; out Time: TUnixTime): Boolean;
var
  Year, Month, Day: LongInt;
  ClockSeconds: LongInt;
  Consumed: Integer;
  Rest: string;
begin
  Time := 0;
  ReadDigits(Text, 1, 4, Year);
  ReadDigits(Text, 6, 2, Month);
  ReadDigits(Text, 9, 2, Day);
  if (Month < 1) or (Month > 12) or (Day < 1) or (Day > 31) then
    Exit(False);
  ClockSeconds := 0;
  Rest := Copy(Text, 11, MaxInt);
  if CharacterAt(Rest, 1) in ['T', ' '] then
  begin
    Rest := WithoutLeadingSpaces(Copy(Rest, 2, MaxInt));
    if Rest <> '' then
    begin
      if not ParseClock(Rest, ClockSeconds, Consumed) then
        Exit(False);
      Delete(Rest, 1, Consumed);
    end;
  end;
  Rest := WithoutLeadingSpaces(Rest);
  if (Rest = 'UTC') or (Rest = 'Z') then
    Time := CalendarToUnixTime(Year, Month, Day, 0, 0, 0) + ClockSeconds
  else if Rest = '' then
    Time := LocalTimeToUnixTime(Year, Month, Day, ClockSeconds div 3600, (ClockSeconds div 60) mod 60,
      ClockSeconds mod 60)
  else
    Exit(False);
  Result := True;
end;

function IsCalendarDate(const Text: string): Boolean;
var
  Value: LongInt;
begin
  Result := ReadDigits(Text, 1, 4, Value) and (CharacterAt(Text, 5) = '-') and ReadDigits(Text, 6, 2, Value) and
    (CharacterAt(Text, 8) = '-') and ReadDigits(Text, 9, 2, Value);
end;

function ParseDateText(const Text: string; out Time: TUnixTime): Boolean;
var
  Trimmed: string;
  ClockSeconds: LongInt;
  Consumed: Integer;
begin
  Time := 0;
  Trimmed := WithoutLeadingSpaces(Text);
  if CharacterAt(Trimmed, 1) = '@' then
    Exit(ParseDecimal(Copy(Trimmed, 2, MaxInt), Time));
  if Trimmed = 'now' then
  begin
    Time := CurrentTime;
    Exit(True);
  end;
  if Trimmed = 'today' then
  begin
    Time := StartOfToday;
    Exit(True);
  end;
  if Trimmed = 'yesterday' then
  begin
    Time := CurrentTime - SecondsPerDay;
    Exit(True);
  end;
  if Trimmed = 'tomorrow' then
  begin
    Time := CurrentTime + SecondsPerDay;
    Exit(True);
  end;
  if IsCalendarDate(Trimmed) then
    Exit(ParseCalendarDate(Trimmed, Time));

  { HH:MM[:SS] today }
  if ParseClock(Trimmed, ClockSeconds, Consumed) and (WithoutLeadingSpaces(Copy(Trimmed, Consumed + 1, MaxInt)) = '') then
  begin
    Time := StartOfToday + ClockSeconds;
    Exit(True);
  end;

  Result := ParseRelative(Trimmed, Time);
end;

function ParseTouchStamp(const Text: string; out Time: TUnixTime): Boolean;
var
  Digits: Integer;
  Dot: Integer;
  Year, Month, Day, Hour, Minute, Second: LongInt;
  Century: LongInt;
  Offset: Integer;
  Now: TLocalTime;
begin
  Time := 0;
  Dot := Pos('.', Text);
  if Dot > 0 then
    Digits := Dot - 1
  else
    Digits := Length(Text);
  if not (Digits in [8, 10, 12]) then
    Exit(False);

  DecodeLocalTime(CurrentTime, Now);
  Year := Now.DateTime.Year;
  Offset := 0;
  if Digits = 12 then
  begin
    if not ReadDigits(Text, 1, 4, Year) then
      Exit(False);
    Offset := 4;
  end
  else if Digits = 10 then
  begin
    if not ReadDigits(Text, 1, 2, Year) then
      Exit(False);
    { POSIX: 69..99 are 1969..1999, 00..68 are 2000..2068. }
    if Year >= 69 then
      Century := 1900
    else
      Century := 2000;
    Year := Century + Year;
    Offset := 2;
  end;
  if not ReadDigits(Text, Offset + 1, 2, Month) or not ReadDigits(Text, Offset + 3, 2, Day) or
     not ReadDigits(Text, Offset + 5, 2, Hour) or not ReadDigits(Text, Offset + 7, 2, Minute) then
    Exit(False);
  Second := 0;
  if Dot > 0 then
  begin
    if (Length(Text) - Dot <> 2) or not ReadDigits(Text, Dot + 1, 2, Second) then
      Exit(False);
  end;
  if (Month < 1) or (Month > 12) or (Day < 1) or (Day > 31) or (Hour > 23) or (Minute > 59) or (Second > 60) then
    Exit(False);
  Time := LocalTimeToUnixTime(Year, Month, Day, Hour, Minute, Second);
  Result := True;
end;

end.
