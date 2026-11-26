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

  A thrown exception (throw, throw_ref, rethrow, or EWasmException out
  of a host function) is looked for in the handlers of the current
  frame (Wasm.Unwinding) and then of each caller, popping frames, up to
  the frame Execute started with; past that it leaves as EWasmException.
  A tail call moves its arguments to the frame's first slot and runs the
  callee in the caller's place, so the frame records do not grow.
  Allocating instructions first collect when the heap asks for it, with
  the running frame recorded at its safepoint; the garbage collection
  instructions themselves are in Wasm.GcOperations, memories other than
  an i32 memory 0 in Wasm.MemoryAccess.
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
  Wasm.Simd,
  Wasm.GcHeap,
  Wasm.TypeDefinitions,
  Wasm.TypeRegistry,
  Wasm.GcOperations,
  Wasm.MemoryAccess,
  Wasm.Exceptions,
  Wasm.Unwinding;

{ Values leaving for the embedder: garbage collected objects among them
  are exposed (Wasm.GcHeap) until the embedder's next trace. }
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
      vkReference:
        begin
          Values[Index].F64Bits := Store.Stack[Slot];
          Store.Heap.Expose(Values[Index].Reference);
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
  for Index := 0 to High(Results) do
    if (Func.FunctionType.Results[Index].Kind = vkReference) and
      not ValueMatchesType(Store, Results[Index], Func.FunctionType.Results[Index]) then
      raise EWasmError.CreateFmt('host function result %d of the wrong type', [Index]);
  WriteValues(Store, First, Func.FunctionType.Results, Results);
end;

{ CallHost, catching the WebAssembly exception a host function raises
  (to be thrown on in the caller); nil if there was none. }
function CallHostCatching(Store: TWasmStore; Func: TWasmFunction; First: SizeInt): PWasmGcObject;
begin
  Result := nil;
  try
    CallHost(Store, Func, First);
  except
    on Thrown: EWasmException do
      Result := Thrown.Reference;
  end;
end;

{ Collects with the running frame recorded at the instruction it is
  suspended at (whose safepoint lists its live references). }
procedure CollectAtSafepoint(Store: TWasmStore; Func: TWasmFunction; ResumeIndex: Integer; Base: SizeInt);
begin
  if not Store.PushFrame(Func, ResumeIndex, Base) then
    Exit;
  try
    Store.CollectGarbage;
  finally
    Dec(Store.FrameCount);
  end;
end;

{ A new exception of tag Tag with its payload at Slots; nil when the heap
  is full. }
function NewThrownException(Store: TWasmStore; Tag: TWasmTag; Slots: PQWord): PWasmGcObject;
begin
  Result := Store.Heap.AllocateException(Tag, Tag.PayloadSlots);
  if (Result <> nil) and (Tag.PayloadSlots > 0) then
    Move(Slots^, ObjectPayload(Result)^, Tag.PayloadSlots * SizeOf(QWord));
end;

{ An allocating instruction at code index Index: collects first if the
  heap asks, and once more if it is full; NoTrap or the trap. }
function AllocateAt(Store: TWasmStore; Func: TWasmFunction; Instance: TWasmModuleInstance; P: PCodeInstruction;
  Base: SizeInt; Index: Integer): Integer;
begin
  if Store.Heap.WantsCollection then
  begin
    Store.StackTop := Base + Func.Code.FrameSlots;
    CollectAtSafepoint(Store, Func, Index + 1, Base);
  end;
  Result := ExecuteAllocation(Store, Instance, P^, @Store.Stack[Base]);
  if Result = Ord(tkOutOfMemory) then
  begin
    Store.StackTop := Base + Func.Code.FrameSlots;
    CollectAtSafepoint(Store, Func, Index + 1, Base);
    Result := ExecuteAllocation(Store, Instance, P^, @Store.Stack[Base]);
  end;
end;

{ A throw at code index Index: its exception, nil when the heap is full
  even after a collection. }
function ThrowAt(Store: TWasmStore; Func: TWasmFunction; Tag: TWasmTag; Base: SizeInt; Payload: Int32;
  Index: Integer): PWasmGcObject;
begin
  if Store.Heap.WantsCollection then
  begin
    Store.StackTop := Base + Func.Code.FrameSlots;
    CollectAtSafepoint(Store, Func, Index + 1, Base);
  end;
  Result := NewThrownException(Store, Tag, @Store.Stack[Base + Payload]);
  if Result = nil then
  begin
    Store.StackTop := Base + Func.Code.FrameSlots;
    CollectAtSafepoint(Store, Func, Index + 1, Base);
    Result := NewThrownException(Store, Tag, @Store.Stack[Base + Payload]);
  end;
end;

{ Whether a function of type TypeId may be called as ExpectedId. }
function CallTypeMatches(Store: TWasmStore; TypeId, ExpectedId: Integer): Boolean;
begin
  Result := (TypeId = ExpectedId) or Store.Registry.IsSubtype(TypeId, ExpectedId);
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
  DoCall, DoTailCall, InterruptCheck, ReturnToCaller, ThrowException, ThrowFromCaller, Allocate, OutOfBounds,
  Trapped, Finished;
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
  Value := nil;
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
      {$I Wasm.Interpreter.References.inc}
    else
      ExecuteSimd(P^, S, PQWord(Code.Constants));
    end;
    Inc(P);
    Continue;

  Allocate:
    Index := AllocateAt(Store, Func, Instance, P, Base, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction));
    if Index <> NoTrap then
    begin
      TrapKind := TWasmTrapKind(Index);
      goto Trapped;
    end;
    Inc(P);
    Continue;

  ThrowFromCaller:
    { The frame that would catch is gone (a tail call left it): unwind
      to its caller, which threw at its call instruction. }
    if Store.FrameCount = EntryFrameCount then
      RaiseUncaught(Store, Value);
    Dec(Store.FrameCount);
    Func := Store.Frames[Store.FrameCount].Func;
    Base := Store.Frames[Store.FrameCount].Base;
    Index := Store.Frames[Store.FrameCount].ResumeIndex;
    Code := Func.Code;
    CodeStart := @Code.Instructions[0];
    P := @CodeStart[Index - 1];
    S := @Store.Stack[Base];
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

  ThrowException:
    { Value was thrown by the instruction at P. }
    Index := FindCatchClause(Code, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction), Instance, Value);
    if Index < 0 then
      goto ThrowFromCaller;
    P := @CodeStart[DeliverException(Code, Index, Value, S)];
    Value := nil;
    Continue;

  DoTailCall:
    { Callee takes this frame's place, its arguments at ArgumentBase. }
    Dec(Store.InterruptCountdown);
    if Store.InterruptCountdown <= 0 then
    begin
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
    end;
    if (ArgumentBase <> 0) and (Callee.ParamSlots > 0) then
      Move(S[ArgumentBase], S[0], SizeInt(Callee.ParamSlots) * SizeOf(QWord));
    if Callee.Code = nil then
    begin
      Store.StackTop := Base + Callee.ParamSlots + Callee.ResultSlots;
      Store.ReserveStack(4);
      Value := CallHostCatching(Store, Callee, Base);
      S := @Store.Stack[Base];
      if Value <> nil then
        goto ThrowFromCaller;
      goto ReturnToCaller;
    end;
    if Base + Callee.Code.FrameSlots + 4 > Length(Store.Stack) then
    begin
      if Base + Callee.Code.FrameSlots + 4 > Store.Options.MaximumStackSlots then
      begin
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

  ReturnToCaller:
    { The results are at the frame's slot 0. }
    if Store.FrameCount = EntryFrameCount then
      goto Finished;
    Dec(Store.FrameCount);
    Func := Store.Frames[Store.FrameCount].Func;
    Base := Store.Frames[Store.FrameCount].Base;
    Index := Store.Frames[Store.FrameCount].ResumeIndex;
    Code := Func.Code;
    CodeStart := @Code.Instructions[0];
    P := @CodeStart[Index];
    S := @Store.Stack[Base];
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
    Continue;

  DoCall:
    { Callee is called with its frame at ArgumentBase; P is the call. }
    Dec(Store.InterruptCountdown);
    if Store.InterruptCountdown <= 0 then
    begin
      { The hook runs with this frame recorded (its safepoint is the call). }
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
      if Instance.DefaultMemory <> nil then
      begin
        MemoryBase := Instance.DefaultMemory.Data;
        MemoryLength := Instance.DefaultMemory.ByteLength;
      end;
    end;
    if Callee.Code = nil then
    begin
      if not Store.PushFrame(Func, (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction) + 1, Base) then
      begin
        TrapKind := tkCallStackExhausted;
        goto Trapped;
      end;
      Store.StackTop := Base + Code.FrameSlots;
      Value := CallHostCatching(Store, Callee, Base + ArgumentBase);
      Dec(Store.FrameCount);
      S := @Store.Stack[Base];
      if Instance.DefaultMemory <> nil then
      begin
        MemoryBase := Instance.DefaultMemory.Data;
        MemoryLength := Instance.DefaultMemory.ByteLength;
      end;
      if Value <> nil then
        goto ThrowException;
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
    if Instance.DefaultMemory <> nil then
    begin
      MemoryBase := Instance.DefaultMemory.Data;
      MemoryLength := Instance.DefaultMemory.ByteLength;
    end;
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
    if not ValueMatchesType(Store, Arguments[Index], Func.FunctionType.Params[Index]) then
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
