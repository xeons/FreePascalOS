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
  Arithmetic in the field of integers mod p = 2^255 - 19, shared by
  X25519 (Curve25519 in Montgomery form) and Ed25519 (the same curve in
  twisted Edwards form).

  An element is sixteen limbs of 16 bits held in 64-bit signed integers,
  so products and their sums cannot overflow. Limbs may be negative or
  a little over 16 bits between operations; Curve25519Pack gives the
  one fully reduced value. Every routine runs the same operations
  whatever the values, so the time taken does not depend on secrets.
}
unit Crypto.Curve25519Field;

{$mode objfpc}
{$pointermath on}

interface

type
  TCurve25519Element = array[0..15] of Int64;

const
  Curve25519Zero: TCurve25519Element = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  Curve25519One: TCurve25519Element = (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

{ Brings every limb back into 16 bits. }
procedure Curve25519Carry(var Element: TCurve25519Element);
{ Swaps First and Second when Swap is 1, leaves them when it is 0. }
procedure Curve25519Swap(var First, Second: TCurve25519Element; Swap: Int64);
procedure Curve25519Add(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
procedure Curve25519Subtract(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
procedure Curve25519Multiply(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
procedure Curve25519Square(out Result: TCurve25519Element; const Value: TCurve25519Element);
{ 1 / Value (Value^(p - 2)). }
procedure Curve25519Invert(out Result: TCurve25519Element; const Value: TCurve25519Element);
{ Value^((p - 5) / 8) = Value^(2^252 - 3), for square roots. }
procedure Curve25519PowerForRoot(out Result: TCurve25519Element; const Value: TCurve25519Element);
{ From 32 little endian bytes; the top bit is ignored. }
procedure Curve25519Unpack(out Element: TCurve25519Element; Bytes: PByte);
{ The fully reduced value (below p) as 32 little endian bytes. }
procedure Curve25519Pack(Bytes: PByte; const Element: TCurve25519Element);
{ The lowest bit of the reduced value (the "sign" of an Ed25519 x). }
function Curve25519Parity(const Element: TCurve25519Element): Integer;
{ True when the two reduce to different values. }
function Curve25519Differ(const First, Second: TCurve25519Element): Boolean;

implementation

uses
  Crypto.Bits;

procedure Curve25519Carry(var Element: TCurve25519Element);
var
  Index: Integer;
  CarryValue: Int64;
begin
  for Index := 0 to 15 do
  begin
    { Arithmetic shifts keep negative limbs right. }
    CarryValue := SarInt64(Element[Index], 16);
    Element[Index] := Element[Index] - (CarryValue shl 16);
    if Index < 15 then
      Element[Index + 1] := Element[Index + 1] + CarryValue
    else
      { 2^256 = 38 mod p. }
      Element[0] := Element[0] + 38 * CarryValue;
  end;
end;

procedure Curve25519Swap(var First, Second: TCurve25519Element; Swap: Int64);
var
  Mask: Int64;
  Difference: Int64;
  Index: Integer;
begin
  Mask := not (Swap - 1);
  for Index := 0 to 15 do
  begin
    Difference := Mask and (First[Index] xor Second[Index]);
    First[Index] := First[Index] xor Difference;
    Second[Index] := Second[Index] xor Difference;
  end;
end;

procedure Curve25519Add(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Result[Index] := First[Index] + Second[Index];
end;

procedure Curve25519Subtract(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Result[Index] := First[Index] - Second[Index];
end;

procedure Curve25519Multiply(out Result: TCurve25519Element; const First, Second: TCurve25519Element);
var
  Product: array[0..30] of Int64;
  Outer, Inner: Integer;
begin
  for Outer := 0 to 30 do
    Product[Outer] := 0;
  for Outer := 0 to 15 do
    for Inner := 0 to 15 do
      Product[Outer + Inner] := Product[Outer + Inner] + First[Outer] * Second[Inner];
  { Limb 16 + i weighs 2^256 times limb i: fold it back times 38. }
  for Outer := 0 to 14 do
    Product[Outer] := Product[Outer] + 38 * Product[Outer + 16];
  for Outer := 0 to 15 do
    Result[Outer] := Product[Outer];
  Curve25519Carry(Result);
  Curve25519Carry(Result);
end;

procedure Curve25519Square(out Result: TCurve25519Element; const Value: TCurve25519Element);
begin
  Curve25519Multiply(Result, Value, Value);
end;

procedure Curve25519Invert(out Result: TCurve25519Element; const Value: TCurve25519Element);
var
  Power: TCurve25519Element;
  Temporary: TCurve25519Element;
  Bit: Integer;
begin
  { p - 2 = 2^255 - 21: every bit set but bits 2 and 4. }
  Power := Value;
  for Bit := 253 downto 0 do
  begin
    Curve25519Square(Temporary, Power);
    if (Bit <> 2) and (Bit <> 4) then
      Curve25519Multiply(Power, Temporary, Value)
    else
      Power := Temporary;
  end;
  Result := Power;
end;

procedure Curve25519PowerForRoot(out Result: TCurve25519Element; const Value: TCurve25519Element);
var
  Power: TCurve25519Element;
  Temporary: TCurve25519Element;
  Bit: Integer;
begin
  { 2^252 - 3: every bit of 251 bits set but bit 1. }
  Power := Value;
  for Bit := 250 downto 0 do
  begin
    Curve25519Square(Temporary, Power);
    if Bit <> 1 then
      Curve25519Multiply(Power, Temporary, Value)
    else
      Power := Temporary;
  end;
  Result := Power;
end;

procedure Curve25519Unpack(out Element: TCurve25519Element; Bytes: PByte);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Element[Index] := Int64(Bytes[2 * Index]) + (Int64(Bytes[2 * Index + 1]) shl 8);
  Element[15] := Element[15] and $7FFF;
end;

procedure Curve25519Pack(Bytes: PByte; const Element: TCurve25519Element);
var
  Value: TCurve25519Element;
  Reduced: TCurve25519Element;
  Borrow: Int64;
  Pass, Index: Integer;
begin
  Value := Element;
  Curve25519Carry(Value);
  Curve25519Carry(Value);
  Curve25519Carry(Value);
  { Subtract p twice if that does not go negative, choosing by masks. }
  for Pass := 1 to 2 do
  begin
    Reduced[0] := Value[0] - $FFED;
    for Index := 1 to 14 do
    begin
      Reduced[Index] := Value[Index] - $FFFF - ((Reduced[Index - 1] shr 16) and 1);
      Reduced[Index - 1] := Reduced[Index - 1] and $FFFF;
    end;
    Reduced[15] := Value[15] - $7FFF - ((Reduced[14] shr 16) and 1);
    Borrow := (Reduced[15] shr 16) and 1;
    Reduced[14] := Reduced[14] and $FFFF;
    Curve25519Swap(Value, Reduced, 1 - Borrow);
  end;
  for Index := 0 to 15 do
  begin
    Bytes[2 * Index] := Byte(Value[Index] and $FF);
    Bytes[2 * Index + 1] := Byte((Value[Index] shr 8) and $FF);
  end;
  WipeMemory(@Value[0], SizeOf(Value));
  WipeMemory(@Reduced[0], SizeOf(Reduced));
end;

function Curve25519Parity(const Element: TCurve25519Element): Integer;
var
  Bytes: array[0..31] of Byte;
begin
  Curve25519Pack(@Bytes[0], Element);
  Result := Bytes[0] and 1;
end;

function Curve25519Differ(const First, Second: TCurve25519Element): Boolean;
var
  FirstBytes, SecondBytes: array[0..31] of Byte;
begin
  Curve25519Pack(@FirstBytes[0], First);
  Curve25519Pack(@SecondBytes[0], Second);
  Result := not ConstantTimeEqual(@FirstBytes[0], @SecondBytes[0], 32);
end;

end.
