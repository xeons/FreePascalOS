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
  The interpreter: runs compiled code (Wasm.Code) on a store's stack.

  One loop and one case over the operation of each instruction, in a
  single procedure so that the instruction pointer, the frame's slots
  and memory 0's address and size stay in registers. The cases are in
  include files by group (control and calls, memory, integer, floating
  point, the fused operations); SIMD operations are calls into
  Wasm.Simd, except for their memory accesses.

  WebAssembly calls do not recurse in Pascal: a call pushes the caller's
  frame record (Wasm.Runtime) and continues in the callee, and a return
  pops it, so recursion is bounded by the store's limits rather than the
  host thread's stack. Host functions are called with the frame pushed,
  so that an embedder's collector sees it (EnumerateReferences) and a
  trap's stack trace includes it.

  Traps jump to one place that builds the stack trace from the frame
  records and raises EWasmTrap. Invoke is the way in from outside: it
  checks the arguments, masks floating point exceptions, and restores
  the stack whatever happens.
}
unit Wasm.Interpreter;

{$mode objfpc}
{$H+}
{$goto on}
{$R-}
{$Q-}

interface

uses
  Wasm.Types,
  Wasm.Runtime;

{ Calls a function (WebAssembly or host) with Arguments, which must match
  its parameter types; raises EWasmTrap on a trap and lets a host
  function's exceptions through. }
function Invoke(Func: TWasmFunction; const Arguments: TWasmValueArray): TWasmValueArray;

implementation

uses
  SysUtils,
  Math,
  Wasm.Errors,
  Wasm.Opcodes,
  Wasm.Code,
  Wasm.Numerics,
  Wasm.Simd;

procedure ReadValues(Store: TWasmStore; First: SizeInt; const Types: TWasmValueTypeArray; var Values: TWasmValueArray);
var
  Index: Integer;
  Slot: SizeInt;
begin
  SetLength(Values, Length(Types));
  Slot := First;
  for Index := 0 to High(Types) do
  begin
    FillChar(Values[Index], SizeOf(TWasmValue), 0);
    Values[Index].ValueType := Types[Index];
    case Types[Index].Kind of
      vkI32, vkF32: Values[Index].F32Bits := DWord(Store.Stack[Slot]);
      vkV128:
        begin
          Values[Index].V128.QWords[0] := Store.Stack[Slot];
          Values[Index].V128.QWords[1] := Store.Stack[Slot + 1];
          Inc(Slot);
        end;
    else
      Values[Index].F64Bits := Store.Stack[Slot];
    end;
    Inc(Slot);
  end;
end;

procedure WriteValues(Store: TWasmStore; First: SizeInt; const Types: TWasmValueTypeArray; const Values: TWasmValueArray);
var
  Index: Integer;
  Slot: SizeInt;
begin
  Slot := First;
  for Index := 0 to High(Types) do
  begin
    case Types[Index].Kind of
      vkI32, vkF32: Store.Stack[Slot] := Values[Index].F32Bits;
      vkV128:
        begin
          Store.Stack[Slot] := Values[Index].V128.QWords[0];
          Store.Stack[Slot + 1] := Values[Index].V128.QWords[1];
          Inc(Slot);
        end;
    else
      Store.Stack[Slot] := Values[Index].F64Bits;
    end;
    Inc(Slot);
  end;
end;

{ Calls a host function whose arguments are at slot First; its results
  go to First on. }
procedure CallHost(Store: TWasmStore; Func: TWasmFunction; First: SizeInt);
var
  Arguments, Results: TWasmValueArray;
  Index: Integer;
begin
  if Store.HostNesting >= Store.Options.MaximumHostNesting then
    raise EWasmTrap.CreateTrap(tkCallStackExhausted);
  ReadValues(Store, First, Func.FunctionType.Params, Arguments);
  SetLength(Results, Length(Func.FunctionType.Results));
  for Index := 0 to High(Results) do
    Results[Index] := WasmDefaultValue(Func.FunctionType.Results[Index]);
  Inc(Store.HostNesting);
  try
    Func.HostCallback(Func, Arguments, Results);
  finally
    Dec(Store.HostNesting);
  end;
  WriteValues(Store, First, Func.FunctionType.Results, Results);
end;

procedure RaiseTrap(Store: TWasmStore; Kind: TWasmTrapKind; Func: TWasmFunction; Index: Integer);
var
  Trap: EWasmTrap;
  Frame, Count: Integer;

  procedure Add(F: TWasmFunction; InstructionIndex: Integer);
  begin
    if (F = nil) or (F.Code = nil) then
      Exit;
    SetLength(Trap.StackTrace, Count + 1);
    Trap.StackTrace[Count].FunctionIndex := F.FunctionIndex;
    Trap.StackTrace[Count].FunctionName := F.Instance.Module.FunctionName(F.FunctionIndex);
    Trap.StackTrace[Count].ModuleName := F.Instance.Module.Name;
    if (InstructionIndex >= 0) and (InstructionIndex < Length(F.Code.ByteOffsets)) then
      Trap.StackTrace[Count].ByteOffset := F.Code.ByteOffsets[InstructionIndex]
    else
      Trap.StackTrace[Count].ByteOffset := 0;
    Inc(Count);
  end;

begin
  Trap := EWasmTrap.CreateTrap(Kind);
  Count := 0;
  Add(Func, Index);
  for Frame := Store.FrameCount - 1 downto 0 do
    Add(Store.Frames[Frame].Func, Store.Frames[Frame].ResumeIndex - 1);
  raise Trap;
end;

{ Runs the WebAssembly function Callee whose arguments are at slot Base. }
procedure Execute(Store: TWasmStore; Callee: TWasmFunction; Base: SizeInt);
label
  DoCall, InterruptCheck, OutOfBounds, Trapped, Finished;
var
  Func: TWasmFunction;
  Code: TCompiledFunction;
  CodeStart, P: PCodeInstruction;
  S: PQWord;
  Instance: TWasmModuleInstance;
  MemoryBase: PByte;
  MemoryLength: QWord;
  EntryFrameCount: Integer;
  TrapKind: TWasmTrapKind;
  Address, Count, Source, Destination: QWord;
  ArgumentBase, Target: Int32;
  Element: QWord;
  Table, SourceTable: TWasmTable;
  Memory: TWasmMemory;
  Slot: SizeInt;
  Index: Integer;
  I32A: Int32;
  U32A: DWord;
  I64A: Int64;
  U64A: QWord;
  Value: Pointer;
  Grown: Int64;
begin
  EntryFrameCount := Store.FrameCount;
  Func := Callee;
  Code := Func.Code;
  Instance := Func.Instance;
  Store.StackTop := Base;
  Store.ReserveStack(Code.FrameSlots + 4);
  S := @Store.Stack[Base];
  if Code.LocalSlots > Code.ParamSlots then
    FillQWord(S[Code.ParamSlots], Code.LocalSlots - Code.ParamSlots, 0);
  CodeStart := @Code.Instructions[0];
  P := CodeStart;
  if Instance.DefaultMemory <> nil then
  begin
    MemoryBase := Instance.DefaultMemory.Data;
    MemoryLength := Instance.DefaultMemory.ByteLength;
  end
  else
  begin
    MemoryBase := nil;
    MemoryLength := 0;
  end;
  TrapKind := tkUnreachable;
  Callee := nil;
  ArgumentBase := 0;
  Target := 0;
  while True do
  begin
    case P^.Operation of
      {$I Wasm.Interpreter.Control.inc}
      {$I Wasm.Interpreter.Memory.inc}
      {$I Wasm.Interpreter.Integer.inc}
      {$I Wasm.Interpreter.Float.inc}
      {$I Wasm.Interpreter.Fused.inc}
    else
      ExecuteSimd(P^, S, PQWord(Code.Constants));
    end;
    Inc(P);
    Continue;

  DoCall:
    { Callee is called with its frame at ArgumentBase; P is the call. }
    Dec(Store.InterruptCountdown);
    if (Store.InterruptCountdown <= 0) and Store.InterruptRequested then
    begin
      TrapKind := tkInterrupted;
      goto Trapped;
    end;
    if Callee.Code = nil then
    begin
      if not Store.PushFrame(Func, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction) + 1, Base) then
      begin
        TrapKind := tkCallStackExhausted;
        goto Trapped;
      end;
      Store.StackTop := Base + Code.FrameSlots;
      CallHost(Store, Callee, Base + ArgumentBase);
      Dec(Store.FrameCount);
      S := @Store.Stack[Base];
      if Instance.DefaultMemory <> nil then
      begin
        MemoryBase := Instance.DefaultMemory.Data;
        MemoryLength := Instance.DefaultMemory.ByteLength;
      end;
      Inc(P);
      Continue;
    end;
    if not Store.PushFrame(Func, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction) + 1, Base) then
    begin
      TrapKind := tkCallStackExhausted;
      goto Trapped;
    end;
    Inc(Base, ArgumentBase);
    if Base + Callee.Code.FrameSlots + 4 > Length(Store.Stack) then
    begin
      if Base + Callee.Code.FrameSlots + 4 > Store.Options.MaximumStackSlots then
      begin
        Dec(Base, ArgumentBase);
        Dec(Store.FrameCount);
        TrapKind := tkCallStackExhausted;
        goto Trapped;
      end;
      Store.StackTop := Base;
      Store.ReserveStack(Callee.Code.FrameSlots + 4);
    end;
    Func := Callee;
    Code := Func.Code;
    S := @Store.Stack[Base];
    if Code.LocalSlots > Code.ParamSlots then
      FillQWord(S[Code.ParamSlots], Code.LocalSlots - Code.ParamSlots, 0);
    CodeStart := @Code.Instructions[0];
    P := CodeStart;
    if Instance <> Func.Instance then
    begin
      Instance := Func.Instance;
      if Instance.DefaultMemory <> nil then
      begin
        MemoryBase := Instance.DefaultMemory.Data;
        MemoryLength := Instance.DefaultMemory.ByteLength;
      end
      else
      begin
        MemoryBase := nil;
        MemoryLength := 0;
      end;
    end;
    Continue;

  InterruptCheck:
    { A back edge to Target found the countdown run out. }
    if not Store.PushFrame(Func, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction) + 1, Base) then
    begin
      TrapKind := tkCallStackExhausted;
      goto Trapped;
    end;
    Store.StackTop := Base + Code.FrameSlots;
    if Store.InterruptRequested then
    begin
      Dec(Store.FrameCount);
      TrapKind := tkInterrupted;
      goto Trapped;
    end;
    Dec(Store.FrameCount);
    S := @Store.Stack[Base];
    P := @CodeStart[Target];
    Continue;
  end;

OutOfBounds:
  TrapKind := tkMemoryOutOfBounds;
Trapped:
  RaiseTrap(Store, TrapKind, Func, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction));

Finished:
end;

function Invoke(Func: TWasmFunction; const Arguments: TWasmValueArray): TWasmValueArray;
var
  Store: TWasmStore;
  SavedFrameCount: Integer;
  SavedStackTop, Base: SizeInt;
  SavedMask: TFPUExceptionMask;
  Index: Integer;
begin
  Result := nil;
  Store := Func.Store;
  if Length(Arguments) <> Length(Func.FunctionType.Params) then
    raise EWasmError.CreateFmt('expected %d arguments, got %d', [Length(Func.FunctionType.Params), Length(Arguments)]);
  for Index := 0 to High(Arguments) do
    if Arguments[Index].ValueType <> Func.FunctionType.Params[Index] then
      raise EWasmError.CreateFmt('argument %d: expected %s, got %s', [Index,
        ValueTypeToString(Func.FunctionType.Params[Index]), ValueTypeToString(Arguments[Index].ValueType)]);
  SavedFrameCount := Store.FrameCount;
  SavedStackTop := Store.StackTop;
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Base := Store.StackTop;
    Store.ReserveStack(Func.ParamSlots + Func.ResultSlots + 4);
    WriteValues(Store, Base, Func.FunctionType.Params, Arguments);
    if Func.Code = nil then
    begin
      Store.StackTop := Base + Func.ParamSlots + Func.ResultSlots;
      CallHost(Store, Func, Base);
    end
    else
      Execute(Store, Func, Base);
    ReadValues(Store, Base, Func.FunctionType.Results, Result);
  finally
    Store.FrameCount := SavedFrameCount;
    Store.StackTop := SavedStackTop;
    SetExceptionMask(SavedMask);
  end;
end;

end.
