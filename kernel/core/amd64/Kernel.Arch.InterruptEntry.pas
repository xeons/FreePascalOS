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

var
  SmapEnabled: Byte; external name 'ArchSmapEnabled';

procedure CommonInterruptEntry; assembler; nostackframe;
asm
  { Stack: vector, error code, RIP, CS (+24), ... }
  test byte ptr [rsp + 24], 3
  jz @FromKernel
  db $0F, $01, $F8 { swapgs }
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

  { Discard the vector number and error code. }
  add rsp, 16
  { Stack: RIP, CS (+8), ... }
  test byte ptr [rsp + 8], 3
  jz @ToKernel
  db $0F, $01, $F8 { swapgs }
@ToKernel:
  iretq
end;

end.
