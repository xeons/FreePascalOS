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
  iretq
end;

function ArchFrameIsFromUserMode(Frame: PTrapFrame): Boolean;
begin
  Result := (Frame^.Cs and PrivilegeLevelMask) = PrivilegeLevelMask;
end;

end.
