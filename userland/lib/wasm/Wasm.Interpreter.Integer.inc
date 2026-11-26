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

{ The interpreter's cases (Wasm.Interpreter.Execute): integer operations.
  Shift counts are taken modulo the width, as the spec says (Pascal's
  shifts leave that to the processor). }

OpI32Eqz:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ = 0);
OpI32Eq:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ = PDWord(@S[P^.C])^);
OpI32Ne:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ <> PDWord(@S[P^.C])^);
OpI32LtS:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ < PInt32(@S[P^.C])^);
OpI32LtU:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ < PDWord(@S[P^.C])^);
OpI32GtS:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ > PInt32(@S[P^.C])^);
OpI32GtU:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ > PDWord(@S[P^.C])^);
OpI32LeS:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ <= PInt32(@S[P^.C])^);
OpI32LeU:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ <= PDWord(@S[P^.C])^);
OpI32GeS:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ >= PInt32(@S[P^.C])^);
OpI32GeU:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ >= PDWord(@S[P^.C])^);
OpI32Clz:
  PDWord(@S[P^.A])^ := CountLeadingZeros32(PDWord(@S[P^.B])^);
OpI32Ctz:
  PDWord(@S[P^.A])^ := CountTrailingZeros32(PDWord(@S[P^.B])^);
OpI32Popcnt:
  PDWord(@S[P^.A])^ := PopCnt(PDWord(@S[P^.B])^);
OpI32Add:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ + PDWord(@S[P^.C])^;
OpI32Sub:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ - PDWord(@S[P^.C])^;
OpI32Mul:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ * PDWord(@S[P^.C])^;
OpI32And:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ and PDWord(@S[P^.C])^;
OpI32Or:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ or PDWord(@S[P^.C])^;
OpI32Xor:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ xor PDWord(@S[P^.C])^;
OpI32DivS:
  begin
    if PInt32(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    if (PInt32(@S[P^.B])^ = Low(Int32)) and (PInt32(@S[P^.C])^ = -1) then
    begin
      TrapKind := tkIntegerOverflow;
      goto Trapped;
    end;
    PInt32(@S[P^.A])^ := PInt32(@S[P^.B])^ div PInt32(@S[P^.C])^;
  end;
OpI32DivU:
  begin
    if PDWord(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ div PDWord(@S[P^.C])^;
  end;
OpI32RemS:
  begin
    if PInt32(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    if PInt32(@S[P^.C])^ = -1 then
      PInt32(@S[P^.A])^ := 0
    else
      PInt32(@S[P^.A])^ := PInt32(@S[P^.B])^ mod PInt32(@S[P^.C])^;
  end;
OpI32RemU:
  begin
    if PDWord(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ mod PDWord(@S[P^.C])^;
  end;
OpI32Shl:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ shl (PDWord(@S[P^.C])^ and 31);
OpI32ShrS:
  PInt32(@S[P^.A])^ := SarLongint(PInt32(@S[P^.B])^, PDWord(@S[P^.C])^ and 31);
OpI32ShrU:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ shr (PDWord(@S[P^.C])^ and 31);
OpI32Rotl:
  PDWord(@S[P^.A])^ := RotateLeft32(PDWord(@S[P^.B])^, PDWord(@S[P^.C])^);
OpI32Rotr:
  PDWord(@S[P^.A])^ := RotateRight32(PDWord(@S[P^.B])^, PDWord(@S[P^.C])^);
OpI64Eqz:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] = 0);
OpI64Eq:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] = S[P^.C]);
OpI64Ne:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] <> S[P^.C]);
OpI64LtS:
  PDWord(@S[P^.A])^ := Ord(PInt64(@S[P^.B])^ < PInt64(@S[P^.C])^);
OpI64LtU:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] < S[P^.C]);
OpI64GtS:
  PDWord(@S[P^.A])^ := Ord(PInt64(@S[P^.B])^ > PInt64(@S[P^.C])^);
OpI64GtU:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] > S[P^.C]);
OpI64LeS:
  PDWord(@S[P^.A])^ := Ord(PInt64(@S[P^.B])^ <= PInt64(@S[P^.C])^);
OpI64LeU:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] <= S[P^.C]);
OpI64GeS:
  PDWord(@S[P^.A])^ := Ord(PInt64(@S[P^.B])^ >= PInt64(@S[P^.C])^);
OpI64GeU:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] >= S[P^.C]);
OpI64Clz:
  S[P^.A] := CountLeadingZeros64(S[P^.B]);
OpI64Ctz:
  S[P^.A] := CountTrailingZeros64(S[P^.B]);
OpI64Popcnt:
  S[P^.A] := PopCnt(S[P^.B]);
OpI64Add:
  S[P^.A] := S[P^.B] + S[P^.C];
OpI64Sub:
  S[P^.A] := S[P^.B] - S[P^.C];
OpI64Mul:
  S[P^.A] := S[P^.B] * S[P^.C];
OpI64And:
  S[P^.A] := S[P^.B] and S[P^.C];
OpI64Or:
  S[P^.A] := S[P^.B] or S[P^.C];
OpI64Xor:
  S[P^.A] := S[P^.B] xor S[P^.C];
OpI64DivS:
  begin
    if PInt64(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    if (PInt64(@S[P^.B])^ = Low(Int64)) and (PInt64(@S[P^.C])^ = -1) then
    begin
      TrapKind := tkIntegerOverflow;
      goto Trapped;
    end;
    PInt64(@S[P^.A])^ := PInt64(@S[P^.B])^ div PInt64(@S[P^.C])^;
  end;
OpI64DivU:
  begin
    if S[P^.C] = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    S[P^.A] := S[P^.B] div S[P^.C];
  end;
OpI64RemS:
  begin
    if PInt64(@S[P^.C])^ = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    if PInt64(@S[P^.C])^ = -1 then
      PInt64(@S[P^.A])^ := 0
    else
      PInt64(@S[P^.A])^ := PInt64(@S[P^.B])^ mod PInt64(@S[P^.C])^;
  end;
OpI64RemU:
  begin
    if S[P^.C] = 0 then
    begin
      TrapKind := tkIntegerDivideByZero;
      goto Trapped;
    end;
    S[P^.A] := S[P^.B] mod S[P^.C];
  end;
OpI64Shl:
  S[P^.A] := S[P^.B] shl (S[P^.C] and 63);
OpI64ShrS:
  PInt64(@S[P^.A])^ := SarInt64(PInt64(@S[P^.B])^, S[P^.C] and 63);
OpI64ShrU:
  S[P^.A] := S[P^.B] shr (S[P^.C] and 63);
OpI64Rotl:
  S[P^.A] := RotateLeft64(S[P^.B], S[P^.C]);
OpI64Rotr:
  S[P^.A] := RotateRight64(S[P^.B], S[P^.C]);
OpI32WrapI64:
  PDWord(@S[P^.A])^ := DWord(S[P^.B]);
OpI64ExtendI32S:
  PInt64(@S[P^.A])^ := PInt32(@S[P^.B])^;
OpI64ExtendI32U:
  S[P^.A] := PDWord(@S[P^.B])^;
OpI32Extend8S:
  PInt32(@S[P^.A])^ := ShortInt(PDWord(@S[P^.B])^);
OpI32Extend16S:
  PInt32(@S[P^.A])^ := SmallInt(PDWord(@S[P^.B])^);
OpI64Extend8S:
  PInt64(@S[P^.A])^ := ShortInt(S[P^.B]);
OpI64Extend16S:
  PInt64(@S[P^.A])^ := SmallInt(S[P^.B]);
OpI64Extend32S:
  PInt64(@S[P^.A])^ := Int32(S[P^.B]);
