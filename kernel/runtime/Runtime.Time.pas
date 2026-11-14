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

end.
