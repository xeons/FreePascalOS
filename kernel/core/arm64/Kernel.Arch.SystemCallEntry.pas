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
  System calls on AArch64.

  A program calls the kernel with SVC #0: the call number in X8, the
  arguments in X0-X5, the result in X0 (as Linux does on AArch64). The
  SVC arrives as a synchronous exception from EL0 on the thread's kernel
  stack (Kernel.Arch.Exceptions), with the usual trap frame, and is
  handled with interrupts enabled.
}
unit Kernel.Arch.SystemCallEntry;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

type
  TSystemCallHandler = procedure(Frame: PTrapFrame);

procedure InitializeSystemCallEntry(Handler: TSystemCallHandler);
{ Nothing to program per processor on AArch64. }
procedure EnableSystemCallsOnThisProcessor;
{ Sets the kernel stack the processor is on when it next leaves user
  mode (the running thread's stack top). }
procedure SetSystemCallKernelStack(StackTop: QWord);
{ Accessors for the call number, arguments and result in a frame. }
function SystemCallNumber(Frame: PTrapFrame): QWord;
function SystemCallArgument(Frame: PTrapFrame; Index: Integer): QWord;
procedure SetSystemCallResult(Frame: PTrapFrame; Value: Int64);

{ Called by the exception code for an SVC from user mode, with
  interrupts disabled; returns with them disabled. }
procedure DispatchSystemCall(Frame: PTrapFrame);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Processors;

const
  NumberRegister = 8;
  ArgumentCount = 6;

var
  RegisteredHandler: TSystemCallHandler = nil;

procedure InitializeSystemCallEntry(Handler: TSystemCallHandler);
begin
  RegisteredHandler := Handler;
end;

procedure EnableSystemCallsOnThisProcessor;
begin
end;

procedure SetSystemCallKernelStack(StackTop: QWord);
begin
  CurrentProcessor^.SystemCallStack := StackTop;
end;

function SystemCallNumber(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.X[NumberRegister];
end;

function SystemCallArgument(Frame: PTrapFrame; Index: Integer): QWord;
begin
  if (Index >= 0) and (Index < ArgumentCount) then
    Result := Frame^.X[Index]
  else
    Result := 0;
end;

procedure SetSystemCallResult(Frame: PTrapFrame; Value: Int64);
begin
  Frame^.X[0] := QWord(Value);
end;

procedure DispatchSystemCall(Frame: PTrapFrame);
begin
  EnableInterrupts;
  if Assigned(RegisteredHandler) then
    RegisteredHandler(Frame);
  DisableInterrupts;
end;

end.
