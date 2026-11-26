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
  (core specification 2.0, section 6.6.1, the identifier context), the
  function types, value types, and type uses with the implicit types
  they add (section 6.6.3: a type use without a matching type gets a new
  one appended after all the others, in the order they are met).

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
  WasmText.Tree;

const
  ValueTypeI32 = $7F;
  ValueTypeI64 = $7E;
  ValueTypeF32 = $7D;
  ValueTypeF64 = $7C;
  ValueTypeV128 = $7B;
  ValueTypeFuncRef = $70;
  ValueTypeExternRef = $6F;

type
  TNameArray = array of AnsiString;

  TIndexSpace = (isType, isFunction, isTable, isMemory, isGlobal, isElement, isData);

  TFunctionType = record
    Parameters: TBytes;
    Results: TBytes;
  end;

  TTypeUse = record
    HasTypeIndex: Boolean;
    TypeIndex: Cardinal;
    Parameters: TBytes;
    Results: TBytes;
    { The identifiers of the inline parameters ('' when unnamed). }
    ParameterNames: TNameArray;
  end;

  TTypeUsePurpose = (tuFunction, tuInstruction);

  TModuleContext = class
  private
    FIdentifiers: array[TIndexSpace] of TStringList;
    FTypes: array of TFunctionType;
    FTypeCount: Integer;
    function GetType(Index: Integer): TFunctionType;
  public
    Counts: array[TIndexSpace] of Cardinal;
    { Set when code uses memory.init or data.drop: the data count
      section then has to be there. }
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
    function AddType(const FunctionType: TFunctionType): Cardinal;
    function ParseValueType(Node: TTextNode): Byte;
    function IsValueType(Node: TTextNode): Boolean;
    function ParseReferenceType(Node: TTextNode): Byte;
    function ParseHeapType(Node: TTextNode): Byte;
    { Reads (param ...)* (result ...)* from Parent's children at
      Position on; with Names, parameters may carry identifiers. }
    procedure ParseSignature(Parent: TTextNode; var Position: Integer; AllowNames: Boolean;
      var FunctionType: TFunctionType; var Names: TNameArray);
    { (type x)? (param ...)* (result ...)*, checked against type x when
      both are written. }
    function ParseTypeUse(Parent: TTextNode; var Position: Integer; Purpose: TTypeUsePurpose): TTypeUse;
    { The type index of a type use: its own, or the first equal type,
      or a new type appended. }
    function TypeIndexOf(const TypeUse: TTypeUse): Cardinal;
    function FunctionTypeOf(const TypeUse: TTypeUse): TFunctionType;
    property Types[Index: Integer]: TFunctionType read GetType;
    property TypeCount: Integer read FTypeCount;
  end;

function SpaceName(Space: TIndexSpace): AnsiString;
function SameFunctionType(const Left, Right: TFunctionType): Boolean;

implementation

uses
  WasmText.Numbers;

function SpaceName(Space: TIndexSpace): AnsiString;
const
  Names: array[TIndexSpace] of AnsiString = ('type', 'func', 'table', 'memory', 'global', 'elem', 'data');
begin
  Result := Names[Space];
end;

function SameBytes(const Left, Right: TBytes): Boolean;
var
  Index: Integer;
begin
  Result := Length(Left) = Length(Right);
  if Result then
    for Index := 0 to High(Left) do
      if Left[Index] <> Right[Index] then
        Exit(False);
end;

function SameFunctionType(const Left, Right: TFunctionType): Boolean;
begin
  Result := SameBytes(Left.Parameters, Right.Parameters) and SameBytes(Left.Results, Right.Results);
end;

procedure AppendByte(var Bytes: TBytes; Value: Byte);
begin
  SetLength(Bytes, Length(Bytes) + 1);
  Bytes[High(Bytes)] := Value;
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

function TModuleContext.GetType(Index: Integer): TFunctionType;
begin
  Result := FTypes[Index];
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

function TModuleContext.AddType(const FunctionType: TFunctionType): Cardinal;
begin
  if FTypeCount = Length(FTypes) then
    SetLength(FTypes, FTypeCount * 2 + 8);
  FTypes[FTypeCount] := FunctionType;
  Result := FTypeCount;
  Inc(FTypeCount);
end;

function TModuleContext.IsValueType(Node: TTextNode): Boolean;
begin
  Result := (Node.Kind = tnAtom) and (Node.TokenKind = ttKeyword) and
    ((Node.Text = 'i32') or (Node.Text = 'i64') or (Node.Text = 'f32') or (Node.Text = 'f64') or
     (Node.Text = 'v128') or (Node.Text = 'funcref') or (Node.Text = 'externref'));
end;

function TModuleContext.ParseValueType(Node: TTextNode): Byte;
begin
  Result := 0;
  if Node.IsKeyword('i32') then Result := ValueTypeI32
  else if Node.IsKeyword('i64') then Result := ValueTypeI64
  else if Node.IsKeyword('f32') then Result := ValueTypeF32
  else if Node.IsKeyword('f64') then Result := ValueTypeF64
  else if Node.IsKeyword('v128') then Result := ValueTypeV128
  else if Node.IsKeyword('funcref') then Result := ValueTypeFuncRef
  else if Node.IsKeyword('externref') then Result := ValueTypeExternRef
  else
    Fail(Node, 'unexpected token: expected a value type');
end;

function TModuleContext.ParseReferenceType(Node: TTextNode): Byte;
begin
  Result := 0;
  if Node.IsKeyword('funcref') then Result := ValueTypeFuncRef
  else if Node.IsKeyword('externref') then Result := ValueTypeExternRef
  else
    Fail(Node, 'unexpected token: expected a reference type');
end;

function TModuleContext.ParseHeapType(Node: TTextNode): Byte;
begin
  Result := 0;
  if Node.IsKeyword('func') then Result := ValueTypeFuncRef
  else if Node.IsKeyword('extern') then Result := ValueTypeExternRef
  else
    Fail(Node, 'unexpected token: expected a heap type');
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
      AppendByte(FunctionType.Parameters, ParseValueType(Node[2]));
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := Node[1].Text;
    end
    else
      for Index := 1 to Node.Count - 1 do
      begin
        AppendByte(FunctionType.Parameters, ParseValueType(Node[Index]));
        SetLength(Names, Length(Names) + 1);
        Names[High(Names)] := '';
      end;
    Inc(Position);
  end;
  while (Position < Parent.Count) and Parent[Position].IsListOf('result') do
  begin
    Node := Parent[Position];
    for Index := 1 to Node.Count - 1 do
      AppendByte(FunctionType.Results, ParseValueType(Node[Index]));
    Inc(Position);
  end;
end;

function TModuleContext.ParseTypeUse(Parent: TTextNode; var Position: Integer; Purpose: TTypeUsePurpose): TTypeUse;
var
  Node: TTextNode;
  InlineType: TFunctionType;
  Names: TNameArray;
  Start: Integer;
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
    if (Position > Start) and (Result.TypeIndex >= ExplicitTypeCount) then
      Fail(Parent, 'unknown type ' + IntToStr(Result.TypeIndex));
    if (Position > Start) and not SameFunctionType(InlineType, FTypes[Result.TypeIndex]) then
      Fail(Parent, 'inline function type does not match its type');
    if (Position = Start) and (Result.TypeIndex < Cardinal(FTypeCount)) then
    begin
      Result.Parameters := FTypes[Result.TypeIndex].Parameters;
      Result.Results := FTypes[Result.TypeIndex].Results;
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
  for Index := 0 to FTypeCount - 1 do
    if SameFunctionType(FTypes[Index], FunctionType) then
      Exit(Index);
  Result := AddType(FunctionType);
end;

end.
