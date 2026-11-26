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
  Decoding one instruction (spec section 5.4): its opcode in the dense
  numbering of Wasm.Opcodes and its immediates, unpacked into a
  TWasmInstruction. The decoder, the validator, the compiler and the
  constant expression evaluator all read code through this, so the
  binary encoding of instructions is known in one place.

  Memory instructions carry a memory index (bit 6 of a memarg's flags
  says one follows; memory.size and the bulk instructions have one where
  2.0 had a zero byte) and a 64-bit offset. try_table's catch clauses and
  br_table's labels are kept in arrays of the reader, valid until the
  next instruction is read. The features (Wasm.Features) say which
  instructions and encodings exist: without the 3.0 ones a reader
  decodes exactly WebAssembly 2.0.
}
unit Wasm.Instructions;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$R-}
{$Q-}

interface

uses
  Wasm.Types,
  Wasm.Features,
  Wasm.Reader;

type
  TWasmBlockTypeKind = (btEmpty, btValue, btTypeIndex);

  TWasmBlockType = record
    Kind: TWasmBlockTypeKind;
    ValueType: TWasmValueType;
    TypeIndex: Cardinal;
  end;

  TWasmCatchKind = (ckCatch, ckCatchRef, ckCatchAll, ckCatchAllRef);

  TWasmCatchClause = record
    Kind: TWasmCatchKind;
    Tag: Cardinal;
    LabelIndex: Cardinal;
  end;

  TWasmInstruction = record
    Opcode: Integer;
    Offset: SizeInt;           { of the opcode, from the module's start }
    { The main index: label, function, local, global, table, type (of
      call_indirect, call_ref and the GC instructions), tag, data or
      element segment, and lane. }
    Index: Cardinal;
    { The second index: the table of call_indirect and table.init, the
      source table of table.copy, the memory of memory.init, the source
      memory of memory.copy, the field of struct.get / set, the count of
      array.new_fixed, the data or element segment of array.new_data /
      new_elem / init_data / init_elem, the source type of array.copy. }
    SecondIndex: Cardinal;
    MemoryIndex: Cardinal;
    Alignment: Cardinal;       { log2, as encoded }
    MemoryOffset: QWord;
    Lane: Byte;
    BlockType: TWasmBlockType;
    Constant: QWord;           { i32 / i64 values, f32 / f64 bits }
    Vector: TWasmV128;         { v128.const, i8x16.shuffle's lanes }
    { ref.null's type; ref.test / ref.cast's target; br_on_cast's source. }
    ReferenceType: TWasmValueType;
    { br_on_cast's target. }
    TargetType: TWasmValueType;
    SelectTypeCount: Cardinal;
    SelectType: TWasmValueType;
    LabelCount: Cardinal;      { br_table: Labels[0..LabelCount), default in Index }
    CatchCount: Cardinal;      { try_table: Catches[0..CatchCount) }
  end;

  TWasmInstructionReader = record
    Reader: TWasmReader;
    Labels: array of Cardinal; { br_table's labels of the last instruction }
    Catches: array of TWasmCatchClause;
    procedure Initialize(Bytes: PByte; Start, Limit: SizeInt; AFeatures: TWasmFeatures);
    function AtEnd: Boolean; inline;
    procedure Next(out Instruction: TWasmInstruction);
  end;

{ Whether the instruction Code exists with Features. }
function InstructionEnabled(Code: Integer; Features: TWasmFeatures): Boolean;

implementation

uses
  Wasm.Opcodes,
  Wasm.Limits;

procedure TWasmInstructionReader.Initialize(Bytes: PByte; Start, Limit: SizeInt; AFeatures: TWasmFeatures);
begin
  Reader.Initialize(Bytes, Start, Limit);
  Reader.Features := AFeatures;
end;

function TWasmInstructionReader.AtEnd: Boolean;
begin
  Result := Reader.AtEnd;
end;

function InstructionEnabled(Code: Integer; Features: TWasmFeatures): Boolean;
begin
  case Code of
    OpTry, OpCatch, OpRethrow, OpDelegate, OpCatchAll:
      Result := wfLegacyExceptions in Features;
    OpThrow:
      Result := Features * [wfExceptionHandling, wfLegacyExceptions] <> [];
    OpThrowRef, OpTryTable:
      Result := wfExceptionHandling in Features;
    OpReturnCall, OpReturnCallIndirect:
      Result := wfTailCalls in Features;
    OpReturnCallRef:
      Result := (wfTailCalls in Features) and (wfFunctionReferences in Features);
    OpCallRef, OpRefAsNonNull, OpBrOnNull, OpBrOnNonNull:
      Result := wfFunctionReferences in Features;
    OpRefEq:
      Result := wfGarbageCollection in Features;
    OpI8x16RelaxedSwizzle..OpI32x4RelaxedDotI8x16I7x16AddS:
      Result := wfRelaxedSimd in Features;
    GcOpcodeBase..LastWasmOpcode:
      Result := wfGarbageCollection in Features;
  else
    Result := True;
  end;
end;

procedure ReadBlockType(var Reader: TWasmReader; out BlockType: TWasmBlockType);
var
  Index: Int64;
begin
  BlockType.TypeIndex := 0;
  BlockType.ValueType := WasmI32Type;
  if Reader.PeekByte = $40 then
  begin
    Reader.ReadByte;
    BlockType.Kind := btEmpty;
  end
  else if Reader.AtValueType then
  begin
    BlockType.ValueType := Reader.ReadValueType;
    BlockType.Kind := btValue;
  end
  else
  begin
    Index := Reader.ReadS33;
    if Index < 0 then
      Reader.Fail('malformed block type');
    BlockType.Kind := btTypeIndex;
    BlockType.TypeIndex := Cardinal(Index);
  end;
end;

procedure ReadMemarg(var Reader: TWasmReader; var Instruction: TWasmInstruction);
var
  Flags: Cardinal;
begin
  Flags := Reader.ReadU32;
  Instruction.MemoryIndex := 0;
  if wfMultipleMemories in Reader.Features then
  begin
    { Bit 6: a memory index follows; 2 to the alignment must fit. }
    if Flags >= 128 then
      Reader.Fail('malformed memop flags');
    if Flags and 64 <> 0 then
    begin
      Instruction.MemoryIndex := Reader.ReadU32;
      Flags := Flags and 63;
    end;
  end
  else if Flags >= 32 then
    Reader.Fail('malformed memop flags');
  Instruction.Alignment := Flags;
  if wfMemory64 in Reader.Features then
    Instruction.MemoryOffset := Reader.ReadU64
  else
    Instruction.MemoryOffset := Reader.ReadU32;
end;

{ A memory index, which WebAssembly 2.0 encodes as a zero byte. }
function ReadMemoryIndex(var Reader: TWasmReader): Cardinal;
begin
  if wfMultipleMemories in Reader.Features then
    Exit(Reader.ReadU32);
  if Reader.ReadByte <> 0 then
    Reader.FailAt(Reader.Position - 1, 'zero byte expected');
  Result := 0;
end;

procedure ReadCatchClauses(var Reader: TWasmReader; var Catches: array of TWasmCatchClause;
  var Instruction: TWasmInstruction); forward;

procedure TWasmInstructionReader.Next(out Instruction: TWasmInstruction);
var
  Code: Cardinal;
  Index: Cardinal;
  First, Flags: Byte;
begin
  Instruction.Offset := Reader.Position;
  Instruction.Index := 0;
  Instruction.SecondIndex := 0;
  Instruction.MemoryIndex := 0;
  Instruction.LabelCount := 0;
  Instruction.CatchCount := 0;
  First := Reader.ReadByte;
  if First = $FC then
  begin
    Code := Reader.ReadU32;
    if Code > $FF then
      Reader.FailAt(Instruction.Offset, 'illegal opcode');
    Code := $100 + Code;
  end
  else if First = $FD then
  begin
    Code := Reader.ReadU32;
    if Code > LastSimdIndex then
      Reader.FailAt(Instruction.Offset, 'illegal opcode');
    Code := $200 + Code;
  end
  else if (First = $FB) and (wfGarbageCollection in Reader.Features) then
  begin
    Code := Reader.ReadU32;
    if Code > LastGcIndex then
      Reader.FailAt(Instruction.Offset, 'illegal opcode');
    Code := GcOpcodeBase + Code;
  end
  else
    Code := First;
  if not IsWasmOpcode(Code) or not InstructionEnabled(Code, Reader.Features) then
    Reader.FailAt(Instruction.Offset, 'illegal opcode ' + WasmOpcodeName(Code));
  Instruction.Opcode := Code;
  case WasmOpcodeTable[Code].Immediate of
    ikNone: ;
    ikBlockType:
      ReadBlockType(Reader, Instruction.BlockType);
    ikLabel, ikFunction, ikLocal, ikGlobal, ikTable, ikData, ikElement, ikTag, ikTypeIndex:
      Instruction.Index := Reader.ReadU32;
    ikLabelTable:
      begin
        Instruction.LabelCount := Reader.ReadU32;
        if Instruction.LabelCount > Reader.Remaining then
          Reader.Fail('unexpected end');
        if Cardinal(Length(Labels)) < Instruction.LabelCount then
          SetLength(Labels, Instruction.LabelCount);
        if Instruction.LabelCount > 0 then
          for Index := 0 to Instruction.LabelCount - 1 do
            Labels[Index] := Reader.ReadU32;
        Instruction.Index := Reader.ReadU32;
      end;
    ikCallIndirect, ikTypeField, ikTypeCount, ikTypeData, ikTypeElement, ikTypeType:
      begin
        Instruction.Index := Reader.ReadU32;
        Instruction.SecondIndex := Reader.ReadU32;
      end;
    ikMemory:
      Instruction.MemoryIndex := ReadMemoryIndex(Reader);
    ikMemarg:
      ReadMemarg(Reader, Instruction);
    ikMemargLane:
      begin
        ReadMemarg(Reader, Instruction);
        Instruction.Lane := Reader.ReadByte;
      end;
    ikLane:
      Instruction.Lane := Reader.ReadByte;
    ikSelectTypes:
      begin
        Instruction.SelectTypeCount := Reader.ReadU32;
        Instruction.SelectType := WasmI32Type;
        if Instruction.SelectTypeCount > Reader.Remaining then
          Reader.Fail('unexpected end');
        if Instruction.SelectTypeCount > 0 then
          for Index := 1 to Instruction.SelectTypeCount do
            Instruction.SelectType := Reader.ReadValueType;
      end;
    ikI32:
      Instruction.Constant := QWord(Int64(Reader.ReadS32));
    ikI64:
      Instruction.Constant := QWord(Reader.ReadS64);
    ikF32:
      Instruction.Constant := Reader.ReadF32Bits;
    ikF64:
      Instruction.Constant := Reader.ReadF64Bits;
    ikV128, ikShuffle:
      Reader.ReadRaw(@Instruction.Vector, 16);
    ikReferenceType:
      if wfFunctionReferences in Reader.Features then
        Instruction.ReferenceType := MakeReferenceType(Reader.ReadHeapType, True)
      else
      begin
        First := Reader.ReadByte;
        case First of
          $70: Instruction.ReferenceType := WasmFuncRefType;
          $6F: Instruction.ReferenceType := WasmExternRefType;
        else
          Reader.FailAt(Reader.Position - 1, 'malformed reference type');
        end;
      end;
    ikHeapType:
      Instruction.ReferenceType := MakeReferenceType(Reader.ReadHeapType,
        (Code = OpRefTestNull) or (Code = OpRefCastNull));
    ikBranchCast:
      begin
        Flags := Reader.ReadByte;
        if Flags > 3 then
          Reader.FailAt(Reader.Position - 1, 'malformed cast flags');
        Instruction.Index := Reader.ReadU32;
        Instruction.ReferenceType := MakeReferenceType(Reader.ReadHeapType, Flags and 1 <> 0);
        Instruction.TargetType := MakeReferenceType(Reader.ReadHeapType, Flags and 2 <> 0);
      end;
    ikDataMemory:
      begin
        Instruction.Index := Reader.ReadU32;
        Instruction.MemoryIndex := ReadMemoryIndex(Reader);
      end;
    ikMemoryMemory:
      begin
        Instruction.MemoryIndex := ReadMemoryIndex(Reader);
        Instruction.SecondIndex := ReadMemoryIndex(Reader);
      end;
    ikElementTable, ikTableTable:
      begin
        Instruction.Index := Reader.ReadU32;
        Instruction.SecondIndex := Reader.ReadU32;
      end;
    ikTryTable:
      begin
        ReadBlockType(Reader, Instruction.BlockType);
        Instruction.CatchCount := Reader.ReadU32;
        if Instruction.CatchCount > Reader.Remaining then
          Reader.Fail('unexpected end');
        if Cardinal(Length(Catches)) < Instruction.CatchCount then
          SetLength(Catches, Instruction.CatchCount);
        ReadCatchClauses(Reader, Catches, Instruction);
      end;
  end;
end;

procedure ReadCatchClauses(var Reader: TWasmReader; var Catches: array of TWasmCatchClause;
  var Instruction: TWasmInstruction);
var
  Index: Cardinal;
  Kind: Byte;
begin
  if Instruction.CatchCount = 0 then
    Exit;
  for Index := 0 to Instruction.CatchCount - 1 do
  begin
    Kind := Reader.ReadByte;
    if Kind > 3 then
      Reader.FailAt(Reader.Position - 1, 'malformed catch clause');
    Catches[Index].Kind := TWasmCatchKind(Kind);
    Catches[Index].Tag := 0;
    if Catches[Index].Kind in [ckCatch, ckCatchRef] then
      Catches[Index].Tag := Reader.ReadU32;
    Catches[Index].LabelIndex := Reader.ReadU32;
  end;
end;

end.
