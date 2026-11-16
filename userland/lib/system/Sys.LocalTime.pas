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
  Local time: times as the clocks of a time zone show them.

  The system keeps UTC (the kernel's wall clock, file times); people
  read local time. The zone is the system's, which the kernel keeps by
  name (CallGetTimeZone; set by root, remembered by the system settings
  service in the system's settings, Time/Zone), unless the environment
  variable TZ names another zone of the database (Sys.TimeZones) for
  one program and its children: `TZ=Asia/Tokyo date`. A name the
  database does not know counts as UTC.

  Setting the system's zone and the clock are root's (the kernel
  refuses others); the system settings service does it for users who
  may, and remembers the zone.
}
unit Sys.LocalTime;

{$mode objfpc}{$H+}

interface

uses
  Runtime.Time,
  Sys.Time,
  Sys.TimeZones;

type
  TLocalTime = record
    { The zone's wall clock reading. }
    DateTime: TDateTime;
    { Seconds east of UTC at that moment. }
    Offset: LongInt;
    { "CET", "EDT", "UTC". }
    Abbreviation: PChar;
    IsDaylight: Boolean;
  end;

{ The zone this program shows times in: TZ's, else the system's. }
function CurrentTimeZone: PTimeZone;
{ The system's zone (the kernel's), whatever TZ says; UTC if the kernel
  holds a name the database does not know. }
function SystemTimeZone: PTimeZone;

procedure DecodeLocalTime(Time: TUnixTime; out Local: TLocalTime);
procedure DecodeTimeInZone(Zone: PTimeZone; Time: TUnixTime; out Local: TLocalTime);
{ The moment the current zone's clocks show this (see
  ZoneLocalTimeToUnixTime for the hours that come twice or never). }
function LocalTimeToUnixTime(Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;

{ "+0100", "-0500", "+0530". }
function FormatUtcOffset(Offset: LongInt): string;

{ The system's zone from now on (root only): ErrorNotFound for a name
  the database does not know, ErrorNotPermitted for others than root. }
function SetSystemTimeZone(const Name: string): LongInt;
{ Sets the system's clock to Time (UTC), and the battery backed clock
  with it (root only). }
function SetSystemClock(Time: TUnixTime): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Environment;

function SystemTimeZone: PTimeZone;
var
  Name: array[0..TimeZoneNameCapacity - 1] of Char;
begin
  Result := nil;
  if KernelGetTimeZone(@Name[0], TimeZoneNameCapacity) >= 0 then
    Result := FindTimeZone(@Name[0]);
  if Result = nil then
    Result := UtcTimeZone;
end;

function CurrentTimeZone: PTimeZone;
var
  Name: PChar;
begin
  Name := GetVariable('TZ');
  if (Name <> nil) and (Name[0] <> #0) then
  begin
    Result := FindTimeZone(Name);
    if Result = nil then
      Result := UtcTimeZone;
    Exit;
  end;
  Result := SystemTimeZone;
end;

procedure DecodeTimeInZone(Zone: PTimeZone; Time: TUnixTime; out Local: TLocalTime);
var
  ZoneOffset: TZoneOffset;
begin
  ZoneOffset := ZoneOffsetAt(Zone, Time);
  DecodeTime(Time + ZoneOffset.Offset, Local.DateTime);
  Local.Offset := ZoneOffset.Offset;
  Local.Abbreviation := ZoneOffset.Abbreviation;
  Local.IsDaylight := ZoneOffset.IsDaylight;
end;

procedure DecodeLocalTime(Time: TUnixTime; out Local: TLocalTime);
begin
  DecodeTimeInZone(CurrentTimeZone, Time, Local);
end;

function LocalTimeToUnixTime(Year, Month, Day, Hour, Minute, Second: LongInt): TUnixTime;
begin
  Result := ZoneLocalTimeToUnixTime(CurrentTimeZone, Year, Month, Day, Hour, Minute, Second);
end;

function FormatUtcOffset(Offset: LongInt): string;
var
  Minutes: LongInt;
  Hours: LongInt;
begin
  if Offset < 0 then
  begin
    Result := '-';
    Offset := -Offset;
  end
  else
    Result := '+';
  Minutes := (Offset div 60) mod 60;
  Hours := Offset div 3600;
  Result := Result + Char(Ord('0') + (Hours div 10) mod 10) + Char(Ord('0') + Hours mod 10) +
    Char(Ord('0') + Minutes div 10) + Char(Ord('0') + Minutes mod 10);
end;

function SetSystemTimeZone(const Name: string): LongInt;
begin
  if FindTimeZone(PChar(Name)) = nil then
    Exit(ErrorNotFound);
  Result := ErrorCodeOf(KernelSetTimeZone(PChar(Name)));
end;

function SetSystemClock(Time: TUnixTime): LongInt;
begin
  Result := ErrorCodeOf(KernelSetWallClock(Time));
end;

end.
