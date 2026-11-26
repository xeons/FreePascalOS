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
  Compiles validated function bodies into the slot code of Wasm.Code.

  One pass over the instructions with the bookkeeping of
  Wasm.CodeEmitter. Code after an unconditional branch up to the end of
  its block cannot run and is skipped. A branch moves the values it
  carries to the target block's slots when they are elsewhere; a
  br_table entry that needs such moves goes to a small stub after the
  table that does them.

  Small fusions save dispatches in hot loops: a comparison followed by
  br_if (or by if) becomes one compare-and-branch, an i32 operation with
  a constant operand becomes an operation with an immediate, and a
  result stored with local.set or local.tee is written to the local
  directly.
}
unit Wasm.Compiler;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Module;

{ Compiles every function body of a validated module. }
procedure CompileModule(Module: TWasmModule);

implementation

uses
  SysUtils,
  Wasm.Types,
  Wasm.Opcodes,
  Wasm.Instructions,
  Wasm.Code,
  Wasm.CodeEmitter,
  Wasm.CodeValidator;

type
  TFunctionCompiler = class(TCodeEmitter)
  private
    procedure BlockTypes(const BlockType: TWasmBlockType; out ParamTypes, ResultTypes: TWasmValueTypeArray);
    function LabelTypes(const Frame: TCompileFrame): TWasmValueTypeArray;
    procedure EmitMoves(Destination, Source, Count: Int32);
    function NeedsMoves(Depth: Cardinal; out Destination, Source, Count: Int32): Boolean;
    procedure EmitBranchTo(Depth: Cardinal);
    procedure EmitConditionalBranch(Depth: Cardinal; Condition: TCompileOperand);
    procedure CompileIf(const Instruction: TWasmInstruction);
    procedure CompileElse;
    procedure CompileEnd;
    procedure CompileBranchTable(const Instruction: TWasmInstruction; const Labels: array of Cardinal);
    procedure CompileReturn;
    procedure CompileCall(FunctionIndex: Cardinal);
    procedure CompileCallIndirect(TypeIndex, TableIndex: Cardinal);
    procedure CompileLocalSet(LocalIndex: Cardinal; Tee: Boolean);
    procedure CompileSelect;
    procedure CompileSimple(const Instruction: TWasmInstruction);
    procedure CompileAtHome(Operation: Integer; OperandCount: Integer; B, C: Int32; Extra: Integer;
      const ResultType: TWasmValueType; HasResult: Boolean);
    procedure CompileInstruction(const Instruction: TWasmInstruction; const Labels: array of Cardinal);
    procedure SkipDeadInstruction(const Instruction: TWasmInstruction; var DeadDepth: Integer;
      const Labels: array of Cardinal);
  public
    function Compile(DefinedIndex: Cardinal): TCompiledFunction;
  end;

function ImmediateForm(Operation: Integer): Integer;
begin
  case Operation of
    OpI32Add: Result := CodeI32AddImmediate;
    OpI32Sub: Result := CodeI32AddImmediate;
    OpI32And: Result := CodeI32AndImmediate;
    OpI32Or: Result := CodeI32OrImmediate;
    OpI32Xor: Result := CodeI32XorImmediate;
    OpI32Shl: Result := CodeI32ShlImmediate;
    OpI32ShrS: Result := CodeI32ShrSImmediate;
    OpI32ShrU: Result := CodeI32ShrUImmediate;
    OpI32Mul: Result := CodeI32MulImmediate;
    OpI32Eq: Result := CodeI32EqImmediate;
    OpI32Ne: Result := CodeI32NeImmediate;
    OpI32LtS: Result := CodeI32LtSImmediate;
    OpI32LtU: Result := CodeI32LtUImmediate;
    OpI32GtS: Result := CodeI32GtSImmediate;
    OpI32GtU: Result := CodeI32GtUImmediate;
    OpI32LeS: Result := CodeI32LeSImmediate;
    OpI32LeU: Result := CodeI32LeUImmediate;
    OpI32GeS: Result := CodeI32GeSImmediate;
    OpI32GeU: Result := CodeI32GeUImmediate;
    OpI64Add: Result := CodeI64AddImmediate;
    OpI64Sub: Result := CodeI64AddImmediate;
    OpI64And: Result := CodeI64AndImmediate;
    OpI64Shl: Result := CodeI64ShlImmediate;
    OpI64ShrU: Result := CodeI64ShrUImmediate;
    OpI64ShrS: Result := CodeI64ShrSImmediate;
  else
    Result := -1;
  end;
end;

{ The compare-and-branch for a comparison; Negated for "branch unless". }
function FusedBranch(Operation: Integer; Negated: Boolean): Integer;
const
  Plain: array[OpI32Eq..OpI32GeU] of Integer = (CodeBranchIfI32Eq, CodeBranchIfI32Ne,
    CodeBranchIfI32LtS, CodeBranchIfI32LtU, CodeBranchIfI32GtS, CodeBranchIfI32GtU,
    CodeBranchIfI32LeS, CodeBranchIfI32LeU, CodeBranchIfI32GeS, CodeBranchIfI32GeU);
  Inverse: array[OpI32Eq..OpI32GeU] of Integer = (CodeBranchIfI32Ne, CodeBranchIfI32Eq,
    CodeBranchIfI32GeS, CodeBranchIfI32GeU, CodeBranchIfI32LeS, CodeBranchIfI32LeU,
    CodeBranchIfI32GtS, CodeBranchIfI32GtU, CodeBranchIfI32LtS, CodeBranchIfI32LtU);
begin
  if Operation = OpI32Eqz then
  begin
    if Negated then
      Result := CodeBranchIf
    else
      Result := CodeBranchIfI32Eqz;
  end
  else if (Operation >= OpI32Eq) and (Operation <= OpI32GeU) then
  begin
    if Negated then
      Result := Inverse[Operation]
    else
      Result := Plain[Operation];
  end
  else
    Result := -1;
end;

procedure TFunctionCompiler.BlockTypes(const BlockType: TWasmBlockType;
  out ParamTypes, ResultTypes: TWasmValueTypeArray);
begin
  ParamTypes := nil;
  ResultTypes := nil;
  case BlockType.Kind of
    btEmpty: ;
    btValue:
      begin
        SetLength(ResultTypes, 1);
        ResultTypes[0] := BlockType.ValueType;
      end;
    btTypeIndex:
      begin
        ParamTypes := FModule.Types[BlockType.TypeIndex].Params;
        ResultTypes := FModule.Types[BlockType.TypeIndex].Results;
      end;
  end;
end;

function TFunctionCompiler.LabelTypes(const Frame: TCompileFrame): TWasmValueTypeArray;
begin
  if Frame.Kind = cfLoop then
    Result := Frame.ParamTypes
  else
    Result := Frame.ResultTypes;
end;

procedure TFunctionCompiler.EmitMoves(Destination, Source, Count: Int32);
begin
  if Count = 1 then
    Emit(CodeCopy, Destination, Source)
  else
    Emit(CodeCopyRange, Destination, Source, Count);
end;

{ The values a branch to Depth carries are the top operands (at home);
  they go to the target's slots. }
function TFunctionCompiler.NeedsMoves(Depth: Cardinal; out Destination, Source, Count: Int32): Boolean;
var
  Frame: Integer;
begin
  Frame := CurrentFrame - Integer(Depth);
  Count := SlotCountOf(LabelTypes(FFrames[Frame]));
  Destination := FFrames[Frame].SlotHeight;
  Source := FNextHome - Count;
  Result := (Count > 0) and (Destination <> Source);
end;

procedure TFunctionCompiler.EmitBranchTo(Depth: Cardinal);
var
  Frame, Index: Integer;
  Destination, Source, Count: Int32;
begin
  Frame := CurrentFrame - Integer(Depth);
  if NeedsMoves(Depth, Destination, Source, Count) then
    EmitMoves(Destination, Source, Count);
  if FFrames[Frame].Kind = cfLoop then
  begin
    Index := Emit(CodeBranch, FFrames[Frame].LoopStart, 0, 0, 1);
    RecordSafepoint(Index, FOperandCount);
  end
  else if FFrames[Frame].Kind = cfFunction then
    Emit(CodeReturn, FNextHome - SlotCountOf(FFrames[Frame].ResultTypes), SlotCountOf(FFrames[Frame].ResultTypes))
  else
  begin
    Index := Emit(CodeBranch);
    AddFixup(FFrames[Frame], Index * 2);
  end;
end;

{ A branch taken when Condition (popped already) is not zero. }
procedure TFunctionCompiler.EmitConditionalBranch(Depth: Cardinal; Condition: TCompileOperand);
var
  Frame, Index, Skip, Fused: Integer;
  Destination, Source, Count: Int32;
  Compare: TCodeInstruction;
  IsLoop: Boolean;
begin
  Frame := CurrentFrame - Integer(Depth);
  IsLoop := FFrames[Frame].Kind = cfLoop;
  if NeedsMoves(Depth, Destination, Source, Count) or (FFrames[Frame].Kind = cfFunction) then
  begin
    Source := SourceOf(Condition);
    MaterializeAll;
    Skip := Emit(CodeBranchUnless, 0, Source);
    EmitBranchTo(Depth);
    FInstructions[Skip].A := FCount;
    Exit;
  end;
  Fused := -1;
  if (FLastResult = FCount - 1) and (FLastResult >= 0) and not Condition.IsConstant and
    (Condition.Source = Condition.Home) and (FInstructions[FLastResult].A = Condition.Home) then
    Fused := FusedBranch(FInstructions[FLastResult].Operation, False);
  if Fused >= 0 then
  begin
    Compare := FInstructions[FLastResult];
    RemoveLastInstruction;
    MaterializeAll;
    Index := Emit(Fused, 0, Compare.B, Compare.C, Ord(IsLoop));
  end
  else
  begin
    Source := SourceOf(Condition);
    MaterializeAll;
    Index := Emit(CodeBranchIf, 0, Source, 0, Ord(IsLoop));
  end;
  if IsLoop then
  begin
    FInstructions[Index].A := FFrames[Frame].LoopStart;
    RecordSafepoint(Index, FOperandCount);
  end
  else
    AddFixup(FFrames[Frame], Index * 2);
end;

procedure TFunctionCompiler.CompileIf(const Instruction: TWasmInstruction);
var
  ParamTypes, ResultTypes: TWasmValueTypeArray;
  Condition: TCompileOperand;
  Fused, Index: Integer;
  Compare: TCodeInstruction;
begin
  BlockTypes(Instruction.BlockType, ParamTypes, ResultTypes);
  Condition := PopOperand;
  Fused := -1;
  if (FLastResult = FCount - 1) and (FLastResult >= 0) and not Condition.IsConstant and
    (Condition.Source = Condition.Home) and (FInstructions[FLastResult].A = Condition.Home) then
    Fused := FusedBranch(FInstructions[FLastResult].Operation, True);
  if Fused >= 0 then
  begin
    Compare := FInstructions[FLastResult];
    RemoveLastInstruction;
    MaterializeAll;
    Index := Emit(Fused, 0, Compare.B, Compare.C);
  end
  else
  begin
    Index := SourceOf(Condition);
    MaterializeAll;
    Index := Emit(CodeBranchUnless, 0, Index);
  end;
  PushFrame(cfIf, ParamTypes, ResultTypes);
  FFrames[CurrentFrame].IfBranch := Index;
end;

procedure TFunctionCompiler.CompileElse;
var
  Index: Integer;
begin
  with FFrames[CurrentFrame] do
  begin
    if not Unreachable then
    begin
      MaterializeAll;
      Index := Emit(CodeBranch);
      AddFixup(FFrames[CurrentFrame], Index * 2);
    end;
    FInstructions[IfBranch].A := FCount;
    IfBranch := -1;
    Kind := cfElse;
    Unreachable := False;
    ResetOperands(OperandHeight, ParamTypes);
  end;
  FLastResult := -1;
end;

procedure TFunctionCompiler.CompileEnd;
var
  Frame: Integer;
begin
  Frame := CurrentFrame;
  if not FFrames[Frame].Unreachable then
    MaterializeAll;
  if FFrames[Frame].Kind = cfFunction then
  begin
    if not FFrames[Frame].Unreachable then
      Emit(CodeReturn, FNextHome - SlotCountOf(FFrames[Frame].ResultTypes), SlotCountOf(FFrames[Frame].ResultTypes));
    Dec(FFrameCount);
    Exit;
  end;
  if FFrames[Frame].IfBranch >= 0 then
    FInstructions[FFrames[Frame].IfBranch].A := FCount;
  BindFixups(FFrames[Frame], FCount);
  ResetOperands(FFrames[Frame].OperandHeight, FFrames[Frame].ResultTypes);
  Dec(FFrameCount);
  FLastResult := -1;
end;

procedure TFunctionCompiler.CompileBranchTable(const Instruction: TWasmInstruction;
  const Labels: array of Cardinal);
var
  IndexOperand: TCompileOperand;
  IndexSlot, Destination, Source, Count: Int32;
  Entry, Start, Frame, Instruction_, Stub: Integer;
  Depths: array of Cardinal;
  StubFor: array of Integer;
begin
  IndexOperand := PopOperand;
  IndexSlot := SourceOf(IndexOperand);
  MaterializeAll;
  SetLength(Depths, Instruction.LabelCount + 1);
  for Entry := 0 to Integer(Instruction.LabelCount) - 1 do
    Depths[Entry] := Labels[Entry];
  Depths[Instruction.LabelCount] := Instruction.Index;
  Start := FBranchTargetCount;
  for Entry := 0 to High(Depths) do
    AddBranchTarget(0);
  Instruction_ := Emit(CodeBranchTable, IndexSlot, Start, Instruction.LabelCount);
  RecordSafepoint(Instruction_, FOperandCount);
  { Entries straight to their target, or to a stub (one per depth) that
    moves the values or returns. }
  SetLength(StubFor, FFrameCount);
  for Frame := 0 to High(StubFor) do
    StubFor[Frame] := -1;
  for Entry := 0 to High(Depths) do
  begin
    Frame := CurrentFrame - Integer(Depths[Entry]);
    if NeedsMoves(Depths[Entry], Destination, Source, Count) or (FFrames[Frame].Kind in [cfLoop, cfFunction]) then
    begin
      Stub := StubFor[Frame];
      if Stub < 0 then
      begin
        Stub := FCount;
        StubFor[Frame] := Stub;
        EmitBranchTo(Depths[Entry]);
      end;
      FBranchTargets[Start + Entry] := Stub;
    end
    else
      AddFixup(FFrames[Frame], (Start + Entry) * 2 + 1);
  end;
  MarkUnreachable;
end;

procedure TFunctionCompiler.CompileReturn;
begin
  MaterializeAll;
  Emit(CodeReturn, FNextHome - SlotCountOf(FFrames[0].ResultTypes), SlotCountOf(FFrames[0].ResultTypes));
  MarkUnreachable;
end;

procedure TFunctionCompiler.CompileCall(FunctionIndex: Cardinal);
var
  FunctionType: TWasmFunctionType;
  Index, ArgumentBase: Integer;
begin
  FunctionType := FModule.FunctionType(FunctionIndex);
  MaterializeAll;
  for Index := 1 to Length(FunctionType.Params) do
    PopOperand;
  ArgumentBase := FNextHome;
  Index := Emit(CodeCall, FunctionIndex, ArgumentBase);
  RecordSafepoint(Index, FOperandCount);
  for Index := 0 to High(FunctionType.Results) do
    PushOperand(FunctionType.Results[Index]);
end;

procedure TFunctionCompiler.CompileCallIndirect(TypeIndex, TableIndex: Cardinal);
var
  FunctionType: TWasmFunctionType;
  Index, ArgumentBase: Integer;
begin
  FunctionType := FModule.Types[TypeIndex];
  MaterializeAll;
  PopOperand;
  for Index := 1 to Length(FunctionType.Params) do
    PopOperand;
  ArgumentBase := FNextHome;
  Index := Emit(CodeCallIndirect, TypeIndex, ArgumentBase, TableIndex, SlotCountOf(FunctionType.Params));
  RecordSafepoint(Index, FOperandCount);
  for Index := 0 to High(FunctionType.Results) do
    PushOperand(FunctionType.Results[Index]);
end;

procedure TFunctionCompiler.CompileLocalSet(LocalIndex: Cardinal; Tee: Boolean);
var
  Slot: Int32;
  Value: TCompileOperand;
  Index: Integer;
  OthersRead: Boolean;
begin
  Slot := FLocalSlots[LocalIndex];
  Value := TopOperand;
  OthersRead := False;
  for Index := 0 to FOperandCount - 2 do
    if not FOperands[Index].IsConstant and (FOperands[Index].Source = Slot) then
      OthersRead := True;
  if (not OthersRead) and (FLastResult >= 0) and not Value.IsConstant and (Value.Source = Value.Home) and
    (FInstructions[FLastResult].A = Value.Home) then
  begin
    FInstructions[FLastResult].A := Slot;
    PopOperand;
  end
  else
  begin
    PopOperand;
    MaterializeLocalReaders(Slot);
    if Value.IsConstant then
    begin
      if Value.ValueType.Kind in [vkI32, vkF32] then
        Emit(CodeConst32, Slot, Int32(Value.Constant))
      else
        Emit(CodeConst64, Slot, Int32(Value.Constant and $FFFFFFFF), Int32(Value.Constant shr 32));
    end
    else if Value.Source <> Slot then
    begin
      if Value.ValueType.Kind = vkV128 then
        Emit(CodeCopy128, Slot, Value.Source)
      else
        Emit(CodeCopy, Slot, Value.Source);
    end;
  end;
  FLastResult := -1;
  if Tee then
    PushLocal(LocalIndex);
end;

procedure TFunctionCompiler.CompileSelect;
var
  Condition, Second, First: TCompileOperand;
  ConditionSlot, SecondSlot, FirstSlot, Destination: Int32;
  IsVector: Boolean;
begin
  Condition := PopOperand;
  Second := PopOperand;
  First := PopOperand;
  IsVector := First.ValueType.Kind = vkV128;
  ConditionSlot := SourceOf(Condition);
  SecondSlot := SourceOf(Second);
  FirstSlot := SourceOf(First);
  Destination := PushOperand(First.ValueType);
  if ConditionSlot <= $FFFF then
  begin
    if IsVector then
      EmitResult(CodeSelect128, Destination, FirstSlot, SecondSlot, ConditionSlot)
    else
      EmitResult(CodeSelect, Destination, FirstSlot, SecondSlot, ConditionSlot);
    Exit;
  end;
  { A frame too large for the condition's slot in Extra: everything at
    home (first, second, condition in a row). }
  PopOperand;
  PushOperand(First.ValueType);
  FOperands[FOperandCount - 1].Source := FirstSlot;
  Materialize(FOperandCount - 1);
  PushOperand(Second.ValueType);
  FOperands[FOperandCount - 1].Source := SecondSlot;
  Materialize(FOperandCount - 1);
  PushOperand(WasmI32Type);
  FOperands[FOperandCount - 1].Source := ConditionSlot;
  Materialize(FOperandCount - 1);
  PopOperand;
  PopOperand;
  if IsVector then
    Emit(CodeSelect128AtHome, Destination)
  else
    Emit(CodeSelectAtHome, Destination);
end;

{ An operation with its operands at home in a row from A (the top
  OperandCount operands) and its result, if any, at A too. }
procedure TFunctionCompiler.CompileAtHome(Operation: Integer; OperandCount: Integer; B, C: Int32; Extra: Integer;
  const ResultType: TWasmValueType; HasResult: Boolean);
var
  Index: Integer;
  Base: Int32;
begin
  for Index := FOperandCount - OperandCount to FOperandCount - 1 do
    Materialize(Index);
  for Index := 1 to OperandCount do
    PopOperand;
  Base := FNextHome;
  Emit(Operation, Base, B, C, Extra);
  if HasResult then
    PushOperand(ResultType);
end;

procedure TFunctionCompiler.CompileSimple(const Instruction: TWasmInstruction);
var
  Info: ^TWasmOpcodeInfo;
  Separator, ParamCount, Index, Immediate: Integer;
  Operands: array[0..2] of TCompileOperand;
  Sources: array[0..2] of Int32;
  ResultType: TWasmValueType;
  HasResult: Boolean;
  Destination: Int32;
begin
  Info := @WasmOpcodeTable[Instruction.Opcode];
  Separator := Pos('>', Info^.Signature);
  ParamCount := Separator - 1;
  HasResult := Separator < Length(Info^.Signature);
  if HasResult then
    ResultType := SignatureLetterType(Info^.Signature[Separator + 1])
  else
    ResultType := WasmI32Type;
  { Operations whose operands and result share their homes. }
  case Info^.Immediate of
    ikMemargLane:
      begin
        CompileAtHome(Instruction.Opcode, 2, Int32(Cardinal(Instruction.MemoryOffset)), 0, Instruction.Lane,
          ResultType, HasResult);
        Exit;
      end;
    ikShuffle:
      begin
        CompileAtHome(Instruction.Opcode, 2, AddConstants(Instruction.Vector.QWords[0], Instruction.Vector.QWords[1]),
          0, 0, ResultType, True);
        Exit;
      end;
  end;
  if ParamCount = 3 then
  begin
    CompileAtHome(Instruction.Opcode, 3, 0, 0, 0, ResultType, HasResult);
    Exit;
  end;
  { A constant second operand of an operation with an immediate form. }
  if (ParamCount = 2) and TopOperand.IsConstant and (ImmediateForm(Instruction.Opcode) >= 0) and
    (TopOperand.Constant >= Low(Int32)) and (TopOperand.Constant <= High(Int32)) then
  begin
    Immediate := Int32(TopOperand.Constant);
    if (Instruction.Opcode = OpI32Sub) or (Instruction.Opcode = OpI64Sub) then
      Immediate := Int32(-Int64(Immediate));
    if not ((Instruction.Opcode = OpI64Sub) and (TopOperand.Constant = Low(Int32))) then
    begin
      PopOperand;
      Operands[0] := PopOperand;
      Sources[0] := SourceOf(Operands[0]);
      Destination := PushOperand(ResultType);
      EmitResult(ImmediateForm(Instruction.Opcode), Destination, Sources[0], Immediate);
      Exit;
    end;
  end;
  for Index := ParamCount - 1 downto 0 do
    Operands[Index] := PopOperand;
  for Index := 0 to ParamCount - 1 do
    Sources[Index] := SourceOf(Operands[Index]);
  for Index := ParamCount to 1 do
    Sources[Index] := 0;
  case Info^.Immediate of
    ikMemarg:
      if HasResult then
      begin
        Destination := PushOperand(ResultType);
        EmitResult(Instruction.Opcode, Destination, Sources[0], Int32(Cardinal(Instruction.MemoryOffset)),
          Instruction.MemoryIndex);
      end
      else
        Emit(Instruction.Opcode, Sources[1], Sources[0], Int32(Cardinal(Instruction.MemoryOffset)),
          Instruction.MemoryIndex);
    ikMemory:
      begin
        Destination := PushOperand(ResultType);
        EmitResult(Instruction.Opcode, Destination, Sources[0], 0, Instruction.MemoryIndex);
      end;
  else
    if HasResult then
    begin
      Destination := PushOperand(ResultType);
      EmitResult(Instruction.Opcode, Destination, Sources[0], Sources[1], Instruction.Lane);
    end
    else
      Emit(Instruction.Opcode, Sources[0], Sources[1], 0, Instruction.Lane);
  end;
end;

procedure TFunctionCompiler.CompileInstruction(const Instruction: TWasmInstruction; const Labels: array of Cardinal);
var
  ParamTypes, ResultTypes: TWasmValueTypeArray;
  Operand: TCompileOperand;
  Destination, Source: Int32;
begin
  case Instruction.Opcode of
    OpUnreachable:
      begin
        Emit(OpUnreachable);
        MarkUnreachable;
      end;
    OpNop: ;
    OpBlock, OpLoop:
      begin
        BlockTypes(Instruction.BlockType, ParamTypes, ResultTypes);
        MaterializeAll;
        FLastResult := -1;
        if Instruction.Opcode = OpLoop then
          PushFrame(cfLoop, ParamTypes, ResultTypes)
        else
          PushFrame(cfBlock, ParamTypes, ResultTypes);
      end;
    OpIf: CompileIf(Instruction);
    OpElse: CompileElse;
    OpEnd: CompileEnd;
    OpBr:
      begin
        MaterializeAll;
        EmitBranchTo(Instruction.Index);
        MarkUnreachable;
      end;
    OpBrIf:
      EmitConditionalBranch(Instruction.Index, PopOperand);
    OpBrTable:
      CompileBranchTable(Instruction, Labels);
    OpReturn:
      CompileReturn;
    OpCall:
      CompileCall(Instruction.Index);
    OpCallIndirect:
      CompileCallIndirect(Instruction.Index, Instruction.SecondIndex);
    OpDrop:
      PopOperand;
    OpSelect, OpSelectTyped:
      CompileSelect;
    OpLocalGet:
      PushLocal(Instruction.Index);
    OpLocalSet:
      CompileLocalSet(Instruction.Index, False);
    OpLocalTee:
      CompileLocalSet(Instruction.Index, True);
    OpGlobalGet:
      begin
        Destination := PushOperand(FModule.Globals[Instruction.Index].ValueType);
        if FModule.Globals[Instruction.Index].ValueType.Kind = vkV128 then
          EmitResult(CodeGlobalGet128, Destination, Instruction.Index)
        else
          EmitResult(CodeGlobalGet, Destination, Instruction.Index);
      end;
    OpGlobalSet:
      begin
        Operand := PopOperand;
        Source := SourceOf(Operand);
        if Operand.ValueType.Kind = vkV128 then
          Emit(CodeGlobalSet128, Source, Instruction.Index)
        else
          Emit(CodeGlobalSet, Source, Instruction.Index);
      end;
    OpI32Const:
      PushConstant(WasmI32Type, Int32(Instruction.Constant));
    OpI64Const:
      if (Int64(Instruction.Constant) >= Low(Int32)) and (Int64(Instruction.Constant) <= High(Int32)) then
        PushConstant(WasmI64Type, Int64(Instruction.Constant))
      else
      begin
        Destination := PushOperand(WasmI64Type);
        EmitResult(CodeConst64, Destination, Int32(Instruction.Constant and $FFFFFFFF), Int32(Instruction.Constant shr 32));
      end;
    OpF32Const:
      begin
        Destination := PushOperand(WasmF32Type);
        EmitResult(CodeConst32, Destination, Int32(Instruction.Constant));
      end;
    OpF64Const:
      begin
        Destination := PushOperand(WasmF64Type);
        EmitResult(CodeConst64, Destination, Int32(Instruction.Constant and $FFFFFFFF), Int32(Instruction.Constant shr 32));
      end;
    OpV128Const:
      begin
        Destination := PushOperand(WasmV128Type);
        EmitResult(CodeConst128, Destination, AddConstants(Instruction.Vector.QWords[0], Instruction.Vector.QWords[1]));
      end;
    OpRefNull:
      begin
        Destination := PushOperand(Instruction.ReferenceType);
        EmitResult(CodeConst64, Destination, 0, 0);
      end;
    OpRefIsNull:
      begin
        Operand := PopOperand;
        Source := SourceOf(Operand);
        Destination := PushOperand(WasmI32Type);
        EmitResult(OpRefIsNull, Destination, Source);
      end;
    OpRefFunc:
      begin
        Destination := PushOperand(WasmFuncRefType);
        EmitResult(OpRefFunc, Destination, Instruction.Index);
      end;
    OpTableGet:
      begin
        Operand := PopOperand;
        Source := SourceOf(Operand);
        Destination := PushOperand(FModule.Tables[Instruction.Index].ElementType);
        EmitResult(OpTableGet, Destination, Source, Instruction.Index);
      end;
    OpTableSet:
      begin
        Operand := PopOperand;
        Source := SourceOf(Operand);
        Operand := PopOperand;
        Emit(OpTableSet, SourceOf(Operand), Source, Instruction.Index);
      end;
    OpTableSize:
      begin
        Destination := PushOperand(WasmI32Type);
        EmitResult(OpTableSize, Destination, 0, Instruction.Index);
      end;
    OpTableGrow:
      CompileAtHome(OpTableGrow, 2, 0, Instruction.Index, 0, WasmI32Type, True);
    OpTableFill:
      CompileAtHome(OpTableFill, 3, 0, Instruction.Index, 0, WasmI32Type, False);
    OpTableCopy:
      CompileAtHome(OpTableCopy, 3, Instruction.Index, Instruction.SecondIndex, 0, WasmI32Type, False);
    OpTableInit:
      CompileAtHome(OpTableInit, 3, Instruction.Index, Instruction.SecondIndex, 0, WasmI32Type, False);
    OpElemDrop:
      Emit(OpElemDrop, Instruction.Index);
    OpMemoryInit:
      CompileAtHome(OpMemoryInit, 3, Instruction.Index, 0, Instruction.MemoryIndex, WasmI32Type, False);
    OpMemoryCopy:
      CompileAtHome(OpMemoryCopy, 3, 0, 0, 0, WasmI32Type, False);
    OpMemoryFill:
      CompileAtHome(OpMemoryFill, 3, 0, 0, Instruction.MemoryIndex, WasmI32Type, False);
    OpDataDrop:
      Emit(OpDataDrop, Instruction.Index);
  else
    CompileSimple(Instruction);
  end;
end;

{ Code after an unconditional branch: only the nesting matters, until
  the else or end that makes code reachable again. }
procedure TFunctionCompiler.SkipDeadInstruction(const Instruction: TWasmInstruction; var DeadDepth: Integer;
  const Labels: array of Cardinal);
begin
  case Instruction.Opcode of
    OpBlock, OpLoop, OpIf:
      Inc(DeadDepth);
    OpElse:
      if DeadDepth = 0 then
        CompileInstruction(Instruction, Labels);
    OpEnd:
      if DeadDepth = 0 then
        CompileInstruction(Instruction, Labels)
      else
        Dec(DeadDepth);
  end;
end;

function TFunctionCompiler.Compile(DefinedIndex: Cardinal): TCompiledFunction;
var
  FunctionIndex: Cardinal;
  FunctionType: TWasmFunctionType;
  Body: TWasmFunctionBody;
  Index, DeadDepth: Integer;
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
begin
  FunctionIndex := FModule.ImportedFunctionCount + DefinedIndex;
  FunctionType := FModule.FunctionType(FunctionIndex);
  Body := FModule.Bodies[DefinedIndex];
  FCode := TCompiledFunction.Create;
  try
    FCode.FunctionIndex := FunctionIndex;
    SetLength(FLocalTypes, Length(FunctionType.Params) + Length(Body.Locals));
    for Index := 0 to High(FunctionType.Params) do
      FLocalTypes[Index] := FunctionType.Params[Index];
    for Index := 0 to High(Body.Locals) do
      FLocalTypes[Length(FunctionType.Params) + Index] := Body.Locals[Index];
    SetLength(FLocalSlots, Length(FLocalTypes));
    FLocalSlotCount := 0;
    FHasExternLocals := False;
    for Index := 0 to High(FLocalTypes) do
    begin
      FLocalSlots[Index] := FLocalSlotCount;
      Inc(FLocalSlotCount, SlotCount(FLocalTypes[Index]));
      if (FLocalTypes[Index].Kind = vkReference) and (FLocalTypes[Index].HeapType = HeapTypeExtern) then
        FHasExternLocals := True;
    end;
    FCode.ParamSlots := SlotCountOf(FunctionType.Params);
    FNextHome := FLocalSlotCount;
    FMaximumSlots := FLocalSlotCount;
    FOperandCount := 0;
    FFrameCount := 0;
    FCount := 0;
    FLastResult := -1;
    PushFrame(cfFunction, nil, FunctionType.Results);
    Instructions.Initialize(PByte(FModule.Bytes), Body.BodyStart, Body.BodyLimit);
    DeadDepth := 0;
    while FFrameCount > 0 do
    begin
      Instructions.Next(Instruction);
      FByteOffset := Instruction.Offset;
      if FFrames[CurrentFrame].Unreachable then
        SkipDeadInstruction(Instruction, DeadDepth, Instructions.Labels)
      else
        CompileInstruction(Instruction, Instructions.Labels);
    end;
    Finish;
    Result := FCode;
  except
    FCode.Free;
    raise;
  end;
end;

procedure CompileModule(Module: TWasmModule);
var
  Compiler: TFunctionCompiler;
  Index: Integer;
begin
  for Index := 0 to High(Module.Bodies) do
  begin
    Compiler := TFunctionCompiler.Create(Module);
    try
      Module.Bodies[Index].Compiled := Compiler.Compile(Index);
    finally
      Compiler.Free;
    end;
  end;
end;

end.
