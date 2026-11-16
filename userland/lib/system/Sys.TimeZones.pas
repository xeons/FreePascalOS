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
  The time zone database: a zone's offset from UTC at any moment.

  Each zone has a standard offset, the abbreviations of its standard and
  daylight saving times, and one of a few daylight saving rules; its
  daylight time is an hour ahead of its standard time. The rules are the
  ones in force today, used for every year:

    European        last Sunday of March 01:00 UTC to last Sunday of
                    October 01:00 UTC (the European Union, the UK; since
                    1996)
    North American  second Sunday of March 02:00 local standard time to
                    first Sunday of November 02:00 local daylight time
                    (the US and Canada; since 2007)
    Australian      first Sunday of October 02:00 standard time to first
                    Sunday of April 03:00 daylight time (south-eastern
                    Australia; since 2008)
    New Zealand     last Sunday of September 02:00 standard time to first
                    Sunday of April 03:00 daylight time (since 2007)

  The zones are named as in the IANA database (Europe/Berlin), so names
  people know work, and are the ones whose rules fit these: places that
  change their rules often (Egypt, Iran, Israel, Chile, Morocco...) are
  left out rather than shown wrong. Dates before a rule began are shown
  with it all the same; the system has no need of historical times.

  The table is compiled in, rather than read from files, so every
  program (and the system settings service, before any file system
  question) has it at once, and the conversions build on the host for
  their tests. The zone a program shows times in is Sys.LocalTime's.
}
unit Sys.TimeZones;

{$mode objfpc}

interface

uses
  Runtime.Time;

type
  TDaylightRule = (RuleNone, RuleEuropean, RuleNorthAmerican, RuleAustralian, RuleNewZealand);

  TTimeZone = record
    Name: PChar;
    { Seconds east of UTC (Berlin +3600, New York -18000). }
    StandardOffset: LongInt;
    StandardAbbreviation: PChar;
    DaylightAbbreviation: PChar;
    Rule: TDaylightRule;
  end;
  PTimeZone = ^TTimeZone;

  { What a zone's clocks say at one moment. }
  TZoneOffset = record
    { Seconds east of UTC. }
    Offset: LongInt;
    Abbreviation: PChar;
    IsDaylight: Boolean;
  end;

const
  DaylightSavingSeconds = 3600;

function TimeZoneCount: Integer;
{ The zones, from the farthest west to the farthest east; nil past the
  last. }
function TimeZoneAt(Index: Integer): PTimeZone;
{ The zone called Name (exactly, as in the table), or nil. }
function FindTimeZone(Name: PChar): PTimeZone;
function UtcTimeZone: PTimeZone;

{ The zone's offset at the moment Time (UTC). }
function ZoneOffsetAt(Zone: PTimeZone; Time: TUnixTime): TZoneOffset;
{ The moment the zone's clocks show the given local time. In the hour
  that comes twice when clocks go back, the first (daylight) one; in the
  hour skipped when they go forward, as if standard time went on. }
function ZoneLocalTimeToUnixTime(Zone: PTimeZone; Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;
{ When daylight saving time starts and ends in Year (UTC moments);
  False for a zone without it. }
function DaylightSavingPeriod(Zone: PTimeZone; Year: LongInt; out Start, Finish: TUnixTime): Boolean;

implementation

const
  ZoneCount = 66;
  Zones: array[0..ZoneCount - 1] of TTimeZone = (
    (Name: 'Pacific/Honolulu'; StandardOffset: -36000; StandardAbbreviation: 'HST';
      DaylightAbbreviation: 'HST'; Rule: RuleNone),
    (Name: 'America/Anchorage'; StandardOffset: -32400; StandardAbbreviation: 'AKST';
      DaylightAbbreviation: 'AKDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Los_Angeles'; StandardOffset: -28800; StandardAbbreviation: 'PST';
      DaylightAbbreviation: 'PDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Vancouver'; StandardOffset: -28800; StandardAbbreviation: 'PST';
      DaylightAbbreviation: 'PDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Denver'; StandardOffset: -25200; StandardAbbreviation: 'MST';
      DaylightAbbreviation: 'MDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Edmonton'; StandardOffset: -25200; StandardAbbreviation: 'MST';
      DaylightAbbreviation: 'MDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Phoenix'; StandardOffset: -25200; StandardAbbreviation: 'MST';
      DaylightAbbreviation: 'MST'; Rule: RuleNone),
    (Name: 'America/Chicago'; StandardOffset: -21600; StandardAbbreviation: 'CST';
      DaylightAbbreviation: 'CDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Winnipeg'; StandardOffset: -21600; StandardAbbreviation: 'CST';
      DaylightAbbreviation: 'CDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Mexico_City'; StandardOffset: -21600; StandardAbbreviation: 'CST';
      DaylightAbbreviation: 'CST'; Rule: RuleNone),
    (Name: 'America/New_York'; StandardOffset: -18000; StandardAbbreviation: 'EST';
      DaylightAbbreviation: 'EDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Toronto'; StandardOffset: -18000; StandardAbbreviation: 'EST';
      DaylightAbbreviation: 'EDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Bogota'; StandardOffset: -18000; StandardAbbreviation: '-05';
      DaylightAbbreviation: '-05'; Rule: RuleNone),
    (Name: 'America/Lima'; StandardOffset: -18000; StandardAbbreviation: '-05';
      DaylightAbbreviation: '-05'; Rule: RuleNone),
    (Name: 'America/Halifax'; StandardOffset: -14400; StandardAbbreviation: 'AST';
      DaylightAbbreviation: 'ADT'; Rule: RuleNorthAmerican),
    (Name: 'America/Caracas'; StandardOffset: -14400; StandardAbbreviation: '-04';
      DaylightAbbreviation: '-04'; Rule: RuleNone),
    (Name: 'America/St_Johns'; StandardOffset: -12600; StandardAbbreviation: 'NST';
      DaylightAbbreviation: 'NDT'; Rule: RuleNorthAmerican),
    (Name: 'America/Sao_Paulo'; StandardOffset: -10800; StandardAbbreviation: '-03';
      DaylightAbbreviation: '-03'; Rule: RuleNone),
    (Name: 'America/Argentina/Buenos_Aires'; StandardOffset: -10800; StandardAbbreviation: '-03';
      DaylightAbbreviation: '-03'; Rule: RuleNone),
    (Name: 'Atlantic/Reykjavik'; StandardOffset: 0; StandardAbbreviation: 'GMT';
      DaylightAbbreviation: 'GMT'; Rule: RuleNone),
    (Name: 'UTC'; StandardOffset: 0; StandardAbbreviation: 'UTC';
      DaylightAbbreviation: 'UTC'; Rule: RuleNone),
    (Name: 'Europe/London'; StandardOffset: 0; StandardAbbreviation: 'GMT';
      DaylightAbbreviation: 'BST'; Rule: RuleEuropean),
    (Name: 'Europe/Dublin'; StandardOffset: 0; StandardAbbreviation: 'GMT';
      DaylightAbbreviation: 'IST'; Rule: RuleEuropean),
    (Name: 'Europe/Lisbon'; StandardOffset: 0; StandardAbbreviation: 'WET';
      DaylightAbbreviation: 'WEST'; Rule: RuleEuropean),
    (Name: 'Africa/Lagos'; StandardOffset: 3600; StandardAbbreviation: 'WAT';
      DaylightAbbreviation: 'WAT'; Rule: RuleNone),
    (Name: 'Europe/Amsterdam'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Berlin'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Brussels'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Budapest'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Copenhagen'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Madrid'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Oslo'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Paris'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Prague'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Rome'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Stockholm'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Vienna'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Warsaw'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Europe/Zurich'; StandardOffset: 3600; StandardAbbreviation: 'CET';
      DaylightAbbreviation: 'CEST'; Rule: RuleEuropean),
    (Name: 'Africa/Johannesburg'; StandardOffset: 7200; StandardAbbreviation: 'SAST';
      DaylightAbbreviation: 'SAST'; Rule: RuleNone),
    (Name: 'Europe/Athens'; StandardOffset: 7200; StandardAbbreviation: 'EET';
      DaylightAbbreviation: 'EEST'; Rule: RuleEuropean),
    (Name: 'Europe/Bucharest'; StandardOffset: 7200; StandardAbbreviation: 'EET';
      DaylightAbbreviation: 'EEST'; Rule: RuleEuropean),
    (Name: 'Europe/Helsinki'; StandardOffset: 7200; StandardAbbreviation: 'EET';
      DaylightAbbreviation: 'EEST'; Rule: RuleEuropean),
    (Name: 'Europe/Kyiv'; StandardOffset: 7200; StandardAbbreviation: 'EET';
      DaylightAbbreviation: 'EEST'; Rule: RuleEuropean),
    (Name: 'Africa/Nairobi'; StandardOffset: 10800; StandardAbbreviation: 'EAT';
      DaylightAbbreviation: 'EAT'; Rule: RuleNone),
    (Name: 'Asia/Riyadh'; StandardOffset: 10800; StandardAbbreviation: '+03';
      DaylightAbbreviation: '+03'; Rule: RuleNone),
    (Name: 'Europe/Istanbul'; StandardOffset: 10800; StandardAbbreviation: '+03';
      DaylightAbbreviation: '+03'; Rule: RuleNone),
    (Name: 'Europe/Moscow'; StandardOffset: 10800; StandardAbbreviation: 'MSK';
      DaylightAbbreviation: 'MSK'; Rule: RuleNone),
    (Name: 'Asia/Dubai'; StandardOffset: 14400; StandardAbbreviation: '+04';
      DaylightAbbreviation: '+04'; Rule: RuleNone),
    (Name: 'Asia/Karachi'; StandardOffset: 18000; StandardAbbreviation: 'PKT';
      DaylightAbbreviation: 'PKT'; Rule: RuleNone),
    (Name: 'Asia/Kolkata'; StandardOffset: 19800; StandardAbbreviation: 'IST';
      DaylightAbbreviation: 'IST'; Rule: RuleNone),
    (Name: 'Asia/Kathmandu'; StandardOffset: 20700; StandardAbbreviation: '+0545';
      DaylightAbbreviation: '+0545'; Rule: RuleNone),
    (Name: 'Asia/Dhaka'; StandardOffset: 21600; StandardAbbreviation: '+06';
      DaylightAbbreviation: '+06'; Rule: RuleNone),
    (Name: 'Asia/Bangkok'; StandardOffset: 25200; StandardAbbreviation: '+07';
      DaylightAbbreviation: '+07'; Rule: RuleNone),
    (Name: 'Asia/Jakarta'; StandardOffset: 25200; StandardAbbreviation: 'WIB';
      DaylightAbbreviation: 'WIB'; Rule: RuleNone),
    (Name: 'Asia/Hong_Kong'; StandardOffset: 28800; StandardAbbreviation: 'HKT';
      DaylightAbbreviation: 'HKT'; Rule: RuleNone),
    (Name: 'Asia/Shanghai'; StandardOffset: 28800; StandardAbbreviation: 'CST';
      DaylightAbbreviation: 'CST'; Rule: RuleNone),
    (Name: 'Asia/Singapore'; StandardOffset: 28800; StandardAbbreviation: '+08';
      DaylightAbbreviation: '+08'; Rule: RuleNone),
    (Name: 'Australia/Perth'; StandardOffset: 28800; StandardAbbreviation: 'AWST';
      DaylightAbbreviation: 'AWST'; Rule: RuleNone),
    (Name: 'Asia/Seoul'; StandardOffset: 32400; StandardAbbreviation: 'KST';
      DaylightAbbreviation: 'KST'; Rule: RuleNone),
    (Name: 'Asia/Tokyo'; StandardOffset: 32400; StandardAbbreviation: 'JST';
      DaylightAbbreviation: 'JST'; Rule: RuleNone),
    (Name: 'Australia/Adelaide'; StandardOffset: 34200; StandardAbbreviation: 'ACST';
      DaylightAbbreviation: 'ACDT'; Rule: RuleAustralian),
    (Name: 'Australia/Brisbane'; StandardOffset: 36000; StandardAbbreviation: 'AEST';
      DaylightAbbreviation: 'AEST'; Rule: RuleNone),
    (Name: 'Australia/Melbourne'; StandardOffset: 36000; StandardAbbreviation: 'AEST';
      DaylightAbbreviation: 'AEDT'; Rule: RuleAustralian),
    (Name: 'Australia/Sydney'; StandardOffset: 36000; StandardAbbreviation: 'AEST';
      DaylightAbbreviation: 'AEDT'; Rule: RuleAustralian),
    (Name: 'Pacific/Auckland'; StandardOffset: 43200; StandardAbbreviation: 'NZST';
      DaylightAbbreviation: 'NZDT'; Rule: RuleNewZealand));

function TimeZoneCount: Integer;
begin
  Result := ZoneCount;
end;

function TimeZoneAt(Index: Integer): PTimeZone;
begin
  if (Index < 0) or (Index >= ZoneCount) then
    Exit(nil);
  Result := @Zones[Index];
end;

function SameName(First, Second: PChar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while (First[Index] <> #0) and (First[Index] = Second[Index]) do
    Inc(Index);
  Result := First[Index] = Second[Index];
end;

function FindTimeZone(Name: PChar): PTimeZone;
var
  Index: Integer;
begin
  if Name = nil then
    Exit(nil);
  for Index := 0 to ZoneCount - 1 do
    if SameName(Zones[Index].Name, Name) then
      Exit(@Zones[Index]);
  Result := nil;
end;

function UtcTimeZone: PTimeZone;
begin
  Result := FindTimeZone('UTC');
end;

{ 0 for Sunday. 1970-01-01 was a Thursday. }
function WeekdayOfDate(Year, Month, Day: LongInt): LongInt;
var
  Days: Int64;
begin
  Days := DaysSinceUnixEpoch(Year, Month, Day);
  Result := LongInt(((Days mod 7) + 7 + 4) mod 7);
end;

function DaysInMonth(Year, Month: LongInt): LongInt;
begin
  if Month = 12 then
    Result := LongInt(DaysSinceUnixEpoch(Year + 1, 1, 1) - DaysSinceUnixEpoch(Year, 12, 1))
  else
    Result := LongInt(DaysSinceUnixEpoch(Year, Month + 1, 1) - DaysSinceUnixEpoch(Year, Month, 1));
end;

{ The day of the month of the Nth Sunday (N from 1). }
function NthSunday(Year, Month, Count: LongInt): LongInt;
var
  FirstSunday: LongInt;
begin
  FirstSunday := 1 + (7 - WeekdayOfDate(Year, Month, 1)) mod 7;
  Result := FirstSunday + 7 * (Count - 1);
end;

function LastSunday(Year, Month: LongInt): LongInt;
var
  LastDay: LongInt;
begin
  LastDay := DaysInMonth(Year, Month);
  Result := LastDay - WeekdayOfDate(Year, Month, LastDay);
end;

{ The UTC moment of a wall clock time at Offset seconds east of UTC. }
function MomentOf(Year, Month, Day, Hour: LongInt; Offset: LongInt): TUnixTime;
begin
  Result := CalendarToUnixTime(Year, Month, Day, Hour, 0, 0) - Offset;
end;

function DaylightSavingPeriod(Zone: PTimeZone; Year: LongInt; out Start, Finish: TUnixTime): Boolean;
var
  Standard: LongInt;
  Daylight: LongInt;
begin
  Start := 0;
  Finish := 0;
  Standard := Zone^.StandardOffset;
  Daylight := Standard + DaylightSavingSeconds;
  Result := True;
  case Zone^.Rule of
    RuleEuropean:
      begin
        Start := MomentOf(Year, 3, LastSunday(Year, 3), 1, 0);
        Finish := MomentOf(Year, 10, LastSunday(Year, 10), 1, 0);
      end;
    RuleNorthAmerican:
      begin
        Start := MomentOf(Year, 3, NthSunday(Year, 3, 2), 2, Standard);
        Finish := MomentOf(Year, 11, NthSunday(Year, 11, 1), 2, Daylight);
      end;
    RuleAustralian:
      begin
        Start := MomentOf(Year, 10, NthSunday(Year, 10, 1), 2, Standard);
        Finish := MomentOf(Year, 4, NthSunday(Year, 4, 1), 3, Daylight);
      end;
    RuleNewZealand:
      begin
        Start := MomentOf(Year, 9, LastSunday(Year, 9), 2, Standard);
        Finish := MomentOf(Year, 4, NthSunday(Year, 4, 1), 3, Daylight);
      end;
  else
    Result := False;
  end;
end;

function IsDaylightAt(Zone: PTimeZone; Time: TUnixTime): Boolean;
var
  Year, Month, Day, Hour, Minute, Second: LongInt;
  Start: TUnixTime;
  Finish: TUnixTime;
begin
  { The year by standard time: no rule changes near the new year. }
  UnixTimeToCalendar(Time + Zone^.StandardOffset, Year, Month, Day, Hour, Minute, Second);
  if not DaylightSavingPeriod(Zone, Year, Start, Finish) then
    Exit(False);
  if Start < Finish then
    { Northern: daylight time in the middle of the year. }
    Result := (Time >= Start) and (Time < Finish)
  else
    { Southern: daylight time at the start and the end of the year. }
    Result := (Time < Finish) or (Time >= Start);
end;

function ZoneOffsetAt(Zone: PTimeZone; Time: TUnixTime): TZoneOffset;
begin
  if Zone = nil then
    Zone := UtcTimeZone;
  Result.IsDaylight := IsDaylightAt(Zone, Time);
  if Result.IsDaylight then
  begin
    Result.Offset := Zone^.StandardOffset + DaylightSavingSeconds;
    Result.Abbreviation := Zone^.DaylightAbbreviation;
  end
  else
  begin
    Result.Offset := Zone^.StandardOffset;
    Result.Abbreviation := Zone^.StandardAbbreviation;
  end;
end;

function ZoneLocalTimeToUnixTime(Zone: PTimeZone; Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;
var
  Local: TUnixTime;
  Candidate: TUnixTime;
begin
  if Zone = nil then
    Zone := UtcTimeZone;
  Local := CalendarToUnixTime(Year, Month, Day, Hour, Minute, Second);
  { The daylight reading first, so the hour that comes twice is taken
    the first time; it holds only if the zone keeps daylight time then. }
  if Zone^.Rule <> RuleNone then
  begin
    Candidate := Local - (Zone^.StandardOffset + DaylightSavingSeconds);
    if ZoneOffsetAt(Zone, Candidate).IsDaylight then
      Exit(Candidate);
  end;
  Result := Local - Zone^.StandardOffset;
end;

end.
