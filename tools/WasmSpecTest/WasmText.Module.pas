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
  A text format module into the binary format (core specification 3.0,
  sections 6.6 and 5.5).

  Two passes over the module fields. The first gives every type,
  function, table, memory, tag, global, element and data segment its
  index (fields in the order written, imports first, as the format
  requires: an import after a definition is malformed) and records
  identifiers; then the type definitions are read, now that every type
  identifier is known. The second pass encodes each field into its
  section (WasmText.Sections; segments in WasmText.Segments), in the
  same order, so indices and section entries agree; type uses met on
  the way append their implicit types after the explicit ones.

  The inline abbreviations are expanded here: exports and imports
  written inside func, table, memory, global and tag fields, element
  lists inside a table (its size is the list's length) and data strings
  inside a memory (its size is the data's length in pages). A table may
  carry an initialiser expression after its type ("(table 10 (ref $t)
  (ref.func $f))"), encoded with the 0x40 0x00 table form.
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
  WasmText.Types,
  WasmText.Context,
  WasmText.Sections,
  WasmText.Segments,
  WasmText.TypeDefinitions;

{ Fields are Container's children from FirstField on. }
function EncodeModuleFields(Container: TTextNode; FirstField: Integer): TBytes;

implementation

uses
  WasmText.Expressions;

type
  TModuleEncoder = class(TSegmentEncoder)
  private
    FDefinitionSeen: Boolean;
    FTypeNodes: TTypeNodeArray;
    function SkipInlineExports(Field: TTextNode; Position: Integer): Integer;
    function SpaceOfDescription(Node: TTextNode): TIndexSpace;
    procedure NoteImport(Node: TTextNode);
    procedure CollectField(Field: TTextNode);
    procedure WriteInlineExports(Field: TTextNode; var Position: Integer; Kind: Byte; Index: Cardinal);
    procedure WriteImportHeader(Import: TTextNode);
    { An inline "(import "m" "n")" at Position: writes the import's
      names and kind and steps over it; False when there is none. }
    function ReadInlineImport(Field: TTextNode; var Position: Integer; Kind: Byte): Boolean;
    procedure WriteTagType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    procedure EncodeImport(Field: TTextNode);
    procedure EncodeFunction(Field: TTextNode);
    procedure EncodeFunctionBody(Field: TTextNode; Position: Integer; const TypeUse: TTypeUse);
    procedure EncodeTable(Field: TTextNode);
    procedure EncodeMemory(Field: TTextNode);
    procedure EncodeGlobal(Field: TTextNode);
    procedure EncodeTag(Field: TTextNode);
    procedure EncodeExport(Field: TTextNode);
    procedure EncodeStart(Field: TTextNode);
    procedure EncodeField(Field: TTextNode);
  public
    function Encode(Container: TTextNode; FirstField: Integer): TBytes;
  end;

const
  ExternalFunction = 0;
  ExternalTable = 1;
  ExternalMemory = 2;
  ExternalGlobal = 3;
  ExternalTag = 4;

  TagAttributeException = 0;
  TableWithInitializer = $40;

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
  else if Node.IsListOf('tag') then Result := isTag
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
  Description: TTextNode;
  Space: TIndexSpace;
begin
  Head := Field.Head;
  Position := 1;
  if (Head = 'type') or (Head = 'rec') then
    CollectTypeField(Self, Field, FTypeNodes)
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
  else if (Head = 'func') or (Head = 'table') or (Head = 'memory') or (Head = 'global') or (Head = 'tag') then
  begin
    Space := SpaceOfDescription(Field);
    Identifier := ReadIdentifier(Field, Position);
    Position := SkipInlineExports(Field, Position);
    if (Position < Field.Count) and Field[Position].IsListOf('import') then
      NoteImport(Field)
    else
    begin
      FDefinitionSeen := True;
      if (Head = 'table') or (Head = 'memory') then
        ReadAddressType(Field, Position);
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

function TModuleEncoder.ReadInlineImport(Field: TTextNode; var Position: Integer; Kind: Byte): Boolean;
var
  Import: TTextNode;
begin
  Result := (Position < Field.Count) and Field[Position].IsListOf('import');
  if not Result then
    Exit;
  Import := Field[Position];
  if Import.Count <> 3 then
    Fail(Import, 'unexpected token in inline import');
  WriteImportHeader(Import);
  FSections[skImport].Writer.WriteByte(Kind);
  Inc(Position);
end;

procedure TModuleEncoder.WriteTagType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
var
  TypeUse: TTypeUse;
begin
  TypeUse := ParseTypeUse(Field, Position, tuFunction);
  Writer.WriteByte(TagAttributeException);
  Writer.WriteUnsigned(TypeIndexOf(TypeUse));
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
        WriteTableType(Writer, Description, Position);
      end;
    isMemory:
      begin
        Writer.WriteByte(ExternalMemory);
        WriteMemoryType(Writer, Description, Position);
      end;
    isGlobal:
      begin
        Writer.WriteByte(ExternalGlobal);
        WriteGlobalType(Writer, Description, Position);
      end;
    isTag:
      begin
        Writer.WriteByte(ExternalTag);
        WriteTagType(Writer, Description, Position);
      end;
  end;
  ExpectEnd(Description, Position);
end;

procedure TModuleEncoder.EncodeFunctionBody(Field: TTextNode; Position: Integer; const TypeUse: TTypeUse);
var
  Locals: TStringList;
  Body: TBinaryWriter;
  LocalTypes: TValueTypeArray;
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
        AppendValueType(LocalTypes, ParseValueType(Node[2]));
        Inc(LocalIndex);
      end
      else
        for Index := 1 to Node.Count - 1 do
        begin
          AppendValueType(LocalTypes, ParseValueType(Node[Index]));
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
      while (Index < Length(LocalTypes)) and SameValueType(LocalTypes[Index], LocalTypes[RunStart]) do
        Inc(Index);
      Inc(RunCount);
    end;
    Body.WriteUnsigned(RunCount);
    Index := 0;
    while Index < Length(LocalTypes) do
    begin
      RunStart := Index;
      while (Index < Length(LocalTypes)) and SameValueType(LocalTypes[Index], LocalTypes[RunStart]) do
        Inc(Index);
      Body.WriteUnsigned(Index - RunStart);
      WriteValueType(Body, LocalTypes[RunStart]);
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
begin
  Index := FNextIndex[isFunction];
  Inc(FNextIndex[isFunction]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalFunction, Index);
  if ReadInlineImport(Field, Position, ExternalFunction) then
  begin
    TypeUse := ParseTypeUse(Field, Position, tuFunction);
    ExpectEnd(Field, Position);
    FSections[skImport].Writer.WriteUnsigned(TypeIndexOf(TypeUse));
    Exit;
  end;
  TypeUse := ParseTypeUse(Field, Position, tuFunction);
  FSections[skFunction].Writer.WriteUnsigned(TypeIndexOf(TypeUse));
  Add(skFunction);
  EncodeFunctionBody(Field, Position, TypeUse);
end;

procedure TModuleEncoder.EncodeTable(Field: TTextNode);
var
  Position, ElementCount: Integer;
  Index: Cardinal;
  ElementNode: TTextNode;
  Writer, TableType: TBinaryWriter;
  ReferenceType: TValueType;
  Is64: Boolean;
begin
  Index := FNextIndex[isTable];
  Inc(FNextIndex[isTable]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalTable, Index);
  if ReadInlineImport(Field, Position, ExternalTable) then
  begin
    WriteTableType(FSections[skImport].Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  Writer := FSections[skTable].Writer;
  Add(skTable);
  if (Position + 1 < Field.Count) and Field[Position + 1].IsListOf('elem') or
     (Position + 2 < Field.Count) and Field[Position + 2].IsListOf('elem') then
  begin
    Is64 := ReadAddressType(Field, Position);
    if Position + 1 >= Field.Count then
      Fail(Field, 'unexpected token in table');
    ReferenceType := ParseReferenceType(Field[Position]);
    ElementNode := Field[Position + 1];
    ExpectEnd(Field, Position + 2);
    ElementCount := ElementNode.Count - 1;
    if (ElementCount > 0) and ElementNode[1].IsKeyword('func') then
      Dec(ElementCount);
    WriteValueType(Writer, ReferenceType);
    if Is64 then
      Writer.WriteByte(5)
    else
      Writer.WriteByte(1);
    Writer.WriteUnsigned(ElementCount);
    Writer.WriteUnsigned(ElementCount);
    Inc(FNextIndex[isElement]);
    WriteTableElements(ElementNode, Index, Is64, ReferenceType);
    Exit;
  end;
  TableType := TBinaryWriter.Create;
  try
    WriteTableType(TableType, Field, Position);
    if Position < Field.Count then
    begin
      Writer.WriteByte(TableWithInitializer);
      Writer.WriteByte(0);
      Writer.WriteWriter(TableType);
      WriteExpression(Writer, Field, Position);
    end
    else
      Writer.WriteWriter(TableType);
  finally
    TableType.Free;
  end;
end;

procedure TModuleEncoder.EncodeMemory(Field: TTextNode);
var
  Position, StringIndex: Integer;
  Index: Cardinal;
  Pages: QWord;
  DataNode: TTextNode;
  Writer: TBinaryWriter;
  Bytes: AnsiString;
  Is64: Boolean;
begin
  Index := FNextIndex[isMemory];
  Inc(FNextIndex[isMemory]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalMemory, Index);
  if ReadInlineImport(Field, Position, ExternalMemory) then
  begin
    WriteMemoryType(FSections[skImport].Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  Writer := FSections[skMemory].Writer;
  Add(skMemory);
  Is64 := False;
  if (Position + 1 < Field.Count) and Field[Position + 1].IsListOf('data') then
    Is64 := ReadAddressType(Field, Position);
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
    Pages := (QWord(Length(Bytes)) + 65535) div 65536;
    if Is64 then
      Writer.WriteByte(5)
    else
      Writer.WriteByte(1);
    Writer.WriteUnsigned(Pages);
    Writer.WriteUnsigned(Pages);
    Inc(FNextIndex[isData]);
    WriteMemoryData(Index, Is64, Bytes);
    Exit;
  end;
  WriteMemoryType(Writer, Field, Position);
  ExpectEnd(Field, Position);
end;

procedure TModuleEncoder.EncodeGlobal(Field: TTextNode);
var
  Position: Integer;
  Index: Cardinal;
  Writer: TBinaryWriter;
begin
  Index := FNextIndex[isGlobal];
  Inc(FNextIndex[isGlobal]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalGlobal, Index);
  if ReadInlineImport(Field, Position, ExternalGlobal) then
  begin
    WriteGlobalType(FSections[skImport].Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  Writer := FSections[skGlobal].Writer;
  WriteGlobalType(Writer, Field, Position);
  WriteExpression(Writer, Field, Position);
  Add(skGlobal);
end;

procedure TModuleEncoder.EncodeTag(Field: TTextNode);
var
  Position: Integer;
  Index: Cardinal;
begin
  Index := FNextIndex[isTag];
  Inc(FNextIndex[isTag]);
  Position := 1;
  ReadIdentifier(Field, Position);
  WriteInlineExports(Field, Position, ExternalTag, Index);
  if ReadInlineImport(Field, Position, ExternalTag) then
  begin
    WriteTagType(FSections[skImport].Writer, Field, Position);
    ExpectEnd(Field, Position);
    Exit;
  end;
  WriteTagType(FSections[skTag].Writer, Field, Position);
  ExpectEnd(Field, Position);
  Add(skTag);
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
    isTag: Writer.WriteByte(ExternalTag);
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
  else if Head = 'tag' then EncodeTag(Field)
  else if Head = 'export' then EncodeExport(Field)
  else if Head = 'start' then EncodeStart(Field)
  else if Head = 'elem' then EncodeElement(Field)
  else if Head = 'data' then EncodeData(Field);
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
  DefineTypes(Self, FTypeNodes);
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
