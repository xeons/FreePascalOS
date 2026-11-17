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
  exceptions to it (Processes.UserExceptions): which exceptions are
  passed on and as what, the context in the exception record (X0-X30,
  SP, PC and PSTATE), starting the program's dispatcher, and continuing
  at a context (CallContinue).
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
{ Replaces Frame's registers with Context; ErrorInvalidArgument (Frame
  unchanged) if it does not lead back into user memory. }
function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;

{ Makes the thread continue in Dispatcher with the record's address in X0
  and the stack pointer at RecordAddress (16-byte aligned), with a null
  link register, as if called. }
procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);

implementation

uses
  Memory.Arch.PageTables,
  Kernel.Arch.Exceptions;

const
  LinkRegister = 30;
  { SPSR: the condition flags N, Z, C and V, the only bits a program's
    context may set; everything else returns to EL0 with SP_EL0 and
    nothing masked. }
  SavedConditionFlags = QWord($F0000000);

function ExceptionCodeOfFrame(Frame: PTrapFrame): LongWord;
begin
  case TrapFrameVector(Frame) of
    VectorUndefinedInstruction: Result := ExceptionIllegalInstruction;
    VectorBreakpoint: Result := ExceptionBreakpoint;
    VectorPageFault, VectorExternalAbort: Result := ExceptionAccessViolation;
    VectorAlignmentFault: Result := ExceptionAlignment;
    VectorFloatingPoint: Result := ExceptionSimdFloatingPoint;
    VectorPrivilegedOperation: Result := ExceptionPrivilegedOperation;
    { Any other synchronous exception of a program (an illegal execution
      state, for one) is the program's fault. }
    VectorOtherSynchronous: Result := ExceptionIllegalInstruction;
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
var
  Index: Integer;
begin
  for Index := 0 to 30 do
    Context.X[Index] := Frame^.X[Index];
  Context.Sp := Frame^.Sp;
  Context.Pc := Frame^.Elr;
  Context.Pstate := Frame^.Spsr;
end;

function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;
var
  Index: Integer;
begin
  if (Context.Pc >= UserSpaceLimit) or (Context.Sp >= UserSpaceLimit) or (Context.Sp = 0) then
    Exit(ErrorInvalidArgument);
  for Index := 0 to 30 do
    Frame^.X[Index] := Context.X[Index];
  Frame^.Sp := Context.Sp;
  Frame^.Elr := Context.Pc;
  Frame^.Spsr := Context.Pstate and SavedConditionFlags;
  Result := ErrorNone;
end;

procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);
begin
  Frame^.Sp := RecordAddress and not QWord(15);
  Frame^.Elr := Dispatcher;
  Frame^.X[0] := RecordAddress;
  { A null return address, as on x86-64; the frame pointer still leads
    to the faulting code's frames. }
  Frame^.X[LinkRegister] := 0;
  { EL0, interrupts enabled, single stepping off; the flags as they were. }
  Frame^.Spsr := Frame^.Spsr and SavedConditionFlags;
end;

end.
