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
  Module validation (spec section 3.4): limits, types of imports and
  definitions, constant expressions, segments, the start function,
  exports, and every function body through Wasm.CodeValidator.

  Constant expressions (globals' initializers, segment offsets and
  element expressions) are checked in the spec's restricted context:
  global.get may only name an imported, immutable global. The functions
  a module may take a reference to with ref.func in code are the ones
  named outside function bodies: in exports, element segments and
  global initializers.
}
unit Wasm.Validator;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Module;

{ Raises EWasmInvalid with the spec's message if the module is invalid. }
procedure ValidateModule(Module: TWasmModule);

implementation

uses
  SysUtils,
  Classes,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Limits,
  Wasm.Opcodes,
  Wasm.Instructions,
  Wasm.CodeValidator;

type
  TModuleValidator = class
  private
    FModule: TWasmModule;
    FDeclaredReferences: array of Boolean;
    procedure Fail(const Message: AnsiString);
    procedure CheckTypeIndex(Index: Cardinal);
    procedure CheckTableLimits(const Limits: TWasmLimits);
    procedure CheckMemoryLimits(const Limits: TWasmLimits);
    procedure CheckConstantExpression(const Expression: TWasmConstantExpression;
      const Expected: TWasmValueType);
    procedure DeclareReferences(const Expression: TWasmConstantExpression);
    procedure CollectDeclaredReferences;
    procedure ValidateImports;
    procedure ValidateDefinitions;
    procedure ValidateElements;
    procedure ValidateData;
    procedure ValidateStart;
    procedure ValidateExports;
    procedure ValidateCode;
  public
    procedure Validate(Module: TWasmModule);
  end;

procedure TModuleValidator.Fail(const Message: AnsiString);
begin
  raise EWasmInvalid.CreateAt(0, Message);
end;

procedure TModuleValidator.CheckTypeIndex(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.Types)) then
    Fail('unknown type ' + IntToStr(Index));
end;

procedure TModuleValidator.CheckTableLimits(const Limits: TWasmLimits);
begin
  if Limits.HasMaximum and (Limits.Minimum > Limits.Maximum) then
    Fail('size minimum must not be greater than maximum');
end;

procedure TModuleValidator.CheckMemoryLimits(const Limits: TWasmLimits);
begin
  if (Limits.Minimum > MaximumMemoryPages) or (Limits.HasMaximum and (Limits.Maximum > MaximumMemoryPages)) then
    Fail('memory size must be at most 65536 pages (4GiB)');
  if Limits.HasMaximum and (Limits.Minimum > Limits.Maximum) then
    Fail('size minimum must not be greater than maximum');
end;

procedure TModuleValidator.CheckConstantExpression(const Expression: TWasmConstantExpression;
  const Expected: TWasmValueType);
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Stack: array of TWasmValueType;
  Count: Integer;

  procedure Push(const ValueType: TWasmValueType);
  begin
    if Count >= Length(Stack) then
      SetLength(Stack, Count * 2 + 4);
    Stack[Count] := ValueType;
    Inc(Count);
  end;

begin
  Count := 0;
  Instructions.Initialize(PByte(FModule.Bytes), Expression.Start, Expression.Limit);
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpI32Const: Push(WasmI32Type);
      OpI64Const: Push(WasmI64Type);
      OpF32Const: Push(WasmF32Type);
      OpF64Const: Push(WasmF64Type);
      OpV128Const: Push(WasmV128Type);
      OpRefNull: Push(Instruction.ReferenceType);
      OpRefFunc:
        begin
          if Instruction.Index >= FModule.FunctionCount then
            Fail('unknown function ' + IntToStr(Instruction.Index));
          Push(WasmFuncRefType);
        end;
      OpGlobalGet:
        begin
          if Instruction.Index >= FModule.ImportedGlobalCount then
            Fail('unknown global ' + IntToStr(Instruction.Index));
          if FModule.Globals[Instruction.Index].Mutable then
            Fail('constant expression required');
          Push(FModule.Globals[Instruction.Index].ValueType);
        end;
      OpEnd: ;
    else
      Fail('constant expression required');
    end;
  until Instruction.Opcode = OpEnd;
  if (Count <> 1) or (Stack[0] <> Expected) then
    Fail('type mismatch');
end;

procedure TModuleValidator.DeclareReferences(const Expression: TWasmConstantExpression);
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
begin
  Instructions.Initialize(PByte(FModule.Bytes), Expression.Start, Expression.Limit);
  while not Instructions.AtEnd do
  begin
    Instructions.Next(Instruction);
    if (Instruction.Opcode = OpRefFunc) and (Instruction.Index < FModule.FunctionCount) then
      FDeclaredReferences[Instruction.Index] := True;
  end;
end;

procedure TModuleValidator.CollectDeclaredReferences;
var
  Index, Item: Integer;
begin
  SetLength(FDeclaredReferences, FModule.FunctionCount);
  for Index := 0 to High(FModule.GlobalDefinitions) do
    DeclareReferences(FModule.GlobalDefinitions[Index].Initializer);
  for Index := 0 to High(FModule.Elements) do
    with FModule.Elements[Index] do
      if UsesExpressions then
      begin
        for Item := 0 to High(Expressions) do
          DeclareReferences(Expressions[Item]);
      end
      else
        for Item := 0 to High(FunctionIndices) do
          if FunctionIndices[Item] < FModule.FunctionCount then
            FDeclaredReferences[FunctionIndices[Item]] := True;
  for Index := 0 to High(FModule.ExportList) do
    if (FModule.ExportList[Index].Kind = ekFunction) and (FModule.ExportList[Index].Index < FModule.FunctionCount) then
      FDeclaredReferences[FModule.ExportList[Index].Index] := True;
end;

procedure TModuleValidator.ValidateImports;
var
  Index: Integer;
begin
  for Index := 0 to High(FModule.Imports) do
    with FModule.Imports[Index] do
      case Kind of
        ekFunction: CheckTypeIndex(TypeIndex);
        ekTable: CheckTableLimits(TableType.Limits);
        ekMemory: CheckMemoryLimits(MemoryType.Limits);
        ekGlobal: ;
      end;
end;

procedure TModuleValidator.ValidateDefinitions;
var
  Index: Integer;
begin
  for Index := FModule.ImportedFunctionCount to High(FModule.FunctionTypes) do
    CheckTypeIndex(FModule.FunctionTypes[Index]);
  for Index := FModule.ImportedTableCount to High(FModule.Tables) do
    CheckTableLimits(FModule.Tables[Index].Limits);
  for Index := FModule.ImportedMemoryCount to High(FModule.Memories) do
    CheckMemoryLimits(FModule.Memories[Index].Limits);
  if Length(FModule.Memories) > MaximumMemories then
    Fail('multiple memories');
  for Index := 0 to High(FModule.GlobalDefinitions) do
    with FModule.GlobalDefinitions[Index] do
      CheckConstantExpression(Initializer, GlobalType.ValueType);
end;

procedure TModuleValidator.ValidateElements;
var
  Index, Item: Integer;
begin
  for Index := 0 to High(FModule.Elements) do
    with FModule.Elements[Index] do
    begin
      if UsesExpressions then
      begin
        for Item := 0 to High(Expressions) do
          CheckConstantExpression(Expressions[Item], ElementType);
      end
      else
        for Item := 0 to High(FunctionIndices) do
          if FunctionIndices[Item] >= FModule.FunctionCount then
            Fail('unknown function ' + IntToStr(FunctionIndices[Item]));
      if Mode = smActive then
      begin
        if TableIndex >= Cardinal(Length(FModule.Tables)) then
          Fail('unknown table ' + IntToStr(TableIndex));
        CheckConstantExpression(Offset, WasmI32Type);
        if FModule.Tables[TableIndex].ElementType <> ElementType then
          Fail('type mismatch');
      end;
    end;
end;

procedure TModuleValidator.ValidateData;
var
  Index: Integer;
begin
  for Index := 0 to High(FModule.Data) do
    with FModule.Data[Index] do
      if Mode = smActive then
      begin
        if MemoryIndex >= Cardinal(Length(FModule.Memories)) then
          Fail('unknown memory ' + IntToStr(MemoryIndex));
        CheckConstantExpression(Offset, WasmI32Type);
      end;
end;

procedure TModuleValidator.ValidateStart;
var
  FunctionType: TWasmFunctionType;
begin
  if not FModule.HasStart then
    Exit;
  if FModule.StartFunction >= FModule.FunctionCount then
    Fail('unknown function ' + IntToStr(FModule.StartFunction));
  FunctionType := FModule.FunctionType(FModule.StartFunction);
  if (Length(FunctionType.Params) <> 0) or (Length(FunctionType.Results) <> 0) then
    Fail('start function');
end;

procedure TModuleValidator.ValidateExports;
var
  Index, Other: Integer;
  Names: TStringList;
  Count: Cardinal;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupAccept;
    for Index := 0 to High(FModule.ExportList) do
      with FModule.ExportList[Index] do
      begin
        case Kind of
          ekFunction: Count := FModule.FunctionCount;
          ekTable: Count := Length(FModule.Tables);
          ekMemory: Count := Length(FModule.Memories);
        else
          Count := Length(FModule.Globals);
        end;
        { (Index is the export's field here.) }
        if Index >= Count then
          Fail('unknown ' + ExternalKindName(Kind) + ' ' + IntToStr(Index));
        if Names.Find(Name, Other) then
          Fail('duplicate export name');
        Names.Add(Name);
      end;
  finally
    Names.Free;
  end;
end;

procedure TModuleValidator.ValidateCode;
var
  CodeValidator: TWasmCodeValidator;
  Index: Integer;
begin
  CodeValidator := TWasmCodeValidator.Create(FModule, FDeclaredReferences);
  try
    for Index := 0 to High(FModule.Bodies) do
      CodeValidator.ValidateFunction(Index);
  finally
    CodeValidator.Free;
  end;
end;

procedure TModuleValidator.Validate(Module: TWasmModule);
begin
  FModule := Module;
  ValidateImports;
  ValidateDefinitions;
  CollectDeclaredReferences;
  ValidateElements;
  ValidateData;
  ValidateStart;
  ValidateExports;
  ValidateCode;
end;

procedure ValidateModule(Module: TWasmModule);
var
  Validator: TModuleValidator;
begin
  Validator := TModuleValidator.Create;
  try
    Validator.Validate(Module);
  finally
    Validator.Free;
  end;
end;

end.
