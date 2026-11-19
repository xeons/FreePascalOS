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
  The polynomial ring of ML-KEM (FIPS 203): polynomials of degree 255
  over the integers modulo q = 3329, their number theoretic transform,
  sampling (uniform in NTT form, and from the centered binomial
  distribution with eta = 2), compression and byte encoding.

  Coefficients are 16-bit signed numbers kept within small multiples of
  q. Products are reduced with Montgomery reduction (R = 2^16), sums
  with Barrett reduction; neither branches nor looks anything up by a
  secret value. The zeta table is indexed only by public positions.
}
unit Crypto.MlKemPolynomials;

{$mode objfpc}
{$pointermath on}

interface

const
  MlKemDegree = 256;
  MlKemModulus = 3329;
  MlKemSeedLength = 32;
  { One polynomial with 12-bit coefficients. }
  MlKemPolynomialBytes = 384;

type
  TMlKemPolynomial = array[0..MlKemDegree - 1] of SmallInt;

procedure PolynomialNtt(var Polynomial: TMlKemPolynomial);
{ The inverse transform; also multiplies by the Montgomery factor R, so
  that it undoes the R^-1 a product in NTT form leaves. }
procedure PolynomialInverseNtt(var Polynomial: TMlKemPolynomial);
{ Product = First * Second * R^-1, both in NTT form. }
procedure PolynomialMultiplyNtt(out Product: TMlKemPolynomial; constref First, Second: TMlKemPolynomial);
{ Multiplies every coefficient by R (into the Montgomery domain). }
procedure PolynomialToMontgomery(var Polynomial: TMlKemPolynomial);
{ Barrett-reduces every coefficient to the centered range. }
procedure PolynomialReduce(var Polynomial: TMlKemPolynomial);
procedure PolynomialAdd(var Sum: TMlKemPolynomial; constref Addend: TMlKemPolynomial);
procedure PolynomialSubtract(out Difference: TMlKemPolynomial; constref Minuend, Subtrahend: TMlKemPolynomial);

{ SampleNTT: a uniform polynomial in NTT form from SHAKE128 of the 32
  byte Seed and the two index bytes. }
procedure SampleNttPolynomial(out Polynomial: TMlKemPolynomial; Seed: PByte; FirstIndex, SecondIndex: Byte);
{ SamplePolyCBD with eta = 2 of PRF(Seed, Nonce) = SHAKE256(Seed || Nonce). }
procedure SampleNoisePolynomial(out Polynomial: TMlKemPolynomial; Seed: PByte; Nonce: Byte);

{ ByteEncode12 of a reduced polynomial (made non-negative first). }
procedure PolynomialToBytes(constref Polynomial: TMlKemPolynomial; Output: PByte);
{ ByteDecode12 without reduction. }
procedure PolynomialFromBytes(out Polynomial: TMlKemPolynomial; Input: PByte);
{ True when every 12-bit value in the 384 bytes is below q (the modulus
  check of FIPS 203 section 7.2). }
function PolynomialBytesAreReduced(Input: PByte): Boolean;

{ ByteEncode(Compress(x)) with Bits per coefficient, of a reduced polynomial. }
procedure CompressPolynomial(constref Polynomial: TMlKemPolynomial; Bits: Integer; Output: PByte);
procedure DecompressPolynomial(out Polynomial: TMlKemPolynomial; Bits: Integer; Input: PByte);

{ Decompress1(ByteDecode1(Message)) of a 32 byte message. }
procedure PolynomialFromMessage(out Polynomial: TMlKemPolynomial; Message: PByte);
{ ByteEncode1(Compress1(x)) of a reduced polynomial into 32 bytes. }
procedure PolynomialToMessage(constref Polynomial: TMlKemPolynomial; Message: PByte);

implementation

uses
  Crypto.Bits,
  Crypto.Sha3;

const
  { q^-1 modulo 2^16. }
  ModulusInverse = 62209;
  { Round(2^26 / q), for Barrett reduction. }
  BarrettMultiplier = 20159;
  { 2^32 mod q: R^2 for PolynomialToMontgomery. }
  MontgomerySquare = 1353;
  { R^2 / 128 mod q: scales the inverse transform. }
  InverseNttScale = 1441;
  { Round(2^32 / q): turns division by q into a multiplication. }
  CompressMultiplier = 1290167;
  HalfModulus = (MlKemModulus + 1) div 2;

  { 17^BitReverse7(i) * R mod q, centered. }
  Zetas: array[0..127] of SmallInt = (
    -1044, -758, -359, -1517, 1493, 1422, 287, 202, -171, 622, 1577, 182, 962, -1202, -1474, 1468,
    573, -1325, 264, 383, -829, 1458, -1602, -130, -681, 1017, 732, 608, -1542, 411, -205, -1571,
    1223, 652, -552, 1015, -1293, 1491, -282, -1544, 516, -8, -320, -666, -1618, -1162, 126, 1469,
    -853, -90, -271, 830, 107, -1421, -247, -951, -398, 961, -1508, -725, 448, -1065, 677, -1275,
    -1103, 430, 555, 843, -1251, 871, 1550, 105, 422, 587, 177, -235, -291, -460, 1574, 1653,
    -246, 778, 1159, -147, -777, 1483, -602, 1119, -1590, 644, -872, 349, 418, 329, -156, -75,
    817, 1097, 603, 610, 1322, -1285, -1465, 384, -1215, -136, 1218, -1335, -874, 220, -1187, -1659,
    -1185, -1530, -1278, 794, -1510, -854, -870, 478, -108, -308, 996, 991, 958, -1460, 1522, 1628);

{ Value * R^-1 mod q, in (-q, q), for |Value| < 2^15 * q. }
function MontgomeryReduce(Value: LongInt): LongInt; inline;
var
  LowMultiple: LongInt;
begin
  LowMultiple := SmallInt(Word((QWord(LongWord(Value)) * ModulusInverse) and $FFFF));
  Result := SarLongint(Value - LowMultiple * MlKemModulus, 16);
end;

function MultiplyMontgomery(First, Second: LongInt): LongInt; inline;
begin
  Result := MontgomeryReduce(First * Second);
end;

{ Value mod q in the centered range, for |Value| < 2^15. }
function BarrettReduce(Value: LongInt): LongInt; inline;
var
  Quotient: LongInt;
begin
  Quotient := SarLongint(BarrettMultiplier * Value + (1 shl 25), 26);
  Result := Value - Quotient * MlKemModulus;
end;

{ A centered residue (|Value| < q) as its representative in [0, q). }
function MakeNonNegative(Value: LongInt): LongInt; inline;
begin
  Result := Value + (SarLongint(Value, 31) and MlKemModulus);
end;

procedure PolynomialNtt(var Polynomial: TMlKemPolynomial);
var
  ZetaIndex, Span, Start, Index: Integer;
  Zeta, Product: LongInt;
begin
  ZetaIndex := 1;
  Span := 128;
  while Span >= 2 do
  begin
    Start := 0;
    while Start < MlKemDegree do
    begin
      Zeta := Zetas[ZetaIndex];
      Inc(ZetaIndex);
      for Index := Start to Start + Span - 1 do
      begin
        Product := MultiplyMontgomery(Zeta, Polynomial[Index + Span]);
        Polynomial[Index + Span] := Polynomial[Index] - Product;
        Polynomial[Index] := Polynomial[Index] + Product;
      end;
      Inc(Start, 2 * Span);
    end;
    Span := Span div 2;
  end;
  PolynomialReduce(Polynomial);
end;

procedure PolynomialInverseNtt(var Polynomial: TMlKemPolynomial);
var
  ZetaIndex, Span, Start, Index: Integer;
  Zeta, Lower: LongInt;
begin
  ZetaIndex := 127;
  Span := 2;
  while Span <= 128 do
  begin
    Start := 0;
    while Start < MlKemDegree do
    begin
      Zeta := Zetas[ZetaIndex];
      Dec(ZetaIndex);
      for Index := Start to Start + Span - 1 do
      begin
        Lower := Polynomial[Index];
        Polynomial[Index] := BarrettReduce(Lower + Polynomial[Index + Span]);
        Polynomial[Index + Span] := MultiplyMontgomery(Zeta, Polynomial[Index + Span] - Lower);
      end;
      Inc(Start, 2 * Span);
    end;
    Span := Span * 2;
  end;
  for Index := 0 to MlKemDegree - 1 do
    Polynomial[Index] := MultiplyMontgomery(Polynomial[Index], InverseNttScale);
end;

{ The product of two degree one polynomials modulo X^2 - Zeta. }
procedure MultiplyPair(Product, First, Second: PSmallInt; Zeta: LongInt);
var
  HighProduct: LongInt;
begin
  HighProduct := MultiplyMontgomery(First[1], Second[1]);
  Product[0] := MultiplyMontgomery(HighProduct, Zeta) + MultiplyMontgomery(First[0], Second[0]);
  Product[1] := MultiplyMontgomery(First[0], Second[1]) + MultiplyMontgomery(First[1], Second[0]);
end;

procedure PolynomialMultiplyNtt(out Product: TMlKemPolynomial; constref First, Second: TMlKemPolynomial);
var
  Pair: Integer;
begin
  for Pair := 0 to MlKemDegree div 4 - 1 do
  begin
    MultiplyPair(@Product[4 * Pair], @First[4 * Pair], @Second[4 * Pair], Zetas[64 + Pair]);
    MultiplyPair(@Product[4 * Pair + 2], @First[4 * Pair + 2], @Second[4 * Pair + 2], -Zetas[64 + Pair]);
  end;
end;

procedure PolynomialToMontgomery(var Polynomial: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Polynomial[Index] := MultiplyMontgomery(Polynomial[Index], MontgomerySquare);
end;

procedure PolynomialReduce(var Polynomial: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Polynomial[Index] := BarrettReduce(Polynomial[Index]);
end;

procedure PolynomialAdd(var Sum: TMlKemPolynomial; constref Addend: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Sum[Index] := Sum[Index] + Addend[Index];
end;

procedure PolynomialSubtract(out Difference: TMlKemPolynomial; constref Minuend, Subtrahend: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Difference[Index] := Minuend[Index] - Subtrahend[Index];
end;

procedure SampleNttPolynomial(out Polynomial: TMlKemPolynomial; Seed: PByte; FirstIndex, SecondIndex: Byte);
var
  Context: TSha3Context;
  Indices: array[0..1] of Byte;
  Block: array[0..167] of Byte;
  Count, Offset: Integer;
  FirstValue, SecondValue: Integer;
begin
  BeginShake(Context, 128);
  AbsorbShake(Context, Seed, MlKemSeedLength);
  Indices[0] := FirstIndex;
  Indices[1] := SecondIndex;
  AbsorbShake(Context, @Indices[0], 2);
  { Rejection sampling of 12-bit values; the matrix is public, so the
    branches leak nothing. }
  Count := 0;
  while Count < MlKemDegree do
  begin
    SqueezeShake(Context, @Block[0], SizeOf(Block));
    Offset := 0;
    while (Offset < SizeOf(Block)) and (Count < MlKemDegree) do
    begin
      FirstValue := Block[Offset] or ((Block[Offset + 1] and $0F) shl 8);
      SecondValue := (Block[Offset + 1] shr 4) or (Block[Offset + 2] shl 4);
      Inc(Offset, 3);
      if FirstValue < MlKemModulus then
      begin
        Polynomial[Count] := FirstValue;
        Inc(Count);
      end;
      if (SecondValue < MlKemModulus) and (Count < MlKemDegree) then
      begin
        Polynomial[Count] := SecondValue;
        Inc(Count);
      end;
    end;
  end;
  WipeSha3(Context);
end;

procedure SampleNoisePolynomial(out Polynomial: TMlKemPolynomial; Seed: PByte; Nonce: Byte);
var
  Context: TSha3Context;
  Noise: array[0..127] of Byte;
  Word32, BitSums: LongWord;
  Group, Index: Integer;
  Positive, Negative: LongInt;
begin
  BeginShake(Context, 256);
  AbsorbShake(Context, Seed, MlKemSeedLength);
  AbsorbShake(Context, @Nonce, 1);
  SqueezeShake(Context, @Noise[0], SizeOf(Noise));
  WipeSha3(Context);
  { Each coefficient is the sum of two bits minus the sum of the next two. }
  for Group := 0 to MlKemDegree div 8 - 1 do
  begin
    Word32 := LoadLittleEndian32(@Noise[4 * Group]);
    BitSums := (Word32 and $55555555) + ((Word32 shr 1) and $55555555);
    for Index := 0 to 7 do
    begin
      Positive := (BitSums shr (4 * Index)) and 3;
      Negative := (BitSums shr (4 * Index + 2)) and 3;
      Polynomial[8 * Group + Index] := Positive - Negative;
    end;
  end;
  Word32 := 0;
  BitSums := 0;
  WipeMemory(@Noise[0], SizeOf(Noise));
end;

{ Packs 256 values of Bits bits each, least significant bit first. }
procedure PackValues(Values: PWord; Bits: Integer; Output: PByte);
var
  Accumulator: QWord;
  Pending, Index, OutputIndex: Integer;
begin
  Accumulator := 0;
  Pending := 0;
  OutputIndex := 0;
  for Index := 0 to MlKemDegree - 1 do
  begin
    Accumulator := Accumulator or (QWord(Values[Index]) shl Pending);
    Inc(Pending, Bits);
    while Pending >= 8 do
    begin
      Output[OutputIndex] := Byte(Accumulator and $FF);
      Accumulator := Accumulator shr 8;
      Dec(Pending, 8);
      Inc(OutputIndex);
    end;
  end;
end;

procedure UnpackValues(Input: PByte; Bits: Integer; Values: PWord);
var
  Accumulator, Mask: QWord;
  Pending, Index, InputIndex: Integer;
begin
  Accumulator := 0;
  Pending := 0;
  InputIndex := 0;
  Mask := (QWord(1) shl Bits) - 1;
  for Index := 0 to MlKemDegree - 1 do
  begin
    while Pending < Bits do
    begin
      Accumulator := Accumulator or (QWord(Input[InputIndex]) shl Pending);
      Inc(InputIndex);
      Inc(Pending, 8);
    end;
    Values[Index] := Word(Accumulator and Mask);
    Accumulator := Accumulator shr Bits;
    Dec(Pending, Bits);
  end;
end;

procedure PolynomialToBytes(constref Polynomial: TMlKemPolynomial; Output: PByte);
var
  Values: array[0..MlKemDegree - 1] of Word;
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Values[Index] := Word(MakeNonNegative(Polynomial[Index]));
  PackValues(@Values[0], 12, Output);
  WipeMemory(@Values[0], SizeOf(Values));
end;

procedure PolynomialFromBytes(out Polynomial: TMlKemPolynomial; Input: PByte);
var
  Values: array[0..MlKemDegree - 1] of Word;
  Index: Integer;
begin
  UnpackValues(Input, 12, @Values[0]);
  for Index := 0 to MlKemDegree - 1 do
    Polynomial[Index] := SmallInt(Values[Index]);
  WipeMemory(@Values[0], SizeOf(Values));
end;

function PolynomialBytesAreReduced(Input: PByte): Boolean;
var
  Values: array[0..MlKemDegree - 1] of Word;
  Index: Integer;
begin
  UnpackValues(Input, 12, @Values[0]);
  Result := True;
  for Index := 0 to MlKemDegree - 1 do
    if Values[Index] >= MlKemModulus then
      Result := False;
end;

{ Round(2^Bits * Value / q) mod 2^Bits, for Value in [0, q). }
function CompressValue(Value: LongInt; Bits: Integer): Word; inline;
var
  Scaled: QWord;
begin
  Scaled := ((QWord(LongWord(Value)) shl Bits) + HalfModulus) * CompressMultiplier;
  Result := Word((Scaled shr 32) and ((QWord(1) shl Bits) - 1));
end;

procedure CompressPolynomial(constref Polynomial: TMlKemPolynomial; Bits: Integer; Output: PByte);
var
  Values: array[0..MlKemDegree - 1] of Word;
  Index: Integer;
begin
  for Index := 0 to MlKemDegree - 1 do
    Values[Index] := CompressValue(MakeNonNegative(Polynomial[Index]), Bits);
  PackValues(@Values[0], Bits, Output);
  WipeMemory(@Values[0], SizeOf(Values));
end;

procedure DecompressPolynomial(out Polynomial: TMlKemPolynomial; Bits: Integer; Input: PByte);
var
  Values: array[0..MlKemDegree - 1] of Word;
  Index: Integer;
begin
  UnpackValues(Input, Bits, @Values[0]);
  { Round(q * Value / 2^Bits). }
  for Index := 0 to MlKemDegree - 1 do
    Polynomial[Index] := SmallInt((LongWord(Values[Index]) * MlKemModulus + (LongWord(1) shl (Bits - 1))) shr Bits);
end;

procedure PolynomialFromMessage(out Polynomial: TMlKemPolynomial; Message: PByte);
var
  ByteIndex, BitIndex: Integer;
  Bit: LongInt;
begin
  for ByteIndex := 0 to 31 do
    for BitIndex := 0 to 7 do
    begin
      Bit := (Message[ByteIndex] shr BitIndex) and 1;
      Polynomial[8 * ByteIndex + BitIndex] := (-Bit) and HalfModulus;
    end;
end;

procedure PolynomialToMessage(constref Polynomial: TMlKemPolynomial; Message: PByte);
begin
  CompressPolynomial(Polynomial, 1, Message);
end;

end.
