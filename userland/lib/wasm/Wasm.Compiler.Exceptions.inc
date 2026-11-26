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

{ The compiler (Wasm.Compiler): tail calls, call_ref and exception
  handling. A try or try_table becomes a handler over the code of its
  body (Wasm.Code's TCodeHandler) with its catch clauses; a clause sends
  the payload to the slots of its target label, through a stub that
  returns when the label is the function's. A legacy catch keeps the
  caught exception in a hidden local (one per nesting depth of try) for
  rethrow. Everything is at home where an exception may be thrown
  (calls and throws materialize first), which is what a handler that
  jumps into the middle of the function expects. }

procedure TFunctionCompiler.CompileReturnCall(const Instruction: TWasmInstruction);
var
  FunctionType: TWasmFunctionType;
  Index, ArgumentBase, Operation: Integer;
  Is64: Boolean;
begin
  MaterializeAll;
  case Instruction.Opcode of
    OpReturnCall:
      begin
        FunctionType := FModule.FunctionType(Instruction.Index);
        for Index := 1 to Length(FunctionType.Params) do
          PopOperand;
        Emit(CodeReturnCall, Instruction.Index, FNextHome);
      end;
    OpReturnCallIndirect:
      begin
        FunctionType := FModule.Types[Instruction.Index];
        PopOperand;
        for Index := 1 to Length(FunctionType.Params) do
          PopOperand;
        ArgumentBase := FNextHome;
        Is64 := FModule.Tables[Instruction.SecondIndex].AddressType = vkI64;
        if Is64 then
          Operation := CodeReturnCallIndirect64
        else
          Operation := CodeReturnCallIndirect;
        Emit(Operation, Instruction.Index, ArgumentBase, Instruction.SecondIndex, SlotCountOf(FunctionType.Params));
      end;
  else
    begin
      FunctionType := FModule.Types[Instruction.Index];
      PopOperand;
      for Index := 1 to Length(FunctionType.Params) do
        PopOperand;
      Emit(CodeReturnCallRef, Instruction.Index, FNextHome, 0, SlotCountOf(FunctionType.Params));
    end;
  end;
  MarkUnreachable;
end;

procedure TFunctionCompiler.CompileCallRef(TypeIndex: Cardinal);
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
  Index := Emit(CodeCallRef, TypeIndex, ArgumentBase, 0, SlotCountOf(FunctionType.Params));
  RecordSafepoint(Index, FOperandCount);
  for Index := 0 to High(FunctionType.Results) do
    PushOperand(FunctionType.Results[Index]);
end;

{ A legacy try's slot for its caught exception: one hidden local per
  depth of try nesting. }
function TFunctionCompiler.ExceptionSlotForDepth: Int32;
var
  Frame, Depth: Integer;
begin
  Depth := 0;
  for Frame := 0 to CurrentFrame - 1 do
    if FFrames[Frame].Kind in [cfTry, cfCatch] then
      Inc(Depth);
  Result := FLocalSlots[FExceptionLocalBase + Depth];
end;

procedure TFunctionCompiler.CompileTry(const Instruction: TWasmInstruction);
var
  ParamTypes, ResultTypes: TWasmValueTypeArray;
  Handler: Int32;
begin
  BlockTypes(Instruction.BlockType, ParamTypes, ResultTypes);
  MaterializeAll;
  FLastResult := -1;
  Handler := AddHandler(hkCatch, FFrames[CurrentFrame].ActiveHandler);
  PushFrame(cfTry, ParamTypes, ResultTypes);
  FFrames[CurrentFrame].Handler := Handler;
  FFrames[CurrentFrame].ActiveHandler := Handler;
  FFrames[CurrentFrame].ExceptionSlot := ExceptionSlotForDepth;
end;

procedure TFunctionCompiler.AddPendingClause(var Frame: TCompileFrame; const Clause: TCodeCatchClause);
begin
  if Frame.PendingCount >= Length(Frame.PendingClauses) then
    SetLength(Frame.PendingClauses, Frame.PendingCount * 2 + 2);
  Frame.PendingClauses[Frame.PendingCount] := Clause;
  Inc(Frame.PendingCount);
end;

{ The clauses of a frame's handler, made contiguous now that it ends. }
procedure TFunctionCompiler.FinishHandler(var Frame: TCompileFrame);
var
  Index: Integer;
begin
  if Frame.Handler < 0 then
    Exit;
  FHandlers[Frame.Handler].FirstClause := FClauseCount;
  FHandlers[Frame.Handler].ClauseCount := Frame.PendingCount;
  for Index := 0 to Frame.PendingCount - 1 do
    AddClause(Frame.PendingClauses[Index]);
  Frame.PendingCount := 0;
end;

procedure TFunctionCompiler.CompileCatch(const Instruction: TWasmInstruction);
var
  Index: Integer;
  Clause: TCodeCatchClause;
  PayloadTypes: TWasmValueTypeArray;
begin
  with FFrames[CurrentFrame] do
  begin
    if Kind = cfTry then
      FHandlers[Handler].Limit := FCount;
    if not Unreachable then
    begin
      MaterializeAll;
      Index := Emit(CodeBranch);
      AddFixup(FFrames[CurrentFrame], Index * 2);
    end;
    Clause.Tag := -1;
    PayloadTypes := nil;
    if Instruction.Opcode = OpCatch then
    begin
      Clause.Tag := Instruction.Index;
      PayloadTypes := FModule.TagType(Instruction.Index).Params;
    end;
    Clause.PushesException := False;
    Clause.Destination := SlotHeight;
    Clause.ExceptionSlot := ExceptionSlot;
    Clause.TargetEntry := AddBranchTarget(FCount);
    AddPendingClause(FFrames[CurrentFrame], Clause);
    Kind := cfCatch;
    ActiveHandler := FHandlers[Handler].Outer;
    Unreachable := False;
    ResetOperands(OperandHeight, PayloadTypes);
  end;
  if FMaximumSlots < FNextHome then
    FMaximumSlots := FNextHome;
  FLastResult := -1;
end;

procedure TFunctionCompiler.CompileDelegate(const Instruction: TWasmInstruction);
var
  Frame: Integer;
begin
  Frame := CurrentFrame;
  FHandlers[FFrames[Frame].Handler].Limit := FCount;
  FHandlers[FFrames[Frame].Handler].Kind := hkDelegate;
  FHandlers[FFrames[Frame].Handler].DelegateTarget := FFrames[Frame - 1 - Integer(Instruction.Index)].ActiveHandler;
  CompileEnd;
end;

procedure TFunctionCompiler.CompileTryTable(const Instruction: TWasmInstruction;
  const Catches: array of TWasmCatchClause);
var
  ParamTypes, ResultTypes: TWasmValueTypeArray;
  Clauses: array of TCodeCatchClause;
  Index, Target, PayloadSlots: Integer;
  Handler: Int32;
begin
  BlockTypes(Instruction.BlockType, ParamTypes, ResultTypes);
  MaterializeAll;
  FLastResult := -1;
  SetLength(Clauses, Instruction.CatchCount);
  for Index := 0 to Integer(Instruction.CatchCount) - 1 do
  begin
    Target := CurrentFrame - Integer(Catches[Index].LabelIndex);
    Clauses[Index].Tag := -1;
    PayloadSlots := 0;
    if Catches[Index].Kind in [ckCatch, ckCatchRef] then
    begin
      Clauses[Index].Tag := Catches[Index].Tag;
      PayloadSlots := SlotCountOf(FModule.TagType(Catches[Index].Tag).Params);
    end;
    Clauses[Index].PushesException := Catches[Index].Kind in [ckCatchRef, ckCatchAllRef];
    Clauses[Index].Destination := FFrames[Target].SlotHeight;
    Clauses[Index].ExceptionSlot := -1;
    Clauses[Index].TargetEntry := AddBranchTarget(0);
    if FMaximumSlots < FFrames[Target].SlotHeight + PayloadSlots + 1 then
      FMaximumSlots := FFrames[Target].SlotHeight + PayloadSlots + 1;
    case FFrames[Target].Kind of
      cfLoop:
        FBranchTargets[Clauses[Index].TargetEntry] := FFrames[Target].LoopStart;
      cfFunction:
        AddReturnStub(Clauses[Index].TargetEntry, FFrames[Target].SlotHeight,
          SlotCountOf(FFrames[Target].ResultTypes));
    else
      AddFixup(FFrames[Target], Clauses[Index].TargetEntry * 2 + 1);
    end;
  end;
  Handler := AddHandler(hkCatch, FFrames[CurrentFrame].ActiveHandler);
  PushFrame(cfTryTable, ParamTypes, ResultTypes);
  FFrames[CurrentFrame].Handler := Handler;
  FFrames[CurrentFrame].ActiveHandler := Handler;
  for Index := 0 to High(Clauses) do
    AddPendingClause(FFrames[CurrentFrame], Clauses[Index]);
end;

procedure TFunctionCompiler.AddReturnStub(TargetEntry, Source, Count: Int32);
begin
  SetLength(FReturnStubs, Length(FReturnStubs) + 1);
  FReturnStubs[High(FReturnStubs)].TargetEntry := TargetEntry;
  FReturnStubs[High(FReturnStubs)].Source := Source;
  FReturnStubs[High(FReturnStubs)].Count := Count;
end;

procedure TFunctionCompiler.EmitReturnStubs;
var
  Index: Integer;
begin
  for Index := 0 to High(FReturnStubs) do
  begin
    FBranchTargets[FReturnStubs[Index].TargetEntry] := FCount;
    Emit(CodeReturn, FReturnStubs[Index].Source, FReturnStubs[Index].Count);
  end;
  FReturnStubs := nil;
end;

procedure TFunctionCompiler.CompileThrow(TagIndex: Cardinal);
var
  Params: TWasmValueTypeArray;
  Base, Index: Integer;
begin
  Params := FModule.TagType(TagIndex).Params;
  MaterializeAll;
  if Length(Params) > 0 then
    Base := FOperands[FOperandCount - Length(Params)].Home
  else
    Base := FNextHome;
  Index := Emit(CodeThrow, Base, TagIndex);
  RecordSafepoint(Index, FOperandCount);
  for Index := 1 to Length(Params) do
    PopOperand;
  MarkUnreachable;
end;

procedure TFunctionCompiler.CompileThrowRef;
var
  Operand: TCompileOperand;
begin
  MaterializeAll;
  Operand := PopOperand;
  Emit(CodeThrowRef, SourceOf(Operand));
  MarkUnreachable;
end;

procedure TFunctionCompiler.CompileRethrow(Depth: Cardinal);
begin
  MaterializeAll;
  Emit(CodeRethrow, FFrames[CurrentFrame - Integer(Depth)].ExceptionSlot);
  MarkUnreachable;
end;
