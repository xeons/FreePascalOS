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
  Checking a signature made with a certificate's key: the signature on
  another certificate (by the certificate's signature algorithm), on an
  OCSP response (by its AlgorithmIdentifier), or the server's
  handshake signature (by a SignatureScheme of RFC 8446 section 4.2.3:
  CertificateVerify in TLS 1.3, ServerKeyExchange in TLS 1.2).

  Keys: RSA (at least 2048 bits), RSA-PSS, ECDSA P-256, P-384 and
  P-521, and Ed25519. SHA-1 signatures are refused (they can be
  forged). The key kind must match the algorithm (an rsa_pss_pss scheme
  needs an RSA-PSS key, Ed25519 an Ed25519 key, and so on). TLS 1.3
  refuses PKCS #1 v1.5 in the handshake and ties each ECDSA scheme to
  its curve; TLS 1.2 allows both (an ECDSA scheme names only the
  hash there).
}
unit Tls.Signatures;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.Certificates;

const
  { SignatureScheme values (RFC 8446). }
  SchemeRsaPkcs1Sha256 = $0401;
  SchemeRsaPkcs1Sha384 = $0501;
  SchemeRsaPkcs1Sha512 = $0601;
  SchemeEcdsaP256Sha256 = $0403;
  SchemeEcdsaP384Sha384 = $0503;
  SchemeRsaPssRsaeSha256 = $0804;
  SchemeRsaPssRsaeSha384 = $0805;
  SchemeRsaPssRsaeSha512 = $0806;
  SchemeRsaPssPssSha256 = $0809;
  SchemeRsaPssPssSha384 = $080A;
  SchemeRsaPssPssSha512 = $080B;
  SchemeEcdsaP521Sha512 = $0603;
  SchemeEd25519 = $0807;

  RsaMinimumBitsForTls = 2048;

type
  { Why a check failed: the signature is wrong, or it cannot be checked
    at all (algorithm, key kind or size not supported). }
  TSignatureCheck = (SignatureValid, SignatureInvalid, SignatureUnsupported);

{ The signature Subject's issuer (Signer) made on it. }
function CheckCertificateSignature(constref Signer: TTlsCertificate; constref Subject: TTlsCertificate): TSignatureCheck;

{ A signature over Data with the algorithm an AlgorithmIdentifier
  named (an OCSP response's, say). }
function CheckSignedData(constref Signer: TTlsCertificate; constref Parameters: TTlsSignatureParameters; Data: PByte;
  DataLength: PtrUInt; Signature: PByte; SignatureLength: PtrUInt): TSignatureCheck;

{ A handshake signature over Data with Scheme: CertificateVerify (TLS
  1.3), or ServerKeyExchange when Tls12 is set. }
function CheckHandshakeSignature(constref Signer: TTlsCertificate; Scheme: Word; Data: PByte; DataLength: PtrUInt;
  Signature: PByte; SignatureLength: PtrUInt; Tls12: Boolean = False): TSignatureCheck;

implementation

uses
  Crypto.Digests,
  Crypto.Rsa,
  Crypto.EllipticCurves,
  Crypto.Ecdsa,
  Crypto.Ed25519,
  Tls.Asn1;

type
  TSignatureMethod = (MethodRsaPkcs1, MethodRsaPss, MethodEcdsa, MethodEd25519);

(* Ecdsa-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } *)
function CheckEcdsa(constref Signer: TTlsCertificate; Digest: PByte; DigestLength: PtrUInt; Signature: PByte;
  SignatureLength: PtrUInt): TSignatureCheck;
var
  Reader, ValueReader: TAsn1Reader;
  Value, R, S: TAsn1Element;
  RBytes, SBytes: PByte;
  RLength, SLength: PtrUInt;
  Curve: TCurveName;
begin
  if Signer.PublicKeyKind = PublicKeyEcP256 then
    Curve := CurveP256
  else if Signer.PublicKeyKind = PublicKeyEcP384 then
    Curve := CurveP384
  else if Signer.PublicKeyKind = PublicKeyEcP521 then
    Curve := CurveP521
  else
    Exit(SignatureUnsupported);
  Result := SignatureInvalid;
  InitializeAsn1Reader(Reader, Signature, SignatureLength);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Value) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(ValueReader, Value);
  if not ReadAsn1Expected(ValueReader, Asn1Integer, R) or not ReadAsn1Expected(ValueReader, Asn1Integer, S) or
     not Asn1ReaderAtEnd(ValueReader) then
    Exit;
  if not ReadAsn1UnsignedInteger(R, RBytes, RLength) or not ReadAsn1UnsignedInteger(S, SBytes, SLength) then
    Exit;
  if VerifyEcdsaSignature(Curve, Signer.PublicKeyPoint.Data, Signer.PublicKeyPoint.Length, Digest, DigestLength,
    RBytes, RLength, SBytes, SLength) then
    Result := SignatureValid;
end;

function CheckRsa(constref Signer: TTlsCertificate; Method: TSignatureMethod; Algorithm: TDigestAlgorithm;
  Digest: PByte; SaltLength: Integer; Signature: PByte; SignatureLength: PtrUInt): TSignatureCheck;
var
  Key: ^TRsaPublicKey;
  Valid: Boolean;
begin
  if not (Signer.PublicKeyKind in [PublicKeyRsa, PublicKeyRsaPss]) then
    Exit(SignatureUnsupported);
  { An RSA-PSS key may only make PSS signatures. }
  if (Signer.PublicKeyKind = PublicKeyRsaPss) and (Method <> MethodRsaPss) then
    Exit(SignatureUnsupported);
  { The key is several kilobytes: on the heap. }
  New(Key);
  try
    if not PrepareRsaPublicKey(Key^, Signer.RsaModulus.Data, Signer.RsaModulus.Length, Signer.RsaExponent.Data,
      Signer.RsaExponent.Length) then
      Exit(SignatureUnsupported);
    if Key^.ModulusBits < RsaMinimumBitsForTls then
      Exit(SignatureUnsupported);
    if Method = MethodRsaPss then
      Valid := VerifyRsaPssSignature(Key^, Algorithm, Digest, SaltLength, Signature, SignatureLength)
    else
      Valid := VerifyRsaPkcs1Signature(Key^, Algorithm, Digest, Signature, SignatureLength);
  finally
    Dispose(Key);
  end;
  if Valid then
    Result := SignatureValid
  else
    Result := SignatureInvalid;
end;

{ Ed25519 signs the message itself (PureEdDSA, RFC 8032). }
function CheckEd25519(constref Signer: TTlsCertificate; Data: PByte; DataLength: PtrUInt; Signature: PByte;
  SignatureLength: PtrUInt): TSignatureCheck;
begin
  if (Signer.PublicKeyKind <> PublicKeyEd25519) or (Signer.PublicKeyPoint.Length <> 32) then
    Exit(SignatureUnsupported);
  if (SignatureLength = 64) and Ed25519Verify(Signer.PublicKeyPoint.Data, Data, DataLength, Signature) then
    Result := SignatureValid
  else
    Result := SignatureInvalid;
end;

function CheckWithMethod(constref Signer: TTlsCertificate; Method: TSignatureMethod; Algorithm: TDigestAlgorithm;
  SaltLength: Integer; Data: PByte; DataLength: PtrUInt; Signature: PByte; SignatureLength: PtrUInt): TSignatureCheck;
var
  Digest: TDigestOutput;
begin
  if Method = MethodEd25519 then
    Exit(CheckEd25519(Signer, Data, DataLength, Signature, SignatureLength));
  ComputeDigest(Algorithm, Data, DataLength, Digest);
  if Method = MethodEcdsa then
    Result := CheckEcdsa(Signer, @Digest[0], PtrUInt(DigestSize(Algorithm)), Signature, SignatureLength)
  else
    Result := CheckRsa(Signer, Method, Algorithm, @Digest[0], SaltLength, Signature, SignatureLength);
end;

function CheckSignedData(constref Signer: TTlsCertificate; constref Parameters: TTlsSignatureParameters; Data: PByte;
  DataLength: PtrUInt; Signature: PByte; SignatureLength: PtrUInt): TSignatureCheck;
var
  Method: TSignatureMethod;
  Algorithm: TDigestAlgorithm;
  SaltLength: Integer;
begin
  SaltLength := 0;
  Algorithm := DigestSha256;
  case Parameters.Algorithm of
    SignatureRsaPkcs1Sha256:
      begin
        Method := MethodRsaPkcs1;
        Algorithm := DigestSha256;
      end;
    SignatureRsaPkcs1Sha384:
      begin
        Method := MethodRsaPkcs1;
        Algorithm := DigestSha384;
      end;
    SignatureRsaPkcs1Sha512:
      begin
        Method := MethodRsaPkcs1;
        Algorithm := DigestSha512;
      end;
    SignatureRsaPss:
      begin
        Method := MethodRsaPss;
        Algorithm := Parameters.PssDigest;
        SaltLength := Parameters.PssSaltLength;
      end;
    SignatureEcdsaSha256:
      begin
        Method := MethodEcdsa;
        Algorithm := DigestSha256;
      end;
    SignatureEcdsaSha384:
      begin
        Method := MethodEcdsa;
        Algorithm := DigestSha384;
      end;
    SignatureEcdsaSha512:
      begin
        Method := MethodEcdsa;
        Algorithm := DigestSha512;
      end;
    SignatureEd25519:
      Method := MethodEd25519;
  else
    { Unknown algorithms and SHA-1. }
    Exit(SignatureUnsupported);
  end;
  Result := CheckWithMethod(Signer, Method, Algorithm, SaltLength, Data, DataLength, Signature, SignatureLength);
end;

function CheckCertificateSignature(constref Signer: TTlsCertificate; constref Subject: TTlsCertificate): TSignatureCheck;
begin
  Result := CheckSignedData(Signer, CertificateSignatureParameters(Subject), Subject.SignedPart.Data,
    Subject.SignedPart.Length, Subject.Signature.Data, Subject.Signature.Length);
end;

{ ECDSA in a TLS 1.2 handshake: any of the curves, with the scheme's
  hash. }
function EcdsaKeyKind(Kind: TTlsPublicKeyKind): Boolean;
begin
  Result := Kind in [PublicKeyEcP256, PublicKeyEcP384, PublicKeyEcP521];
end;

function CheckHandshakeSignature(constref Signer: TTlsCertificate; Scheme: Word; Data: PByte; DataLength: PtrUInt;
  Signature: PByte; SignatureLength: PtrUInt; Tls12: Boolean): TSignatureCheck;
var
  Method: TSignatureMethod;
  Algorithm: TDigestAlgorithm;
  Curve: TTlsPublicKeyKind;
begin
  Algorithm := DigestSha256;
  case Scheme of
    SchemeEcdsaP256Sha256, SchemeEcdsaP384Sha384, SchemeEcdsaP521Sha512:
      begin
        if Scheme = SchemeEcdsaP256Sha256 then
        begin
          Curve := PublicKeyEcP256;
          Algorithm := DigestSha256;
        end
        else if Scheme = SchemeEcdsaP384Sha384 then
        begin
          Curve := PublicKeyEcP384;
          Algorithm := DigestSha384;
        end
        else
        begin
          Curve := PublicKeyEcP521;
          Algorithm := DigestSha512;
        end;
        if Tls12 then
        begin
          if not EcdsaKeyKind(Signer.PublicKeyKind) then
            Exit(SignatureUnsupported);
        end
        else if Signer.PublicKeyKind <> Curve then
          Exit(SignatureUnsupported);
        Method := MethodEcdsa;
      end;
    SchemeEd25519:
      Method := MethodEd25519;
    SchemeRsaPkcs1Sha256, SchemeRsaPkcs1Sha384, SchemeRsaPkcs1Sha512:
      begin
        if not Tls12 or (Signer.PublicKeyKind <> PublicKeyRsa) then
          Exit(SignatureUnsupported);
        Method := MethodRsaPkcs1;
        if Scheme = SchemeRsaPkcs1Sha256 then
          Algorithm := DigestSha256
        else if Scheme = SchemeRsaPkcs1Sha384 then
          Algorithm := DigestSha384
        else
          Algorithm := DigestSha512;
      end;
    SchemeRsaPssRsaeSha256, SchemeRsaPssRsaeSha384, SchemeRsaPssRsaeSha512:
      begin
        if Signer.PublicKeyKind <> PublicKeyRsa then
          Exit(SignatureUnsupported);
        Method := MethodRsaPss;
        if Scheme = SchemeRsaPssRsaeSha256 then
          Algorithm := DigestSha256
        else if Scheme = SchemeRsaPssRsaeSha384 then
          Algorithm := DigestSha384
        else
          Algorithm := DigestSha512;
      end;
    SchemeRsaPssPssSha256, SchemeRsaPssPssSha384, SchemeRsaPssPssSha512:
      begin
        if Signer.PublicKeyKind <> PublicKeyRsaPss then
          Exit(SignatureUnsupported);
        Method := MethodRsaPss;
        if Scheme = SchemeRsaPssPssSha256 then
          Algorithm := DigestSha256
        else if Scheme = SchemeRsaPssPssSha384 then
          Algorithm := DigestSha384
        else
          Algorithm := DigestSha512;
      end;
  else
    Exit(SignatureUnsupported);
  end;
  { PSS in TLS 1.3: the salt is as long as the digest. }
  Result := CheckWithMethod(Signer, Method, Algorithm, DigestSize(Algorithm), Data, DataLength, Signature,
    SignatureLength);
end;

end.
