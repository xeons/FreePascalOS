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
  The type definition fields of a text module (core specification 3.0,
  section 6.4.9):

    (type $t? comptype)                 a final type without supertypes,
                                        in a recursion group of its own
    (type $t? (sub final? x* comptype)) a subtype
    (rec (type ...)*)                   a recursion group

  where a composite type is (func (param ...)* (result ...)*),
  (struct (field $f? fieldtype)* ...) with "(field fieldtype*)" naming
  none of several fields, or (array fieldtype); a field type is a
  storage type (a value type, i8 or i16) or (mut storagetype).

  Types may refer to types defined after them (in their group or not),
  so this happens in two steps: CollectTypeField gives every type its
  index and identifier while the module's fields are collected, and
  DefineTypes reads the definitions once all type identifiers are known.
}
unit WasmText.TypeDefinitions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree,
  WasmText.Types,
  WasmText.Context;

type
  { The "(type ...)" node of each type index. }
  TTypeNodeArray = array of TTextNode;

{ A "(type ...)" or "(rec ...)" field: its types get their indices. }
procedure CollectTypeField(Context: TModuleContext; Field: TTextNode; var TypeNodes: TTypeNodeArray);
{ Reads the definitions of the collected types. }
procedure DefineTypes(Context: TModuleContext; const TypeNodes: TTypeNodeArray);

implementation

procedure DeclareType(Context: TModuleContext; Node: TTextNode; var TypeNodes: TTypeNodeArray);
var
  Identifier: AnsiString;
begin
  if not Node.IsListOf('type') then
    Context.Fail(Node, 'unexpected token: expected a type definition');
  Identifier := '';
  if (Node.Count > 1) and Node[1].IsAtomOf(ttIdentifier) then
    Identifier := Node[1].Text;
  Context.DefineIndex(isType, Identifier, Node);
  SetLength(TypeNodes, Length(TypeNodes) + 1);
  TypeNodes[High(TypeNodes)] := Node;
end;

procedure CollectTypeField(Context: TModuleContext; Field: TTextNode; var TypeNodes: TTypeNodeArray);
var
  Index: Integer;
begin
  if Field.IsListOf('rec') then
  begin
    Context.AddTypeGroup(Field.Count - 1, True);
    for Index := 1 to Field.Count - 1 do
      DeclareType(Context, Field[Index], TypeNodes);
  end
  else
  begin
    Context.AddTypeGroup(1, False);
    DeclareType(Context, Field, TypeNodes);
  end;
end;

function ParseFieldType(Context: TModuleContext; Node: TTextNode): TFieldType;
begin
  Result.Mutable := Node.IsListOf('mut');
  if Result.Mutable then
  begin
    if Node.Count <> 2 then
      Context.Fail(Node, 'unexpected token in field type');
    Result.StorageType := Context.ParseStorageType(Node[1]);
  end
  else
    Result.StorageType := Context.ParseStorageType(Node);
end;

procedure AddField(var Definition: TTypeDefinition; const Field: TFieldType; const Name: AnsiString);
begin
  SetLength(Definition.Fields, Length(Definition.Fields) + 1);
  Definition.Fields[High(Definition.Fields)] := Field;
  SetLength(Definition.FieldNames, Length(Definition.FieldNames) + 1);
  Definition.FieldNames[High(Definition.FieldNames)] := Name;
end;

procedure ParseStruct(Context: TModuleContext; Node: TTextNode; var Definition: TTypeDefinition);
var
  Position, Index, Other: Integer;
  FieldNode: TTextNode;
begin
  Definition.Kind := ckStruct;
  for Position := 1 to Node.Count - 1 do
  begin
    FieldNode := Node[Position];
    if not FieldNode.IsListOf('field') then
      Context.Fail(FieldNode, 'unexpected token: expected a field');
    if (FieldNode.Count > 1) and FieldNode[1].IsAtomOf(ttIdentifier) then
    begin
      if FieldNode.Count <> 3 then
        Context.Fail(FieldNode, 'unexpected token: one type per named field');
      for Other := 0 to High(Definition.FieldNames) do
        if Definition.FieldNames[Other] = FieldNode[1].Text then
          Context.Fail(FieldNode, 'duplicate field ' + FieldNode[1].Text);
      AddField(Definition, ParseFieldType(Context, FieldNode[2]), FieldNode[1].Text);
    end
    else
      for Index := 1 to FieldNode.Count - 1 do
        AddField(Definition, ParseFieldType(Context, FieldNode[Index]), '');
  end;
end;

procedure ParseCompositeType(Context: TModuleContext; Node: TTextNode; var Definition: TTypeDefinition);
var
  Position: Integer;
  Names: TNameArray;
begin
  if Node.IsListOf('func') then
  begin
    Definition.Kind := ckFunction;
    Position := 1;
    Names := nil;
    Context.ParseSignature(Node, Position, True, Definition.FunctionType, Names);
    if Position <> Node.Count then
      Context.Fail(Node, 'unexpected token in function type');
  end
  else if Node.IsListOf('struct') then
    ParseStruct(Context, Node, Definition)
  else if Node.IsListOf('array') then
  begin
    Definition.Kind := ckArray;
    if Node.Count <> 2 then
      Context.Fail(Node, 'unexpected token in array type');
    AddField(Definition, ParseFieldType(Context, Node[1]), '');
  end
  else
    Context.Fail(Node, 'unexpected token: expected a composite type');
end;

function ParseTypeDefinition(Context: TModuleContext; Node: TTextNode): TTypeDefinition;
var
  Position: Integer;
  Body: TTextNode;
begin
  Result := Default(TTypeDefinition);
  Result.IsFinal := True;
  Position := 1;
  if (Position < Node.Count) and Node[Position].IsAtomOf(ttIdentifier) then
    Inc(Position);
  if Position <> Node.Count - 1 then
    Context.Fail(Node, 'unexpected token in type definition');
  Body := Node[Position];
  if Body.IsListOf('sub') then
  begin
    Position := 1;
    Result.IsFinal := (Position < Body.Count) and Body[Position].IsKeyword('final');
    if Result.IsFinal then
      Inc(Position);
    while (Position < Body.Count) and Context.IsIndex(Body[Position]) do
    begin
      SetLength(Result.SuperTypes, Length(Result.SuperTypes) + 1);
      Result.SuperTypes[High(Result.SuperTypes)] := Context.ResolveIndex(isType, Body[Position]);
      Inc(Position);
    end;
    if Position <> Body.Count - 1 then
      Context.Fail(Body, 'unexpected token in subtype');
    Body := Body[Position];
  end;
  ParseCompositeType(Context, Body, Result);
end;

procedure DefineTypes(Context: TModuleContext; const TypeNodes: TTypeNodeArray);
var
  Index: Integer;
begin
  for Index := 0 to High(TypeNodes) do
    Context.SetTypeDefinition(Index, ParseTypeDefinition(Context, TypeNodes[Index]));
end;

end.
