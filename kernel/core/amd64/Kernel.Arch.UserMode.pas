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
  Entering user mode on x86-64.

  A thread enters user mode for the first time by "returning" from an
  interrupt frame built by hand: the user code and stack selectors, the
  entry point, the user stack and flags with interrupts enabled.
}
unit Kernel.Arch.UserMode;

{$mode objfpc}
{$asmmode intel}

interface

uses
  Kernel.Arch.TrapFrame;

{ Starts executing user code at EntryPoint with the given stack. Argument
  is passed in the first argument register (RDI); all other general
  purpose registers start out zero. Never returns. }
procedure ArchEnterUserMode(EntryPoint: QWord; StackPointer: QWord; Argument: QWord);
{ Starts executing user code with every register of Context (a
  TAbiContext in kernel memory): the child of fork. Of RFLAGS only the
  arithmetic and direction flags are taken. Never returns. }
procedure ArchEnterUserModeWithContext(Context: Pointer);

function ArchFrameIsFromUserMode(Frame: PTrapFrame): Boolean;

implementation

uses
  Kernel.Arch.DescriptorTables;

const
  UserInitialFlags = $202; { interrupts enabled, reserved bit 1 }
  PrivilegeLevelMask = 3;

procedure ArchEnterUserMode(EntryPoint: QWord; StackPointer: QWord; Argument: QWord); assembler; nostackframe;
asm
  cli
  push qword UserDataSelector
  push rsi
  push dword UserInitialFlags { a 64-bit push of a sign-extended 32-bit immediate }
  push qword UserCodeSelector
  push rdi
  mov r11, rdx

  xor eax, eax
  xor ebx, ebx
  xor ecx, ecx
  xor edx, edx
  xor esi, esi
  mov rdi, r11
  xor ebp, ebp
  xor r8d, r8d
  xor r9d, r9d
  xor r10d, r10d
  xor r11d, r11d
  xor r12d, r12d
  xor r13d, r13d
  xor r14d, r14d
  xor r15d, r15d
  { Hand GS back to user mode (Kernel.Arch.ProcessorBlock). }
  db $0F, $01, $F8 { swapgs }
  iretq
end;

{ TAbiContext: RAX, RBX, RCX, RDX, RSI, RDI, RBP, RSP, R8-R15, RIP,
  RFLAGS, 8 bytes each. }
procedure ArchEnterUserModeWithContext(Context: Pointer); assembler; nostackframe;
asm
  cli
  push qword UserDataSelector
  push qword [rdi + 56]
  mov rax, [rdi + 136]
  and rax, $0CD5
  or rax, UserInitialFlags
  push rax
  push qword UserCodeSelector
  push qword [rdi + 128]
  mov rax, [rdi]
  mov rbx, [rdi + 8]
  mov rcx, [rdi + 16]
  mov rdx, [rdi + 24]
  mov rsi, [rdi + 32]
  mov rbp, [rdi + 48]
  mov r8, [rdi + 64]
  mov r9, [rdi + 72]
  mov r10, [rdi + 80]
  mov r11, [rdi + 88]
  mov r12, [rdi + 96]
  mov r13, [rdi + 104]
  mov r14, [rdi + 112]
  mov r15, [rdi + 120]
  mov rdi, [rdi + 40]
  { Hand GS back to user mode (Kernel.Arch.ProcessorBlock). }
  db $0F, $01, $F8 { swapgs }
  iretq
end;

function ArchFrameIsFromUserMode(Frame: PTrapFrame): Boolean;
begin
  Result := (Frame^.Cs and PrivilegeLevelMask) = PrivilegeLevelMask;
end;

end.
