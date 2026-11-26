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

    1. every import is matched against its external value (kind, and
       the type: equal function types, limits within the import's,
       equal global types); a mismatch is a link error and nothing is
       made;
    2. the instance is allocated: its functions, tables, memories and
       globals (initializers evaluated against the imported globals),
       and the element segments' references;
    3. active element segments are copied into their tables, in order,
       and dropped, as are declarative ones;
    4. active data segments are copied into memory, in order, and
       dropped;
    5. the start function runs.

  Steps 3 and 4 check each segment as it comes (bulk memory semantics):
  one that does not fit traps, and what earlier segments wrote to
  imported tables and memories stays written. The instance stays in the
  store, so functions put into an imported table before a trap remain
  callable.
}
unit Wasm.Instantiation;

{$mode objfpc}
{$H+}

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
  Wasm.Instructions,
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

procedure CheckImport(Module: TWasmModule; const Import: TWasmImport; const External: TWasmExternal);
var
  Limits: TWasmLimits;
begin
  if External.Kind <> Import.Kind then
    raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: expected a %s', [Import.ModuleName,
      Import.FieldName, ExternalKindName(Import.Kind)]);
  case Import.Kind of
    ekFunction:
      if (External.Func = nil) or not FunctionTypesEqual(External.Func.FunctionType, Module.Types[Import.TypeIndex]) then
        raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: function type', [Import.ModuleName,
          Import.FieldName]);
    ekTable:
      begin
        Limits := External.Table.TableType.Limits;
        Limits.Minimum := External.Table.Size;
        if (External.Table.TableType.ElementType <> Import.TableType.ElementType) or
          not LimitsMatch(Limits, Import.TableType.Limits) then
          raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: table type', [Import.ModuleName,
            Import.FieldName]);
      end;
    ekMemory:
      begin
        Limits := External.Memory.MemoryType.Limits;
        Limits.Minimum := External.Memory.PageCount;
        if not LimitsMatch(Limits, Import.MemoryType.Limits) then
          raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: memory type', [Import.ModuleName,
            Import.FieldName]);
      end;
    ekGlobal:
      if (External.Global.GlobalType.Mutable <> Import.GlobalType.Mutable) or
        (External.Global.GlobalType.ValueType <> Import.GlobalType.ValueType) then
        raise EWasmLinkError.CreateFmt('incompatible import type for %s.%s: global type', [Import.ModuleName,
          Import.FieldName]);
  end;
end;

function EvaluateConstantExpression(Instance: TWasmModuleInstance; const Expression: TWasmConstantExpression): TWasmValue;
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
begin
  Result := WasmI32(0);
  Instructions.Initialize(PByte(Instance.Module.Bytes), Expression.Start, Expression.Limit);
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpI32Const: Result := WasmI32(Int32(Instruction.Constant));
      OpI64Const: Result := WasmI64(Int64(Instruction.Constant));
      OpF32Const: Result := WasmF32FromBits(DWord(Instruction.Constant));
      OpF64Const: Result := WasmF64FromBits(Instruction.Constant);
      OpV128Const: Result := WasmV128(Instruction.Vector);
      OpRefNull: Result := WasmReference(Instruction.ReferenceType, nil);
      OpRefFunc: Result := WasmFuncRef(Instance.Functions[Instruction.Index]);
      OpGlobalGet: Result := Instance.Globals[Instruction.Index].GetValue;
    end;
  until Instruction.Opcode = OpEnd;
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
          Offset := DWord(EvaluateConstantExpression(Instance, Module.Elements[Index].Offset).I32);
          Table := Instance.Tables[Module.Elements[Index].TableIndex];
          Count := Length(Instance.ElementSegments[Index]);
          if Offset + Count > Table.Size then
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
      Offset := DWord(EvaluateConstantExpression(Instance, Module.Data[Index].Offset).I32);
      Memory := Instance.Memories[Module.Data[Index].MemoryIndex];
      Count := Module.Data[Index].DataLength;
      if Offset + Count > Memory.ByteLength then
        raise EWasmTrap.CreateTrap(tkMemoryOutOfBounds);
      if Count > 0 then
        Move(Module.Bytes[Module.Data[Index].DataStart], Memory.Data[Offset], Count);
      Instance.DataDropped[Index] := True;
    end;
end;

function InstantiateModule(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;
var
  Instance: TWasmModuleInstance;
  Index, Item: Integer;
  FunctionIndex, TableIndex, MemoryIndex, GlobalIndex: Integer;
  Value: TWasmValue;
begin
  if Length(Imports) <> Length(Module.Imports) then
    raise EWasmLinkError.CreateFmt('expected %d imports, got %d', [Length(Module.Imports), Length(Imports)]);
  for Index := 0 to High(Module.Imports) do
    CheckImport(Module, Module.Imports[Index], Imports[Index]);

  Instance := Store.NewModuleInstance(Module);
  SetLength(Instance.TypeIds, Length(Module.Types));
  for Index := 0 to High(Module.Types) do
    Instance.TypeIds[Index] := Store.CanonicalTypeId(Module.Types[Index]);
  SetLength(Instance.Functions, Module.FunctionCount);
  SetLength(Instance.Tables, Length(Module.Tables));
  SetLength(Instance.Memories, Length(Module.Memories));
  SetLength(Instance.Globals, Length(Module.Globals));
  FunctionIndex := 0;
  TableIndex := 0;
  MemoryIndex := 0;
  GlobalIndex := 0;
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
    end;
  for Index := FunctionIndex to High(Instance.Functions) do
    Instance.Functions[Index] := Store.NewFunction(Instance, Index);
  for Index := TableIndex to High(Instance.Tables) do
    Instance.Tables[Index] := Store.NewTable(Module.Tables[Index], nil);
  for Index := MemoryIndex to High(Instance.Memories) do
    Instance.Memories[Index] := Store.NewMemory(Module.Memories[Index]);
  if Length(Instance.Memories) > 0 then
    Instance.DefaultMemory := Instance.Memories[0];
  for Index := 0 to High(Module.GlobalDefinitions) do
  begin
    Value := EvaluateConstantExpression(Instance, Module.GlobalDefinitions[Index].Initializer);
    Instance.Globals[GlobalIndex + Index] := Store.NewGlobal(Module.GlobalDefinitions[Index].GlobalType, Value);
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

  InitializeElements(Instance);
  InitializeData(Instance);
  if Module.HasStart then
    Invoke(Instance.Functions[Module.StartFunction], nil);
  Result := Instance;
end;

end.
