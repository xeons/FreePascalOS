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
{$pointermath on}

interface

uses
  Runtime.Time;

function ParseDateText(Text: PChar; out Time: TUnixTime): Boolean; overload;
function ParseDateText(const Text: string; out Time: TUnixTime): Boolean; overload;
function ParseTouchStamp(Text: PChar; out Time: TUnixTime): Boolean; overload;
function ParseTouchStamp(const Text: string; out Time: TUnixTime): Boolean; overload;

implementation

uses
  Runtime.Text,
  Sys.Text,
  Sys.Time,
  Sys.LocalTime;

const
  SecondsPerDay = 86400;

{ Reads Count digits as a number; False if they are not all digits. }
function ReadDigits(Text: PChar; Count: Integer; out Value: LongInt): Boolean;
var
  Index: Integer;
begin
  Value := 0;
  for Index := 0 to Count - 1 do
  begin
    if not IsDigit(Text[Index]) then
      Exit(False);
    Value := Value * 10 + Ord(Text[Index]) - Ord('0');
  end;
  Result := True;
end;

function SkipSpaces(Text: PChar): PChar;
begin
  Result := Text;
  while IsSpace(Result^) do
    Inc(Result);
end;

{ HH:MM[:SS] at Text; Consumed tells how many characters. }
function ParseClock(Text: PChar; out Seconds: LongInt; out Consumed: Integer): Boolean;
var
  Hour, Minute, Second: LongInt;
begin
  Consumed := 0;
  Seconds := 0;
  if not ReadDigits(Text, 2, Hour) or (Text[2] <> ':') or not ReadDigits(Text + 3, 2, Minute) then
    Exit(False);
  Consumed := 5;
  Second := 0;
  if (Text[5] = ':') and ReadDigits(Text + 6, 2, Second) then
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

function UnitSeconds(Name: PChar; out Seconds: Int64): Boolean;
var
  Word: array[0..15] of Char;
  Length: PtrUInt;
begin
  CopyText(@Word[0], Name, SizeOf(Word));
  Length := TextLength(@Word[0]);
  if (Length > 1) and (Word[Length - 1] = 's') then
    Word[Length - 1] := #0;
  Result := True;
  if TextIsEqual(@Word[0], 'second') or TextIsEqual(@Word[0], 'sec') then
    Seconds := 1
  else if TextIsEqual(@Word[0], 'minute') or TextIsEqual(@Word[0], 'min') then
    Seconds := 60
  else if TextIsEqual(@Word[0], 'hour') then
    Seconds := 3600
  else if TextIsEqual(@Word[0], 'day') then
    Seconds := SecondsPerDay
  else if TextIsEqual(@Word[0], 'week') then
    Seconds := 7 * SecondsPerDay
  else
    Result := False;
end;

{ "N UNIT ago", "+N UNIT", "-N UNIT" }
function ParseRelative(Text: PChar; out Time: TUnixTime): Boolean;
var
  Sign: Int64;
  Amount: Int64;
  UnitName: array[0..15] of Char;
  Length: Integer;
  Multiplier: Int64;
begin
  Result := False;
  Sign := 1;
  if Text^ = '+' then
    Inc(Text)
  else if Text^ = '-' then
  begin
    Sign := -1;
    Inc(Text);
  end;
  if not IsDigit(Text^) then
    Exit;
  Amount := 0;
  while IsDigit(Text^) do
  begin
    Amount := Amount * 10 + Ord(Text^) - Ord('0');
    Inc(Text);
  end;
  Text := SkipSpaces(Text);
  Length := 0;
  while IsLetter(Text^) and (Length < 15) do
  begin
    UnitName[Length] := Text^;
    Inc(Length);
    Inc(Text);
  end;
  UnitName[Length] := #0;
  if not UnitSeconds(@UnitName[0], Multiplier) then
    Exit;
  Text := SkipSpaces(Text);
  if TextStartsWith(Text, 'ago') then
  begin
    Sign := -Sign;
    Text := SkipSpaces(Text + 3);
  end;
  if Text^ <> #0 then
    Exit;
  Time := CurrentTime + Sign * Amount * Multiplier;
  Result := True;
end;

function ParseDateText(Text: PChar; out Time: TUnixTime): Boolean;
var
  Year, Month, Day: LongInt;
  ClockSeconds: LongInt;
  Consumed: Integer;
  Rest: PChar;
begin
  Time := 0;
  Text := SkipSpaces(Text);
  if Text^ = '@' then
    Exit(ParseInteger(Text + 1, Time));
  if TextIsEqual(Text, 'now') then
  begin
    Time := CurrentTime;
    Exit(True);
  end;
  if TextIsEqual(Text, 'today') then
  begin
    Time := StartOfToday;
    Exit(True);
  end;
  if TextIsEqual(Text, 'yesterday') then
  begin
    Time := CurrentTime - SecondsPerDay;
    Exit(True);
  end;
  if TextIsEqual(Text, 'tomorrow') then
  begin
    Time := CurrentTime + SecondsPerDay;
    Exit(True);
  end;

  { YYYY-MM-DD [HH:MM[:SS]] }
  if ReadDigits(Text, 4, Year) and (Text[4] = '-') and ReadDigits(Text + 5, 2, Month) and
     (Text[7] = '-') and ReadDigits(Text + 8, 2, Day) then
  begin
    if (Month < 1) or (Month > 12) or (Day < 1) or (Day > 31) then
      Exit(False);
    ClockSeconds := 0;
    Rest := Text + 10;
    if (Rest^ = 'T') or (Rest^ = ' ') then
    begin
      Rest := SkipSpaces(Rest + 1);
      if (Rest^ <> #0) and not ParseClock(Rest, ClockSeconds, Consumed) then
        Exit(False);
      if Rest^ <> #0 then
        Rest := Rest + Consumed;
    end;
    Rest := SkipSpaces(Rest);
    if TextIsEqual(Rest, 'UTC') or TextIsEqual(Rest, 'Z') then
      Time := CalendarToUnixTime(Year, Month, Day, 0, 0, 0) + ClockSeconds
    else if Rest^ = #0 then
      Time := LocalTimeToUnixTime(Year, Month, Day, ClockSeconds div 3600, (ClockSeconds div 60) mod 60,
        ClockSeconds mod 60)
    else
      Exit(False);
    Exit(True);
  end;

  { HH:MM[:SS] today }
  if ParseClock(Text, ClockSeconds, Consumed) and (SkipSpaces(Text + Consumed)^ = #0) then
  begin
    Time := StartOfToday + ClockSeconds;
    Exit(True);
  end;

  Result := ParseRelative(Text, Time);
end;

function ParseTouchStamp(Text: PChar; out Time: TUnixTime): Boolean;
var
  Digits: PtrUInt;
  Dot: PtrInt;
  Year, Month, Day, Hour, Minute, Second: LongInt;
  Century: LongInt;
  Offset: Integer;
  Now: TLocalTime;
begin
  Time := 0;
  Dot := FindCharacter(Text, '.');
  if Dot >= 0 then
    Digits := PtrUInt(Dot)
  else
    Digits := TextLength(Text);
  if not (Digits in [8, 10, 12]) then
    Exit(False);

  DecodeLocalTime(CurrentTime, Now);
  Year := Now.DateTime.Year;
  Offset := 0;
  if Digits = 12 then
  begin
    if not ReadDigits(Text, 4, Year) then
      Exit(False);
    Offset := 4;
  end
  else if Digits = 10 then
  begin
    if not ReadDigits(Text, 2, Year) then
      Exit(False);
    { POSIX: 69..99 are 1969..1999, 00..68 are 2000..2068. }
    if Year >= 69 then
      Century := 1900
    else
      Century := 2000;
    Year := Century + Year;
    Offset := 2;
  end;
  if not ReadDigits(Text + Offset, 2, Month) or not ReadDigits(Text + Offset + 2, 2, Day) or
     not ReadDigits(Text + Offset + 4, 2, Hour) or not ReadDigits(Text + Offset + 6, 2, Minute) then
    Exit(False);
  Second := 0;
  if Dot >= 0 then
  begin
    if (TextLength(Text + Dot + 1) <> 2) or not ReadDigits(Text + Dot + 1, 2, Second) then
      Exit(False);
  end;
  if (Month < 1) or (Month > 12) or (Day < 1) or (Day > 31) or (Hour > 23) or (Minute > 59) or (Second > 60) then
    Exit(False);
  Time := LocalTimeToUnixTime(Year, Month, Day, Hour, Minute, Second);
  Result := True;
end;

function ParseDateText(const Text: string; out Time: TUnixTime): Boolean;
begin
  Result := ParseDateText(PChar(Text), Time);
end;

function ParseTouchStamp(const Text: string; out Time: TUnixTime): Boolean;
begin
  Result := ParseTouchStamp(PChar(Text), Time);
end;

end.
