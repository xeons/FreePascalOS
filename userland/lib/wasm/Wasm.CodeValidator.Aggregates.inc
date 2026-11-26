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

{ The body validator (Wasm.CodeValidator): the garbage collection
  instructions. Packed fields (i8, i16) are read with the _s and _u
  forms only and as i32; writes need a mutable field; array.new_data and
  init_data need numbers or vectors as elements. Casts test a reference
  against a type of the same hierarchy as the operand's. }

procedure TWasmCodeValidator.ValidateAggregate(const Instruction: TWasmInstruction);
var
  Definition, Source: TWasmTypeDefinition;
  Field: TWasmFieldType;
  Reference: TWasmValueType;
  Index: Integer;
  Count: Cardinal;

  function TypedReference(TypeIndex: Cardinal): TWasmValueType;
  begin
    Result := MakeReferenceType(HeapType(TypeIndex), True);
  end;

  procedure CheckFieldAccess(const AField: TWasmFieldType);
  begin
    case Instruction.Opcode of
      OpStructGet, OpArrayGet:
        if IsPackedField(AField) then
          Fail('type mismatch: packed field needs get_s or get_u');
      OpStructGetS, OpStructGetU, OpArrayGetS, OpArrayGetU:
        if not IsPackedField(AField) then
          Fail('type mismatch: field is not packed');
    end;
  end;

  procedure CheckMutable(const AField: TWasmFieldType);
  begin
    if not AField.Mutable then
      Fail('immutable field');
  end;

  procedure CheckNumericElement(const AField: TWasmFieldType);
  begin
    if (AField.Storage = skValue) and (AField.ValueType.Kind = vkReference) then
      Fail('type mismatch: array type is not numeric or vector');
  end;

  procedure CheckElementSegment(SegmentIndex: Cardinal; const AField: TWasmFieldType);
  begin
    CheckElement(SegmentIndex);
    if not Matches(FModule.Elements[SegmentIndex].ElementType, FieldValueType(AField)) then
      Fail('type mismatch');
  end;

begin
  case Instruction.Opcode of
    OpStructNew, OpStructNewDefault:
      begin
        Definition := StructAt(Instruction.Index);
        if Instruction.Opcode = OpStructNew then
        begin
          for Index := High(Definition.Fields) downto 0 do
            PopExpected(FieldValueType(Definition.Fields[Index]));
        end
        else
          for Index := 0 to High(Definition.Fields) do
            if not IsDefaultable(Definition.Fields[Index].ValueType) then
              Fail('type mismatch: field type is not defaultable');
        PushOperand(MakeReferenceType(HeapType(Instruction.Index), False));
      end;
    OpStructGet, OpStructGetS, OpStructGetU, OpStructSet:
      begin
        Definition := StructAt(Instruction.Index);
        if Instruction.SecondIndex >= Cardinal(Length(Definition.Fields)) then
          Fail('unknown field ' + IntToStr(Instruction.SecondIndex));
        Field := Definition.Fields[Instruction.SecondIndex];
        if Instruction.Opcode = OpStructSet then
        begin
          CheckMutable(Field);
          PopExpected(FieldValueType(Field));
          PopExpected(TypedReference(Instruction.Index));
        end
        else
        begin
          CheckFieldAccess(Field);
          PopExpected(TypedReference(Instruction.Index));
          PushOperand(FieldValueType(Field));
        end;
      end;
    OpArrayNew, OpArrayNewDefault, OpArrayNewFixed, OpArrayNewData, OpArrayNewElem:
      begin
        Definition := ArrayAt(Instruction.Index);
        Field := Definition.Fields[0];
        case Instruction.Opcode of
          OpArrayNew:
            begin
              PopExpected(WasmI32Type);
              PopExpected(FieldValueType(Field));
            end;
          OpArrayNewDefault:
            begin
              if not IsDefaultable(Field.ValueType) then
                Fail('type mismatch: array type is not defaultable');
              PopExpected(WasmI32Type);
            end;
          OpArrayNewFixed:
            begin
              if Instruction.SecondIndex > MaximumFixedArrayLength then
                Fail('type mismatch: too many array elements');
              Count := 0;
              while Count < Instruction.SecondIndex do
              begin
                PopExpected(FieldValueType(Field));
                Inc(Count);
              end;
            end;
          OpArrayNewData:
            begin
              CheckNumericElement(Field);
              CheckData(Instruction.SecondIndex);
              PopExpected(WasmI32Type);
              PopExpected(WasmI32Type);
            end;
        else
          CheckElementSegment(Instruction.SecondIndex, Field);
          PopExpected(WasmI32Type);
          PopExpected(WasmI32Type);
        end;
        PushOperand(MakeReferenceType(HeapType(Instruction.Index), False));
      end;
    OpArrayGet, OpArrayGetS, OpArrayGetU:
      begin
        Field := ArrayAt(Instruction.Index).Fields[0];
        CheckFieldAccess(Field);
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.Index));
        PushOperand(FieldValueType(Field));
      end;
    OpArraySet:
      begin
        Field := ArrayAt(Instruction.Index).Fields[0];
        CheckMutable(Field);
        PopExpected(FieldValueType(Field));
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.Index));
      end;
    OpArrayLen:
      begin
        PopExpected(MakeReferenceType(HeapTypeArray, True));
        PushOperand(WasmI32Type);
      end;
    OpArrayFill:
      begin
        Field := ArrayAt(Instruction.Index).Fields[0];
        CheckMutable(Field);
        PopExpected(WasmI32Type);
        PopExpected(FieldValueType(Field));
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.Index));
      end;
    OpArrayCopy:
      begin
        Definition := ArrayAt(Instruction.Index);
        Source := ArrayAt(Instruction.SecondIndex);
        CheckMutable(Definition.Fields[0]);
        if (Definition.Fields[0].Storage <> Source.Fields[0].Storage) or
          not Matches(FieldValueType(Source.Fields[0]), FieldValueType(Definition.Fields[0])) then
          Fail('type mismatch: array types do not match');
        PopExpected(WasmI32Type);
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.SecondIndex));
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.Index));
      end;
    OpArrayInitData, OpArrayInitElem:
      begin
        Field := ArrayAt(Instruction.Index).Fields[0];
        CheckMutable(Field);
        if Instruction.Opcode = OpArrayInitData then
        begin
          CheckNumericElement(Field);
          CheckData(Instruction.SecondIndex);
        end
        else
          CheckElementSegment(Instruction.SecondIndex, Field);
        PopExpected(WasmI32Type);
        PopExpected(WasmI32Type);
        PopExpected(WasmI32Type);
        PopExpected(TypedReference(Instruction.Index));
      end;
    OpAnyConvertExtern:
      begin
        Reference := PopExpected(WasmExternRefType).ValueType;
        PushOperand(MakeReferenceType(HeapTypeAny, Reference.Nullable));
      end;
    OpExternConvertAny:
      begin
        Reference := PopExpected(MakeReferenceType(HeapTypeAny)).ValueType;
        PushOperand(MakeReferenceType(HeapTypeExtern, Reference.Nullable));
      end;
    OpRefI31:
      begin
        PopExpected(WasmI32Type);
        PushOperand(MakeReferenceType(HeapTypeI31, False));
      end;
    OpI31GetS, OpI31GetU:
      begin
        PopExpected(MakeReferenceType(HeapTypeI31, True));
        PushOperand(WasmI32Type);
      end;
  end;
end;

procedure TWasmCodeValidator.ValidateCast(const Instruction: TWasmInstruction);
var
  Target, Source, Remainder, Expected: TWasmValueType;
  Types: TWasmValueTypeArray;
  Frame: Integer;
  Top: Int32;
begin
  Target := Instruction.ReferenceType;
  CheckValueType(Target);
  Top := HeapTypeTop(FContext, Target.HeapType);
  case Instruction.Opcode of
    OpRefTest, OpRefTestNull, OpRefCast, OpRefCastNull:
      begin
        PopExpected(MakeReferenceType(Top, True));
        if (Instruction.Opcode = OpRefTest) or (Instruction.Opcode = OpRefTestNull) then
          PushOperand(WasmI32Type)
        else
          PushOperand(Target);
      end;
  else
    begin
      { br_on_cast(_fail) l rt1 rt2: ReferenceType is rt1, TargetType rt2. }
      Source := Target;
      Target := Instruction.TargetType;
      CheckValueType(Target);
      if not Matches(Target, Source) then
        Fail('type mismatch: cast target is not a subtype of the source');
      Frame := Label_(Instruction.Index);
      Types := Copy(LabelTypes(FControls[Frame]));
      if Length(Types) = 0 then
        Fail('type mismatch: br_on_cast needs a label with a reference');
      Expected := Types[High(Types)];
      SetLength(Types, Length(Types) - 1);
      { What fails the cast: the source without what the target allows. }
      Remainder := Source;
      if Target.Nullable then
        Remainder.Nullable := False;
      if Instruction.Opcode = OpBrOnCast then
      begin
        if not Matches(Target, Expected) then
          Fail('type mismatch: br_on_cast label');
      end
      else if not Matches(Remainder, Expected) then
        Fail('type mismatch: br_on_cast_fail label');
      PopExpected(Source);
      PopTypes(Types);
      PushTypes(Types);
      if Instruction.Opcode = OpBrOnCast then
        PushOperand(Remainder)
      else
        PushOperand(Target);
    end;
  end;
end;
