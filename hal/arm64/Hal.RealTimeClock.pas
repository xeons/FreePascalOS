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
  The real-time clock on AArch64: none yet.

  The Raspberry Pi 4 has no battery-backed clock (the Pi 5 has one, on
  its RP1/PMIC); QEMU's virt machine has a PL031, which its ACPI tables
  do not list. The UEFI runtime service GetTime would cover both once
  the kernel calls runtime services. Until then the time starts at zero
  and the network time (or the user) sets it.
}
unit Hal.RealTimeClock;

{$mode objfpc}

interface

uses
  Runtime.Time;

{ Returns the current time, or zero if the clock could not be read. }
function ReadRealTimeClock: TUnixTime;

{ Does nothing (there is no clock to set). }
procedure WriteRealTimeClock(Time: TUnixTime);

implementation

function ReadRealTimeClock: TUnixTime;
begin
  Result := 0;
end;

procedure WriteRealTimeClock(Time: TUnixTime);
begin
end;

end.
