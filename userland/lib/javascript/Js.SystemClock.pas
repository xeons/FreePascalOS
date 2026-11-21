{
  The clock and time zone of FreePascalOS for Js.Platform.

  The kernel's wall clock counts seconds; milliseconds come from the
  uptime counter, measured from a moment the wall clock was read (read
  again when the two drift apart by more than a second, as when the
  clock is set). The local offset and the zone's abbreviation come from
  the time zone database for the zone the program shows times in (TZ,
  else the system's), at the moment asked about, so dates in other
  seasons and years get their own rules.
}
unit Js.SystemClock;

{$mode objfpc}{$H+}

interface

implementation

uses
  Math,
  Js.Values,
  Runtime.Time,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Js.Platform;

var
  BaseSeconds: Int64 = 0;
  BaseUptime: QWord = 0;
  Zone: PTimeZone = nil;

function SystemCurrentTime: Double;
var
  Seconds: Int64;
  Uptime: QWord;
begin
  Seconds := CurrentTime;
  Uptime := UptimeMilliseconds;
  if (BaseUptime = 0) or (Abs((Seconds - BaseSeconds) * 1000 - Int64(Uptime - BaseUptime)) > 1500) then
  begin
    BaseSeconds := Seconds;
    BaseUptime := Uptime;
  end;
  Result := BaseSeconds * 1000.0 + (Uptime - BaseUptime);
end;

function ProgramZone: PTimeZone;
begin
  if Zone = nil then
    Zone := CurrentTimeZone;
  Result := Zone;
end;

function SystemLocalOffset(UtcMilliseconds: Double): Double;
begin
  if IsNan(UtcMilliseconds) then
    Exit(0);
  Result := ZoneOffsetAt(ProgramZone, Trunc(FloorDouble(UtcMilliseconds / 1000.0))).Offset * 1000.0;
end;

function SystemZoneName(UtcMilliseconds: Double): string;
var
  Abbreviation: PChar;
begin
  Abbreviation := ZoneOffsetAt(ProgramZone, Trunc(FloorDouble(UtcMilliseconds / 1000.0))).Abbreviation;
  if Abbreviation = nil then
    Exit('UTC');
  Result := Abbreviation;
end;

function SystemMonotonicTime: Double;
begin
  Result := UptimeMilliseconds;
end;

initialization
  JsCurrentTime := @SystemCurrentTime;
  JsLocalOffset := @SystemLocalOffset;
  JsZoneName := @SystemZoneName;
  JsMonotonicTime := @SystemMonotonicTime;
end.
