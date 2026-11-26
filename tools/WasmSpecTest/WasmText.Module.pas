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
  A text format module into the binary format (core specification 2.0,
  sections 6.6 and 5.5).

  Two passes over the module fields. The first gives every function,
  table, memory, global, element and data segment its index (fields in
  the order written, imports first, as the format requires: an import
  after a definition is malformed), records identifiers and collects
  the explicit types. The second encodes each field into its section,
  in the same order, so indices and section entries agree; type uses
  met on the way append their implicit types after the explicit ones.

  The inline abbreviations are expanded here: exports and imports
  written inside func, table, memory and global fields, element lists
  inside a table (its size is the list's length) and data strings inside
  a memory (its size is the data's length in pages).

  The data count section is written whenever there are data segments or
  code uses a data index, which is always allowed and what memory.init
  and data.drop need.
}
unit WasmText.Module;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree,
  WasmText.Binary,
  WasmText.Context;

{ Fields are Container's children from FirstField on. }
function EncodeModuleFields(Container: TTextNode; FirstField: Integer): TBytes;

implementation

uses
  WasmText.Numbers,
  WasmText.Expressions;

type
  TSection = record
    Writer: TBinaryWriter;
    Count: Cardinal;
  end;

  TSectionKind = (skImport, skFunction, skTable, skMemory, skGlobal, skExport, skElement, skCode, skData);

  TModuleEncoder = class(TModuleContext)
  private
    FSections: array[TSectionKind] of TSection;
    FNextIndex: array[TIndexSpace] of Cardinal;
    FDefinitionSeen: Boolean;
    FHasStart: Boolean;
    FStart: Cardinal;
    function ReadIdentifier(Field: TTextNode; var Position: Integer): AnsiString;
    function ReadString(Field: TTextNode; var Position: Integer): AnsiString;
    function ReadName(Field: TTextNode; var Position: Integer): AnsiString;
    function SkipInlineExports(Field: TTextNode; Position: Integer): Integer;
    function SpaceOfDescription(Node: TTextNode): TIndexSpace;
    procedure NoteImport(Node: TTextNode);
    procedure CollectField(Field: TTextNode);
    procedure Add(Kind: TSectionKind);
    procedure WriteLimits(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    procedure WriteGlobalType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    procedure WriteExpression(Writer: TBinaryWriter; Parent: TTextNode; Position: Integer);
    procedure WriteOffset(Writer: TBinaryWriter; Node: TTextNode);
    procedure WriteInlineExports(Field: TTextNode; var Position: Integer; Kind: Byte; Index: Cardinal);
    procedure WriteImportHeader(Import: TTextNode);
    procedure ExpectEnd(Field: TTextNode; Position: Integer);
    procedure EncodeImport(Field: TTextNode);
    procedure EncodeFunction(Field: TTextNode);
    procedure EncodeFunctionBody(Field: TTextNode; Position: Integer; const TypeUse: TTypeUse);
    procedure EncodeTable(Field: TTextNode);
    procedure EncodeMemory(Field: TTextNode);
    procedure EncodeGlobal(Field: TTextNode);
    procedure EncodeExport(Field: TTextNode);
    procedure EncodeStart(Field: TTextNode);
    procedure WriteElementList(Writer: TBinaryWriter; Field: TTextNode; Position: Integer; Mode: Integer;
      TableIndex: Cardinal; Offset: TTextNode; DefaultReferenceType: Byte = ValueTypeFuncRef);
    procedure EncodeElement(Field: TTextNode);
    procedure EncodeData(Field: TTextNode);
    procedure EncodeField(Field: TTextNode);
    function Assemble: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function Encode(Container: TTextNode; FirstField: Integer): TBytes;
  end;

const
  ExternalFunction = 0;
  ExternalTable = 1;
  ExternalMemory = 2;
  ExternalGlobal = 3;

  { Element segment modes for WriteElementList. }
  ElementActive = 0;
  ElementPassive = 1;
  ElementDeclarative = 2;

function IsValidUtf8(const Text: AnsiString): Boolean;
var
  Index, Extra, Count: Integer;
  CodePoint: Cardinal;
  Lead: Byte;
begin
  Result := False;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Lead := Ord(Text[Index]);
    if Lead < $80 then
    begin
      Inc(Index);
      Continue;
    end
    else if (Lead and $E0) = $C0 then
    begin
      Extra := 1;
      CodePoint := Lead and $1F;
    end
    else if (Lead and $F0) = $E0 then
    begin
      Extra := 2;
      CodePoint := Lead and $0F;
    end
    else if (Lead and $F8) = $F0 then
    begin
      Extra := 3;
      CodePoint := Lead and $07;
    end
    else
      Exit;
    if Index + Extra > Length(Text) then
      Exit;
    for Count := 1 to Extra do
    begin
      if (Ord(Text[Index + Count]) and $C0) <> $80 then
        Exit;
      CodePoint := (CodePoint shl 6) or (Ord(Text[Index + Count]) and $3F);
    end;
    if ((Extra = 1) and (CodePoint < $80)) or ((Extra = 2) and (CodePoint < $800)) or
       ((Extra = 3) and (CodePoint < $10000)) or (CodePoint > $10FFFF) or
       ((CodePoint >= $D800) and (CodePoint < $E000)) then
      Exit;
    Inc(Index, Extra + 1);
  end;
  Result := True;
end;

constructor TModuleEncoder.Create;
var
  Kind: TSectionKind;
begin
  inherited Create;
  for Kind := Low(TSectionKind) to High(TSectionKind) do
    FSections[Kind].Writer := TBinaryWriter.Create;
end;

destructor TModuleEncoder.Destroy;
var
  Kind: TSectionKind;
begin
  for Kind := Low(TSectionKind) to High(TSectionKind) do
    FSections[Kind].Writer.Free;
  inherited Destroy;
end;

procedure TModuleEncoder.Add(Kind: TSectionKind);
begin
  Inc(FSections[Kind].Count);
end;

function TModuleEncoder.ReadIdentifier(Field: TTextNode; var Position: Integer): AnsiString;
begin
  Result := '';
  if (Position < Field.Count) and Field[Position].IsAtomOf(ttIdentifier) then
  begin
    Result := Field[Position].Text;
    Inc(Position);
  end;
end;

function TModuleEncoder.ReadString(Field: TTextNode; var Position: Integer): AnsiString;
begin
  if (Position >= Field.Count) or not Field[Position].IsAtomOf(ttString) then
    Fail(Field, 'unexpected token: expected a string');
  Result := Field[Position].Text;
  Inc(Position);
end;

function TModuleEncoder.ReadName(Field: TTextNode; var Position: Integer): AnsiString;
begin
  Result := ReadString(Field, Position);
  if not IsValidUtf8(Result) then
    Fail(Field, 'malformed UTF-8 encoding');
end;

function TModuleEncoder.SkipInlineExports(Field: TTextNode; Position: Integer): Integer;
begin
  while (Position < Field.Count) and Field[Position].IsListOf('export') do
    Inc(Position);
  Result := Position;
end;

function TModuleEncoder.SpaceOfDescription(Node: TTextNode): TIndexSpace;
begin
  Result := isFunction;
  if Node.IsListOf('func') then Result := isFunction
  else if Node.IsListOf('table') then Result := isTable
  else if Node.IsListOf('memory') then Result := isMemory
  else if Node.IsListOf('global') then Result := isGlobal
  else
    Fail(Node, 'unexpected token: expected an import or export description');
end;

procedure TModuleEncoder.NoteImport(Node: TTextNode);
begin
  if FDefinitionSeen then
    Fail(Node, 'import after definition');
end;

procedure TModuleEncoder.CollectField(Field: TTextNode);
var
  Head, Identifier: AnsiString;
  Position: Integer;
  Description, Signature: TTextNode;
  FunctionType: TFunctionType;
  Names: TNameArray;
  Space: TIndexSpace;
begin
  Head := Field.Head;
  Position := 1;
  if Head = 'type' then
  begin
    Identifier := ReadIdentifier(Field, Position);
    if (Position <> Field.Count - 1) or not Field[Position].IsListOf('func') then
      Fail(Field, 'unexpected token in type definition');
    Signature := Field[Position];
    FunctionType.Parameters := nil;
    FunctionType.Results := nil;
    Names := nil;
    Position := 1;
    ParseSignature(Signature, Position, True, FunctionType, Names);
    if Position <> Signature.Count then
      Fail(Signature, 'unexpected token in function type');
    DefineIndex(isType, Identifier, Field);
    AddType(FunctionType);
  end
  else if Head = 'import' then
  begin
    if Field.Count <> 4 then
      Fail(Field, 'unexpected token in import');
    Description := Field[3];
    Space := SpaceOfDescription(Description);
    NoteImport(Field);
    Position := 1;
    DefineIndex(Space, ReadIdentifier(Description, Position), Description);
  end
  else if (Head = 'func') or (Head = 'table') or (Head = 'memory') or (Head = 'global') then
  begin
    Space := SpaceOfDescription(Field);
    Identifier := ReadIdentifier(Field, Position);
    Position := SkipInlineExports(Field, Position);
    if (Position < Field.Count) and Field[Position].IsListOf('import') then
      NoteImport(Field)
    else
    begin
      FDefinitionSeen := True;
      if (Head = 'table') and (Position + 1 < Field.Count) and Field[Position + 1].IsListOf('elem') then
        DefineIndex(isElement, '', Field);
      if (Head = 'memory') and (Position < Field.Count) and Field[Position].IsListOf('data') then
        DefineIndex(isData, '', Field);
    end;
    DefineIndex(Space, Identifier, Field);
  end
  else if Head = 'elem' then
    DefineIndex(isElement, ReadIdentifier(Field, Position), Field)
  else if Head = 'data' then
    DefineIndex(isData, ReadIdentifier(Field, Position), Field)
  else if (Head = 'export') or (Head = 'start') then
  else
    Fail(Field, 'unexpected token: unknown module field ' + Head);
end;

procedure TModuleEncoder.ExpectEnd(Field: TTextNode; Position: Integer);
begin
  if Position < Field.Count then
    Fail(Field[Position], 'unexpected token ' + Field[Position].Text);
end;

procedure TModuleEncoder.WriteLimits(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
var
  Minimum, Maximum: QWord;
begin
  if (Position >= Field.Count) or not Field[Position].IsAtomOf(ttNumber) then
    Fail(Field, 'unexpected token: expected limits');
  Minimum := ParseUnsigned(Field[Position].Text, 32);
  Inc(Position);
  if (Position < Field.Count) and Field[Position].IsAtomOf(ttNumber) then
  begin
    Maximum := ParseUnsigned(Field[Position].Text, 32);
    Inc(Position);
    Writer.WriteByte(1);
    Writer.WriteUnsigned(Minimum);
    Writer.WriteUnsigned(Maximum);
  end
  else
  begin
    Writer.WriteByte(0);
    Writer.WriteUnsigned(Minimum);
  end;
end;

procedure TModuleEncoder.WriteGlobalType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
var
  Node: TTextNode;
begin
  if Position >= Field.Count then
    Fail(Field, 'unexpected end: expected a global type');
  Node := Field[Position];
  if Node.IsListOf('mut') then
  begin
    if Node.Count <> 2 then
      Fail(Node, 'unexpected token in global type');
    Writer.WriteByte(ParseValueType(Node[1]));
    Writer.WriteByte(1);
  end
  else
  begin
    Writer.WriteByte(ParseValueType(Node));
    Writer.WriteByte(0);
  end;
  Inc(Position);
end;

procedure TModuleEncoder.WriteExpression(Writer: TBinaryWriter; Parent: TTextNode; Position: Integer);
var
  Encoder: TExpressionEncoder;
begin
  Encoder := TExpressionEncoder.Create(Self, Writer, nil);
  try
    Encoder.EncodeSequence(Parent, Position);
  finally
    Encoder.Free;
  end;
  Writer.WriteByte($0B);
end;

procedure TModuleEncoder.WriteOffset(Writer: TBinaryWriter; Node: TTextNode);
var
  Encoder: TExpressionEncoder;
begin
  if Node.IsListOf('offset') then
    WriteExpression(Writer, Node, 1)
  else
  begin
    Encoder := TExpressionEncoder.Create(Self, Writer, nil);
    try
      Encoder.EncodeFoldedInstruction(Node);
    finally
      Encoder.Free;
    end;
    Writer.WriteByte($0B);
  end;
end;

procedure TModuleEncoder.WriteInlineExports(Field: TTextNode; var Position: Integer; Kind: Byte; Index: Cardinal);
var
  ExportNode: TTextNode;
  NamePosition: Integer;
  Writer: TBinaryWriter;
begin
  Writer := FSections[skExport].Writer;
  while (Position < Field.Count) and Field[Position].IsListOf('export') do
  begin
    ExportNode := Field[Position];
    NamePosition := 1;
    Writer.WriteName(ReadName(ExportNode, NamePosition));
    ExpectEnd(ExportNode, NamePosition);
    Writer.WriteByte(Kind);
    Writer.WriteUnsigned(Index);
    Add(skExport);
    Inc(Position);
  end;
end;

procedure TModuleEncoder.WriteImportHeader(Import: TTextNode);
var
  Position: Integer;
  Writer: TBinaryWriter;
begin
  Writer := FSections[skImport].Writer;
  Position := 1;
  Writer.WriteName(ReadName(Import, Position));
  Writer.WriteName(ReadName(Import, Position));
  Add(skImport);
end;

procedure TModuleEncoder.EncodeImport(Field: TTextNode);
var
  Description: TTextNode;
  Position: Integer;
  Writer: TBinaryWriter;
  TypeUse: TTypeUse;
  Space: TIndexSpace;
begin
  Writer := FSections[skImport].Writer;
  WriteImportHeader(Field);
  Description := Field[3];
  Space := SpaceOfDescription(Description);
  Inc(FNextIndex[Space]);
  Position := 1;
  ReadIdentifier(Description, Position);
  case Space of
    isFunction:
      begin
        TypeUse := ParseTypeUse(Description, Position, tuFunction);
        Writer.WriteByte(ExternalFunction);
        Writer.WriteUnsigned(TypeIndexOf(TypeUse));
      end;
    isTable:
      begin
        Writer.WriteByte(ExternalTable);
        if (Position + 1 < Description.Count) then
          Writer.WriteByte(ParseReferenceType(Description[Description.Count - 1]))
        else
          Fail(Description, 'unexpected token in table type');
        WriteLimits(Writer, Description, Position);
        Inc(Position);
      end;
    isMemory:
      begin
        Writer.WriteByte(ExternalMemory);
        WriteLimits(Writer, Description, Position);
      end;
    isGlobal:
      begin
        Writer.WriteByte(ExternalGlobal);
        WriteGlobalType(Writer, Description, Position);
      end;
  end;
  ExpectEnd(Description, Position);
end;

procedure TModuleEncoder.EncodeFunctionBody(Field: TTextNode; Position: Integer; const TypeUse: TTypeUse);
var
  Locals: TStringList;
  Body: TBinaryWriter;
  LocalTypes: TBytes;
  Index, LocalIndex, RunStart, RunCount: Integer;
  Node: TTextNode;
  Encoder: TExpressionEncoder;
  Found: Integer;

  procedure NameLocal(const Name: AnsiString; Index: Integer; Where: TTextNode);
  begin
    if Name = '' then
      Exit;
    if Locals.Find(Name, Found) then
      Fail(Where, 'duplicate local ' + Name);
    Locals.AddObject(Name, TObject(PtrUInt(Index)));
  end;

begin
  Locals := TStringList.Create;
  Body := TBinaryWriter.Create;
  try
    Locals.CaseSensitive := True;
    Locals.Sorted := True;
    for Index := 0 to High(TypeUse.ParameterNames) do
      NameLocal(TypeUse.ParameterNames[Index], Index, Field);
    LocalIndex := Length(TypeUse.Parameters);
    LocalTypes := nil;
    while (Position < Field.Count) and Field[Position].IsListOf('local') do
    begin
      Node := Field[Position];
      if (Node.Count >= 2) and Node[1].IsAtomOf(ttIdentifier) then
      begin
        if Node.Count <> 3 then
          Fail(Node, 'unexpected token: one type per named local');
        NameLocal(Node[1].Text, LocalIndex, Node);
        SetLength(LocalTypes, Length(LocalTypes) + 1);
        LocalTypes[High(LocalTypes)] := ParseValueType(Node[2]);
        Inc(LocalIndex);
      end
      else
        for Index := 1 to Node.Count - 1 do
        begin
          SetLength(LocalTypes, Length(LocalTypes) + 1);
          LocalTypes[High(LocalTypes)] := ParseValueType(Node[Index]);
          Inc(LocalIndex);
        end;
      Inc(Position);
    end;
    { Runs of equal local types, each as a count and a type. }
    RunCount := 0;
    Index := 0;
    while Index < Length(LocalTypes) do
    begin
      RunStart := Index;
      while (Index < Length(LocalTypes)) and (LocalTypes[Index] = LocalTypes[RunStart]) do
        Inc(Index);
      Inc(RunCount);
    end;
    Body.WriteUnsigned(RunCount);
    Index := 0;
    while Index < Length(LocalTypes) do
    begin
      RunStart := Index;
      while (Index < Length(LocalTypes)) and (LocalTypes[Index] = LocalTypes[RunStart]) do
        Inc(Index);
      Body.WriteUnsigned(Index - RunStart);
      Body.WriteByte(LocalTypes[RunStart]);
    end;
    Encoder := TExpressionEncoder.Create(Self, Body, Locals);
    try
      Encoder.EncodeSequence(Field, Position);
    finally
      Encoder.Free;
    end;
    Body.WriteByte($0B);
    FSections[skCode].Writer.WriteSized(Body);
    Add(skCode);
  finally
    Body.Free;
    Locals.Free;
  end;
end;

procedure TModuleEncoder.EncodeFunction(Field: TTextNode);
var
  Position: Integer;
  Index: Cardinal;
  TypeUse: TTypeUse;
  Import: TTextNode;
begin
  Index := FNextIndex[isFunction];
  Inc(FNextIndex[isFunction]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalFunction, Index);
  if (Position < Field.Count) and Field[Position].IsListOf('import') then
  begin
    Import := Field[Position];
    if Import.Count <> 3 then
      Fail(Import, 'unexpected token in inline import');
    WriteImportHeader(Import);
    Inc(Position);
    TypeUse := ParseTypeUse(Field, Position, tuFunction);
    ExpectEnd(Field, Position);
    FSections[skImport].Writer.WriteByte(ExternalFunction);
    FSections[skImport].Writer.WriteUnsigned(TypeIndexOf(TypeUse));
    Exit;
  end;
  TypeUse := ParseTypeUse(Field, Position, tuFunction);
  FSections[skFunction].Writer.WriteUnsigned(TypeIndexOf(TypeUse));
  Add(skFunction);
  EncodeFunctionBody(Field, Position, TypeUse);
end;

procedure TModuleEncoder.WriteElementList(Writer: TBinaryWriter; Field: TTextNode; Position: Integer; Mode: Integer;
  TableIndex: Cardinal; Offset: TTextNode; DefaultReferenceType: Byte);
var
  ReferenceType: Byte;
  UsesExpressions: Boolean;
  Flags: Byte;
  Index, Count: Integer;
  Node: TTextNode;
  Items: TBinaryWriter;
begin
  ReferenceType := ValueTypeFuncRef;
  UsesExpressions := False;
  if (Position < Field.Count) and Field[Position].IsKeyword('func') then
    Inc(Position)
  else if (Position < Field.Count) and (Field[Position].IsKeyword('funcref') or
          Field[Position].IsKeyword('externref')) then
  begin
    ReferenceType := ParseReferenceType(Field[Position]);
    UsesExpressions := True;
    Inc(Position);
  end
  else if (Position < Field.Count) and (Field[Position].Kind = tnList) then
  begin
    ReferenceType := DefaultReferenceType;
    UsesExpressions := True;
  end
  else if Mode <> ElementActive then
    Fail(Field, 'unexpected token: expected an element list');
  Items := TBinaryWriter.Create;
  try
    Count := 0;
    for Index := Position to Field.Count - 1 do
    begin
      Node := Field[Index];
      if UsesExpressions then
      begin
        if Node.Kind <> tnList then
          Fail(Node, 'unexpected token: expected an element expression');
        if Node.IsListOf('item') then
          WriteExpression(Items, Node, 1)
        else
          WriteOffset(Items, Node);
      end
      else
        Items.WriteUnsigned(ResolveIndex(isFunction, Node));
      Inc(Count);
    end;
    if UsesExpressions then
      Flags := 4
    else
      Flags := 0;
    case Mode of
      ElementActive:
        if (TableIndex <> 0) or (UsesExpressions and (ReferenceType <> ValueTypeFuncRef)) then
          Flags := Flags or 2;
      ElementPassive:
        Flags := Flags or 1;
      ElementDeclarative:
        Flags := Flags or 3;
    end;
    Writer.WriteUnsigned(Flags);
    if Mode = ElementActive then
    begin
      if (Flags and 2) <> 0 then
        Writer.WriteUnsigned(TableIndex);
      if Offset = nil then
      begin
        { A table's inline elements start at 0. }
        Writer.WriteByte($41);
        Writer.WriteByte(0);
        Writer.WriteByte($0B);
      end
      else
        WriteOffset(Writer, Offset);
    end;
    if (Flags and 3) <> 0 then
    begin
      if UsesExpressions then
        Writer.WriteByte(ReferenceType)
      else
        Writer.WriteByte(0);
    end;
    Writer.WriteUnsigned(Count);
    Writer.WriteWriter(Items);
    Add(skElement);
  finally
    Items.Free;
  end;
end;

procedure TModuleEncoder.EncodeTable(Field: TTextNode);
var
  Position, ElementCount: Integer;
  Index: Cardinal;
  Import, ElementNode: TTextNode;
  Writer: TBinaryWriter;
  ReferenceType: Byte;
begin
  Index := FNextIndex[isTable];
  Inc(FNextIndex[isTable]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalTable, Index);
  if (Position < Field.Count) and Field[Position].IsListOf('import') then
  begin
    Import := Field[Position];
    if Import.Count <> 3 then
      Fail(Import, 'unexpected token in inline import');
    WriteImportHeader(Import);
    Inc(Position);
    Writer := FSections[skImport].Writer;
    Writer.WriteByte(ExternalTable);
    if Position + 1 >= Field.Count then
      Fail(Field, 'unexpected token in table type');
    Writer.WriteByte(ParseReferenceType(Field[Field.Count - 1]));
    WriteLimits(Writer, Field, Position);
    ExpectEnd(Field, Position + 1);
    Exit;
  end;
  Writer := FSections[skTable].Writer;
  if (Position + 1 < Field.Count) and Field[Position + 1].IsListOf('elem') then
  begin
    ReferenceType := ParseReferenceType(Field[Position]);
    ElementNode := Field[Position + 1];
    ExpectEnd(Field, Position + 2);
    ElementCount := ElementNode.Count - 1;
    if (ElementCount > 0) and ElementNode[1].IsKeyword('func') then
      Dec(ElementCount);
    Writer.WriteByte(ReferenceType);
    Writer.WriteByte(1);
    Writer.WriteUnsigned(ElementCount);
    Writer.WriteUnsigned(ElementCount);
    Add(skTable);
    Inc(FNextIndex[isElement]);
    WriteElementList(FSections[skElement].Writer, ElementNode, 1, ElementActive, Index, nil, ReferenceType);
    Exit;
  end;
  if Position + 1 >= Field.Count then
    Fail(Field, 'unexpected token in table type');
  Writer.WriteByte(ParseReferenceType(Field[Field.Count - 1]));
  WriteLimits(Writer, Field, Position);
  ExpectEnd(Field, Position + 1);
  Add(skTable);
end;

procedure TModuleEncoder.EncodeMemory(Field: TTextNode);
var
  Position, StringIndex: Integer;
  Index, Pages: Cardinal;
  Import, DataNode: TTextNode;
  Writer: TBinaryWriter;
  Bytes: AnsiString;
begin
  Index := FNextIndex[isMemory];
  Inc(FNextIndex[isMemory]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalMemory, Index);
  if (Position < Field.Count) and Field[Position].IsListOf('import') then
  begin
    Import := Field[Position];
    if Import.Count <> 3 then
      Fail(Import, 'unexpected token in inline import');
    WriteImportHeader(Import);
    Inc(Position);
    Writer := FSections[skImport].Writer;
    Writer.WriteByte(ExternalMemory);
    WriteLimits(Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  Writer := FSections[skMemory].Writer;
  if (Position < Field.Count) and Field[Position].IsListOf('data') then
  begin
    DataNode := Field[Position];
    ExpectEnd(Field, Position + 1);
    Bytes := '';
    for StringIndex := 1 to DataNode.Count - 1 do
    begin
      if not DataNode[StringIndex].IsAtomOf(ttString) then
        Fail(DataNode[StringIndex], 'unexpected token: expected a string');
      Bytes := Bytes + DataNode[StringIndex].Text;
    end;
    Pages := (Cardinal(Length(Bytes)) + 65535) div 65536;
    Writer.WriteByte(1);
    Writer.WriteUnsigned(Pages);
    Writer.WriteUnsigned(Pages);
    Add(skMemory);
    Inc(FNextIndex[isData]);
    Writer := FSections[skData].Writer;
    if Index = 0 then
      Writer.WriteByte(0)
    else
    begin
      Writer.WriteByte(2);
      Writer.WriteUnsigned(Index);
    end;
    Writer.WriteByte($41);
    Writer.WriteByte(0);
    Writer.WriteByte($0B);
    Writer.WriteName(Bytes);
    Add(skData);
    Exit;
  end;
  WriteLimits(Writer, Field, Position);
  ExpectEnd(Field, Position);
  Add(skMemory);
end;

procedure TModuleEncoder.EncodeGlobal(Field: TTextNode);
var
  Position: Integer;
  Index: Cardinal;
  Import: TTextNode;
  Writer: TBinaryWriter;
begin
  Index := FNextIndex[isGlobal];
  Inc(FNextIndex[isGlobal]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalGlobal, Index);
  if (Position < Field.Count) and Field[Position].IsListOf('import') then
  begin
    Import := Field[Position];
    if Import.Count <> 3 then
      Fail(Import, 'unexpected token in inline import');
    WriteImportHeader(Import);
    Inc(Position);
    Writer := FSections[skImport].Writer;
    Writer.WriteByte(ExternalGlobal);
    WriteGlobalType(Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  Writer := FSections[skGlobal].Writer;
  WriteGlobalType(Writer, Field, Position);
  WriteExpression(Writer, Field, Position);
  Add(skGlobal);
end;

procedure TModuleEncoder.EncodeExport(Field: TTextNode);
var
  Position: Integer;
  Writer: TBinaryWriter;
  Description: TTextNode;
  Space: TIndexSpace;
begin
  Writer := FSections[skExport].Writer;
  Position := 1;
  Writer.WriteName(ReadName(Field, Position));
  if Position <> Field.Count - 1 then
    Fail(Field, 'unexpected token in export');
  Description := Field[Position];
  Space := SpaceOfDescription(Description);
  if Description.Count <> 2 then
    Fail(Description, 'unexpected token in export description');
  case Space of
    isFunction: Writer.WriteByte(ExternalFunction);
    isTable: Writer.WriteByte(ExternalTable);
    isMemory: Writer.WriteByte(ExternalMemory);
    isGlobal: Writer.WriteByte(ExternalGlobal);
  end;
  Writer.WriteUnsigned(ResolveIndex(Space, Description[1]));
  Add(skExport);
end;

procedure TModuleEncoder.EncodeStart(Field: TTextNode);
begin
  if FHasStart then
    Fail(Field, 'multiple start sections');
  if Field.Count <> 2 then
    Fail(Field, 'unexpected token in start');
  FHasStart := True;
  FStart := ResolveIndex(isFunction, Field[1]);
end;

procedure TModuleEncoder.EncodeElement(Field: TTextNode);
var
  Position: Integer;
  TableIndex: Cardinal;
  Offset: TTextNode;
  Writer: TBinaryWriter;
begin
  Inc(FNextIndex[isElement]);
  Writer := FSections[skElement].Writer;
  Position := 1;
  ReadIdentifier(Field, Position);
  if (Position < Field.Count) and Field[Position].IsKeyword('declare') then
  begin
    WriteElementList(Writer, Field, Position + 1, ElementDeclarative, 0, nil);
    Exit;
  end;
  TableIndex := 0;
  if (Position < Field.Count) and Field[Position].IsListOf('table') then
  begin
    if Field[Position].Count <> 2 then
      Fail(Field[Position], 'unexpected token in table use');
    TableIndex := ResolveIndex(isTable, Field[Position][1]);
    Inc(Position);
    if (Position >= Field.Count) or (Field[Position].Kind <> tnList) then
      Fail(Field, 'unexpected token: expected an offset');
  end;
  if (Position < Field.Count) and (Field[Position].Kind = tnList) and not Field[Position].IsListOf('item') then
  begin
    Offset := Field[Position];
    WriteElementList(Writer, Field, Position + 1, ElementActive, TableIndex, Offset);
  end
  else
    WriteElementList(Writer, Field, Position, ElementPassive, 0, nil);
end;

procedure TModuleEncoder.EncodeData(Field: TTextNode);
var
  Position: Integer;
  MemoryIndex: Cardinal;
  Writer: TBinaryWriter;
  Offset: TTextNode;
  Bytes: AnsiString;
begin
  Inc(FNextIndex[isData]);
  Writer := FSections[skData].Writer;
  Position := 1;
  ReadIdentifier(Field, Position);
  MemoryIndex := 0;
  Offset := nil;
  if (Position < Field.Count) and Field[Position].IsListOf('memory') then
  begin
    if Field[Position].Count <> 2 then
      Fail(Field[Position], 'unexpected token in memory use');
    MemoryIndex := ResolveIndex(isMemory, Field[Position][1]);
    Inc(Position);
    if (Position >= Field.Count) or (Field[Position].Kind <> tnList) then
      Fail(Field, 'unexpected token: expected an offset');
  end;
  if (Position < Field.Count) and (Field[Position].Kind = tnList) then
  begin
    Offset := Field[Position];
    Inc(Position);
  end;
  Bytes := '';
  while Position < Field.Count do
    Bytes := Bytes + ReadString(Field, Position);
  if Offset = nil then
    Writer.WriteByte(1)
  else
  begin
    if MemoryIndex = 0 then
      Writer.WriteByte(0)
    else
    begin
      Writer.WriteByte(2);
      Writer.WriteUnsigned(MemoryIndex);
    end;
    WriteOffset(Writer, Offset);
  end;
  Writer.WriteName(Bytes);
  Add(skData);
end;

procedure TModuleEncoder.EncodeField(Field: TTextNode);
var
  Head: AnsiString;
begin
  Head := Field.Head;
  if Head = 'import' then EncodeImport(Field)
  else if Head = 'func' then EncodeFunction(Field)
  else if Head = 'table' then EncodeTable(Field)
  else if Head = 'memory' then EncodeMemory(Field)
  else if Head = 'global' then EncodeGlobal(Field)
  else if Head = 'export' then EncodeExport(Field)
  else if Head = 'start' then EncodeStart(Field)
  else if Head = 'elem' then EncodeElement(Field)
  else if Head = 'data' then EncodeData(Field);
end;

function TModuleEncoder.Assemble: TBytes;
var
  Output, Content: TBinaryWriter;
  Index: Integer;
  FunctionType: TFunctionType;

  procedure WriteSection(Id: Byte; Kind: TSectionKind);
  begin
    if FSections[Kind].Count = 0 then
      Exit;
    Content.Clear;
    Content.WriteUnsigned(FSections[Kind].Count);
    Content.WriteWriter(FSections[Kind].Writer);
    Output.WriteByte(Id);
    Output.WriteSized(Content);
  end;

begin
  Output := TBinaryWriter.Create;
  Content := TBinaryWriter.Create;
  try
    Output.WriteRawString(#0'asm'#1#0#0#0);
    if TypeCount > 0 then
    begin
      Content.Clear;
      Content.WriteUnsigned(TypeCount);
      for Index := 0 to TypeCount - 1 do
      begin
        FunctionType := Types[Index];
        Content.WriteByte($60);
        Content.WriteUnsigned(Length(FunctionType.Parameters));
        if FunctionType.Parameters <> nil then
          Content.WriteRaw(FunctionType.Parameters[0], Length(FunctionType.Parameters));
        Content.WriteUnsigned(Length(FunctionType.Results));
        if FunctionType.Results <> nil then
          Content.WriteRaw(FunctionType.Results[0], Length(FunctionType.Results));
      end;
      Output.WriteByte(1);
      Output.WriteSized(Content);
    end;
    WriteSection(2, skImport);
    WriteSection(3, skFunction);
    WriteSection(4, skTable);
    WriteSection(5, skMemory);
    WriteSection(6, skGlobal);
    WriteSection(7, skExport);
    if FHasStart then
    begin
      Content.Clear;
      Content.WriteUnsigned(FStart);
      Output.WriteByte(8);
      Output.WriteSized(Content);
    end;
    WriteSection(9, skElement);
    if (FSections[skData].Count > 0) or UsesDataIndices then
    begin
      Content.Clear;
      Content.WriteUnsigned(FSections[skData].Count);
      Output.WriteByte(12);
      Output.WriteSized(Content);
    end;
    WriteSection(10, skCode);
    WriteSection(11, skData);
    Result := Output.ToBytes;
  finally
    Content.Free;
    Output.Free;
  end;
end;

function TModuleEncoder.Encode(Container: TTextNode; FirstField: Integer): TBytes;
var
  Index: Integer;
begin
  for Index := FirstField to Container.Count - 1 do
  begin
    if Container[Index].Kind <> tnList then
      Fail(Container[Index], 'unexpected token ' + Container[Index].Text);
    CollectField(Container[Index]);
  end;
  ExplicitTypeCount := TypeCount;
  for Index := FirstField to Container.Count - 1 do
    EncodeField(Container[Index]);
  Result := Assemble;
end;

function EncodeModuleFields(Container: TTextNode; FirstField: Integer): TBytes;
var
  Encoder: TModuleEncoder;
begin
  Encoder := TModuleEncoder.Create;
  try
    Result := Encoder.Encode(Container, FirstField);
  finally
    Encoder.Free;
  end;
end;

end.
