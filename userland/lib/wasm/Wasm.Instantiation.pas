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
  Instantiation (spec section 4.5.4), in the spec's order:

    1. the module's types are registered in the store (Wasm.TypeRegistry)
       and every import is matched against its external value (kind,
       and the type: a function's type a subtype of the import's, limits
       within the import's and the same address type, a global's type
       equal when mutable and a subtype when not, a tag's type equal); a
       mismatch is a link error and nothing is made;
    2. the instance is allocated: its functions, tables (filled with
       their initializer), memories, tags and globals (initializers
       evaluated in order), and the element segments' references;
    3. active element segments are copied into their tables, in order,
       and dropped, as are declarative ones;
    4. active data segments are copied into memory, in order, and
       dropped;
    5. the start function runs.

  Steps 3 and 4 check each segment as it comes (bulk memory semantics):
  one that does not fit traps, and what earlier segments wrote to
  imported tables and memories stays written. The instance stays in the
  store, so functions put into an imported table before a trap remain
  callable. No collection runs during steps 2 to 4 (constant
  expressions hold new objects only on the evaluator's stack).
}
unit Wasm.Instantiation;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

uses
  Wasm.Types,
  Wasm.Module,
  Wasm.Runtime;

{ Instantiates a validated and compiled module with one external value
  per import, in the order of the module's imports. Raises
  EWasmLinkError, EWasmTrap (a segment or the start function) or
  EWasmResourceError. }
function InstantiateModule(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;

{ The value of a constant expression in an instance. }
function EvaluateConstantExpression(Instance: TWasmModuleInstance; const Expression: TWasmConstantExpression): TWasmValue;

implementation

uses
  SysUtils,
  Wasm.Errors,
  Wasm.Opcodes,
  Wasm.Code,
  Wasm.Instructions,
  Wasm.TypeDefinitions,
  Wasm.Subtyping,
  Wasm.GcOperations,
  Wasm.Interpreter;

function LimitsMatch(const Actual, Expected: TWasmLimits): Boolean;
begin
  if Actual.Minimum < Expected.Minimum then
    Exit(False);
  if Expected.HasMaximum then
  begin
    if not Actual.HasMaximum then
      Exit(False);
    if Actual.Maximum > Expected.Maximum then
      Exit(False);
  end;
  Result := True;
end;

procedure LinkFailure(const Import: TWasmImport; const What: AnsiString);
begin
  raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: %s', [Import.ModuleName, Import.FieldName,
    What]);
end;

procedure CheckImport(Instance: TWasmModuleInstance; const Import: TWasmImport; const External: TWasmExternal);
var
  Store: TWasmStore;
  Limits: TWasmLimits;
  Expected: TWasmValueType;
begin
  Store := Instance.Store;
  if External.Kind <> Import.Kind then
    LinkFailure(Import, 'expected a ' + ExternalKindName(Import.Kind));
  case Import.Kind of
    ekFunction:
      if (External.Func = nil) or
        not Store.Registry.IsSubtype(External.Func.TypeId, Instance.TypeIds[Import.TypeIndex]) then
        LinkFailure(Import, 'function type');
    ekTable:
      begin
        Limits := External.Table.TableType.Limits;
        Limits.Minimum := External.Table.Size;
        Expected := Instance.RuntimeValueType(Import.TableType.ElementType);
        if (External.Table.TableType.ElementType <> Expected) or
          (External.Table.TableType.AddressType <> Import.TableType.AddressType) or
          not LimitsMatch(Limits, Import.TableType.Limits) then
          LinkFailure(Import, 'table type');
      end;
    ekMemory:
      begin
        Limits := External.Memory.MemoryType.Limits;
        Limits.Minimum := External.Memory.PageCount;
        if (External.Memory.MemoryType.AddressType <> Import.MemoryType.AddressType) or
          not LimitsMatch(Limits, Import.MemoryType.Limits) then
          LinkFailure(Import, 'memory type');
      end;
    ekGlobal:
      begin
        Expected := Instance.RuntimeValueType(Import.GlobalType.ValueType);
        if External.Global.GlobalType.Mutable <> Import.GlobalType.Mutable then
          LinkFailure(Import, 'global type');
        if Import.GlobalType.Mutable then
        begin
          if External.Global.GlobalType.ValueType <> Expected then
            LinkFailure(Import, 'global type');
        end
        else if not ValueTypeMatches(Store.Registry, External.Global.GlobalType.ValueType, Expected) then
          LinkFailure(Import, 'global type');
      end;
    ekTag:
      if (External.Tag = nil) or (External.Tag.TypeId <> Instance.TypeIds[Import.TagTypeIndex]) then
        LinkFailure(Import, 'tag type');
  end;
end;

type
  { A constant expression's stack machine: values as 64-bit words (a
    v128 as the whole TWasmValue). }
  TConstantEvaluator = record
    Stack: array of TWasmValue;
    Count: Integer;
    procedure Push(const Value: TWasmValue);
    function Pop: TWasmValue;
  end;

procedure TConstantEvaluator.Push(const Value: TWasmValue);
begin
  if Count >= Length(Stack) then
    SetLength(Stack, Count * 2 + 4);
  Stack[Count] := Value;
  Inc(Count);
end;

function TConstantEvaluator.Pop: TWasmValue;
begin
  Dec(Count);
  Result := Stack[Count];
end;

{ Runs an allocating GC instruction on values taken from the evaluator
  as slots, the way the interpreter would. }
function Allocate(Instance: TWasmModuleInstance; var Evaluator: TConstantEvaluator; Operation: Integer;
  TypeIndex: Cardinal; OperandCount: Integer; C: Int32; const ResultType: TWasmValueType): TWasmValue;
var
  Slots: array of QWord;
  Values: array of TWasmValue;
  Index, Slot: Integer;
  Instruction: TCodeInstruction;
  Outcome: Integer;
begin
  SetLength(Values, OperandCount);
  for Index := OperandCount - 1 downto 0 do
    Values[Index] := Evaluator.Pop;
  SetLength(Slots, OperandCount * 2 + 2);
  Slot := 0;
  for Index := 0 to OperandCount - 1 do
  begin
    case Values[Index].ValueType.Kind of
      vkI32, vkF32: Slots[Slot] := Values[Index].F32Bits;
      vkV128:
        begin
          Slots[Slot] := Values[Index].V128.QWords[0];
          Slots[Slot + 1] := Values[Index].V128.QWords[1];
          Inc(Slot);
        end;
    else
      Slots[Slot] := Values[Index].F64Bits;
    end;
    Inc(Slot);
  end;
  Instruction := Default(TCodeInstruction);
  Instruction.Operation := Operation;
  Instruction.A := 0;
  Instruction.B := TypeIndex;
  Instruction.C := C;
  Outcome := ExecuteAllocation(Instance.Store, Instance, Instruction, @Slots[0]);
  if Outcome <> NoTrap then
    raise EWasmTrap.CreateTrap(TWasmTrapKind(Outcome));
  Result := WasmReference(ResultType, Pointer(PtrUInt(Slots[0])));
end;

function EvaluateConstantExpression(Instance: TWasmModuleInstance; const Expression: TWasmConstantExpression): TWasmValue;
var
  Module: TWasmModule;
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Evaluator: TConstantEvaluator;
  Left, Right: TWasmValue;
  Converted: QWord;
  ResultType: TWasmValueType;
begin
  Module := Instance.Module;
  Evaluator.Stack := nil;
  Evaluator.Count := 0;
  Instructions.Initialize(PByte(Module.Bytes), Expression.Start, Expression.Limit, Module.Features);
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpI32Const: Evaluator.Push(WasmI32(Int32(Instruction.Constant)));
      OpI64Const: Evaluator.Push(WasmI64(Int64(Instruction.Constant)));
      OpF32Const: Evaluator.Push(WasmF32FromBits(DWord(Instruction.Constant)));
      OpF64Const: Evaluator.Push(WasmF64FromBits(Instruction.Constant));
      OpV128Const: Evaluator.Push(WasmV128(Instruction.Vector));
      OpRefNull: Evaluator.Push(WasmReference(Instance.RuntimeValueType(Instruction.ReferenceType), nil));
      OpRefFunc: Evaluator.Push(WasmFuncRef(Instance.Functions[Instruction.Index]));
      OpGlobalGet: Evaluator.Push(Instance.Globals[Instruction.Index].GetValue);
      OpI32Add, OpI32Sub, OpI32Mul:
        begin
          Right := Evaluator.Pop;
          Left := Evaluator.Pop;
          case Instruction.Opcode of
            OpI32Add: Evaluator.Push(WasmI32(Int32(DWord(Left.I32) + DWord(Right.I32))));
            OpI32Sub: Evaluator.Push(WasmI32(Int32(DWord(Left.I32) - DWord(Right.I32))));
          else
            Evaluator.Push(WasmI32(Int32(DWord(Left.I32) * DWord(Right.I32))));
          end;
        end;
      OpI64Add, OpI64Sub, OpI64Mul:
        begin
          Right := Evaluator.Pop;
          Left := Evaluator.Pop;
          case Instruction.Opcode of
            OpI64Add: Evaluator.Push(WasmI64(Int64(QWord(Left.I64) + QWord(Right.I64))));
            OpI64Sub: Evaluator.Push(WasmI64(Int64(QWord(Left.I64) - QWord(Right.I64))));
          else
            Evaluator.Push(WasmI64(Int64(QWord(Left.I64) * QWord(Right.I64))));
          end;
        end;
      OpRefI31:
        begin
          Left := Evaluator.Pop;
          Evaluator.Push(WasmReference(MakeReferenceType(HeapTypeI31, False), Pointer(PtrUInt(MakeI31(DWord(Left.I32))))));
        end;
      OpStructNew, OpStructNewDefault, OpArrayNew, OpArrayNewDefault, OpArrayNewFixed:
        begin
          ResultType := MakeReferenceType(Instance.TypeIds[Instruction.Index], False);
          case Instruction.Opcode of
            OpStructNew:
              Evaluator.Push(Allocate(Instance, Evaluator, CodeStructNew, Instruction.Index,
                Length(Module.TypeDefinitions[Instruction.Index].Fields), 0, ResultType));
            OpStructNewDefault:
              Evaluator.Push(Allocate(Instance, Evaluator, CodeStructNewDefault, Instruction.Index, 0, 0, ResultType));
            OpArrayNew:
              Evaluator.Push(Allocate(Instance, Evaluator, CodeArrayNew, Instruction.Index, 2, 0, ResultType));
            OpArrayNewDefault:
              Evaluator.Push(Allocate(Instance, Evaluator, CodeArrayNewDefault, Instruction.Index, 1, 0, ResultType));
          else
            Evaluator.Push(Allocate(Instance, Evaluator, CodeArrayNewFixed, Instruction.Index,
              Instruction.SecondIndex, Instruction.SecondIndex, ResultType));
          end;
        end;
      OpAnyConvertExtern:
        begin
          Left := Evaluator.Pop;
          if not Internalize(Instance.Store, QWord(PtrUInt(Left.Reference)), Converted) then
            raise EWasmTrap.CreateTrap(tkOutOfMemory);
          Evaluator.Push(WasmReference(MakeReferenceType(HeapTypeAny, Left.ValueType.Nullable),
            Pointer(PtrUInt(Converted))));
        end;
      OpExternConvertAny:
        begin
          Left := Evaluator.Pop;
          Evaluator.Push(WasmReference(MakeReferenceType(HeapTypeExtern, Left.ValueType.Nullable),
            Pointer(PtrUInt(Externalize(Instance.Store, QWord(PtrUInt(Left.Reference)))))));
        end;
    end;
  until Instruction.Opcode = OpEnd;
  if Evaluator.Count > 0 then
    Result := Evaluator.Stack[Evaluator.Count - 1]
  else
    Result := WasmI32(0);
end;

{ An offset of a table or memory of the address type. }
function OffsetValue(const Value: TWasmValue): QWord;
begin
  if Value.ValueType.Kind = vkI64 then
    Result := QWord(Value.I64)
  else
    Result := DWord(Value.I32);
end;

procedure InitializeElements(Instance: TWasmModuleInstance);
var
  Module: TWasmModule;
  Index: Integer;
  Offset, Count: QWord;
  Table: TWasmTable;
begin
  Module := Instance.Module;
  for Index := 0 to High(Module.Elements) do
    case Module.Elements[Index].Mode of
      smActive:
        begin
          Offset := OffsetValue(EvaluateConstantExpression(Instance, Module.Elements[Index].Offset));
          Table := Instance.Tables[Module.Elements[Index].TableIndex];
          Count := Length(Instance.ElementSegments[Index]);
          if (Offset > Table.Size) or (Count > Table.Size - Offset) then
          begin
            Instance.ElementSegments[Index] := nil;
            raise EWasmTrap.CreateTrap(tkTableOutOfBounds);
          end;
          if Count > 0 then
            Move(Instance.ElementSegments[Index][0], Table.Elements[Offset], Count * SizeOf(Pointer));
          Instance.ElementSegments[Index] := nil;
        end;
      smDeclarative:
        Instance.ElementSegments[Index] := nil;
      smPassive: ;
    end;
end;

procedure InitializeData(Instance: TWasmModuleInstance);
var
  Module: TWasmModule;
  Index: Integer;
  Offset, Count: QWord;
  Memory: TWasmMemory;
begin
  Module := Instance.Module;
  for Index := 0 to High(Module.Data) do
    if Module.Data[Index].Mode = smActive then
    begin
      Offset := OffsetValue(EvaluateConstantExpression(Instance, Module.Data[Index].Offset));
      Memory := Instance.Memories[Module.Data[Index].MemoryIndex];
      Count := Module.Data[Index].DataLength;
      if (Offset > Memory.ByteLength) or (Count > Memory.ByteLength - Offset) then
        raise EWasmTrap.CreateTrap(tkMemoryOutOfBounds);
      if Count > 0 then
        Move(Module.Bytes[Module.Data[Index].DataStart], Memory.Data[Offset], Count);
      Instance.DataDropped[Index] := True;
    end;
end;

procedure AllocateDefinitions(Instance: TWasmModuleInstance; FunctionIndex, TableIndex, MemoryIndex, GlobalIndex,
  TagIndex: Integer);
var
  Store: TWasmStore;
  Module: TWasmModule;
  Index, Item: Integer;
  TableType: TWasmTableType;
  GlobalType: TWasmGlobalType;
  Initial: Pointer;
begin
  Store := Instance.Store;
  Module := Instance.Module;
  for Index := FunctionIndex to High(Instance.Functions) do
    Instance.Functions[Index] := Store.NewFunction(Instance, Index);
  for Index := TagIndex to High(Instance.Tags) do
    Instance.Tags[Index] := Store.NewTag(Store.TypeOfId(Instance.TypeIds[Module.TagTypes[Index]]),
      Instance.TypeIds[Module.TagTypes[Index]]);
  for Index := TableIndex to High(Instance.Tables) do
  begin
    TableType := Module.Tables[Index];
    TableType.ElementType := Instance.RuntimeValueType(TableType.ElementType);
    Initial := nil;
    if Module.TableDefinitions[Index - TableIndex].HasInitializer then
      Initial := EvaluateConstantExpression(Instance, Module.TableDefinitions[Index - TableIndex].Initializer).Reference;
    Instance.Tables[Index] := Store.NewTable(TableType, Initial);
  end;
  for Index := MemoryIndex to High(Instance.Memories) do
    Instance.Memories[Index] := Store.NewMemory(Module.Memories[Index]);
  if Length(Instance.Memories) > 0 then
    Instance.DefaultMemory := Instance.Memories[0];
  for Index := 0 to High(Module.GlobalDefinitions) do
  begin
    GlobalType := Module.GlobalDefinitions[Index].GlobalType;
    GlobalType.ValueType := Instance.RuntimeValueType(GlobalType.ValueType);
    Instance.Globals[GlobalIndex + Index] := Store.NewGlobal(GlobalType,
      EvaluateConstantExpression(Instance, Module.GlobalDefinitions[Index].Initializer));
  end;
  SetLength(Instance.ElementSegments, Length(Module.Elements));
  for Index := 0 to High(Module.Elements) do
    with Module.Elements[Index] do
      if UsesExpressions then
      begin
        SetLength(Instance.ElementSegments[Index], Length(Expressions));
        for Item := 0 to High(Expressions) do
          Instance.ElementSegments[Index][Item] := EvaluateConstantExpression(Instance, Expressions[Item]).Reference;
      end
      else
      begin
        SetLength(Instance.ElementSegments[Index], Length(FunctionIndices));
        for Item := 0 to High(FunctionIndices) do
          Instance.ElementSegments[Index][Item] := Instance.Functions[FunctionIndices[Item]];
      end;
  SetLength(Instance.DataDropped, Length(Module.Data));
end;

function InstantiateModule(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;
var
  Instance: TWasmModuleInstance;
  Index: Integer;
  FunctionIndex, TableIndex, MemoryIndex, GlobalIndex, TagIndex: Integer;
begin
  if Length(Imports) <> Length(Module.Imports) then
    raise EWasmLinkError.CreateFmt('expected %d imports, got %d', [Length(Module.Imports), Length(Imports)]);
  Instance := Store.NewModuleInstance(Module);
  Instance.TypeIds := Store.Registry.RegisterModule(Module);
  SetLength(Instance.RuntimeTypes, Length(Instance.TypeIds));
  for Index := 0 to High(Instance.TypeIds) do
    Instance.RuntimeTypes[Index] := Store.Registry.TypeOf(Instance.TypeIds[Index]);
  for Index := 0 to High(Module.Imports) do
    CheckImport(Instance, Module.Imports[Index], Imports[Index]);

  SetLength(Instance.Functions, Module.FunctionCount);
  SetLength(Instance.Tables, Length(Module.Tables));
  SetLength(Instance.Memories, Length(Module.Memories));
  SetLength(Instance.Globals, Length(Module.Globals));
  SetLength(Instance.Tags, Length(Module.TagTypes));
  FunctionIndex := 0;
  TableIndex := 0;
  MemoryIndex := 0;
  GlobalIndex := 0;
  TagIndex := 0;
  for Index := 0 to High(Imports) do
    case Imports[Index].Kind of
      ekFunction:
        begin
          Instance.Functions[FunctionIndex] := Imports[Index].Func;
          Inc(FunctionIndex);
        end;
      ekTable:
        begin
          Instance.Tables[TableIndex] := Imports[Index].Table;
          Inc(TableIndex);
        end;
      ekMemory:
        begin
          Instance.Memories[MemoryIndex] := Imports[Index].Memory;
          Inc(MemoryIndex);
        end;
      ekGlobal:
        begin
          Instance.Globals[GlobalIndex] := Imports[Index].Global;
          Inc(GlobalIndex);
        end;
      ekTag:
        begin
          Instance.Tags[TagIndex] := Imports[Index].Tag;
          Inc(TagIndex);
        end;
    end;
  Store.Heap.Inhibit;
  try
    AllocateDefinitions(Instance, FunctionIndex, TableIndex, MemoryIndex, GlobalIndex, TagIndex);
    InitializeElements(Instance);
    InitializeData(Instance);
  finally
    Store.Heap.Allow;
  end;
  if Module.HasStart then
    Invoke(Instance.Functions[Module.StartFunction], nil);
  Result := Instance;
end;

end.
