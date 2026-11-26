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
  Element and data segments (core specification 3.0, sections 6.6.12
  and 6.6.13):

    (elem $e? elemlist)                              passive
    (elem $e? (table x)? offset elemlist)            active
    (elem $e? declare elemlist)                      declarative
    (data $d? string*)                               passive
    (data $d? (memory x)? offset string*)            active

  An element list is "reftype item*" (each item "(item instr*)" or one
  folded instruction) or "func x*"; an active segment without a table
  use may leave out "func" too. The offset is "(offset instr*)" or one
  folded instruction.

  A list of function indices is encoded as one (flags 0 to 3, element
  kind 0); a list of expressions with its reference type (flags 4 to
  7, the type left out for funcref in table 0). The inline segments of
  a table or memory abbreviation are encoded here as well.
}
unit WasmText.Segments;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Tree,
  WasmText.Binary,
  WasmText.Types,
  WasmText.Context,
  WasmText.Sections;

type
  TElementMode = (emActive, emPassive, emDeclarative);

  TSegmentEncoder = class(TSectionEncoder)
  protected
    { The element list of Field from Position on, with its mode;
      Offset nil for an active segment at a zero offset of the given
      address type. DefaultType is the type of a list of expressions
      written without one (a table abbreviation's type). }
    procedure WriteElementSegment(Field: TTextNode; Position: Integer; Mode: TElementMode; TableIndex: Cardinal;
      Offset: TTextNode; OffsetIs64: Boolean; const DefaultType: TValueType);
    { The element segment of "(table ... reftype (elem ...))". }
    procedure WriteTableElements(ElementNode: TTextNode; TableIndex: Cardinal; Is64: Boolean;
      const ReferenceType: TValueType);
    { The data segment of "(memory ... (data ...))". }
    procedure WriteMemoryData(MemoryIndex: Cardinal; Is64: Boolean; const Bytes: AnsiString);
    procedure EncodeElement(Field: TTextNode);
    procedure EncodeData(Field: TTextNode);
  end;

implementation

const
  ElementFlagPassiveOrDeclarative = 1;
  ElementFlagExplicitTable = 2;
  ElementFlagExpressions = 4;
  ElementKindFunction = 0;

procedure TSegmentEncoder.WriteElementSegment(Field: TTextNode; Position: Integer; Mode: TElementMode;
  TableIndex: Cardinal; Offset: TTextNode; OffsetIs64: Boolean; const DefaultType: TValueType);
var
  ReferenceType: TValueType;
  UsesExpressions: Boolean;
  Flags: Byte;
  Index, Count: Integer;
  Node: TTextNode;
  Items: TBinaryWriter;
begin
  ReferenceType := SingleByte(ValueTypeFuncRef);
  UsesExpressions := False;
  if (Position < Field.Count) and Field[Position].IsKeyword('func') then
    Inc(Position)
  else if (Position < Field.Count) and IsReferenceType(Field[Position]) then
  begin
    ReferenceType := ParseReferenceType(Field[Position]);
    UsesExpressions := True;
    Inc(Position);
  end
  else if (Position < Field.Count) and (Field[Position].Kind = tnList) then
  begin
    ReferenceType := DefaultType;
    UsesExpressions := True;
  end
  else if (Mode <> emActive) and (Position < Field.Count) then
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
      Flags := ElementFlagExpressions
    else
      Flags := 0;
    case Mode of
      emActive:
        if (TableIndex <> 0) or (UsesExpressions and not SameValueType(ReferenceType, SingleByte(ValueTypeFuncRef))) then
          Flags := Flags or ElementFlagExplicitTable;
      emPassive:
        Flags := Flags or ElementFlagPassiveOrDeclarative;
      emDeclarative:
        Flags := Flags or ElementFlagPassiveOrDeclarative or ElementFlagExplicitTable;
    end;
    FSections[skElement].Writer.WriteUnsigned(Flags);
    if Mode = emActive then
    begin
      if (Flags and ElementFlagExplicitTable) <> 0 then
        FSections[skElement].Writer.WriteUnsigned(TableIndex);
      if Offset = nil then
        WriteZeroOffset(FSections[skElement].Writer, OffsetIs64)
      else
        WriteOffset(FSections[skElement].Writer, Offset);
    end;
    if (Flags and (ElementFlagPassiveOrDeclarative or ElementFlagExplicitTable)) <> 0 then
    begin
      if UsesExpressions then
        WriteValueType(FSections[skElement].Writer, ReferenceType)
      else
        FSections[skElement].Writer.WriteByte(ElementKindFunction);
    end;
    FSections[skElement].Writer.WriteUnsigned(Count);
    FSections[skElement].Writer.WriteWriter(Items);
    Add(skElement);
  finally
    Items.Free;
  end;
end;

procedure TSegmentEncoder.WriteTableElements(ElementNode: TTextNode; TableIndex: Cardinal; Is64: Boolean;
  const ReferenceType: TValueType);
var
  Index: Integer;
  Writer: TBinaryWriter;
begin
  { Function indices for any type but funcref become (ref.func x)
    expressions of the table's type. }
  if (ElementNode.Count > 1) and (ElementNode[1].Kind = tnAtom) and
     not SameValueType(ReferenceType, SingleByte(ValueTypeFuncRef)) then
  begin
    Writer := FSections[skElement].Writer;
    Writer.WriteUnsigned(ElementFlagExpressions or ElementFlagExplicitTable);
    Writer.WriteUnsigned(TableIndex);
    WriteZeroOffset(Writer, Is64);
    WriteValueType(Writer, ReferenceType);
    Index := 1;
    if ElementNode[Index].IsKeyword('func') then
      Inc(Index);
    Writer.WriteUnsigned(ElementNode.Count - Index);
    while Index < ElementNode.Count do
    begin
      Writer.WriteByte($D2);
      Writer.WriteUnsigned(ResolveIndex(isFunction, ElementNode[Index]));
      Writer.WriteByte($0B);
      Inc(Index);
    end;
    Add(skElement);
    Exit;
  end;
  WriteElementSegment(ElementNode, 1, emActive, TableIndex, nil, Is64, ReferenceType);
end;

procedure TSegmentEncoder.WriteMemoryData(MemoryIndex: Cardinal; Is64: Boolean; const Bytes: AnsiString);
var
  Writer: TBinaryWriter;
begin
  Writer := FSections[skData].Writer;
  if MemoryIndex = 0 then
    Writer.WriteByte(0)
  else
  begin
    Writer.WriteByte(2);
    Writer.WriteUnsigned(MemoryIndex);
  end;
  WriteZeroOffset(Writer, Is64);
  Writer.WriteName(Bytes);
  Add(skData);
end;

procedure TSegmentEncoder.EncodeElement(Field: TTextNode);
var
  Position: Integer;
  TableIndex: Cardinal;
begin
  Inc(FNextIndex[isElement]);
  Position := 1;
  ReadIdentifier(Field, Position);
  if (Position < Field.Count) and Field[Position].IsKeyword('declare') then
  begin
    WriteElementSegment(Field, Position + 1, emDeclarative, 0, nil, False, SingleByte(ValueTypeFuncRef));
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
    { With a table use, the element list needs its "func" or type. }
    if (Position + 1 < Field.Count) and (Field[Position + 1].Kind = tnAtom) and
       not Field[Position + 1].IsKeyword('func') and not IsReferenceType(Field[Position + 1]) then
      Fail(Field[Position + 1], 'unexpected token: expected an element list');
  end;
  if (Position < Field.Count) and (Field[Position].Kind = tnList) and not Field[Position].IsListOf('item') and
     not Field[Position].IsListOf('ref') then
    WriteElementSegment(Field, Position + 1, emActive, TableIndex, Field[Position], False,
      SingleByte(ValueTypeFuncRef))
  else
    WriteElementSegment(Field, Position, emPassive, 0, nil, False, SingleByte(ValueTypeFuncRef));
end;

procedure TSegmentEncoder.EncodeData(Field: TTextNode);
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

end.
