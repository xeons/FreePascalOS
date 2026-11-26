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

{ The interpreter's cases (Wasm.Interpreter.Execute): floating point
  operations and conversions. Sign operations work on the bits, so they
  leave NaN payloads alone; arithmetic is done in the value's own
  precision. }

OpF32Eq:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ = PSingle(@S[P^.C])^);
OpF32Ne:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ <> PSingle(@S[P^.C])^);
OpF32Lt:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ < PSingle(@S[P^.C])^);
OpF32Gt:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ > PSingle(@S[P^.C])^);
OpF32Le:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ <= PSingle(@S[P^.C])^);
OpF32Ge:
  PDWord(@S[P^.A])^ := Ord(PSingle(@S[P^.B])^ >= PSingle(@S[P^.C])^);
OpF32Abs:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ and $7FFFFFFF;
OpF32Neg:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ xor $80000000;
OpF32Copysign:
  PDWord(@S[P^.A])^ := (PDWord(@S[P^.B])^ and $7FFFFFFF) or (PDWord(@S[P^.C])^ and $80000000);
OpF32Ceil:
  PDWord(@S[P^.A])^ := F32Ceil(PDWord(@S[P^.B])^);
OpF32Floor:
  PDWord(@S[P^.A])^ := F32Floor(PDWord(@S[P^.B])^);
OpF32Trunc:
  PDWord(@S[P^.A])^ := F32Trunc(PDWord(@S[P^.B])^);
OpF32Nearest:
  PDWord(@S[P^.A])^ := F32Nearest(PDWord(@S[P^.B])^);
OpF32Sqrt:
  PSingle(@S[P^.A])^ := Sqrt(PSingle(@S[P^.B])^);
OpF32Add:
  PSingle(@S[P^.A])^ := PSingle(@S[P^.B])^ + PSingle(@S[P^.C])^;
OpF32Sub:
  PSingle(@S[P^.A])^ := PSingle(@S[P^.B])^ - PSingle(@S[P^.C])^;
OpF32Mul:
  PSingle(@S[P^.A])^ := PSingle(@S[P^.B])^ * PSingle(@S[P^.C])^;
OpF32Div:
  PSingle(@S[P^.A])^ := PSingle(@S[P^.B])^ / PSingle(@S[P^.C])^;
OpF32Min:
  PDWord(@S[P^.A])^ := F32Min(PDWord(@S[P^.B])^, PDWord(@S[P^.C])^);
OpF32Max:
  PDWord(@S[P^.A])^ := F32Max(PDWord(@S[P^.B])^, PDWord(@S[P^.C])^);
OpF64Eq:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ = PDouble(@S[P^.C])^);
OpF64Ne:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ <> PDouble(@S[P^.C])^);
OpF64Lt:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ < PDouble(@S[P^.C])^);
OpF64Gt:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ > PDouble(@S[P^.C])^);
OpF64Le:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ <= PDouble(@S[P^.C])^);
OpF64Ge:
  PDWord(@S[P^.A])^ := Ord(PDouble(@S[P^.B])^ >= PDouble(@S[P^.C])^);
OpF64Abs:
  S[P^.A] := S[P^.B] and QWord($7FFFFFFFFFFFFFFF);
OpF64Neg:
  S[P^.A] := S[P^.B] xor QWord($8000000000000000);
OpF64Copysign:
  S[P^.A] := (S[P^.B] and QWord($7FFFFFFFFFFFFFFF)) or (S[P^.C] and QWord($8000000000000000));
OpF64Ceil:
  S[P^.A] := F64Ceil(S[P^.B]);
OpF64Floor:
  S[P^.A] := F64Floor(S[P^.B]);
OpF64Trunc:
  S[P^.A] := F64Trunc(S[P^.B]);
OpF64Nearest:
  S[P^.A] := F64Nearest(S[P^.B]);
OpF64Sqrt:
  PDouble(@S[P^.A])^ := Sqrt(PDouble(@S[P^.B])^);
OpF64Add:
  PDouble(@S[P^.A])^ := PDouble(@S[P^.B])^ + PDouble(@S[P^.C])^;
OpF64Sub:
  PDouble(@S[P^.A])^ := PDouble(@S[P^.B])^ - PDouble(@S[P^.C])^;
OpF64Mul:
  PDouble(@S[P^.A])^ := PDouble(@S[P^.B])^ * PDouble(@S[P^.C])^;
OpF64Div:
  PDouble(@S[P^.A])^ := PDouble(@S[P^.B])^ / PDouble(@S[P^.C])^;
OpF64Min:
  S[P^.A] := F64Min(S[P^.B], S[P^.C]);
OpF64Max:
  S[P^.A] := F64Max(S[P^.B], S[P^.C]);
OpI32TruncF32S:
  begin
    case TruncateToI32(PSingle(@S[P^.B])^, I32A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PInt32(@S[P^.A])^ := I32A;
  end;
OpI32TruncF32U:
  begin
    case TruncateToU32(PSingle(@S[P^.B])^, U32A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PDWord(@S[P^.A])^ := U32A;
  end;
OpI64TruncF32S:
  begin
    case TruncateToI64(PSingle(@S[P^.B])^, I64A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PInt64(@S[P^.A])^ := I64A;
  end;
OpI64TruncF32U:
  begin
    case TruncateToU64(PSingle(@S[P^.B])^, U64A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    S[P^.A] := U64A;
  end;
OpI32TruncSatF32S:
  PInt32(@S[P^.A])^ := SaturateToI32(PSingle(@S[P^.B])^);
OpI32TruncSatF32U:
  PDWord(@S[P^.A])^ := SaturateToU32(PSingle(@S[P^.B])^);
OpI64TruncSatF32S:
  PInt64(@S[P^.A])^ := SaturateToI64(PSingle(@S[P^.B])^);
OpI64TruncSatF32U:
  S[P^.A] := SaturateToU64(PSingle(@S[P^.B])^);
OpI32TruncF64S:
  begin
    case TruncateToI32(PDouble(@S[P^.B])^, I32A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PInt32(@S[P^.A])^ := I32A;
  end;
OpI32TruncF64U:
  begin
    case TruncateToU32(PDouble(@S[P^.B])^, U32A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PDWord(@S[P^.A])^ := U32A;
  end;
OpI64TruncF64S:
  begin
    case TruncateToI64(PDouble(@S[P^.B])^, I64A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    PInt64(@S[P^.A])^ := I64A;
  end;
OpI64TruncF64U:
  begin
    case TruncateToU64(PDouble(@S[P^.B])^, U64A) of
      crNotANumber:
        begin
          TrapKind := tkInvalidConversion;
          goto Trapped;
        end;
      crOverflow:
        begin
          TrapKind := tkIntegerOverflow;
          goto Trapped;
        end;
    end;
    S[P^.A] := U64A;
  end;
OpI32TruncSatF64S:
  PInt32(@S[P^.A])^ := SaturateToI32(PDouble(@S[P^.B])^);
OpI32TruncSatF64U:
  PDWord(@S[P^.A])^ := SaturateToU32(PDouble(@S[P^.B])^);
OpI64TruncSatF64S:
  PInt64(@S[P^.A])^ := SaturateToI64(PDouble(@S[P^.B])^);
OpI64TruncSatF64U:
  S[P^.A] := SaturateToU64(PDouble(@S[P^.B])^);
OpF32ConvertI32S:
  PSingle(@S[P^.A])^ := PInt32(@S[P^.B])^;
OpF32ConvertI32U:
  PSingle(@S[P^.A])^ := U32ToF32(PDWord(@S[P^.B])^);
OpF32ConvertI64S:
  PSingle(@S[P^.A])^ := I64ToF32(PInt64(@S[P^.B])^);
OpF32ConvertI64U:
  PSingle(@S[P^.A])^ := U64ToF32(S[P^.B]);
OpF32DemoteF64:
  PSingle(@S[P^.A])^ := PDouble(@S[P^.B])^;
OpF64ConvertI32S:
  PDouble(@S[P^.A])^ := PInt32(@S[P^.B])^;
OpF64ConvertI32U:
  PDouble(@S[P^.A])^ := Int64(PDWord(@S[P^.B])^);
OpF64ConvertI64S:
  PDouble(@S[P^.A])^ := PInt64(@S[P^.B])^;
OpF64ConvertI64U:
  PDouble(@S[P^.A])^ := U64ToF64(S[P^.B]);
OpF64PromoteF32:
  PDouble(@S[P^.A])^ := PSingle(@S[P^.B])^;
OpI32ReinterpretF32, OpI64ReinterpretF64, OpF32ReinterpretI32, OpF64ReinterpretI64:
  S[P^.A] := S[P^.B];
