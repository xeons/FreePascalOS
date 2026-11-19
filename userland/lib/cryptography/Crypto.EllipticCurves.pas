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
  The NIST prime curves P-256, P-384 and P-521 (FIPS 186-4, SEC 2): y^2 = x^3 -
  3x + b over the integers mod p, with points in Jacobian coordinates
  (x = X / Z^2, y = Y / Z^3) whose coordinates are kept in Montgomery
  form (Crypto.BigNumbers).

  For checking signatures only: the arithmetic works on public points
  and scalars and takes time that depends on them.
}
unit Crypto.EllipticCurves;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Crypto.BigNumbers;

type
  TCurveName = (CurveP256, CurveP384, CurveP521);

  TEllipticCurve = record
    Name: TCurveName;
    { The field (p) and the order of the base point (n). }
    Field: TMontgomeryModulus;
    Order: TMontgomeryModulus;
    { b and the base point, in Montgomery form. }
    B: TBigNumber;
    GeneratorX, GeneratorY: TBigNumber;
    { Bytes of a coordinate (32, 48 or 66), bits of n (256, 384 or 521). }
    CoordinateBytes: Integer;
    OrderBits: Integer;
  end;

  TCurvePoint = record
    X, Y, Z: TBigNumber;
    IsInfinity: Boolean;
  end;

procedure PrepareCurve(Name: TCurveName; out Curve: TEllipticCurve);

{ An uncompressed point (04 || x || y), checked to lie on the curve with
  coordinates below p. Compressed points and the point at infinity are
  refused. }
function DecodeCurvePoint(constref Curve: TEllipticCurve; Bytes: PByte; Count: PtrUInt;
  out Point: TCurvePoint): Boolean;

procedure GeneratorPoint(constref Curve: TEllipticCurve; out Point: TCurvePoint);
procedure DoublePoint(constref Curve: TEllipticCurve; constref Point: TCurvePoint; out Doubled: TCurvePoint);
procedure AddPoints(constref Curve: TEllipticCurve; constref First, Second: TCurvePoint; out Sum: TCurvePoint);
{ Scalar (ordinary form, any size) times Point. }
procedure MultiplyPoint(constref Curve: TEllipticCurve; constref Scalar: TBigNumber; constref Point: TCurvePoint;
  out Product: TCurvePoint);
{ The affine x coordinate in ordinary form; False for infinity. }
function AffineX(constref Curve: TEllipticCurve; constref Point: TCurvePoint; out X: TBigNumber): Boolean;
{ The point as uncompressed bytes (04 || x || y), 1 + 2 CoordinateBytes
  of them; False for infinity. }
function EncodeCurvePoint(constref Curve: TEllipticCurve; constref Point: TCurvePoint; Bytes: PByte): Boolean;

implementation

const
  P256Prime = 'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff';
  P256B = '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b';
  P256GeneratorX = '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296';
  P256GeneratorY = '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5';
  P256Order = 'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551';

  P384Prime = 'fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe' +
    'ffffffff0000000000000000ffffffff';
  P384B = 'b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875a' +
    'c656398d8a2ed19d2a85c8edd3ec2aef';
  P384GeneratorX = 'aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a38' +
    '5502f25dbf55296c3a545e3872760ab7';
  P384GeneratorY = '3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c0' +
    '0a60b1ce1d7e819d7a431d7c90ea0e5f';
  P384Order = 'ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf' +
    '581a0db248b0a77aecec196accc52973';

  P521Prime = '01ff' + 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' +
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
  P521B = '0051' + '953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e1' +
    '56193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00';
  P521GeneratorX = '00c6' + '858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dba' +
    'a14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66';
  P521GeneratorY = '0118' + '39296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c' +
    '97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650';
  P521Order = '01ff' + 'fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa' +
    '51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409';

procedure LoadMontgomery(constref Field: TMontgomeryModulus; const Digits: string; out Value: TBigNumber);
var
  Ordinary: TBigNumber;
begin
  BigNumberFromHex(Ordinary, Digits);
  ToMontgomeryForm(Field, Ordinary, Value);
end;

procedure PrepareCurve(Name: TCurveName; out Curve: TEllipticCurve);
var
  Prime, Order: TBigNumber;
  BDigits, XDigits, YDigits: string;
begin
  FillChar(Curve, SizeOf(Curve), 0);
  Curve.Name := Name;
  case Name of
    CurveP256:
      begin
        BigNumberFromHex(Prime, P256Prime);
        BigNumberFromHex(Order, P256Order);
        BDigits := P256B;
        XDigits := P256GeneratorX;
        YDigits := P256GeneratorY;
        Curve.CoordinateBytes := 32;
      end;
    CurveP384:
      begin
        BigNumberFromHex(Prime, P384Prime);
        BigNumberFromHex(Order, P384Order);
        BDigits := P384B;
        XDigits := P384GeneratorX;
        YDigits := P384GeneratorY;
        Curve.CoordinateBytes := 48;
      end;
  else
    begin
      BigNumberFromHex(Prime, P521Prime);
      BigNumberFromHex(Order, P521Order);
      BDigits := P521B;
      XDigits := P521GeneratorX;
      YDigits := P521GeneratorY;
      Curve.CoordinateBytes := 66;
    end;
  end;
  PrepareMontgomeryModulus(Curve.Field, Prime);
  PrepareMontgomeryModulus(Curve.Order, Order);
  LoadMontgomery(Curve.Field, BDigits, Curve.B);
  LoadMontgomery(Curve.Field, XDigits, Curve.GeneratorX);
  LoadMontgomery(Curve.Field, YDigits, Curve.GeneratorY);
  Curve.OrderBits := BigNumberBitLength(Order);
end;

procedure SetInfinity(out Point: TCurvePoint);
begin
  SetBigNumberZero(Point.X);
  SetBigNumberZero(Point.Y);
  SetBigNumberZero(Point.Z);
  Point.IsInfinity := True;
end;

{ Short names for the field operations, all in Montgomery form. }
procedure FieldMultiply(constref Curve: TEllipticCurve; constref First, Second: TBigNumber; out Product: TBigNumber);
begin
  MontgomeryMultiply(Curve.Field, First, Second, Product);
end;

procedure FieldSquare(constref Curve: TEllipticCurve; constref Value: TBigNumber; out Square: TBigNumber);
begin
  MontgomeryMultiply(Curve.Field, Value, Value, Square);
end;

procedure FieldAdd(constref Curve: TEllipticCurve; constref First, Second: TBigNumber; out Sum: TBigNumber);
begin
  ModularAdd(Curve.Field, First, Second, Sum);
end;

procedure FieldSubtract(constref Curve: TEllipticCurve; constref First, Second: TBigNumber;
  out Difference: TBigNumber);
begin
  ModularSubtract(Curve.Field, First, Second, Difference);
end;

{ Value * 2^Doublings. }
procedure FieldDouble(constref Curve: TEllipticCurve; constref Value: TBigNumber; Doublings: Integer;
  out Doubled: TBigNumber);
var
  Accumulator: TBigNumber;
  Step: Integer;
begin
  Accumulator := Value;
  for Step := 1 to Doublings do
    ModularAdd(Curve.Field, Accumulator, Accumulator, Accumulator);
  Doubled := Accumulator;
end;

function DecodeCurvePoint(constref Curve: TEllipticCurve; Bytes: PByte; Count: PtrUInt;
  out Point: TCurvePoint): Boolean;
var
  OrdinaryX, OrdinaryY: TBigNumber;
  Left, Right, Temporary, ThreeX: TBigNumber;
begin
  SetInfinity(Point);
  Result := False;
  if Count <> PtrUInt(1 + 2 * Curve.CoordinateBytes) then
    Exit;
  if Bytes[0] <> 4 then
    Exit;
  BigNumberFromBytes(OrdinaryX, Bytes + 1, Curve.CoordinateBytes);
  BigNumberFromBytes(OrdinaryY, Bytes + 1 + Curve.CoordinateBytes, Curve.CoordinateBytes);
  if (CompareBigNumbers(OrdinaryX, Curve.Field.Modulus) >= 0) or
     (CompareBigNumbers(OrdinaryY, Curve.Field.Modulus) >= 0) then
    Exit;
  ToMontgomeryForm(Curve.Field, OrdinaryX, Point.X);
  ToMontgomeryForm(Curve.Field, OrdinaryY, Point.Y);
  Point.Z := Curve.Field.MontgomeryOne;
  Point.IsInfinity := False;

  { y^2 = x^3 - 3x + b }
  FieldSquare(Curve, Point.Y, Left);
  FieldSquare(Curve, Point.X, Temporary);
  FieldMultiply(Curve, Temporary, Point.X, Right);
  FieldAdd(Curve, Point.X, Point.X, ThreeX);
  FieldAdd(Curve, ThreeX, Point.X, ThreeX);
  FieldSubtract(Curve, Right, ThreeX, Right);
  FieldAdd(Curve, Right, Curve.B, Right);
  Result := BigNumbersEqual(Left, Right);
  if not Result then
    SetInfinity(Point);
end;

procedure GeneratorPoint(constref Curve: TEllipticCurve; out Point: TCurvePoint);
begin
  Point.X := Curve.GeneratorX;
  Point.Y := Curve.GeneratorY;
  Point.Z := Curve.Field.MontgomeryOne;
  Point.IsInfinity := False;
end;

{ "dbl-2001-b" for a = -3 (Bernstein and Lange's Explicit-Formulas
  Database). }
procedure DoublePoint(constref Curve: TEllipticCurve; constref Point: TCurvePoint; out Doubled: TCurvePoint);
var
  Delta, Gamma, Beta, Alpha: TBigNumber;
  Sum, Difference, Temporary: TBigNumber;
  Computed: TCurvePoint;
begin
  if Point.IsInfinity or BigNumberIsZero(Point.Y) then
  begin
    SetInfinity(Doubled);
    Exit;
  end;
  FieldSquare(Curve, Point.Z, Delta);
  FieldSquare(Curve, Point.Y, Gamma);
  FieldMultiply(Curve, Point.X, Gamma, Beta);
  { alpha = 3 (X - delta)(X + delta) }
  FieldSubtract(Curve, Point.X, Delta, Difference);
  FieldAdd(Curve, Point.X, Delta, Sum);
  FieldMultiply(Curve, Difference, Sum, Temporary);
  FieldAdd(Curve, Temporary, Temporary, Alpha);
  FieldAdd(Curve, Alpha, Temporary, Alpha);
  { X3 = alpha^2 - 8 beta }
  FieldSquare(Curve, Alpha, Computed.X);
  FieldDouble(Curve, Beta, 3, Temporary);
  FieldSubtract(Curve, Computed.X, Temporary, Computed.X);
  { Z3 = (Y + Z)^2 - gamma - delta }
  FieldAdd(Curve, Point.Y, Point.Z, Sum);
  FieldSquare(Curve, Sum, Computed.Z);
  FieldSubtract(Curve, Computed.Z, Gamma, Computed.Z);
  FieldSubtract(Curve, Computed.Z, Delta, Computed.Z);
  { Y3 = alpha (4 beta - X3) - 8 gamma^2 }
  FieldDouble(Curve, Beta, 2, Temporary);
  FieldSubtract(Curve, Temporary, Computed.X, Temporary);
  FieldMultiply(Curve, Alpha, Temporary, Computed.Y);
  FieldSquare(Curve, Gamma, Temporary);
  FieldDouble(Curve, Temporary, 3, Temporary);
  FieldSubtract(Curve, Computed.Y, Temporary, Computed.Y);
  Computed.IsInfinity := False;
  Doubled := Computed;
end;

{ "add-2007-bl". }
procedure AddPoints(constref Curve: TEllipticCurve; constref First, Second: TCurvePoint; out Sum: TCurvePoint);
var
  Z1Squared, Z2Squared: TBigNumber;
  U1, U2, S1, S2: TBigNumber;
  H, I, J, R, V: TBigNumber;
  Temporary: TBigNumber;
  Computed: TCurvePoint;
begin
  if First.IsInfinity then
  begin
    Sum := Second;
    Exit;
  end;
  if Second.IsInfinity then
  begin
    Sum := First;
    Exit;
  end;
  FieldSquare(Curve, First.Z, Z1Squared);
  FieldSquare(Curve, Second.Z, Z2Squared);
  FieldMultiply(Curve, First.X, Z2Squared, U1);
  FieldMultiply(Curve, Second.X, Z1Squared, U2);
  FieldMultiply(Curve, First.Y, Second.Z, Temporary);
  FieldMultiply(Curve, Temporary, Z2Squared, S1);
  FieldMultiply(Curve, Second.Y, First.Z, Temporary);
  FieldMultiply(Curve, Temporary, Z1Squared, S2);
  FieldSubtract(Curve, U2, U1, H);
  FieldSubtract(Curve, S2, S1, R);
  if BigNumberIsZero(H) then
  begin
    { The same x: the same point (double it) or opposite points. }
    if BigNumberIsZero(R) then
      DoublePoint(Curve, First, Sum)
    else
      SetInfinity(Sum);
    Exit;
  end;
  FieldAdd(Curve, R, R, R);
  { I = (2H)^2, J = H I, V = U1 I }
  FieldAdd(Curve, H, H, Temporary);
  FieldSquare(Curve, Temporary, I);
  FieldMultiply(Curve, H, I, J);
  FieldMultiply(Curve, U1, I, V);
  { X3 = r^2 - J - 2V }
  FieldSquare(Curve, R, Computed.X);
  FieldSubtract(Curve, Computed.X, J, Computed.X);
  FieldSubtract(Curve, Computed.X, V, Computed.X);
  FieldSubtract(Curve, Computed.X, V, Computed.X);
  { Y3 = r (V - X3) - 2 S1 J }
  FieldSubtract(Curve, V, Computed.X, Temporary);
  FieldMultiply(Curve, R, Temporary, Computed.Y);
  FieldMultiply(Curve, S1, J, Temporary);
  FieldAdd(Curve, Temporary, Temporary, Temporary);
  FieldSubtract(Curve, Computed.Y, Temporary, Computed.Y);
  { Z3 = ((Z1 + Z2)^2 - Z1Z1 - Z2Z2) H }
  FieldAdd(Curve, First.Z, Second.Z, Temporary);
  FieldSquare(Curve, Temporary, Temporary);
  FieldSubtract(Curve, Temporary, Z1Squared, Temporary);
  FieldSubtract(Curve, Temporary, Z2Squared, Temporary);
  FieldMultiply(Curve, Temporary, H, Computed.Z);
  Computed.IsInfinity := False;
  Sum := Computed;
end;

procedure MultiplyPoint(constref Curve: TEllipticCurve; constref Scalar: TBigNumber; constref Point: TCurvePoint;
  out Product: TCurvePoint);
var
  Accumulator: TCurvePoint;
  Bit: Integer;
begin
  SetInfinity(Accumulator);
  for Bit := BigNumberBitLength(Scalar) - 1 downto 0 do
  begin
    DoublePoint(Curve, Accumulator, Accumulator);
    if BigNumberBit(Scalar, Bit) then
      AddPoints(Curve, Accumulator, Point, Accumulator);
  end;
  Product := Accumulator;
end;

function AffineX(constref Curve: TEllipticCurve; constref Point: TCurvePoint; out X: TBigNumber): Boolean;
var
  ZInverse, ZInverseSquared, MontgomeryX: TBigNumber;
begin
  SetBigNumberZero(X);
  if Point.IsInfinity or BigNumberIsZero(Point.Z) then
    Exit(False);
  MontgomeryInverseForPrime(Curve.Field, Point.Z, ZInverse);
  FieldSquare(Curve, ZInverse, ZInverseSquared);
  FieldMultiply(Curve, Point.X, ZInverseSquared, MontgomeryX);
  FromMontgomeryForm(Curve.Field, MontgomeryX, X);
  Result := True;
end;

function EncodeCurvePoint(constref Curve: TEllipticCurve; constref Point: TCurvePoint; Bytes: PByte): Boolean;
var
  ZInverse, ZInverseSquared, ZInverseCubed: TBigNumber;
  MontgomeryX, MontgomeryY, X, Y: TBigNumber;
begin
  if Point.IsInfinity or BigNumberIsZero(Point.Z) then
    Exit(False);
  { Jacobian coordinates: x = X / Z^2, y = Y / Z^3. }
  MontgomeryInverseForPrime(Curve.Field, Point.Z, ZInverse);
  FieldSquare(Curve, ZInverse, ZInverseSquared);
  FieldMultiply(Curve, ZInverseSquared, ZInverse, ZInverseCubed);
  FieldMultiply(Curve, Point.X, ZInverseSquared, MontgomeryX);
  FieldMultiply(Curve, Point.Y, ZInverseCubed, MontgomeryY);
  FromMontgomeryForm(Curve.Field, MontgomeryX, X);
  FromMontgomeryForm(Curve.Field, MontgomeryY, Y);
  Bytes[0] := 4;
  Result := BigNumberToBytes(X, Bytes + 1, Curve.CoordinateBytes) and
    BigNumberToBytes(Y, Bytes + 1 + Curve.CoordinateBytes, Curve.CoordinateBytes);
end;

end.
