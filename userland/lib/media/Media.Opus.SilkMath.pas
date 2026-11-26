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

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  SILK's fixed-point arithmetic: the 16 x 32-bit multiplications with
  their Q16 shifts, rounding shifts, saturation, leading zero counts and
  the approximate division and inversion SILK's decoder is specified
  with. Each follows the reference macro of the same name (silk_SMULWB
  is SilkMulWB and so on); they must give the same bits.
}
unit Media.Opus.SilkMath;

{$mode objfpc}
{$H+}
{ The reference relies on two's complement 32-bit wraparound in places
  (the _ovflw macros): range and overflow checks are off here. }
{$R-}
{$Q-}

interface

const
  SilkInt16Max = 32767;
  SilkInt16Min = -32768;
  SilkInt32Max = High(LongInt);
  SilkInt32Min = Low(LongInt);

function SilkMulWB(A, B: LongInt): LongInt; inline;
function SilkMlaWB(A, B, C: LongInt): LongInt; inline;
function SilkMulWT(A, B: LongInt): LongInt; inline;
function SilkMlaWT(A, B, C: LongInt): LongInt; inline;
function SilkMulBB(A, B: LongInt): LongInt; inline;
function SilkMlaBB(A, B, C: LongInt): LongInt; inline;
function SilkMulBT(A, B: LongInt): LongInt; inline;
function SilkMlaBT(A, B, C: LongInt): LongInt; inline;
function SilkMulWW(A, B: LongInt): LongInt; inline;
function SilkMlaWW(A, B, C: LongInt): LongInt; inline;
function SilkMul(A, B: LongInt): LongInt; inline;
function SilkMla(A, B, C: LongInt): LongInt; inline;
function SilkSMMul(A, B: LongInt): LongInt; inline;
function SilkRShiftRound(A: LongInt; Shift: Integer): LongInt;
function SilkRShiftRound64(A: Int64; Shift: Integer): Int64;
function SilkSar(A: LongInt; Shift: Integer): LongInt; inline;
function SilkSar64(A: Int64; Shift: Integer): Int64; inline;
function SilkShl(A: LongInt; Shift: Integer): LongInt; inline;
function SilkSat16(A: LongInt): LongInt; inline;
function SilkLimit(A, Limit1, Limit2: LongInt): LongInt;
function SilkMin(A, B: LongInt): LongInt; inline;
function SilkMax(A, B: LongInt): LongInt; inline;
function SilkAbs(A: LongInt): LongInt; inline;
function SilkAddSat32(A, B: LongInt): LongInt; inline;
function SilkSubSat32(A, B: LongInt): LongInt; inline;
function SilkLShiftSat32(A: LongInt; Shift: Integer): LongInt; inline;
function SilkAddPosSat32(A, B: LongInt): LongInt; inline;
function SilkRand(Seed: LongInt): LongInt; inline;
function SilkClz32(A: LongInt): LongInt; inline;
function SilkClz64(A: Int64): LongInt; inline;
function SilkRor32(A: LongInt; Rotation: Integer): LongInt; inline;
procedure SilkClzFrac(A: LongInt; out LeadingZeros, FractionQ7: LongInt); inline;
function SilkSqrtApprox(X: LongInt): LongInt;
function SilkDiv32VarQ(A, B: LongInt; QResult: Integer): LongInt;
function SilkInverse32VarQ(B: LongInt; QResult: Integer): LongInt;
{ log2 and 2^x in Q7 (silk_lin2log, silk_log2lin). }
function SilkLinToLog(InLinear: LongInt): LongInt;
function SilkLogToLin(InLogQ7: LongInt): LongInt;

implementation

function SilkSar(A: LongInt; Shift: Integer): LongInt;
begin
  Result := SarLongint(A, Shift);
end;

function SilkSar64(A: Int64; Shift: Integer): Int64;
begin
  Result := SarInt64(A, Shift);
end;

function SilkShl(A: LongInt; Shift: Integer): LongInt;
begin
  Result := LongInt(LongWord(A) shl Shift);
end;

function SilkMulWB(A, B: LongInt): LongInt;
begin
  Result := LongInt(SarInt64(Int64(A) * SmallInt(B), 16));
end;

function SilkMlaWB(A, B, C: LongInt): LongInt;
begin
  Result := LongInt(Int64(A) + SarInt64(Int64(B) * SmallInt(C), 16));
end;

function SilkMulWT(A, B: LongInt): LongInt;
begin
  Result := LongInt(SarInt64(Int64(A) * SarLongint(B, 16), 16));
end;

function SilkMlaWT(A, B, C: LongInt): LongInt;
begin
  Result := LongInt(Int64(A) + SarInt64(Int64(B) * SarLongint(C, 16), 16));
end;

function SilkMulBB(A, B: LongInt): LongInt;
begin
  Result := LongInt(SmallInt(A)) * LongInt(SmallInt(B));
end;

function SilkMlaBB(A, B, C: LongInt): LongInt;
begin
  Result := A + LongInt(SmallInt(B)) * LongInt(SmallInt(C));
end;

function SilkMulBT(A, B: LongInt): LongInt;
begin
  Result := LongInt(SmallInt(A)) * SarLongint(B, 16);
end;

function SilkMlaBT(A, B, C: LongInt): LongInt;
begin
  Result := A + LongInt(SmallInt(B)) * SarLongint(C, 16);
end;

function SilkMulWW(A, B: LongInt): LongInt;
begin
  Result := LongInt(SarInt64(Int64(A) * B, 16));
end;

function SilkMlaWW(A, B, C: LongInt): LongInt;
begin
  Result := LongInt(Int64(A) + SarInt64(Int64(B) * C, 16));
end;

function SilkMul(A, B: LongInt): LongInt;
begin
  Result := LongInt(LongWord(A) * LongWord(B));
end;

function SilkMla(A, B, C: LongInt): LongInt;
begin
  Result := LongInt(LongWord(A) + LongWord(B) * LongWord(C));
end;

function SilkSMMul(A, B: LongInt): LongInt;
begin
  Result := LongInt(SarInt64(Int64(A) * B, 32));
end;

function SilkRShiftRound(A: LongInt; Shift: Integer): LongInt;
begin
  if Shift = 1 then
    Result := SarLongint(A, 1) + (A and 1)
  else
    Result := SarLongint(SarLongint(A, Shift - 1) + 1, 1);
end;

function SilkRShiftRound64(A: Int64; Shift: Integer): Int64;
begin
  if Shift = 1 then
    Result := SarInt64(A, 1) + (A and 1)
  else
    Result := SarInt64(SarInt64(A, Shift - 1) + 1, 1);
end;

function SilkSat16(A: LongInt): LongInt;
begin
  if A > SilkInt16Max then
    Result := SilkInt16Max
  else if A < SilkInt16Min then
    Result := SilkInt16Min
  else
    Result := A;
end;

function SilkLimit(A, Limit1, Limit2: LongInt): LongInt;
begin
  if Limit1 > Limit2 then
  begin
    if A > Limit1 then
      Result := Limit1
    else if A < Limit2 then
      Result := Limit2
    else
      Result := A;
  end
  else
  begin
    if A > Limit2 then
      Result := Limit2
    else if A < Limit1 then
      Result := Limit1
    else
      Result := A;
  end;
end;

function SilkMin(A, B: LongInt): LongInt;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

function SilkMax(A, B: LongInt): LongInt;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function SilkAbs(A: LongInt): LongInt;
begin
  if A > 0 then
    Result := A
  else
    Result := -A;
end;

function SilkAddSat32(A, B: LongInt): LongInt;
var
  Sum: LongWord;
begin
  Sum := LongWord(A) + LongWord(B);
  if (Sum and $80000000) = 0 then
  begin
    if (LongWord(A) and LongWord(B) and $80000000) <> 0 then
      Result := SilkInt32Min
    else
      Result := LongInt(Sum);
  end
  else
  begin
    if ((LongWord(A) or LongWord(B)) and $80000000) = 0 then
      Result := SilkInt32Max
    else
      Result := LongInt(Sum);
  end;
end;

function SilkSubSat32(A, B: LongInt): LongInt;
var
  Difference: LongWord;
begin
  Difference := LongWord(A) - LongWord(B);
  if (Difference and $80000000) = 0 then
  begin
    if (LongWord(A) and (LongWord(B) xor $80000000) and $80000000) <> 0 then
      Result := SilkInt32Min
    else
      Result := LongInt(Difference);
  end
  else
  begin
    if ((LongWord(A) xor $80000000) and LongWord(B) and $80000000) <> 0 then
      Result := SilkInt32Max
    else
      Result := LongInt(Difference);
  end;
end;

function SilkLShiftSat32(A: LongInt; Shift: Integer): LongInt;
begin
  Result := SilkShl(SilkLimit(A, SarLongint(SilkInt32Min, Shift), SarLongint(SilkInt32Max, Shift)), Shift);
end;

function SilkAddPosSat32(A, B: LongInt): LongInt;
begin
  if ((LongWord(A) + LongWord(B)) and $80000000) <> 0 then
    Result := SilkInt32Max
  else
    Result := A + B;
end;

function SilkRand(Seed: LongInt): LongInt;
begin
  Result := LongInt(LongWord(907633515) + LongWord(Seed) * LongWord(196314165));
end;

function SilkClz32(A: LongInt): LongInt;
begin
  if A = 0 then
    Result := 32
  else
    Result := 31 - BsrDWord(LongWord(A));
end;

function SilkClz64(A: Int64): LongInt;
var
  Upper: LongInt;
begin
  Upper := LongInt(SarInt64(A, 32));
  if Upper = 0 then
    Result := 32 + SilkClz32(LongInt(A))
  else
    Result := SilkClz32(Upper);
end;

function SilkRor32(A: LongInt; Rotation: Integer): LongInt;
var
  Value: LongWord;
  Amount: LongWord;
begin
  Value := LongWord(A);
  if Rotation = 0 then
    Result := A
  else if Rotation < 0 then
  begin
    Amount := -Rotation;
    Result := LongInt((Value shl Amount) or (Value shr (32 - Amount)));
  end
  else
  begin
    Amount := Rotation;
    Result := LongInt((Value shl (32 - Amount)) or (Value shr Amount));
  end;
end;

procedure SilkClzFrac(A: LongInt; out LeadingZeros, FractionQ7: LongInt);
begin
  LeadingZeros := SilkClz32(A);
  FractionQ7 := SilkRor32(A, 24 - LeadingZeros) and $7F;
end;

function SilkSqrtApprox(X: LongInt): LongInt;
var
  Y, LeadingZeros, FractionQ7: LongInt;
begin
  if X <= 0 then
    Exit(0);
  SilkClzFrac(X, LeadingZeros, FractionQ7);
  if (LeadingZeros and 1) <> 0 then
    Y := 32768
  else
    Y := 46214;
  Y := SarLongint(Y, SarLongint(LeadingZeros, 1));
  Y := SilkMlaWB(Y, Y, SilkMulBB(213, FractionQ7));
  Result := Y;
end;

function SilkDiv32VarQ(A, B: LongInt; QResult: Integer): LongInt;
var
  AHeadroom, BHeadroom, Shift: Integer;
  BInverse, ANormal, BNormal, Quotient: LongInt;
begin
  AHeadroom := SilkClz32(SilkAbs(A)) - 1;
  ANormal := SilkShl(A, AHeadroom);
  BHeadroom := SilkClz32(SilkAbs(B)) - 1;
  BNormal := SilkShl(B, BHeadroom);
  BInverse := (SilkInt32Max shr 2) div SmallInt(SarLongint(BNormal, 16));
  Quotient := SilkMulWB(ANormal, BInverse);
  ANormal := LongInt(LongWord(ANormal) - (LongWord(SilkSMMul(BNormal, Quotient)) shl 3));
  Quotient := SilkMlaWB(Quotient, ANormal, BInverse);
  Shift := 29 + AHeadroom - BHeadroom - QResult;
  if Shift < 0 then
    Result := SilkLShiftSat32(Quotient, -Shift)
  else if Shift < 32 then
    Result := SarLongint(Quotient, Shift)
  else
    Result := 0;
end;

function SilkInverse32VarQ(B: LongInt; QResult: Integer): LongInt;
var
  BHeadroom, Shift: Integer;
  BInverse, BNormal, ErrorQ32, Inverse: LongInt;
begin
  BHeadroom := SilkClz32(SilkAbs(B)) - 1;
  BNormal := SilkShl(B, BHeadroom);
  BInverse := (SilkInt32Max shr 2) div SmallInt(SarLongint(BNormal, 16));
  Inverse := SilkShl(BInverse, 16);
  ErrorQ32 := SilkShl((LongInt(1) shl 29) - SilkMulWB(BNormal, BInverse), 3);
  Inverse := SilkMlaWW(Inverse, ErrorQ32, BInverse);
  Shift := 61 - BHeadroom - QResult;
  if Shift <= 0 then
    Result := SilkLShiftSat32(Inverse, -Shift)
  else if Shift < 32 then
    Result := SarLongint(Inverse, Shift)
  else
    Result := 0;
end;

function SilkLinToLog(InLinear: LongInt): LongInt;
var
  LeadingZeros, FractionQ7: LongInt;
begin
  SilkClzFrac(InLinear, LeadingZeros, FractionQ7);
  Result := SilkMlaWB(FractionQ7, SilkMul(FractionQ7, 128 - FractionQ7), 179) + SilkShl(31 - LeadingZeros, 7);
end;

function SilkLogToLin(InLogQ7: LongInt): LongInt;
var
  Output, FractionQ7: LongInt;
begin
  if InLogQ7 < 0 then
    Exit(0);
  if InLogQ7 >= 3967 then
    Exit(SilkInt32Max);
  Output := SilkShl(1, SarLongint(InLogQ7, 7));
  FractionQ7 := InLogQ7 and $7F;
  if InLogQ7 < 2048 then
    Output := Output + SarLongint(Output * SilkMlaWB(FractionQ7, SilkMulBB(FractionQ7, 128 - FractionQ7), -174), 7)
  else
    Output := SilkMla(Output, SarLongint(Output, 7), SilkMlaWB(FractionQ7, SilkMulBB(FractionQ7, 128 - FractionQ7), -174));
  Result := Output;
end;

end.
