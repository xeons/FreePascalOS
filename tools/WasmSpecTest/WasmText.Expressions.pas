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
  Instructions of the text format into binary (core specification 2.0,
  section 6.5): plain instructions, whose immediates follow them as
  sibling tokens and whose blocks run to a matching "end", and folded
  instructions, written as lists with their operands nested inside,
  which are encoded operands first.

  Labels are kept on a stack of names (the function body's own label is
  the bottom one), so br $name becomes the depth of the innermost block
  with that name; locals come from the function's parameter and local
  identifiers. Every other index goes through the module context.
}
unit WasmText.Expressions;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree,
  WasmText.Binary,
  WasmText.Instructions,
  WasmText.Context;

type
  TExpressionEncoder = class
  private
    FContext: TModuleContext;
    FWriter: TBinaryWriter;
    FLocals: TStringList;
    FLabels: array of AnsiString;
    FLabelCount: Integer;
    procedure Fail(Node: TTextNode; const Message: AnsiString);
    procedure PushLabel(const Name: AnsiString);
    procedure PopLabel;
    function ResolveLabel(Node: TTextNode): Cardinal;
    function ResolveLocal(Node: TTextNode): Cardinal;
    function ReadOptionalLabel(Parent: TTextNode; var Position: Integer): AnsiString;
    procedure WriteOpcode(Output: TBinaryWriter; const Info: TInstructionInfo);
    procedure ParseBlockType(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    procedure ParseMemoryArgument(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer;
      Output: TBinaryWriter);
    procedure ParseVectorConstant(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    procedure ParseLane(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    function ParseOptionalIndex(Space: TIndexSpace; Parent: TTextNode; var Position: Integer;
      out Index: Cardinal): Boolean;
    { Writes the opcode and the immediates read from Parent's children
      at Position on (all but block instructions). }
    procedure EncodeSimple(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer;
      Output: TBinaryWriter);
    procedure EncodePlainBlock(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer);
    procedure EncodeFolded(Node: TTextNode);
    procedure EncodeFoldedIf(Node: TTextNode);
    procedure EncodeInstructions(Parent: TTextNode; var Position: Integer; InsidePlainBlock: Boolean);
  public
    { Locals maps local identifiers to indices (nil: none). }
    constructor Create(Context: TModuleContext; Writer: TBinaryWriter; Locals: TStringList);
    { Parent's children from Position to the end, as one instruction
      sequence (without the final end). }
    procedure EncodeSequence(Parent: TTextNode; Position: Integer);
    { One folded instruction (an offset or element item abbreviation). }
    procedure EncodeFoldedInstruction(Node: TTextNode);
  end;

implementation

uses
  WasmText.Numbers;

constructor TExpressionEncoder.Create(Context: TModuleContext; Writer: TBinaryWriter; Locals: TStringList);
begin
  inherited Create;
  FContext := Context;
  FWriter := Writer;
  FLocals := Locals;
end;

procedure TExpressionEncoder.Fail(Node: TTextNode; const Message: AnsiString);
begin
  FContext.Fail(Node, Message);
end;

procedure TExpressionEncoder.PushLabel(const Name: AnsiString);
begin
  if FLabelCount = Length(FLabels) then
    SetLength(FLabels, FLabelCount * 2 + 8);
  FLabels[FLabelCount] := Name;
  Inc(FLabelCount);
end;

procedure TExpressionEncoder.PopLabel;
begin
  Dec(FLabelCount);
end;

function TExpressionEncoder.ResolveLabel(Node: TTextNode): Cardinal;
var
  Index: Integer;
begin
  if Node.IsAtomOf(ttNumber) then
    Exit(Cardinal(ParseUnsigned(Node.Text, 32)));
  if not Node.IsAtomOf(ttIdentifier) then
    Fail(Node, 'unexpected token: expected a label');
  for Index := FLabelCount - 1 downto 0 do
    if FLabels[Index] = Node.Text then
      Exit(Cardinal(FLabelCount - 1 - Index));
  Fail(Node, 'unknown label ' + Node.Text);
  Result := 0;
end;

function TExpressionEncoder.ResolveLocal(Node: TTextNode): Cardinal;
var
  Found: Integer;
begin
  if Node.IsAtomOf(ttNumber) then
    Exit(Cardinal(ParseUnsigned(Node.Text, 32)));
  if not Node.IsAtomOf(ttIdentifier) then
    Fail(Node, 'unexpected token: expected a local');
  if (FLocals = nil) or not FLocals.Find(Node.Text, Found) then
    Fail(Node, 'unknown local ' + Node.Text);
  Result := Cardinal(PtrUInt(FLocals.Objects[Found]));
end;

function TExpressionEncoder.ReadOptionalLabel(Parent: TTextNode; var Position: Integer): AnsiString;
begin
  Result := '';
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttIdentifier) then
  begin
    Result := Parent[Position].Text;
    Inc(Position);
  end;
end;

procedure TExpressionEncoder.WriteOpcode(Output: TBinaryWriter; const Info: TInstructionInfo);
begin
  if Info.Prefix <> 0 then
  begin
    Output.WriteByte(Info.Prefix);
    Output.WriteUnsigned(Info.Code);
  end
  else
    Output.WriteByte(Byte(Info.Code));
end;

procedure TExpressionEncoder.ParseBlockType(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
var
  TypeUse: TTypeUse;
begin
  TypeUse := FContext.ParseTypeUse(Parent, Position, tuInstruction);
  if not TypeUse.HasTypeIndex and (Length(TypeUse.Parameters) = 0) and (Length(TypeUse.Results) <= 1) then
  begin
    if Length(TypeUse.Results) = 0 then
      Output.WriteByte($40)
    else
      Output.WriteByte(TypeUse.Results[0]);
  end
  else
    Output.WriteSigned(FContext.TypeIndexOf(TypeUse));
end;

function PowerOfTwoExponent(Value: QWord): Integer;
begin
  Result := -1;
  if (Value = 0) or ((Value and (Value - 1)) <> 0) then
    Exit;
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

procedure TExpressionEncoder.ParseMemoryArgument(const Info: TInstructionInfo; Parent: TTextNode;
  var Position: Integer; Output: TBinaryWriter);
var
  Offset, Alignment: QWord;
  AlignmentExponent: Integer;
  Text: AnsiString;
begin
  Offset := 0;
  AlignmentExponent := Info.Alignment;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttKeyword) and
     (Copy(Parent[Position].Text, 1, 7) = 'offset=') then
  begin
    Text := Copy(Parent[Position].Text, 8, MaxInt);
    Offset := ParseUnsigned(Text, 32);
    Inc(Position);
  end;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttKeyword) and
     (Copy(Parent[Position].Text, 1, 6) = 'align=') then
  begin
    Text := Copy(Parent[Position].Text, 7, MaxInt);
    Alignment := ParseUnsigned(Text, 32);
    AlignmentExponent := PowerOfTwoExponent(Alignment);
    if AlignmentExponent < 0 then
      Fail(Parent[Position], 'alignment must be a power of two');
    Inc(Position);
  end;
  Output.WriteUnsigned(AlignmentExponent);
  Output.WriteUnsigned(Offset);
end;

procedure TExpressionEncoder.ParseVectorConstant(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
var
  Shape: AnsiString;
  LaneCount, LaneBytes, Lane, ByteIndex: Integer;
  Value: QWord;
  Node: TTextNode;
begin
  if Position >= Parent.Count then
    Fail(Parent, 'unexpected end: v128.const needs a shape');
  Node := Parent[Position];
  Shape := Node.Text;
  if not Node.IsAtomOf(ttKeyword) then
    Fail(Node, 'unexpected token: expected a vector shape');
  if Shape = 'i8x16' then begin LaneCount := 16; LaneBytes := 1; end
  else if Shape = 'i16x8' then begin LaneCount := 8; LaneBytes := 2; end
  else if (Shape = 'i32x4') or (Shape = 'f32x4') then begin LaneCount := 4; LaneBytes := 4; end
  else if (Shape = 'i64x2') or (Shape = 'f64x2') then begin LaneCount := 2; LaneBytes := 8; end
  else
  begin
    Fail(Node, 'unexpected token: unknown vector shape ' + Shape);
    Exit;
  end;
  Inc(Position);
  for Lane := 0 to LaneCount - 1 do
  begin
    if (Position >= Parent.Count) or not (Parent[Position].IsAtomOf(ttNumber) or
       Parent[Position].IsAtomOf(ttKeyword)) then
      Fail(Parent, 'wrong number of lane literals');
    Node := Parent[Position];
    if Shape[1] = 'f' then
    begin
      if LaneBytes = 4 then
        Value := ParseFloatBits(Node.Text, fpSingle)
      else
        Value := ParseFloatBits(Node.Text, fpDouble);
    end
    else
      Value := ParseIntegerBits(Node.Text, LaneBytes * 8);
    for ByteIndex := 0 to LaneBytes - 1 do
      Output.WriteByte(Byte((Value shr (8 * ByteIndex)) and $FF));
    Inc(Position);
  end;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttNumber) then
    Fail(Parent[Position], 'wrong number of lane literals');
end;

procedure TExpressionEncoder.ParseLane(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
begin
  if (Position >= Parent.Count) or not Parent[Position].IsAtomOf(ttNumber) then
    Fail(Parent, 'unexpected token: expected a lane index');
  Output.WriteByte(Byte(ParseUnsigned(Parent[Position].Text, 8)));
  Inc(Position);
end;

function TExpressionEncoder.ParseOptionalIndex(Space: TIndexSpace; Parent: TTextNode; var Position: Integer;
  out Index: Cardinal): Boolean;
begin
  Index := 0;
  Result := (Position < Parent.Count) and FContext.IsIndex(Parent[Position]);
  if Result then
  begin
    Index := FContext.ResolveIndex(Space, Parent[Position]);
    Inc(Position);
  end;
end;

procedure TExpressionEncoder.EncodeSimple(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer;
  Output: TBinaryWriter);
var
  Index, First, Second: Cardinal;
  Labels: array of Cardinal;
  LabelIndex: Integer;
  TypeUse: TTypeUse;
  Bits: QWord;
  Single: Cardinal;
  Types: TBytes;
  Node: TTextNode;

  function RequireIndex(Space: TIndexSpace): Cardinal;
  begin
    if Position >= Parent.Count then
      Fail(Parent, 'unexpected end: expected a ' + SpaceName(Space) + ' index');
    Result := FContext.ResolveIndex(Space, Parent[Position]);
    Inc(Position);
  end;

begin
  if Info.Immediate = ikSelect then
  begin
    Types := nil;
    while (Position < Parent.Count) and Parent[Position].IsListOf('result') do
    begin
      Node := Parent[Position];
      for LabelIndex := 1 to Node.Count - 1 do
      begin
        SetLength(Types, Length(Types) + 1);
        Types[High(Types)] := FContext.ParseValueType(Node[LabelIndex]);
      end;
      Inc(Position);
    end;
    if (Position < Parent.Count) and Parent[Position].IsListOf('param') then
      Fail(Parent[Position], 'unexpected token: select takes no parameters');
    { A written (result) list, even an empty one, makes it the typed select. }
    if (Position > 0) and Parent[Position - 1].IsListOf('result') then
    begin
      Output.WriteByte($1C);
      Output.WriteUnsigned(Length(Types));
      if Types <> nil then
        Output.WriteRaw(Types[0], Length(Types));
    end
    else
      Output.WriteByte($1B);
    Exit;
  end;
  WriteOpcode(Output, Info);
  case Info.Immediate of
    ikNone:
      ;
    ikLabel:
      begin
        if Position >= Parent.Count then
          Fail(Parent, 'unexpected end: expected a label');
        Output.WriteUnsigned(ResolveLabel(Parent[Position]));
        Inc(Position);
      end;
    ikBranchTable:
      begin
        Labels := nil;
        while (Position < Parent.Count) and FContext.IsIndex(Parent[Position]) do
        begin
          SetLength(Labels, Length(Labels) + 1);
          Labels[High(Labels)] := ResolveLabel(Parent[Position]);
          Inc(Position);
        end;
        if Labels = nil then
          Fail(Parent, 'unexpected token: br_table needs a label');
        Output.WriteUnsigned(Length(Labels) - 1);
        for LabelIndex := 0 to High(Labels) do
          Output.WriteUnsigned(Labels[LabelIndex]);
      end;
    ikFunction:
      Output.WriteUnsigned(RequireIndex(isFunction));
    ikReferenceFunction:
      Output.WriteUnsigned(RequireIndex(isFunction));
    ikCallIndirect:
      begin
        ParseOptionalIndex(isTable, Parent, Position, Index);
        TypeUse := FContext.ParseTypeUse(Parent, Position, tuInstruction);
        Output.WriteUnsigned(FContext.TypeIndexOf(TypeUse));
        Output.WriteUnsigned(Index);
      end;
    ikLocal:
      begin
        if Position >= Parent.Count then
          Fail(Parent, 'unexpected end: expected a local');
        Output.WriteUnsigned(ResolveLocal(Parent[Position]));
        Inc(Position);
      end;
    ikGlobal:
      Output.WriteUnsigned(RequireIndex(isGlobal));
    ikTable:
      begin
        ParseOptionalIndex(isTable, Parent, Position, Index);
        Output.WriteUnsigned(Index);
      end;
    ikMemoryArgument:
      ParseMemoryArgument(Info, Parent, Position, Output);
    ikMemoryLane:
      begin
        ParseMemoryArgument(Info, Parent, Position, Output);
        ParseLane(Parent, Position, Output);
      end;
    ikMemoryZero:
      Output.WriteByte(0);
    ikMemoryCopy:
      begin
        Output.WriteByte(0);
        Output.WriteByte(0);
      end;
    ikMemoryInit:
      begin
        Output.WriteUnsigned(RequireIndex(isData));
        Output.WriteByte(0);
        FContext.UsesDataIndices := True;
      end;
    ikData:
      begin
        Output.WriteUnsigned(RequireIndex(isData));
        FContext.UsesDataIndices := True;
      end;
    ikTableInit:
      begin
        if (Position + 1 < Parent.Count) and FContext.IsIndex(Parent[Position]) and
           FContext.IsIndex(Parent[Position + 1]) then
        begin
          First := RequireIndex(isTable);
          Second := RequireIndex(isElement);
        end
        else
        begin
          First := 0;
          Second := RequireIndex(isElement);
        end;
        Output.WriteUnsigned(Second);
        Output.WriteUnsigned(First);
      end;
    ikElement:
      Output.WriteUnsigned(RequireIndex(isElement));
    ikTableCopy:
      begin
        First := 0;
        Second := 0;
        if ParseOptionalIndex(isTable, Parent, Position, First) then
          Second := RequireIndex(isTable);
        Output.WriteUnsigned(First);
        Output.WriteUnsigned(Second);
      end;
    ikInt32, ikInt64, ikFloat32, ikFloat64:
      begin
        if (Position >= Parent.Count) or not (Parent[Position].IsAtomOf(ttNumber) or
           Parent[Position].IsAtomOf(ttKeyword)) then
          Fail(Parent, 'unexpected token: expected a constant');
        Node := Parent[Position];
        Inc(Position);
        case Info.Immediate of
          ikInt32:
            Output.WriteSigned(Int64(Int32(Cardinal(ParseIntegerBits(Node.Text, 32)))));
          ikInt64:
            Output.WriteSigned(Int64(ParseIntegerBits(Node.Text, 64)));
          ikFloat32:
            begin
              Single := Cardinal(ParseFloatBits(Node.Text, fpSingle));
              Output.WriteRaw(Single, 4);
            end;
          ikFloat64:
            begin
              Bits := ParseFloatBits(Node.Text, fpDouble);
              Output.WriteRaw(Bits, 8);
            end;
        end;
      end;
    ikVector:
      ParseVectorConstant(Parent, Position, Output);
    ikShuffle:
      for LabelIndex := 0 to 15 do
        ParseLane(Parent, Position, Output);
    ikLane:
      ParseLane(Parent, Position, Output);
    ikReferenceNull:
      begin
        if Position >= Parent.Count then
          Fail(Parent, 'unexpected end: expected a heap type');
        Output.WriteByte(FContext.ParseHeapType(Parent[Position]));
        Inc(Position);
      end;
  else
    Fail(Parent, 'unexpected token');
  end;
end;

procedure TExpressionEncoder.EncodePlainBlock(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer);
var
  LabelName, Closing: AnsiString;
  BlockType: TBinaryWriter;
  Start: TTextNode;
begin
  Start := Parent[Position - 1];
  LabelName := ReadOptionalLabel(Parent, Position);
  BlockType := TBinaryWriter.Create;
  try
    ParseBlockType(Parent, Position, BlockType);
    WriteOpcode(FWriter, Info);
    FWriter.WriteWriter(BlockType);
  finally
    BlockType.Free;
  end;
  PushLabel(LabelName);
  EncodeInstructions(Parent, Position, True);
  if (Position < Parent.Count) and Parent[Position].IsKeyword('else') then
  begin
    if Info.Immediate <> ikIf then
      Fail(Parent[Position], 'unexpected token: else outside if');
    Inc(Position);
    Closing := ReadOptionalLabel(Parent, Position);
    if (Closing <> '') and (Closing <> LabelName) then
      Fail(Parent[Position - 1], 'mismatching label ' + Closing);
    FWriter.WriteByte($05);
    EncodeInstructions(Parent, Position, True);
  end;
  if (Position >= Parent.Count) or not Parent[Position].IsKeyword('end') then
    Fail(Start, 'unexpected end of block: missing end');
  Inc(Position);
  Closing := ReadOptionalLabel(Parent, Position);
  if (Closing <> '') and (Closing <> LabelName) then
    Fail(Parent[Position - 1], 'mismatching label ' + Closing);
  PopLabel;
  FWriter.WriteByte($0B);
end;

procedure TExpressionEncoder.EncodeFoldedIf(Node: TTextNode);
var
  Position: Integer;
  LabelName: AnsiString;
  BlockType: TBinaryWriter;
  ThenNode, ElseNode: TTextNode;
begin
  Position := 1;
  LabelName := ReadOptionalLabel(Node, Position);
  BlockType := TBinaryWriter.Create;
  try
    ParseBlockType(Node, Position, BlockType);
    while (Position < Node.Count) and (Node[Position].Kind = tnList) and
          not Node[Position].IsListOf('then') and not Node[Position].IsListOf('else') do
    begin
      EncodeFolded(Node[Position]);
      Inc(Position);
    end;
    if (Position >= Node.Count) or not Node[Position].IsListOf('then') then
      Fail(Node, 'unexpected token: if needs (then ...)');
    ThenNode := Node[Position];
    Inc(Position);
    ElseNode := nil;
    if (Position < Node.Count) and Node[Position].IsListOf('else') then
    begin
      ElseNode := Node[Position];
      Inc(Position);
    end;
    if Position < Node.Count then
      Fail(Node[Position], 'unexpected token after if');
    FWriter.WriteByte($04);
    FWriter.WriteWriter(BlockType);
  finally
    BlockType.Free;
  end;
  PushLabel(LabelName);
  EncodeSequence(ThenNode, 1);
  if ElseNode <> nil then
  begin
    FWriter.WriteByte($05);
    EncodeSequence(ElseNode, 1);
  end;
  PopLabel;
  FWriter.WriteByte($0B);
end;

procedure TExpressionEncoder.EncodeFolded(Node: TTextNode);
var
  Info: TInstructionInfo;
  Position: Integer;
  LabelName: AnsiString;
  Immediates: TBinaryWriter;
begin
  if (Node.Kind <> tnList) or (Node.Count = 0) or not Node[0].IsAtomOf(ttKeyword) then
    Fail(Node, 'unexpected token: expected an instruction');
  if not LookUpInstruction(Node[0].Text, Info) then
    Fail(Node, 'unknown operator ' + Node[0].Text);
  case Info.Immediate of
    ikBlock, ikLoop:
      begin
        Position := 1;
        LabelName := ReadOptionalLabel(Node, Position);
        Immediates := TBinaryWriter.Create;
        try
          ParseBlockType(Node, Position, Immediates);
          WriteOpcode(FWriter, Info);
          FWriter.WriteWriter(Immediates);
        finally
          Immediates.Free;
        end;
        PushLabel(LabelName);
        EncodeInstructions(Node, Position, False);
        PopLabel;
        FWriter.WriteByte($0B);
      end;
    ikIf:
      EncodeFoldedIf(Node);
    ikElse, ikEnd:
      Fail(Node, 'unexpected token: ' + Node[0].Text);
  else
    begin
      Position := 1;
      Immediates := TBinaryWriter.Create;
      try
        EncodeSimple(Info, Node, Position, Immediates);
        while Position < Node.Count do
        begin
          if Node[Position].Kind <> tnList then
            Fail(Node[Position], 'unexpected token ' + Node[Position].Text);
          EncodeFolded(Node[Position]);
          Inc(Position);
        end;
        FWriter.WriteWriter(Immediates);
      finally
        Immediates.Free;
      end;
    end;
  end;
end;

procedure TExpressionEncoder.EncodeInstructions(Parent: TTextNode; var Position: Integer; InsidePlainBlock: Boolean);
var
  Node: TTextNode;
  Info: TInstructionInfo;
begin
  while Position < Parent.Count do
  begin
    Node := Parent[Position];
    if Node.Kind = tnList then
    begin
      EncodeFolded(Node);
      Inc(Position);
      Continue;
    end;
    if not Node.IsAtomOf(ttKeyword) then
      Fail(Node, 'unexpected token ' + Node.Text);
    if (Node.Text = 'end') or (Node.Text = 'else') then
    begin
      if InsidePlainBlock then
        Exit;
      Fail(Node, 'unexpected token ' + Node.Text);
    end;
    if not LookUpInstruction(Node.Text, Info) then
      Fail(Node, 'unknown operator ' + Node.Text);
    Inc(Position);
    if Info.Immediate in [ikBlock, ikLoop, ikIf] then
      EncodePlainBlock(Info, Parent, Position)
    else
      EncodeSimple(Info, Parent, Position, FWriter);
  end;
end;

procedure TExpressionEncoder.EncodeSequence(Parent: TTextNode; Position: Integer);
begin
  if FLabelCount = 0 then
  begin
    PushLabel('');
    EncodeInstructions(Parent, Position, False);
    PopLabel;
  end
  else
    EncodeInstructions(Parent, Position, False);
end;

procedure TExpressionEncoder.EncodeFoldedInstruction(Node: TTextNode);
begin
  PushLabel('');
  EncodeFolded(Node);
  PopLabel;
end;

end.
