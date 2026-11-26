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

{ The body validator (Wasm.CodeValidator): the dispatch over every
  instruction, control instructions, locals and globals, memories,
  tables and the reference instructions. Memories and tables are
  addressed with their address type (i32, or i64 with memory64 and
  table64). }

procedure TWasmCodeValidator.ValidateLocal(const Instruction: TWasmInstruction);
begin
  if Instruction.Index >= Cardinal(Length(FLocals)) then
    Fail('unknown local ' + IntToStr(Instruction.Index));
  case Instruction.Opcode of
    OpLocalGet:
      begin
        if not FLocalSet[Instruction.Index] then
          Fail('uninitialized local ' + IntToStr(Instruction.Index));
        PushOperand(FLocals[Instruction.Index]);
      end;
    OpLocalSet:
      begin
        PopExpected(FLocals[Instruction.Index]);
        SetLocal(Instruction.Index);
      end;
  else
    PopExpected(FLocals[Instruction.Index]);
    SetLocal(Instruction.Index);
    PushOperand(FLocals[Instruction.Index]);
  end;
end;

procedure TWasmCodeValidator.ValidateMemory(const Instruction: TWasmInstruction);
var
  Info: ^TWasmOpcodeInfo;
  Address, Source: TWasmValueType;
  Separator, Index: Integer;
begin
  Info := @WasmOpcodeTable[Instruction.Opcode];
  case Instruction.Opcode of
    OpMemorySize:
      PushOperand(MemoryAddressType(Instruction.MemoryIndex));
    OpMemoryGrow:
      begin
        Address := MemoryAddressType(Instruction.MemoryIndex);
        PopExpected(Address);
        PushOperand(Address);
      end;
    OpMemoryFill:
      begin
        Address := MemoryAddressType(Instruction.MemoryIndex);
        PopExpected(Address);
        PopExpected(WasmI32Type);
        PopExpected(Address);
      end;
    OpMemoryCopy:
      begin
        Address := MemoryAddressType(Instruction.MemoryIndex);
        Source := MemoryAddressType(Instruction.SecondIndex);
        if (Address.Kind = vkI64) and (Source.Kind = vkI64) then
          PopExpected(WasmI64Type)
        else
          PopExpected(WasmI32Type);
        PopExpected(Source);
        PopExpected(Address);
      end;
    OpMemoryInit:
      begin
        Address := MemoryAddressType(Instruction.MemoryIndex);
        CheckData(Instruction.Index);
        PopExpected(WasmI32Type);
        PopExpected(WasmI32Type);
        PopExpected(Address);
      end;
  else
    begin
      { Loads and stores: the signature's first operand is the address. }
      CheckMemarg(Instruction);
      if Info^.Immediate = ikMemargLane then
        CheckLane(Instruction);
      Address := MemoryAddressType(Instruction.MemoryIndex);
      Separator := Pos('>', Info^.Signature);
      for Index := Separator - 1 downto 2 do
        PopExpected(SignatureLetterType(Info^.Signature[Index]));
      PopExpected(Address);
      for Index := Separator + 1 to Length(Info^.Signature) do
        PushOperand(SignatureLetterType(Info^.Signature[Index]));
    end;
  end;
end;

procedure TWasmCodeValidator.ValidateTable(const Instruction: TWasmInstruction);
var
  Address, Source: TWasmValueType;
  Element: TWasmValueType;
begin
  case Instruction.Opcode of
    OpTableGet:
      begin
        PopExpected(TableAddressType(Instruction.Index));
        PushOperand(FModule.Tables[Instruction.Index].ElementType);
      end;
    OpTableSet:
      begin
        Address := TableAddressType(Instruction.Index);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PopExpected(Address);
      end;
    OpTableSize:
      PushOperand(TableAddressType(Instruction.Index));
    OpTableGrow:
      begin
        Address := TableAddressType(Instruction.Index);
        PopExpected(Address);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PushOperand(Address);
      end;
    OpTableFill:
      begin
        Address := TableAddressType(Instruction.Index);
        PopExpected(Address);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PopExpected(Address);
      end;
    OpTableCopy:
      begin
        Address := TableAddressType(Instruction.Index);
        Source := TableAddressType(Instruction.SecondIndex);
        if not Matches(FModule.Tables[Instruction.SecondIndex].ElementType,
          FModule.Tables[Instruction.Index].ElementType) then
          Fail('type mismatch');
        if (Address.Kind = vkI64) and (Source.Kind = vkI64) then
          PopExpected(WasmI64Type)
        else
          PopExpected(WasmI32Type);
        PopExpected(Source);
        PopExpected(Address);
      end;
    OpTableInit:
      begin
        Address := TableAddressType(Instruction.SecondIndex);
        CheckElement(Instruction.Index);
        Element := FModule.Elements[Instruction.Index].ElementType;
        if not Matches(Element, FModule.Tables[Instruction.SecondIndex].ElementType) then
          Fail('type mismatch');
        PopExpected(WasmI32Type);
        PopExpected(WasmI32Type);
        PopExpected(Address);
      end;
    OpElemDrop:
      CheckElement(Instruction.Index);
  end;
end;

procedure TWasmCodeValidator.ValidateReference(const Instruction: TWasmInstruction);
var
  Reference, Expected: TWasmValueType;
  Types: TWasmValueTypeArray;
  Frame: Integer;
begin
  case Instruction.Opcode of
    OpRefNull:
      begin
        Reference := Instruction.ReferenceType;
        CheckValueType(Reference);
        PushOperand(Reference);
      end;
    OpRefIsNull:
      begin
        PopReference;
        PushOperand(WasmI32Type);
      end;
    OpRefFunc:
      begin
        CheckFunction(Instruction.Index);
        if (Instruction.Index >= Cardinal(Length(FDeclaredReferences))) or
          not FDeclaredReferences[Instruction.Index] then
          Fail('undeclared function reference');
        PushOperand(MakeReferenceType(HeapType(FModule.FunctionTypes[Instruction.Index]), False));
      end;
    OpRefAsNonNull:
      begin
        Reference := PopReference;
        Reference.Nullable := False;
        PushOperand(Reference);
      end;
    OpRefEq:
      begin
        PopExpected(MakeReferenceType(HeapTypeEq));
        PopExpected(MakeReferenceType(HeapTypeEq));
        PushOperand(WasmI32Type);
      end;
    OpBrOnNull:
      begin
        Frame := Label_(Instruction.Index);
        Reference := PopReference;
        Types := LabelTypes(FControls[Frame]);
        PopTypes(Types);
        PushTypes(Types);
        Reference.Nullable := False;
        PushOperand(Reference);
      end;
    OpBrOnNonNull:
      begin
        Frame := Label_(Instruction.Index);
        Types := Copy(LabelTypes(FControls[Frame]));
        if Length(Types) = 0 then
          Fail('type mismatch: br_on_non_null needs a label with a reference');
        Expected := Types[High(Types)];
        SetLength(Types, Length(Types) - 1);
        Reference := PopReference;
        Reference.Nullable := False;
        if not Matches(Reference, Expected) then
          Fail('type mismatch');
        PopTypes(Types);
        PushTypes(Types);
      end;
  end;
end;

procedure TWasmCodeValidator.ValidateInstruction(const Instruction: TWasmInstruction;
  const Labels: array of Cardinal; const Catches: array of TWasmCatchClause);
var
  StartTypes, EndTypes, Types, DefaultTypes: TWasmValueTypeArray;
  Frame: TControlFrame;
  First, Second: TOperandType;
  Index, Arity, Item: Integer;
  Popped: array of TOperandType;
  Info: ^TWasmOpcodeInfo;
  SelectType: TWasmValueType;
begin
  FOffset := Instruction.Offset;
  Info := @WasmOpcodeTable[Instruction.Opcode];
  case Instruction.Opcode of
    OpUnreachable:
      MarkUnreachable;
    OpNop: ;
    OpBlock, OpLoop:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        PopTypes(StartTypes);
        PushControl(Instruction.Opcode, StartTypes, EndTypes);
      end;
    OpIf:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        PopExpected(WasmI32Type);
        PopTypes(StartTypes);
        PushControl(OpIf, StartTypes, EndTypes);
      end;
    OpElse:
      begin
        Frame := PopControl;
        if Frame.Opcode <> OpIf then
          Fail('else without if');
        PushControl(OpElse, Frame.StartTypes, Frame.EndTypes);
      end;
    OpEnd:
      begin
        Frame := PopControl;
        if Frame.Opcode = OpIf then
        begin
          { An if without else passes its parameters through. }
          if Length(Frame.StartTypes) <> Length(Frame.EndTypes) then
            Fail('type mismatch');
          for Index := 0 to High(Frame.StartTypes) do
            if not Matches(Frame.StartTypes[Index], Frame.EndTypes[Index]) then
              Fail('type mismatch');
        end;
        PushTypes(Frame.EndTypes);
      end;
    OpBr:
      begin
        PopTypes(LabelTypes(FControls[Label_(Instruction.Index)]));
        MarkUnreachable;
      end;
    OpBrIf:
      begin
        PopExpected(WasmI32Type);
        Types := LabelTypes(FControls[Label_(Instruction.Index)]);
        PopTypes(Types);
        PushTypes(Types);
      end;
    OpBrTable:
      begin
        PopExpected(WasmI32Type);
        DefaultTypes := LabelTypes(FControls[Label_(Instruction.Index)]);
        Arity := Length(DefaultTypes);
        if Instruction.LabelCount > 0 then
          for Index := 0 to Integer(Instruction.LabelCount) - 1 do
          begin
            Types := LabelTypes(FControls[Label_(Labels[Index])]);
            if Length(Types) <> Arity then
              Fail('type mismatch');
            { Pop and push back what was there: unknown stays unknown. }
            SetLength(Popped, Length(Types));
            for Item := High(Types) downto 0 do
            begin
              Popped[Item] := PopOperand;
              if Popped[Item].Known and not Matches(Popped[Item].ValueType, Types[Item]) then
                Fail('type mismatch');
            end;
            for Item := 0 to High(Types) do
              if Popped[Item].Known then
                PushOperand(Popped[Item].ValueType)
              else
                PushUnknown;
          end;
        PopTypes(DefaultTypes);
        MarkUnreachable;
      end;
    OpReturn:
      begin
        PopTypes(FResults);
        MarkUnreachable;
      end;
    OpCall, OpCallIndirect, OpCallRef, OpReturnCall, OpReturnCallIndirect, OpReturnCallRef:
      ValidateCall(Instruction);
    OpTry, OpCatch, OpCatchAll, OpDelegate, OpThrow, OpRethrow, OpThrowRef, OpTryTable:
      ValidateException(Instruction, Catches);
    OpDrop:
      PopOperand;
    OpSelect:
      begin
        PopExpected(WasmI32Type);
        First := PopOperand;
        Second := PopOperand;
        if (First.Known and IsReferenceType(First.ValueType)) or
          (Second.Known and IsReferenceType(Second.ValueType)) then
          Fail('type mismatch');
        if First.Known and Second.Known and (First.ValueType <> Second.ValueType) then
          Fail('type mismatch');
        if First.Known then
          PushOperand(First.ValueType)
        else if Second.Known then
          PushOperand(Second.ValueType)
        else
          PushUnknown;
      end;
    OpSelectTyped:
      begin
        if Instruction.SelectTypeCount <> 1 then
          Fail('invalid result arity');
        SelectType := Instruction.SelectType;
        CheckValueType(SelectType);
        PopExpected(WasmI32Type);
        PopExpected(SelectType);
        PopExpected(SelectType);
        PushOperand(SelectType);
      end;
    OpLocalGet, OpLocalSet, OpLocalTee:
      ValidateLocal(Instruction);
    OpGlobalGet, OpGlobalSet:
      begin
        if Instruction.Index >= Cardinal(Length(FModule.Globals)) then
          Fail('unknown global ' + IntToStr(Instruction.Index));
        if Instruction.Opcode = OpGlobalGet then
          PushOperand(FModule.Globals[Instruction.Index].ValueType)
        else
        begin
          if not FModule.Globals[Instruction.Index].Mutable then
            Fail('global is immutable');
          PopExpected(FModule.Globals[Instruction.Index].ValueType);
        end;
      end;
    OpTableGet, OpTableSet, OpTableSize, OpTableGrow, OpTableFill, OpTableCopy, OpTableInit, OpElemDrop:
      ValidateTable(Instruction);
    OpMemorySize, OpMemoryGrow, OpMemoryFill, OpMemoryCopy, OpMemoryInit:
      ValidateMemory(Instruction);
    OpDataDrop:
      CheckData(Instruction.Index);
    OpRefNull, OpRefIsNull, OpRefFunc, OpRefAsNonNull, OpRefEq, OpBrOnNull, OpBrOnNonNull:
      ValidateReference(Instruction);
    OpStructNew..OpArrayInitElem, OpAnyConvertExtern..OpI31GetU:
      ValidateAggregate(Instruction);
    OpRefTest..OpBrOnCastFail:
      ValidateCast(Instruction);
  else
    case Info^.Immediate of
      ikMemarg, ikMemargLane:
        begin
          ValidateMemory(Instruction);
          Exit;
        end;
      ikLane:
        CheckLane(Instruction);
      ikShuffle:
        for Index := 0 to 15 do
          if Instruction.Vector.Bytes[Index] >= 32 then
            Fail('invalid lane index');
    end;
    if Info^.Signature = '' then
      Fail('unsupported instruction ' + Info^.Name);
    ApplySignature(Info^.Signature);
  end;
end;
