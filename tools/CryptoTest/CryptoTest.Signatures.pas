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
  Signature checks: big number arithmetic against values worked out by
  hand, RSA PKCS #1 v1.5 and PSS signatures of 2048, 3072 and 4096 bit
  keys made by OpenSSL (CryptoTest.RsaVectors.inc), and the ECDSA P-256
  and P-384 signatures of RFC 6979 appendix A.2.5 and A.2.6; each also
  with the message, the signature or the key changed.
}
unit CryptoTest.Signatures;

{$mode objfpc}
{$H+}

interface

procedure TestBigNumbers;
procedure TestRsa;
procedure TestEcdsa;

implementation

uses
  TestChecks,
  Crypto.BigNumbers,
  Crypto.Digests,
  Crypto.Rsa,
  Crypto.EllipticCurves,
  Crypto.Ecdsa;

{$i CryptoTest.RsaVectors.inc}

function NumberToHex(constref Number: TBigNumber): string;
var
  Bytes: array[0..BigNumberMaximumBytes - 1] of Byte;
  Count: Integer;
begin
  Count := (BigNumberBitLength(Number) + 7) div 8;
  if Count = 0 then
    Exit('00');
  BigNumberToBytes(Number, @Bytes[0], Count);
  Result := BytesToHex(@Bytes[0], Count);
end;

procedure TestBigNumbers;
var
  First, Second, Sum, Difference, Power, Exponent: TBigNumber;
  Modulus: TMontgomeryModulus;
  Value, Montgomery, Inverse, Product, Back: TBigNumber;
begin
  BigNumberFromHex(First, 'ffffffffffffffffffffffff');
  SetBigNumberSmall(Second, 1);
  AddBigNumbers(Sum, First, Second);
  Check(NumberToHex(Sum) = '01000000000000000000000000', 'big numbers: carry through limbs');
  SubtractBigNumbers(Difference, Sum, Second);
  Check(NumberToHex(Difference) = 'ffffffffffffffffffffffff', 'big numbers: borrow through limbs');
  Check(CompareBigNumbers(Sum, First) > 0, 'big numbers: compare');

  { 4^13 mod 497 = 445 }
  SetBigNumberSmall(Value, 497);
  Check(PrepareMontgomeryModulus(Modulus, Value), 'big numbers: odd modulus');
  SetBigNumberSmall(Value, 4);
  SetBigNumberSmall(Exponent, 13);
  ModularPower(Modulus, Value, Exponent, Power);
  Check(NumberToHex(Power) = '01bd', 'big numbers: 4^13 mod 497');

  { 2^127 - 1 is prime: 3 * (1 / 3) = 1 and Fermat's little theorem. }
  BigNumberFromHex(Value, '7fffffffffffffffffffffffffffffff');
  PrepareMontgomeryModulus(Modulus, Value);
  SetBigNumberSmall(Value, 3);
  ToMontgomeryForm(Modulus, Value, Montgomery);
  MontgomeryInverseForPrime(Modulus, Montgomery, Inverse);
  MontgomeryMultiply(Modulus, Montgomery, Inverse, Product);
  FromMontgomeryForm(Modulus, Product, Back);
  Check(NumberToHex(Back) = '01', 'big numbers: inverse mod 2^127 - 1');
  BigNumberFromHex(Exponent, '7ffffffffffffffffffffffffffffffe');
  BigNumberFromHex(Value, '123456789abcdef0123456789abcdef');
  ModularPower(Modulus, Value, Exponent, Power);
  Check(NumberToHex(Power) = '01', 'big numbers: a^(p-1) = 1 mod 2^127 - 1');

  SetBigNumberSmall(Value, 10);
  Check(not PrepareMontgomeryModulus(Modulus, Value), 'big numbers: even modulus refused');
  Check(not BigNumberFromHex(Value, '12g4'), 'big numbers: bad hexadecimal refused');
end;

procedure TestRsa;
var
  Index: Integer;
  Vector: TRsaVector;
  ModulusBytes, Signature, Exponent: TByteArray;
  Key: TRsaPublicKey;
  Message: TByteArray;
  Digest, OtherDigest: TDigestOutput;
  HashLength: Integer;
  Verified: Boolean;
  Name: string;
begin
  Exponent := HexToBytes('010001');
  Message := TextBytes(RsaTestMessage);
  for Index := 0 to High(RsaVectors) do
  begin
    Vector := RsaVectors[Index];
    ModulusBytes := HexToBytes(Vector.Modulus);
    Signature := HexToBytes(Vector.Signature);
    Str(Length(ModulusBytes) * 8, Name);
    if Vector.UsesPss then
      Name := 'RSA-' + Name + ' PSS ' + DigestTagName(Vector.Algorithm)
    else
      Name := 'RSA-' + Name + ' PKCS#1 v1.5 ' + DigestTagName(Vector.Algorithm);
    Check(PrepareRsaPublicKey(Key, @ModulusBytes[0], Length(ModulusBytes), @Exponent[0], Length(Exponent)),
      Name + ': key');
    ComputeDigest(Vector.Algorithm, @Message[0], Length(Message), Digest);
    HashLength := DigestSize(Vector.Algorithm);
    if Vector.UsesPss then
      Verified := VerifyRsaPssSignature(Key, Vector.Algorithm, @Digest[0], HashLength, @Signature[0],
        Length(Signature))
    else
      Verified := VerifyRsaPkcs1Signature(Key, Vector.Algorithm, @Digest[0], @Signature[0], Length(Signature));
    Check(Verified, Name + ': good signature');

    { Another message. }
    OtherDigest := Digest;
    OtherDigest[0] := OtherDigest[0] xor 1;
    if Vector.UsesPss then
      Verified := VerifyRsaPssSignature(Key, Vector.Algorithm, @OtherDigest[0], HashLength, @Signature[0],
        Length(Signature))
    else
      Verified := VerifyRsaPkcs1Signature(Key, Vector.Algorithm, @OtherDigest[0], @Signature[0],
        Length(Signature));
    Check(not Verified, Name + ': other message refused');

    { A changed signature. }
    Signature[Length(Signature) div 2] := Signature[Length(Signature) div 2] xor $40;
    if Vector.UsesPss then
      Verified := VerifyRsaPssSignature(Key, Vector.Algorithm, @Digest[0], HashLength, @Signature[0],
        Length(Signature))
    else
      Verified := VerifyRsaPkcs1Signature(Key, Vector.Algorithm, @Digest[0], @Signature[0], Length(Signature));
    Check(not Verified, Name + ': changed signature refused');
    Signature[Length(Signature) div 2] := Signature[Length(Signature) div 2] xor $40;

    { The wrong scheme, and a signature one byte short. }
    if Vector.UsesPss then
      Verified := VerifyRsaPkcs1Signature(Key, Vector.Algorithm, @Digest[0], @Signature[0], Length(Signature))
    else
      Verified := VerifyRsaPssSignature(Key, Vector.Algorithm, @Digest[0], HashLength, @Signature[0],
        Length(Signature));
    Check(not Verified, Name + ': the other padding refused');
    Check(not VerifyRsaPkcs1Signature(Key, Vector.Algorithm, @Digest[0], @Signature[1], Length(Signature) - 1),
      Name + ': short signature refused');
  end;
  ModulusBytes := HexToBytes(RsaVectors[0].Modulus);
  ModulusBytes[Length(ModulusBytes) - 1] := ModulusBytes[Length(ModulusBytes) - 1] and $FE;
  Check(not PrepareRsaPublicKey(Key, @ModulusBytes[0], Length(ModulusBytes), @Exponent[0], Length(Exponent)),
    'RSA: even modulus refused');
  Check(not PrepareRsaPublicKey(Key, @ModulusBytes[0], 100, @Exponent[0], Length(Exponent)),
    'RSA: 800-bit modulus refused');
end;

procedure CheckEcdsa(Curve: TCurveName; const KeyHex, MessageText: string; Algorithm: TDigestAlgorithm;
  const RHex, SHex, Name: string);
var
  Key, R, S, Message: TByteArray;
  Digest: TDigestOutput;
  HashLength: Integer;
begin
  Key := HexToBytes(KeyHex);
  R := HexToBytes(RHex);
  S := HexToBytes(SHex);
  Message := TextBytes(MessageText);
  ComputeDigest(Algorithm, @Message[0], Length(Message), Digest);
  HashLength := DigestSize(Algorithm);
  Check(VerifyEcdsaSignature(Curve, @Key[0], Length(Key), @Digest[0], HashLength, @R[0], Length(R), @S[0],
    Length(S)), Name + ': good signature');
  Digest[0] := Digest[0] xor 1;
  Check(not VerifyEcdsaSignature(Curve, @Key[0], Length(Key), @Digest[0], HashLength, @R[0], Length(R), @S[0],
    Length(S)), Name + ': other message refused');
  Digest[0] := Digest[0] xor 1;
  S[3] := S[3] xor 2;
  Check(not VerifyEcdsaSignature(Curve, @Key[0], Length(Key), @Digest[0], HashLength, @R[0], Length(R), @S[0],
    Length(S)), Name + ': changed signature refused');
  S[3] := S[3] xor 2;
  Key[Length(Key) - 1] := Key[Length(Key) - 1] xor 1;
  Check(not VerifyEcdsaSignature(Curve, @Key[0], Length(Key), @Digest[0], HashLength, @R[0], Length(R), @S[0],
    Length(S)), Name + ': point off the curve refused');
end;

procedure TestEcdsa;
const
  P256Key = '04' + '60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6' +
    '7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299';
  P384Key = '04' + 'EC3A4E415B4E19A4568618029F427FA5DA9A8BC4AE92E02E06AAE5286B300C64DEF8F0EA9055866064A254515480BC13' +
    '8015D9B72D7D57244EA8EF9AC0C621896708A59367F9DFB9F54CA84B3F1C9DB1288B231C3AE0D4FE7344FD2533264720';
var
  Key, R, S: TByteArray;
  Digest: TDigestOutput;
begin
  CheckEcdsa(CurveP256, P256Key, 'sample', DigestSha256,
    'EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716',
    'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8', 'ECDSA P-256 SHA-256 "sample"');
  CheckEcdsa(CurveP256, P256Key, 'test', DigestSha256,
    'F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367',
    '019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083', 'ECDSA P-256 SHA-256 "test"');
  { A digest longer than the order: only its leftmost 256 bits count. }
  CheckEcdsa(CurveP256, P256Key, 'sample', DigestSha384,
    '0EAFEA039B20E9B42309FB1D89E213057CBF973DC0CFC8F129EDDDC800EF7719',
    '4861F0491E6998B9455193E34E7B0D284DDD7149A74B95B9261F13ABDE940954', 'ECDSA P-256 SHA-384 "sample"');
  CheckEcdsa(CurveP384, P384Key, 'sample', DigestSha384,
    '94EDBB92A5ECB8AAD4736E56C691916B3F88140666CE9FA73D64C4EA95AD133C81A648152E44ACF96E36DD1E80FABE46',
    '99EF4AEB15F178CEA1FE40DB2603138F130E740A19624526203B6351D0A3A94FA329C145786E679E7B82C71A38628AC8',
    'ECDSA P-384 SHA-384 "sample"');
  CheckEcdsa(CurveP384, P384Key, 'sample', DigestSha256,
    '21B13D1E013C7FA1392D03C5F99AF8B30C570C6F98D4EA8E354B63A21D3DAA33BDE1E888E63355D92FA2B3C36D8FB2CD',
    'F3AA443FB107745BF4BD77CB3891674632068A10CA67E3D45DB2266FA7D1FEEBEFDC63ECCD1AC42EC0CB8668A4FA0AB0',
    'ECDSA P-384 SHA-256 "sample"');
  CheckEcdsa(CurveP384, P384Key, 'test', DigestSha256,
    '6D6DEFAC9AB64DABAFE36C6BF510352A4CC27001263638E5B16D9BB51D451559F918EEDAF2293BE5B475CC8F0188636B',
    '2D46F3BECBCC523D5F1A1256BF0C9B024D879BA9E838144C8BA6BAEB4B53B47D51AB373F9845C0514EEFB14024787265',
    'ECDSA P-384 SHA-256 "test"');

  { r = 0 and s = n are outside [1, n - 1]. }
  Key := HexToBytes(P256Key);
  R := HexToBytes('00');
  S := HexToBytes('F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8');
  FillChar(Digest, SizeOf(Digest), 0);
  Check(not VerifyEcdsaSignature(CurveP256, @Key[0], Length(Key), @Digest[0], 32, @R[0], 1, @S[0], Length(S)),
    'ECDSA: r = 0 refused');
  R := HexToBytes('ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551');
  Check(not VerifyEcdsaSignature(CurveP256, @Key[0], Length(Key), @Digest[0], 32, @R[0], Length(R), @S[0],
    Length(S)), 'ECDSA: r = n refused');
  Key[0] := 2;
  Check(not VerifyEcdsaSignature(CurveP256, @Key[0], 33, @Digest[0], 32, @S[0], Length(S), @S[0], Length(S)),
    'ECDSA: compressed point refused');
end;

end.
