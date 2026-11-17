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
  A program's register context on AArch64, for passing processor
  exceptions to it (Processes.UserExceptions).

  The exception record's context (TAbiContext) is x86-64's register set
  so far; until the AArch64 user mode ABI gives it AArch64's (X0-X30,
  SP, PC, PSTATE: the next phase of the port), the record carries X0-X15
  in the places of RAX-R15, SP, PC and PSTATE, and a program cannot
  continue at a context (CallContinue fails with ErrorUnsupported).
}
unit Processes.Arch.UserContext;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.Arch.TrapFrame;

const
  { AAPCS64 has no red zone. }
  UserStackRedZoneSize = 0;

{ The Abi code for a frame's exception vector, 0 for one not passed on. }
function ExceptionCodeOfFrame(Frame: PTrapFrame): LongWord;
{ The final code, once interrupts are enabled (no change on AArch64). }
function RefineExceptionCode(Frame: PTrapFrame; Code: LongWord): LongWord;

function FrameIsPageFault(Frame: PTrapFrame): Boolean;
{ AccessKind* of a page fault. }
function PageFaultAccessKind(Frame: PTrapFrame): LongWord;

procedure CaptureUserContext(Frame: PTrapFrame; out Context: TAbiContext);
{ Not supported yet (see above): ErrorUnsupported. }
function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;

{ Makes the thread continue in Dispatcher with the record's address in X0
  and the stack pointer at RecordAddress (16-byte aligned), with a null
  link register, as if called. }
procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.Exceptions;

const
  LinkRegister = 30;

function ExceptionCodeOfFrame(Frame: PTrapFrame): LongWord;
begin
  case TrapFrameVector(Frame) of
    VectorUndefinedInstruction: Result := ExceptionIllegalInstruction;
    VectorBreakpoint: Result := ExceptionBreakpoint;
    VectorPageFault, VectorExternalAbort: Result := ExceptionAccessViolation;
    VectorAlignmentFault: Result := ExceptionAlignment;
    VectorFloatingPoint: Result := ExceptionSimdFloatingPoint;
    VectorPrivilegedOperation: Result := ExceptionPrivilegedOperation;
  else
    Result := 0;
  end;
end;

function RefineExceptionCode(Frame: PTrapFrame; Code: LongWord): LongWord;
begin
  Result := Code;
end;

function FrameIsPageFault(Frame: PTrapFrame): Boolean;
begin
  Result := TrapFrameVector(Frame) = VectorPageFault;
end;

function PageFaultAccessKind(Frame: PTrapFrame): LongWord;
begin
  if (Frame^.ErrorCode and PageFaultInstructionFetch) <> 0 then
    Result := AccessKindExecute
  else if (Frame^.ErrorCode and PageFaultWrite) <> 0 then
    Result := AccessKindWrite
  else
    Result := AccessKindRead;
end;

procedure CaptureUserContext(Frame: PTrapFrame; out Context: TAbiContext);
begin
  Context.Rax := Frame^.X[0];
  Context.Rbx := Frame^.X[1];
  Context.Rcx := Frame^.X[2];
  Context.Rdx := Frame^.X[3];
  Context.Rsi := Frame^.X[4];
  Context.Rdi := Frame^.X[5];
  Context.Rbp := Frame^.X[6];
  Context.Rsp := Frame^.Sp;
  Context.R8 := Frame^.X[8];
  Context.R9 := Frame^.X[9];
  Context.R10 := Frame^.X[10];
  Context.R11 := Frame^.X[11];
  Context.R12 := Frame^.X[12];
  Context.R13 := Frame^.X[13];
  Context.R14 := Frame^.X[14];
  Context.R15 := Frame^.X[15];
  Context.Rip := Frame^.Elr;
  Context.Rflags := Frame^.Spsr;
end;

function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;
begin
  Result := ErrorUnsupported;
end;

procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);
begin
  Frame^.Sp := RecordAddress and not QWord(15);
  Frame^.Elr := Dispatcher;
  Frame^.X[0] := RecordAddress;
  Frame^.X[LinkRegister] := 0;
  { Interrupts enabled in the program. }
  Frame^.Spsr := Frame^.Spsr and not InterruptMaskBit;
end;

end.
