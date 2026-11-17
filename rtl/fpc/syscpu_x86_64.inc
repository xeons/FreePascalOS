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
  The processor specific part of the FreePascalOS System unit, x86-64:
  the system call instruction, the thread control block (%fs), and what a
  processor exception record means for the runtime.
}

function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64; assembler; nostackframe;
asm
  { Our arguments arrive in RDI, RSI, RDX, RCX, R8, R9 and on the stack;
    the kernel wants the number in RAX and the arguments in RDI, RSI,
    RDX, R10, R8, R9. }
  movq %rdi, %rax
  movq %rsi, %rdi
  movq %rdx, %rsi
  movq %rcx, %rdx
  movq %r8, %r10
  movq %r9, %r8
  movq 8(%rsp), %r9
  syscall
end;

{ --- Thread control block (ThreadBlock* in Abi.SystemCalls) ------------- }

{ The thread pointer: the control block's self pointer at %fs:0. }
function ThreadPointer: Pointer; assembler; nostackframe;
asm
  movq %fs:0, %rax
end;

function ReadRuntimeWord: Pointer; assembler; nostackframe;
asm
  movq %fs:8, %rax
end;

procedure WriteRuntimeWord(Value: Pointer); assembler; nostackframe;
asm
  movq %rdi, %fs:8
end;

function KernelThreadId: QWord; assembler; nostackframe;
asm
  movq %fs:16, %rax
end;

{ --- Processor exceptions ------------------------------------------------ }

const
  { Exception flags of the x87 status word and of MXCSR (same order). }
  FloatInvalid = $01;
  FloatDenormal = $02;
  FloatZeroDivide = $04;
  FloatOverflow = $08;
  FloatUnderflow = $10;

function ReadX87StatusWord: Word; assembler; nostackframe;
asm
  fnstsw %ax
end;

{ The runtime error for a floating point exception with these flags. }
function FloatFlagsRuntimeError(Flags: LongWord): LongInt;
begin
  if (Flags and FloatZeroDivide) <> 0 then
    FloatFlagsRuntimeError := 208
  else if (Flags and FloatOverflow) <> 0 then
    FloatFlagsRuntimeError := 205
  else if (Flags and FloatUnderflow) <> 0 then
    FloatFlagsRuntimeError := 206
  else
    FloatFlagsRuntimeError := 207;
end;

{ The runtime error for ExceptionFloatingPoint (x87) or
  ExceptionSimdFloatingPoint (SSE). }
function FloatExceptionRuntimeError(Code: LongWord): LongInt;
begin
  if Code = ExceptionFloatingPoint then
    FloatExceptionRuntimeError := FloatFlagsRuntimeError(ReadX87StatusWord)
  else
    FloatExceptionRuntimeError := FloatFlagsRuntimeError(GetMXCSR);
end;

{ The frame pointer of an exception's context, for the error address. }
function ContextFramePointer(const Context: TAbiContext): Pointer;
begin
  ContextFramePointer := Pointer(Context.Rbp);
end;
