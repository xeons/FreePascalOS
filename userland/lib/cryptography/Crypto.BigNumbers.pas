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
  Unsigned big integers and arithmetic modulo an odd number, enough to
  check RSA signatures (up to 8192-bit keys) and to work on the NIST
  prime curves.

  A number is little endian 32-bit limbs; every product of two limbs
  plus two more fits in a QWord, which is how carries are kept.
  Arithmetic modulo N uses Montgomery multiplication: numbers are kept
  as a * R mod N (R = 2^(32 * limbs of N)) while a computation runs, so
  no division is ever needed.

  This is for public values (signatures, public keys): the time taken
  depends on the numbers. It must not be used with secrets.
}
unit Crypto.BigNumbers;

{$mode objfpc}
{$pointermath on}

interface

const
  { 8192 bits, and a limb for carries. }
  BigNumberMaximumLimbs = 257;
  BigNumberMaximumBytes = BigNumberMaximumLimbs * 4;

type
  TBigNumber = record
    { Limbs in use (no zero limbs on top); 0 for zero. }
    LimbCount: Integer;
    Limbs: array[0..BigNumberMaximumLimbs - 1] of LongWord;
  end;

  TMontgomeryModulus = record
    Modulus: TBigNumber;
    { Limbs of the modulus; every number in Montgomery form has this
      many limbs (some may be zero). }
    Width: Integer;
    { -1 / N mod 2^32. }
    InverseLimb: LongWord;
    { R^2 mod N, to bring numbers into Montgomery form. }
    RSquared: TBigNumber;
    { R mod N, which is 1 in Montgomery form. }
    MontgomeryOne: TBigNumber;
  end;

procedure SetBigNumberZero(out Number: TBigNumber);
procedure SetBigNumberSmall(out Number: TBigNumber; Value: LongWord);
{ From big endian bytes (leading zeros allowed); False when too large. }
function BigNumberFromBytes(out Number: TBigNumber; Bytes: PByte; Count: PtrUInt): Boolean;
{ From hexadecimal digits (most significant first); False for anything
  else or when too large. }
function BigNumberFromHex(out Number: TBigNumber; Digits: PChar): Boolean;
{ To exactly Count big endian bytes; False when it does not fit. }
function BigNumberToBytes(constref Number: TBigNumber; Bytes: PByte; Count: PtrUInt): Boolean;

function BigNumberIsZero(constref Number: TBigNumber): Boolean;
function BigNumberBitLength(constref Number: TBigNumber): Integer;
function BigNumberBit(constref Number: TBigNumber; Bit: Integer): Boolean;
function CompareBigNumbers(constref First, Second: TBigNumber): Integer;
function BigNumbersEqual(constref First, Second: TBigNumber): Boolean;

procedure AddBigNumbers(out Result: TBigNumber; constref First, Second: TBigNumber);
{ First must not be smaller than Second. }
procedure SubtractBigNumbers(out Result: TBigNumber; constref First, Second: TBigNumber);

{ Needs an odd modulus greater than 1, at most 8192 bits. }
function PrepareMontgomeryModulus(out Modulus: TMontgomeryModulus; constref Value: TBigNumber): Boolean;

{ Operands below the modulus. Results are below the modulus too. }
procedure MontgomeryMultiply(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber;
  out Result: TBigNumber);
procedure ToMontgomeryForm(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Result: TBigNumber);
procedure FromMontgomeryForm(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Result: TBigNumber);
procedure ModularAdd(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber; out Result: TBigNumber);
procedure ModularSubtract(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber;
  out Result: TBigNumber);
{ Value mod N for Value below 2N (one subtraction at most). False when
  Value is 2N or more. }
function ReduceOnce(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Reduced: TBigNumber): Boolean;

{ Base^Exponent mod N, all in ordinary form; Base below the modulus. }
procedure ModularPower(constref Modulus: TMontgomeryModulus; constref Base, Exponent: TBigNumber;
  out Result: TBigNumber);
{ Base^Exponent with Base already in Montgomery form; the result is too. }
procedure MontgomeryPower(constref Modulus: TMontgomeryModulus; constref Base, Exponent: TBigNumber;
  out Result: TBigNumber);
{ 1 / Value in Montgomery form, for a prime modulus (Fermat: Value^(N-2)). }
procedure MontgomeryInverseForPrime(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber;
  out Result: TBigNumber);

implementation

procedure Normalize(var Number: TBigNumber);
begin
  while (Number.LimbCount > 0) and (Number.Limbs[Number.LimbCount - 1] = 0) do
    Dec(Number.LimbCount);
end;

procedure SetBigNumberZero(out Number: TBigNumber);
begin
  FillChar(Number, SizeOf(Number), 0);
end;

procedure SetBigNumberSmall(out Number: TBigNumber; Value: LongWord);
begin
  SetBigNumberZero(Number);
  Number.Limbs[0] := Value;
  Number.LimbCount := 1;
  Normalize(Number);
end;

function BigNumberFromBytes(out Number: TBigNumber; Bytes: PByte; Count: PtrUInt): Boolean;
var
  ByteIndex: PtrUInt;
  Position: PtrUInt;
begin
  SetBigNumberZero(Number);
  { Skip leading zeros. }
  while (Count > 0) and (Bytes[0] = 0) do
  begin
    Inc(Bytes);
    Dec(Count);
  end;
  if Count > BigNumberMaximumBytes then
    Exit(False);
  ByteIndex := 0;
  while ByteIndex < Count do
  begin
    { Byte ByteIndex from the end is bits 8 * position up. }
    Position := Count - 1 - ByteIndex;
    Number.Limbs[Position div 4] := Number.Limbs[Position div 4] or
      (LongWord(Bytes[ByteIndex]) shl (8 * (Position mod 4)));
    Inc(ByteIndex);
  end;
  Number.LimbCount := Integer((Count + 3) div 4);
  Normalize(Number);
  Result := True;
end;

function HexDigitValue(Digit: Char; out Value: Byte): Boolean;
begin
  Result := True;
  case Digit of
    '0'..'9': Value := Ord(Digit) - Ord('0');
    'a'..'f': Value := Ord(Digit) - Ord('a') + 10;
    'A'..'F': Value := Ord(Digit) - Ord('A') + 10;
  else
    Value := 0;
    Result := False;
  end;
end;

function BigNumberFromHex(out Number: TBigNumber; Digits: PChar): Boolean;
var
  DigitCount: PtrUInt;
  Index: PtrUInt;
  Position: PtrUInt;
  Value: Byte;
begin
  SetBigNumberZero(Number);
  DigitCount := 0;
  while Digits[DigitCount] <> #0 do
    Inc(DigitCount);
  if DigitCount > 8 * BigNumberMaximumLimbs then
    Exit(False);
  Index := 0;
  while Index < DigitCount do
  begin
    if not HexDigitValue(Digits[Index], Value) then
      Exit(False);
    { Digit Index from the end is bits 4 * position up. }
    Position := DigitCount - 1 - Index;
    Number.Limbs[Position div 8] := Number.Limbs[Position div 8] or (LongWord(Value) shl (4 * (Position mod 8)));
    Inc(Index);
  end;
  Number.LimbCount := Integer((DigitCount + 7) div 8);
  Normalize(Number);
  Result := True;
end;

function BigNumberToBytes(constref Number: TBigNumber; Bytes: PByte; Count: PtrUInt): Boolean;
var
  ByteIndex: PtrUInt;
  Position: PtrUInt;
begin
  if (BigNumberBitLength(Number) + 7) div 8 > Integer(Count) then
    Exit(False);
  ByteIndex := 0;
  while ByteIndex < Count do
  begin
    Position := Count - 1 - ByteIndex;
    if Position div 4 < PtrUInt(Number.LimbCount) then
      Bytes[ByteIndex] := Byte(Number.Limbs[Position div 4] shr (8 * (Position mod 4)))
    else
      Bytes[ByteIndex] := 0;
    Inc(ByteIndex);
  end;
  Result := True;
end;

function BigNumberIsZero(constref Number: TBigNumber): Boolean;
begin
  Result := Number.LimbCount = 0;
end;

function BigNumberBitLength(constref Number: TBigNumber): Integer;
var
  TopLimb: LongWord;
begin
  if Number.LimbCount = 0 then
    Exit(0);
  Result := 32 * (Number.LimbCount - 1);
  TopLimb := Number.Limbs[Number.LimbCount - 1];
  while TopLimb <> 0 do
  begin
    Inc(Result);
    TopLimb := TopLimb shr 1;
  end;
end;

function BigNumberBit(constref Number: TBigNumber; Bit: Integer): Boolean;
begin
  if (Bit < 0) or (Bit div 32 >= Number.LimbCount) then
    Exit(False);
  Result := ((Number.Limbs[Bit div 32] shr (Bit mod 32)) and 1) <> 0;
end;

function CompareBigNumbers(constref First, Second: TBigNumber): Integer;
var
  Index: Integer;
begin
  if First.LimbCount <> Second.LimbCount then
  begin
    if First.LimbCount > Second.LimbCount then
      Exit(1);
    Exit(-1);
  end;
  for Index := First.LimbCount - 1 downto 0 do
    if First.Limbs[Index] <> Second.Limbs[Index] then
    begin
      if First.Limbs[Index] > Second.Limbs[Index] then
        Exit(1);
      Exit(-1);
    end;
  Result := 0;
end;

function BigNumbersEqual(constref First, Second: TBigNumber): Boolean;
begin
  Result := CompareBigNumbers(First, Second) = 0;
end;

procedure AddBigNumbers(out Result: TBigNumber; constref First, Second: TBigNumber);
var
  Sum: TBigNumber;
  Carry: QWord;
  Count: Integer;
  Index: Integer;
begin
  SetBigNumberZero(Sum);
  Count := First.LimbCount;
  if Second.LimbCount > Count then
    Count := Second.LimbCount;
  Carry := 0;
  for Index := 0 to Count - 1 do
  begin
    Carry := Carry + First.Limbs[Index] + Second.Limbs[Index];
    Sum.Limbs[Index] := LongWord(Carry);
    Carry := Carry shr 32;
  end;
  Sum.LimbCount := Count;
  if (Carry <> 0) and (Count < BigNumberMaximumLimbs) then
  begin
    Sum.Limbs[Count] := LongWord(Carry);
    Sum.LimbCount := Count + 1;
  end;
  Normalize(Sum);
  Result := Sum;
end;

procedure SubtractBigNumbers(out Result: TBigNumber; constref First, Second: TBigNumber);
var
  Difference: TBigNumber;
  Borrow: Int64;
  Value: Int64;
  Index: Integer;
begin
  SetBigNumberZero(Difference);
  Borrow := 0;
  for Index := 0 to First.LimbCount - 1 do
  begin
    Value := Int64(First.Limbs[Index]) - Int64(Second.Limbs[Index]) - Borrow;
    if Value < 0 then
    begin
      Value := Value + (Int64(1) shl 32);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Difference.Limbs[Index] := LongWord(Value);
  end;
  Difference.LimbCount := First.LimbCount;
  Normalize(Difference);
  Result := Difference;
end;

{ Doubles Value modulo N (Value below N). }
procedure DoubleModulo(var Value: TBigNumber; constref Modulus: TBigNumber);
var
  Doubled: TBigNumber;
begin
  AddBigNumbers(Doubled, Value, Value);
  if CompareBigNumbers(Doubled, Modulus) >= 0 then
    SubtractBigNumbers(Doubled, Doubled, Modulus);
  Value := Doubled;
end;

function PrepareMontgomeryModulus(out Modulus: TMontgomeryModulus; constref Value: TBigNumber): Boolean;
var
  Inverse: LongWord;
  Step: Integer;
  Doubling: Integer;
begin
  FillChar(Modulus, SizeOf(Modulus), 0);
  if (Value.LimbCount = 0) or ((Value.Limbs[0] and 1) = 0) then
    Exit(False);
  if (Value.LimbCount = 1) and (Value.Limbs[0] = 1) then
    Exit(False);
  if Value.LimbCount > BigNumberMaximumLimbs - 1 then
    Exit(False);
  Modulus.Modulus := Value;
  Modulus.Width := Value.LimbCount;

  { Newton's iteration for 1 / N mod 2^32: each step doubles the
    correct bits (an odd N is its own inverse mod 8). }
  Inverse := Value.Limbs[0];
  for Step := 1 to 5 do
    Inverse := LongWord(Inverse * LongWord(2 - LongWord(Value.Limbs[0] * Inverse)));
  Modulus.InverseLimb := LongWord(0 - Inverse);

  { R mod N and R^2 mod N by doubling 1. }
  SetBigNumberSmall(Modulus.MontgomeryOne, 1);
  for Doubling := 1 to 32 * Modulus.Width do
    DoubleModulo(Modulus.MontgomeryOne, Value);
  Modulus.RSquared := Modulus.MontgomeryOne;
  for Doubling := 1 to 32 * Modulus.Width do
    DoubleModulo(Modulus.RSquared, Value);
  Result := True;
end;

procedure MontgomeryMultiply(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber;
  out Result: TBigNumber);
var
  Accumulator: array[0..BigNumberMaximumLimbs + 1] of LongWord;
  Width: Integer;
  Outer, Inner: Integer;
  Carry: QWord;
  Sum: QWord;
  Factor: LongWord;
  Product: TBigNumber;
  Top: LongWord;
begin
  Width := Modulus.Width;
  for Inner := 0 to Width + 1 do
    Accumulator[Inner] := 0;
  { Coarsely integrated operand scanning: add First * Second[i], then
    a multiple of N that clears the lowest limb, and shift down. }
  for Outer := 0 to Width - 1 do
  begin
    Carry := 0;
    for Inner := 0 to Width - 1 do
    begin
      Sum := QWord(Accumulator[Inner]) + QWord(First.Limbs[Inner]) * Second.Limbs[Outer] + Carry;
      Accumulator[Inner] := LongWord(Sum);
      Carry := Sum shr 32;
    end;
    Sum := QWord(Accumulator[Width]) + Carry;
    Accumulator[Width] := LongWord(Sum);
    Accumulator[Width + 1] := LongWord(Sum shr 32);

    Factor := LongWord(Accumulator[0] * Modulus.InverseLimb);
    Sum := QWord(Accumulator[0]) + QWord(Factor) * Modulus.Modulus.Limbs[0];
    Carry := Sum shr 32;
    for Inner := 1 to Width - 1 do
    begin
      Sum := QWord(Accumulator[Inner]) + QWord(Factor) * Modulus.Modulus.Limbs[Inner] + Carry;
      Accumulator[Inner - 1] := LongWord(Sum);
      Carry := Sum shr 32;
    end;
    Sum := QWord(Accumulator[Width]) + Carry;
    Accumulator[Width - 1] := LongWord(Sum);
    Accumulator[Width] := Accumulator[Width + 1] + LongWord(Sum shr 32);
  end;

  SetBigNumberZero(Product);
  for Inner := 0 to Width - 1 do
    Product.Limbs[Inner] := Accumulator[Inner];
  Top := Accumulator[Width];
  Product.LimbCount := Width;
  Normalize(Product);
  { The result is below 2N: one subtraction at most. }
  if (Top <> 0) or (CompareBigNumbers(Product, Modulus.Modulus) >= 0) then
  begin
    if Top <> 0 then
    begin
      Product.Limbs[Width] := Top;
      Product.LimbCount := Width + 1;
    end;
    SubtractBigNumbers(Product, Product, Modulus.Modulus);
  end;
  Result := Product;
end;

procedure ToMontgomeryForm(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Result: TBigNumber);
begin
  MontgomeryMultiply(Modulus, Value, Modulus.RSquared, Result);
end;

procedure FromMontgomeryForm(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Result: TBigNumber);
var
  One: TBigNumber;
begin
  SetBigNumberSmall(One, 1);
  MontgomeryMultiply(Modulus, Value, One, Result);
end;

procedure ModularAdd(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber; out Result: TBigNumber);
var
  Sum: TBigNumber;
begin
  AddBigNumbers(Sum, First, Second);
  if CompareBigNumbers(Sum, Modulus.Modulus) >= 0 then
    SubtractBigNumbers(Sum, Sum, Modulus.Modulus);
  Result := Sum;
end;

procedure ModularSubtract(constref Modulus: TMontgomeryModulus; constref First, Second: TBigNumber;
  out Result: TBigNumber);
var
  Difference: TBigNumber;
begin
  if CompareBigNumbers(First, Second) >= 0 then
    SubtractBigNumbers(Difference, First, Second)
  else
  begin
    AddBigNumbers(Difference, First, Modulus.Modulus);
    SubtractBigNumbers(Difference, Difference, Second);
  end;
  Result := Difference;
end;

function ReduceOnce(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber; out Reduced: TBigNumber): Boolean;
var
  Candidate: TBigNumber;
begin
  Candidate := Value;
  if CompareBigNumbers(Candidate, Modulus.Modulus) >= 0 then
    SubtractBigNumbers(Candidate, Candidate, Modulus.Modulus);
  Result := CompareBigNumbers(Candidate, Modulus.Modulus) < 0;
  if not Result then
    SetBigNumberZero(Candidate);
  Reduced := Candidate;
end;

procedure MontgomeryPower(constref Modulus: TMontgomeryModulus; constref Base, Exponent: TBigNumber;
  out Result: TBigNumber);
var
  Accumulator: TBigNumber;
  Bit: Integer;
begin
  { Left to right square and multiply. }
  Accumulator := Modulus.MontgomeryOne;
  for Bit := BigNumberBitLength(Exponent) - 1 downto 0 do
  begin
    MontgomeryMultiply(Modulus, Accumulator, Accumulator, Accumulator);
    if BigNumberBit(Exponent, Bit) then
      MontgomeryMultiply(Modulus, Accumulator, Base, Accumulator);
  end;
  Result := Accumulator;
end;

procedure ModularPower(constref Modulus: TMontgomeryModulus; constref Base, Exponent: TBigNumber;
  out Result: TBigNumber);
var
  MontgomeryBase: TBigNumber;
  Power: TBigNumber;
begin
  ToMontgomeryForm(Modulus, Base, MontgomeryBase);
  MontgomeryPower(Modulus, MontgomeryBase, Exponent, Power);
  FromMontgomeryForm(Modulus, Power, Result);
end;

procedure MontgomeryInverseForPrime(constref Modulus: TMontgomeryModulus; constref Value: TBigNumber;
  out Result: TBigNumber);
var
  Two: TBigNumber;
  Exponent: TBigNumber;
begin
  SetBigNumberSmall(Two, 2);
  SubtractBigNumbers(Exponent, Modulus.Modulus, Two);
  MontgomeryPower(Modulus, Value, Exponent, Result);
end;

end.
