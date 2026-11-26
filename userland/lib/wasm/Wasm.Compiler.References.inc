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

{ The compiler (Wasm.Compiler): typed references and garbage collection.
  An allocating instruction has its operands at home and a safepoint
  that lists them (the collector may run before the object exists).
  Field accesses carry the field's byte offset and access kind, so the
  run time needs no type for them. br_on_cast tests into a scratch slot
  and branches on it; br_on_null and br_on_non_null branch on the
  reference itself. }

function TFunctionCompiler.CanonicalReference(const ValueType: TWasmValueType): TWasmValueType;
begin
  Result := ValueType;
  if (Result.Kind = vkReference) and (Result.HeapType >= 0) then
    Result.HeapType := FModule.CanonicalType(Result.HeapType);
end;

procedure TFunctionCompiler.CompileAllocation(Operation: Integer; OperandCount: Integer; B, C: Int32;
  const ResultType: TWasmValueType);
var
  Index, Base, Slots: Integer;
begin
  MaterializeAll;
  Slots := 0;
  for Index := FOperandCount - OperandCount to FOperandCount - 1 do
    Inc(Slots, SlotCount(FOperands[Index].ValueType));
  Base := FNextHome - Slots;
  Index := Emit(Operation, Base, B, C);
  RecordSafepoint(Index, FOperandCount);
  for Index := 1 to OperandCount do
    PopOperand;
  PushOperand(ResultType);
end;

procedure TFunctionCompiler.CompileStructAccess(const Instruction: TWasmInstruction);
var
  Fields: TWasmFieldTypeArray;
  Offset, Access: Integer;
  Value, Reference: TCompileOperand;
  ValueSlot: Int32;
begin
  Fields := FModule.TypeDefinitions[Instruction.Index].Fields;
  Offset := StructFieldOffset(Fields, Instruction.SecondIndex);
  Access := FieldAccess(Fields[Instruction.SecondIndex], Instruction.Opcode = OpStructGetS);
  if Instruction.Opcode = OpStructSet then
  begin
    Value := PopOperand;
    ValueSlot := SourceOf(Value);
    Reference := PopOperand;
    Emit(CodeStructSet, SourceOf(Reference), ValueSlot, Offset, Access);
  end
  else
  begin
    Reference := PopOperand;
    ValueSlot := SourceOf(Reference);
    EmitResult(CodeStructGet, PushOperand(FieldValueType(Fields[Instruction.SecondIndex])), ValueSlot, Offset,
      Access);
  end;
end;

function TFunctionCompiler.ArrayElementAccess(TypeIndex: Cardinal; Signed: Boolean): Integer;
begin
  Result := FieldAccess(FModule.TypeDefinitions[TypeIndex].Fields[0], Signed);
end;

procedure TFunctionCompiler.CompileUnaryReference(Operation: Integer; const ResultType: TWasmValueType;
  Extra: Integer = 0; C: Int32 = 0);
var
  Operand: TCompileOperand;
  Source: Int32;
begin
  Operand := PopOperand;
  Source := SourceOf(Operand);
  EmitResult(Operation, PushOperand(ResultType), Source, C, Extra);
end;

{ The heap type operand of a test or cast: abstract, or canonical. }
function TFunctionCompiler.HeapTypeOperand(const ValueType: TWasmValueType): Int32;
begin
  Result := CanonicalReference(ValueType).HeapType;
end;

procedure TFunctionCompiler.CompileBranchOnCast(const Instruction: TWasmInstruction);
var
  Reference, Condition: TCompileOperand;
  Source, Scratch: Int32;
  Target, Remainder: TWasmValueType;
  Flags: Integer;
begin
  Target := CanonicalReference(Instruction.TargetType);
  Reference := TopOperand;
  Source := Reference.Source;
  Flags := Ord(Target.Nullable);
  if Instruction.Opcode = OpBrOnCastFail then
    Flags := Flags or 2;
  Scratch := PushOperand(WasmI32Type);
  EmitResult(CodeRefTest, Scratch, Source, HeapTypeOperand(Target), Flags);
  Condition := PopOperand;
  EmitConditionalBranch(Instruction.Index, Condition);
  Remainder := CanonicalReference(Instruction.ReferenceType);
  if Target.Nullable then
    Remainder.Nullable := False;
  if Instruction.Opcode = OpBrOnCast then
    FOperands[FOperandCount - 1].ValueType := Remainder
  else
    FOperands[FOperandCount - 1].ValueType := Target;
end;

procedure TFunctionCompiler.CompileBranchOnNull(const Instruction: TWasmInstruction);
var
  Operand: TCompileOperand;
  ValueType: TWasmValueType;
begin
  if Instruction.Opcode = OpBrOnNull then
  begin
    Operand := PopOperand;
    EmitConditionalBranch(Instruction.Index, Operand, bcNull);
    ValueType := Operand.ValueType;
    ValueType.Nullable := False;
    PushOperand(ValueType);
    FOperands[FOperandCount - 1].Source := Operand.Source;
  end
  else
  begin
    { The reference stays where the label's values are while branching. }
    Operand := TopOperand;
    EmitConditionalBranch(Instruction.Index, Operand, bcNonNull);
    PopOperand;
  end;
end;

procedure TFunctionCompiler.CompileReferenceInstruction(const Instruction: TWasmInstruction);
var
  Operand, Second: TCompileOperand;
  Source, Destination: Int32;
  ResultType: TWasmValueType;
  Definition: TWasmTypeDefinition;
  Index: Integer;
begin
  case Instruction.Opcode of
    OpRefAsNonNull:
      begin
        Operand := PopOperand;
        ResultType := Operand.ValueType;
        ResultType.Nullable := False;
        Source := SourceOf(Operand);
        EmitResult(CodeRefAsNonNull, PushOperand(ResultType), Source);
      end;
    OpRefEq:
      begin
        Second := PopOperand;
        Operand := PopOperand;
        Source := SourceOf(Operand);
        Destination := SourceOf(Second);
        EmitResult(CodeRefEq, PushOperand(WasmI32Type), Source, Destination);
      end;
    OpBrOnNull, OpBrOnNonNull:
      CompileBranchOnNull(Instruction);
    OpStructNew:
      begin
        Definition := FModule.TypeDefinitions[Instruction.Index];
        CompileAllocation(CodeStructNew, Length(Definition.Fields), Instruction.Index, 0,
          MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
      end;
    OpStructNewDefault:
      CompileAllocation(CodeStructNewDefault, 0, Instruction.Index, 0,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpStructGet, OpStructGetS, OpStructGetU, OpStructSet:
      CompileStructAccess(Instruction);
    OpArrayNew:
      CompileAllocation(CodeArrayNew, 2, Instruction.Index, 0,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpArrayNewDefault:
      CompileAllocation(CodeArrayNewDefault, 1, Instruction.Index, 0,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpArrayNewFixed:
      CompileAllocation(CodeArrayNewFixed, Instruction.SecondIndex, Instruction.Index, Instruction.SecondIndex,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpArrayNewData:
      CompileAllocation(CodeArrayNewData, 2, Instruction.Index, Instruction.SecondIndex,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpArrayNewElem:
      CompileAllocation(CodeArrayNewElem, 2, Instruction.Index, Instruction.SecondIndex,
        MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
    OpArrayGet, OpArrayGetS, OpArrayGetU:
      begin
        Second := PopOperand;
        Destination := SourceOf(Second);
        Operand := PopOperand;
        Source := SourceOf(Operand);
        ResultType := FieldValueType(FModule.TypeDefinitions[Instruction.Index].Fields[0]);
        EmitResult(CodeArrayGet, PushOperand(ResultType), Source, Destination,
          ArrayElementAccess(Instruction.Index, Instruction.Opcode = OpArrayGetS));
      end;
    OpArraySet:
      CompileAtHome(CodeArraySet, 3, 0, 0, ArrayElementAccess(Instruction.Index, False), WasmI32Type, False);
    OpArrayLen:
      CompileUnaryReference(CodeArrayLen, WasmI32Type);
    OpArrayFill:
      CompileAtHome(CodeArrayFill, 4, 0, 0, ArrayElementAccess(Instruction.Index, False), WasmI32Type, False);
    OpArrayCopy:
      CompileAtHome(CodeArrayCopy, 5, 0, 0, 0, WasmI32Type, False);
    OpArrayInitData:
      CompileAtHome(CodeArrayInitData, 4, Instruction.Index, Instruction.SecondIndex, 0, WasmI32Type, False);
    OpArrayInitElem:
      CompileAtHome(CodeArrayInitElem, 4, Instruction.Index, Instruction.SecondIndex, 0, WasmI32Type, False);
    OpRefTest, OpRefTestNull:
      CompileUnaryReference(CodeRefTest, WasmI32Type, Ord(Instruction.ReferenceType.Nullable),
        HeapTypeOperand(Instruction.ReferenceType));
    OpRefCast, OpRefCastNull:
      CompileUnaryReference(CodeRefCast, CanonicalReference(Instruction.ReferenceType),
        Ord(Instruction.ReferenceType.Nullable), HeapTypeOperand(Instruction.ReferenceType));
    OpBrOnCast, OpBrOnCastFail:
      CompileBranchOnCast(Instruction);
    OpAnyConvertExtern:
      begin
        ResultType := MakeReferenceType(HeapTypeAny, TopOperand.ValueType.Nullable);
        CompileAllocation(CodeAnyConvertExtern, 1, 0, 0, ResultType);
        Index := FInstructions[FCount - 1].A;
        FInstructions[FCount - 1].B := Index;
      end;
    OpExternConvertAny:
      CompileUnaryReference(CodeExternConvertAny, MakeReferenceType(HeapTypeExtern, TopOperand.ValueType.Nullable));
    OpRefI31:
      CompileUnaryReference(CodeRefI31, MakeReferenceType(HeapTypeI31, False));
    OpI31GetS:
      CompileUnaryReference(CodeI31Get, WasmI32Type, 1);
    OpI31GetU:
      CompileUnaryReference(CodeI31Get, WasmI32Type, 0);
  end;
end;
