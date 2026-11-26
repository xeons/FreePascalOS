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
  The fixed-width SIMD operations (spec 2.0, the 0xFD instructions) on
  v128 values, lane by lane in portable Pascal, and relaxed SIMD (3.0)
  as the deterministic profile defines it: every relaxed instruction
  behaves as its plain counterpart (swizzle, trunc_sat, bitselect, min,
  max, q15mulr_sat_s), multiply-add rounds the product and then the
  sum (not fused), and the dot products treat both operands as signed.

  A v128 lives in two slots, lane 0 in the lowest bytes (little endian
  on both of our architectures). Operands are read into locals before
  the result is written, since the result's slots may be an operand's.
  Floating point lanes follow the scalar rules of Wasm.Numerics (exact
  rounding, min and max with NaN and signed zeros); integer lanes wrap or
  saturate as each operation says.

  Operand layout (Wasm.Code): A the result, B and C the operands, Extra
  the lane; i8x16.shuffle and v128.bitselect have their operands at
  home from A (shuffle's lanes are Constants[B], Constants[B+1]).
}
unit Wasm.Simd;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

uses
  Wasm.Code;

procedure ExecuteSimd(const Instruction: TCodeInstruction; Slots: PQWord; Constants: PQWord);
{ The v128 loads that widen or splat (load8x8_s ... load64_zero). }
procedure SimdLoad(Operation: Integer; Memory: PByte; Destination: PQWord);
{ load*_lane and store*_lane: Home holds the address, then the vector,
  and receives the result of a load. }
procedure SimdLaneAccess(Operation: Integer; Lane: Integer; Memory: PByte; Home: PQWord);

implementation

uses
  Wasm.Types,
  Wasm.Opcodes,
  Wasm.Numerics;

type
  PWasmV128 = ^TWasmV128;
  TLaneWidth = (lw8, lw16, lw32, lw64);

const
  LaneCount: array[TLaneWidth] of Integer = (16, 8, 4, 2);
  LaneBits: array[TLaneWidth] of Integer = (8, 16, 32, 64);

function LaneSigned(const V: TWasmV128; Width: TLaneWidth; Index: Integer): Int64; inline;
begin
  case Width of
    lw8: Result := ShortInt(V.Bytes[Index]);
    lw16: Result := SmallInt(V.Words[Index]);
    lw32: Result := Int32(V.DWords[Index]);
  else
    Result := Int64(V.QWords[Index]);
  end;
end;

function LaneUnsigned(const V: TWasmV128; Width: TLaneWidth; Index: Integer): QWord; inline;
begin
  case Width of
    lw8: Result := V.Bytes[Index];
    lw16: Result := V.Words[Index];
    lw32: Result := V.DWords[Index];
  else
    Result := V.QWords[Index];
  end;
end;

procedure SetLane(var V: TWasmV128; Width: TLaneWidth; Index: Integer; Value: QWord); inline;
begin
  case Width of
    lw8: V.Bytes[Index] := Byte(Value);
    lw16: V.Words[Index] := Word(Value);
    lw32: V.DWords[Index] := DWord(Value);
  else
    V.QWords[Index] := Value;
  end;
end;

function SaturateSigned(Value: Int64; Width: TLaneWidth): Int64;
var
  Lowest, Highest: Int64;
begin
  Highest := (Int64(1) shl (LaneBits[Width] - 1)) - 1;
  Lowest := -Highest - 1;
  if Value < Lowest then
    Result := Lowest
  else if Value > Highest then
    Result := Highest
  else
    Result := Value;
end;

function SaturateUnsigned(Value: Int64; Width: TLaneWidth): Int64;
var
  Highest: Int64;
begin
  Highest := (Int64(1) shl LaneBits[Width]) - 1;
  if Value < 0 then
    Result := 0
  else if Value > Highest then
    Result := Highest
  else
    Result := Value;
end;

function F32Lane(const V: TWasmV128; Index: Integer): Single; inline;
begin
  Result := PSingle(@V.DWords[Index])^;
end;

function F64Lane(const V: TWasmV128; Index: Integer): Double; inline;
begin
  Result := PDouble(@V.QWords[Index])^;
end;

procedure SetF32Lane(var V: TWasmV128; Index: Integer; Value: Single); inline;
begin
  PSingle(@V.DWords[Index])^ := Value;
end;

procedure SetF64Lane(var V: TWasmV128; Index: Integer; Value: Double); inline;
begin
  PDouble(@V.QWords[Index])^ := Value;
end;

type
  TIntegerCompare = (icEq, icNe, icLtS, icLtU, icGtS, icGtU, icLeS, icLeU, icGeS, icGeU);
  TIntegerBinary = (ibAdd, ibSub, ibMul, ibAddSatS, ibAddSatU, ibSubSatS, ibSubSatU, ibMinS, ibMinU,
    ibMaxS, ibMaxU, ibAverageU, ibQ15MulRSatS);
  TFloatBinary = (fbAdd, fbSub, fbMul, fbDiv, fbMin, fbMax, fbPMin, fbPMax);
  TFloatCompare = (fcEq, fcNe, fcLt, fcGt, fcLe, fcGe);

function CompareIntegers(const X, Y: TWasmV128; Width: TLaneWidth; Kind: TIntegerCompare): TWasmV128;
var
  Index: Integer;
  Outcome: Boolean;
begin
  for Index := 0 to LaneCount[Width] - 1 do
  begin
    case Kind of
      icEq: Outcome := LaneUnsigned(X, Width, Index) = LaneUnsigned(Y, Width, Index);
      icNe: Outcome := LaneUnsigned(X, Width, Index) <> LaneUnsigned(Y, Width, Index);
      icLtS: Outcome := LaneSigned(X, Width, Index) < LaneSigned(Y, Width, Index);
      icLtU: Outcome := LaneUnsigned(X, Width, Index) < LaneUnsigned(Y, Width, Index);
      icGtS: Outcome := LaneSigned(X, Width, Index) > LaneSigned(Y, Width, Index);
      icGtU: Outcome := LaneUnsigned(X, Width, Index) > LaneUnsigned(Y, Width, Index);
      icLeS: Outcome := LaneSigned(X, Width, Index) <= LaneSigned(Y, Width, Index);
      icLeU: Outcome := LaneUnsigned(X, Width, Index) <= LaneUnsigned(Y, Width, Index);
      icGeS: Outcome := LaneSigned(X, Width, Index) >= LaneSigned(Y, Width, Index);
    else
      Outcome := LaneUnsigned(X, Width, Index) >= LaneUnsigned(Y, Width, Index);
    end;
    if Outcome then
      SetLane(Result, Width, Index, QWord($FFFFFFFFFFFFFFFF))
    else
      SetLane(Result, Width, Index, 0);
  end;
end;

function IntegerBinary(const X, Y: TWasmV128; Width: TLaneWidth; Kind: TIntegerBinary): TWasmV128;
var
  Index: Integer;
  A, B: Int64;
  UA, UB, Value: QWord;
begin
  for Index := 0 to LaneCount[Width] - 1 do
  begin
    A := LaneSigned(X, Width, Index);
    B := LaneSigned(Y, Width, Index);
    UA := LaneUnsigned(X, Width, Index);
    UB := LaneUnsigned(Y, Width, Index);
    case Kind of
      ibAdd: Value := UA + UB;
      ibSub: Value := UA - UB;
      ibMul: Value := UA * UB;
      ibAddSatS: Value := QWord(SaturateSigned(A + B, Width));
      ibAddSatU: Value := QWord(SaturateUnsigned(Int64(UA) + Int64(UB), Width));
      ibSubSatS: Value := QWord(SaturateSigned(A - B, Width));
      ibSubSatU: Value := QWord(SaturateUnsigned(Int64(UA) - Int64(UB), Width));
      ibMinS: if A < B then Value := QWord(A) else Value := QWord(B);
      ibMinU: if UA < UB then Value := UA else Value := UB;
      ibMaxS: if A > B then Value := QWord(A) else Value := QWord(B);
      ibMaxU: if UA > UB then Value := UA else Value := UB;
      ibAverageU: Value := (UA + UB + 1) shr 1;
    else
      Value := QWord(SaturateSigned(SarInt64(A * B + $4000, 15), Width));
    end;
    SetLane(Result, Width, Index, Value);
  end;
end;

function Shift(const X: TWasmV128; Width: TLaneWidth; Count: DWord; Kind: Integer): TWasmV128;
var
  Index: Integer;
  Amount: Integer;
begin
  Amount := Count and DWord(LaneBits[Width] - 1);
  for Index := 0 to LaneCount[Width] - 1 do
    case Kind of
      0: SetLane(Result, Width, Index, LaneUnsigned(X, Width, Index) shl Amount);
      1: SetLane(Result, Width, Index, QWord(SarInt64(LaneSigned(X, Width, Index), Amount)));
    else
      SetLane(Result, Width, Index, LaneUnsigned(X, Width, Index) shr Amount);
    end;
end;

function IntegerUnary(const X: TWasmV128; Width: TLaneWidth; Kind: Integer): TWasmV128;
var
  Index: Integer;
  Value: Int64;
begin
  for Index := 0 to LaneCount[Width] - 1 do
  begin
    Value := LaneSigned(X, Width, Index);
    case Kind of
      0: if Value < 0 then Value := -Value;  { abs (wraps for the lowest value) }
      1: Value := -Value;
    else
      Value := PopCnt(Byte(Value));
    end;
    SetLane(Result, Width, Index, QWord(Value));
  end;
end;

function AllTrue(const X: TWasmV128; Width: TLaneWidth): DWord;
var
  Index: Integer;
begin
  for Index := 0 to LaneCount[Width] - 1 do
    if LaneUnsigned(X, Width, Index) = 0 then
      Exit(0);
  Result := 1;
end;

function Bitmask(const X: TWasmV128; Width: TLaneWidth): DWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to LaneCount[Width] - 1 do
    if LaneSigned(X, Width, Index) < 0 then
      Result := Result or (DWord(1) shl Index);
end;

{ Narrow: the lanes of X then Y, each saturated to the half width. }
function Narrow(const X, Y: TWasmV128; Width: TLaneWidth; Signed: Boolean): TWasmV128;
var
  Index, Count: Integer;
  Narrower: TLaneWidth;
  Value: Int64;
begin
  Narrower := Pred(Width);
  Count := LaneCount[Width];
  for Index := 0 to 2 * Count - 1 do
  begin
    if Index < Count then
      Value := LaneSigned(X, Width, Index)
    else
      Value := LaneSigned(Y, Width, Index - Count);
    if Signed then
      Value := SaturateSigned(Value, Narrower)
    else
      Value := SaturateUnsigned(Value, Narrower);
    SetLane(Result, Narrower, Index, QWord(Value));
  end;
end;

{ Extend: the low or high half of X's lanes widened to Width. }
function Extend(const X: TWasmV128; Width: TLaneWidth; High, Signed: Boolean): TWasmV128;
var
  Index, First: Integer;
  Narrower: TLaneWidth;
begin
  Narrower := Pred(Width);
  First := 0;
  if High then
    First := LaneCount[Width];
  for Index := 0 to LaneCount[Width] - 1 do
    if Signed then
      SetLane(Result, Width, Index, QWord(LaneSigned(X, Narrower, First + Index)))
    else
      SetLane(Result, Width, Index, LaneUnsigned(X, Narrower, First + Index));
end;

function ExtendMultiply(const X, Y: TWasmV128; Width: TLaneWidth; High, Signed: Boolean): TWasmV128;
var
  Index: Integer;
  A, B: TWasmV128;
begin
  A := Extend(X, Width, High, Signed);
  B := Extend(Y, Width, High, Signed);
  for Index := 0 to LaneCount[Width] - 1 do
    SetLane(Result, Width, Index, LaneUnsigned(A, Width, Index) * LaneUnsigned(B, Width, Index));
end;

function ExtendAddPairwise(const X: TWasmV128; Width: TLaneWidth; Signed: Boolean): TWasmV128;
var
  Index: Integer;
  Narrower: TLaneWidth;
begin
  Narrower := Pred(Width);
  for Index := 0 to LaneCount[Width] - 1 do
    if Signed then
      SetLane(Result, Width, Index, QWord(LaneSigned(X, Narrower, 2 * Index) + LaneSigned(X, Narrower, 2 * Index + 1)))
    else
      SetLane(Result, Width, Index, LaneUnsigned(X, Narrower, 2 * Index) + LaneUnsigned(X, Narrower, 2 * Index + 1));
end;

function F32Binary(const X, Y: TWasmV128; Kind: TFloatBinary): TWasmV128;
var
  Index: Integer;
  A, B: Single;
begin
  for Index := 0 to 3 do
  begin
    A := F32Lane(X, Index);
    B := F32Lane(Y, Index);
    case Kind of
      fbAdd: SetF32Lane(Result, Index, A + B);
      fbSub: SetF32Lane(Result, Index, A - B);
      fbMul: SetF32Lane(Result, Index, A * B);
      fbDiv: SetF32Lane(Result, Index, A / B);
      fbMin: Result.DWords[Index] := F32Min(X.DWords[Index], Y.DWords[Index]);
      fbMax: Result.DWords[Index] := F32Max(X.DWords[Index], Y.DWords[Index]);
      fbPMin: if B < A then Result.DWords[Index] := Y.DWords[Index] else Result.DWords[Index] := X.DWords[Index];
    else
      if A < B then Result.DWords[Index] := Y.DWords[Index] else Result.DWords[Index] := X.DWords[Index];
    end;
  end;
end;

function F64Binary(const X, Y: TWasmV128; Kind: TFloatBinary): TWasmV128;
var
  Index: Integer;
  A, B: Double;
begin
  for Index := 0 to 1 do
  begin
    A := F64Lane(X, Index);
    B := F64Lane(Y, Index);
    case Kind of
      fbAdd: SetF64Lane(Result, Index, A + B);
      fbSub: SetF64Lane(Result, Index, A - B);
      fbMul: SetF64Lane(Result, Index, A * B);
      fbDiv: SetF64Lane(Result, Index, A / B);
      fbMin: Result.QWords[Index] := F64Min(X.QWords[Index], Y.QWords[Index]);
      fbMax: Result.QWords[Index] := F64Max(X.QWords[Index], Y.QWords[Index]);
      fbPMin: if B < A then Result.QWords[Index] := Y.QWords[Index] else Result.QWords[Index] := X.QWords[Index];
    else
      if A < B then Result.QWords[Index] := Y.QWords[Index] else Result.QWords[Index] := X.QWords[Index];
    end;
  end;
end;

function FloatCompare(const X, Y: TWasmV128; Double_: Boolean; Kind: TFloatCompare): TWasmV128;
var
  Index: Integer;
  Outcome: Boolean;
  A, B: Double;
begin
  for Index := 0 to 3 do
  begin
    if Double_ and (Index > 1) then
      Break;
    if Double_ then
    begin
      A := F64Lane(X, Index);
      B := F64Lane(Y, Index);
    end
    else
    begin
      A := F32Lane(X, Index);
      B := F32Lane(Y, Index);
    end;
    case Kind of
      fcEq: Outcome := A = B;
      fcNe: Outcome := A <> B;
      fcLt: Outcome := A < B;
      fcGt: Outcome := A > B;
      fcLe: Outcome := A <= B;
    else
      Outcome := A >= B;
    end;
    if Double_ then
      Result.QWords[Index] := QWord(-Int64(Ord(Outcome)))
    else
      Result.DWords[Index] := DWord(-Int32(Ord(Outcome)));
  end;
end;

{ The relaxed SIMD instructions that are not a plain SIMD instruction
  in the deterministic profile: multiply-add (not fused: the product is
  rounded, then the sum) and the i8 dot products (signed times signed,
  pairs added with saturation). Three operands are at home from A. }
procedure ExecuteRelaxed(const Instruction: TCodeInstruction; Slots: PQWord);
var
  X, Y, Z, R, Product: TWasmV128;
  Index: Integer;
  Sum: Int32;
begin
  if Instruction.Operation = OpI16x8RelaxedDotI8x16I7x16S then
  begin
    { Two operands: in B and C like any binary SIMD instruction. }
    X := PWasmV128(@Slots[Instruction.B])^;
    Y := PWasmV128(@Slots[Instruction.C])^;
  end
  else
  begin
    X := PWasmV128(@Slots[Instruction.A])^;
    Y := PWasmV128(@Slots[Instruction.A + 2])^;
    Z := PWasmV128(@Slots[Instruction.A + 4])^;
  end;
  case Instruction.Operation of
    OpF32x4RelaxedMadd, OpF32x4RelaxedNmadd:
      begin
        if Instruction.Operation = OpF32x4RelaxedNmadd then
          for Index := 0 to 3 do
            X.DWords[Index] := X.DWords[Index] xor $80000000;
        Product := F32Binary(X, Y, fbMul);
        R := F32Binary(Product, Z, fbAdd);
      end;
    OpF64x2RelaxedMadd, OpF64x2RelaxedNmadd:
      begin
        if Instruction.Operation = OpF64x2RelaxedNmadd then
          for Index := 0 to 1 do
            X.QWords[Index] := X.QWords[Index] xor QWord($8000000000000000);
        Product := F64Binary(X, Y, fbMul);
        R := F64Binary(Product, Z, fbAdd);
      end;
  else
    begin
      for Index := 0 to 7 do
      begin
        Sum := Int32(ShortInt(X.Bytes[2 * Index])) * Int32(ShortInt(Y.Bytes[2 * Index])) +
          Int32(ShortInt(X.Bytes[2 * Index + 1])) * Int32(ShortInt(Y.Bytes[2 * Index + 1]));
        if Sum > 32767 then
          Sum := 32767
        else if Sum < -32768 then
          Sum := -32768;
        R.Words[Index] := Word(Sum);
      end;
      if Instruction.Operation = OpI32x4RelaxedDotI8x16I7x16AddS then
      begin
        Product := R;
        for Index := 0 to 3 do
          R.DWords[Index] := DWord(Int32(SmallInt(Product.Words[2 * Index])) +
            Int32(SmallInt(Product.Words[2 * Index + 1])) + Int32(Z.DWords[Index]));
      end;
    end;
  end;
  PWasmV128(@Slots[Instruction.A])^ := R;
end;

procedure ExecuteSimd(const Instruction: TCodeInstruction; Slots: PQWord; Constants: PQWord);
var
  X, Y, Z, R: TWasmV128;
  Index: Integer;
  Lane: Integer;
  Scalar: QWord;
  WritesVector: Boolean;
begin
  X := PWasmV128(@Slots[Instruction.B])^;
  Y := PWasmV128(@Slots[Instruction.C])^;
  Lane := Instruction.Extra;
  WritesVector := True;
  case Instruction.Operation of
    OpI8x16Shuffle:
      begin
        X := PWasmV128(@Slots[Instruction.A])^;
        Y := PWasmV128(@Slots[Instruction.A + 2])^;
        Z := PWasmV128(@Constants[Instruction.B])^;
        for Index := 0 to 15 do
          if Z.Bytes[Index] < 16 then
            R.Bytes[Index] := X.Bytes[Z.Bytes[Index]]
          else
            R.Bytes[Index] := Y.Bytes[Z.Bytes[Index] - 16];
      end;
    OpI8x16Swizzle, OpI8x16RelaxedSwizzle:
      for Index := 0 to 15 do
        if Y.Bytes[Index] < 16 then
          R.Bytes[Index] := X.Bytes[Y.Bytes[Index]]
        else
          R.Bytes[Index] := 0;
    OpI8x16Splat: FillChar(R, 16, Byte(Slots[Instruction.B]));
    OpI16x8Splat: for Index := 0 to 7 do R.Words[Index] := Word(Slots[Instruction.B]);
    OpI32x4Splat, OpF32x4Splat: for Index := 0 to 3 do R.DWords[Index] := DWord(Slots[Instruction.B]);
    OpI64x2Splat, OpF64x2Splat: for Index := 0 to 1 do R.QWords[Index] := Slots[Instruction.B];
    OpI8x16ExtractLaneS, OpI8x16ExtractLaneU, OpI16x8ExtractLaneS, OpI16x8ExtractLaneU,
    OpI32x4ExtractLane, OpI64x2ExtractLane, OpF32x4ExtractLane, OpF64x2ExtractLane:
      begin
        case Instruction.Operation of
          OpI8x16ExtractLaneS: Scalar := DWord(Int32(ShortInt(X.Bytes[Lane])));
          OpI8x16ExtractLaneU: Scalar := X.Bytes[Lane];
          OpI16x8ExtractLaneS: Scalar := DWord(Int32(SmallInt(X.Words[Lane])));
          OpI16x8ExtractLaneU: Scalar := X.Words[Lane];
          OpI32x4ExtractLane, OpF32x4ExtractLane: Scalar := X.DWords[Lane];
        else
          Scalar := X.QWords[Lane];
        end;
        Slots[Instruction.A] := Scalar;
        WritesVector := False;
      end;
    OpI8x16ReplaceLane, OpI16x8ReplaceLane, OpI32x4ReplaceLane, OpI64x2ReplaceLane, OpF32x4ReplaceLane,
    OpF64x2ReplaceLane:
      begin
        R := X;
        Scalar := Slots[Instruction.C];
        case Instruction.Operation of
          OpI8x16ReplaceLane: R.Bytes[Lane] := Byte(Scalar);
          OpI16x8ReplaceLane: R.Words[Lane] := Word(Scalar);
          OpI32x4ReplaceLane, OpF32x4ReplaceLane: R.DWords[Lane] := DWord(Scalar);
        else
          R.QWords[Lane] := Scalar;
        end;
      end;
    OpI8x16Eq..OpI8x16GeU: R := CompareIntegers(X, Y, lw8, TIntegerCompare(Instruction.Operation - OpI8x16Eq));
    OpI16x8Eq..OpI16x8GeU: R := CompareIntegers(X, Y, lw16, TIntegerCompare(Instruction.Operation - OpI16x8Eq));
    OpI32x4Eq..OpI32x4GeU: R := CompareIntegers(X, Y, lw32, TIntegerCompare(Instruction.Operation - OpI32x4Eq));
    OpI64x2Eq: R := CompareIntegers(X, Y, lw64, icEq);
    OpI64x2Ne: R := CompareIntegers(X, Y, lw64, icNe);
    OpI64x2LtS: R := CompareIntegers(X, Y, lw64, icLtS);
    OpI64x2GtS: R := CompareIntegers(X, Y, lw64, icGtS);
    OpI64x2LeS: R := CompareIntegers(X, Y, lw64, icLeS);
    OpI64x2GeS: R := CompareIntegers(X, Y, lw64, icGeS);
    OpF32x4Eq..OpF32x4Ge: R := FloatCompare(X, Y, False, TFloatCompare(Instruction.Operation - OpF32x4Eq));
    OpF64x2Eq..OpF64x2Ge: R := FloatCompare(X, Y, True, TFloatCompare(Instruction.Operation - OpF64x2Eq));
    OpV128Not:
      begin
        R.QWords[0] := not X.QWords[0];
        R.QWords[1] := not X.QWords[1];
      end;
    OpV128And:
      begin
        R.QWords[0] := X.QWords[0] and Y.QWords[0];
        R.QWords[1] := X.QWords[1] and Y.QWords[1];
      end;
    OpV128Andnot:
      begin
        R.QWords[0] := X.QWords[0] and not Y.QWords[0];
        R.QWords[1] := X.QWords[1] and not Y.QWords[1];
      end;
    OpV128Or:
      begin
        R.QWords[0] := X.QWords[0] or Y.QWords[0];
        R.QWords[1] := X.QWords[1] or Y.QWords[1];
      end;
    OpV128Xor:
      begin
        R.QWords[0] := X.QWords[0] xor Y.QWords[0];
        R.QWords[1] := X.QWords[1] xor Y.QWords[1];
      end;
    OpV128Bitselect, OpI8x16RelaxedLaneselect..OpI64x2RelaxedLaneselect:
      begin
        X := PWasmV128(@Slots[Instruction.A])^;
        Y := PWasmV128(@Slots[Instruction.A + 2])^;
        Z := PWasmV128(@Slots[Instruction.A + 4])^;
        R.QWords[0] := (X.QWords[0] and Z.QWords[0]) or (Y.QWords[0] and not Z.QWords[0]);
        R.QWords[1] := (X.QWords[1] and Z.QWords[1]) or (Y.QWords[1] and not Z.QWords[1]);
        PWasmV128(@Slots[Instruction.A])^ := R;
        Exit;
      end;
    OpV128AnyTrue:
      begin
        PDWord(@Slots[Instruction.A])^ := Ord((X.QWords[0] or X.QWords[1]) <> 0);
        WritesVector := False;
      end;
    OpF32x4DemoteF64x2Zero:
      begin
        SetF32Lane(R, 0, F64Lane(X, 0));
        SetF32Lane(R, 1, F64Lane(X, 1));
        R.QWords[1] := 0;
      end;
    OpF64x2PromoteLowF32x4:
      begin
        SetF64Lane(R, 0, F32Lane(X, 0));
        SetF64Lane(R, 1, F32Lane(X, 1));
      end;
    OpI8x16Abs: R := IntegerUnary(X, lw8, 0);
    OpI8x16Neg: R := IntegerUnary(X, lw8, 1);
    OpI8x16Popcnt: R := IntegerUnary(X, lw8, 2);
    OpI16x8Abs: R := IntegerUnary(X, lw16, 0);
    OpI16x8Neg: R := IntegerUnary(X, lw16, 1);
    OpI32x4Abs: R := IntegerUnary(X, lw32, 0);
    OpI32x4Neg: R := IntegerUnary(X, lw32, 1);
    OpI64x2Abs: R := IntegerUnary(X, lw64, 0);
    OpI64x2Neg: R := IntegerUnary(X, lw64, 1);
    OpI8x16AllTrue, OpI16x8AllTrue, OpI32x4AllTrue, OpI64x2AllTrue,
    OpI8x16Bitmask, OpI16x8Bitmask, OpI32x4Bitmask, OpI64x2Bitmask:
      begin
        case Instruction.Operation of
          OpI8x16AllTrue: Scalar := AllTrue(X, lw8);
          OpI16x8AllTrue: Scalar := AllTrue(X, lw16);
          OpI32x4AllTrue: Scalar := AllTrue(X, lw32);
          OpI64x2AllTrue: Scalar := AllTrue(X, lw64);
          OpI8x16Bitmask: Scalar := Bitmask(X, lw8);
          OpI16x8Bitmask: Scalar := Bitmask(X, lw16);
          OpI32x4Bitmask: Scalar := Bitmask(X, lw32);
        else
          Scalar := Bitmask(X, lw64);
        end;
        Slots[Instruction.A] := Scalar;
        WritesVector := False;
      end;
    OpI8x16NarrowI16x8S: R := Narrow(X, Y, lw16, True);
    OpI8x16NarrowI16x8U: R := Narrow(X, Y, lw16, False);
    OpI16x8NarrowI32x4S: R := Narrow(X, Y, lw32, True);
    OpI16x8NarrowI32x4U: R := Narrow(X, Y, lw32, False);
    OpF32x4Ceil, OpF32x4Floor, OpF32x4Trunc, OpF32x4Nearest:
      for Index := 0 to 3 do
        case Instruction.Operation of
          OpF32x4Ceil: R.DWords[Index] := F32Ceil(X.DWords[Index]);
          OpF32x4Floor: R.DWords[Index] := F32Floor(X.DWords[Index]);
          OpF32x4Trunc: R.DWords[Index] := F32Trunc(X.DWords[Index]);
        else
          R.DWords[Index] := F32Nearest(X.DWords[Index]);
        end;
    OpF64x2Ceil, OpF64x2Floor, OpF64x2Trunc, OpF64x2Nearest:
      for Index := 0 to 1 do
        case Instruction.Operation of
          OpF64x2Ceil: R.QWords[Index] := F64Ceil(X.QWords[Index]);
          OpF64x2Floor: R.QWords[Index] := F64Floor(X.QWords[Index]);
          OpF64x2Trunc: R.QWords[Index] := F64Trunc(X.QWords[Index]);
        else
          R.QWords[Index] := F64Nearest(X.QWords[Index]);
        end;
    OpI8x16Shl: R := Shift(X, lw8, DWord(Slots[Instruction.C]), 0);
    OpI8x16ShrS: R := Shift(X, lw8, DWord(Slots[Instruction.C]), 1);
    OpI8x16ShrU: R := Shift(X, lw8, DWord(Slots[Instruction.C]), 2);
    OpI16x8Shl: R := Shift(X, lw16, DWord(Slots[Instruction.C]), 0);
    OpI16x8ShrS: R := Shift(X, lw16, DWord(Slots[Instruction.C]), 1);
    OpI16x8ShrU: R := Shift(X, lw16, DWord(Slots[Instruction.C]), 2);
    OpI32x4Shl: R := Shift(X, lw32, DWord(Slots[Instruction.C]), 0);
    OpI32x4ShrS: R := Shift(X, lw32, DWord(Slots[Instruction.C]), 1);
    OpI32x4ShrU: R := Shift(X, lw32, DWord(Slots[Instruction.C]), 2);
    OpI64x2Shl: R := Shift(X, lw64, DWord(Slots[Instruction.C]), 0);
    OpI64x2ShrS: R := Shift(X, lw64, DWord(Slots[Instruction.C]), 1);
    OpI64x2ShrU: R := Shift(X, lw64, DWord(Slots[Instruction.C]), 2);
    OpI8x16Add: R := IntegerBinary(X, Y, lw8, ibAdd);
    OpI8x16AddSatS: R := IntegerBinary(X, Y, lw8, ibAddSatS);
    OpI8x16AddSatU: R := IntegerBinary(X, Y, lw8, ibAddSatU);
    OpI8x16Sub: R := IntegerBinary(X, Y, lw8, ibSub);
    OpI8x16SubSatS: R := IntegerBinary(X, Y, lw8, ibSubSatS);
    OpI8x16SubSatU: R := IntegerBinary(X, Y, lw8, ibSubSatU);
    OpI8x16MinS: R := IntegerBinary(X, Y, lw8, ibMinS);
    OpI8x16MinU: R := IntegerBinary(X, Y, lw8, ibMinU);
    OpI8x16MaxS: R := IntegerBinary(X, Y, lw8, ibMaxS);
    OpI8x16MaxU: R := IntegerBinary(X, Y, lw8, ibMaxU);
    OpI8x16AvgrU: R := IntegerBinary(X, Y, lw8, ibAverageU);
    OpI16x8ExtaddPairwiseI8x16S: R := ExtendAddPairwise(X, lw16, True);
    OpI16x8ExtaddPairwiseI8x16U: R := ExtendAddPairwise(X, lw16, False);
    OpI32x4ExtaddPairwiseI16x8S: R := ExtendAddPairwise(X, lw32, True);
    OpI32x4ExtaddPairwiseI16x8U: R := ExtendAddPairwise(X, lw32, False);
    OpI16x8Q15mulrSatS, OpI16x8RelaxedQ15mulrS: R := IntegerBinary(X, Y, lw16, ibQ15MulRSatS);
    OpI16x8ExtendLowI8x16S: R := Extend(X, lw16, False, True);
    OpI16x8ExtendHighI8x16S: R := Extend(X, lw16, True, True);
    OpI16x8ExtendLowI8x16U: R := Extend(X, lw16, False, False);
    OpI16x8ExtendHighI8x16U: R := Extend(X, lw16, True, False);
    OpI16x8Add: R := IntegerBinary(X, Y, lw16, ibAdd);
    OpI16x8AddSatS: R := IntegerBinary(X, Y, lw16, ibAddSatS);
    OpI16x8AddSatU: R := IntegerBinary(X, Y, lw16, ibAddSatU);
    OpI16x8Sub: R := IntegerBinary(X, Y, lw16, ibSub);
    OpI16x8SubSatS: R := IntegerBinary(X, Y, lw16, ibSubSatS);
    OpI16x8SubSatU: R := IntegerBinary(X, Y, lw16, ibSubSatU);
    OpI16x8Mul: R := IntegerBinary(X, Y, lw16, ibMul);
    OpI16x8MinS: R := IntegerBinary(X, Y, lw16, ibMinS);
    OpI16x8MinU: R := IntegerBinary(X, Y, lw16, ibMinU);
    OpI16x8MaxS: R := IntegerBinary(X, Y, lw16, ibMaxS);
    OpI16x8MaxU: R := IntegerBinary(X, Y, lw16, ibMaxU);
    OpI16x8AvgrU: R := IntegerBinary(X, Y, lw16, ibAverageU);
    OpI16x8ExtmulLowI8x16S: R := ExtendMultiply(X, Y, lw16, False, True);
    OpI16x8ExtmulHighI8x16S: R := ExtendMultiply(X, Y, lw16, True, True);
    OpI16x8ExtmulLowI8x16U: R := ExtendMultiply(X, Y, lw16, False, False);
    OpI16x8ExtmulHighI8x16U: R := ExtendMultiply(X, Y, lw16, True, False);
    OpI32x4ExtendLowI16x8S: R := Extend(X, lw32, False, True);
    OpI32x4ExtendHighI16x8S: R := Extend(X, lw32, True, True);
    OpI32x4ExtendLowI16x8U: R := Extend(X, lw32, False, False);
    OpI32x4ExtendHighI16x8U: R := Extend(X, lw32, True, False);
    OpI32x4Add: R := IntegerBinary(X, Y, lw32, ibAdd);
    OpI32x4Sub: R := IntegerBinary(X, Y, lw32, ibSub);
    OpI32x4Mul: R := IntegerBinary(X, Y, lw32, ibMul);
    OpI32x4MinS: R := IntegerBinary(X, Y, lw32, ibMinS);
    OpI32x4MinU: R := IntegerBinary(X, Y, lw32, ibMinU);
    OpI32x4MaxS: R := IntegerBinary(X, Y, lw32, ibMaxS);
    OpI32x4MaxU: R := IntegerBinary(X, Y, lw32, ibMaxU);
    OpI32x4DotI16x8S:
      for Index := 0 to 3 do
        R.DWords[Index] := DWord(Int32(SmallInt(X.Words[2 * Index])) * Int32(SmallInt(Y.Words[2 * Index])) +
          Int32(SmallInt(X.Words[2 * Index + 1])) * Int32(SmallInt(Y.Words[2 * Index + 1])));
    OpI32x4ExtmulLowI16x8S: R := ExtendMultiply(X, Y, lw32, False, True);
    OpI32x4ExtmulHighI16x8S: R := ExtendMultiply(X, Y, lw32, True, True);
    OpI32x4ExtmulLowI16x8U: R := ExtendMultiply(X, Y, lw32, False, False);
    OpI32x4ExtmulHighI16x8U: R := ExtendMultiply(X, Y, lw32, True, False);
    OpI64x2ExtendLowI32x4S: R := Extend(X, lw64, False, True);
    OpI64x2ExtendHighI32x4S: R := Extend(X, lw64, True, True);
    OpI64x2ExtendLowI32x4U: R := Extend(X, lw64, False, False);
    OpI64x2ExtendHighI32x4U: R := Extend(X, lw64, True, False);
    OpI64x2Add: R := IntegerBinary(X, Y, lw64, ibAdd);
    OpI64x2Sub: R := IntegerBinary(X, Y, lw64, ibSub);
    OpI64x2Mul: R := IntegerBinary(X, Y, lw64, ibMul);
    OpI64x2ExtmulLowI32x4S: R := ExtendMultiply(X, Y, lw64, False, True);
    OpI64x2ExtmulHighI32x4S: R := ExtendMultiply(X, Y, lw64, True, True);
    OpI64x2ExtmulLowI32x4U: R := ExtendMultiply(X, Y, lw64, False, False);
    OpI64x2ExtmulHighI32x4U: R := ExtendMultiply(X, Y, lw64, True, False);
    OpF32x4Abs: for Index := 0 to 3 do R.DWords[Index] := X.DWords[Index] and $7FFFFFFF;
    OpF32x4Neg: for Index := 0 to 3 do R.DWords[Index] := X.DWords[Index] xor $80000000;
    OpF32x4Sqrt: for Index := 0 to 3 do SetF32Lane(R, Index, Sqrt(F32Lane(X, Index)));
    OpF32x4Add..OpF32x4Pmax: R := F32Binary(X, Y, TFloatBinary(Instruction.Operation - OpF32x4Add));
    OpF64x2Abs: for Index := 0 to 1 do R.QWords[Index] := X.QWords[Index] and QWord($7FFFFFFFFFFFFFFF);
    OpF64x2Neg: for Index := 0 to 1 do R.QWords[Index] := X.QWords[Index] xor QWord($8000000000000000);
    OpF64x2Sqrt: for Index := 0 to 1 do SetF64Lane(R, Index, Sqrt(F64Lane(X, Index)));
    OpF64x2Add..OpF64x2Pmax: R := F64Binary(X, Y, TFloatBinary(Instruction.Operation - OpF64x2Add));
    OpF32x4RelaxedMin: R := F32Binary(X, Y, TFloatBinary(OpF32x4Min - OpF32x4Add));
    OpF32x4RelaxedMax: R := F32Binary(X, Y, TFloatBinary(OpF32x4Max - OpF32x4Add));
    OpF64x2RelaxedMin: R := F64Binary(X, Y, TFloatBinary(OpF64x2Min - OpF64x2Add));
    OpF64x2RelaxedMax: R := F64Binary(X, Y, TFloatBinary(OpF64x2Max - OpF64x2Add));
    OpF32x4RelaxedMadd..OpF64x2RelaxedNmadd, OpI16x8RelaxedDotI8x16I7x16S, OpI32x4RelaxedDotI8x16I7x16AddS:
      begin
        ExecuteRelaxed(Instruction, Slots);
        Exit;
      end;
    OpI32x4TruncSatF32x4S, OpI32x4RelaxedTruncF32x4S: for Index := 0 to 3 do R.DWords[Index] := DWord(SaturateToI32(F32Lane(X, Index)));
    OpI32x4TruncSatF32x4U, OpI32x4RelaxedTruncF32x4U: for Index := 0 to 3 do R.DWords[Index] := SaturateToU32(F32Lane(X, Index));
    OpF32x4ConvertI32x4S: for Index := 0 to 3 do SetF32Lane(R, Index, Int32(X.DWords[Index]));
    OpF32x4ConvertI32x4U: for Index := 0 to 3 do SetF32Lane(R, Index, U32ToF32(X.DWords[Index]));
    OpI32x4TruncSatF64x2SZero, OpI32x4RelaxedTruncF64x2SZero:
      begin
        R.DWords[0] := DWord(SaturateToI32(F64Lane(X, 0)));
        R.DWords[1] := DWord(SaturateToI32(F64Lane(X, 1)));
        R.QWords[1] := 0;
      end;
    OpI32x4TruncSatF64x2UZero, OpI32x4RelaxedTruncF64x2UZero:
      begin
        R.DWords[0] := SaturateToU32(F64Lane(X, 0));
        R.DWords[1] := SaturateToU32(F64Lane(X, 1));
        R.QWords[1] := 0;
      end;
    OpF64x2ConvertLowI32x4S: for Index := 0 to 1 do SetF64Lane(R, Index, Int32(X.DWords[Index]));
    OpF64x2ConvertLowI32x4U: for Index := 0 to 1 do SetF64Lane(R, Index, Int64(X.DWords[Index]));
  else
    WritesVector := False;
  end;
  if WritesVector then
    PWasmV128(@Slots[Instruction.A])^ := R;
end;

procedure SimdLoad(Operation: Integer; Memory: PByte; Destination: PQWord);
var
  Source, R: TWasmV128;
  Index: Integer;
begin
  FillChar(Source, SizeOf(Source), 0);
  FillChar(R, SizeOf(R), 0);
  case Operation of
    OpV128Load8x8S, OpV128Load8x8U, OpV128Load16x4S, OpV128Load16x4U, OpV128Load32x2S, OpV128Load32x2U:
      begin
        Move(Memory^, Source, 8);
        case Operation of
          OpV128Load8x8S: R := Extend(Source, lw16, False, True);
          OpV128Load8x8U: R := Extend(Source, lw16, False, False);
          OpV128Load16x4S: R := Extend(Source, lw32, False, True);
          OpV128Load16x4U: R := Extend(Source, lw32, False, False);
          OpV128Load32x2S: R := Extend(Source, lw64, False, True);
        else
          R := Extend(Source, lw64, False, False);
        end;
      end;
    OpV128Load8Splat: FillChar(R, 16, Memory^);
    OpV128Load16Splat: for Index := 0 to 7 do R.Words[Index] := PWord(Memory)^;
    OpV128Load32Splat: for Index := 0 to 3 do R.DWords[Index] := PDWord(Memory)^;
    OpV128Load64Splat: for Index := 0 to 1 do R.QWords[Index] := PQWord(Memory)^;
    OpV128Load32Zero: R.DWords[0] := PDWord(Memory)^;
    OpV128Load64Zero: R.QWords[0] := PQWord(Memory)^;
  end;
  PWasmV128(Destination)^ := R;
end;

procedure SimdLaneAccess(Operation: Integer; Lane: Integer; Memory: PByte; Home: PQWord);
var
  Vector: TWasmV128;
begin
  Vector := PWasmV128(@Home[1])^;
  case Operation of
    OpV128Load8Lane: Vector.Bytes[Lane] := Memory^;
    OpV128Load16Lane: Vector.Words[Lane] := PWord(Memory)^;
    OpV128Load32Lane: Vector.DWords[Lane] := PDWord(Memory)^;
    OpV128Load64Lane: Vector.QWords[Lane] := PQWord(Memory)^;
    OpV128Store8Lane: Memory^ := Vector.Bytes[Lane];
    OpV128Store16Lane: PWord(Memory)^ := Vector.Words[Lane];
    OpV128Store32Lane: PDWord(Memory)^ := Vector.DWords[Lane];
    OpV128Store64Lane: PQWord(Memory)^ := Vector.QWords[Lane];
  end;
  if Operation <= OpV128Load64Lane then
    PWasmV128(Home)^ := Vector;
end;

end.
