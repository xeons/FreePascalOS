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
  (GICv2: GICC_PMR, banked per processor at one address; GICv3: the
  system register ICC_PMR_EL1, GicSystemRegisters.s): the GIC signals only
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
{ Called by the HAL on a GICv3 once this processor's system register
  interface is on: from then on the level is ICC_PMR_EL1. }
procedure UseSystemRegisterPriorityMask;

implementation

uses
  Kernel.Arch.Cpu;

const
  HighestLevel = 15;

type
  TPriorityMaskKind = (MaskNotYetKnown, MaskMemoryMapped, MaskSystemRegister);

var
  MaskKind: TPriorityMaskKind = MaskNotYetKnown;
  PriorityMaskRegister: PLongWord = nil;
  EarlyLevel: Byte = 0;

function ArchReadGicPriorityMask: QWord; external name 'ArchReadGicPriorityMask';
procedure ArchWriteGicPriorityMask(Value: QWord); external name 'ArchWriteGicPriorityMask';

function GicPriorityOfLevel(Level: Byte): Byte;
begin
  Result := Byte((HighestLevel - Level) shl 4);
end;

function ArchGetPriorityLevel: Byte;
begin
  case MaskKind of
    MaskMemoryMapped:
      Result := Byte(HighestLevel - ((PriorityMaskRegister^ shr 4) and $F));
    MaskSystemRegister:
      Result := Byte(HighestLevel - ((ArchReadGicPriorityMask shr 4) and $F));
  else
    Result := EarlyLevel;
  end;
end;

procedure ArchSetPriorityLevel(Level: Byte);
begin
  case MaskKind of
    MaskMemoryMapped:
      begin
        PriorityMaskRegister^ := GicPriorityOfLevel(Level);
        { The write must have reached the GIC before the code that
          relies on the new level runs. }
        DataSynchronizationBarrier;
      end;
    MaskSystemRegister:
      ArchWriteGicPriorityMask(GicPriorityOfLevel(Level));
  else
    EarlyLevel := Level;
  end;
end;

function ArchPriorityLevelOfVector(Vector: Byte): Byte;
begin
  Result := Vector shr 4;
end;

procedure UsePriorityMaskRegister(Register: PLongWord);
begin
  Register^ := GicPriorityOfLevel(EarlyLevel);
  PriorityMaskRegister := Register;
  MaskKind := MaskMemoryMapped;
end;

procedure UseSystemRegisterPriorityMask;
begin
  { Each processor has its own register, set as the memory mapped one
    is (UsePriorityMaskRegister). }
  ArchWriteGicPriorityMask(GicPriorityOfLevel(EarlyLevel));
  MaskKind := MaskSystemRegister;
end;

end.
