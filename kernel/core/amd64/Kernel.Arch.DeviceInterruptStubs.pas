{
  Entry stubs for hardware and software interrupt vectors.

  Only vectors the kernel actually uses get a stub (see
  Hal.InterruptVectors for the assignments). Interrupts never push an
  error code, so every stub pushes a zero placeholder followed by its
  vector number before continuing in the common entry path.

  The vector is pushed with "push dword": the inline assembler rejects
  "push qword" for constants of 128 and above. In 64-bit mode both encode
  the same instruction, which pushes a 32-bit immediate sign-extended to
  a full 64-bit stack slot.
}
unit Kernel.Arch.DeviceInterruptStubs;

{$mode objfpc}
{$asmmode intel}

interface

{ Returns the entry stub for an interrupt vector, or nil if the kernel
  does not use that vector. }
function DeviceInterruptStubAddress(Vector: Byte): Pointer;

implementation

uses
  Hal.InterruptVectors,
  Kernel.Arch.InterruptEntry;

procedure InterruptStubDispatchInterrupt; assembler; nostackframe;
asm
  push qword 0
  push dword DispatchInterruptVector
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice00; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 0
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice01; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 1
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice02; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 2
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice03; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 3
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice04; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 4
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice05; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 5
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice06; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 6
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice07; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 7
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice08; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 8
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice09; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 9
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice10; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 10
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice11; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 11
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice12; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 12
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice13; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 13
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice14; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 14
  jmp CommonInterruptEntry
end;

procedure InterruptStubDevice15; assembler; nostackframe;
asm
  push qword 0
  push dword DeviceInterruptVectorFirst + 15
  jmp CommonInterruptEntry
end;

procedure InterruptStubClock; assembler; nostackframe;
asm
  push qword 0
  push dword ClockInterruptVector
  jmp CommonInterruptEntry
end;

procedure InterruptStubInterProcessor; assembler; nostackframe;
asm
  push qword 0
  push dword InterProcessorInterruptVector
  jmp CommonInterruptEntry
end;

procedure InterruptStubLegacyPicSpurious; assembler; nostackframe;
asm
  push qword 0
  push dword LegacyPicSpuriousVector
  jmp CommonInterruptEntry
end;

procedure InterruptStubApicSpurious; assembler; nostackframe;
asm
  push qword 0
  push dword ApicSpuriousVector
  jmp CommonInterruptEntry
end;

function DeviceInterruptStubAddress(Vector: Byte): Pointer;
begin
  case Vector of
    DispatchInterruptVector: Result := @InterruptStubDispatchInterrupt;
    DeviceInterruptVectorFirst + 0: Result := @InterruptStubDevice00;
    DeviceInterruptVectorFirst + 1: Result := @InterruptStubDevice01;
    DeviceInterruptVectorFirst + 2: Result := @InterruptStubDevice02;
    DeviceInterruptVectorFirst + 3: Result := @InterruptStubDevice03;
    DeviceInterruptVectorFirst + 4: Result := @InterruptStubDevice04;
    DeviceInterruptVectorFirst + 5: Result := @InterruptStubDevice05;
    DeviceInterruptVectorFirst + 6: Result := @InterruptStubDevice06;
    DeviceInterruptVectorFirst + 7: Result := @InterruptStubDevice07;
    DeviceInterruptVectorFirst + 8: Result := @InterruptStubDevice08;
    DeviceInterruptVectorFirst + 9: Result := @InterruptStubDevice09;
    DeviceInterruptVectorFirst + 10: Result := @InterruptStubDevice10;
    DeviceInterruptVectorFirst + 11: Result := @InterruptStubDevice11;
    DeviceInterruptVectorFirst + 12: Result := @InterruptStubDevice12;
    DeviceInterruptVectorFirst + 13: Result := @InterruptStubDevice13;
    DeviceInterruptVectorFirst + 14: Result := @InterruptStubDevice14;
    DeviceInterruptVectorFirst + 15: Result := @InterruptStubDevice15;
    ClockInterruptVector: Result := @InterruptStubClock;
    InterProcessorInterruptVector: Result := @InterruptStubInterProcessor;
    LegacyPicSpuriousVector: Result := @InterruptStubLegacyPicSpurious;
    ApicSpuriousVector: Result := @InterruptStubApicSpurious;
  else
    Result := nil;
  end;
end;

end.
