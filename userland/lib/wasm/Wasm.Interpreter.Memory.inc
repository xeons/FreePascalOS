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

{ The interpreter's cases (Wasm.Interpreter.Execute): loads and stores.
  The effective address is the 32-bit operand plus the offset, computed
  in 64 bits, and the access must lie within the memory's length. }

OpI32Load:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PDWord(@S[P^.A])^ := PDWord(@MemoryBase[Address])^;
  end;
OpI64Load:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    S[P^.A] := PQWord(@MemoryBase[Address])^;
  end;
OpF32Load:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PDWord(@S[P^.A])^ := PDWord(@MemoryBase[Address])^;
  end;
OpF64Load:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    S[P^.A] := PQWord(@MemoryBase[Address])^;
  end;
OpI32Load8S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    PInt32(@S[P^.A])^ := PShortInt(@MemoryBase[Address])^;
  end;
OpI32Load8U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    PDWord(@S[P^.A])^ := MemoryBase[Address];
  end;
OpI32Load16S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    PInt32(@S[P^.A])^ := PSmallInt(@MemoryBase[Address])^;
  end;
OpI32Load16U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    PDWord(@S[P^.A])^ := PWord(@MemoryBase[Address])^;
  end;
OpI64Load8S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    PInt64(@S[P^.A])^ := PShortInt(@MemoryBase[Address])^;
  end;
OpI64Load8U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    S[P^.A] := MemoryBase[Address];
  end;
OpI64Load16S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    PInt64(@S[P^.A])^ := PSmallInt(@MemoryBase[Address])^;
  end;
OpI64Load16U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    S[P^.A] := PWord(@MemoryBase[Address])^;
  end;
OpI64Load32S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PInt64(@S[P^.A])^ := PInt32(@MemoryBase[Address])^;
  end;
OpI64Load32U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    S[P^.A] := PDWord(@MemoryBase[Address])^;
  end;
OpI32Store:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PDWord(@MemoryBase[Address])^ := PDWord(@S[P^.A])^;
  end;
OpI64Store:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    PQWord(@MemoryBase[Address])^ := S[P^.A];
  end;
OpF32Store:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PDWord(@MemoryBase[Address])^ := PDWord(@S[P^.A])^;
  end;
OpF64Store:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    PQWord(@MemoryBase[Address])^ := S[P^.A];
  end;
OpI32Store8:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    MemoryBase[Address] := Byte(S[P^.A]);
  end;
OpI32Store16:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    PWord(@MemoryBase[Address])^ := Word(S[P^.A]);
  end;
OpI64Store8:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    MemoryBase[Address] := Byte(S[P^.A]);
  end;
OpI64Store16:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    PWord(@MemoryBase[Address])^ := Word(S[P^.A]);
  end;
OpI64Store32:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    PDWord(@MemoryBase[Address])^ := DWord(S[P^.A]);
  end;
OpV128Load:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 16 > MemoryLength then
      goto OutOfBounds;
    U64A := PQWord(@MemoryBase[Address])^;
    S[P^.A + 1] := PQWord(@MemoryBase[Address + 8])^;
    S[P^.A] := U64A;
  end;
OpV128Store:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 16 > MemoryLength then
      goto OutOfBounds;
    PQWord(@MemoryBase[Address])^ := S[P^.A];
    PQWord(@MemoryBase[Address + 8])^ := S[P^.A + 1];
  end;
OpV128Load8x8S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load8x8U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load16x4S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load16x4U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load32x2S:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load32x2U:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load8Splat:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load16Splat:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load32Splat:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load64Splat:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load32Zero:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load64Zero:
  begin
    Address := QWord(PDWord(@S[P^.B])^) + QWord(DWord(P^.C));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLoad(P^.Operation, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load8Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load16Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load32Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Load64Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Store8Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 1 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Store16Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 2 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Store32Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 4 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
OpV128Store64Lane:
  begin
    Address := QWord(PDWord(@S[P^.A])^) + QWord(DWord(P^.B));
    if Address + 8 > MemoryLength then
      goto OutOfBounds;
    SimdLaneAccess(P^.Operation, P^.Extra, @MemoryBase[Address], @S[P^.A]);
  end;
