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
  What the module encoder and the instruction encoder share while a text
  module is turned into binary: the index spaces with their identifiers
  (core specification 3.0, section 6.6.1, the identifier context), the
  type definitions (see WasmText.Types; the "(type ...)" and "(rec ...)"
  fields are read by WasmText.TypeDefinitions), value, reference and heap
  types, and type uses with the implicit types they add.

  An implicit type use (parameters and results without "(type x)")
  stands for the first type that is a function type alone in its
  recursion group, final and without supertypes, with the same
  parameters and results; when there is none, such a type is appended
  after all the others, in the order the uses are met.

  Nothing here validates: an index past the end of its space is encoded
  as written, for the validator to reject.
}
unit WasmText.Context;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree,
  WasmText.Types;

type
  TNameArray = WasmText.Types.TNameArray;
  TFunctionType = WasmText.Types.TFunctionType;

  TIndexSpace = (isType, isFunction, isTable, isMemory, isGlobal, isElement, isData, isTag);

  TTypeUse = record
    HasTypeIndex: Boolean;
    TypeIndex: Cardinal;
    Parameters: TValueTypeArray;
    Results: TValueTypeArray;
    { The identifiers of the inline parameters ('' when unnamed). }
    ParameterNames: TNameArray;
  end;

  TTypeUsePurpose = (tuFunction, tuInstruction);

  TModuleContext = class
  private
    FIdentifiers: array[TIndexSpace] of TStringList;
    FDefinitions: array of TTypeDefinition;
    FDefinitionCount: Integer;
    FGroups: array of TTypeGroup;
    FGroupCount: Integer;
    function GetDefinition(Index: Integer): TTypeDefinition;
    function GetGroup(Index: Integer): TTypeGroup;
  public
    Counts: array[TIndexSpace] of Cardinal;
    { Set when code uses memory.init, data.drop or another data index:
      the data count section then has to be there. }
    UsesDataIndices: Boolean;
    { The number of types written as type definitions (known once the
      fields are collected); an inline signature can only be checked
      against those. }
    ExplicitTypeCount: Cardinal;
    constructor Create;
    destructor Destroy; override;
    procedure Fail(Node: TTextNode; const Message: AnsiString);
    { Takes the next index of Space, naming it Identifier (when not ''). }
    function DefineIndex(Space: TIndexSpace; const Identifier: AnsiString; Node: TTextNode): Cardinal;
    { An index written as a number or an identifier. }
    function ResolveIndex(Space: TIndexSpace; Node: TTextNode): Cardinal;
    function IsIndex(Node: TTextNode): Boolean;
    { Reserves a recursion group of Count type definitions (filled in
      with SetTypeDefinition); returns the first one's index. }
    function AddTypeGroup(Count: Cardinal; IsRecursive: Boolean): Cardinal;
    procedure SetTypeDefinition(Index: Cardinal; const Definition: TTypeDefinition);
    { Appends a function type in a group of its own. }
    function AddType(const FunctionType: TFunctionType): Cardinal;
    { A field of structure type TypeIndex, by number or identifier. }
    function ResolveField(TypeIndex: Cardinal; Node: TTextNode): Cardinal;
    function ParseHeapType(Node: TTextNode): TValueType;
    function IsReferenceType(Node: TTextNode): Boolean;
    function ParseReferenceType(Node: TTextNode): TValueType;
    function IsValueType(Node: TTextNode): Boolean;
    function ParseValueType(Node: TTextNode): TValueType;
    { A value type or a packed type (i8, i16). }
    function ParseStorageType(Node: TTextNode): TValueType;
    { Reads (param ...)* (result ...)* from Parent's children at
      Position on; with Names, parameters may carry identifiers. }
    procedure ParseSignature(Parent: TTextNode; var Position: Integer; AllowNames: Boolean;
      var FunctionType: TFunctionType; var Names: TNameArray);
    { (type x)? (param ...)* (result ...)*, checked against type x when
      both are written. }
    function ParseTypeUse(Parent: TTextNode; var Position: Integer; Purpose: TTypeUsePurpose): TTypeUse;
    { The type index of a type use: its own, or the first equal
      standalone function type, or a new type appended. }
    function TypeIndexOf(const TypeUse: TTypeUse): Cardinal;
    function FunctionTypeOf(const TypeUse: TTypeUse): TFunctionType;
    property Definitions[Index: Integer]: TTypeDefinition read GetDefinition;
    property TypeCount: Integer read FDefinitionCount;
    property Groups[Index: Integer]: TTypeGroup read GetGroup;
    property GroupCount: Integer read FGroupCount;
  end;

function SpaceName(Space: TIndexSpace): AnsiString;

implementation

uses
  WasmText.Numbers;

function SpaceName(Space: TIndexSpace): AnsiString;
const
  Names: array[TIndexSpace] of AnsiString = ('type', 'func', 'table', 'memory', 'global', 'elem', 'data', 'tag');
begin
  Result := Names[Space];
end;

constructor TModuleContext.Create;
var
  Space: TIndexSpace;
begin
  inherited Create;
  for Space := Low(TIndexSpace) to High(TIndexSpace) do
  begin
    FIdentifiers[Space] := TStringList.Create;
    FIdentifiers[Space].CaseSensitive := True;
    FIdentifiers[Space].Sorted := True;
  end;
end;

destructor TModuleContext.Destroy;
var
  Space: TIndexSpace;
begin
  for Space := Low(TIndexSpace) to High(TIndexSpace) do
    FIdentifiers[Space].Free;
  inherited Destroy;
end;

procedure TModuleContext.Fail(Node: TTextNode; const Message: AnsiString);
begin
  if Node <> nil then
    raise EWasmTextError.CreateFmt('line %d: %s', [Node.Line, Message])
  else
    raise EWasmTextError.Create(Message);
end;

function TModuleContext.GetDefinition(Index: Integer): TTypeDefinition;
begin
  Result := FDefinitions[Index];
end;

function TModuleContext.GetGroup(Index: Integer): TTypeGroup;
begin
  Result := FGroups[Index];
end;

function TModuleContext.DefineIndex(Space: TIndexSpace; const Identifier: AnsiString; Node: TTextNode): Cardinal;
var
  Existing: Integer;
begin
  Result := Counts[Space];
  if Identifier <> '' then
  begin
    if FIdentifiers[Space].Find(Identifier, Existing) then
      Fail(Node, 'duplicate ' + SpaceName(Space) + ' ' + Identifier);
    FIdentifiers[Space].AddObject(Identifier, TObject(PtrUInt(Result)));
  end;
  Inc(Counts[Space]);
end;

function TModuleContext.IsIndex(Node: TTextNode): Boolean;
begin
  Result := (Node <> nil) and (Node.IsAtomOf(ttIdentifier) or Node.IsAtomOf(ttNumber));
end;

function TModuleContext.ResolveIndex(Space: TIndexSpace; Node: TTextNode): Cardinal;
var
  Found: Integer;
begin
  if Node.IsAtomOf(ttNumber) then
    Exit(Cardinal(ParseUnsigned(Node.Text, 32)));
  if not Node.IsAtomOf(ttIdentifier) then
    Fail(Node, 'unexpected token: expected a ' + SpaceName(Space) + ' index');
  if not FIdentifiers[Space].Find(Node.Text, Found) then
    Fail(Node, 'unknown ' + SpaceName(Space) + ' ' + Node.Text);
  Result := Cardinal(PtrUInt(FIdentifiers[Space].Objects[Found]));
end;

function TModuleContext.AddTypeGroup(Count: Cardinal; IsRecursive: Boolean): Cardinal;
var
  Index: Cardinal;
begin
  if FGroupCount = Length(FGroups) then
    SetLength(FGroups, FGroupCount * 2 + 8);
  Result := FDefinitionCount;
  FGroups[FGroupCount].First := Result;
  FGroups[FGroupCount].Count := Count;
  FGroups[FGroupCount].IsRecursive := IsRecursive;
  Inc(FGroupCount);
  if FDefinitionCount + Integer(Count) > Length(FDefinitions) then
    SetLength(FDefinitions, (FDefinitionCount + Integer(Count)) * 2 + 8);
  Index := 0;
  while Index < Count do
  begin
    FDefinitions[FDefinitionCount] := Default(TTypeDefinition);
    FDefinitions[FDefinitionCount].IsFinal := True;
    FDefinitions[FDefinitionCount].GroupSize := Count;
    Inc(FDefinitionCount);
    Inc(Index);
  end;
end;

procedure TModuleContext.SetTypeDefinition(Index: Cardinal; const Definition: TTypeDefinition);
var
  GroupSize: Cardinal;
begin
  GroupSize := FDefinitions[Index].GroupSize;
  FDefinitions[Index] := Definition;
  FDefinitions[Index].GroupSize := GroupSize;
end;

function TModuleContext.AddType(const FunctionType: TFunctionType): Cardinal;
begin
  Result := AddTypeGroup(1, False);
  FDefinitions[Result].Kind := ckFunction;
  FDefinitions[Result].FunctionType := FunctionType;
  Inc(Counts[isType]);
end;

function TModuleContext.ResolveField(TypeIndex: Cardinal; Node: TTextNode): Cardinal;
var
  Index: Integer;
begin
  if Node.IsAtomOf(ttNumber) then
    Exit(Cardinal(ParseUnsigned(Node.Text, 32)));
  if not Node.IsAtomOf(ttIdentifier) then
    Fail(Node, 'unexpected token: expected a field index');
  if TypeIndex < Cardinal(FDefinitionCount) then
    for Index := 0 to High(FDefinitions[TypeIndex].FieldNames) do
      if FDefinitions[TypeIndex].FieldNames[Index] = Node.Text then
        Exit(Index);
  Fail(Node, 'unknown field ' + Node.Text);
  Result := 0;
end;

function TModuleContext.ParseHeapType(Node: TTextNode): TValueType;
var
  Code: Byte;
begin
  if Node.IsAtomOf(ttKeyword) and AbstractHeapTypeCode(Node.Text, Code) then
    Exit(SingleByte(Code));
  if not IsIndex(Node) then
    Fail(Node, 'unexpected token: expected a heap type');
  Result := HeapTypeOfIndex(ResolveIndex(isType, Node));
end;

function TModuleContext.IsReferenceType(Node: TTextNode): Boolean;
var
  Code: Byte;
begin
  Result := (Node.IsAtomOf(ttKeyword) and ReferenceAbbreviationCode(Node.Text, Code)) or Node.IsListOf('ref');
end;

function TModuleContext.ParseReferenceType(Node: TTextNode): TValueType;
var
  Code: Byte;
  Position: Integer;
  Nullable: Boolean;
begin
  if Node.IsAtomOf(ttKeyword) and ReferenceAbbreviationCode(Node.Text, Code) then
    Exit(SingleByte(Code));
  if not Node.IsListOf('ref') then
    Fail(Node, 'unexpected token: expected a reference type');
  Position := 1;
  Nullable := (Position < Node.Count) and Node[Position].IsKeyword('null');
  if Nullable then
    Inc(Position);
  if Position <> Node.Count - 1 then
    Fail(Node, 'unexpected token in reference type');
  Result := MakeReferenceType(Nullable, ParseHeapType(Node[Position]));
end;

function TModuleContext.IsValueType(Node: TTextNode): Boolean;
var
  Code: Byte;
begin
  Result := (Node.IsAtomOf(ttKeyword) and NumberTypeCode(Node.Text, Code)) or IsReferenceType(Node);
end;

function TModuleContext.ParseValueType(Node: TTextNode): TValueType;
var
  Code: Byte;
begin
  if Node.IsAtomOf(ttKeyword) and NumberTypeCode(Node.Text, Code) then
    Exit(SingleByte(Code));
  if not IsReferenceType(Node) then
    Fail(Node, 'unexpected token: expected a value type');
  Result := ParseReferenceType(Node);
end;

function TModuleContext.ParseStorageType(Node: TTextNode): TValueType;
var
  Code: Byte;
begin
  if Node.IsAtomOf(ttKeyword) and PackedTypeCode(Node.Text, Code) then
    Exit(SingleByte(Code));
  Result := ParseValueType(Node);
end;

procedure TModuleContext.ParseSignature(Parent: TTextNode; var Position: Integer; AllowNames: Boolean;
  var FunctionType: TFunctionType; var Names: TNameArray);
var
  Node: TTextNode;
  Index: Integer;
begin
  while (Position < Parent.Count) and Parent[Position].IsListOf('param') do
  begin
    Node := Parent[Position];
    if (Node.Count >= 2) and Node[1].IsAtomOf(ttIdentifier) then
    begin
      if not AllowNames then
        Fail(Node[1], 'unexpected token: named parameter');
      if Node.Count <> 3 then
        Fail(Node, 'unexpected token: one type per named parameter');
      AppendValueType(FunctionType.Parameters, ParseValueType(Node[2]));
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := Node[1].Text;
    end
    else
      for Index := 1 to Node.Count - 1 do
      begin
        AppendValueType(FunctionType.Parameters, ParseValueType(Node[Index]));
        SetLength(Names, Length(Names) + 1);
        Names[High(Names)] := '';
      end;
    Inc(Position);
  end;
  while (Position < Parent.Count) and Parent[Position].IsListOf('result') do
  begin
    Node := Parent[Position];
    for Index := 1 to Node.Count - 1 do
      AppendValueType(FunctionType.Results, ParseValueType(Node[Index]));
    Inc(Position);
  end;
end;

function TModuleContext.ParseTypeUse(Parent: TTextNode; var Position: Integer; Purpose: TTypeUsePurpose): TTypeUse;
var
  Node: TTextNode;
  InlineType: TFunctionType;
  Names: TNameArray;
  Start: Integer;
  HasDefinition: Boolean;
begin
  Result.HasTypeIndex := False;
  Result.TypeIndex := 0;
  Result.Parameters := nil;
  Result.Results := nil;
  Result.ParameterNames := nil;
  if (Position < Parent.Count) and Parent[Position].IsListOf('type') then
  begin
    Node := Parent[Position];
    if Node.Count <> 2 then
      Fail(Node, 'unexpected token in type use');
    Result.HasTypeIndex := True;
    Result.TypeIndex := ResolveIndex(isType, Node[1]);
    Inc(Position);
  end;
  InlineType.Parameters := nil;
  InlineType.Results := nil;
  Names := nil;
  Start := Position;
  ParseSignature(Parent, Position, Purpose = tuFunction, InlineType, Names);
  Result.Parameters := InlineType.Parameters;
  Result.Results := InlineType.Results;
  Result.ParameterNames := Names;
  if Result.HasTypeIndex then
  begin
    HasDefinition := (Result.TypeIndex < Cardinal(FDefinitionCount)) and
      (FDefinitions[Result.TypeIndex].Kind = ckFunction);
    if (Position > Start) and (Result.TypeIndex >= ExplicitTypeCount) then
      Fail(Parent, 'unknown type ' + IntToStr(Result.TypeIndex));
    if (Position > Start) and not (HasDefinition and
       SameFunctionType(InlineType, FDefinitions[Result.TypeIndex].FunctionType)) then
      Fail(Parent, 'inline function type does not match its type');
    if (Position = Start) and HasDefinition then
    begin
      Result.Parameters := FDefinitions[Result.TypeIndex].FunctionType.Parameters;
      Result.Results := FDefinitions[Result.TypeIndex].FunctionType.Results;
      SetLength(Result.ParameterNames, Length(Result.Parameters));
    end;
  end;
end;

function TModuleContext.FunctionTypeOf(const TypeUse: TTypeUse): TFunctionType;
begin
  Result.Parameters := TypeUse.Parameters;
  Result.Results := TypeUse.Results;
end;

function TModuleContext.TypeIndexOf(const TypeUse: TTypeUse): Cardinal;
var
  Index: Integer;
  FunctionType: TFunctionType;
begin
  if TypeUse.HasTypeIndex then
    Exit(TypeUse.TypeIndex);
  FunctionType := FunctionTypeOf(TypeUse);
  for Index := 0 to FDefinitionCount - 1 do
    if IsStandaloneFunctionType(FDefinitions[Index]) and
       SameFunctionType(FDefinitions[Index].FunctionType, FunctionType) then
      Exit(Index);
  Result := AddType(FunctionType);
end;

end.
