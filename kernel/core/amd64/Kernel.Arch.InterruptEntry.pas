{
  Common interrupt and exception entry path for x86-64.

  Each vector has a tiny stub (see Kernel.Arch.ExceptionStubs and
  Kernel.Arch.DeviceInterruptStubs) that pushes an error code placeholder
  if needed plus the vector number, then jumps here. This code saves the
  remaining registers to complete a TTrapFrame, calls the architecture
  independent dispatcher, restores the registers and returns from the
  interrupt.
}
unit Kernel.Arch.InterruptEntry;

{$mode objfpc}
{$asmmode intel}

interface

procedure CommonInterruptEntry;

implementation

uses
  Kernel.Interrupts;

procedure CommonInterruptEntry; assembler; nostackframe;
asm
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
  iretq
end;

end.
