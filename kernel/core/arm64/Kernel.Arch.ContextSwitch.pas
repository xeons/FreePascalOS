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
  Thread context switching for AArch64 (the switch itself is in
  ContextSwitch.s).
}
unit Kernel.Arch.ContextSwitch;

{$mode objfpc}
{$pointermath on}

interface

const
  { V0-V31, FPCR and FPSR. }
  ArchFpuStateSize = 528;

{ Saves the current thread's state on its stack, stores its stack pointer
  in SavedStackPointer, then resumes the thread whose state is on top of
  NewStackPointer. Returns when the original thread is resumed again. }
procedure ArchSwitchContext(SavedStackPointer: PQWord; NewStackPointer: QWord);
  external name 'ArchSwitchContext';

{ Lays out a fresh stack so that switching to it starts EntryPoint with
  interrupts disabled. Returns the initial saved stack pointer. EntryPoint
  must never return. }
function ArchPrepareInitialStack(StackTop: QWord; EntryPoint: Pointer): QWord;

{ The kernel stack the processor is on when it next leaves user mode:
  the running thread's (SP_EL1 is reset to it on every return to user
  mode, Kernel.Arch.UserMode). }
procedure ArchSetThreadInterruptStack(StackTop: QWord);

{ Where a thread that is not running stopped, from the state the switch
  saved on its stack (SavedStackPointer): the address it resumes at and
  its frame pointer, so its back trace can be walked. }
procedure ArchSwitchFramePointers(SavedStackPointer: QWord; out ProgramCounter, FramePointer: QWord);

{ Loads the user thread pointer: TPIDR_EL0, which user code reads for
  its thread-local storage. }
procedure ArchSetUserThreadPointer(ThreadPointer: QWord);

{ Floating point and SIMD registers. The kernel itself uses none (the
  build checks), so they only change hands at a thread switch. }
procedure ArchInitializeFpuState(Area: Pointer);
procedure ArchSaveFpuState(Area: Pointer); external name 'ArchSaveFpuState';
procedure ArchRestoreFpuState(Area: Pointer); external name 'ArchRestoreFpuState';

implementation

uses
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Arch.SystemCallEntry;

const
  SwitchFrameSize = 112;
  SavedFramePointerSlot = 10;
  SavedLinkRegisterSlot = 11;
  SavedInterruptMaskSlot = 12;
  { D, A, I and F masked. }
  InitialInterruptMask = QWord($3C0);

procedure ArchWriteUserThreadPointer(ThreadPointer: QWord); external name 'ArchWriteUserThreadPointer';

procedure ArchSwitchFramePointers(SavedStackPointer: QWord; out ProgramCounter, FramePointer: QWord);
begin
  FramePointer := PQWord(SavedStackPointer)[SavedFramePointerSlot];
  ProgramCounter := PQWord(SavedStackPointer)[SavedLinkRegisterSlot];
end;

function ArchPrepareInitialStack(StackTop: QWord; EntryPoint: Pointer): QWord;
var
  Frame: PQWord;
begin
  { After the switch "returns" into EntryPoint the stack pointer is
    StackTop again, 16-byte aligned as a routine expects. X29 = 0 ends
    stack traces. }
  Frame := PQWord(StackTop - SwitchFrameSize);
  ZeroMemory(Frame, SwitchFrameSize);
  Frame[SavedLinkRegisterSlot] := QWord(EntryPoint);
  Frame[SavedInterruptMaskSlot] := InitialInterruptMask;
  Result := QWord(Frame);
end;

procedure ArchInitializeFpuState(Area: Pointer);
begin
  { All registers zero, FPCR zero: round to nearest, exceptions not
    trapped. }
  ZeroMemory(Area, ArchFpuStateSize);
end;

procedure ArchSetUserThreadPointer(ThreadPointer: QWord);
begin
  ArchWriteUserThreadPointer(ThreadPointer);
end;

procedure ArchSetThreadInterruptStack(StackTop: QWord);
begin
  SetSystemCallKernelStack(StackTop);
end;

end.
