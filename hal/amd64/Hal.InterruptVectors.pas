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
