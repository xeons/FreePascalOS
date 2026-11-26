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

{ The compiler (Wasm.Compiler): memory instructions on memories other
  than an i32 memory 0 (multiple memories, memory64), which become the
  ...At operations of Wasm.MemoryAccess, and table instructions on
  table64 tables (a flag in Extra). }

{ Whether a memory instruction can use the interpreter's own loads and
  stores (memory 0, 32-bit addresses, an offset of 32 bits). }
function TFunctionCompiler.IsFastMemory(const Instruction: TWasmInstruction): Boolean;
begin
  Result := (Instruction.MemoryIndex = 0) and (Length(FModule.Memories) > 0) and
    (FModule.Memories[0].AddressType = vkI32) and (Instruction.MemoryOffset <= $FFFFFFFF);
  if Result and (Instruction.Opcode = OpMemoryCopy) then
    Result := Instruction.SecondIndex = 0;
end;

function TFunctionCompiler.MemoryAddressType(MemoryIndex: Cardinal): TWasmValueType;
begin
  Result := MakeNumberType(FModule.Memories[MemoryIndex].AddressType);
end;

procedure TFunctionCompiler.CompileMemoryAt(const Instruction: TWasmInstruction);
var
  Info: ^TWasmOpcodeInfo;
  Separator: Integer;
  HasResult: Boolean;
  ResultType: TWasmValueType;
  Constant: Int32;
  Address, Value: TCompileOperand;
  AddressSlot, ValueSlot: Int32;
begin
  Info := @WasmOpcodeTable[Instruction.Opcode];
  case Instruction.Opcode of
    OpMemorySize:
      EmitResult(CodeMemorySizeAt, PushOperand(MemoryAddressType(Instruction.MemoryIndex)), 0, 0,
        Instruction.MemoryIndex);
    OpMemoryGrow:
      begin
        Value := PopOperand;
        ValueSlot := SourceOf(Value);
        EmitResult(CodeMemoryGrowAt, PushOperand(MemoryAddressType(Instruction.MemoryIndex)), ValueSlot, 0,
          Instruction.MemoryIndex);
      end;
    OpMemoryFill:
      CompileAtHome(CodeMemoryFillAt, 3, 0, 0, Instruction.MemoryIndex, WasmI32Type, False);
    OpMemoryCopy:
      CompileAtHome(CodeMemoryCopyAt, 3, Instruction.MemoryIndex, Instruction.SecondIndex, 0, WasmI32Type, False);
    OpMemoryInit:
      CompileAtHome(CodeMemoryInitAt, 3, Instruction.Index, 0, Instruction.MemoryIndex, WasmI32Type, False);
  else
    begin
      Constant := AddConstants(Instruction.MemoryOffset,
        QWord(Instruction.MemoryIndex) or (QWord(Instruction.Lane) shl 32));
      Separator := Pos('>', Info^.Signature);
      HasResult := Separator < Length(Info^.Signature);
      if HasResult then
        ResultType := SignatureLetterType(Info^.Signature[Separator + 1])
      else
        ResultType := WasmI32Type;
      if Info^.Immediate = ikMemargLane then
        CompileAtHome(CodeMemoryAccessAt, 2, 0, Constant, Instruction.Opcode, ResultType, HasResult)
      else if HasResult then
      begin
        Address := PopOperand;
        AddressSlot := SourceOf(Address);
        EmitResult(CodeMemoryAccessAt, PushOperand(ResultType), AddressSlot, Constant, Instruction.Opcode);
      end
      else
      begin
        Value := PopOperand;
        ValueSlot := SourceOf(Value);
        Address := PopOperand;
        AddressSlot := SourceOf(Address);
        Emit(CodeMemoryAccessAt, ValueSlot, AddressSlot, Constant, Instruction.Opcode);
      end;
    end;
  end;
end;

function TFunctionCompiler.TableFlags(Index: Cardinal): Integer;
begin
  Result := Ord(FModule.Tables[Index].AddressType = vkI64) * TableIndex64;
end;

function TFunctionCompiler.TableAddressType(Index: Cardinal): TWasmValueType;
begin
  Result := MakeNumberType(FModule.Tables[Index].AddressType);
end;
