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

  The field arithmetic is Crypto.Curve25519Field's. The Montgomery ladder swaps by masks and every step runs the same
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
  Crypto.Bits,
  Crypto.Curve25519Field;

const
  { (A - 2) / 4 for Curve25519's A = 486662: 121665 in limbs. }
  CurveConstant: TCurve25519Element = ($DB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

{ The Montgomery ladder (RFC 7748 section 5). }
procedure ScalarMultiply(Output: PByte; Scalar: PByte; Point: PByte);
var
  ClampedScalar: array[0..31] of Byte;
  BaseX: TCurve25519Element;
  X2, Z2, X3, Z3: TCurve25519Element;
  E, F: TCurve25519Element;
  Bit: Integer;
  Swap: Int64;
  Index: Integer;
begin
  for Index := 0 to 31 do
    ClampedScalar[Index] := Scalar[Index];
  ClampedScalar[0] := ClampedScalar[0] and 248;
  ClampedScalar[31] := (ClampedScalar[31] and 127) or 64;
  Curve25519Unpack(BaseX, Point);

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
    Curve25519Swap(X2, X3, Swap);
    Curve25519Swap(Z2, Z3, Swap);
    { One ladder step: (X2:Z2) doubles, (X3:Z3) becomes the sum. }
    Curve25519Add(E, X2, Z2);
    Curve25519Subtract(X2, X2, Z2);
    Curve25519Add(Z2, X3, Z3);
    Curve25519Subtract(X3, X3, Z3);
    Curve25519Square(Z3, E);
    Curve25519Square(F, X2);
    Curve25519Multiply(X2, Z2, X2);
    Curve25519Multiply(Z2, X3, E);
    Curve25519Add(E, X2, Z2);
    Curve25519Subtract(X2, X2, Z2);
    Curve25519Square(X3, X2);
    Curve25519Subtract(Z2, Z3, F);
    Curve25519Multiply(X2, Z2, CurveConstant);
    Curve25519Add(X2, X2, Z3);
    Curve25519Multiply(Z2, Z2, X2);
    Curve25519Multiply(X2, Z3, F);
    Curve25519Multiply(Z3, X3, BaseX);
    Curve25519Square(X3, E);
    Curve25519Swap(X2, X3, Swap);
    Curve25519Swap(Z2, Z3, Swap);
  end;

  Curve25519Invert(Z2, Z2);
  Curve25519Multiply(X2, X2, Z2);
  Curve25519Pack(Output, X2);

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
