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
  ECDH on P-256, P-384 and P-521 (Crypto.Ecdh) and ECDSA on P-521, against
  what Python's cryptography package (OpenSSL) computes from the same
  private keys (CryptoTest.CurveVectors.inc, made at build time): public
  keys and shared secrets, deterministic (RFC 6979) signatures made the
  same, and random ones checked.
}
unit CryptoTest.Curves;

{$mode objfpc}
{$H+}

interface

procedure TestEcdh;
procedure TestP521Ecdsa;

implementation

uses
  SysUtils,
  TestChecks,
  Crypto.Digests,
  Crypto.Ecdh,
  Crypto.Ecdsa,
  Crypto.EllipticCurves;

{$i CryptoTest.CurveVectors.inc}

const
  CurveNames: array[TCurveName] of string = ('P-256', 'P-384', 'P-521');

procedure TestEcdh;
var
  Index: Integer;
  Vector: TEcdhVector;
  PrivateKey, PeerKey: TByteArray;
  PublicKey: array[0..132] of Byte;
  Secret: array[0..65] of Byte;
  Name: string;
begin
  for Index := 0 to High(EcdhVectors) do
  begin
    Vector := EcdhVectors[Index];
    Name := 'ECDH ' + CurveNames[Vector.Curve] + ' #' + IntToStr(Index);
    PrivateKey := HexToBytes(Vector.PrivateKey);
    PeerKey := HexToBytes(Vector.PeerPublicKey);
    Check(EcdhPublicKey(Vector.Curve, @PrivateKey[0], Length(PrivateKey), @PublicKey[0]), Name + ': public key made');
    CheckBytes(@PublicKey[0], EcdhPublicKeyLength(Vector.Curve), Vector.PublicKey, Name + ': public key');
    Check(EcdhSharedSecret(Vector.Curve, @PrivateKey[0], Length(PrivateKey), @PeerKey[0], Length(PeerKey),
      @Secret[0]), Name + ': shared secret made');
    CheckBytes(@Secret[0], EcdhSharedSecretLength(Vector.Curve), Vector.SharedSecret, Name + ': shared secret');
    PeerKey[Length(PeerKey) - 1] := PeerKey[Length(PeerKey) - 1] xor 1;
    Check(not EcdhSharedSecret(Vector.Curve, @PrivateKey[0], Length(PrivateKey), @PeerKey[0], Length(PeerKey),
      @Secret[0]), Name + ': peer point off the curve refused');
  end;
  PrivateKey := HexToBytes('00');
  Check(not EcdhPublicKey(CurveP256, @PrivateKey[0], 1, @PublicKey[0]), 'ECDH: zero private key refused');
end;

procedure TestP521Ecdsa;
var
  Index: Integer;
  Vector: TEcdsaVector;
  PrivateKey, PublicKey, Message, R, S: TByteArray;
  Digest: TDigestOutput;
  MadeR, MadeS: array[0..65] of Byte;
  HashLength: Integer;
  Name: string;
begin
  for Index := 0 to High(EcdsaVectors) do
  begin
    Vector := EcdsaVectors[Index];
    Name := 'ECDSA ' + CurveNames[Vector.Curve] + ' #' + IntToStr(Index);
    PrivateKey := HexToBytes(Vector.PrivateKey);
    PublicKey := HexToBytes(Vector.PublicKey);
    Message := TextBytes(Vector.Message);
    R := HexToBytes(Vector.R);
    S := HexToBytes(Vector.S);
    ComputeDigest(Vector.Algorithm, @Message[0], Length(Message), Digest);
    HashLength := DigestSize(Vector.Algorithm);
    Check(VerifyEcdsaSignature(Vector.Curve, @PublicKey[0], Length(PublicKey), @Digest[0], HashLength, @R[0],
      Length(R), @S[0], Length(S)), Name + ': OpenSSL''s signature verifies');
    S[5] := S[5] xor $10;
    Check(not VerifyEcdsaSignature(Vector.Curve, @PublicKey[0], Length(PublicKey), @Digest[0], HashLength, @R[0],
      Length(R), @S[0], Length(S)), Name + ': changed signature refused');
    if Vector.Deterministic then
    begin
      Check(SignEcdsa(Vector.Curve, @PrivateKey[0], Length(PrivateKey), Vector.Algorithm, @Digest[0], HashLength,
        @MadeR[0], @MadeS[0]), Name + ': signed');
      CheckBytes(@MadeR[0], 66, Vector.R, Name + ': RFC 6979 r as OpenSSL makes it');
      CheckBytes(@MadeS[0], 66, Vector.S, Name + ': RFC 6979 s as OpenSSL makes it');
    end;
  end;
end;

end.
