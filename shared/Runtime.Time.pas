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
  Calendar conversions.

  The kernel stores times as Unix time: seconds since 1970-01-01 00:00:00
  UTC. These helpers convert calendar dates and the packed date/time words
  used by FAT and exFAT into that form.
}
unit Runtime.Time;

{$mode objfpc}

interface

type
  TUnixTime = Int64;

{ Days since 1970-01-01 for a proleptic Gregorian date. }
function DaysSinceUnixEpoch(Year, Month, Day: LongInt): Int64;

function CalendarToUnixTime(Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;

{ Decodes a FAT/exFAT date word (bits 15-9 year since 1980, 8-5 month,
  4-0 day) and time word (bits 15-11 hours, 10-5 minutes, 4-0 two-second
  units). Returns zero for an unset date. }
function DosDateTimeToUnixTime(DateWord, TimeWord: Word): TUnixTime;

procedure UnixTimeToCalendar(Time: TUnixTime; out Year, Month, Day, Hour, Minute, Second: LongInt);

{ The inverse of DosDateTimeToUnixTime. Times before 1980 become the
  earliest representable date. Seconds are rounded down to even. }
procedure UnixTimeToDosDateTime(Time: TUnixTime; out DateWord, TimeWord: Word);

implementation

function DaysSinceUnixEpoch(Year, Month, Day: LongInt): Int64;
var
  YearOfEra: LongInt;
  Era: LongInt;
  DayOfYear: LongInt;
  DayOfEra: LongInt;
  ShiftedMonth: LongInt;
begin
  { Howard Hinnant's days_from_civil algorithm: count from March 1 so the
    leap day falls at the end of the year. }
  if Month <= 2 then
    Year := Year - 1;

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
  Result := Int64(Era) * 146097 + DayOfEra - 719468;
end;

function CalendarToUnixTime(Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;
begin
  Result := DaysSinceUnixEpoch(Year, Month, Day) * 86400 +
    Int64(Hour) * 3600 + Int64(Minute) * 60 + Second;
end;

function DosDateTimeToUnixTime(DateWord, TimeWord: Word): TUnixTime;
var
  Year: LongInt;
  Month: LongInt;
  Day: LongInt;
begin
  if DateWord = 0 then
    Exit(0);

  Year := 1980 + (DateWord shr 9);
  Month := (DateWord shr 5) and $0F;
  Day := DateWord and $1F;
  if (Month < 1) or (Month > 12) or (Day < 1) then
    Exit(0);

  Result := CalendarToUnixTime(Year, Month, Day,
    TimeWord shr 11, (TimeWord shr 5) and $3F, (TimeWord and $1F) * 2);
end;

procedure UnixTimeToCalendar(Time: TUnixTime; out Year, Month, Day, Hour, Minute, Second: LongInt);
var
  Days: Int64;
  SecondsOfDay: Int64;
  Era: Int64;
  DayOfEra: Int64;
  YearOfEra: Int64;
  DayOfYear: Int64;
  ShiftedMonth: Int64;
begin
  Days := Time div 86400;
  SecondsOfDay := Time mod 86400;
  if SecondsOfDay < 0 then
  begin
    SecondsOfDay := SecondsOfDay + 86400;
    Days := Days - 1;
  end;
  Hour := LongInt(SecondsOfDay div 3600);
  Minute := LongInt((SecondsOfDay mod 3600) div 60);
  Second := LongInt(SecondsOfDay mod 60);

  { Howard Hinnant's civil_from_days, the inverse of days_from_civil. }
  Days := Days + 719468;
  if Days >= 0 then
    Era := Days div 146097
  else
    Era := (Days - 146096) div 146097;
  DayOfEra := Days - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  ShiftedMonth := (5 * DayOfYear + 2) div 153;
  Day := LongInt(DayOfYear - (153 * ShiftedMonth + 2) div 5 + 1);
  if ShiftedMonth < 10 then
    Month := LongInt(ShiftedMonth + 3)
  else
    Month := LongInt(ShiftedMonth - 9);
  Year := LongInt(YearOfEra + Era * 400);
  if Month <= 2 then
    Inc(Year);
end;

procedure UnixTimeToDosDateTime(Time: TUnixTime; out DateWord, TimeWord: Word);
var
  Year, Month, Day, Hour, Minute, Second: LongInt;
begin
  UnixTimeToCalendar(Time, Year, Month, Day, Hour, Minute, Second);
  if Year < 1980 then
  begin
    DateWord := (1 shl 5) or 1; { 1980-01-01 }
    TimeWord := 0;
    Exit;
  end;
  if Year > 2107 then
    Year := 2107;
  DateWord := Word(((Year - 1980) shl 9) or (Month shl 5) or Day);
  TimeWord := Word((Hour shl 11) or (Minute shl 5) or (Second div 2));
end;

end.
