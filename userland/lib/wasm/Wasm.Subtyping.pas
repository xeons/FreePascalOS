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
  Subtyping (spec 3.0, section 3.3): heap types form four hierarchies,

    any > eq > i31, struct > (struct types), array > (array types)
    func > (function types)
    extern
    exn

  each with a bottom (none, nofunc, noextern, noexn) below every type in
  it; concrete types are below their declared supertypes. A reference
  type matches another when its heap type does and it is not nullable
  where the other is not.

  What a concrete type index means depends on where the type is: a
  module's canonical type index while validating, a store's type id at
  run time. TWasmTypeContext answers the two questions subtyping asks of
  a concrete type (its kind and its declared supertype) for either.
}
unit Wasm.Subtyping;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types,
  Wasm.TypeDefinitions;

type
  TWasmTypeContext = class
  public
    function KindOf(TypeIndex: Int32): TWasmCompositeKind; virtual; abstract;
    { The declared supertype of a concrete type; False if it has none. }
    function SuperTypeOf(TypeIndex: Int32; out SuperType: Int32): Boolean; virtual; abstract;
  end;

function HeapTypeMatches(Context: TWasmTypeContext; Sub, Super: Int32): Boolean;
function ValueTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmValueType): Boolean;
{ The top of the hierarchy a heap type belongs to (any, func, extern, exn). }
function HeapTypeTop(Context: TWasmTypeContext; HeapType: Int32): Int32;
{ Field and composite type subtyping (for declared supertypes). }
function FieldTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmFieldType): Boolean;
function FunctionTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmFunctionType): Boolean;

implementation

function KindTop(Kind: TWasmCompositeKind): Int32;
begin
  if Kind = ckFunction then
    Result := HeapTypeFunc
  else
    Result := HeapTypeAny;
end;

function HeapTypeTop(Context: TWasmTypeContext; HeapType: Int32): Int32;
begin
  if HeapType >= 0 then
    Result := KindTop(Context.KindOf(HeapType))
  else
    Result := AbstractHeapTypeTop(HeapType);
end;

function AbstractMatches(Sub, Super: Int32): Boolean;
begin
  if Sub = Super then
    Exit(True);
  case Super of
    HeapTypeAny:
      Result := (Sub = HeapTypeEq) or (Sub = HeapTypeI31) or (Sub = HeapTypeStruct) or (Sub = HeapTypeArray) or
        (Sub = HeapTypeNone);
    HeapTypeEq:
      Result := (Sub = HeapTypeI31) or (Sub = HeapTypeStruct) or (Sub = HeapTypeArray) or (Sub = HeapTypeNone);
    HeapTypeI31, HeapTypeStruct, HeapTypeArray: Result := Sub = HeapTypeNone;
    HeapTypeFunc: Result := Sub = HeapTypeNoFunc;
    HeapTypeExtern: Result := Sub = HeapTypeNoExtern;
    HeapTypeExn: Result := Sub = HeapTypeNoExn;
  else
    Result := False;
  end;
end;

function HeapTypeMatches(Context: TWasmTypeContext; Sub, Super: Int32): Boolean;
var
  Kind: TWasmCompositeKind;
  Current, Next, Depth: Int32;
begin
  if Sub = Super then
    Exit(True);
  if (Sub < 0) and (Super < 0) then
    Exit(AbstractMatches(Sub, Super));
  if Sub < 0 then
  begin
    { A bottom type below a concrete type of its hierarchy. }
    Kind := Context.KindOf(Super);
    if Kind = ckFunction then
      Result := Sub = HeapTypeNoFunc
    else
      Result := Sub = HeapTypeNone;
    Exit;
  end;
  Kind := Context.KindOf(Sub);
  if Super < 0 then
  begin
    case Super of
      HeapTypeAny, HeapTypeEq: Result := Kind in [ckStruct, ckArray];
      HeapTypeStruct: Result := Kind = ckStruct;
      HeapTypeArray: Result := Kind = ckArray;
      HeapTypeFunc: Result := Kind = ckFunction;
    else
      Result := False;
    end;
    Exit;
  end;
  { Both concrete: up the declared supertypes. }
  Current := Sub;
  Depth := 0;
  while Context.SuperTypeOf(Current, Next) and (Depth <= 64) do
  begin
    if Next = Super then
      Exit(True);
    Current := Next;
    Inc(Depth);
  end;
  Result := False;
end;

function ValueTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmValueType): Boolean;
begin
  if Sub.Kind <> Super.Kind then
    Exit(False);
  if Sub.Kind <> vkReference then
    Exit(True);
  if Sub.Nullable and not Super.Nullable then
    Exit(False);
  Result := HeapTypeMatches(Context, Sub.HeapType, Super.HeapType);
end;

function FieldTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmFieldType): Boolean;
begin
  if (Sub.Mutable <> Super.Mutable) or (Sub.Storage <> Super.Storage) then
    Exit(False);
  if Sub.Storage <> skValue then
    Exit(True);
  if Sub.Mutable then
    Result := ValueTypeMatches(Context, Sub.ValueType, Super.ValueType) and
      ValueTypeMatches(Context, Super.ValueType, Sub.ValueType)
  else
    Result := ValueTypeMatches(Context, Sub.ValueType, Super.ValueType);
end;

function FunctionTypeMatches(Context: TWasmTypeContext; const Sub, Super: TWasmFunctionType): Boolean;
var
  Index: Integer;
begin
  if (Length(Sub.Params) <> Length(Super.Params)) or (Length(Sub.Results) <> Length(Super.Results)) then
    Exit(False);
  for Index := 0 to High(Sub.Params) do
    if not ValueTypeMatches(Context, Super.Params[Index], Sub.Params[Index]) then
      Exit(False);
  for Index := 0 to High(Sub.Results) do
    if not ValueTypeMatches(Context, Sub.Results[Index], Super.Results[Index]) then
      Exit(False);
  Result := True;
end;

end.
