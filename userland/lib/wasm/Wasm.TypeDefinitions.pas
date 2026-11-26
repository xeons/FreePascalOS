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
  Defined types (spec 3.0, section 2.3.8): the entries of the type
  section, each a composite type (a function, struct or array type)
  with its subtyping declaration (final or not, at most one declared
  supertype), grouped in recursive type groups.

  Types are equivalent iso-recursively: two rec groups are the same when
  they have the same shape and refer to each other's members by the
  same positions and to outside types that are themselves equivalent.
  CanonicalGroupKey writes a group as a string in which references into
  the group are relative positions and references outside it go through
  a mapping (the module's canonical indices while validating, the
  store's type ids at run time), so equal keys mean equivalent groups.
}
unit Wasm.TypeDefinitions;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types;

type
  { A struct field's or an array element's storage: a value type, or
    one of the packed integers i8 and i16. }
  TWasmStorageKind = (skValue, skI8, skI16);

  TWasmFieldType = record
    Storage: TWasmStorageKind;
    ValueType: TWasmValueType;  { i32 for the packed kinds }
    Mutable: Boolean;
  end;
  TWasmFieldTypeArray = array of TWasmFieldType;

  TWasmCompositeKind = (ckFunction, ckStruct, ckArray);

  TWasmTypeDefinition = record
    Kind: TWasmCompositeKind;
    Final: Boolean;
    HasSuperType: Boolean;
    SuperType: Cardinal;
    FunctionType: TWasmFunctionType;  { ckFunction }
    Fields: TWasmFieldTypeArray;      { a struct's fields; an array's one element }
    { The rec group this type belongs to: its first type and size. }
    GroupStart: Cardinal;
    GroupSize: Cardinal;
  end;
  TWasmTypeDefinitionArray = array of TWasmTypeDefinition;

  { Maps a type index outside the group being keyed to the canonical
    number it is known by. }
  TWasmTypeIndexMapper = function(Index: Cardinal): Int64 of object;

  { How the collector treats a slot of a value type: not at all (numbers,
    the func hierarchy), as an object or i31 (any and exn hierarchies),
    or as an extern reference (which may be an embedder's pointer). }
  TWasmReferenceTrace = (rtNone, rtInternal, rtExternal);

{ The key of the rec group Definitions[First .. First + Count). }
function CanonicalGroupKey(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
  Mapper: TWasmTypeIndexMapper): AnsiString;
{ The same where references to ReferenceFirst .. + Count are the group's
  own members (ReferenceFirst -1: no reference is). }
function CanonicalGroupKeyAt(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
  ReferenceFirst: Int64; Mapper: TWasmTypeIndexMapper): AnsiString;

{ Struct layout: every field takes 8 bytes (a v128 16), in order. }
function StructFieldOffset(const Fields: TWasmFieldTypeArray; Index: Integer): Integer;
function StructPayloadSize(const Fields: TWasmFieldTypeArray): Integer;
{ ConcreteIsFunction: whether a concrete heap type of ValueType is a
  function type (the caller knows its type context). }
function ReferenceTrace(const ValueType: TWasmValueType; ConcreteIsFunction: Boolean): TWasmReferenceTrace;

{ The value type of a field as read (packed fields read as i32). }
function FieldValueType(const Field: TWasmFieldType): TWasmValueType; inline;
{ The bytes an array element of the storage takes (1, 2, 4, 8 or 16). }
function StorageSize(const Field: TWasmFieldType): Integer;
function IsPackedField(const Field: TWasmFieldType): Boolean; inline;
function CompositeKindName(Kind: TWasmCompositeKind): AnsiString;

implementation

uses
  SysUtils;

function FieldValueType(const Field: TWasmFieldType): TWasmValueType;
begin
  if Field.Storage = skValue then
    Result := Field.ValueType
  else
    Result := WasmI32Type;
end;

function IsPackedField(const Field: TWasmFieldType): Boolean;
begin
  Result := Field.Storage <> skValue;
end;

function StorageSize(const Field: TWasmFieldType): Integer;
begin
  case Field.Storage of
    skI8: Result := 1;
    skI16: Result := 2;
  else
    case Field.ValueType.Kind of
      vkI32, vkF32: Result := 4;
      vkV128: Result := 16;
    else
      Result := 8;
    end;
  end;
end;

function CompositeKindName(Kind: TWasmCompositeKind): AnsiString;
begin
  case Kind of
    ckFunction: Result := 'func';
    ckStruct: Result := 'struct';
  else
    Result := 'array';
  end;
end;

function StructFieldOffset(const Fields: TWasmFieldTypeArray; Index: Integer): Integer;
var
  Item: Integer;
begin
  Result := 0;
  for Item := 0 to Index - 1 do
    if (Fields[Item].Storage = skValue) and (Fields[Item].ValueType.Kind = vkV128) then
      Inc(Result, 16)
    else
      Inc(Result, 8);
end;

function StructPayloadSize(const Fields: TWasmFieldTypeArray): Integer;
begin
  Result := StructFieldOffset(Fields, Length(Fields));
end;

function ReferenceTrace(const ValueType: TWasmValueType; ConcreteIsFunction: Boolean): TWasmReferenceTrace;
begin
  if ValueType.Kind <> vkReference then
    Exit(rtNone);
  if ValueType.HeapType >= 0 then
  begin
    if ConcreteIsFunction then
      Result := rtNone
    else
      Result := rtInternal;
    Exit;
  end;
  case AbstractHeapTypeTop(ValueType.HeapType) of
    HeapTypeFunc: Result := rtNone;
    HeapTypeExtern: Result := rtExternal;
  else
    Result := rtInternal;
  end;
end;

function CanonicalGroupKey(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
  Mapper: TWasmTypeIndexMapper): AnsiString;
begin
  Result := CanonicalGroupKeyAt(Definitions, First, Count, First, Mapper);
end;

function CanonicalGroupKeyAt(const Definitions: TWasmTypeDefinitionArray; First, Count: Cardinal;
  ReferenceFirst: Int64; Mapper: TWasmTypeIndexMapper): AnsiString;
var
  Builder: AnsiString;

  procedure AddTypeReference(Index: Cardinal);
  begin
    if (ReferenceFirst >= 0) and (Index >= ReferenceFirst) and (Index < ReferenceFirst + Count) then
      Builder := Builder + 'r' + IntToStr(Index - ReferenceFirst)
    else
      Builder := Builder + 'x' + IntToStr(Mapper(Index));
  end;

  procedure AddValueType(const ValueType: TWasmValueType);
  begin
    Builder := Builder + IntToStr(Ord(ValueType.Kind));
    if ValueType.Kind = vkReference then
    begin
      if ValueType.Nullable then
        Builder := Builder + 'n';
      if ValueType.HeapType < 0 then
        Builder := Builder + 'a' + IntToStr(-ValueType.HeapType)
      else
        AddTypeReference(Cardinal(ValueType.HeapType));
    end;
    Builder := Builder + ',';
  end;

  procedure AddField(const Field: TWasmFieldType);
  begin
    Builder := Builder + IntToStr(Ord(Field.Storage)) + IntToStr(Ord(Field.Mutable));
    if Field.Storage = skValue then
      AddValueType(Field.ValueType)
    else
      Builder := Builder + ',';
  end;

var
  Index: Cardinal;
  Item: Integer;
begin
  Builder := IntToStr(Count) + ':';
  Index := First;
  while Index < First + Count do
  begin
    with Definitions[Index] do
    begin
      Builder := Builder + '(' + IntToStr(Ord(Kind)) + IntToStr(Ord(Final));
      if HasSuperType then
      begin
        Builder := Builder + 's';
        AddTypeReference(SuperType);
      end;
      Builder := Builder + '|';
      case Kind of
        ckFunction:
          begin
            for Item := 0 to High(FunctionType.Params) do
              AddValueType(FunctionType.Params[Item]);
            Builder := Builder + '>';
            for Item := 0 to High(FunctionType.Results) do
              AddValueType(FunctionType.Results[Item]);
          end;
      else
        for Item := 0 to High(Fields) do
          AddField(Fields[Item]);
      end;
      Builder := Builder + ')';
    end;
    Inc(Index);
  end;
  Result := Builder;
end;

end.
