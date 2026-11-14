{
  Final transfer of control from the loader to the kernel on x86-64.
}
unit Loader.Arch.Handoff;

{$mode objfpc}
{$asmmode intel}

interface

uses
  Elf64;

const
  KernelElfMachine = ElfMachineAmd64;

{ Switches to the kernel page tables and stack, then jumps to the kernel
  entry point with BootInformation as its only argument. Never returns.

  The loader uses the Microsoft x64 calling convention (arguments in RCX,
  RDX, R8, R9) while the kernel uses the System V convention (first
  argument in RDI), so the argument is moved explicitly. }
procedure TransferControlToKernel(PageTableRoot: QWord; StackTop: QWord;
  BootInformation: QWord; EntryPoint: QWord);

implementation

procedure TransferControlToKernel(PageTableRoot: QWord; StackTop: QWord;
  BootInformation: QWord; EntryPoint: QWord); assembler; nostackframe;
asm
  cli
  mov cr3, rcx
  mov rsp, rdx
  xor rbp, rbp
  mov rdi, r8

  { Push a null return address so the kernel entry point sees the stack
    alignment it would after a normal call, and so stack traces end here. }
  push qword 0
  jmp r9
end;

end.
