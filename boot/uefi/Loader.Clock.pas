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
  The time of day as the firmware tells it (the GetTime runtime
  service), for machines whose clock the kernel cannot read itself (the
  AArch64 ones: QEMU's virt machine lists no clock in its ACPI tables,
  the Raspberry Pi 4 has none and its firmware keeps one in a variable).
  A time of no known zone is taken as UTC.
}
unit Loader.Clock;

{$mode objfpc}

interface

{ Seconds since 1970-01-01 UTC, or 0 if the firmware does not tell. }
function ReadFirmwareTime: Int64;

implementation

uses
  Uefi.Base,
  Uefi.RuntimeServices,
  Runtime.Memory,
  Runtime.Time,
  Loader.Firmware;

function ReadFirmwareTime: Int64;
var
  RuntimeServices: PEfiRuntimeServices;
  Time: TEfiTime;
begin
  Result := 0;
  RuntimeServices := PEfiRuntimeServices(FirmwareSystemTable^.RuntimeServices);
  if (RuntimeServices = nil) or not Assigned(RuntimeServices^.GetTime) then
    Exit;
  ZeroMemory(@Time, SizeOf(Time));
  if EfiIsError(RuntimeServices^.GetTime(@Time, nil)) then
    Exit;
  if (Time.Year < 1970) or (Time.Month < 1) or (Time.Month > 12) or (Time.Day < 1) or (Time.Day > 31) then
    Exit;
  Result := CalendarToUnixTime(Time.Year, Time.Month, Time.Day, Time.Hour, Time.Minute, Time.Second);
  { Local time = UTC + TimeZone minutes (UEFI 2.7 and later). }
  if Time.TimeZone <> EfiUnspecifiedTimeZone then
    Result := Result - Int64(Time.TimeZone) * 60;
end;

end.
