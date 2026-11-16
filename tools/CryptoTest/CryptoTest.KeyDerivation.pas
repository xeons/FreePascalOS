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
  Known answers for SHA-256 and SHA-384 (FIPS 180-4 examples), HKDF
  (RFC 5869 appendix A, and HKDF-SHA384 checked against OpenSSL) and
  X25519 (RFC 7748 sections 5.2 and 6.1).
}
unit CryptoTest.KeyDerivation;

{$mode objfpc}
{$H+}

interface

procedure TestDigests;
procedure TestHkdf;
procedure TestX25519;

implementation

uses
  TestChecks,
  Crypto.Digests,
  Crypto.Hkdf,
  Crypto.X25519;

procedure TestDigests;
var
  Data: TByteArray;
  Output: TDigestOutput;
begin
  Data := TextBytes('abc');
  ComputeDigest(DigestSha256, @Data[0], 3, Output);
  CheckBytes(@Output[0], 32, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA-256 "abc"');
  ComputeDigest(DigestSha384, @Data[0], 3, Output);
  CheckBytes(@Output[0], 48, 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed' +
    '8086072ba1e7cc2358baeca134c825a7', 'SHA-384 "abc"');
  Data := TextBytes('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrs' +
    'mnopqrstnopqrstu');
  ComputeDigest(DigestSha384, @Data[0], Length(Data), Output);
  CheckBytes(@Output[0], 48, '09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712' +
    'fcc7c71a557e2db966c3e9fa91746039', 'SHA-384 two blocks');
end;

procedure TestHkdf;
var
  InputKey, Salt, Info: TByteArray;
  PseudoRandomKey: TDigestOutput;
  Output: array[0..63] of Byte;
  Large: array[0..255 * 32] of Byte;
begin
  { RFC 5869 A.1 }
  InputKey := HexToBytes('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b');
  Salt := HexToBytes('000102030405060708090a0b0c');
  Info := HexToBytes('f0f1f2f3f4f5f6f7f8f9');
  HkdfExtract(DigestSha256, @Salt[0], Length(Salt), @InputKey[0], Length(InputKey), PseudoRandomKey);
  CheckBytes(@PseudoRandomKey[0], 32, '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5',
    'HKDF-SHA256 A.1 PRK');
  Check(HkdfExpand(DigestSha256, @PseudoRandomKey[0], 32, @Info[0], Length(Info), @Output[0], 42),
    'HKDF-SHA256 A.1 expands');
  CheckBytes(@Output[0], 42, '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
    'HKDF-SHA256 A.1 OKM');

  { RFC 5869 A.3: no salt, no info. }
  HkdfExtract(DigestSha256, nil, 0, @InputKey[0], Length(InputKey), PseudoRandomKey);
  CheckBytes(@PseudoRandomKey[0], 32, '19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04',
    'HKDF-SHA256 A.3 PRK');
  HkdfExpand(DigestSha256, @PseudoRandomKey[0], 32, nil, 0, @Output[0], 42);
  CheckBytes(@Output[0], 42, '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8',
    'HKDF-SHA256 A.3 OKM');

  { HKDF-SHA384 with A.1's inputs, as OpenSSL computes it. }
  HkdfExtract(DigestSha384, @Salt[0], Length(Salt), @InputKey[0], Length(InputKey), PseudoRandomKey);
  CheckBytes(@PseudoRandomKey[0], 48, '704b39990779ce1dc548052c7dc39f303570dd13fb39f7acc564680bef80e8de' +
    'c70ee9a7e1f3e293ef68eceb072a5ade', 'HKDF-SHA384 PRK');
  HkdfExpand(DigestSha384, @PseudoRandomKey[0], 48, @Info[0], Length(Info), @Output[0], 42);
  CheckBytes(@Output[0], 42, '9b5097a86038b805309076a44b3a9f38063e25b516dcbf369f394cfab43685f748b6457763e4f0204fc5',
    'HKDF-SHA384 OKM');

  Check(HkdfExpand(DigestSha256, @PseudoRandomKey[0], 32, nil, 0, @Large[0], 255 * 32),
    'HKDF: 255 blocks allowed');
  Check(not HkdfExpand(DigestSha256, @PseudoRandomKey[0], 32, nil, 0, @Large[0], 255 * 32 + 1),
    'HKDF: more than 255 blocks refused');
end;

procedure CheckScalarMultiplication(const ScalarHex, PointHex, ExpectedHex, Name: string);
var
  Scalar, Point: TByteArray;
  Output: array[0..31] of Byte;
begin
  Scalar := HexToBytes(ScalarHex);
  Point := HexToBytes(PointHex);
  Check(X25519SharedSecret(@Scalar[0], @Point[0], @Output[0]), Name + ' (not zero)');
  CheckBytes(@Output[0], 32, ExpectedHex, Name);
end;

procedure TestX25519;
var
  AlicePrivate, BobPrivate: TByteArray;
  AlicePublic, BobPublic, Shared: array[0..31] of Byte;
  Scalar, Point, Next: array[0..31] of Byte;
  Iteration: Integer;
  SmallOrderPoint: TByteArray;
begin
  CheckScalarMultiplication('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4',
    'e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c',
    'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552', 'X25519: RFC 7748 5.2 first');
  CheckScalarMultiplication('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d',
    'e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493',
    '95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957', 'X25519: RFC 7748 5.2 second');

  { Iterated: k, u start as 9; then u := old k, k := X25519(k, u). }
  FillChar(Scalar, SizeOf(Scalar), 0);
  FillChar(Point, SizeOf(Point), 0);
  Scalar[0] := 9;
  Point[0] := 9;
  for Iteration := 1 to 1000 do
  begin
    X25519SharedSecret(@Scalar[0], @Point[0], @Next[0]);
    Point := Scalar;
    Scalar := Next;
    if Iteration = 1 then
      CheckBytes(@Scalar[0], 32, '422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079',
        'X25519: one iteration');
  end;
  CheckBytes(@Scalar[0], 32, '684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51',
    'X25519: 1000 iterations');

  { RFC 7748 6.1 }
  AlicePrivate := HexToBytes('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
  BobPrivate := HexToBytes('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
  X25519PublicKey(@AlicePrivate[0], @AlicePublic[0]);
  CheckBytes(@AlicePublic[0], 32, '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
    'X25519: Alice''s public key');
  X25519PublicKey(@BobPrivate[0], @BobPublic[0]);
  CheckBytes(@BobPublic[0], 32, 'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
    'X25519: Bob''s public key');
  X25519SharedSecret(@AlicePrivate[0], @BobPublic[0], @Shared[0]);
  CheckBytes(@Shared[0], 32, '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
    'X25519: shared secret (Alice)');
  X25519SharedSecret(@BobPrivate[0], @AlicePublic[0], @Shared[0]);
  CheckBytes(@Shared[0], 32, '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
    'X25519: shared secret (Bob)');

  { A point of small order (zero) gives the all-zero secret, refused. }
  SmallOrderPoint := HexToBytes('0000000000000000000000000000000000000000000000000000000000000000');
  Check(not X25519SharedSecret(@AlicePrivate[0], @SmallOrderPoint[0], @Shared[0]),
    'X25519: a point of small order is refused');
  SmallOrderPoint := HexToBytes('0100000000000000000000000000000000000000000000000000000000000000');
  Check(not X25519SharedSecret(@AlicePrivate[0], @SmallOrderPoint[0], @Shared[0]),
    'X25519: the point 1 is refused');
end;

end.
