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
  Entry stubs for the 32 processor exception vectors.

  Some exceptions make the processor push an error code and some do not.
  Stubs for the latter push a zero first, so that every trap frame has the
  same layout. Each stub then pushes its vector number and continues in
  the common entry path.
}
unit Kernel.Arch.ExceptionStubs;

{$mode objfpc}
{$asmmode intel}

interface

{ Returns the entry stub for a processor exception vector (0..31). }
function ExceptionStubAddress(Vector: Byte): Pointer;

implementation

uses
  Kernel.Arch.InterruptEntry;

procedure ExceptionStubDivideError; assembler; nostackframe;
asm
  push qword 0
  push qword 0
  jmp CommonInterruptEntry
end;

procedure ExceptionStubDebug; assembler; nostackframe;
asm
  push qword 0
  push qword 1
  jmp CommonInterruptEntry
end;

procedure ExceptionStubNonMaskableInterrupt; assembler; nostackframe;
asm
  push qword 0
  push qword 2
  jmp CommonInterruptEntry
end;

procedure ExceptionStubBreakpoint; assembler; nostackframe;
asm
  push qword 0
  push qword 3
  jmp CommonInterruptEntry
end;

procedure ExceptionStubOverflow; assembler; nostackframe;
asm
  push qword 0
  push qword 4
  jmp CommonInterruptEntry
end;

procedure ExceptionStubBoundRangeExceeded; assembler; nostackframe;
asm
  push qword 0
  push qword 5
  jmp CommonInterruptEntry
end;

procedure ExceptionStubInvalidOpcode; assembler; nostackframe;
asm
  push qword 0
  push qword 6
  jmp CommonInterruptEntry
end;

procedure ExceptionStubDeviceNotAvailable; assembler; nostackframe;
asm
  push qword 0
  push qword 7
  jmp CommonInterruptEntry
end;

procedure ExceptionStubDoubleFault; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 8
  jmp CommonInterruptEntry
end;

procedure ExceptionStubCoprocessorSegmentOverrun; assembler; nostackframe;
asm
  push qword 0
  push qword 9
  jmp CommonInterruptEntry
end;

procedure ExceptionStubInvalidTaskState; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 10
  jmp CommonInterruptEntry
end;

procedure ExceptionStubSegmentNotPresent; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 11
  jmp CommonInterruptEntry
end;

procedure ExceptionStubStackSegmentFault; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 12
  jmp CommonInterruptEntry
end;

procedure ExceptionStubGeneralProtection; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 13
  jmp CommonInterruptEntry
end;

procedure ExceptionStubPageFault; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 14
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved15; assembler; nostackframe;
asm
  push qword 0
  push qword 15
  jmp CommonInterruptEntry
end;

procedure ExceptionStubFloatingPointError; assembler; nostackframe;
asm
  push qword 0
  push qword 16
  jmp CommonInterruptEntry
end;

procedure ExceptionStubAlignmentCheck; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 17
  jmp CommonInterruptEntry
end;

procedure ExceptionStubMachineCheck; assembler; nostackframe;
asm
  push qword 0
  push qword 18
  jmp CommonInterruptEntry
end;

procedure ExceptionStubSimdFloatingPoint; assembler; nostackframe;
asm
  push qword 0
  push qword 19
  jmp CommonInterruptEntry
end;

procedure ExceptionStubVirtualization; assembler; nostackframe;
asm
  push qword 0
  push qword 20
  jmp CommonInterruptEntry
end;

procedure ExceptionStubControlProtection; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 21
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved22; assembler; nostackframe;
asm
  push qword 0
  push qword 22
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved23; assembler; nostackframe;
asm
  push qword 0
  push qword 23
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved24; assembler; nostackframe;
asm
  push qword 0
  push qword 24
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved25; assembler; nostackframe;
asm
  push qword 0
  push qword 25
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved26; assembler; nostackframe;
asm
  push qword 0
  push qword 26
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved27; assembler; nostackframe;
asm
  push qword 0
  push qword 27
  jmp CommonInterruptEntry
end;

procedure ExceptionStubHypervisorInjection; assembler; nostackframe;
asm
  push qword 0
  push qword 28
  jmp CommonInterruptEntry
end;

procedure ExceptionStubVmmCommunication; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 29
  jmp CommonInterruptEntry
end;

procedure ExceptionStubSecurity; assembler; nostackframe;
asm
  { The processor pushed an error code. }
  push qword 30
  jmp CommonInterruptEntry
end;

procedure ExceptionStubReserved31; assembler; nostackframe;
asm
  push qword 0
  push qword 31
  jmp CommonInterruptEntry
end;

function ExceptionStubAddress(Vector: Byte): Pointer;
begin
  case Vector of
    0: Result := @ExceptionStubDivideError;
    1: Result := @ExceptionStubDebug;
    2: Result := @ExceptionStubNonMaskableInterrupt;
    3: Result := @ExceptionStubBreakpoint;
    4: Result := @ExceptionStubOverflow;
    5: Result := @ExceptionStubBoundRangeExceeded;
    6: Result := @ExceptionStubInvalidOpcode;
    7: Result := @ExceptionStubDeviceNotAvailable;
    8: Result := @ExceptionStubDoubleFault;
    9: Result := @ExceptionStubCoprocessorSegmentOverrun;
    10: Result := @ExceptionStubInvalidTaskState;
    11: Result := @ExceptionStubSegmentNotPresent;
    12: Result := @ExceptionStubStackSegmentFault;
    13: Result := @ExceptionStubGeneralProtection;
    14: Result := @ExceptionStubPageFault;
    15: Result := @ExceptionStubReserved15;
    16: Result := @ExceptionStubFloatingPointError;
    17: Result := @ExceptionStubAlignmentCheck;
    18: Result := @ExceptionStubMachineCheck;
    19: Result := @ExceptionStubSimdFloatingPoint;
    20: Result := @ExceptionStubVirtualization;
    21: Result := @ExceptionStubControlProtection;
    22: Result := @ExceptionStubReserved22;
    23: Result := @ExceptionStubReserved23;
    24: Result := @ExceptionStubReserved24;
    25: Result := @ExceptionStubReserved25;
    26: Result := @ExceptionStubReserved26;
    27: Result := @ExceptionStubReserved27;
    28: Result := @ExceptionStubHypervisorInjection;
    29: Result := @ExceptionStubVmmCommunication;
    30: Result := @ExceptionStubSecurity;
    31: Result := @ExceptionStubReserved31;
  else
    Result := nil;
  end;
end;

end.
