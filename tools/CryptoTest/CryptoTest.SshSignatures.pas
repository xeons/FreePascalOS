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
  The signatures the SSH server makes with its host keys: Ed25519
  against the test vectors of RFC 8032 section 7.1 (the public key from
  the seed, the signature, verification, and refusals of a changed
  message, signature, key and an S not below L), and deterministic
  ECDSA signing against RFC 6979 appendix A.2.5 and A.2.6 (the public
  key from d, r and s for "sample" and "test", a digest longer than the
  order), each signature also checked with the verifier.
}
unit CryptoTest.SshSignatures;

{$mode objfpc}
{$H+}

interface

procedure TestEd25519;
procedure TestEcdsaSigning;

implementation

uses
  TestChecks,
  Crypto.Digests,
  Crypto.EllipticCurves,
  Crypto.Ecdsa,
  Crypto.Ed25519;

procedure CheckEd25519(const SeedHex, PublicKeyHex, MessageHex, SignatureHex, Name: string);
var
  Seed, Message, ExpectedKey, ExpectedSignature: TByteArray;
  PublicKey: array[0..Ed25519PublicKeySize - 1] of Byte;
  Signature: array[0..Ed25519SignatureSize - 1] of Byte;
  MessagePointer: PByte;
begin
  Seed := HexToBytes(SeedHex);
  Message := HexToBytes(MessageHex);
  ExpectedKey := HexToBytes(PublicKeyHex);
  ExpectedSignature := HexToBytes(SignatureHex);
  MessagePointer := nil;
  if Length(Message) > 0 then
    MessagePointer := @Message[0];

  Ed25519PublicKey(@Seed[0], @PublicKey[0]);
  CheckBytes(@PublicKey[0], Ed25519PublicKeySize, PublicKeyHex, Name + ': public key');
  Ed25519Sign(@Seed[0], MessagePointer, Length(Message), @Signature[0]);
  CheckBytes(@Signature[0], Ed25519SignatureSize, SignatureHex, Name + ': signature');
  Check(Ed25519Verify(@ExpectedKey[0], MessagePointer, Length(Message), @ExpectedSignature[0]),
    Name + ': verified');

  ExpectedSignature[5] := ExpectedSignature[5] xor $01;
  Check(not Ed25519Verify(@ExpectedKey[0], MessagePointer, Length(Message), @ExpectedSignature[0]),
    Name + ': changed R refused');
  ExpectedSignature[5] := ExpectedSignature[5] xor $01;
  ExpectedSignature[40] := ExpectedSignature[40] xor $10;
  Check(not Ed25519Verify(@ExpectedKey[0], MessagePointer, Length(Message), @ExpectedSignature[0]),
    Name + ': changed S refused');
  ExpectedSignature[40] := ExpectedSignature[40] xor $10;
  ExpectedKey[3] := ExpectedKey[3] xor $04;
  Check(not Ed25519Verify(@ExpectedKey[0], MessagePointer, Length(Message), @ExpectedSignature[0]),
    Name + ': changed key refused');
  ExpectedKey[3] := ExpectedKey[3] xor $04;
  if Length(Message) > 0 then
  begin
    Message[0] := Message[0] xor $80;
    Check(not Ed25519Verify(@ExpectedKey[0], @Message[0], Length(Message), @ExpectedSignature[0]),
      Name + ': changed message refused');
  end;
end;

procedure TestEd25519;
const
  { SHA-512("abc"), the message of the RFC's last short test. }
  AbcDigest = 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a' +
    '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f';
  FirstKey = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
  FirstSignature = 'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';
var
  Key, Signature: TByteArray;
  Index: Integer;
  Carry: Integer;
  Order: TByteArray;
begin
  CheckEd25519('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    FirstKey, '', FirstSignature, 'Ed25519 RFC 8032 test 1 (empty message)');
  CheckEd25519('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', '72',
    '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
    'Ed25519 RFC 8032 test 2 (one byte)');
  CheckEd25519('c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
    'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', 'af82',
    '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
    'Ed25519 RFC 8032 test 3 (two bytes)');
  CheckEd25519('833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42',
    'ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf', AbcDigest,
    'dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704',
    'Ed25519 RFC 8032 test SHA(abc)');

  { S + L is the same point equation but must be refused (RFC 8032
    section 5.1.7: S in [0, L)). }
  Key := HexToBytes(FirstKey);
  Signature := HexToBytes(FirstSignature);
  Order := HexToBytes('edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010');
  Carry := 0;
  for Index := 0 to 31 do
  begin
    Carry := Carry + Signature[32 + Index] + Order[Index];
    Signature[32 + Index] := Byte(Carry and $FF);
    Carry := Carry shr 8;
  end;
  Check(not Ed25519Verify(@Key[0], nil, 0, @Signature[0]), 'Ed25519: S + L refused');
end;

procedure CheckEcdsaSigning(Curve: TCurveName; const PrivateKeyHex, PublicKeyHex, Message: string;
  Algorithm: TDigestAlgorithm; const ExpectedR, ExpectedS, Name: string);
var
  PrivateKey, MessageBytes: TByteArray;
  PublicKey: array[0..96] of Byte;
  R, S: array[0..47] of Byte;
  Digest: TDigestOutput;
  CoordinateBytes: Integer;
begin
  PrivateKey := HexToBytes(PrivateKeyHex);
  MessageBytes := TextBytes(Message);
  CoordinateBytes := Length(PrivateKey);
  Check(EcdsaPublicKey(Curve, @PrivateKey[0], Length(PrivateKey), @PublicKey[0]), Name + ': public key made');
  CheckBytes(@PublicKey[0], 1 + 2 * CoordinateBytes, PublicKeyHex, Name + ': public key');
  ComputeDigest(Algorithm, @MessageBytes[0], Length(MessageBytes), Digest);
  Check(SignEcdsa(Curve, @PrivateKey[0], Length(PrivateKey), Algorithm, @Digest[0], DigestSize(Algorithm),
    @R[0], @S[0]), Name + ': signed');
  CheckBytes(@R[0], CoordinateBytes, ExpectedR, Name + ': r');
  CheckBytes(@S[0], CoordinateBytes, ExpectedS, Name + ': s');
  Check(VerifyEcdsaSignature(Curve, @PublicKey[0], 1 + 2 * CoordinateBytes, @Digest[0], DigestSize(Algorithm),
    @R[0], CoordinateBytes, @S[0], CoordinateBytes), Name + ': verified');
end;

procedure TestEcdsaSigning;
const
  P256PrivateKey = 'C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721';
  P256PublicKey = '04' + '60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6' +
    '7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299';
  P384PrivateKey = '6B9D3DAD2E1B8C1C05B19875B6659F4DE23C3B667BF297BA9AA47740787137D896D5724E4C70A825F872C9EA60D2EDF5';
  P384PublicKey = '04' + 'EC3A4E415B4E19A4568618029F427FA5DA9A8BC4AE92E02E06AAE5286B300C64DEF8F0EA9055866064A254515480BC13' +
    '8015D9B72D7D57244EA8EF9AC0C621896708A59367F9DFB9F54CA84B3F1C9DB1288B231C3AE0D4FE7344FD2533264720';
var
  Zero: array[0..31] of Byte;
  PublicKey: array[0..64] of Byte;
begin
  CheckEcdsaSigning(CurveP256, P256PrivateKey, P256PublicKey, 'sample', DigestSha256,
    'EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716',
    'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8', 'ECDSA signing P-256 SHA-256 "sample"');
  CheckEcdsaSigning(CurveP256, P256PrivateKey, P256PublicKey, 'test', DigestSha256,
    'F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367',
    '019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083', 'ECDSA signing P-256 SHA-256 "test"');
  CheckEcdsaSigning(CurveP256, P256PrivateKey, P256PublicKey, 'sample', DigestSha512,
    '8496A60B5E9B47C825488827E0495B0E3FA109EC4568FD3F8D1097678EB97F00',
    '2362AB1ADBE2B8ADF9CB9EDAB740EA6049C028114F2460F96554F61FAE3302FE', 'ECDSA signing P-256 SHA-512 "sample"');
  CheckEcdsaSigning(CurveP384, P384PrivateKey, P384PublicKey, 'sample', DigestSha384,
    '94EDBB92A5ECB8AAD4736E56C691916B3F88140666CE9FA73D64C4EA95AD133C81A648152E44ACF96E36DD1E80FABE46',
    '99EF4AEB15F178CEA1FE40DB2603138F130E740A19624526203B6351D0A3A94FA329C145786E679E7B82C71A38628AC8',
    'ECDSA signing P-384 SHA-384 "sample"');
  FillChar(Zero, SizeOf(Zero), 0);
  Check(not EcdsaPublicKey(CurveP256, @Zero[0], SizeOf(Zero), @PublicKey[0]), 'ECDSA: a zero private key refused');
end;

end.
