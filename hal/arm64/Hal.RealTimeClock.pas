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
  The real-time clock on AArch64.

  The Raspberry Pi 4 has no battery-backed clock (its UEFI firmware
  keeps the time in a variable; the Pi 5 has one, on its RP1/PMIC);
  QEMU's virt machine has a PL031, which its ACPI tables do not list.
  So the time comes from the firmware's GetTime runtime service, which
  the loader calls before it hands over (TBootInformation.FirmwareTime):
  the clock reads that time plus the time since the kernel started.
  Setting it changes nothing kept: the network time (or the user) sets
  the system's time again after the next start.
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

uses
  Boot.Information,
  Kernel.Arch.Cpu;

var
  ArchBootInformation: PBootInformation; external name 'ArchBootInformation';

function ReadRealTimeClock: TUnixTime;
var
  Frequency: QWord;
begin
  Result := 0;
  if (ArchBootInformation = nil) or (ArchBootInformation^.FirmwareTime = 0) then
    Exit;
  Frequency := ReadCounterFrequency;
  Result := TUnixTime(ArchBootInformation^.FirmwareTime);
  if Frequency <> 0 then
    Result := Result + TUnixTime(ReadTimeStampCounter div Frequency);
end;

procedure WriteRealTimeClock(Time: TUnixTime);
begin
end;

end.
