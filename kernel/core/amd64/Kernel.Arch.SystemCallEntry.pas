{
  System call entry for x86-64.

  User programs enter the kernel with the "syscall" instruction. The
  processor then jumps to SystemCallEntry with interrupts masked (through
  the flag mask), the user's return address in RCX and flags in R11, but
  still on the user's stack. The entry code switches to the thread's
  kernel stack, builds a TTrapFrame like the interrupt entry does, and
  calls the registered handler with interrupts enabled.

  Returning uses "iretq" rather than "sysretq": it restores everything
  from the frame in one well defined step and avoids sysret's pitfalls
  with non-canonical return addresses.

  This kernel runs on one processor, so the user stack pointer is parked
  in a global while switching stacks; with several processors it would
  live in per-processor data.
}
unit Kernel.Arch.SystemCallEntry;

{$mode objfpc}
{$asmmode intel}

interface

uses
  Kernel.Arch.TrapFrame;

type
  TSystemCallHandler = procedure(Frame: PTrapFrame);

procedure InitializeSystemCallEntry(Handler: TSystemCallHandler);

{ Sets the kernel stack the next system call switches to. }
procedure SetSystemCallKernelStack(StackTop: QWord);

{ Accessors for the call number, arguments and result in a frame. }
function SystemCallNumber(Frame: PTrapFrame): QWord;
function SystemCallArgument(Frame: PTrapFrame; Index: Integer): QWord;
procedure SetSystemCallResult(Frame: PTrapFrame; Value: Int64);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables;

const
  MsrStar = $C0000081;
  MsrLongModeTarget = $C0000082;
  MsrFlagMask = $C0000084;
  EferSystemCallEnable = QWord(1) shl 0;

  { Cleared on entry: trap, interrupt, direction, I/O privilege, nested
    task and alignment check flags. }
  EntryFlagMask = $47700;

  { sysret (not used for returning, but the layout must still be right)
    takes the user selectors from STAR[63:48]: SS = base + 8, CS = base + 16. }
  UserSelectorBase = UserDataSelector - 8;

var
  SystemCallKernelStack: QWord;
  UserStackScratch: QWord;
  RegisteredHandler: TSystemCallHandler;

procedure DispatchSystemCall(Frame: PTrapFrame);
begin
  RegisteredHandler(Frame);
end;

procedure SystemCallEntry; assembler; nostackframe;
asm
  mov [rip + UserStackScratch], rsp
  mov rsp, [rip + SystemCallKernelStack]

  { The same frame shape an interrupt from user mode produces. }
  push qword UserDataSelector
  push qword ptr [rip + UserStackScratch]
  push r11
  push qword UserCodeSelector
  push rcx
  push qword 0  { error code slot }
  push qword 0  { vector slot }

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

  mov rdi, rsp
  cld
  sti
  call DispatchSystemCall
  cli

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
  add rsp, 16
  iretq
end;

procedure InitializeSystemCallEntry(Handler: TSystemCallHandler);
begin
  RegisteredHandler := Handler;
  WriteModelSpecificRegister(MsrExtendedFeatureEnable,
    ReadModelSpecificRegister(MsrExtendedFeatureEnable) or EferSystemCallEnable);
  WriteModelSpecificRegister(MsrStar,
    (QWord(KernelCodeSelector) shl 32) or (QWord(UserSelectorBase) shl 48));
  WriteModelSpecificRegister(MsrLongModeTarget, QWord(@SystemCallEntry));
  WriteModelSpecificRegister(MsrFlagMask, EntryFlagMask);
end;

procedure SetSystemCallKernelStack(StackTop: QWord);
begin
  SystemCallKernelStack := StackTop;
end;

function SystemCallNumber(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.Rax;
end;

function SystemCallArgument(Frame: PTrapFrame; Index: Integer): QWord;
begin
  case Index of
    0: Result := Frame^.Rdi;
    1: Result := Frame^.Rsi;
    2: Result := Frame^.Rdx;
    3: Result := Frame^.R10;
    4: Result := Frame^.R8;
    5: Result := Frame^.R9;
  else
    Result := 0;
  end;
end;

procedure SetSystemCallResult(Frame: PTrapFrame; Value: Int64);
begin
  Frame^.Rax := QWord(Value);
end;

end.
