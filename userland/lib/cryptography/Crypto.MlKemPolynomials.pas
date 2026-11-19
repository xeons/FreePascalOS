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
  The polynomial arithmetic of ML-KEM (FIPS 203 section 4): polynomials
  of 256 coefficients modulo q = 3329, the number theoretic transform
  and multiplication in its domain, compression, byte encoding, and the
  two samplers (uniform from SHAKE128 for the matrix, centered binomial
  for secrets and errors).

  Coefficients are kept reduced (0 <= c < q). Reduction divides by q
  with a multiplication and a shift, never a division instruction and
  never a branch on a secret, so the time taken does not depend on the
  values (the KyberSlash timing leak came from divisions).
}
unit Crypto.MlKemPolynomials;

{$mode objfpc}
{$pointermath on}

interface

const
  MlKemQ = 3329;
  MlKemN = 256;
  { Bytes of one polynomial of 12-bit coefficients. }
  MlKemPolynomialBytes = 384;

type
  TMlKemPolynomial = array[0..MlKemN - 1] of Word;

{ Value mod q for Value < 2^26. }
function ReduceModQ(Value: QWord): Word; inline;

procedure ForwardNtt(var Polynomial: TMlKemPolynomial);
procedure InverseNtt(var Polynomial: TMlKemPolynomial);
{ Sum += First * Second, both in the NTT domain. }
procedure MultiplyAccumulateNtt(var Sum: TMlKemPolynomial; constref First, Second: TMlKemPolynomial);
procedure AddPolynomial(var Sum: TMlKemPolynomial; constref Addend: TMlKemPolynomial);
procedure SubtractPolynomial(var Difference: TMlKemPolynomial; constref Subtrahend: TMlKemPolynomial);

{ Compress_d and Decompress_d of every coefficient (1 <= d <= 11). }
procedure CompressPolynomial(var Polynomial: TMlKemPolynomial; Bits: Integer);
procedure DecompressPolynomial(var Polynomial: TMlKemPolynomial; Bits: Integer);
function CompressCoefficient(Value: Word; Bits: Integer): Word; inline;

{ ByteEncode_d and ByteDecode_d: 32 * d bytes. Decoding 12-bit values
  reduces them mod q. }
procedure EncodePolynomial(constref Polynomial: TMlKemPolynomial; Bits: Integer; Output: PByte);
procedure DecodePolynomial(Input: PByte; Bits: Integer; out Polynomial: TMlKemPolynomial);
{ Whether every 12-bit value in Input (384 bytes) is below q: the
  modulus check of an encapsulation key. }
function PolynomialBytesAreReduced(Input: PByte): Boolean;

{ SampleNTT: Seed is rho || j || i (34 bytes). }
procedure SampleUniformNtt(Seed: PByte; out Polynomial: TMlKemPolynomial);
{ SamplePolyCBD_eta from 64 * Eta bytes. }
procedure SampleCenteredBinomial(Bytes: PByte; Eta: Integer; out Polynomial: TMlKemPolynomial);

implementation

uses
  Crypto.Keccak;

const
  { floor(x / q) = (x * Reciprocal) shr ReciprocalShift for x < 2^26. }
  Reciprocal = QWord(330282877);
  ReciprocalShift = 40;
  { 128^-1 mod q. }
  InverseOf128 = 3303;
  Generator = 17;

var
  { zeta^BitRev7(i) and, for the base case products, zeta^(2 BitRev7(i) + 1). }
  Zetas: array[0..127] of Word;
  Gammas: array[0..127] of Word;
  TablesReady: Boolean = False;

function ReduceModQ(Value: QWord): Word; inline;
begin
  Result := Word(Value - ((Value * Reciprocal) shr ReciprocalShift) * MlKemQ);
end;

function BitReverse7(Value: Integer): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to 6 do
    if (Value and (1 shl Index)) <> 0 then
      Result := Result or (1 shl (6 - Index));
end;

function PowerModQ(Base: QWord; Exponent: Integer): Word;
var
  Product: QWord;
begin
  Product := 1;
  while Exponent > 0 do
  begin
    Product := (Product * Base) mod MlKemQ;
    Dec(Exponent);
  end;
  Result := Word(Product);
end;

{ The tables depend on nothing secret; filling them twice at once
  writes the same values. }
procedure PrepareTables;
var
  Index: Integer;
begin
  if TablesReady then
    Exit;
  for Index := 0 to 127 do
  begin
    Zetas[Index] := PowerModQ(Generator, BitReverse7(Index));
    Gammas[Index] := PowerModQ(Generator, 2 * BitReverse7(Index) + 1);
  end;
  TablesReady := True;
end;

procedure ForwardNtt(var Polynomial: TMlKemPolynomial);
var
  ZetaIndex, Length_, Start, Index: Integer;
  Zeta, Product: Word;
begin
  PrepareTables;
  ZetaIndex := 1;
  Length_ := 128;
  while Length_ >= 2 do
  begin
    Start := 0;
    while Start < MlKemN do
    begin
      Zeta := Zetas[ZetaIndex];
      Inc(ZetaIndex);
      for Index := Start to Start + Length_ - 1 do
      begin
        Product := ReduceModQ(QWord(Zeta) * Polynomial[Index + Length_]);
        Polynomial[Index + Length_] := ReduceModQ(QWord(Polynomial[Index]) + MlKemQ - Product);
        Polynomial[Index] := ReduceModQ(QWord(Polynomial[Index]) + Product);
      end;
      Inc(Start, 2 * Length_);
    end;
    Length_ := Length_ div 2;
  end;
end;

procedure InverseNtt(var Polynomial: TMlKemPolynomial);
var
  ZetaIndex, Length_, Start, Index: Integer;
  Zeta, Saved: Word;
begin
  PrepareTables;
  ZetaIndex := 127;
  Length_ := 2;
  while Length_ <= 128 do
  begin
    Start := 0;
    while Start < MlKemN do
    begin
      Zeta := Zetas[ZetaIndex];
      Dec(ZetaIndex);
      for Index := Start to Start + Length_ - 1 do
      begin
        Saved := Polynomial[Index];
        Polynomial[Index] := ReduceModQ(QWord(Saved) + Polynomial[Index + Length_]);
        Polynomial[Index + Length_] := ReduceModQ(QWord(Zeta) *
          ReduceModQ(QWord(Polynomial[Index + Length_]) + MlKemQ - Saved));
      end;
      Inc(Start, 2 * Length_);
    end;
    Length_ := Length_ * 2;
  end;
  for Index := 0 to MlKemN - 1 do
    Polynomial[Index] := ReduceModQ(QWord(Polynomial[Index]) * InverseOf128);
end;

procedure MultiplyAccumulateNtt(var Sum: TMlKemPolynomial; constref First, Second: TMlKemPolynomial);
var
  Pair: Integer;
  A0, A1, B0, B1: QWord;
  Even, Odd: QWord;
begin
  PrepareTables;
  for Pair := 0 to 127 do
  begin
    A0 := First[2 * Pair];
    A1 := First[2 * Pair + 1];
    B0 := Second[2 * Pair];
    B1 := Second[2 * Pair + 1];
    Even := A0 * B0 + QWord(ReduceModQ(A1 * B1)) * Gammas[Pair] + Sum[2 * Pair];
    Odd := A0 * B1 + A1 * B0 + Sum[2 * Pair + 1];
    Sum[2 * Pair] := ReduceModQ(Even);
    Sum[2 * Pair + 1] := ReduceModQ(Odd);
  end;
end;

procedure AddPolynomial(var Sum: TMlKemPolynomial; constref Addend: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemN - 1 do
    Sum[Index] := ReduceModQ(QWord(Sum[Index]) + Addend[Index]);
end;

procedure SubtractPolynomial(var Difference: TMlKemPolynomial; constref Subtrahend: TMlKemPolynomial);
var
  Index: Integer;
begin
  for Index := 0 to MlKemN - 1 do
    Difference[Index] := ReduceModQ(QWord(Difference[Index]) + MlKemQ - Subtrahend[Index]);
end;

{ round(2^d x / q) mod 2^d = floor((2^d x + (q - 1) / 2) / q) mod 2^d,
  q being odd. }
function CompressCoefficient(Value: Word; Bits: Integer): Word; inline;
var
  Numerator: QWord;
begin
  Numerator := (QWord(Value) shl Bits) + (MlKemQ - 1) div 2;
  Result := Word(((Numerator * Reciprocal) shr ReciprocalShift) and ((QWord(1) shl Bits) - 1));
end;

procedure CompressPolynomial(var Polynomial: TMlKemPolynomial; Bits: Integer);
var
  Index: Integer;
begin
  for Index := 0 to MlKemN - 1 do
    Polynomial[Index] := CompressCoefficient(Polynomial[Index], Bits);
end;

{ round(q y / 2^d) = floor((q y + 2^(d-1)) / 2^d). }
procedure DecompressPolynomial(var Polynomial: TMlKemPolynomial; Bits: Integer);
var
  Index: Integer;
begin
  for Index := 0 to MlKemN - 1 do
    Polynomial[Index] := Word((LongWord(Polynomial[Index]) * MlKemQ + (LongWord(1) shl (Bits - 1))) shr Bits);
end;

procedure EncodePolynomial(constref Polynomial: TMlKemPolynomial; Bits: Integer; Output: PByte);
var
  Accumulator: QWord;
  Held, Index, Written: Integer;
begin
  Accumulator := 0;
  Held := 0;
  Written := 0;
  for Index := 0 to MlKemN - 1 do
  begin
    Accumulator := Accumulator or (QWord(Polynomial[Index]) shl Held);
    Inc(Held, Bits);
    while Held >= 8 do
    begin
      Output[Written] := Byte(Accumulator);
      Inc(Written);
      Accumulator := Accumulator shr 8;
      Dec(Held, 8);
    end;
  end;
end;

procedure DecodePolynomial(Input: PByte; Bits: Integer; out Polynomial: TMlKemPolynomial);
var
  Accumulator: QWord;
  Held, Index, Taken: Integer;
  Mask: QWord;
begin
  Accumulator := 0;
  Held := 0;
  Taken := 0;
  Mask := (QWord(1) shl Bits) - 1;
  for Index := 0 to MlKemN - 1 do
  begin
    while Held < Bits do
    begin
      Accumulator := Accumulator or (QWord(Input[Taken]) shl Held);
      Inc(Taken);
      Inc(Held, 8);
    end;
    Polynomial[Index] := Word(Accumulator and Mask);
    Accumulator := Accumulator shr Bits;
    Dec(Held, Bits);
    if Bits = 12 then
      Polynomial[Index] := ReduceModQ(Polynomial[Index]);
  end;
end;

function PolynomialBytesAreReduced(Input: PByte): Boolean;
var
  Pair: Integer;
  First, Second: Word;
  Excess: LongWord;
begin
  Excess := 0;
  for Pair := 0 to MlKemN div 2 - 1 do
  begin
    First := Word(Input[3 * Pair]) or (Word(Input[3 * Pair + 1] and $0F) shl 8);
    Second := Word(Input[3 * Pair + 1] shr 4) or (Word(Input[3 * Pair + 2]) shl 4);
    { The top bit of (q - 1 - c) is set when c >= q. }
    Excess := Excess or LongWord((LongInt(MlKemQ - 1) - LongInt(First)) shr 31) or
      LongWord((LongInt(MlKemQ - 1) - LongInt(Second)) shr 31);
  end;
  Result := Excess = 0;
end;

procedure SampleUniformNtt(Seed: PByte; out Polynomial: TMlKemPolynomial);
var
  State: TKeccakState;
  Block: array[0..2] of Byte;
  Count: Integer;
  First, Second: Word;
begin
  BeginKeccak(State, Shake128Rate, ShakeSuffix);
  AbsorbKeccak(State, Seed, 34);
  Count := 0;
  { Rejection sampling: the matrix is public, so the time it takes
    tells nothing. }
  while Count < MlKemN do
  begin
    SqueezeKeccak(State, @Block[0], 3);
    First := Word(Block[0]) or (Word(Block[1] and $0F) shl 8);
    Second := Word(Block[1] shr 4) or (Word(Block[2]) shl 4);
    if First < MlKemQ then
    begin
      Polynomial[Count] := First;
      Inc(Count);
    end;
    if (Second < MlKemQ) and (Count < MlKemN) then
    begin
      Polynomial[Count] := Second;
      Inc(Count);
    end;
  end;
  WipeKeccak(State);
end;

function BitAt(Bytes: PByte; Index: Integer): Word; inline;
begin
  Result := (Bytes[Index shr 3] shr (Index and 7)) and 1;
end;

procedure SampleCenteredBinomial(Bytes: PByte; Eta: Integer; out Polynomial: TMlKemPolynomial);
var
  Index, Bit: Integer;
  Positive, Negative: Word;
begin
  for Index := 0 to MlKemN - 1 do
  begin
    Positive := 0;
    Negative := 0;
    for Bit := 0 to Eta - 1 do
    begin
      Inc(Positive, BitAt(Bytes, 2 * Index * Eta + Bit));
      Inc(Negative, BitAt(Bytes, 2 * Index * Eta + Eta + Bit));
    end;
    Polynomial[Index] := ReduceModQ(QWord(Positive) + MlKemQ - Negative);
  end;
end;

end.
