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
  AArch64 implementation of interrupt priority levels.

  The level lives in the GIC CPU interface's priority mask register
  (GICC_PMR, banked per processor at one address): the GIC signals only
  interrupts whose priority value is below the mask, and lower values
  are more urgent. Level L is the mask (15 - L) * 16, and an interrupt
  at level L gets the priority (15 - L) * 16 (Hal.Gic), so it is held off
  exactly while the level is L or higher - as CR8 does on x86-64. GIC-400
  implements 32 priority steps, more than these 16 need.

  Each vector's level is its number div 16, as on x86-64 (the HAL picks
  the vectors, Hal.InterruptVectors).

  Before the HAL found the GIC (the first moments of the boot processor)
  the level is only remembered; interrupts are masked then anyway.
}
unit Kernel.Arch.PriorityLevel;

{$mode objfpc}

interface

function ArchGetPriorityLevel: Byte;
procedure ArchSetPriorityLevel(Level: Byte);
function ArchPriorityLevelOfVector(Vector: Byte): Byte;

{ The GIC priority value of an interrupt at Level, and the mask for it. }
function GicPriorityOfLevel(Level: Byte): Byte;

{ Called by the HAL once the CPU interface is mapped: from then on the
  level is the priority mask register at that address. }
procedure UsePriorityMaskRegister(Register: PLongWord);

implementation

uses
  Kernel.Arch.Cpu;

const
  HighestLevel = 15;

var
  PriorityMaskRegister: PLongWord = nil;
  EarlyLevel: Byte = 0;

function GicPriorityOfLevel(Level: Byte): Byte;
begin
  Result := Byte((HighestLevel - Level) shl 4);
end;

function ArchGetPriorityLevel: Byte;
begin
  if PriorityMaskRegister = nil then
    Exit(EarlyLevel);
  Result := Byte(HighestLevel - ((PriorityMaskRegister^ shr 4) and $F));
end;

procedure ArchSetPriorityLevel(Level: Byte);
begin
  if PriorityMaskRegister = nil then
  begin
    EarlyLevel := Level;
    Exit;
  end;
  PriorityMaskRegister^ := GicPriorityOfLevel(Level);
  { The write must have reached the GIC before the code that relies on
    the new level runs. }
  DataSynchronizationBarrier;
end;

function ArchPriorityLevelOfVector(Vector: Byte): Byte;
begin
  Result := Vector shr 4;
end;

procedure UsePriorityMaskRegister(Register: PLongWord);
begin
  Register^ := GicPriorityOfLevel(EarlyLevel);
  PriorityMaskRegister := Register;
end;

end.
