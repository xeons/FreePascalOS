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
  P-256 for signing, in constant time: nothing the time taken or the
  memory touched depends on is secret. Crypto.EllipticCurves is for
  checking signatures (public values) and branches on the scalar; this
  is what ECDSA signing (Crypto.Ecdsa) and making a public key use for
  P-256.

  - Numbers mod p and mod n are 8 limbs of 32 bits, always all of them,
    in Montgomery form (R = 2^256). The multiplication runs the same
    loops whatever the values and ends with a subtraction kept or not
    by a mask; addition and subtraction correct the same way.
  - Inverses are a^(m - 2) (Fermat): the exponent is public, the
    squarings and multiplications the same for every a.
  - Points are projective (X : Y : Z) and added with the complete
    formulas for a = -3 of Renes, Costello and Batina (2016, algorithm
    4): one formula for every pair, the point at infinity (0 : 1 : 0)
    and doubling included, so there is no case to branch on.
  - k G is a Montgomery ladder over all 256 bits: each step adds and
    doubles, the two points swapped before and after by a mask made from
    the scalar's bit, never by a branch or a table index.
}
unit Crypto.P256;

{$mode objfpc}
{$pointermath on}

interface

const
  P256ScalarBytes = 32;

{ Scalar (32 bytes big endian, below n, not zero) times the base point;
  the affine x and y, big endian. }
procedure P256MultiplyBase(Scalar: PByte; X, Y: PByte);
{ r = x(k G) mod n and s = (e + r d) / k mod n, all 32 bytes big endian
  (d and k in [1, n - 1], e below n). False when r or s is zero (the
  caller takes another k). }
function P256Sign(D, K, E: PByte; R, S: PByte): Boolean;

implementation

uses
  Crypto.Bits;

type
  TP256Number = array[0..7] of LongWord;

  TP256Modulus = record
    Value: TP256Number;
    { -1 / Value mod 2^32. }
    InverseLimb: LongWord;
    { R^2 mod Value. }
    RSquared: TP256Number;
  end;

  TP256Point = record
    X, Y, Z: TP256Number;
  end;

const
  FieldPrime: TP256Number = ($FFFFFFFF, $FFFFFFFF, $FFFFFFFF, $00000000, $00000000, $00000000, $00000001, $FFFFFFFF);
  GroupOrder: TP256Number = ($FC632551, $F3B9CAC2, $A7179E84, $BCE6FAAD, $FFFFFFFF, $FFFFFFFF, $00000000, $FFFFFFFF);
  CurveB: TP256Number = ($27D2604B, $3BCE3C3E, $CC53B0F6, $651D06B0, $769886BC, $B3EBBD55, $AA3A93E7, $5AC635D8);
  BaseX: TP256Number = ($D898C296, $F4A13945, $2DEB33A0, $77037D81, $63A440F2, $F8BCE6E5, $E12C4247, $6B17D1F2);
  BaseY: TP256Number = ($37BF51F5, $CBB64068, $6B315ECE, $2BCE3357, $7C0F9E16, $8EE7EB4A, $FE1A7F9B, $4FE342E2);

var
  Field, Order: TP256Modulus;
  Prepared: Boolean = False;
  MontgomeryB: TP256Number;

procedure LoadBigEndian(Bytes: PByte; out Number: TP256Number);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    Number[Index] := LoadBigEndian32(Bytes + 4 * (7 - Index));
end;

procedure StoreBigEndian(constref Number: TP256Number; Bytes: PByte);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    StoreBigEndian32(Bytes + 4 * (7 - Index), Number[Index]);
end;

{ Result := First - Second; the borrow out (0 or 1). }
function SubtractLimbs(out Output: TP256Number; constref First, Second: TP256Number): LongWord;
var
  Index: Integer;
  Difference: QWord;
  Borrow: LongWord;
begin
  Borrow := 0;
  for Index := 0 to 7 do
  begin
    Difference := QWord(First[Index]) - QWord(Second[Index]) - Borrow;
    Output[Index] := LongWord(Difference);
    Borrow := LongWord(Difference shr 63);
  end;
  Result := Borrow;
end;

{ Result := First + Second; the carry out. }
function AddLimbs(out Output: TP256Number; constref First, Second: TP256Number): LongWord;
var
  Index: Integer;
  Sum: QWord;
begin
  Sum := 0;
  for Index := 0 to 7 do
  begin
    Sum := QWord(First[Index]) + QWord(Second[Index]) + (Sum shr 32);
    Output[Index] := LongWord(Sum);
  end;
  Result := LongWord(Sum shr 32);
end;

{ All ones for 1, zero for 0. }
function MaskOf(Bit: LongWord): LongWord; inline;
begin
  Result := LongWord(QWord(0) - QWord(Bit));
end;

{ Target := Source where Mask is all ones; kept where it is zero. }
procedure SelectInto(var Target: TP256Number; constref Source: TP256Number; Mask: LongWord);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    Target[Index] := (Source[Index] and Mask) or (Target[Index] and not Mask);
end;

{ Value (with a ninth limb Top of 0 or 1, below 2 m) reduced below m. }
procedure ReduceOnce(var Value: TP256Number; Top: LongWord; constref Modulus: TP256Modulus);
var
  Reduced: TP256Number;
  Borrow: LongWord;
begin
  Borrow := SubtractLimbs(Reduced, Value, Modulus.Value);
  { No borrow overall (Top - Borrow >= 0): the subtraction stays. }
  SelectInto(Value, Reduced, MaskOf(Top or (Borrow xor 1)));
end;

procedure ModularAdd(out Result: TP256Number; constref First, Second: TP256Number; constref Modulus: TP256Modulus);
var
  Carry: LongWord;
begin
  Carry := AddLimbs(Result, First, Second);
  ReduceOnce(Result, Carry, Modulus);
end;

procedure ModularSubtract(out Result: TP256Number; constref First, Second: TP256Number;
  constref Modulus: TP256Modulus);
var
  Borrow: LongWord;
  Corrected: TP256Number;
begin
  Borrow := SubtractLimbs(Result, First, Second);
  AddLimbs(Corrected, Result, Modulus.Value);
  SelectInto(Result, Corrected, MaskOf(Borrow));
end;

{ Montgomery multiplication (CIOS): First * Second / R mod m. }
procedure MontgomeryMultiply(out Result: TP256Number; constref First, Second: TP256Number;
  constref Modulus: TP256Modulus);
var
  Accumulator: array[0..9] of LongWord;
  Outer, Inner: Integer;
  Carry, Product: QWord;
  Factor: LongWord;
begin
  FillChar(Accumulator, SizeOf(Accumulator), 0);
  for Outer := 0 to 7 do
  begin
    Carry := 0;
    for Inner := 0 to 7 do
    begin
      Product := QWord(Accumulator[Inner]) + QWord(First[Inner]) * Second[Outer] + Carry;
      Accumulator[Inner] := LongWord(Product);
      Carry := Product shr 32;
    end;
    Product := QWord(Accumulator[8]) + Carry;
    Accumulator[8] := LongWord(Product);
    Accumulator[9] := LongWord(Product shr 32);
    Factor := LongWord(QWord(Accumulator[0]) * Modulus.InverseLimb);
    Product := QWord(Accumulator[0]) + QWord(Factor) * Modulus.Value[0];
    Carry := Product shr 32;
    for Inner := 1 to 7 do
    begin
      Product := QWord(Accumulator[Inner]) + QWord(Factor) * Modulus.Value[Inner] + Carry;
      Accumulator[Inner - 1] := LongWord(Product);
      Carry := Product shr 32;
    end;
    Product := QWord(Accumulator[8]) + Carry;
    Accumulator[7] := LongWord(Product);
    Accumulator[8] := Accumulator[9] + LongWord(Product shr 32);
  end;
  for Inner := 0 to 7 do
    Result[Inner] := Accumulator[Inner];
  ReduceOnce(Result, Accumulator[8], Modulus);
  WipeMemory(@Accumulator, SizeOf(Accumulator));
end;

procedure ToMontgomery(out Result: TP256Number; constref Value: TP256Number; constref Modulus: TP256Modulus);
begin
  MontgomeryMultiply(Result, Value, Modulus.RSquared, Modulus);
end;

procedure FromMontgomery(out Result: TP256Number; constref Value: TP256Number; constref Modulus: TP256Modulus);
var
  One: TP256Number;
begin
  FillChar(One, SizeOf(One), 0);
  One[0] := 1;
  MontgomeryMultiply(Result, Value, One, Modulus);
end;

{ Value^(m - 2) in Montgomery form: the inverse. The exponent is public. }
procedure Invert(out Result: TP256Number; constref Value: TP256Number; constref Modulus: TP256Modulus);
var
  Exponent, Two: TP256Number;
  Bit: Integer;
  Square: TP256Number;
begin
  FillChar(Two, SizeOf(Two), 0);
  Two[0] := 2;
  SubtractLimbs(Exponent, Modulus.Value, Two);
  { Montgomery one: R mod m = R^2 / R. }
  FromMontgomery(Result, Modulus.RSquared, Modulus);
  for Bit := 255 downto 0 do
  begin
    MontgomeryMultiply(Square, Result, Result, Modulus);
    Result := Square;
    if ((Exponent[Bit div 32] shr (Bit mod 32)) and 1) <> 0 then
    begin
      MontgomeryMultiply(Square, Result, Value, Modulus);
      Result := Square;
    end;
  end;
end;

{ -1 / Value mod 2^32 by Newton's iteration (Value odd). }
function NegatedInverseLimb(Value: LongWord): LongWord;
var
  Inverse: LongWord;
  Step: Integer;
begin
  Inverse := 1;
  for Step := 1 to 5 do
    Inverse := LongWord(QWord(Inverse) * LongWord(2 - LongWord(QWord(Value) * Inverse)));
  Result := LongWord(QWord(0) - Inverse);
end;

{ R^2 mod m by doubling 1 five hundred and twelve times. }
procedure PrepareModulus(out Modulus: TP256Modulus; constref Value: TP256Number);
var
  Number: TP256Number;
  Step: Integer;
  Carry: LongWord;
begin
  Modulus.Value := Value;
  Modulus.InverseLimb := NegatedInverseLimb(Value[0]);
  FillChar(Number, SizeOf(Number), 0);
  Number[0] := 1;
  for Step := 1 to 512 do
  begin
    Carry := AddLimbs(Number, Number, Number);
    ReduceOnce(Number, Carry, Modulus);
  end;
  Modulus.RSquared := Number;
end;

procedure Prepare;
begin
  if Prepared then
    Exit;
  PrepareModulus(Field, FieldPrime);
  PrepareModulus(Order, GroupOrder);
  ToMontgomery(MontgomeryB, CurveB, Field);
  Prepared := True;
end;

procedure FieldMultiply(out Result: TP256Number; constref First, Second: TP256Number); inline;
begin
  MontgomeryMultiply(Result, First, Second, Field);
end;

procedure FieldAdd(out Result: TP256Number; constref First, Second: TP256Number); inline;
begin
  ModularAdd(Result, First, Second, Field);
end;

procedure FieldSubtract(out Result: TP256Number; constref First, Second: TP256Number); inline;
begin
  ModularSubtract(Result, First, Second, Field);
end;

{ Renes-Costello-Batina algorithm 4: complete addition for a = -3. }
procedure AddPoints(out Sum: TP256Point; constref P, Q: TP256Point);
var
  T0, T1, T2, T3, T4, X3, Y3, Z3, Scratch: TP256Number;
begin
  FieldMultiply(T0, P.X, Q.X);
  FieldMultiply(T1, P.Y, Q.Y);
  FieldMultiply(T2, P.Z, Q.Z);
  FieldAdd(T3, P.X, P.Y);
  FieldAdd(T4, Q.X, Q.Y);
  FieldMultiply(Scratch, T3, T4); T3 := Scratch;
  FieldAdd(T4, T0, T1);
  FieldSubtract(Scratch, T3, T4); T3 := Scratch;
  FieldAdd(T4, P.Y, P.Z);
  FieldAdd(X3, Q.Y, Q.Z);
  FieldMultiply(Scratch, T4, X3); T4 := Scratch;
  FieldAdd(X3, T1, T2);
  FieldSubtract(Scratch, T4, X3); T4 := Scratch;
  FieldAdd(X3, P.X, P.Z);
  FieldAdd(Y3, Q.X, Q.Z);
  FieldMultiply(Scratch, X3, Y3); X3 := Scratch;
  FieldAdd(Y3, T0, T2);
  FieldSubtract(Scratch, X3, Y3); Y3 := Scratch;
  FieldMultiply(Z3, MontgomeryB, T2);
  FieldSubtract(X3, Y3, Z3);
  FieldAdd(Z3, X3, X3);
  FieldAdd(Scratch, X3, Z3); X3 := Scratch;
  FieldSubtract(Z3, T1, X3);
  FieldAdd(Scratch, T1, X3); X3 := Scratch;
  FieldMultiply(Scratch, MontgomeryB, Y3); Y3 := Scratch;
  FieldAdd(T1, T2, T2);
  FieldAdd(Scratch, T1, T2); T2 := Scratch;
  FieldSubtract(Scratch, Y3, T2); Y3 := Scratch;
  FieldSubtract(Scratch, Y3, T0); Y3 := Scratch;
  FieldAdd(T1, Y3, Y3);
  FieldAdd(Scratch, T1, Y3); Y3 := Scratch;
  FieldAdd(T1, T0, T0);
  FieldAdd(Scratch, T1, T0); T0 := Scratch;
  FieldSubtract(Scratch, T0, T2); T0 := Scratch;
  FieldMultiply(T1, T4, Y3);
  FieldMultiply(T2, T0, Y3);
  FieldMultiply(Y3, X3, Z3);
  FieldAdd(Scratch, Y3, T2); Y3 := Scratch;
  FieldMultiply(Scratch, T3, X3); X3 := Scratch;
  FieldSubtract(Scratch, X3, T1); X3 := Scratch;
  FieldMultiply(Scratch, T4, Z3); Z3 := Scratch;
  FieldMultiply(T1, T3, T0);
  FieldAdd(Scratch, Z3, T1); Z3 := Scratch;
  Sum.X := X3;
  Sum.Y := Y3;
  Sum.Z := Z3;
end;

procedure SwapPoints(var First, Second: TP256Point; Mask: LongWord);
var
  Index: Integer;
  Difference: LongWord;
begin
  for Index := 0 to 7 do
  begin
    Difference := (First.X[Index] xor Second.X[Index]) and Mask;
    First.X[Index] := First.X[Index] xor Difference;
    Second.X[Index] := Second.X[Index] xor Difference;
    Difference := (First.Y[Index] xor Second.Y[Index]) and Mask;
    First.Y[Index] := First.Y[Index] xor Difference;
    Second.Y[Index] := Second.Y[Index] xor Difference;
    Difference := (First.Z[Index] xor Second.Z[Index]) and Mask;
    First.Z[Index] := First.Z[Index] xor Difference;
    Second.Z[Index] := Second.Z[Index] xor Difference;
  end;
end;

{ Scalar G, projective, by the Montgomery ladder. }
procedure LadderBase(constref Scalar: TP256Number; out Product: TP256Point);
var
  Other, Sum, Doubled: TP256Point;
  Bit: Integer;
  Mask: LongWord;
begin
  { Product starts as the point at infinity (0 : 1 : 0), Other as G. }
  FillChar(Product, SizeOf(Product), 0);
  FromMontgomery(Product.Y, Field.RSquared, Field);
  ToMontgomery(Other.X, BaseX, Field);
  ToMontgomery(Other.Y, BaseY, Field);
  Other.Z := Product.Y;
  for Bit := 255 downto 0 do
  begin
    Mask := MaskOf((Scalar[Bit div 32] shr (Bit mod 32)) and 1);
    SwapPoints(Product, Other, Mask);
    AddPoints(Sum, Product, Other);
    AddPoints(Doubled, Product, Product);
    Other := Sum;
    Product := Doubled;
    SwapPoints(Product, Other, Mask);
  end;
  WipeMemory(@Other, SizeOf(Other));
  WipeMemory(@Sum, SizeOf(Sum));
  WipeMemory(@Doubled, SizeOf(Doubled));
end;

{ The affine x and y (ordinary form) of a projective point. }
procedure ToAffine(constref Point: TP256Point; out X, Y: TP256Number);
var
  Inverse, Coordinate: TP256Number;
begin
  Invert(Inverse, Point.Z, Field);
  FieldMultiply(Coordinate, Point.X, Inverse);
  FromMontgomery(X, Coordinate, Field);
  FieldMultiply(Coordinate, Point.Y, Inverse);
  FromMontgomery(Y, Coordinate, Field);
end;

function IsZero(constref Number: TP256Number): Boolean;
var
  Index: Integer;
  Bits: LongWord;
begin
  Bits := 0;
  for Index := 0 to 7 do
    Bits := Bits or Number[Index];
  Result := Bits = 0;
end;

procedure P256MultiplyBase(Scalar: PByte; X, Y: PByte);
var
  Number, AffineX, AffineY: TP256Number;
  Product: TP256Point;
begin
  Prepare;
  LoadBigEndian(Scalar, Number);
  LadderBase(Number, Product);
  ToAffine(Product, AffineX, AffineY);
  StoreBigEndian(AffineX, X);
  StoreBigEndian(AffineY, Y);
  WipeMemory(@Number, SizeOf(Number));
  WipeMemory(@Product, SizeOf(Product));
end;

function P256Sign(D, K, E: PByte; R, S: PByte): Boolean;
var
  PrivateKey, Nonce, Digest, AffineX, AffineY, Signature: TP256Number;
  MontgomeryR, MontgomeryD, MontgomeryE, MontgomeryK, KInverse, Product, Sum, Scratch: TP256Number;
  Commitment: TP256Point;
  Borrow: LongWord;
begin
  Prepare;
  LoadBigEndian(D, PrivateKey);
  LoadBigEndian(K, Nonce);
  LoadBigEndian(E, Digest);
  { r = x(k G) mod n: x < p < 2n, so one conditional subtraction. }
  LadderBase(Nonce, Commitment);
  ToAffine(Commitment, AffineX, AffineY);
  Borrow := SubtractLimbs(Scratch, AffineX, GroupOrder);
  SelectInto(AffineX, Scratch, MaskOf(Borrow xor 1));
  { s = k^-1 (e + r d) mod n, in Montgomery form mod n. }
  ToMontgomery(MontgomeryR, AffineX, Order);
  ToMontgomery(MontgomeryD, PrivateKey, Order);
  ToMontgomery(MontgomeryE, Digest, Order);
  ToMontgomery(MontgomeryK, Nonce, Order);
  MontgomeryMultiply(Product, MontgomeryR, MontgomeryD, Order);
  ModularAdd(Sum, MontgomeryE, Product, Order);
  Invert(KInverse, MontgomeryK, Order);
  MontgomeryMultiply(Scratch, KInverse, Sum, Order);
  FromMontgomery(Signature, Scratch, Order);
  StoreBigEndian(AffineX, R);
  StoreBigEndian(Signature, S);
  Result := not IsZero(AffineX) and not IsZero(Signature);
  WipeMemory(@PrivateKey, SizeOf(PrivateKey));
  WipeMemory(@Nonce, SizeOf(Nonce));
  WipeMemory(@MontgomeryD, SizeOf(MontgomeryD));
  WipeMemory(@MontgomeryK, SizeOf(MontgomeryK));
  WipeMemory(@KInverse, SizeOf(KInverse));
  WipeMemory(@Product, SizeOf(Product));
  WipeMemory(@Sum, SizeOf(Sum));
  WipeMemory(@Commitment, SizeOf(Commitment));
end;

end.
