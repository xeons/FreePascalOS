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
  Instructions of the text format into binary (core specification 3.0,
  section 6.5): plain instructions, whose immediates follow them as
  sibling tokens and whose blocks run to a matching "end", and folded
  instructions, written as lists with their operands nested inside,
  which are encoded operands first.

  Labels are kept on a stack of names (the function body's own label is
  the bottom one), so br $name becomes the depth of the innermost block
  with that name; locals come from the function's parameter and local
  identifiers. Every other index goes through the module context.

  Structured instructions: block, loop, if/else, try_table and the
  legacy try. A try_table's catch clauses, "(catch x l)", "(catch_ref x
  l)", "(catch_all l)" and "(catch_all_ref l)", come after its block type
  and name labels outside it: they are resolved before its own label is
  pushed. A legacy try is "try bt instr* (catch x instr*)* (catch_all
  instr*)? end" (its handlers see its label) or "try bt instr* delegate
  l" (l resolved once the try's label is popped); folded it is
  "(try bt (do instr*) (catch x instr*)* (catch_all instr*)?)" or
  "(try bt (do instr*) (delegate l))".
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
  WasmText.Types,
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
    procedure ReadClosingLabel(Parent: TTextNode; var Position: Integer; const LabelName: AnsiString);
    procedure WriteOpcode(Output: TBinaryWriter; const Info: TInstructionInfo);
    procedure ParseBlockType(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    procedure ParseCatchClauses(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    { The opcode, label (when written) and block type of a structured
      instruction, read from Parent's children at Position on. }
    function ParseBlockHeader(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer): AnsiString;
    function ParseOptionalIndex(Space: TIndexSpace; Parent: TTextNode; var Position: Integer;
      out Index: Cardinal): Boolean;
    procedure EncodeReferenceTest(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer;
      Output: TBinaryWriter);
    procedure EncodeBranchCast(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
    { Writes the opcode and the immediates read from Parent's children
      at Position on (all but structured instructions). }
    procedure EncodeSimple(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer;
      Output: TBinaryWriter);
    procedure EncodePlainHandlers(Parent: TTextNode; var Position: Integer; const LabelName: AnsiString);
    procedure EncodePlainBlock(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer);
    procedure EncodeFolded(Node: TTextNode);
    procedure EncodeFoldedIf(Node: TTextNode);
    procedure EncodeFoldedTry(Node: TTextNode);
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
  WasmText.Numbers,
  WasmText.Immediates;

const
  OpcodeElse = $05;
  OpcodeEnd = $0B;
  OpcodeCatch = $07;
  OpcodeCatchAll = $19;
  OpcodeDelegate = $18;
  OpcodeSelect = $1B;
  OpcodeSelectTyped = $1C;
  BlockTypeEmpty = $40;

  CatchClauseTag = 0;
  CatchClauseTagReference = 1;
  CatchClauseAll = 2;
  CatchClauseAllReference = 3;

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

procedure TExpressionEncoder.ReadClosingLabel(Parent: TTextNode; var Position: Integer; const LabelName: AnsiString);
var
  Closing: AnsiString;
begin
  Closing := ReadOptionalLabel(Parent, Position);
  if (Closing <> '') and (Closing <> LabelName) then
    Fail(Parent[Position - 1], 'mismatching label ' + Closing);
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
      Output.WriteByte(BlockTypeEmpty)
    else
      WriteValueType(Output, TypeUse.Results[0]);
  end
  else
    Output.WriteSigned(FContext.TypeIndexOf(TypeUse));
end;

procedure TExpressionEncoder.ParseCatchClauses(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
var
  Clauses: TBinaryWriter;
  Count: Cardinal;
  Node: TTextNode;
  Head: AnsiString;
  WithTag: Boolean;
begin
  Clauses := TBinaryWriter.Create;
  try
    Count := 0;
    while Position < Parent.Count do
    begin
      Node := Parent[Position];
      Head := Node.Head;
      if (Head <> 'catch') and (Head <> 'catch_ref') and (Head <> 'catch_all') and (Head <> 'catch_all_ref') then
        Break;
      WithTag := (Head = 'catch') or (Head = 'catch_ref');
      if (WithTag and (Node.Count <> 3)) or (not WithTag and (Node.Count <> 2)) then
        Fail(Node, 'unexpected token in catch clause');
      if Head = 'catch' then Clauses.WriteByte(CatchClauseTag)
      else if Head = 'catch_ref' then Clauses.WriteByte(CatchClauseTagReference)
      else if Head = 'catch_all' then Clauses.WriteByte(CatchClauseAll)
      else Clauses.WriteByte(CatchClauseAllReference);
      if WithTag then
        Clauses.WriteUnsigned(FContext.ResolveIndex(isTag, Node[1]));
      Clauses.WriteUnsigned(ResolveLabel(Node[Node.Count - 1]));
      Inc(Count);
      Inc(Position);
    end;
    Output.WriteUnsigned(Count);
    Output.WriteWriter(Clauses);
  finally
    Clauses.Free;
  end;
end;

function TExpressionEncoder.ParseBlockHeader(const Info: TInstructionInfo; Parent: TTextNode;
  var Position: Integer): AnsiString;
var
  Header: TBinaryWriter;
begin
  Result := ReadOptionalLabel(Parent, Position);
  Header := TBinaryWriter.Create;
  try
    ParseBlockType(Parent, Position, Header);
    if Info.Immediate = ikTryTable then
      ParseCatchClauses(Parent, Position, Header);
    WriteOpcode(FWriter, Info);
    FWriter.WriteWriter(Header);
  finally
    Header.Free;
  end;
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

procedure TExpressionEncoder.EncodeReferenceTest(const Info: TInstructionInfo; Parent: TTextNode;
  var Position: Integer; Output: TBinaryWriter);
var
  Nullable: Boolean;
  HeapType: TValueType;
begin
  if Position >= Parent.Count then
    Fail(Parent, 'unexpected end: expected a reference type');
  SplitReferenceType(FContext.ParseReferenceType(Parent[Position]), Nullable, HeapType);
  Inc(Position);
  Output.WriteByte(Info.Prefix);
  Output.WriteUnsigned(Info.Code + Cardinal(Ord(Nullable)));
  WriteValueType(Output, HeapType);
end;

procedure TExpressionEncoder.EncodeBranchCast(Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
var
  LabelIndex: Cardinal;
  Nullable: array[0..1] of Boolean;
  HeapTypes: array[0..1] of TValueType;
  Index: Integer;
begin
  if Position + 2 >= Parent.Count then
    Fail(Parent, 'unexpected end: expected a label and two reference types');
  LabelIndex := ResolveLabel(Parent[Position]);
  Inc(Position);
  for Index := 0 to 1 do
  begin
    SplitReferenceType(FContext.ParseReferenceType(Parent[Position]), Nullable[Index], HeapTypes[Index]);
    Inc(Position);
  end;
  Output.WriteByte(Ord(Nullable[0]) or (Ord(Nullable[1]) shl 1));
  Output.WriteUnsigned(LabelIndex);
  WriteValueType(Output, HeapTypes[0]);
  WriteValueType(Output, HeapTypes[1]);
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
  Types: TValueTypeArray;
  Node: TTextNode;

  function RequireIndex(Space: TIndexSpace): Cardinal;
  begin
    if Position >= Parent.Count then
      Fail(Parent, 'unexpected end: expected a ' + SpaceName(Space) + ' index');
    Result := FContext.ResolveIndex(Space, Parent[Position]);
    Inc(Position);
  end;

  function RequireNumber: Cardinal;
  begin
    if (Position >= Parent.Count) or not Parent[Position].IsAtomOf(ttNumber) then
      Fail(Parent, 'unexpected token: expected a number');
    Result := Cardinal(ParseUnsigned(Parent[Position].Text, 32));
    Inc(Position);
  end;

begin
  case Info.Immediate of
    ikSelect:
      begin
        Types := nil;
        while (Position < Parent.Count) and Parent[Position].IsListOf('result') do
        begin
          Node := Parent[Position];
          for LabelIndex := 1 to Node.Count - 1 do
            AppendValueType(Types, FContext.ParseValueType(Node[LabelIndex]));
          Inc(Position);
        end;
        if (Position < Parent.Count) and Parent[Position].IsListOf('param') then
          Fail(Parent[Position], 'unexpected token: select takes no parameters');
        { A written (result) list, even an empty one, makes it the typed select. }
        if (Position > 0) and Parent[Position - 1].IsListOf('result') then
        begin
          Output.WriteByte(OpcodeSelectTyped);
          WriteValueTypes(Output, Types);
        end
        else
          Output.WriteByte(OpcodeSelect);
        Exit;
      end;
    ikReferenceTest:
      begin
        EncodeReferenceTest(Info, Parent, Position, Output);
        Exit;
      end;
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
    ikFunction, ikReferenceFunction:
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
      ParseMemoryArgument(FContext, Info.Alignment, False, Parent, Position, Output);
    ikMemoryLane:
      begin
        ParseMemoryArgument(FContext, Info.Alignment, True, Parent, Position, Output);
        ParseLane(FContext, Parent, Position, Output);
      end;
    ikMemoryIndex:
      begin
        ParseOptionalIndex(isMemory, Parent, Position, Index);
        Output.WriteUnsigned(Index);
      end;
    ikMemoryCopy:
      begin
        First := 0;
        Second := 0;
        if ParseOptionalIndex(isMemory, Parent, Position, First) then
          Second := RequireIndex(isMemory);
        Output.WriteUnsigned(First);
        Output.WriteUnsigned(Second);
      end;
    ikMemoryInit:
      begin
        First := 0;
        if (Position + 1 < Parent.Count) and FContext.IsIndex(Parent[Position]) and
           FContext.IsIndex(Parent[Position + 1]) then
          First := RequireIndex(isMemory);
        Output.WriteUnsigned(RequireIndex(isData));
        Output.WriteUnsigned(First);
        FContext.UsesDataIndices := True;
      end;
    ikData:
      begin
        Output.WriteUnsigned(RequireIndex(isData));
        FContext.UsesDataIndices := True;
      end;
    ikTableInit:
      begin
        First := 0;
        if (Position + 1 < Parent.Count) and FContext.IsIndex(Parent[Position]) and
           FContext.IsIndex(Parent[Position + 1]) then
          First := RequireIndex(isTable);
        Second := RequireIndex(isElement);
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
      ParseVectorConstant(FContext, Parent, Position, Output);
    ikShuffle:
      for LabelIndex := 0 to 15 do
        ParseLane(FContext, Parent, Position, Output);
    ikLane:
      ParseLane(FContext, Parent, Position, Output);
    ikReferenceNull:
      begin
        if Position >= Parent.Count then
          Fail(Parent, 'unexpected end: expected a heap type');
        WriteValueType(Output, FContext.ParseHeapType(Parent[Position]));
        Inc(Position);
      end;
    ikTag:
      Output.WriteUnsigned(RequireIndex(isTag));
    ikType:
      Output.WriteUnsigned(RequireIndex(isType));
    ikTypeField:
      begin
        Index := RequireIndex(isType);
        Output.WriteUnsigned(Index);
        if Position >= Parent.Count then
          Fail(Parent, 'unexpected end: expected a field');
        Output.WriteUnsigned(FContext.ResolveField(Index, Parent[Position]));
        Inc(Position);
      end;
    ikTypeCount:
      begin
        Output.WriteUnsigned(RequireIndex(isType));
        Output.WriteUnsigned(RequireNumber);
      end;
    ikTypeData:
      begin
        Output.WriteUnsigned(RequireIndex(isType));
        Output.WriteUnsigned(RequireIndex(isData));
        FContext.UsesDataIndices := True;
      end;
    ikTypeElement:
      begin
        Output.WriteUnsigned(RequireIndex(isType));
        Output.WriteUnsigned(RequireIndex(isElement));
      end;
    ikTypeType:
      begin
        Output.WriteUnsigned(RequireIndex(isType));
        Output.WriteUnsigned(RequireIndex(isType));
      end;
    ikBranchCast:
      EncodeBranchCast(Parent, Position, Output);
  else
    Fail(Parent, 'unexpected token');
  end;
end;

{ The handlers of a plain legacy try, after its body: catch clauses and
  catch_all; the caller then expects end. }
procedure TExpressionEncoder.EncodePlainHandlers(Parent: TTextNode; var Position: Integer; const LabelName: AnsiString);
var
  SeenCatchAll: Boolean;
begin
  SeenCatchAll := False;
  while (Position < Parent.Count) and (Parent[Position].IsKeyword('catch') or
        Parent[Position].IsKeyword('catch_all')) do
  begin
    if SeenCatchAll then
      Fail(Parent[Position], 'unexpected token: handler after catch_all');
    if Parent[Position].IsKeyword('catch') then
    begin
      Inc(Position);
      if Position >= Parent.Count then
        Fail(Parent, 'unexpected end: expected a tag index');
      FWriter.WriteByte(OpcodeCatch);
      FWriter.WriteUnsigned(FContext.ResolveIndex(isTag, Parent[Position]));
      Inc(Position);
    end
    else
    begin
      Inc(Position);
      ReadClosingLabel(Parent, Position, LabelName);
      SeenCatchAll := True;
      FWriter.WriteByte(OpcodeCatchAll);
    end;
    EncodeInstructions(Parent, Position, True);
  end;
end;

procedure TExpressionEncoder.EncodePlainBlock(const Info: TInstructionInfo; Parent: TTextNode; var Position: Integer);
var
  LabelName: AnsiString;
  Start: TTextNode;
begin
  Start := Parent[Position - 1];
  LabelName := ParseBlockHeader(Info, Parent, Position);
  PushLabel(LabelName);
  EncodeInstructions(Parent, Position, True);
  if (Info.Immediate = ikIf) and (Position < Parent.Count) and Parent[Position].IsKeyword('else') then
  begin
    Inc(Position);
    ReadClosingLabel(Parent, Position, LabelName);
    FWriter.WriteByte(OpcodeElse);
    EncodeInstructions(Parent, Position, True);
  end;
  if Info.Immediate = ikTry then
  begin
    if (Position < Parent.Count) and Parent[Position].IsKeyword('delegate') then
    begin
      Inc(Position);
      PopLabel;
      if Position >= Parent.Count then
        Fail(Parent, 'unexpected end: expected a label');
      FWriter.WriteByte(OpcodeDelegate);
      FWriter.WriteUnsigned(ResolveLabel(Parent[Position]));
      Inc(Position);
      Exit;
    end;
    EncodePlainHandlers(Parent, Position, LabelName);
  end;
  if (Position >= Parent.Count) or not Parent[Position].IsKeyword('end') then
  begin
    if Position < Parent.Count then
      Fail(Parent[Position], 'unexpected token ' + Parent[Position].Text);
    Fail(Start, 'unexpected end of block: missing end');
  end;
  Inc(Position);
  ReadClosingLabel(Parent, Position, LabelName);
  PopLabel;
  FWriter.WriteByte(OpcodeEnd);
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
    FWriter.WriteByte(OpcodeElse);
    EncodeSequence(ElseNode, 1);
  end;
  PopLabel;
  FWriter.WriteByte(OpcodeEnd);
end;

procedure TExpressionEncoder.EncodeFoldedTry(Node: TTextNode);
var
  Position, BodyPosition: Integer;
  Info: TInstructionInfo;
  Handler: TTextNode;
  SeenCatchAll: Boolean;
begin
  LookUpInstruction('try', Info);
  Position := 1;
  PushLabel(ParseBlockHeader(Info, Node, Position));
  if (Position >= Node.Count) or not Node[Position].IsListOf('do') then
    Fail(Node, 'unexpected token: try needs (do ...)');
  BodyPosition := 1;
  EncodeInstructions(Node[Position], BodyPosition, False);
  Inc(Position);
  if (Position < Node.Count) and Node[Position].IsListOf('delegate') then
  begin
    Handler := Node[Position];
    if Handler.Count <> 2 then
      Fail(Handler, 'unexpected token in delegate');
    PopLabel;
    FWriter.WriteByte(OpcodeDelegate);
    FWriter.WriteUnsigned(ResolveLabel(Handler[1]));
    if Position + 1 < Node.Count then
      Fail(Node[Position + 1], 'unexpected token after delegate');
    Exit;
  end;
  SeenCatchAll := False;
  while (Position < Node.Count) and (Node[Position].IsListOf('catch') or Node[Position].IsListOf('catch_all')) do
  begin
    Handler := Node[Position];
    if SeenCatchAll then
      Fail(Handler, 'unexpected token: handler after catch_all');
    BodyPosition := 1;
    if Handler.IsListOf('catch') then
    begin
      if Handler.Count < 2 then
        Fail(Handler, 'unexpected end: expected a tag index');
      FWriter.WriteByte(OpcodeCatch);
      FWriter.WriteUnsigned(FContext.ResolveIndex(isTag, Handler[1]));
      BodyPosition := 2;
    end
    else
    begin
      SeenCatchAll := True;
      FWriter.WriteByte(OpcodeCatchAll);
    end;
    EncodeInstructions(Handler, BodyPosition, False);
    Inc(Position);
  end;
  if Position < Node.Count then
    Fail(Node[Position], 'unexpected token in try');
  PopLabel;
  FWriter.WriteByte(OpcodeEnd);
end;

procedure TExpressionEncoder.EncodeFolded(Node: TTextNode);
var
  Info: TInstructionInfo;
  Position: Integer;
  Immediates: TBinaryWriter;
begin
  if (Node.Kind <> tnList) or (Node.Count = 0) or not Node[0].IsAtomOf(ttKeyword) then
    Fail(Node, 'unexpected token: expected an instruction');
  if not LookUpInstruction(Node[0].Text, Info) then
    Fail(Node, 'unknown operator ' + Node[0].Text);
  case Info.Immediate of
    ikBlock, ikLoop, ikTryTable:
      begin
        Position := 1;
        PushLabel(ParseBlockHeader(Info, Node, Position));
        EncodeInstructions(Node, Position, False);
        PopLabel;
        FWriter.WriteByte(OpcodeEnd);
      end;
    ikIf:
      EncodeFoldedIf(Node);
    ikTry:
      EncodeFoldedTry(Node);
    ikElse, ikEnd, ikCatch, ikCatchAll, ikDelegate:
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
    if not LookUpInstruction(Node.Text, Info) then
      Fail(Node, 'unknown operator ' + Node.Text);
    if Info.Immediate in [ikEnd, ikElse, ikCatch, ikCatchAll, ikDelegate] then
    begin
      if InsidePlainBlock then
        Exit;
      Fail(Node, 'unexpected token ' + Node.Text);
    end;
    Inc(Position);
    if Info.Immediate in [ikBlock, ikLoop, ikIf, ikTryTable, ikTry] then
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
