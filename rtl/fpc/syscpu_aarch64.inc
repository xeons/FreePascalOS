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

{ The thread's dynamic TLS vector (sysdyntls.inc), in the word below the
  control block (ThreadBlockDynamicVectorOffset). }
function ReadDynamicVector: Pointer; assembler; nostackframe;
asm
  mrs x1, tpidr_el0
  sub x1, x1, #8
  ldr x0, [x1]
end;

procedure WriteDynamicVector(Value: Pointer); assembler; nostackframe;
asm
  mrs x1, tpidr_el0
  sub x1, x1, #8
  str x0, [x1]
end;

{ The resolver of TLS descriptors (R_AARCH64_TLSDESC): the kernel lays
  thread-local storage out statically, so a descriptor's second word is
  already the variable's offset from the thread pointer. Called with X0
  = the descriptor; must keep every other register. }
procedure ResolveStaticTlsDescriptor; assembler; nostackframe; [public, alias: '__tlsdesc_static'];
asm
  ldr x0, [x0, #8]
end;

function ResolveDynamicTlsDescriptor(Argument: QWord): PtrUInt; forward;

{ The resolver of TLS descriptors of libraries loaded after the program
  started (dynamic TLS, sysdyntls.inc). The descriptor's second word is
  TlsDynamicModuleTag + (module handle shl 32) + the variable's offset in
  the module's block; the result is the variable's address minus the
  thread pointer. Called with X0 = the descriptor; must keep every other
  register but the flags. The thread's vector entry (indexed by the
  handle) is found here; only a thread's first access to a library
  makes the block, in Pascal, around which every register the procedure
  call standard lets it change is saved (the vector registers encoded by
  hand: the assembler does not take Q register pairs). }
procedure ResolveDynamicTlsDescriptorEntry; assembler; nostackframe; [public, alias: '__tlsdesc_dynamic'];
asm
  ldr x0, [x0, #8]
  stp x1, x2, [sp, #-32]!
  str x3, [sp, #16]
  mrs x1, tpidr_el0
  sub x1, x1, #8
  ldr x2, [x1]
  cbz x2, .LMakeBlock
  lsr x3, x0, #32
  and x3, x3, #0xFFFFFF
  ldr x1, [x2]
  cmp x3, x1
  b.hs .LMakeBlock
  add x2, x2, x3, lsl #3
  ldr x2, [x2, #8]
  cbz x2, .LMakeBlock
  mov w0, w0
  add x0, x2, x0
  mrs x1, tpidr_el0
  sub x0, x0, x1
  ldr x3, [sp, #16]
  ldp x1, x2, [sp], #32
  ret
.LMakeBlock:
  ldr x3, [sp, #16]
  ldp x1, x2, [sp], #32
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #672
  stp x1, x2, [sp, #0]
  stp x3, x4, [sp, #16]
  stp x5, x6, [sp, #32]
  stp x7, x8, [sp, #48]
  stp x9, x10, [sp, #64]
  stp x11, x12, [sp, #80]
  stp x13, x14, [sp, #96]
  stp x15, x16, [sp, #112]
  stp x17, x18, [sp, #128]
  .long 0xAD0507E0 { stp q0, q1, [sp, #160] }
  .long 0xAD060FE2 { stp q2, q3, [sp, #192] }
  .long 0xAD0717E4 { stp q4, q5, [sp, #224] }
  .long 0xAD081FE6 { stp q6, q7, [sp, #256] }
  .long 0xAD0927E8 { stp q8, q9, [sp, #288] }
  .long 0xAD0A2FEA { stp q10, q11, [sp, #320] }
  .long 0xAD0B37EC { stp q12, q13, [sp, #352] }
  .long 0xAD0C3FEE { stp q14, q15, [sp, #384] }
  .long 0xAD0D47F0 { stp q16, q17, [sp, #416] }
  .long 0xAD0E4FF2 { stp q18, q19, [sp, #448] }
  .long 0xAD0F57F4 { stp q20, q21, [sp, #480] }
  .long 0xAD105FF6 { stp q22, q23, [sp, #512] }
  .long 0xAD1167F8 { stp q24, q25, [sp, #544] }
  .long 0xAD126FFA { stp q26, q27, [sp, #576] }
  .long 0xAD1377FC { stp q28, q29, [sp, #608] }
  .long 0xAD147FFE { stp q30, q31, [sp, #640] }
  bl ResolveDynamicTlsDescriptor
  mrs x1, tpidr_el0
  sub x0, x0, x1
  .long 0xAD4507E0 { ldp q0, q1, [sp, #160] }
  .long 0xAD460FE2 { ldp q2, q3, [sp, #192] }
  .long 0xAD4717E4 { ldp q4, q5, [sp, #224] }
  .long 0xAD481FE6 { ldp q6, q7, [sp, #256] }
  .long 0xAD4927E8 { ldp q8, q9, [sp, #288] }
  .long 0xAD4A2FEA { ldp q10, q11, [sp, #320] }
  .long 0xAD4B37EC { ldp q12, q13, [sp, #352] }
  .long 0xAD4C3FEE { ldp q14, q15, [sp, #384] }
  .long 0xAD4D47F0 { ldp q16, q17, [sp, #416] }
  .long 0xAD4E4FF2 { ldp q18, q19, [sp, #448] }
  .long 0xAD4F57F4 { ldp q20, q21, [sp, #480] }
  .long 0xAD505FF6 { ldp q22, q23, [sp, #512] }
  .long 0xAD5167F8 { ldp q24, q25, [sp, #544] }
  .long 0xAD526FFA { ldp q26, q27, [sp, #576] }
  .long 0xAD5377FC { ldp q28, q29, [sp, #608] }
  .long 0xAD547FFE { ldp q30, q31, [sp, #640] }
  ldp x1, x2, [sp, #0]
  ldp x3, x4, [sp, #16]
  ldp x5, x6, [sp, #32]
  ldp x7, x8, [sp, #48]
  ldp x9, x10, [sp, #64]
  ldp x11, x12, [sp, #80]
  ldp x13, x14, [sp, #96]
  ldp x15, x16, [sp, #112]
  ldp x17, x18, [sp, #128]
  add sp, sp, #672
  ldp x29, x30, [sp], #16
  ret
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
  processors trap floating point exceptions: programs are compiled with
  -CE, so the compiler checks FPSR after floating point operations and
  FPC_THROWFPUEXCEPTION (rtl/aarch64/aarch64.inc) raises the unmasked
  ones; this is for processors that do trap. }
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
