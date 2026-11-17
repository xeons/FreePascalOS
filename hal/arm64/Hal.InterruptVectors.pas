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
  The kernel's interrupt vectors on AArch64.

  The GIC numbers its interrupts itself (INTIDs: 0-15 software generated,
  16-31 private to a processor, 32 and up shared). The kernel keeps its
  own vector numbers, the same as on x86-64, so the priority level of a
  vector is its number div 16 everywhere: the HAL gives each INTID it
  uses a vector (Hal.Gic) and the GIC priority of that vector's level.

    0-31    processor exceptions (Kernel.Arch.Exceptions numbers them)
    2Fh     dispatch (SGI 0 to the processor itself)          level 2
    30h-3Fh device interrupts (shared peripheral interrupts)  level 3
    D0h     clock (the generic timer's virtual timer PPI)     level 13
    E0h     inter-processor requests (SGI 1)                  level 14
    FFh     spurious (INTID 1023)
}
unit Hal.InterruptVectors;

{$mode objfpc}

interface

const
  ProcessorExceptionVectorCount = 32;
  DispatchInterruptVector = $2F;
  DeviceInterruptVectorFirst = $30;
  DeviceInterruptVectorCount = 16;
  ClockInterruptVector = $D0;
  InterProcessorInterruptVector = $E0;
  SpuriousInterruptVector = $FF;

function IsSpuriousInterruptVector(Vector: Byte): Boolean;

implementation

function IsSpuriousInterruptVector(Vector: Byte): Boolean;
begin
  Result := Vector = SpuriousInterruptVector;
end;

end.
