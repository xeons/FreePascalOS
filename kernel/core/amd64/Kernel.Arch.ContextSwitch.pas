{
  Thread context switching for x86-64.

  A switch only needs to preserve what the System V calling convention
  says a called function must preserve (RBX, RBP, R12-R15), plus the
  flags register so the interrupt flag travels with the thread. Everything
  else was either already saved by the caller or lives in the interrupt
  frame on the thread's own stack.

  The saved state sits on top of the thread's stack, in this order from
  the lowest address up:

    RFLAGS, R15, R14, R13, R12, RBX, RBP, return address
}
unit Kernel.Arch.ContextSwitch;

{$mode objfpc}
{$asmmode intel}

interface

{ Saves the current thread's state on its stack, stores its stack pointer
  in SavedStackPointer, then resumes the thread whose state is on top of
  NewStackPointer. Returns when the original thread is resumed again. }
procedure ArchSwitchContext(SavedStackPointer: PQWord; NewStackPointer: QWord);

{ Lays out a fresh stack so that switching to it starts EntryPoint with
  interrupts disabled. Returns the initial saved stack pointer. EntryPoint
  must never return. }
function ArchPrepareInitialStack(StackTop: QWord; EntryPoint: Pointer): QWord;

{ Tells the processor which stack to use for interrupts that arrive while
  the given thread is running in user mode. }
procedure ArchSetThreadInterruptStack(StackTop: QWord);

implementation

uses
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.SystemCallEntry;

const
  InitialFlags = QWord($2); { bit 1 is always set; interrupts disabled }

procedure ArchSwitchContext(SavedStackPointer: PQWord; NewStackPointer: QWord); assembler; nostackframe;
asm
  push rbp
  push rbx
  push r12
  push r13
  push r14
  push r15
  pushfq

  mov [rdi], rsp
  mov rsp, rsi

  popfq
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  pop rbp
end;

function ArchPrepareInitialStack(StackTop: QWord; EntryPoint: Pointer): QWord;
var
  Slot: PQWord;
begin
  { The stack top is 16-byte aligned. After the switch "returns" into
    EntryPoint the stack pointer sits on the fake return address below,
    which is the alignment a function expects right after a call. }
  Slot := PQWord(StackTop);

  Dec(Slot);
  Slot^ := 0;                  { fake return address of EntryPoint }
  Dec(Slot);
  Slot^ := QWord(EntryPoint);  { where the switch returns to }
  Dec(Slot);
  Slot^ := 0;                  { RBP }
  Dec(Slot);
  Slot^ := 0;                  { RBX }
  Dec(Slot);
  Slot^ := 0;                  { R12 }
  Dec(Slot);
  Slot^ := 0;                  { R13 }
  Dec(Slot);
  Slot^ := 0;                  { R14 }
  Dec(Slot);
  Slot^ := 0;                  { R15 }
  Dec(Slot);
  Slot^ := InitialFlags;       { RFLAGS }

  Result := QWord(Slot);
end;

procedure ArchSetThreadInterruptStack(StackTop: QWord);
begin
  SetInterruptKernelStack(StackTop);
  SetSystemCallKernelStack(StackTop);
end;

end.
