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
  Interrupt vector assignments for x86-64.

  The local APIC derives an interrupt's priority class from the upper four
  bits of its vector, and the kernel's priority levels map one to one onto
  those classes. Each vector below is therefore chosen to fall in the
  class of the priority level it is serviced at:

    0x00 .. 0x1F   Processor exceptions
    0x2F           Dispatch level software interrupt (level 2)
    0x30 .. 0x3F   Device interrupts (level 3)
    0xD0           Clock (level 13)
    0xD1           The HPET's comparator: the broadcast timer (level 13)
    0xE0           Inter-processor interrupts (level 14)
    0xF0 .. 0xFF   Legacy PIC (masked, only spurious) and APIC spurious
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
  { The HPET comparator that wakes processors in deep idle states
    (Hal.HpetEventTimer): at the clock's level, never below it. }
  PlatformTimerInterruptVector = $D1;
  InterProcessorInterruptVector = $E0;

  { The legacy 8259 controllers are remapped here and fully masked. They
    can still raise a spurious interrupt on their lowest priority line. }
  LegacyPicMasterVectorBase = $F0;
  LegacyPicSlaveVectorBase = $F8;
  LegacyPicSpuriousVector = LegacyPicMasterVectorBase + 7;

  ApicSpuriousVector = $FF;

function IsSpuriousInterruptVector(Vector: Byte): Boolean;

implementation

function IsSpuriousInterruptVector(Vector: Byte): Boolean;
begin
  Result := (Vector = ApicSpuriousVector) or (Vector = LegacyPicSpuriousVector);
end;

end.
