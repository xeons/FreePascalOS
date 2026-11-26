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
  A module's type section validated and made canonical (spec 3.0,
  sections 3.2.11 and 3.5.1).

  Rec groups are taken in order. A group may refer to its own members
  and to earlier types, nothing later; each member's supertype must come
  before it, not be final, be of the same kind and be matched by it
  (function parameters contravariantly, results and immutable fields
  covariantly, mutable fields exactly), at most 63 deep. Each group gets
  its canonical key (Wasm.TypeDefinitions); the first group with a key
  is where its members' canonical indices point. Then every concrete
  heap type in the module's value types is replaced by its canonical
  index, so type equality is record equality from here on.

  TWasmModuleTypeContext answers subtyping's questions (Wasm.Subtyping)
  about a module's (canonical) type indices.
}
unit Wasm.ModuleTypes;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Subtyping,
  Wasm.Module;

type
  TWasmModuleTypeContext = class(TWasmTypeContext)
  private
    FModule: TWasmModule;
  public
    constructor Create(AModule: TWasmModule);
    function KindOf(TypeIndex: Int32): TWasmCompositeKind; override;
    function SuperTypeOf(TypeIndex: Int32; out SuperType: Int32): Boolean; override;
    property Module: TWasmModule read FModule;
  end;

{ Validates the type section and rewrites the module's value types with
  canonical type indices; raises EWasmInvalid. }
procedure CanonicalizeModuleTypes(Module: TWasmModule);

implementation

uses
  SysUtils,
  Wasm.Errors,
  Wasm.Limits;

type
  TTypeCanonicalizer = class
  private
    FModule: TWasmModule;
    FContext: TWasmModuleTypeContext;
    FCanonical: array of Cardinal;
    FDepths: array of Integer;
    FKeys: TStringList;
    FLimit: Cardinal;   { references must be below this while checking a group }
    procedure Fail(const Message: AnsiString);
    function MapOutside(Index: Cardinal): Int64;
    procedure CheckTypeIndex(Index: Cardinal);
    procedure CheckValueType(const ValueType: TWasmValueType);
    procedure CanonicalizeValueType(var ValueType: TWasmValueType);
    procedure CanonicalizeValueTypes(var Types: TWasmValueTypeArray);
    procedure CheckGroupReferences(First, Count: Cardinal);
    procedure CanonicalizeDefinition(var Definition: TWasmTypeDefinition);
    procedure CheckSubtype(Index: Cardinal);
    procedure CanonicalizeRest;
  public
    constructor Create(AModule: TWasmModule);
    destructor Destroy; override;
    procedure Run;
  end;

{ TWasmModuleTypeContext }

constructor TWasmModuleTypeContext.Create(AModule: TWasmModule);
begin
  inherited Create;
  FModule := AModule;
end;

function TWasmModuleTypeContext.KindOf(TypeIndex: Int32): TWasmCompositeKind;
begin
  if (TypeIndex >= 0) and (TypeIndex < Length(FModule.TypeDefinitions)) then
    Result := FModule.TypeDefinitions[TypeIndex].Kind
  else
    Result := ckStruct;
end;

function TWasmModuleTypeContext.SuperTypeOf(TypeIndex: Int32; out SuperType: Int32): Boolean;
begin
  SuperType := 0;
  Result := (TypeIndex >= 0) and (TypeIndex < Length(FModule.TypeDefinitions)) and
    FModule.TypeDefinitions[TypeIndex].HasSuperType;
  if Result then
    SuperType := FModule.TypeDefinitions[TypeIndex].SuperType;
end;

{ TTypeCanonicalizer }

constructor TTypeCanonicalizer.Create(AModule: TWasmModule);
begin
  inherited Create;
  FModule := AModule;
  FContext := TWasmModuleTypeContext.Create(AModule);
  FKeys := TStringList.Create;
  FKeys.Sorted := True;
  FKeys.CaseSensitive := True;
end;

destructor TTypeCanonicalizer.Destroy;
begin
  FKeys.Free;
  FContext.Free;
  inherited Destroy;
end;

procedure TTypeCanonicalizer.Fail(const Message: AnsiString);
begin
  raise EWasmInvalid.CreateAt(0, Message);
end;

function TTypeCanonicalizer.MapOutside(Index: Cardinal): Int64;
begin
  Result := FCanonical[Index];
end;

procedure TTypeCanonicalizer.CheckTypeIndex(Index: Cardinal);
begin
  if Index >= FLimit then
    Fail('unknown type ' + IntToStr(Index));
end;

procedure TTypeCanonicalizer.CheckValueType(const ValueType: TWasmValueType);
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType >= 0) then
    CheckTypeIndex(Cardinal(ValueType.HeapType));
end;

procedure TTypeCanonicalizer.CanonicalizeValueType(var ValueType: TWasmValueType);
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType >= 0) then
  begin
    CheckTypeIndex(Cardinal(ValueType.HeapType));
    ValueType.HeapType := FCanonical[ValueType.HeapType];
  end;
end;

procedure TTypeCanonicalizer.CanonicalizeValueTypes(var Types: TWasmValueTypeArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Types) do
    CanonicalizeValueType(Types[Index]);
end;

procedure TTypeCanonicalizer.CheckGroupReferences(First, Count: Cardinal);
var
  Index: Cardinal;
  Item: Integer;
begin
  FLimit := First + Count;
  Index := First;
  while Index < First + Count do
  begin
    with FModule.TypeDefinitions[Index] do
    begin
      if HasSuperType and (SuperType >= Index) then
        Fail('unknown type ' + IntToStr(SuperType));
      for Item := 0 to High(FunctionType.Params) do
        CheckValueType(FunctionType.Params[Item]);
      for Item := 0 to High(FunctionType.Results) do
        CheckValueType(FunctionType.Results[Item]);
      for Item := 0 to High(Fields) do
        CheckValueType(Fields[Item].ValueType);
    end;
    Inc(Index);
  end;
end;

procedure TTypeCanonicalizer.CanonicalizeDefinition(var Definition: TWasmTypeDefinition);
var
  Item: Integer;
begin
  if Definition.HasSuperType then
    Definition.SuperType := FCanonical[Definition.SuperType];
  CanonicalizeValueTypes(Definition.FunctionType.Params);
  CanonicalizeValueTypes(Definition.FunctionType.Results);
  for Item := 0 to High(Definition.Fields) do
    CanonicalizeValueType(Definition.Fields[Item].ValueType);
end;

procedure TTypeCanonicalizer.CheckSubtype(Index: Cardinal);
var
  Definition, Super: TWasmTypeDefinition;
  Item: Integer;
  Matches: Boolean;
begin
  Definition := FModule.TypeDefinitions[Index];
  FDepths[Index] := 0;
  if not Definition.HasSuperType then
    Exit;
  Super := FModule.TypeDefinitions[Definition.SuperType];
  FDepths[Index] := FDepths[Definition.SuperType] + 1;
  if FDepths[Index] > MaximumSubtypeDepth then
    Fail('subtype depth limit');
  if Super.Final or (Super.Kind <> Definition.Kind) then
    Fail('sub type ' + IntToStr(Index) + ' does not match super type');
  case Definition.Kind of
    ckFunction:
      Matches := FunctionTypeMatches(FContext, Definition.FunctionType, Super.FunctionType);
  else
    begin
      Matches := Length(Definition.Fields) >= Length(Super.Fields);
      if Definition.Kind = ckArray then
        Matches := Length(Definition.Fields) = Length(Super.Fields);
      if Matches then
        for Item := 0 to High(Super.Fields) do
          if not FieldTypeMatches(FContext, Definition.Fields[Item], Super.Fields[Item]) then
            Matches := False;
    end;
  end;
  if not Matches then
    Fail('sub type ' + IntToStr(Index) + ' does not match super type');
end;

procedure TTypeCanonicalizer.CanonicalizeRest;
var
  Index, Item: Integer;
begin
  FLimit := Length(FModule.TypeDefinitions);
  for Index := 0 to High(FModule.TypeDefinitions) do
    if FModule.TypeDefinitions[Index].Kind = ckFunction then
      FModule.Types[Index] := FModule.TypeDefinitions[Index].FunctionType
    else
      FModule.Types[Index] := Default(TWasmFunctionType);
  for Index := 0 to High(FModule.Imports) do
    with FModule.Imports[Index] do
    begin
      CanonicalizeValueType(TableType.ElementType);
      CanonicalizeValueType(GlobalType.ValueType);
    end;
  for Index := 0 to High(FModule.Tables) do
    CanonicalizeValueType(FModule.Tables[Index].ElementType);
  for Index := 0 to High(FModule.Globals) do
    CanonicalizeValueType(FModule.Globals[Index].ValueType);
  for Index := 0 to High(FModule.GlobalDefinitions) do
    CanonicalizeValueType(FModule.GlobalDefinitions[Index].GlobalType.ValueType);
  for Index := 0 to High(FModule.Elements) do
    CanonicalizeValueType(FModule.Elements[Index].ElementType);
  for Index := 0 to High(FModule.Bodies) do
    for Item := 0 to High(FModule.Bodies[Index].Locals) do
      CanonicalizeValueType(FModule.Bodies[Index].Locals[Item]);
end;

procedure TTypeCanonicalizer.Run;
var
  First, Count, Member: Cardinal;
  Key: AnsiString;
  Found: Integer;
  Representative: Cardinal;
begin
  SetLength(FCanonical, Length(FModule.TypeDefinitions));
  SetLength(FDepths, Length(FModule.TypeDefinitions));
  First := 0;
  while First < Cardinal(Length(FModule.TypeDefinitions)) do
  begin
    Count := FModule.TypeDefinitions[First].GroupSize;
    CheckGroupReferences(First, Count);
    Key := CanonicalGroupKey(FModule.TypeDefinitions, First, Count, @MapOutside);
    if FKeys.Find(Key, Found) then
      Representative := Cardinal(PtrUInt(FKeys.Objects[Found]))
    else
    begin
      Representative := First;
      FKeys.AddObject(Key, TObject(PtrUInt(First)));
    end;
    for Member := 0 to Count - 1 do
      FCanonical[First + Member] := Representative + Member;
    for Member := 0 to Count - 1 do
      CanonicalizeDefinition(FModule.TypeDefinitions[First + Member]);
    for Member := 0 to Count - 1 do
      CheckSubtype(First + Member);
    Inc(First, Count);
  end;
  FModule.CanonicalTypes := FCanonical;
  CanonicalizeRest;
end;

procedure CanonicalizeModuleTypes(Module: TWasmModule);
var
  Canonicalizer: TTypeCanonicalizer;
begin
  Canonicalizer := TTypeCanonicalizer.Create(Module);
  try
    Canonicalizer.Run;
  finally
    Canonicalizer.Free;
  end;
end;

end.
