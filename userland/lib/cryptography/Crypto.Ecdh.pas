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
  Elliptic curve Diffie-Hellman on the NIST curves P-256, P-384 and
  P-521 (SEC 1 section 3.3.1), for key exchange (TLS's secp256r1,
  secp384r1 and secp521r1 groups):

    GenerateEcdsaPrivateKey(CurveP256, PrivateKey);          (Crypto.KeyGeneration)
    EcdhPublicKey(CurveP256, PrivateKey, 32, PublicKey);     (65 bytes, 04 || x || y)
    EcdhSharedSecret(CurveP256, PrivateKey, 32, PeerKey, 65, Secret);   (x, 32 bytes)

  The private scalar is secret, so it is not multiplied by doubling and
  adding: a Montgomery ladder does the same point operations for every
  bit, swapping its two points by masks rather than branches, over a
  scalar made a fixed number of bits long (k + n or k + 2n, the same
  multiple of a point of order n). The big number arithmetic underneath
  (Crypto.BigNumbers) still takes time that depends on the values; the
  keys TLS uses this for are made for one handshake and dropped.

  The peer's point must be on the curve (Crypto.EllipticCurves checks);
  a shared point at infinity is refused.
}
unit Crypto.Ecdh;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.EllipticCurves;

{ Bytes of a public key (an uncompressed point) and of a shared secret. }
function EcdhPublicKeyLength(Curve: TCurveName): Integer;
function EcdhSharedSecretLength(Curve: TCurveName): Integer;

{ d G as an uncompressed point. False when d is not in [1, n - 1]. }
function EcdhPublicKey(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PublicKey: PByte): Boolean;
{ The x coordinate of d Q, big endian, the curve's coordinate size.
  False for a bad d, a peer key not on the curve, or infinity. }
function EcdhSharedSecret(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PeerPublicKey: PByte;
  PeerPublicKeyLength: PtrUInt; SharedSecret: PByte): Boolean;

implementation

uses
  Crypto.BigNumbers,
  Crypto.Bits;

function EcdhPublicKeyLength(Curve: TCurveName): Integer;
begin
  Result := 1 + 2 * EcdhSharedSecretLength(Curve);
end;

function EcdhSharedSecretLength(Curve: TCurveName): Integer;
begin
  case Curve of
    CurveP256: Result := 32;
    CurveP384: Result := 48;
  else
    Result := 66;
  end;
end;

{ All ones when the low bit of Condition is 1, zero when it is 0. }
function MaskOf(Condition: LongWord): LongWord;
begin
  Result := LongWord(0) - (Condition and 1);
end;

procedure SwapNumbersIf(var First, Second: TBigNumber; Mask: LongWord; Width: Integer);
var
  Index: Integer;
  Difference: LongWord;
  CountDifference: LongInt;
begin
  for Index := 0 to Width - 1 do
  begin
    Difference := (First.Limbs[Index] xor Second.Limbs[Index]) and Mask;
    First.Limbs[Index] := First.Limbs[Index] xor Difference;
    Second.Limbs[Index] := Second.Limbs[Index] xor Difference;
  end;
  CountDifference := (First.LimbCount xor Second.LimbCount) and LongInt(Mask);
  First.LimbCount := First.LimbCount xor CountDifference;
  Second.LimbCount := Second.LimbCount xor CountDifference;
end;

procedure SwapPointsIf(var First, Second: TCurvePoint; Mask: LongWord; Width: Integer);
var
  FirstInfinity, SecondInfinity: LongWord;
begin
  SwapNumbersIf(First.X, Second.X, Mask, Width);
  SwapNumbersIf(First.Y, Second.Y, Mask, Width);
  SwapNumbersIf(First.Z, Second.Z, Mask, Width);
  FirstInfinity := LongWord(Ord(First.IsInfinity));
  SecondInfinity := LongWord(Ord(Second.IsInfinity));
  First.IsInfinity := ((FirstInfinity and not Mask) or (SecondInfinity and Mask)) <> 0;
  Second.IsInfinity := ((SecondInfinity and not Mask) or (FirstInfinity and Mask)) <> 0;
end;

{ k + n when that has OrderBits + 1 bits, else k + 2n (which then has),
  picked by mask. }
procedure FixScalarLength(constref Curve: TEllipticCurve; constref Scalar: TBigNumber; out Fixed: TBigNumber);
var
  PlusOrder, PlusTwoOrders: TBigNumber;
  Mask: LongWord;
  Index: Integer;
begin
  AddBigNumbers(PlusOrder, Scalar, Curve.Order.Modulus);
  AddBigNumbers(PlusTwoOrders, PlusOrder, Curve.Order.Modulus);
  Mask := MaskOf(PlusOrder.Limbs[Curve.OrderBits div 32] shr (Curve.OrderBits mod 32));
  SetBigNumberZero(Fixed);
  for Index := 0 to Curve.OrderBits div 32 do
    Fixed.Limbs[Index] := (PlusOrder.Limbs[Index] and Mask) or (PlusTwoOrders.Limbs[Index] and not Mask);
  Fixed.LimbCount := Curve.OrderBits div 32 + 1;
  WipeMemory(@PlusOrder, SizeOf(PlusOrder));
  WipeMemory(@PlusTwoOrders, SizeOf(PlusTwoOrders));
end;

{ Scalar (in [1, n - 1]) times Point by a Montgomery ladder. }
procedure LadderMultiply(constref Curve: TEllipticCurve; constref Scalar: TBigNumber; constref Point: TCurvePoint;
  out Product: TCurvePoint);
var
  Fixed: TBigNumber;
  Low, High: TCurvePoint;
  Bit: Integer;
  Mask: LongWord;
  Width: Integer;
begin
  FixScalarLength(Curve, Scalar, Fixed);
  Width := Curve.Field.Width;
  { The top bit (bit OrderBits) is set: start from P and 2P. }
  Low := Point;
  DoublePoint(Curve, Point, High);
  for Bit := Curve.OrderBits - 1 downto 0 do
  begin
    Mask := MaskOf(Fixed.Limbs[Bit div 32] shr (Bit mod 32));
    SwapPointsIf(Low, High, Mask, Width);
    AddPoints(Curve, Low, High, High);
    DoublePoint(Curve, Low, Low);
    SwapPointsIf(Low, High, Mask, Width);
  end;
  Product := Low;
  WipeMemory(@Fixed, SizeOf(Fixed));
  WipeMemory(@High, SizeOf(High));
  WipeMemory(@Low, SizeOf(Low));
end;

function ReadPrivateScalar(constref Curve: TEllipticCurve; PrivateKey: PByte; PrivateKeyLength: PtrUInt;
  out Scalar: TBigNumber): Boolean;
begin
  Result := BigNumberFromBytes(Scalar, PrivateKey, PrivateKeyLength) and not BigNumberIsZero(Scalar) and
    (CompareBigNumbers(Scalar, Curve.Order.Modulus) < 0);
end;

function EcdhPublicKey(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PublicKey: PByte): Boolean;
var
  Parameters: TEllipticCurve;
  Scalar: TBigNumber;
  Generator, KeyPoint: TCurvePoint;
begin
  PrepareCurve(Curve, Parameters);
  Result := ReadPrivateScalar(Parameters, PrivateKey, PrivateKeyLength, Scalar);
  if Result then
  begin
    GeneratorPoint(Parameters, Generator);
    LadderMultiply(Parameters, Scalar, Generator, KeyPoint);
    Result := EncodeCurvePoint(Parameters, KeyPoint, PublicKey);
    WipeMemory(@KeyPoint, SizeOf(KeyPoint));
  end;
  WipeMemory(@Scalar, SizeOf(Scalar));
end;

function EcdhSharedSecret(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PeerPublicKey: PByte;
  PeerPublicKeyLength: PtrUInt; SharedSecret: PByte): Boolean;
var
  Parameters: TEllipticCurve;
  Scalar, X: TBigNumber;
  Peer, Shared: TCurvePoint;
begin
  Result := False;
  PrepareCurve(Curve, Parameters);
  if not DecodeCurvePoint(Parameters, PeerPublicKey, PeerPublicKeyLength, Peer) then
    Exit;
  if ReadPrivateScalar(Parameters, PrivateKey, PrivateKeyLength, Scalar) then
  begin
    LadderMultiply(Parameters, Scalar, Peer, Shared);
    Result := AffineX(Parameters, Shared, X) and BigNumberToBytes(X, SharedSecret, Parameters.CoordinateBytes);
    WipeMemory(@Shared, SizeOf(Shared));
    WipeMemory(@X, SizeOf(X));
  end;
  WipeMemory(@Scalar, SizeOf(Scalar));
end;

end.
