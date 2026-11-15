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
  Saving a processor's state across suspend to RAM.

  ArchSaveSuspendContext works like setjmp: it saves what the caller
  needs kept (the callee-saved registers, the stack pointer, where to
  return, the flags), the FS base and the swapped GS base (user thread
  pointers), and the floating point and SSE registers, then returns 0.
  ArchResumeSuspendContext, on the same processor after it was woken and
  set up again, puts all of it back and returns from the saving call a
  second time, with 1. Memory survives suspend to RAM, so the stack the
  context points into is still there.
}
unit Kernel.Arch.Suspend;

{$mode objfpc}
{$asmmode intel}

interface

type
  TArchSuspendContext = record
    { rbx, rbp, r12-r15, rsp, rip, rflags, FS base, swapped GS base. }
    Registers: array[0..11] of QWord;
    { FXSAVE needs 512 bytes, 16-byte aligned: the area is found inside. }
    FpuArea: array[0..527] of Byte;
  end;
  PArchSuspendContext = ^TArchSuspendContext;

{ 0 when saving, 1 when resumed. Call with interrupts disabled. }
function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord;
{ Never returns: the saving call returns again. }
procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);

implementation

function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord; assembler; nostackframe;
asm
  mov [rdi], rbx
  mov [rdi + 8], rbp
  mov [rdi + 16], r12
  mov [rdi + 24], r13
  mov [rdi + 32], r14
  mov [rdi + 40], r15
  { The stack pointer as it will be after returning, and where to. }
  lea rax, [rsp + 8]
  mov [rdi + 48], rax
  mov rax, [rsp]
  mov [rdi + 56], rax
  pushfq
  pop rax
  mov [rdi + 64], rax
  mov rsi, rdi
  mov ecx, $C0000100
  rdmsr
  mov [rsi + 72], eax
  mov [rsi + 76], edx
  mov ecx, $C0000102
  rdmsr
  mov [rsi + 80], eax
  mov [rsi + 84], edx
  lea rax, [rsi + 96 + 15]
  and rax, -16
  fxsave [rax]
  xor eax, eax
end;

procedure ArchResumeSuspendContext(var Context: TArchSuspendContext); assembler; nostackframe;
asm
  lea rax, [rdi + 96 + 15]
  and rax, -16
  fxrstor [rax]
  mov ecx, $C0000100
  mov eax, [rdi + 72]
  mov edx, [rdi + 76]
  wrmsr
  mov ecx, $C0000102
  mov eax, [rdi + 80]
  mov edx, [rdi + 84]
  wrmsr
  mov rbx, [rdi]
  mov rbp, [rdi + 8]
  mov r12, [rdi + 16]
  mov r13, [rdi + 24]
  mov r14, [rdi + 32]
  mov r15, [rdi + 40]
  mov rsp, [rdi + 48]
  push qword ptr [rdi + 64]
  popfq
  mov eax, 1
  jmp qword ptr [rdi + 56]
end;

end.
