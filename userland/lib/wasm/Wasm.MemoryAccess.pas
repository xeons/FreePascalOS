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
  Memory instructions on any memory: multiple memories and memory64.

  The interpreter does loads and stores of an i32 memory 0 itself, with
  the memory's address and length in registers; every other memory
  access comes here (the compiled forms CodeMemoryAccessAt and the
  CodeMemory...At bulk instructions of Wasm.Code). Addresses are 32 or
  64 bits by the memory's address type; the access must lie in the
  memory, checked without overflow however large address and offset
  are. memory.copy between memories takes each operand by its memory's
  address type and the count by the smaller one.
}
unit Wasm.MemoryAccess;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

uses
  Wasm.Code,
  Wasm.Runtime;

{ Executes one of the ...At operations; NoTrap (-1) or the trap kind. }
function ExecuteMemoryAt(Instance: TWasmModuleInstance; const Instruction: TCodeInstruction; Slots: PQWord;
  Constants: PQWord): Integer;

{ Whether Size bytes at Address + Offset lie within Length bytes;
  Effective is where they start. }
function AccessInBounds(Address, Offset, Size, Length: QWord; out Effective: QWord): Boolean; inline;

implementation

uses
  Wasm.Types,
  Wasm.Errors,
  Wasm.Opcodes,
  Wasm.Simd;

const
  NoTrap = -1;

function AccessInBounds(Address, Offset, Size, Length: QWord; out Effective: QWord): Boolean;
begin
  Effective := 0;
  if (Address > Length) or (Offset > Length - Address) then
    Exit(False);
  Effective := Address + Offset;
  Result := Size <= Length - Effective;
end;

function AddressOf(Memory: TWasmMemory; Slot: PQWord): QWord; inline;
begin
  if Memory.Is64 then
    Result := Slot^
  else
    Result := PDWord(Slot)^;
end;

function AccessSize(Opcode: Integer): Integer;
begin
  case Opcode of
    OpI32Load8S, OpI32Load8U, OpI64Load8S, OpI64Load8U, OpI32Store8, OpI64Store8,
    OpV128Load8Splat, OpV128Load8Lane, OpV128Store8Lane:
      Result := 1;
    OpI32Load16S, OpI32Load16U, OpI64Load16S, OpI64Load16U, OpI32Store16, OpI64Store16,
    OpV128Load16Splat, OpV128Load16Lane, OpV128Store16Lane:
      Result := 2;
    OpI32Load, OpF32Load, OpI64Load32S, OpI64Load32U, OpI32Store, OpF32Store, OpI64Store32,
    OpV128Load32Splat, OpV128Load32Zero, OpV128Load32Lane, OpV128Store32Lane:
      Result := 4;
    OpV128Load, OpV128Store:
      Result := 16;
  else
    Result := 8;
  end;
end;

function IsLaneAccess(Opcode: Integer): Boolean; inline;
begin
  Result := (Opcode >= OpV128Load8Lane) and (Opcode <= OpV128Store64Lane);
end;

function LoadOrStore(Instance: TWasmModuleInstance; const Instruction: TCodeInstruction; Slots: PQWord;
  Constants: PQWord): Integer;
var
  Memory: TWasmMemory;
  Opcode: Integer;
  Address, Effective: QWord;
  At: PByte;
  Value: PQWord;
  Lane: Integer;
begin
  Opcode := Instruction.Extra;
  Memory := Instance.Memories[DWord(Constants[Instruction.C + 1])];
  if IsLaneAccess(Opcode) then
  begin
    Address := AddressOf(Memory, @Slots[Instruction.A]);
    Lane := Constants[Instruction.C + 1] shr 32;
  end
  else
  begin
    Address := AddressOf(Memory, @Slots[Instruction.B]);
    Lane := 0;
  end;
  if not AccessInBounds(Address, Constants[Instruction.C], AccessSize(Opcode), Memory.ByteLength, Effective) then
    Exit(Ord(tkMemoryOutOfBounds));
  At := Memory.Data + Effective;
  Value := @Slots[Instruction.A];
  Result := NoTrap;
  case Opcode of
    OpI32Load, OpF32Load: PDWord(Value)^ := PDWord(At)^;
    OpI64Load, OpF64Load: Value^ := PQWord(At)^;
    OpI32Load8S: PInt32(Value)^ := PShortInt(At)^;
    OpI32Load8U: PDWord(Value)^ := At^;
    OpI32Load16S: PInt32(Value)^ := PSmallInt(At)^;
    OpI32Load16U: PDWord(Value)^ := PWord(At)^;
    OpI64Load8S: PInt64(Value)^ := PShortInt(At)^;
    OpI64Load8U: Value^ := At^;
    OpI64Load16S: PInt64(Value)^ := PSmallInt(At)^;
    OpI64Load16U: Value^ := PWord(At)^;
    OpI64Load32S: PInt64(Value)^ := PInt32(At)^;
    OpI64Load32U: Value^ := PDWord(At)^;
    OpI32Store, OpF32Store, OpI64Store32: PDWord(At)^ := DWord(Value^);
    OpI64Store, OpF64Store: PQWord(At)^ := Value^;
    OpI32Store8, OpI64Store8: At^ := Byte(Value^);
    OpI32Store16, OpI64Store16: PWord(At)^ := Word(Value^);
    OpV128Load:
      begin
        Value[0] := PQWord(At)^;
        Value[1] := PQWord(At + 8)^;
      end;
    OpV128Store:
      begin
        PQWord(At)^ := Value[0];
        PQWord(At + 8)^ := Value[1];
      end;
  else
    if IsLaneAccess(Opcode) then
      SimdLaneAccess(Opcode, Lane, At, @Slots[Instruction.A])
    else
      SimdLoad(Opcode, At, Value);
  end;
end;

function ExecuteMemoryAt(Instance: TWasmModuleInstance; const Instruction: TCodeInstruction; Slots: PQWord;
  Constants: PQWord): Integer;
var
  Memory, Source: TWasmMemory;
  Destination, From, Count, Effective, Available: QWord;
  Grown: Int64;
  Segment: Integer;
begin
  Result := NoTrap;
  case Instruction.Operation of
    CodeMemoryAccessAt:
      Result := LoadOrStore(Instance, Instruction, Slots, Constants);
    CodeMemorySizeAt:
      begin
        Memory := Instance.Memories[Instruction.Extra];
        if Memory.Is64 then
          Slots[Instruction.A] := Memory.PageCount
        else
          PDWord(@Slots[Instruction.A])^ := DWord(Memory.PageCount);
      end;
    CodeMemoryGrowAt:
      begin
        Memory := Instance.Memories[Instruction.Extra];
        Grown := Memory.Grow(AddressOf(Memory, @Slots[Instruction.B]));
        if Memory.Is64 then
          PInt64(@Slots[Instruction.A])^ := Grown
        else
          PInt32(@Slots[Instruction.A])^ := Int32(Grown);
      end;
    CodeMemoryFillAt:
      begin
        Memory := Instance.Memories[Instruction.Extra];
        Destination := AddressOf(Memory, @Slots[Instruction.A]);
        Count := AddressOf(Memory, @Slots[Instruction.A + 2]);
        if not AccessInBounds(Destination, 0, Count, Memory.ByteLength, Effective) then
          Exit(Ord(tkMemoryOutOfBounds));
        if Count > 0 then
          FillChar(Memory.Data[Effective], Count, Byte(Slots[Instruction.A + 1]));
      end;
    CodeMemoryCopyAt:
      begin
        Memory := Instance.Memories[Instruction.B];
        Source := Instance.Memories[Instruction.C];
        Destination := AddressOf(Memory, @Slots[Instruction.A]);
        From := AddressOf(Source, @Slots[Instruction.A + 1]);
        if Memory.Is64 and Source.Is64 then
          Count := Slots[Instruction.A + 2]
        else
          Count := PDWord(@Slots[Instruction.A + 2])^;
        if not AccessInBounds(From, 0, Count, Source.ByteLength, Effective) or
          not AccessInBounds(Destination, 0, Count, Memory.ByteLength, Effective) then
          Exit(Ord(tkMemoryOutOfBounds));
        if Count > 0 then
          Move(Source.Data[From], Memory.Data[Destination], Count);
      end;
    CodeMemoryInitAt:
      begin
        Memory := Instance.Memories[Instruction.Extra];
        Segment := Instruction.B;
        Destination := AddressOf(Memory, @Slots[Instruction.A]);
        From := PDWord(@Slots[Instruction.A + 1])^;
        Count := PDWord(@Slots[Instruction.A + 2])^;
        if Instance.DataDropped[Segment] then
          Available := 0
        else
          Available := Instance.Module.Data[Segment].DataLength;
        if not AccessInBounds(From, 0, Count, Available, Effective) or
          not AccessInBounds(Destination, 0, Count, Memory.ByteLength, Effective) then
          Exit(Ord(tkMemoryOutOfBounds));
        if Count > 0 then
          Move(Instance.Module.Bytes[Instance.Module.Data[Segment].DataStart + SizeInt(From)],
            Memory.Data[Destination], Count);
      end;
  end;
end;

end.
