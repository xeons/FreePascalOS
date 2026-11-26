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

  Memory instructions carry a memory index (always 0 in WebAssembly 2.0,
  whose encoding has a zero byte or nothing there) and a 64-bit offset,
  which is what multiple memories and memory64 need.
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
  Wasm.Reader;

type
  TWasmBlockTypeKind = (btEmpty, btValue, btTypeIndex);

  TWasmBlockType = record
    Kind: TWasmBlockTypeKind;
    ValueType: TWasmValueType;
    TypeIndex: Cardinal;
  end;

  TWasmInstruction = record
    Opcode: Integer;
    Offset: SizeInt;           { of the opcode, from the module's start }
    { The main index: label, function, local, global, table, type (of
      call_indirect), data or element segment, and lane. }
    Index: Cardinal;
    { The second index: the table of call_indirect and table.init, the
      source table of table.copy, the memory of memory.init, the source
      memory of memory.copy. }
    SecondIndex: Cardinal;
    MemoryIndex: Cardinal;
    Alignment: Cardinal;       { log2, as encoded }
    MemoryOffset: QWord;
    Lane: Byte;
    BlockType: TWasmBlockType;
    Constant: QWord;           { i32 / i64 values, f32 / f64 bits }
    Vector: TWasmV128;         { v128.const, i8x16.shuffle's lanes }
    ReferenceType: TWasmValueType;   { ref.null }
    SelectTypeCount: Cardinal;
    SelectType: TWasmValueType;
    LabelCount: Cardinal;      { br_table: Labels[0..LabelCount), default in Index }
  end;

  TWasmInstructionReader = record
    Reader: TWasmReader;
    Labels: array of Cardinal; { br_table's labels of the last instruction }
    procedure Initialize(Bytes: PByte; Start, Limit: SizeInt);
    function AtEnd: Boolean; inline;
    procedure Next(out Instruction: TWasmInstruction);
  end;

implementation

uses
  Wasm.Opcodes,
  Wasm.Limits;

procedure TWasmInstructionReader.Initialize(Bytes: PByte; Start, Limit: SizeInt);
begin
  Reader.Initialize(Bytes, Start, Limit);
end;

function TWasmInstructionReader.AtEnd: Boolean;
begin
  Result := Reader.AtEnd;
end;

procedure ReadBlockType(var Reader: TWasmReader; out BlockType: TWasmBlockType);
var
  First: Byte;
  Index: Int64;
begin
  First := Reader.PeekByte;
  BlockType.TypeIndex := 0;
  BlockType.ValueType := WasmI32Type;
  if First = $40 then
  begin
    Reader.ReadByte;
    BlockType.Kind := btEmpty;
  end
  else if DecodeValueType(First, BlockType.ValueType) then
  begin
    Reader.ReadByte;
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
begin
  Instruction.Alignment := Reader.ReadU32;
  Instruction.MemoryIndex := 0;
  Instruction.MemoryOffset := Reader.ReadU32;
end;

procedure ReadZeroByte(var Reader: TWasmReader);
begin
  if Reader.ReadByte <> 0 then
    Reader.FailAt(Reader.Position - 1, 'zero byte expected');
end;

procedure TWasmInstructionReader.Next(out Instruction: TWasmInstruction);
var
  Code: Cardinal;
  Index: Cardinal;
  First: Byte;
begin
  Instruction.Offset := Reader.Position;
  Instruction.Index := 0;
  Instruction.SecondIndex := 0;
  Instruction.MemoryIndex := 0;
  Instruction.LabelCount := 0;
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
    if Code > $FF then
      Reader.FailAt(Instruction.Offset, 'illegal opcode');
    Code := $200 + Code;
  end
  else
    Code := First;
  if not IsWasmOpcode(Code) then
    Reader.FailAt(Instruction.Offset, 'illegal opcode ' + WasmOpcodeName(Code));
  Instruction.Opcode := Code;
  case WasmOpcodeTable[Code].Immediate of
    ikNone: ;
    ikBlockType:
      ReadBlockType(Reader, Instruction.BlockType);
    ikLabel, ikFunction, ikLocal, ikGlobal, ikTable, ikData, ikElement:
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
    ikCallIndirect:
      begin
        Instruction.Index := Reader.ReadU32;
        Instruction.SecondIndex := Reader.ReadU32;
      end;
    ikMemory:
      ReadZeroByte(Reader);
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
          begin
            First := Reader.ReadByte;
            if not DecodeValueType(First, Instruction.SelectType) then
              Reader.FailAt(Reader.Position - 1, 'malformed value type');
          end;
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
      begin
        First := Reader.ReadByte;
        case First of
          $70: Instruction.ReferenceType := WasmFuncRefType;
          $6F: Instruction.ReferenceType := WasmExternRefType;
        else
          Reader.FailAt(Reader.Position - 1, 'malformed reference type');
        end;
      end;
    ikDataMemory:
      begin
        Instruction.Index := Reader.ReadU32;
        ReadZeroByte(Reader);
      end;
    ikMemoryMemory:
      begin
        ReadZeroByte(Reader);
        ReadZeroByte(Reader);
      end;
    ikElementTable, ikTableTable:
      begin
        Instruction.Index := Reader.ReadU32;
        Instruction.SecondIndex := Reader.ReadU32;
      end;
  end;
end;

end.
