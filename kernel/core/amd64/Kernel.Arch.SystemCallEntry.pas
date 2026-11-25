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

  The kernel stack and a place to park the user stack pointer while
  switching are in the processor's block, reached through GS after
  SWAPGS (Kernel.Arch.ProcessorBlock).
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
{ Programs the executing processor's system call registers (each
  processor has its own; InitializeSystemCallEntry does the boot one). }
procedure EnableSystemCallsOnThisProcessor;

{ Sets the kernel stack the next system call switches to. }
procedure SetSystemCallKernelStack(StackTop: QWord);

{ Accessors for the call number, arguments and result in a frame. }
function SystemCallNumber(Frame: PTrapFrame): QWord;
function SystemCallArgument(Frame: PTrapFrame; Index: Integer): QWord;
procedure SetSystemCallResult(Frame: PTrapFrame; Value: Int64);
{ Makes the thread make its system call again when it returns to user
  mode: back to the syscall instruction, with the call number (which the
  result replaced) given back. }
procedure RewindSystemCall(Frame: PTrapFrame; Number, Argument0: QWord);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.ProcessorBlock,
  Kernel.Processors;

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
  RegisteredHandler: TSystemCallHandler;

procedure DispatchSystemCall(Frame: PTrapFrame);
begin
  RegisteredHandler(Frame);
end;

procedure SystemCallEntry; assembler; nostackframe;
asm
  db $0F, $01, $F8 { swapgs }
  mov qword ptr gs:[ProcessorUserStackScratchOffset], rsp
  mov rsp, qword ptr gs:[ProcessorSystemCallStackOffset]

  { The same frame shape an interrupt from user mode produces. }
  push qword UserDataSelector
  push qword ptr gs:[ProcessorUserStackScratchOffset]
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
  db $0F, $01, $F8 { swapgs }
  iretq
end;

procedure InitializeSystemCallEntry(Handler: TSystemCallHandler);
begin
  RegisteredHandler := Handler;
  EnableSystemCallsOnThisProcessor;
end;

procedure EnableSystemCallsOnThisProcessor;
begin
  WriteModelSpecificRegister(MsrExtendedFeatureEnable,
    ReadModelSpecificRegister(MsrExtendedFeatureEnable) or EferSystemCallEnable);
  WriteModelSpecificRegister(MsrStar,
    (QWord(KernelCodeSelector) shl 32) or (QWord(UserSelectorBase) shl 48));
  WriteModelSpecificRegister(MsrLongModeTarget, QWord(@SystemCallEntry));
  WriteModelSpecificRegister(MsrFlagMask, EntryFlagMask);
end;

procedure SetSystemCallKernelStack(StackTop: QWord);
begin
  CurrentProcessor^.SystemCallStack := StackTop;
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

procedure RewindSystemCall(Frame: PTrapFrame; Number, Argument0: QWord);
const
  SyscallLength = 2;
begin
  Frame^.Rip := Frame^.Rip - SyscallLength;
  Frame^.Rax := Number;
  { The arguments are in registers the call left alone. }
end;

end.
