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
  Checking ECDSA signatures (FIPS 186-4 section 6.4, SEC 1 section 4.1.4)
  on P-256 and P-384. The caller hashes the message and passes the
  digest, the public key as an uncompressed point (04 || x || y) and the
  signature's r and s as big endian integers (as taken out of the DER
  Ecdsa-Sig-Value). Nothing here signs.
}
unit Crypto.Ecdsa;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.EllipticCurves;

function VerifyEcdsaSignature(Curve: TCurveName; PublicKey: PByte; PublicKeyLength: PtrUInt; Digest: PByte;
  DigestLength: PtrUInt; SignatureR: PByte; SignatureRLength: PtrUInt; SignatureS: PByte;
  SignatureSLength: PtrUInt): Boolean;

implementation

uses
  Crypto.BigNumbers;

{ The digest as an integer, cut to the leftmost bits of n's length, and
  reduced mod n (it is below 2n, so once is enough). }
procedure DigestToInteger(constref Curve: TEllipticCurve; Digest: PByte; DigestLength: PtrUInt;
  out Value: TBigNumber);
var
  UsedBytes: PtrUInt;
  ExcessBits: Integer;
  Bit: Integer;
  Shifted: TBigNumber;
begin
  UsedBytes := DigestLength;
  if UsedBytes * 8 > PtrUInt(Curve.OrderBits) then
    UsedBytes := (PtrUInt(Curve.OrderBits) + 7) div 8;
  BigNumberFromBytes(Value, Digest, UsedBytes);
  ExcessBits := Integer(UsedBytes * 8) - Curve.OrderBits;
  if ExcessBits > 0 then
  begin
    { Shift right by the bits over n's length. }
    SetBigNumberZero(Shifted);
    for Bit := 0 to Curve.OrderBits - 1 do
      if BigNumberBit(Value, Bit + ExcessBits) then
      begin
        Shifted.Limbs[Bit div 32] := Shifted.Limbs[Bit div 32] or (LongWord(1) shl (Bit mod 32));
        if Bit div 32 + 1 > Shifted.LimbCount then
          Shifted.LimbCount := Bit div 32 + 1;
      end;
    Value := Shifted;
  end;
  ReduceOnce(Curve.Order, Value, Value);
end;

{ r and s must be integers in [1, n - 1]. }
function ReadScalar(constref Curve: TEllipticCurve; Bytes: PByte; Count: PtrUInt; out Value: TBigNumber): Boolean;
begin
  Result := BigNumberFromBytes(Value, Bytes, Count) and not BigNumberIsZero(Value) and
    (CompareBigNumbers(Value, Curve.Order.Modulus) < 0);
end;

function VerifyEcdsaSignature(Curve: TCurveName; PublicKey: PByte; PublicKeyLength: PtrUInt; Digest: PByte;
  DigestLength: PtrUInt; SignatureR: PByte; SignatureRLength: PtrUInt; SignatureS: PByte;
  SignatureSLength: PtrUInt): Boolean;
var
  Parameters: TEllipticCurve;
  KeyPoint, Generator: TCurvePoint;
  FirstPart, SecondPart, Combined: TCurvePoint;
  R, S, E: TBigNumber;
  MontgomeryS, MontgomeryW: TBigNumber;
  U1, U2: TBigNumber;
  X, V: TBigNumber;
begin
  Result := False;
  PrepareCurve(Curve, Parameters);
  if not DecodeCurvePoint(Parameters, PublicKey, PublicKeyLength, KeyPoint) then
    Exit;
  if not ReadScalar(Parameters, SignatureR, SignatureRLength, R) then
    Exit;
  if not ReadScalar(Parameters, SignatureS, SignatureSLength, S) then
    Exit;
  DigestToInteger(Parameters, Digest, DigestLength, E);

  { w = 1 / s mod n; multiplying an ordinary number by w in Montgomery
    form gives an ordinary product. }
  ToMontgomeryForm(Parameters.Order, S, MontgomeryS);
  MontgomeryInverseForPrime(Parameters.Order, MontgomeryS, MontgomeryW);
  MontgomeryMultiply(Parameters.Order, E, MontgomeryW, U1);
  MontgomeryMultiply(Parameters.Order, R, MontgomeryW, U2);

  { (x, y) = u1 G + u2 Q }
  GeneratorPoint(Parameters, Generator);
  MultiplyPoint(Parameters, U1, Generator, FirstPart);
  MultiplyPoint(Parameters, U2, KeyPoint, SecondPart);
  AddPoints(Parameters, FirstPart, SecondPart, Combined);
  if not AffineX(Parameters, Combined, X) then
    Exit;
  { x is below p, which is below 2n. }
  if not ReduceOnce(Parameters.Order, X, V) then
    Exit;
  Result := BigNumbersEqual(V, R);
end;

end.
