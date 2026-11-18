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
  ECDSA signatures (FIPS 186-4 section 6.4, SEC 1 section 4.1.4) on
  P-256 and P-384. The caller hashes the message and passes the digest,
  the public key as an uncompressed point (04 || x || y) and the
  signature's r and s as big endian integers (as taken out of the DER
  Ecdsa-Sig-Value, or an SSH signature blob).

  Signing takes the private key d as a big endian integer and makes the
  per signature secret k deterministically from d and the digest (RFC
  6979, HMAC with the digest's own algorithm), so no random numbers are
  needed and a weak generator cannot leak the key. The point arithmetic
  takes time that depends on k (Crypto.EllipticCurves multiplies by
  doubling and adding).
}
unit Crypto.Ecdsa;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.EllipticCurves,
  Crypto.Digests;

function VerifyEcdsaSignature(Curve: TCurveName; PublicKey: PByte; PublicKeyLength: PtrUInt; Digest: PByte;
  DigestLength: PtrUInt; SignatureR: PByte; SignatureRLength: PtrUInt; SignatureS: PByte;
  SignatureSLength: PtrUInt): Boolean;

{ d G as an uncompressed point (1 + 2 coordinate bytes: 65 for P-256)
  into PublicKey. False when d is not in [1, n - 1]. }
function EcdsaPublicKey(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PublicKey: PByte): Boolean;
{ Signs Digest (made with Algorithm, which RFC 6979 also uses) with the
  private key d; r and s go to SignatureR and SignatureS as big endian
  integers of the curve's coordinate size each (32 bytes for P-256).
  False when d is not in [1, n - 1]. }
function SignEcdsa(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; Algorithm: TDigestAlgorithm;
  Digest: PByte; DigestLength: PtrUInt; SignatureR: PByte; SignatureS: PByte): Boolean;

implementation

uses
  Crypto.BigNumbers,
  Crypto.Bits,
  Crypto.Hmac;

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

{ d from big endian bytes, in [1, n - 1]. }
function ReadPrivateKey(constref Curve: TEllipticCurve; PrivateKey: PByte; PrivateKeyLength: PtrUInt;
  out Value: TBigNumber): Boolean;
begin
  Result := ReadScalar(Curve, PrivateKey, PrivateKeyLength, Value);
end;

function EcdsaPublicKey(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; PublicKey: PByte): Boolean;
var
  Parameters: TEllipticCurve;
  D: TBigNumber;
  Generator, KeyPoint: TCurvePoint;
begin
  Result := False;
  PrepareCurve(Curve, Parameters);
  if not ReadPrivateKey(Parameters, PrivateKey, PrivateKeyLength, D) then
    Exit;
  GeneratorPoint(Parameters, Generator);
  MultiplyPoint(Parameters, D, Generator, KeyPoint);
  Result := EncodeCurvePoint(Parameters, KeyPoint, PublicKey);
  WipeMemory(@D, SizeOf(D));
end;

type
  { The HMAC_DRBG state of RFC 6979 section 3.2. }
  TNonceGenerator = record
    Algorithm: TDigestAlgorithm;
    HashSize: Integer;
    Key: TDigestOutput;
    Value: TDigestOutput;
  end;

{ HMAC_K(V || Separator || Extra) when Separator >= 0, else HMAC_K(V). }
procedure NonceHmac(var Generator: TNonceGenerator; Separator: Integer; Extra: PByte; ExtraLength: PtrUInt;
  out Output: TDigestOutput);
var
  Context: THmacContext;
  SeparatorByte: Byte;
begin
  BeginHmac(Context, Generator.Algorithm, @Generator.Key[0], Generator.HashSize);
  UpdateHmac(Context, @Generator.Value[0], Generator.HashSize);
  if Separator >= 0 then
  begin
    SeparatorByte := Byte(Separator);
    UpdateHmac(Context, @SeparatorByte, 1);
    if ExtraLength > 0 then
      UpdateHmac(Context, Extra, ExtraLength);
  end;
  FinishHmac(Context, Output);
end;

{ K = HMAC_K(V || Separator || Extra); V = HMAC_K(V) }
procedure ReseedNonceGenerator(var Generator: TNonceGenerator; Separator: Integer; Extra: PByte;
  ExtraLength: PtrUInt);
var
  Output: TDigestOutput;
begin
  NonceHmac(Generator, Separator, Extra, ExtraLength, Output);
  Generator.Key := Output;
  NonceHmac(Generator, -1, nil, 0, Output);
  Generator.Value := Output;
  WipeMemory(@Output[0], SizeOf(Output));
end;

{ Starts the generator from int2octets(d) || bits2octets(h1). }
procedure BeginNonceGenerator(out Generator: TNonceGenerator; constref Curve: TEllipticCurve;
  Algorithm: TDigestAlgorithm; constref D: TBigNumber; Digest: PByte; DigestLength: PtrUInt);
var
  Seed: array[0..2 * BigNumberMaximumBytes - 1] of Byte;
  Reduced: TBigNumber;
  Size: Integer;
begin
  Generator.Algorithm := Algorithm;
  Generator.HashSize := DigestSize(Algorithm);
  FillChar(Generator.Key, SizeOf(Generator.Key), 0);
  FillChar(Generator.Value, SizeOf(Generator.Value), 1);
  Size := Curve.CoordinateBytes;
  BigNumberToBytes(D, @Seed[0], Size);
  { bits2octets: the digest as an integer mod n. }
  DigestToInteger(Curve, Digest, DigestLength, Reduced);
  BigNumberToBytes(Reduced, @Seed[Size], Size);
  ReseedNonceGenerator(Generator, 0, @Seed[0], 2 * Size);
  ReseedNonceGenerator(Generator, 1, @Seed[0], 2 * Size);
  WipeMemory(@Seed[0], SizeOf(Seed));
end;

{ The next candidate k in [1, n - 1]. The curves here have orders of a
  whole number of bytes, so bits2int needs no shift. }
procedure NextNonce(var Generator: TNonceGenerator; constref Curve: TEllipticCurve; out K: TBigNumber);
var
  Candidate: array[0..BigNumberMaximumBytes - 1] of Byte;
  Filled, Part: Integer;
  Output: TDigestOutput;
begin
  repeat
    Filled := 0;
    while Filled < Curve.CoordinateBytes do
    begin
      NonceHmac(Generator, -1, nil, 0, Output);
      Generator.Value := Output;
      Part := Generator.HashSize;
      if Part > Curve.CoordinateBytes - Filled then
        Part := Curve.CoordinateBytes - Filled;
      Move(Output[0], Candidate[Filled], Part);
      Filled := Filled + Part;
    end;
    BigNumberFromBytes(K, @Candidate[0], Curve.CoordinateBytes);
    if (not BigNumberIsZero(K)) and (CompareBigNumbers(K, Curve.Order.Modulus) < 0) then
      Break;
    ReseedNonceGenerator(Generator, 0, nil, 0);
  until False;
  WipeMemory(@Candidate[0], SizeOf(Candidate));
  WipeMemory(@Output[0], SizeOf(Output));
end;

function SignEcdsa(Curve: TCurveName; PrivateKey: PByte; PrivateKeyLength: PtrUInt; Algorithm: TDigestAlgorithm;
  Digest: PByte; DigestLength: PtrUInt; SignatureR: PByte; SignatureS: PByte): Boolean;
var
  Parameters: TEllipticCurve;
  Generator: TNonceGenerator;
  D, E, K, X, R, S: TBigNumber;
  MontgomeryK, MontgomeryKInverse, MontgomeryR, RD, Sum: TBigNumber;
  BasePoint, Commitment: TCurvePoint;
begin
  Result := False;
  PrepareCurve(Curve, Parameters);
  if not ReadPrivateKey(Parameters, PrivateKey, PrivateKeyLength, D) then
    Exit;
  DigestToInteger(Parameters, Digest, DigestLength, E);
  BeginNonceGenerator(Generator, Parameters, Algorithm, D, Digest, DigestLength);
  GeneratorPoint(Parameters, BasePoint);
  repeat
    NextNonce(Generator, Parameters, K);
    { r = x(k G) mod n }
    MultiplyPoint(Parameters, K, BasePoint, Commitment);
    if not AffineX(Parameters, Commitment, X) then
      Continue;
    if not ReduceOnce(Parameters.Order, X, R) or BigNumberIsZero(R) then
      Continue;
    { s = (e + r d) / k mod n. A number in Montgomery form multiplied
      by an ordinary one gives an ordinary product. }
    ToMontgomeryForm(Parameters.Order, R, MontgomeryR);
    MontgomeryMultiply(Parameters.Order, MontgomeryR, D, RD);
    ModularAdd(Parameters.Order, E, RD, Sum);
    ToMontgomeryForm(Parameters.Order, K, MontgomeryK);
    MontgomeryInverseForPrime(Parameters.Order, MontgomeryK, MontgomeryKInverse);
    MontgomeryMultiply(Parameters.Order, MontgomeryKInverse, Sum, S);
    if not BigNumberIsZero(S) then
      Break;
  until False;
  Result := BigNumberToBytes(R, SignatureR, Parameters.CoordinateBytes) and
    BigNumberToBytes(S, SignatureS, Parameters.CoordinateBytes);
  WipeMemory(@D, SizeOf(D));
  WipeMemory(@K, SizeOf(K));
  WipeMemory(@MontgomeryK, SizeOf(MontgomeryK));
  WipeMemory(@MontgomeryKInverse, SizeOf(MontgomeryKInverse));
  WipeMemory(@Generator, SizeOf(Generator));
end;

end.
