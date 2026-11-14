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
