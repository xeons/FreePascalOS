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
  A clock in nanoseconds from the HPET's main counter: the kernel's
  clock where the time stamp counter cannot be trusted (Hal.Clock-
  Sources). One counter for every processor, running in every power
  state, so it never goes back between processors; but each read is a
  read of the device (about a microsecond on real chipsets, an exit to
  the hypervisor in a virtual machine), so the counter is preferred
  where it is sound.

  Like the counter clock it starts at a given time, pauses before
  suspend to RAM and continues from there after waking (the chipset
  loses its counter while asleep).
}
unit Hal.HpetClock;

{$mode objfpc}

interface

{ Starts the clock reading StartNanoseconds now. }
procedure StartHpetClock(StartNanoseconds: QWord);
function HpetClockIsRunning: Boolean;
function HpetClockNanoseconds: QWord;
procedure PauseHpetClock;
procedure ContinueHpetClock;

implementation

uses
  Hal.Hpet,
  Hal.HpetMath;

var
  Running: Boolean = False;
  OriginCount: QWord = 0;
  OriginNanoseconds: QWord = 0;
  PausedNanoseconds: QWord = 0;

procedure StartHpetClock(StartNanoseconds: QWord);
begin
  OriginCount := ReadHpetCounter;
  OriginNanoseconds := StartNanoseconds;
  Running := True;
end;

function HpetClockIsRunning: Boolean;
begin
  Result := Running;
end;

function HpetClockNanoseconds: QWord;
var
  Count: QWord;
begin
  Count := ReadHpetCounter;
  if Count <= OriginCount then
    Exit(OriginNanoseconds);
  Result := OriginNanoseconds + HpetTicksToNanoseconds(Count - OriginCount, HpetPeriodFemtoseconds);
end;

procedure PauseHpetClock;
begin
  PausedNanoseconds := HpetClockNanoseconds;
end;

procedure ContinueHpetClock;
begin
  OriginCount := ReadHpetCounter;
  OriginNanoseconds := PausedNanoseconds;
end;

end.
