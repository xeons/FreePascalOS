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
  X25519 (RFC 7748): Diffie-Hellman on Curve25519. A random 32-byte
  private key gives a public key (X25519PublicKey); one side's private
  key and the other's public key give both sides the same shared secret
  (X25519SharedSecret).

  Field elements mod 2^255 - 19 are sixteen limbs of 16 bits held in
  64-bit signed integers, so products and their sums cannot overflow.
  The Montgomery ladder swaps by masks and every step runs the same
  operations whatever the key: the time taken does not depend on it.
}
unit Crypto.X25519;

{$mode objfpc}
{$pointermath on}

interface

const
  X25519KeySize = 32;

{ The public key for a private key (the scalar times the base point 9). }
procedure X25519PublicKey(PrivateKey: PByte; PublicKey: PByte);

{ Scalar multiplication of PeerPublicKey by PrivateKey. False when the
  result is all zeros (the peer sent a point of small order), which a
  protocol must refuse (RFC 7748 section 6.1, RFC 8446 section 7.4.2). }
function X25519SharedSecret(PrivateKey: PByte; PeerPublicKey: PByte; SharedSecret: PByte): Boolean;

implementation

uses
  Crypto.Bits;

type
  TFieldElement = array[0..15] of Int64;

const
  { (A - 2) / 4 for Curve25519's A = 486662: 121665 in limbs. }
  CurveConstant: TFieldElement = ($DB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

{ Brings every limb back into 16 bits, the carry out of the top limb
  coming back times 38 (2^256 = 38 mod p). Arithmetic shifts keep
  negative limbs right. }
procedure Carry(var Element: TFieldElement);
var
  Index: Integer;
  CarryValue: Int64;
begin
  for Index := 0 to 15 do
  begin
    CarryValue := SarInt64(Element[Index], 16);
    Element[Index] := Element[Index] - (CarryValue shl 16);
    if Index < 15 then
      Element[Index + 1] := Element[Index + 1] + CarryValue
    else
      Element[0] := Element[0] + 38 * CarryValue;
  end;
end;

{ Swaps First and Second when Swap is 1, leaves them when it is 0. }
procedure ConditionalSwap(var First, Second: TFieldElement; Swap: Int64);
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

procedure Add(out Result: TFieldElement; const First, Second: TFieldElement);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Result[Index] := First[Index] + Second[Index];
end;

procedure Subtract(out Result: TFieldElement; const First, Second: TFieldElement);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Result[Index] := First[Index] - Second[Index];
end;

procedure Multiply(out Result: TFieldElement; const First, Second: TFieldElement);
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
  Carry(Result);
  Carry(Result);
end;

procedure Square(out Result: TFieldElement; const Value: TFieldElement);
begin
  Multiply(Result, Value, Value);
end;

{ Value^(p - 2) = 1 / Value, by a fixed chain of squarings and
  multiplications (p - 2 = 2^255 - 21). }
procedure Invert(out Result: TFieldElement; const Value: TFieldElement);
var
  Power: TFieldElement;
  Temporary: TFieldElement;
  Bit: Integer;
begin
  Power := Value;
  for Bit := 253 downto 0 do
  begin
    Square(Temporary, Power);
    if (Bit <> 2) and (Bit <> 4) then
      Multiply(Power, Temporary, Value)
    else
      Power := Temporary;
  end;
  Result := Power;
end;

procedure Unpack(out Element: TFieldElement; Bytes: PByte);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Element[Index] := Int64(Bytes[2 * Index]) + (Int64(Bytes[2 * Index + 1]) shl 8);
  { The top bit of a u-coordinate is ignored (RFC 7748 section 5). }
  Element[15] := Element[15] and $7FFF;
end;

{ The fully reduced value (below p) as 32 little endian bytes. }
procedure Pack(Bytes: PByte; const Element: TFieldElement);
var
  Value: TFieldElement;
  Reduced: TFieldElement;
  Borrow: Int64;
  Pass, Index: Integer;
begin
  Value := Element;
  Carry(Value);
  Carry(Value);
  Carry(Value);
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
    ConditionalSwap(Value, Reduced, 1 - Borrow);
  end;
  for Index := 0 to 15 do
  begin
    Bytes[2 * Index] := Byte(Value[Index] and $FF);
    Bytes[2 * Index + 1] := Byte((Value[Index] shr 8) and $FF);
  end;
  WipeMemory(@Value[0], SizeOf(Value));
  WipeMemory(@Reduced[0], SizeOf(Reduced));
end;

{ The Montgomery ladder (RFC 7748 section 5). }
procedure ScalarMultiply(Output: PByte; Scalar: PByte; Point: PByte);
var
  ClampedScalar: array[0..31] of Byte;
  BaseX: TFieldElement;
  X2, Z2, X3, Z3: TFieldElement;
  E, F: TFieldElement;
  Bit: Integer;
  Swap: Int64;
  Index: Integer;
begin
  for Index := 0 to 31 do
    ClampedScalar[Index] := Scalar[Index];
  ClampedScalar[0] := ClampedScalar[0] and 248;
  ClampedScalar[31] := (ClampedScalar[31] and 127) or 64;
  Unpack(BaseX, Point);

  for Index := 0 to 15 do
  begin
    X2[Index] := 0;
    Z2[Index] := 0;
    Z3[Index] := 0;
  end;
  X3 := BaseX;
  X2[0] := 1;
  Z3[0] := 1;

  for Bit := 254 downto 0 do
  begin
    Swap := (ClampedScalar[Bit shr 3] shr (Bit and 7)) and 1;
    ConditionalSwap(X2, X3, Swap);
    ConditionalSwap(Z2, Z3, Swap);
    { One ladder step: (X2:Z2) doubles, (X3:Z3) becomes the sum. }
    Add(E, X2, Z2);
    Subtract(X2, X2, Z2);
    Add(Z2, X3, Z3);
    Subtract(X3, X3, Z3);
    Square(Z3, E);
    Square(F, X2);
    Multiply(X2, Z2, X2);
    Multiply(Z2, X3, E);
    Add(E, X2, Z2);
    Subtract(X2, X2, Z2);
    Square(X3, X2);
    Subtract(Z2, Z3, F);
    Multiply(X2, Z2, CurveConstant);
    Add(X2, X2, Z3);
    Multiply(Z2, Z2, X2);
    Multiply(X2, Z3, F);
    Multiply(Z3, X3, BaseX);
    Square(X3, E);
    ConditionalSwap(X2, X3, Swap);
    ConditionalSwap(Z2, Z3, Swap);
  end;

  Invert(Z2, Z2);
  Multiply(X2, X2, Z2);
  Pack(Output, X2);

  WipeMemory(@ClampedScalar[0], SizeOf(ClampedScalar));
  WipeMemory(@X2[0], SizeOf(X2));
  WipeMemory(@Z2[0], SizeOf(Z2));
  WipeMemory(@X3[0], SizeOf(X3));
  WipeMemory(@Z3[0], SizeOf(Z3));
  WipeMemory(@E[0], SizeOf(E));
  WipeMemory(@F[0], SizeOf(F));
end;

procedure X25519PublicKey(PrivateKey: PByte; PublicKey: PByte);
var
  BasePoint: array[0..31] of Byte;
  Index: Integer;
begin
  for Index := 0 to 31 do
    BasePoint[Index] := 0;
  BasePoint[0] := 9;
  ScalarMultiply(PublicKey, PrivateKey, @BasePoint[0]);
end;

function X25519SharedSecret(PrivateKey: PByte; PeerPublicKey: PByte; SharedSecret: PByte): Boolean;
var
  Accumulated: Byte;
  Index: Integer;
begin
  ScalarMultiply(SharedSecret, PrivateKey, PeerPublicKey);
  Accumulated := 0;
  for Index := 0 to 31 do
    Accumulated := Accumulated or SharedSecret[Index];
  Result := Accumulated <> 0;
end;

end.
