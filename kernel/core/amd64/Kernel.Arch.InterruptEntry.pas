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
  Common interrupt and exception entry path for x86-64.

  Each vector has a tiny stub (see Kernel.Arch.ExceptionStubs and
  Kernel.Arch.DeviceInterruptStubs) that pushes an error code placeholder
  if needed plus the vector number, then jumps here. This code saves the
  remaining registers to complete a TTrapFrame, calls the architecture
  independent dispatcher, restores the registers and returns from the
  interrupt.

  An interrupt from user mode swaps in the kernel's GS base on the way in
  and the user's on the way out (Kernel.Arch.ProcessorBlock); the saved
  code selector says where the interrupt came from.

  An NMI or machine check can arrive anywhere, also between SYSCALL and
  its SWAPGS (or between the SWAPGS and IRETQ on the way back): there the
  saved code selector says kernel while GS still holds the user's base.
  For those two vectors the entry looks at the GS base itself (its
  MSR): a user base (the kernel's has bit 63 set; a program cannot set
  one in the kernel half) is swapped, which the vector's (unused) error
  code slot remembers for the way out.

  With SMAP on, an interrupt in the middle of a user copy arrives with
  RFLAGS.AC set (the copy's window to user memory); the entry clears it
  (CLAC), so the handler runs with user memory protected. IRETQ gives
  the copy its flags back.
}
unit Kernel.Arch.InterruptEntry;

{$mode objfpc}
{$asmmode intel}

interface

procedure CommonInterruptEntry;

implementation

uses
  Kernel.Interrupts;

const
  VectorNonMaskableInterrupt = 2;
  VectorMachineCheck = 18;
  MsrGsBase = $C0000101;

var
  SmapEnabled: Byte; external name 'ArchSmapEnabled';

procedure CommonInterruptEntry; assembler; nostackframe;
asm
  { Stack: vector, error code, RIP, CS (+24), ... }
  cmp qword ptr [rsp], VectorNonMaskableInterrupt
  je @CheckGsBase
  cmp qword ptr [rsp], VectorMachineCheck
  je @CheckGsBase
  test byte ptr [rsp + 24], 3
  jz @FromKernel
  db $0F, $01, $F8 { swapgs }
  jmp @FromKernel
@CheckGsBase:
  push rax
  push rcx
  push rdx
  mov ecx, MsrGsBase
  rdmsr
  { Stack: rdx, rcx, rax, vector, error code (+32). }
  mov qword ptr [rsp + 32], 0
  test edx, edx
  js @GsBaseChecked
  db $0F, $01, $F8 { swapgs }
  mov qword ptr [rsp + 32], 1
@GsBaseChecked:
  pop rdx
  pop rcx
  pop rax
@FromKernel:
  push rax
  push rbx
  push rcx
  push rdx
  push rsi
  push rdi
  push rbp
  push r8
  push r9
  push r10
  push r11
  push r12
  push r13
  push r14
  push r15

  { The processor aligns the stack to 16 bytes before pushing its frame.
    Five processor values, two stub values and fifteen registers are 22
    quadwords, so the stack is still 16-byte aligned for the call. }
  mov rdi, rsp
  cld
  cmp byte ptr [rip + SmapEnabled], 0
  je @UserMemoryClosed
  db $0F, $01, $CA { clac }
@UserMemoryClosed:
  call DispatchInterrupt

  pop r15
  pop r14
  pop r13
  pop r12
  pop r11
  pop r10
  pop r9
  pop r8
  pop rbp
  pop rdi
  pop rsi
  pop rdx
  pop rcx
  pop rbx
  pop rax

  { An NMI or machine check swapped GS if its error code slot says so. }
  cmp qword ptr [rsp], VectorNonMaskableInterrupt
  je @RestoreCheckedGsBase
  cmp qword ptr [rsp], VectorMachineCheck
  je @RestoreCheckedGsBase
  { Discard the vector number and error code. }
  add rsp, 16
  { Stack: RIP, CS (+8), ... }
  test byte ptr [rsp + 8], 3
  jz @ToKernel
  db $0F, $01, $F8 { swapgs }
@ToKernel:
  iretq
@RestoreCheckedGsBase:
  cmp qword ptr [rsp + 8], 0
  lea rsp, [rsp + 16]
  je @ToKernel
  db $0F, $01, $F8 { swapgs }
  iretq
end;

end.
