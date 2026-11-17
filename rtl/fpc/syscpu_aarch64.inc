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
  The processor specific part of the FreePascalOS System unit, AArch64:
  the system call instruction, the thread control block (TPIDR_EL0), and
  what a processor exception record means for the runtime.
}

function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64; assembler; nostackframe;
asm
  { Our arguments arrive in X0-X6; the kernel wants the number in X8 and
    the arguments in X0-X5. }
  mov x8, x0
  mov x0, x1
  mov x1, x2
  mov x2, x3
  mov x3, x4
  mov x4, x5
  mov x5, x6
  svc #0
end;

{ --- Thread control block (ThreadBlock* in Abi.SystemCalls) ------------- }

{ The thread pointer: TPIDR_EL0, which points at the control block. }
function ThreadPointer: Pointer; assembler; nostackframe;
asm
  mrs x0, tpidr_el0
end;

{ The runtime word is at offset 0, the thread id at offset 8. }
function ReadRuntimeWord: Pointer; assembler; nostackframe;
asm
  mrs x1, tpidr_el0
  ldr x0, [x1]
end;

procedure WriteRuntimeWord(Value: Pointer); assembler; nostackframe;
asm
  mrs x1, tpidr_el0
  str x0, [x1]
end;

function KernelThreadId: QWord; assembler; nostackframe;
asm
  mrs x1, tpidr_el0
  ldr x0, [x1, #8]
end;

{ The resolver of TLS descriptors (R_AARCH64_TLSDESC): the kernel lays
  thread-local storage out statically, so a descriptor's second word is
  already the variable's offset from the thread pointer. Called with X0
  = the descriptor; must keep every other register. }
procedure ResolveStaticTlsDescriptor; assembler; nostackframe; [public, alias: '__tlsdesc_static'];
asm
  ldr x0, [x0, #8]
end;

{ --- Processor exceptions ------------------------------------------------ }

const
  { The cumulative exception flags of FPSR. }
  FloatInvalid = $01;
  FloatZeroDivide = $02;
  FloatOverflow = $04;
  FloatUnderflow = $08;

function ReadFloatStatus: QWord; assembler; nostackframe;
asm
  mrs x0, fpsr
end;

{ The runtime error for a floating point exception. Few AArch64
  processors trap floating point exceptions (the compiler checks FPSR
  after floating point operations instead), so this is for those that
  do. }
function FloatExceptionRuntimeError(Code: LongWord): LongInt;
var
  Flags: QWord;
begin
  Flags := ReadFloatStatus;
  if (Flags and FloatZeroDivide) <> 0 then
    FloatExceptionRuntimeError := 208
  else if (Flags and FloatOverflow) <> 0 then
    FloatExceptionRuntimeError := 205
  else if (Flags and FloatUnderflow) <> 0 then
    FloatExceptionRuntimeError := 206
  else
    FloatExceptionRuntimeError := 207;
end;

{ The frame pointer (X29) of an exception's context, for the error
  address. }
function ContextFramePointer(const Context: TAbiContext): Pointer;
begin
  ContextFramePointer := Pointer(Context.X[29]);
end;
