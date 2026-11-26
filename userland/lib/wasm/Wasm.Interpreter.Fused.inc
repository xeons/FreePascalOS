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

{ The interpreter's cases (Wasm.Interpreter.Execute): the compiled form's
  fused operations, i32 and i64 operations with an immediate and
  compare-and-branch. }

CodeI32AddImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ + DWord(P^.C);
CodeI32AndImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ and DWord(P^.C);
CodeI32OrImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ or DWord(P^.C);
CodeI32XorImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ xor DWord(P^.C);
CodeI32MulImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ * DWord(P^.C);
CodeI32ShlImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ shl (DWord(P^.C) and 31);
CodeI32ShrSImmediate:
  PInt32(@S[P^.A])^ := SarLongint(PInt32(@S[P^.B])^, DWord(P^.C) and 31);
CodeI32ShrUImmediate:
  PDWord(@S[P^.A])^ := PDWord(@S[P^.B])^ shr (DWord(P^.C) and 31);
CodeI32EqImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ = P^.C);
CodeI32NeImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ <> P^.C);
CodeI32LtSImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ < P^.C);
CodeI32LtUImmediate:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ < DWord(P^.C));
CodeI32GtSImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ > P^.C);
CodeI32GtUImmediate:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ > DWord(P^.C));
CodeI32LeSImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ <= P^.C);
CodeI32LeUImmediate:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ <= DWord(P^.C));
CodeI32GeSImmediate:
  PDWord(@S[P^.A])^ := Ord(PInt32(@S[P^.B])^ >= P^.C);
CodeI32GeUImmediate:
  PDWord(@S[P^.A])^ := Ord(PDWord(@S[P^.B])^ >= DWord(P^.C));
CodeI64AddImmediate:
  S[P^.A] := S[P^.B] + QWord(Int64(P^.C));
CodeI64AndImmediate:
  S[P^.A] := S[P^.B] and QWord(Int64(P^.C));
CodeI64ShlImmediate:
  S[P^.A] := S[P^.B] shl (P^.C and 63);
CodeI64ShrUImmediate:
  S[P^.A] := S[P^.B] shr (P^.C and 63);
CodeI64ShrSImmediate:
  PInt64(@S[P^.A])^ := SarInt64(PInt64(@S[P^.B])^, P^.C and 63);
CodeBranchIfI32Eqz:
  if PDWord(@S[P^.B])^ = 0 then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32Eq:
  if PDWord(@S[P^.B])^ = PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32Ne:
  if PDWord(@S[P^.B])^ <> PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32LtS:
  if PInt32(@S[P^.B])^ < PInt32(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32LtU:
  if PDWord(@S[P^.B])^ < PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32GtS:
  if PInt32(@S[P^.B])^ > PInt32(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32GtU:
  if PDWord(@S[P^.B])^ > PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32LeS:
  if PInt32(@S[P^.B])^ <= PInt32(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32LeU:
  if PDWord(@S[P^.B])^ <= PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32GeS:
  if PInt32(@S[P^.B])^ >= PInt32(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfI32GeU:
  if PDWord(@S[P^.B])^ >= PDWord(@S[P^.C])^ then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
