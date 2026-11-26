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
  The sections of a module being encoded (core specification 3.0,
  section 5.5) and what every kind of module field needs to write into
  them: the contents of each section as the fields add entries, the
  reading of identifiers, strings and names, limits, memory, table and
  global types, constant expressions and offsets, and finally the
  assembly of the binary module with its sections in the required order
  (type, import, function, table, memory, tag, global, export, start,
  element, data count, code, data).

  Limits belong to an address type: "i64" before them makes a 64-bit
  memory or table (flag bit 2). Their bounds are read as 64-bit numbers
  either way (the text format allows that; a 32-bit memory or table
  beyond its range is invalid, not malformed).

  The data count section is written whenever there are data segments or
  code uses a data index, which is always allowed and what memory.init,
  data.drop and the array data instructions need.
}
unit WasmText.Sections;

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
  WasmText.Context;

type
  TSection = record
    Writer: TBinaryWriter;
    Count: Cardinal;
  end;

  TSectionKind = (skImport, skFunction, skTable, skMemory, skTag, skGlobal, skExport, skElement, skCode, skData);

  TSectionEncoder = class(TModuleContext)
  protected
    FSections: array[TSectionKind] of TSection;
    FNextIndex: array[TIndexSpace] of Cardinal;
    FHasStart: Boolean;
    FStart: Cardinal;
    procedure Add(Kind: TSectionKind);
    function ReadIdentifier(Field: TTextNode; var Position: Integer): AnsiString;
    function ReadString(Field: TTextNode; var Position: Integer): AnsiString;
    function ReadName(Field: TTextNode; var Position: Integer): AnsiString;
    procedure ExpectEnd(Field: TTextNode; Position: Integer);
    { An optional address type (i32 or i64); True for i64. }
    function ReadAddressType(Field: TTextNode; var Position: Integer): Boolean;
    procedure WriteLimits(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer; Is64: Boolean);
    { i64? limits }
    procedure WriteMemoryType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    { i64? limits reftype }
    procedure WriteTableType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    procedure WriteGlobalType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
    { Parent's children from Position on as a constant expression. }
    procedure WriteExpression(Writer: TBinaryWriter; Parent: TTextNode; Position: Integer);
    { "(offset instr*)" or one folded instruction. }
    procedure WriteOffset(Writer: TBinaryWriter; Node: TTextNode);
    { i32.const 0 or i64.const 0, as an offset expression. }
    procedure WriteZeroOffset(Writer: TBinaryWriter; Is64: Boolean);
    function Assemble: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  WasmText.Numbers,
  WasmText.Expressions;

const
  LimitsHasMaximum = 1;
  Limits64 = 4;

constructor TSectionEncoder.Create;
var
  Kind: TSectionKind;
begin
  inherited Create;
  for Kind := Low(TSectionKind) to High(TSectionKind) do
    FSections[Kind].Writer := TBinaryWriter.Create;
end;

destructor TSectionEncoder.Destroy;
var
  Kind: TSectionKind;
begin
  for Kind := Low(TSectionKind) to High(TSectionKind) do
    FSections[Kind].Writer.Free;
  inherited Destroy;
end;

procedure TSectionEncoder.Add(Kind: TSectionKind);
begin
  Inc(FSections[Kind].Count);
end;

function TSectionEncoder.ReadIdentifier(Field: TTextNode; var Position: Integer): AnsiString;
begin
  Result := '';
  if (Position < Field.Count) and Field[Position].IsAtomOf(ttIdentifier) then
  begin
    Result := Field[Position].Text;
    Inc(Position);
  end;
end;

function TSectionEncoder.ReadString(Field: TTextNode; var Position: Integer): AnsiString;
begin
  if (Position >= Field.Count) or not Field[Position].IsAtomOf(ttString) then
    Fail(Field, 'unexpected token: expected a string');
  Result := Field[Position].Text;
  Inc(Position);
end;

function TSectionEncoder.ReadName(Field: TTextNode; var Position: Integer): AnsiString;
begin
  Result := ReadString(Field, Position);
  if not IsValidUtf8(Result) then
    Fail(Field, 'malformed UTF-8 encoding');
end;

procedure TSectionEncoder.ExpectEnd(Field: TTextNode; Position: Integer);
begin
  if Position < Field.Count then
    Fail(Field[Position], 'unexpected token ' + Field[Position].Text);
end;

function TSectionEncoder.ReadAddressType(Field: TTextNode; var Position: Integer): Boolean;
begin
  Result := False;
  if Position >= Field.Count then
    Exit;
  if Field[Position].IsKeyword('i64') then
  begin
    Result := True;
    Inc(Position);
  end
  else if Field[Position].IsKeyword('i32') then
    Inc(Position);
end;

procedure TSectionEncoder.WriteLimits(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer; Is64: Boolean);
var
  Minimum, Maximum: QWord;
  Flags: Byte;
begin
  if Is64 then
    Flags := Limits64
  else
    Flags := 0;
  if (Position >= Field.Count) or not Field[Position].IsAtomOf(ttNumber) then
    Fail(Field, 'unexpected token: expected limits');
  Minimum := ParseUnsigned(Field[Position].Text, 64);
  Inc(Position);
  if (Position < Field.Count) and Field[Position].IsAtomOf(ttNumber) then
  begin
    Maximum := ParseUnsigned(Field[Position].Text, 64);
    Inc(Position);
    Writer.WriteByte(Flags or LimitsHasMaximum);
    Writer.WriteUnsigned(Minimum);
    Writer.WriteUnsigned(Maximum);
  end
  else
  begin
    Writer.WriteByte(Flags);
    Writer.WriteUnsigned(Minimum);
  end;
end;

procedure TSectionEncoder.WriteMemoryType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
begin
  WriteLimits(Writer, Field, Position, ReadAddressType(Field, Position));
end;

procedure TSectionEncoder.WriteTableType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
var
  Limits: TBinaryWriter;
begin
  Limits := TBinaryWriter.Create;
  try
    WriteLimits(Limits, Field, Position, ReadAddressType(Field, Position));
    if Position >= Field.Count then
      Fail(Field, 'unexpected end: expected a reference type');
    WriteValueType(Writer, ParseReferenceType(Field[Position]));
    Inc(Position);
    Writer.WriteWriter(Limits);
  finally
    Limits.Free;
  end;
end;

procedure TSectionEncoder.WriteGlobalType(Writer: TBinaryWriter; Field: TTextNode; var Position: Integer);
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
    WriteValueType(Writer, ParseValueType(Node[1]));
    Writer.WriteByte(1);
  end
  else
  begin
    WriteValueType(Writer, ParseValueType(Node));
    Writer.WriteByte(0);
  end;
  Inc(Position);
end;

procedure TSectionEncoder.WriteExpression(Writer: TBinaryWriter; Parent: TTextNode; Position: Integer);
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

procedure TSectionEncoder.WriteOffset(Writer: TBinaryWriter; Node: TTextNode);
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

procedure TSectionEncoder.WriteZeroOffset(Writer: TBinaryWriter; Is64: Boolean);
begin
  if Is64 then
    Writer.WriteByte($42)
  else
    Writer.WriteByte($41);
  Writer.WriteByte(0);
  Writer.WriteByte($0B);
end;

function TSectionEncoder.Assemble: TBytes;
var
  Output, Content: TBinaryWriter;
  GroupIndex: Integer;
  Group: TTypeGroup;
  Index: Cardinal;

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
    if GroupCount > 0 then
    begin
      Content.Clear;
      Content.WriteUnsigned(GroupCount);
      for GroupIndex := 0 to GroupCount - 1 do
      begin
        Group := Groups[GroupIndex];
        if Group.IsRecursive then
        begin
          Content.WriteByte(RecursionGroup);
          Content.WriteUnsigned(Group.Count);
        end;
        Index := 0;
        while Index < Group.Count do
        begin
          WriteTypeDefinition(Content, Definitions[Group.First + Index]);
          Inc(Index);
        end;
      end;
      Output.WriteByte(1);
      Output.WriteSized(Content);
    end;
    WriteSection(2, skImport);
    WriteSection(3, skFunction);
    WriteSection(4, skTable);
    WriteSection(5, skMemory);
    WriteSection(13, skTag);
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

end.
