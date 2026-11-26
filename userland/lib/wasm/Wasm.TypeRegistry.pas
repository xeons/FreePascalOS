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
  A store's canonical types (spec 3.0, section 4.2.1: defined types
  are closed over the rec groups they come from, so equivalent types of
  different modules are the same type).

  Every rec group a module defines is registered by its canonical key
  (Wasm.TypeDefinitions), with references outside the group written as
  type ids of the store: a group equivalent to one registered before
  gets the same ids, a new one the next ids in a row. A host function's
  type is a group of one final function type. The run time's types
  (functions, globals, tables, tags) name these ids as heap types.

  Each type records its supertype chain (Ancestors: the ids from the
  root down to itself), so a run time subtype test is one comparison,
  and for structs and arrays what the collector needs: the payload size,
  the traced fields, the element size.
}
unit Wasm.TypeRegistry;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Subtyping,
  Wasm.GcHeap,
  Wasm.Module;

type
  TWasmRuntimeType = class(TWasmGcDescriptor)
  public
    Id: Integer;
    Definition: TWasmTypeDefinition;  { heap types are store ids }
    Depth: Integer;
    Ancestors: array of Integer;
    PayloadSize: Integer;             { structs }
    function IsSubtypeOf(Other: TWasmRuntimeType): Boolean; inline;
  end;

  TWasmIdArray = array of Integer;

  TWasmTypeRegistry = class(TWasmTypeContext)
  private
    FTypes: array of TWasmRuntimeType;
    FCount: Integer;
    FKeys: TStringList;
    FModuleIds: TWasmIdArray;   { while registering a module }
    function MapModuleIndex(Index: Cardinal): Int64;
    function MapIdentity(Index: Cardinal): Int64;
    function AddGroup(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
      const Key: AnsiString; ReferenceFirst: Int64; const OutsideIds: TWasmIdArray): Integer;
    procedure Complete(RuntimeType: TWasmRuntimeType);
  public
    constructor Create;
    destructor Destroy; override;
    { The store id of each of the module's type indices. }
    function RegisterModule(Module: TWasmModule): TWasmIdArray;
    { A function type whose heap types are store ids already. }
    function RegisterFunctionType(const FunctionType: TWasmFunctionType): Integer;
    function TypeOf(Id: Integer): TWasmRuntimeType; inline;
    function IsSubtype(SubId, SuperId: Integer): Boolean;
    function KindOf(TypeIndex: Int32): TWasmCompositeKind; override;
    function SuperTypeOf(TypeIndex: Int32; out SuperType: Int32): Boolean; override;
    property TypeCount: Integer read FCount;
  end;

implementation

uses
  SysUtils;

function TWasmRuntimeType.IsSubtypeOf(Other: TWasmRuntimeType): Boolean;
begin
  Result := (Other = Self) or ((Other.Depth < Depth) and (Ancestors[Other.Depth] = Other.Id));
end;

constructor TWasmTypeRegistry.Create;
begin
  inherited Create;
  FKeys := TStringList.Create;
  FKeys.Sorted := True;
  FKeys.CaseSensitive := True;
end;

destructor TWasmTypeRegistry.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    FTypes[Index].Free;
  FKeys.Free;
  inherited Destroy;
end;

function TWasmTypeRegistry.TypeOf(Id: Integer): TWasmRuntimeType;
begin
  Result := FTypes[Id];
end;

function TWasmTypeRegistry.KindOf(TypeIndex: Int32): TWasmCompositeKind;
begin
  if (TypeIndex >= 0) and (TypeIndex < FCount) then
    Result := FTypes[TypeIndex].Definition.Kind
  else
    Result := ckStruct;
end;

function TWasmTypeRegistry.SuperTypeOf(TypeIndex: Int32; out SuperType: Int32): Boolean;
begin
  SuperType := 0;
  Result := (TypeIndex >= 0) and (TypeIndex < FCount) and FTypes[TypeIndex].Definition.HasSuperType;
  if Result then
    SuperType := FTypes[TypeIndex].Definition.SuperType;
end;

function TWasmTypeRegistry.IsSubtype(SubId, SuperId: Integer): Boolean;
begin
  Result := (SubId = SuperId) or FTypes[SubId].IsSubtypeOf(FTypes[SuperId]);
end;

function TWasmTypeRegistry.MapModuleIndex(Index: Cardinal): Int64;
begin
  Result := FModuleIds[Index];
end;

function TWasmTypeRegistry.MapIdentity(Index: Cardinal): Int64;
begin
  Result := Index;
end;

{ Layout and collector information of a new type. }
procedure TWasmTypeRegistry.Complete(RuntimeType: TWasmRuntimeType);
var
  Item, Count: Integer;
  Trace: TWasmReferenceTrace;
  Field: TWasmFieldType;

  function IsFunctionId(const ValueType: TWasmValueType): Boolean;
  begin
    Result := (ValueType.HeapType >= 0) and (KindOf(ValueType.HeapType) = ckFunction);
  end;

begin
  with RuntimeType do
  begin
    if Definition.HasSuperType then
    begin
      Depth := FTypes[Definition.SuperType].Depth + 1;
      Ancestors := Copy(FTypes[Definition.SuperType].Ancestors);
    end
    else
    begin
      Depth := 0;
      Ancestors := nil;
    end;
    SetLength(Ancestors, Depth + 1);
    Ancestors[Depth] := Id;
    case Definition.Kind of
      ckStruct:
        begin
          PayloadSize := StructPayloadSize(Definition.Fields);
          Count := 0;
          for Item := 0 to High(Definition.Fields) do
          begin
            Field := Definition.Fields[Item];
            if Field.Storage <> skValue then
              Continue;
            Trace := ReferenceTrace(Field.ValueType, IsFunctionId(Field.ValueType));
            if Trace = rtNone then
              Continue;
            SetLength(TracedOffsets, Count + 1);
            TracedOffsets[Count] := StructFieldOffset(Definition.Fields, Item) * 2 + Ord(Trace = rtExternal);
            Inc(Count);
          end;
        end;
      ckArray:
        begin
          Field := Definition.Fields[0];
          ElementSize := StorageSize(Field);
          Trace := rtNone;
          if Field.Storage = skValue then
            Trace := ReferenceTrace(Field.ValueType, IsFunctionId(Field.ValueType));
          ElementsTraced := Trace <> rtNone;
          ElementsExternal := Trace = rtExternal;
        end;
    end;
  end;
end;

function TWasmTypeRegistry.AddGroup(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
  const Key: AnsiString; ReferenceFirst: Int64; const OutsideIds: TWasmIdArray): Integer;
var
  Member: Cardinal;
  RuntimeType: TWasmRuntimeType;
  BaseId: Integer;

  procedure MapValueType(var ValueType: TWasmValueType);
  begin
    if (ValueType.Kind <> vkReference) or (ValueType.HeapType < 0) then
      Exit;
    if (ReferenceFirst >= 0) and (ValueType.HeapType >= ReferenceFirst) and
      (ValueType.HeapType < ReferenceFirst + Count) then
      ValueType.HeapType := BaseId + (ValueType.HeapType - ReferenceFirst)
    else if OutsideIds <> nil then
      ValueType.HeapType := OutsideIds[ValueType.HeapType];
  end;

var
  Item: Integer;
begin
  Result := FCount;
  BaseId := Result;
  if FCount + Integer(Count) > Length(FTypes) then
    SetLength(FTypes, (FCount + Integer(Count)) * 2 + 16);
  Member := 0;
  while Member < Count do
  begin
    RuntimeType := TWasmRuntimeType.Create;
    RuntimeType.Id := Result + Integer(Member);
    RuntimeType.Definition := Definitions[First + Member];
    with RuntimeType.Definition do
    begin
      FunctionType.Params := Copy(FunctionType.Params);
      FunctionType.Results := Copy(FunctionType.Results);
      Fields := Copy(Fields);
      for Item := 0 to High(FunctionType.Params) do
        MapValueType(FunctionType.Params[Item]);
      for Item := 0 to High(FunctionType.Results) do
        MapValueType(FunctionType.Results[Item]);
      for Item := 0 to High(Fields) do
        MapValueType(Fields[Item].ValueType);
      if HasSuperType then
      begin
        if (ReferenceFirst >= 0) and (SuperType >= ReferenceFirst) and (SuperType < ReferenceFirst + Count) then
          SuperType := Result + Integer(SuperType - ReferenceFirst)
        else if OutsideIds <> nil then
          SuperType := OutsideIds[SuperType];
      end;
      GroupStart := Result;
      GroupSize := Count;
    end;
    FTypes[FCount] := RuntimeType;
    Inc(FCount);
    Inc(Member);
  end;
  for Member := 0 to Count - 1 do
    Complete(FTypes[Result + Integer(Member)]);
  FKeys.AddObject(Key, TObject(PtrInt(Result)));
end;

function TWasmTypeRegistry.RegisterModule(Module: TWasmModule): TWasmIdArray;
var
  First, Count, Member, Canonical: Cardinal;
  Key: AnsiString;
  Found, FirstId: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Module.TypeDefinitions));
  FModuleIds := Result;
  First := 0;
  while First < Cardinal(Length(Module.TypeDefinitions)) do
  begin
    Count := Module.TypeDefinitions[First].GroupSize;
    Canonical := Module.CanonicalType(First);
    if Canonical <> First then
    begin
      { An equivalent group came earlier in the module. }
      for Member := 0 to Count - 1 do
        Result[First + Member] := Result[Canonical + Member];
    end
    else
    begin
      Key := CanonicalGroupKey(Module.TypeDefinitions, First, Count, @MapModuleIndex);
      if FKeys.Find(Key, Found) then
        FirstId := PtrInt(FKeys.Objects[Found])
      else
        FirstId := AddGroup(Module.TypeDefinitions, First, Count, Key, First, Result);
      for Member := 0 to Count - 1 do
        Result[First + Member] := FirstId + Integer(Member);
    end;
    FModuleIds := Result;
    Inc(First, Count);
  end;
  FModuleIds := nil;
end;

function TWasmTypeRegistry.RegisterFunctionType(const FunctionType: TWasmFunctionType): Integer;
var
  Definitions: TWasmTypeDefinitionArray;
  Key: AnsiString;
  Found: Integer;
begin
  Definitions := nil;
  SetLength(Definitions, 1);
  Definitions[0].Kind := ckFunction;
  Definitions[0].Final := True;
  Definitions[0].HasSuperType := False;
  Definitions[0].FunctionType := FunctionType;
  Definitions[0].GroupStart := 0;
  Definitions[0].GroupSize := 1;
  Key := CanonicalGroupKeyAt(Definitions, 0, 1, -1, @MapIdentity);
  if FKeys.Find(Key, Found) then
    Exit(PtrInt(FKeys.Objects[Found]));
  Result := AddGroup(Definitions, 0, 1, Key, -1, nil);
end;

end.
