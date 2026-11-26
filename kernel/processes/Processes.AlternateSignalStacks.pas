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
  Alternate signal stacks (sigaltstack, CallSetAlternateSignalStack).

  A thread may name a stack of its own memory for signal handlers. A
  signal whose disposition has SignalFlagOnStack then has its record
  (TAbiSignalRecord) written at the top of that stack, and the handler
  runs there - unless the thread is on it already, when the record goes
  below its stack pointer as usual. Processor exceptions of a C program
  (the process has a signal dispatcher) go there the same way when the
  signal the C library makes of them has the flag: so a stack overflow,
  which leaves no room on the thread's own stack, still reaches a
  SIGSEGV handler.

  The stack is per thread; a forked child's thread keeps the forking
  thread's (its copy), exec forgets it, a new thread has none. It cannot
  be changed while the thread runs on it (ErrorNotPermitted).
}
unit Processes.AlternateSignalStacks;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.Thread;

{ Where a handler of Signal starts: True and the top of Thread's
  alternate stack if Signal runs on it and the thread, at StackPointer,
  is not on it already. }
function AlternateStackTopForSignal(Process: PProcess; Thread: PThread; Signal: LongInt; StackPointer: QWord;
  out Top: QWord): Boolean;
{ The same for a processor exception (Abi ExceptionCode) of a C program. }
function AlternateStackTopForException(Process: PProcess; Thread: PThread; Code: LongWord; StackPointer: QWord;
  out Top: QWord): Boolean;
{ The signal the C library makes of a processor exception. }
function SignalOfException(Code: LongWord): LongInt;

function PerformSetAlternateSignalStack(NewAddress, OldAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Memory.Arch.PageTables,
  Kernel.Arch.TrapFrame,
  Processes.PosixState,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function IsOnStack(const Stack: TAlternateSignalStack; StackPointer: QWord): Boolean;
begin
  Result := (Stack.Size <> 0) and (StackPointer > Stack.Base) and (StackPointer <= Stack.Base + Stack.Size);
end;

function AlternateStackTopForSignal(Process: PProcess; Thread: PThread; Signal: LongInt; StackPointer: QWord;
  out Top: QWord): Boolean;
var
  Stack: TAlternateSignalStack;
begin
  Top := 0;
  Stack := Thread^.Posix.AlternateStack;
  Result := (Signal >= 1) and (Signal <= HighestSignal) and
    ((Process^.Posix.HandlerFlags[Signal] and SignalFlagOnStack) <> 0) and (Stack.Size <> 0) and
    not IsOnStack(Stack, StackPointer);
  if Result then
    Top := Stack.Base + Stack.Size;
end;

function SignalOfException(Code: LongWord): LongInt;
begin
  case Code of
    ExceptionIntegerDivide, ExceptionIntegerOverflow, ExceptionFloatingPoint, ExceptionSimdFloatingPoint:
      Result := SignalFloatingPoint;
    ExceptionIllegalInstruction, ExceptionPrivilegedOperation:
      Result := SignalIllegalInstruction;
    ExceptionBreakpoint:
      Result := SignalTrap;
    ExceptionAlignment, ExceptionBoundRange:
      Result := SignalBus;
  else
    Result := SignalSegmentation;
  end;
end;

function AlternateStackTopForException(Process: PProcess; Thread: PThread; Code: LongWord; StackPointer: QWord;
  out Top: QWord): Boolean;
begin
  Top := 0;
  if Process^.Posix.SignalDispatcher = 0 then
    Exit(False);
  Result := AlternateStackTopForSignal(Process, Thread, SignalOfException(Code), StackPointer, Top);
end;

function PerformSetAlternateSignalStack(NewAddress, OldAddress: QWord): Int64;
var
  Thread: PThread;
  Requested: TAbiSignalStack;
  Previous: TAbiSignalStack;
  StackPointer: QWord;
  OnStack: Boolean;
  Error: LongInt;
begin
  Thread := CurrentThreadObject;
  StackPointer := TrapFrameStackPointer(PTrapFrame(Thread^.SystemCallFrame));
  OnStack := IsOnStack(Thread^.Posix.AlternateStack, StackPointer);
  Previous.Base := Thread^.Posix.AlternateStack.Base;
  Previous.Size := Thread^.Posix.AlternateStack.Size;
  Previous.Reserved := 0;
  if Previous.Size = 0 then
    Previous.Flags := SignalStackDisable
  else if OnStack then
    Previous.Flags := SignalStackOnStack
  else
    Previous.Flags := 0;
  if NewAddress <> 0 then
  begin
    Error := CopyFromUser(@Requested, NewAddress, SizeOf(Requested));
    if Error <> ErrorNone then
      Exit(Failure(Error));
    if (Requested.Flags and not LongWord(SignalStackDisable or SignalStackOnStack)) <> 0 then
      Exit(Failure(ErrorInvalidArgument));
    if OnStack then
      Exit(Failure(ErrorNotPermitted));
    if (Requested.Flags and SignalStackDisable) <> 0 then
    begin
      Thread^.Posix.AlternateStack.Base := 0;
      Thread^.Posix.AlternateStack.Size := 0;
    end
    else
    begin
      if Requested.Size < MinimumSignalStackSize then
        Exit(Failure(ErrorOutOfMemory));
      if (Requested.Base >= UserSpaceLimit) or (Requested.Size > UserSpaceLimit - Requested.Base) then
        Exit(Failure(ErrorBadAddress));
      Thread^.Posix.AlternateStack.Base := Requested.Base;
      Thread^.Posix.AlternateStack.Size := Requested.Size;
    end;
  end;
  if OldAddress <> 0 then
  begin
    Error := CopyToUser(OldAddress, @Previous, SizeOf(Previous));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Result := 0;
end;

end.
