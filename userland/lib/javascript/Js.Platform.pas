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
  What the engine needs from the system: the clock and the local time
  zone.

  The defaults use the Free Pascal runtime (the host's clock and its
  current UTC offset, for the host tests); Js.SystemClock replaces them
  on FreePascalOS with the kernel's clock and the time zone database
  (Sys.LocalTime), so that historical dates get their own daylight
  saving rules.
}
unit Js.Platform;

{$mode objfpc}{$H+}

interface

type
  { Milliseconds since 1970-01-01 UTC. }
  TJsClockFunction = function: Double;
  { Local time minus UTC, in milliseconds, at the UTC moment given. }
  TJsOffsetFunction = function(UtcMilliseconds: Double): Double;
  { The zone's short name at the UTC moment ("CET", "UTC"). }
  TJsZoneNameFunction = function(UtcMilliseconds: Double): string;
  { A monotonic millisecond count for performance.now(). }
  TJsMonotonicFunction = function: Double;

var
  JsCurrentTime: TJsClockFunction;
  JsLocalOffset: TJsOffsetFunction;
  JsZoneName: TJsZoneNameFunction;
  JsMonotonicTime: TJsMonotonicFunction;

implementation

uses
  SysUtils,
  DateUtils;

function HostCurrentTime: Double;
begin
  Result := (Now - UnixDateDelta) * 86400000.0 + GetLocalTimeOffset * 60000.0;
end;

function HostLocalOffset(UtcMilliseconds: Double): Double;
begin
  Result := -GetLocalTimeOffset * 60000.0;
end;

function HostZoneName(UtcMilliseconds: Double): string;
var
  Offset: Integer;
begin
  Offset := -GetLocalTimeOffset;
  if Offset = 0 then
    Exit('Coordinated Universal Time');
  Result := 'GMT' + Format('%s%.2d%.2d', [Copy('+-', 1 + Ord(Offset < 0), 1), Abs(Offset) div 60, Abs(Offset) mod 60]);
end;

function HostMonotonicTime: Double;
begin
  Result := GetTickCount64;
end;

initialization
  JsCurrentTime := @HostCurrentTime;
  JsLocalOffset := @HostLocalOffset;
  JsZoneName := @HostZoneName;
  JsMonotonicTime := @HostMonotonicTime;
end.
