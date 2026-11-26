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
  Module validation (spec section 3.4): the type section
  (Wasm.ModuleTypes), limits, types of imports and definitions, constant
  expressions (Wasm.ConstantValidator), segments, the start function,
  exports, and every function body through Wasm.CodeValidator.

  The functions a module may take a reference to with ref.func in code
  are the ones named outside function bodies: in exports, element
  segments, and global and table initializers.
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
  Wasm.TypeDefinitions,
  Wasm.Features,
  Wasm.Errors,
  Wasm.Limits,
  Wasm.Opcodes,
  Wasm.Instructions,
  Wasm.Subtyping,
  Wasm.ModuleTypes,
  Wasm.ConstantValidator,
  Wasm.CodeValidator;

type
  TModuleValidator = class
  private
    FModule: TWasmModule;
    FContext: TWasmModuleTypeContext;
    FConstants: TWasmConstantValidator;
    FDeclaredReferences: array of Boolean;
    procedure Fail(const Message: AnsiString);
    procedure CheckTypeIndex(Index: Cardinal);
    procedure CheckFunctionTypeIndex(Index: Cardinal);
    procedure CheckValueType(const ValueType: TWasmValueType);
    procedure CheckTableType(const TableType: TWasmTableType);
    procedure CheckMemoryType(const MemoryType: TWasmMemoryType);
    procedure CheckTagType(TypeIndex: Cardinal);
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
    destructor Destroy; override;
    procedure Validate(Module: TWasmModule);
  end;

destructor TModuleValidator.Destroy;
begin
  FConstants.Free;
  FContext.Free;
  inherited Destroy;
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

procedure TModuleValidator.CheckFunctionTypeIndex(Index: Cardinal);
begin
  CheckTypeIndex(Index);
  if FModule.TypeDefinitions[Index].Kind <> ckFunction then
    Fail('type mismatch: not a function type');
end;

procedure TModuleValidator.CheckValueType(const ValueType: TWasmValueType);
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType >= 0) then
    CheckTypeIndex(Cardinal(ValueType.HeapType));
end;

procedure TModuleValidator.CheckTableType(const TableType: TWasmTableType);
begin
  CheckValueType(TableType.ElementType);
  if (TableType.AddressType = vkI32) and ((TableType.Limits.Minimum > $FFFFFFFF) or
    (TableType.Limits.HasMaximum and (TableType.Limits.Maximum > $FFFFFFFF))) then
    Fail('table size must be at most 2^32-1');
  if TableType.Limits.HasMaximum and (TableType.Limits.Minimum > TableType.Limits.Maximum) then
    Fail('size minimum must not be greater than maximum');
end;

procedure TModuleValidator.CheckMemoryType(const MemoryType: TWasmMemoryType);
var
  Largest: QWord;
begin
  with MemoryType do
  begin
    if AddressType = vkI64 then
      Largest := MaximumMemory64Pages
    else
      Largest := MaximumMemoryPages;
    if (Limits.Minimum > Largest) or (Limits.HasMaximum and (Limits.Maximum > Largest)) then
    begin
      if AddressType = vkI64 then
        Fail('memory size must be at most 2^48 pages')
      else
        Fail('memory size must be at most 65536 pages (4GiB)');
    end;
    if Limits.HasMaximum and (Limits.Minimum > Limits.Maximum) then
      Fail('size minimum must not be greater than maximum');
  end;
end;

procedure TModuleValidator.CheckTagType(TypeIndex: Cardinal);
begin
  CheckFunctionTypeIndex(TypeIndex);
  if Length(FModule.Types[TypeIndex].Results) <> 0 then
    Fail('non-empty tag result type');
end;

procedure TModuleValidator.DeclareReferences(const Expression: TWasmConstantExpression);
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
begin
  Instructions.Initialize(PByte(FModule.Bytes), Expression.Start, Expression.Limit, FModule.Features);
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
  for Index := 0 to High(FModule.TableDefinitions) do
    if FModule.TableDefinitions[Index].HasInitializer then
      DeclareReferences(FModule.TableDefinitions[Index].Initializer);
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
        ekFunction: CheckFunctionTypeIndex(TypeIndex);
        ekTable: CheckTableType(TableType);
        ekMemory: CheckMemoryType(MemoryType);
        ekGlobal: CheckValueType(GlobalType.ValueType);
        ekTag: CheckTagType(TagTypeIndex);
      end;
end;

procedure TModuleValidator.ValidateDefinitions;
var
  Index: Integer;
  TableIndex: Cardinal;
begin
  for Index := FModule.ImportedFunctionCount to High(FModule.FunctionTypes) do
    CheckFunctionTypeIndex(FModule.FunctionTypes[Index]);
  for Index := FModule.ImportedTagCount to High(FModule.TagTypes) do
    CheckTagType(FModule.TagTypes[Index]);
  for Index := 0 to High(FModule.TableDefinitions) do
  begin
    TableIndex := FModule.ImportedTableCount + Cardinal(Index);
    CheckTableType(FModule.Tables[TableIndex]);
    if FModule.TableDefinitions[Index].HasInitializer then
      FConstants.Check(FModule.TableDefinitions[Index].Initializer, FModule.Tables[TableIndex].ElementType,
        FModule.ImportedGlobalCount)
    else if not FModule.Tables[TableIndex].ElementType.Nullable then
      Fail('type mismatch: a table of non-nullable references needs an initializer');
  end;
  for Index := FModule.ImportedMemoryCount to High(FModule.Memories) do
    CheckMemoryType(FModule.Memories[Index]);
  if (Length(FModule.Memories) > 1) and not (wfMultipleMemories in FModule.Features) then
    Fail('multiple memories');
  if Length(FModule.Memories) > MaximumMemories then
    Fail('too many memories');
  for Index := 0 to High(FModule.GlobalDefinitions) do
    with FModule.GlobalDefinitions[Index] do
    begin
      CheckValueType(GlobalType.ValueType);
      FConstants.Check(Initializer, GlobalType.ValueType, FModule.ImportedGlobalCount + Cardinal(Index));
    end;
end;

procedure TModuleValidator.ValidateElements;
var
  Index, Item: Integer;
  Table: TWasmTableType;
begin
  for Index := 0 to High(FModule.Elements) do
    with FModule.Elements[Index] do
    begin
      CheckValueType(ElementType);
      if UsesExpressions then
      begin
        for Item := 0 to High(Expressions) do
          FConstants.Check(Expressions[Item], ElementType, Length(FModule.Globals));
      end
      else
        for Item := 0 to High(FunctionIndices) do
          if FunctionIndices[Item] >= FModule.FunctionCount then
            Fail('unknown function ' + IntToStr(FunctionIndices[Item]));
      if Mode = smActive then
      begin
        if TableIndex >= Cardinal(Length(FModule.Tables)) then
          Fail('unknown table ' + IntToStr(TableIndex));
        Table := FModule.Tables[TableIndex];
        FConstants.Check(Offset, MakeNumberType(Table.AddressType), Length(FModule.Globals));
        if not ValueTypeMatches(FContext, ElementType, Table.ElementType) then
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
        FConstants.Check(Offset, MakeNumberType(FModule.Memories[MemoryIndex].AddressType), Length(FModule.Globals));
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
          ekTag: Count := Length(FModule.TagTypes);
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
  CodeValidator := TWasmCodeValidator.Create(FModule, FContext, FDeclaredReferences);
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
  CanonicalizeModuleTypes(Module);
  FContext := TWasmModuleTypeContext.Create(Module);
  FConstants := TWasmConstantValidator.Create(Module, FContext);
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
