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

  Where there is a PL031 (QEMU's virt machine; Hal.Pl031) it is the
  clock: read at start and after waking from suspend, and set whenever
  the wall clock is stepped (Kernel.WallClock), so the time set survives
  a restart.

  Otherwise (the Raspberry Pi 4 has no battery-backed clock: its UEFI
  firmware keeps the time in a variable; the Pi 5's, on its PMIC, has no
  driver yet) the time comes from the firmware's GetTime runtime
  service, which the loader calls before it hands over
  (TBootInformation.FirmwareTime): the clock reads that time plus the
  time since the kernel started. Setting it then changes nothing kept:
  the network time (or the user) sets the system's time again after the
  next start.
}
unit Hal.RealTimeClock;

{$mode objfpc}

interface

uses
  Runtime.Time;

{ Returns the current time, or zero if the clock could not be read. }
function ReadRealTimeClock: TUnixTime;

{ Sets the PL031 if there is one; otherwise does nothing. }
procedure WriteRealTimeClock(Time: TUnixTime);
{ True if a clock that keeps time (a PL031) was found. }
function RealTimeClockIsKept: Boolean;
{ The PL031's alarm at Time (0: off); False without one, or for a time
  past or beyond its 32-bit count. }
function SetRealTimeClockAlarm(Time: TUnixTime): Boolean;
{ True if the alarm went off since the last call. }
function RealTimeClockAlarmFired: Boolean;

implementation

uses
  Boot.Information,
  Kernel.Arch.Cpu,
  Hal.Pl031;

var
  ArchBootInformation: PBootInformation; external name 'ArchBootInformation';
  { Copied at the first reading (during start-up, Kernel.Clock): the boot
    information's pages are given back later (Memory.BootDataReclaim). }
  FirmwareTime: Int64 = 0;
  FirmwareTimeIsCopied: Boolean = False;

function ReadRealTimeClock: TUnixTime;
var
  Frequency: QWord;
begin
  Result := 0;
  if FindPl031 then
    Exit(TUnixTime(ReadPl031Seconds));
  if not FirmwareTimeIsCopied and (ArchBootInformation <> nil) then
  begin
    FirmwareTime := ArchBootInformation^.FirmwareTime;
    FirmwareTimeIsCopied := True;
  end;
  if FirmwareTime = 0 then
    Exit;
  Frequency := ReadCounterFrequency;
  Result := TUnixTime(FirmwareTime);
  if Frequency <> 0 then
    Result := Result + TUnixTime(ReadTimeStampCounter div Frequency);
end;

procedure WriteRealTimeClock(Time: TUnixTime);
begin
  { The PL031 counts unsigned 32-bit seconds. }
  if (Time >= 0) and (Time <= High(LongWord)) and FindPl031 then
    WritePl031Seconds(QWord(Time));
end;

function RealTimeClockIsKept: Boolean;
begin
  Result := FindPl031;
end;

function SetRealTimeClockAlarm(Time: TUnixTime): Boolean;
begin
  if not FindPl031 then
    Exit(False);
  if Time = 0 then
  begin
    SetPl031Alarm(0);
    Exit(True);
  end;
  Result := (Time > TUnixTime(ReadPl031Seconds)) and (Time <= High(LongWord));
  if Result then
    SetPl031Alarm(QWord(Time));
end;

function RealTimeClockAlarmFired: Boolean;
begin
  Result := FindPl031 and Pl031AlarmFired;
end;

end.
