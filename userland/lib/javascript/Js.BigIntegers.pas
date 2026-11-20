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
  BigInt values: arbitrary precision integers.

  A sign and a magnitude of 32-bit digits, least significant first,
  with no leading zero digits (zero has none and is never negative).
  The arithmetic is schoolbook: addition, subtraction, multiplication,
  division with remainder (Knuth's algorithm D), powers, shifts and the
  bitwise operators with two's complement meaning for negative values,
  conversion from and to text in any radix 2..36 and to and from
  doubles.
}
unit Js.BigIntegers;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap;

type
  TJsDigits = array of LongWord;

  TJsBigInt = class(TJsCell)
  public
    Negative: Boolean;
    Digits: TJsDigits;
    function MemorySize: SizeInt; override;
    function IsZero: Boolean; inline;
  end;

function NewBigInt(Heap: TJsHeap; Negative: Boolean; const Digits: TJsDigits): TJsBigInt;
function BigIntFromInt64(Heap: TJsHeap; Value: Int64): TJsBigInt;
{ nil when Value is not an integer. }
function BigIntFromDouble(Heap: TJsHeap; Value: Double): TJsBigInt;
{ Text of digits in Radix (no sign, no prefix); nil when malformed. }
function BigIntFromText(Heap: TJsHeap; const Text: string; Radix: Integer; Negative: Boolean): TJsBigInt;
function BigIntToText(Value: TJsBigInt; Radix: Integer): string;
function BigIntToDouble(Value: TJsBigInt): Double;
{ The low 64 bits, two's complement. }
function BigIntToInt64(Value: TJsBigInt): Int64;
function BigIntCompare(First, Second: TJsBigInt): Integer;
{ Compares with a double (not NaN). }
function BigIntCompareDouble(First: TJsBigInt; Second: Double): Integer;

function BigIntAdd(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntSubtract(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntMultiply(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
{ Truncating division; Second is not zero. }
function BigIntDivide(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntRemainder(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntPower(Heap: TJsHeap; Base: TJsBigInt; Exponent: LongWord): TJsBigInt;
function BigIntNegate(Heap: TJsHeap; Value: TJsBigInt): TJsBigInt;
function BigIntShiftLeft(Heap: TJsHeap; Value: TJsBigInt; Count: Int64): TJsBigInt;
function BigIntAnd(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntOr(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntXor(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
function BigIntNot(Heap: TJsHeap; Value: TJsBigInt): TJsBigInt;
{ BigInt.asIntN / asUintN. }
function BigIntAsIntN(Heap: TJsHeap; Value: TJsBigInt; Bits: Integer; Signed: Boolean): TJsBigInt;

implementation

uses
  Math;

function TJsBigInt.MemorySize: SizeInt;
begin
  Result := InstanceSize + Length(Digits) * SizeOf(LongWord);
end;

function TJsBigInt.IsZero: Boolean;
begin
  Result := Length(Digits) = 0;
end;

procedure Normalize(var Digits: TJsDigits);
var
  Count: Integer;
begin
  Count := Length(Digits);
  while (Count > 0) and (Digits[Count - 1] = 0) do
    Dec(Count);
  SetLength(Digits, Count);
end;

function NewBigInt(Heap: TJsHeap; Negative: Boolean; const Digits: TJsDigits): TJsBigInt;
begin
  Result := TJsBigInt.Create;
  Heap.Register(Result, ckBigInt);
  Result.Digits := Copy(Digits);
  Normalize(Result.Digits);
  Result.Negative := Negative and (Length(Result.Digits) > 0);
  Heap.Account(Length(Result.Digits) * SizeOf(LongWord));
end;

function BigIntFromInt64(Heap: TJsHeap; Value: Int64): TJsBigInt;
var
  Digits: TJsDigits;
  Magnitude: QWord;
begin
  Digits := nil;
  if Value < 0 then
    Magnitude := QWord(-(Value + 1)) + 1
  else
    Magnitude := QWord(Value);
  SetLength(Digits, 2);
  Digits[0] := LongWord(Magnitude);
  Digits[1] := LongWord(Magnitude shr 32);
  Result := NewBigInt(Heap, Value < 0, Digits);
end;

function BigIntFromDouble(Heap: TJsHeap; Value: Double): TJsBigInt;
var
  Digits: TJsDigits;
  Magnitude: Double;
  Count, Index: Integer;
begin
  Result := nil;
  if IsNaNDouble(Value) or not IsFiniteDouble(Value) or (Int(Value) <> Value) then
    Exit;
  Magnitude := Abs(Value);
  Count := 0;
  Digits := nil;
  SetLength(Digits, 34);
  while Magnitude >= 1 do
  begin
    Digits[Count] := LongWord(Trunc(Magnitude - Int(Magnitude / 4294967296.0) * 4294967296.0));
    Magnitude := Int(Magnitude / 4294967296.0);
    Inc(Count);
  end;
  SetLength(Digits, Count);

  Result := NewBigInt(Heap, Value < 0, Digits);
end;

function CompareMagnitudes(const First, Second: TJsDigits): Integer;
var
  Index: Integer;
begin
  if Length(First) <> Length(Second) then
    Exit(Length(First) - Length(Second));
  for Index := High(First) downto 0 do
    if First[Index] <> Second[Index] then
    begin
      if First[Index] > Second[Index] then
        Exit(1);
      Exit(-1);
    end;
  Result := 0;
end;

function AddMagnitudes(const First, Second: TJsDigits): TJsDigits;
var
  Index, Count: Integer;
  Carry: QWord;
  A, B: QWord;
begin
  Result := nil;
  Count := Max(Length(First), Length(Second));
  SetLength(Result, Count + 1);
  Carry := 0;
  for Index := 0 to Count - 1 do
  begin
    A := 0;
    B := 0;
    if Index < Length(First) then
      A := First[Index];
    if Index < Length(Second) then
      B := Second[Index];
    Carry := Carry + A + B;
    Result[Index] := LongWord(Carry);
    Carry := Carry shr 32;
  end;
  Result[Count] := LongWord(Carry);
  Normalize(Result);
end;

{ First - Second, First >= Second. }
function SubtractMagnitudes(const First, Second: TJsDigits): TJsDigits;
var
  Index: Integer;
  Borrow: Int64;
  Difference: Int64;
begin
  Result := nil;
  SetLength(Result, Length(First));
  Borrow := 0;
  for Index := 0 to High(First) do
  begin
    Difference := Int64(First[Index]) - Borrow;
    if Index < Length(Second) then
      Difference := Difference - Int64(Second[Index]);
    if Difference < 0 then
    begin
      Difference := Difference + Int64(4294967296);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Result[Index] := LongWord(Difference);
  end;
  Normalize(Result);
end;

function MultiplyMagnitudes(const First, Second: TJsDigits): TJsDigits;
var
  I, J: Integer;
  Carry, Product: QWord;
begin
  Result := nil;
  if (Length(First) = 0) or (Length(Second) = 0) then
    Exit;
  SetLength(Result, Length(First) + Length(Second));
  for I := 0 to High(First) do
  begin
    Carry := 0;
    for J := 0 to High(Second) do
    begin
      Product := QWord(First[I]) * Second[J] + Result[I + J] + Carry;
      Result[I + J] := LongWord(Product);
      Carry := Product shr 32;
    end;
    Result[I + Length(Second)] := LongWord(Carry);
  end;
  Normalize(Result);
end;

{ Quotient and remainder of magnitudes (Divisor not zero). }
procedure DivideMagnitudes(const Dividend, Divisor: TJsDigits; out Quotient, Remainder: TJsDigits);
var
  Shift, M, N, J, I: Integer;
  U, V: TJsDigits;
  Estimate, RemainderEstimate, Product, Borrow, Carry: QWord;
  Top: QWord;
  Difference: Int64;
  Single: QWord;
begin
  Quotient := nil;
  Remainder := nil;
  if CompareMagnitudes(Dividend, Divisor) < 0 then
  begin
    Remainder := Copy(Dividend);
    Exit;
  end;
  N := Length(Divisor);
  if N = 1 then
  begin
    SetLength(Quotient, Length(Dividend));
    Single := 0;
    for I := High(Dividend) downto 0 do
    begin
      Single := (Single shl 32) or Dividend[I];
      Quotient[I] := LongWord(Single div Divisor[0]);
      Single := Single mod Divisor[0];
    end;
    Normalize(Quotient);
    SetLength(Remainder, 1);
    Remainder[0] := LongWord(Single);
    Normalize(Remainder);
    Exit;
  end;
  { Knuth D: normalise so the divisor's top digit has its top bit set. }
  Shift := 0;
  while (Divisor[N - 1] shl Shift) and $80000000 = 0 do
    Inc(Shift);
  M := Length(Dividend) - N;
  V := nil;
  SetLength(V, N);
  for I := N - 1 downto 1 do
    if Shift > 0 then
      V[I] := (Divisor[I] shl Shift) or (Divisor[I - 1] shr (32 - Shift))
    else
      V[I] := Divisor[I];
  V[0] := Divisor[0] shl Shift;
  U := nil;
  SetLength(U, Length(Dividend) + 1);
  if Shift > 0 then
    U[Length(Dividend)] := Dividend[High(Dividend)] shr (32 - Shift)
  else
    U[Length(Dividend)] := 0;
  for I := High(Dividend) downto 1 do
    if Shift > 0 then
      U[I] := (Dividend[I] shl Shift) or (Dividend[I - 1] shr (32 - Shift))
    else
      U[I] := Dividend[I];
  U[0] := Dividend[0] shl Shift;
  SetLength(Quotient, M + 1);
  for J := M downto 0 do
  begin
    Top := (QWord(U[J + N]) shl 32) or U[J + N - 1];
    Estimate := Top div V[N - 1];
    RemainderEstimate := Top mod V[N - 1];
    while (Estimate >= QWord(4294967296)) or
      (Estimate * V[N - 2] > ((RemainderEstimate shl 32) or U[J + N - 2])) do
    begin
      Dec(Estimate);
      Inc(RemainderEstimate, V[N - 1]);
      if RemainderEstimate >= QWord(4294967296) then
        Break;
    end;
    Borrow := 0;
    for I := 0 to N - 1 do
    begin
      Product := Estimate * V[I];
      Difference := Int64(U[I + J]) - Int64(Borrow) - Int64(Product and $FFFFFFFF);
      U[I + J] := LongWord(Difference);
      Borrow := (Product shr 32) - QWord(Difference shr 32);
    end;
    Difference := Int64(U[J + N]) - Int64(Borrow);
    U[J + N] := LongWord(Difference);
    if Difference < 0 then
    begin
      Dec(Estimate);
      Carry := 0;
      for I := 0 to N - 1 do
      begin
        Carry := QWord(U[I + J]) + V[I] + Carry;
        U[I + J] := LongWord(Carry);
        Carry := Carry shr 32;
      end;
      U[J + N] := LongWord(QWord(U[J + N]) + Carry);
    end;
    Quotient[J] := LongWord(Estimate);
  end;
  Normalize(Quotient);
  SetLength(Remainder, N);
  for I := 0 to N - 1 do
    if Shift > 0 then
      Remainder[I] := (U[I] shr Shift) or (U[I + 1] shl (32 - Shift))
    else
      Remainder[I] := U[I];
  Normalize(Remainder);
end;

function SignedAdd(Heap: TJsHeap; NegativeA: Boolean; const A: TJsDigits; NegativeB: Boolean;
  const B: TJsDigits): TJsBigInt;
begin
  if NegativeA = NegativeB then
    Exit(NewBigInt(Heap, NegativeA, AddMagnitudes(A, B)));
  if CompareMagnitudes(A, B) >= 0 then
    Result := NewBigInt(Heap, NegativeA, SubtractMagnitudes(A, B))
  else
    Result := NewBigInt(Heap, NegativeB, SubtractMagnitudes(B, A));
end;

function BigIntAdd(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := SignedAdd(Heap, First.Negative, First.Digits, Second.Negative, Second.Digits);
end;

function BigIntSubtract(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := SignedAdd(Heap, First.Negative, First.Digits, not Second.Negative, Second.Digits);
end;

function BigIntMultiply(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := NewBigInt(Heap, First.Negative <> Second.Negative, MultiplyMagnitudes(First.Digits, Second.Digits));
end;

function BigIntDivide(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
var
  Quotient, Remainder: TJsDigits;
begin
  DivideMagnitudes(First.Digits, Second.Digits, Quotient, Remainder);
  Result := NewBigInt(Heap, First.Negative <> Second.Negative, Quotient);
end;

function BigIntRemainder(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
var
  Quotient, Remainder: TJsDigits;
begin
  DivideMagnitudes(First.Digits, Second.Digits, Quotient, Remainder);
  Result := NewBigInt(Heap, First.Negative, Remainder);
end;

function BigIntPower(Heap: TJsHeap; Base: TJsBigInt; Exponent: LongWord): TJsBigInt;
var
  Accumulator, Square: TJsDigits;
  Negative: Boolean;
begin
  Accumulator := nil;
  SetLength(Accumulator, 1);
  Accumulator[0] := 1;
  Square := Copy(Base.Digits);
  Negative := Base.Negative and Odd(Exponent);
  while Exponent > 0 do
  begin
    if Odd(Exponent) then
      Accumulator := MultiplyMagnitudes(Accumulator, Square);
    Exponent := Exponent shr 1;
    if Exponent > 0 then
      Square := MultiplyMagnitudes(Square, Square);
  end;
  Result := NewBigInt(Heap, Negative, Accumulator);
end;

function BigIntNegate(Heap: TJsHeap; Value: TJsBigInt): TJsBigInt;
begin
  Result := NewBigInt(Heap, not Value.Negative, Value.Digits);
end;

function ShiftMagnitudeLeft(const Digits: TJsDigits; Count: Integer): TJsDigits;
var
  WholeDigits, Bits, Index: Integer;
begin
  Result := nil;
  if Length(Digits) = 0 then
    Exit;
  WholeDigits := Count div 32;
  Bits := Count mod 32;
  SetLength(Result, Length(Digits) + WholeDigits + 1);
  for Index := 0 to High(Digits) do
  begin
    Result[Index + WholeDigits] := Result[Index + WholeDigits] or (Digits[Index] shl Bits);
    if Bits > 0 then
      Result[Index + WholeDigits + 1] := Digits[Index] shr (32 - Bits);
  end;
  Normalize(Result);
end;

function ShiftMagnitudeRight(const Digits: TJsDigits; Count: Integer; out LostBits: Boolean): TJsDigits;
var
  WholeDigits, Bits, Index: Integer;
begin
  Result := nil;
  LostBits := False;
  WholeDigits := Count div 32;
  Bits := Count mod 32;
  if WholeDigits >= Length(Digits) then
  begin
    LostBits := Length(Digits) > 0;
    Exit;
  end;
  for Index := 0 to WholeDigits - 1 do
    if Digits[Index] <> 0 then
      LostBits := True;
  if (Bits > 0) and ((Digits[WholeDigits] and ((LongWord(1) shl Bits) - 1)) <> 0) then
    LostBits := True;
  SetLength(Result, Length(Digits) - WholeDigits);
  for Index := 0 to High(Result) do
  begin
    Result[Index] := Digits[Index + WholeDigits] shr Bits;
    if (Bits > 0) and (Index + WholeDigits + 1 < Length(Digits)) then
      Result[Index] := Result[Index] or (Digits[Index + WholeDigits + 1] shl (32 - Bits));
  end;
  Normalize(Result);
end;

function BigIntShiftLeft(Heap: TJsHeap; Value: TJsBigInt; Count: Int64): TJsBigInt;
var
  Digits: TJsDigits;
  LostBits: Boolean;
  One: TJsDigits;
begin
  if Count >= 0 then
    Exit(NewBigInt(Heap, Value.Negative, ShiftMagnitudeLeft(Value.Digits, Count)));
  Digits := ShiftMagnitudeRight(Value.Digits, -Count, LostBits);
  if Value.Negative and LostBits then
  begin
    { Rounds toward minus infinity. }
    One := nil;
    SetLength(One, 1);
    One[0] := 1;
    Digits := AddMagnitudes(Digits, One);
  end;
  Result := NewBigInt(Heap, Value.Negative, Digits);
end;

{ Two's complement digits of Value, Count digits long. }
function ToComplement(Value: TJsBigInt; Count: Integer): TJsDigits;
var
  Index: Integer;
  Carry: QWord;
begin
  Result := nil;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    if Index < Length(Value.Digits) then
      Result[Index] := Value.Digits[Index];
  if Value.Negative then
  begin
    Carry := 1;
    for Index := 0 to Count - 1 do
    begin
      Carry := QWord(not Result[Index]) + Carry;
      Result[Index] := LongWord(Carry);
      Carry := Carry shr 32;
    end;
  end;
end;

function FromComplement(Heap: TJsHeap; Digits: TJsDigits): TJsBigInt;
var
  Index: Integer;
  Carry: QWord;
  Negative: Boolean;
begin
  Negative := (Length(Digits) > 0) and ((Digits[High(Digits)] and $80000000) <> 0);
  if Negative then
  begin
    Carry := 1;
    for Index := 0 to High(Digits) do
    begin
      Carry := QWord(not Digits[Index]) + Carry;
      Digits[Index] := LongWord(Carry);
      Carry := Carry shr 32;
    end;
  end;
  Result := NewBigInt(Heap, Negative, Digits);
end;

function Bitwise(Heap: TJsHeap; First, Second: TJsBigInt; Operation: Integer): TJsBigInt;
var
  Count, Index: Integer;
  A, B, C: TJsDigits;
begin
  Count := Max(Length(First.Digits), Length(Second.Digits)) + 1;
  A := ToComplement(First, Count);
  B := ToComplement(Second, Count);
  C := nil;
  SetLength(C, Count);
  for Index := 0 to Count - 1 do
    case Operation of
      0: C[Index] := A[Index] and B[Index];
      1: C[Index] := A[Index] or B[Index];
    else
      C[Index] := A[Index] xor B[Index];
    end;
  Result := FromComplement(Heap, C);
end;

function BigIntAnd(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := Bitwise(Heap, First, Second, 0);
end;

function BigIntOr(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := Bitwise(Heap, First, Second, 1);
end;

function BigIntXor(Heap: TJsHeap; First, Second: TJsBigInt): TJsBigInt;
begin
  Result := Bitwise(Heap, First, Second, 2);
end;

function BigIntNot(Heap: TJsHeap; Value: TJsBigInt): TJsBigInt;
var
  One: TJsDigits;
begin
  { ~x = -x - 1 }
  One := nil;
  SetLength(One, 1);
  One[0] := 1;
  Result := SignedAdd(Heap, not Value.Negative, Value.Digits, True, One);
end;

function BigIntAsIntN(Heap: TJsHeap; Value: TJsBigInt; Bits: Integer; Signed: Boolean): TJsBigInt;
var
  Count, Index, TopBits: Integer;
  Digits: TJsDigits;
begin
  if Bits = 0 then
    Exit(NewBigInt(Heap, False, nil));
  Count := (Bits + 31) div 32;
  Digits := ToComplement(Value, Count + 1);
  SetLength(Digits, Count);
  TopBits := Bits mod 32;
  if TopBits > 0 then
    Digits[Count - 1] := Digits[Count - 1] and ((LongWord(1) shl TopBits) - 1);
  if Signed and (((Digits[Count - 1] shr ((Bits - 1) mod 32)) and 1) <> 0) then
  begin
    { Sign extend to whole digits and read as negative. }
    if TopBits > 0 then
      Digits[Count - 1] := Digits[Count - 1] or not ((LongWord(1) shl TopBits) - 1);
    Exit(FromComplement(Heap, Digits));
  end;
  SetLength(Digits, Count + 1);
  Digits[Count] := 0;

  Result := NewBigInt(Heap, False, Digits);
end;

function DigitValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'z': Result := Ord(Character) - Ord('a') + 10;
    'A'..'Z': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := 99;
  end;
end;

function BigIntFromText(Heap: TJsHeap; const Text: string; Radix: Integer; Negative: Boolean): TJsBigInt;
var
  Digits: TJsDigits;
  Index, Position, Value: Integer;
  Carry: QWord;
begin
  Result := nil;
  if Text = '' then
    Exit;
  Digits := nil;
  for Position := 1 to Length(Text) do
  begin
    Value := DigitValue(Text[Position]);
    if Value >= Radix then
      Exit(nil);
    Carry := Value;
    for Index := 0 to High(Digits) do
    begin
      Carry := QWord(Digits[Index]) * QWord(Radix) + Carry;
      Digits[Index] := LongWord(Carry);
      Carry := Carry shr 32;
    end;
    if Carry <> 0 then
    begin
      SetLength(Digits, Length(Digits) + 1);
      Digits[High(Digits)] := LongWord(Carry);
    end;
  end;
  Result := NewBigInt(Heap, Negative, Digits);
end;

function BigIntToText(Value: TJsBigInt; Radix: Integer): string;
const
  DigitCharacters = '0123456789abcdefghijklmnopqrstuvwxyz';
var
  Digits: TJsDigits;
  Index: Integer;
  Remainder: QWord;
  Reversed: string;
  Count: Integer;
begin
  if Value.IsZero then
    Exit('0');
  Digits := Copy(Value.Digits);
  Reversed := '';
  while Length(Digits) > 0 do
  begin
    Remainder := 0;
    for Index := High(Digits) downto 0 do
    begin
      Remainder := (Remainder shl 32) or Digits[Index];
      Digits[Index] := LongWord(Remainder div QWord(Radix));
      Remainder := Remainder mod QWord(Radix);
    end;
    Reversed := Reversed + DigitCharacters[Remainder + 1];
    Normalize(Digits);
  end;
  Result := '';
  Count := Length(Reversed);
  SetLength(Result, Count);
  for Index := 1 to Count do
    Result[Index] := Reversed[Count - Index + 1];
  if Value.Negative then
    Result := '-' + Result;
end;

function BigIntToDouble(Value: TJsBigInt): Double;
var
  Index: Integer;
begin
  Result := 0;
  for Index := High(Value.Digits) downto 0 do
    Result := Result * 4294967296.0 + Value.Digits[Index];
  if Value.Negative then
    Result := -Result;
end;

function BigIntToInt64(Value: TJsBigInt): Int64;
var
  Magnitude: QWord;
begin
  Magnitude := 0;
  if Length(Value.Digits) > 0 then
    Magnitude := Value.Digits[0];
  if Length(Value.Digits) > 1 then
    Magnitude := Magnitude or (QWord(Value.Digits[1]) shl 32);
  if Value.Negative then
    Magnitude := QWord(0) - Magnitude;
  Result := Int64(Magnitude);
end;

function BigIntCompare(First, Second: TJsBigInt): Integer;
begin
  if First.Negative <> Second.Negative then
  begin
    if First.Negative then
      Exit(-1);
    Exit(1);
  end;
  Result := CompareMagnitudes(First.Digits, Second.Digits);
  if First.Negative then
    Result := -Result;
end;

function BigIntCompareDouble(First: TJsBigInt; Second: Double): Integer;
var
  Value: Double;
  Whole: Double;
begin
  if not IsFiniteDouble(Second) then
  begin
    if Second > 0 then
      Exit(-1);
    Exit(1);
  end;
  Value := BigIntToDouble(First);
  if Value < Second then
    Exit(-1);
  if Value > Second then
    Exit(1);
  { Equal as doubles: the BigInt may have lost low digits. }
  Whole := Int(Second);
  if Whole <> Second then
  begin
    if Second > Whole then
      Exit(-1);
    Exit(1);
  end;
  Result := 0;
end;

end.
