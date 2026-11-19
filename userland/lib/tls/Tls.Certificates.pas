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
  X.509 v3 certificates (RFC 5280), parsed from DER.

  ParseCertificate copies the encoding and fills in a TTlsCertificate
  whose byte ranges point into that copy: the signed part, the issuer
  and subject names (kept as DER, compared byte for byte), the validity,
  the public key and the extensions this library acts on (basic
  constraints, key usage, extended key usage, subject alternative names,
  key identifiers, name constraints, the TLS feature list). The
  extensions are in Tls.CertificateExtensions.

  Keys: RSA (and RSA-PSS), ECDSA on P-256, P-384 and P-521, and
  Ed25519. Signatures: RSA PKCS #1 v1.5 and PSS, ECDSA with SHA-2, and
  Ed25519 (RFC 8410).

  Anything malformed is refused (TlsErrorCertificateMalformed); a
  certificate with an algorithm this library cannot check is still
  parsed, its kind left unknown, so that the chain check can say what
  was wrong.
}
unit Tls.Certificates;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Crypto.Digests,
  Tls.Asn1,
  Tls.ByteBuffers;

type
  TTlsSignatureAlgorithm = (SignatureUnknown, SignatureRsaPkcs1Sha1, SignatureRsaPkcs1Sha256,
    SignatureRsaPkcs1Sha384, SignatureRsaPkcs1Sha512, SignatureRsaPss, SignatureEcdsaSha256,
    SignatureEcdsaSha384, SignatureEcdsaSha512, SignatureEd25519);

  TTlsPublicKeyKind = (PublicKeyUnknown, PublicKeyRsa, PublicKeyRsaPss, PublicKeyEcP256, PublicKeyEcP384,
    PublicKeyEcP521, PublicKeyEd25519);

  { A signature algorithm as an AlgorithmIdentifier names it (in a
    certificate, an OCSP response or a CRL). }
  TTlsSignatureParameters = record
    Algorithm: TTlsSignatureAlgorithm;
    { For RSA-PSS: the digest (MGF1 uses the same) and salt length. }
    PssDigest: TDigestAlgorithm;
    PssSaltLength: Integer;
  end;

  TTlsCertificate = record
    { The whole DER encoding, owned by the certificate. }
    Encoding: TTlsByteRange;
    { What the issuer signed (tbsCertificate), and its signature. }
    SignedPart: TTlsByteRange;
    SignatureAlgorithm: TTlsSignatureAlgorithm;
    { For RSA-PSS: the digest (MGF1 uses the same) and salt length. }
    PssDigest: TDigestAlgorithm;
    PssSaltLength: Integer;
    Signature: TTlsByteRange;

    { 1 to 3. }
    Version: Integer;
    SerialNumber: TTlsByteRange;
    { The names as DER (the whole SEQUENCE). }
    Issuer: TTlsByteRange;
    Subject: TTlsByteRange;
    { The first common name of each, for messages (may be empty). }
    IssuerCommonName: TTlsByteRange;
    SubjectCommonName: TTlsByteRange;
    NotBefore: Int64;
    NotAfter: Int64;

    PublicKeyKind: TTlsPublicKeyKind;
    { RSA: modulus and exponent. EC: the point in PublicKeyPoint;
      Ed25519: the 32-byte key there too. }
    RsaModulus: TTlsByteRange;
    RsaExponent: TTlsByteRange;
    PublicKeyPoint: TTlsByteRange;
    { The subjectPublicKey BIT STRING's bytes (what OCSP hashes). }
    PublicKeyBits: TTlsByteRange;

    { Extensions. }
    HasBasicConstraints: Boolean;
    IsAuthority: Boolean;
    { -1 when not limited. }
    PathLengthLimit: LongInt;
    HasKeyUsage: Boolean;
    KeyUsage: LongWord;
    HasExtendedKeyUsage: Boolean;
    AllowsServerAuthentication: Boolean;
    { id-kp-OCSPSigning: a delegated OCSP responder. }
    AllowsOcspSigning: Boolean;
    HasSubjectAlternativeNames: Boolean;
    { The contents of the GeneralNames SEQUENCE. }
    SubjectAlternativeNames: TTlsByteRange;
    SubjectKeyIdentifier: TTlsByteRange;
    AuthorityKeyIdentifier: TTlsByteRange;
    { Name constraints (an authority's): the contents of the permitted
      and excluded GeneralSubtrees (empty when absent). }
    HasNameConstraints: Boolean;
    PermittedSubtrees: TTlsByteRange;
    ExcludedSubtrees: TTlsByteRange;
    { The TLS feature extension (RFC 7633) lists status_request: the
      server must staple an OCSP response ("must staple"). }
    RequiresStapledStatus: Boolean;
    { A critical extension this library does not know: the certificate
      cannot be used. }
    HasUnsupportedCriticalExtension: Boolean;
  end;
  PTlsCertificate = ^TTlsCertificate;

const
  { KeyUsage bits (RFC 5280 section 4.2.1.3). }
  KeyUsageDigitalSignature = 1 shl 0;
  KeyUsageKeyEncipherment = 1 shl 2;
  KeyUsageKeyAgreement = 1 shl 4;
  KeyUsageKeyCertificateSign = 1 shl 5;

{ TlsErrorNone with a new certificate (free it with FreeCertificate), or
  TlsErrorCertificateMalformed / TlsErrorOutOfMemory. }
function ParseCertificate(Data: PByte; Length: PtrUInt; out Certificate: PTlsCertificate): LongInt;
procedure FreeCertificate(var Certificate: PTlsCertificate);

{ A common name as text ("?" for characters outside printable ASCII);
  "(no common name)" when there is none. }
function CommonNameText(constref Name: TTlsByteRange): string;

{ An AlgorithmIdentifier of a signature (Element is its SEQUENCE).
  False when malformed; an algorithm this library does not check gives
  True with SignatureUnknown. }
function ReadSignatureAlgorithmIdentifier(constref Element: TAsn1Element;
  out Parameters: TTlsSignatureParameters): Boolean;
{ The signature parameters of a certificate's own signature. }
function CertificateSignatureParameters(constref Certificate: TTlsCertificate): TTlsSignatureParameters;

implementation

uses
  SysUtils,
  Crypto.Bits,
  Tls.Errors,
  Tls.ObjectIdentifiers,
  Tls.CertificateExtensions;

function OidIs(constref Element: TAsn1Element; const Identifier: array of Byte): Boolean;
begin
  Result := Asn1ObjectIdentifierIs(Element, @Identifier[0], Length(Identifier));
end;

{ Absent parameters, or NULL. }
function ParametersAreNullOrAbsent(var Reader: TAsn1Reader): Boolean;
var
  Parameters: TAsn1Element;
begin
  if Asn1ReaderAtEnd(Reader) then
    Exit(True);
  Result := ReadAsn1Expected(Reader, Asn1Null, Parameters) and (Parameters.ContentsLength = 0) and
    Asn1ReaderAtEnd(Reader);
end;

function DigestFromOid(constref Element: TAsn1Element; out Algorithm: TDigestAlgorithm): Boolean;
begin
  Result := True;
  Algorithm := DigestSha256;
  if OidIs(Element, OidSha256) then
    Algorithm := DigestSha256
  else if OidIs(Element, OidSha384) then
    Algorithm := DigestSha384
  else if OidIs(Element, OidSha512) then
    Algorithm := DigestSha512
  else
    Result := False;
end;

{ HashAlgorithm ::= AlgorithmIdentifier of a SHA-2 digest. }
function ReadHashAlgorithm(constref Element: TAsn1Element; out Algorithm: TDigestAlgorithm): Boolean;
var
  Reader: TAsn1Reader;
  Identifier: TAsn1Element;
begin
  Algorithm := DigestSha256;
  if Element.Tag <> Asn1Sequence then
    Exit(False);
  OpenAsn1Element(Reader, Element);
  Result := ReadAsn1Expected(Reader, Asn1ObjectIdentifier, Identifier) and DigestFromOid(Identifier, Algorithm) and
    ParametersAreNullOrAbsent(Reader);
end;

{ RSASSA-PSS-params (RFC 4055 section 3.1). The SHA-1 defaults are not
  accepted: the digest must be SHA-256, -384 or -512, MGF1 must use the
  same one and the trailer must be 1. Unusable parameters leave the
  algorithm unknown; malformed ones fail. }
function ReadPssParameters(var Reader: TAsn1Reader; var Signature: TTlsSignatureParameters): Boolean;
var
  Parameters, Field, Inner, Identifier, MaskHash: TAsn1Element;
  ParameterReader, FieldReader, InnerReader: TAsn1Reader;
  Present: Boolean;
  MaskDigest: TDigestAlgorithm;
  SaltLength, Trailer: LongInt;
  Usable: Boolean;
begin
  { No parameters: the SHA-1 defaults, which are not accepted. }
  if Asn1ReaderAtEnd(Reader) then
  begin
    Signature.Algorithm := SignatureUnknown;
    Exit(True);
  end;
  Result := ReadAsn1Expected(Reader, Asn1Sequence, Parameters) and Asn1ReaderAtEnd(Reader);
  if not Result then
    Exit;
  OpenAsn1Element(ParameterReader, Parameters);
  Usable := True;
  Signature.PssDigest := DigestSha1;
  MaskDigest := DigestSha1;
  SaltLength := 20;
  Trailer := 1;

  if not ReadAsn1Optional(ParameterReader, Asn1ContextSpecific or Asn1Constructed or 0, Field, Present) then
    Exit(False);
  if Present then
  begin
    OpenAsn1Element(FieldReader, Field);
    if not ReadAsn1Element(FieldReader, Inner) or not Asn1ReaderAtEnd(FieldReader) then
      Exit(False);
    if not ReadHashAlgorithm(Inner, Signature.PssDigest) then
      Usable := False;
  end
  else
    Usable := False;

  if not ReadAsn1Optional(ParameterReader, Asn1ContextSpecific or Asn1Constructed or 1, Field, Present) then
    Exit(False);
  if Present then
  begin
    { MaskGenAlgorithm: id-mgf1 with a HashAlgorithm. }
    OpenAsn1Element(FieldReader, Field);
    if not ReadAsn1Expected(FieldReader, Asn1Sequence, Inner) or not Asn1ReaderAtEnd(FieldReader) then
      Exit(False);
    OpenAsn1Element(InnerReader, Inner);
    if not ReadAsn1Expected(InnerReader, Asn1ObjectIdentifier, Identifier) then
      Exit(False);
    if not OidIs(Identifier, OidMgf1) then
      Usable := False
    else if not ReadAsn1Element(InnerReader, MaskHash) or not ReadHashAlgorithm(MaskHash, MaskDigest) then
      Usable := False;
  end
  else
    Usable := False;

  if not ReadAsn1Optional(ParameterReader, Asn1ContextSpecific or Asn1Constructed or 2, Field, Present) then
    Exit(False);
  if Present then
  begin
    OpenAsn1Element(FieldReader, Field);
    if not ReadAsn1Element(FieldReader, Inner) or not ReadAsn1SmallInteger(Inner, SaltLength) then
      Exit(False);
  end;
  if not ReadAsn1Optional(ParameterReader, Asn1ContextSpecific or Asn1Constructed or 3, Field, Present) then
    Exit(False);
  if Present then
  begin
    OpenAsn1Element(FieldReader, Field);
    if not ReadAsn1Element(FieldReader, Inner) or not ReadAsn1SmallInteger(Inner, Trailer) then
      Exit(False);
  end;
  if not Asn1ReaderAtEnd(ParameterReader) then
    Exit(False);
  if (Trailer <> 1) or (MaskDigest <> Signature.PssDigest) or (SaltLength > 512) then
    Usable := False;
  Signature.PssSaltLength := SaltLength;
  if Usable then
    Signature.Algorithm := SignatureRsaPss
  else
    Signature.Algorithm := SignatureUnknown;
end;

function ReadSignatureAlgorithmIdentifier(constref Element: TAsn1Element;
  out Parameters: TTlsSignatureParameters): Boolean;
var
  Reader: TAsn1Reader;
  Identifier: TAsn1Element;
begin
  if Element.Tag <> Asn1Sequence then
    Exit(False);
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Expected(Reader, Asn1ObjectIdentifier, Identifier) then
    Exit(False);
  Parameters.Algorithm := SignatureUnknown;
  Parameters.PssDigest := DigestSha256;
  Parameters.PssSaltLength := 0;
  if OidIs(Identifier, OidRsaPss) then
    Exit(ReadPssParameters(Reader, Parameters));
  if OidIs(Identifier, OidSha256WithRsa) then
    Parameters.Algorithm := SignatureRsaPkcs1Sha256
  else if OidIs(Identifier, OidSha384WithRsa) then
    Parameters.Algorithm := SignatureRsaPkcs1Sha384
  else if OidIs(Identifier, OidSha512WithRsa) then
    Parameters.Algorithm := SignatureRsaPkcs1Sha512
  else if OidIs(Identifier, OidSha1WithRsa) then
    Parameters.Algorithm := SignatureRsaPkcs1Sha1
  else if OidIs(Identifier, OidEcdsaWithSha256) then
    Parameters.Algorithm := SignatureEcdsaSha256
  else if OidIs(Identifier, OidEcdsaWithSha384) then
    Parameters.Algorithm := SignatureEcdsaSha384
  else if OidIs(Identifier, OidEcdsaWithSha512) then
    Parameters.Algorithm := SignatureEcdsaSha512
  else if OidIs(Identifier, OidEd25519) then
    Parameters.Algorithm := SignatureEd25519
  else
    Exit(True);
  if Parameters.Algorithm in [SignatureEcdsaSha256, SignatureEcdsaSha384, SignatureEcdsaSha512,
    SignatureEd25519] then
    { ECDSA and Ed25519 have no parameters at all (RFC 5758, RFC 8410). }
    Result := Asn1ReaderAtEnd(Reader)
  else
    Result := ParametersAreNullOrAbsent(Reader);
end;

function CertificateSignatureParameters(constref Certificate: TTlsCertificate): TTlsSignatureParameters;
begin
  Result.Algorithm := Certificate.SignatureAlgorithm;
  Result.PssDigest := Certificate.PssDigest;
  Result.PssSaltLength := Certificate.PssSaltLength;
end;

{ The certificate's signature algorithm, into its fields. }
function ReadSignatureAlgorithm(constref Element: TAsn1Element; var Certificate: TTlsCertificate): Boolean;
var
  Parameters: TTlsSignatureParameters;
begin
  Result := ReadSignatureAlgorithmIdentifier(Element, Parameters);
  Certificate.SignatureAlgorithm := Parameters.Algorithm;
  Certificate.PssDigest := Parameters.PssDigest;
  Certificate.PssSaltLength := Parameters.PssSaltLength;
end;

(* RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } *)
function ReadRsaPublicKey(Bytes: PByte; Count: PtrUInt; var Certificate: TTlsCertificate): Boolean;
var
  Reader, KeyReader: TAsn1Reader;
  Key, Modulus, Exponent: TAsn1Element;
begin
  InitializeAsn1Reader(Reader, Bytes, Count);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Key) or not Asn1ReaderAtEnd(Reader) then
    Exit(False);
  OpenAsn1Element(KeyReader, Key);
  if not ReadAsn1Expected(KeyReader, Asn1Integer, Modulus) or not ReadAsn1Expected(KeyReader, Asn1Integer, Exponent) or
     not Asn1ReaderAtEnd(KeyReader) then
    Exit(False);
  Result := ReadAsn1UnsignedInteger(Modulus, Certificate.RsaModulus.Data, Certificate.RsaModulus.Length) and
    ReadAsn1UnsignedInteger(Exponent, Certificate.RsaExponent.Data, Certificate.RsaExponent.Length);
end;

function ReadSubjectPublicKeyInfo(constref Element: TAsn1Element; var Certificate: TTlsCertificate): Boolean;
var
  Reader, AlgorithmReader: TAsn1Reader;
  Algorithm, Identifier, Curve, KeyBits: TAsn1Element;
  KeyBytes: PByte;
  KeyLength: PtrUInt;
begin
  Result := False;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Algorithm) or not ReadAsn1Expected(Reader, Asn1BitString, KeyBits) or
     not Asn1ReaderAtEnd(Reader) then
    Exit;
  if not ReadAsn1BitStringBytes(KeyBits, KeyBytes, KeyLength) then
    Exit;
  Certificate.PublicKeyBits := ByteRange(KeyBytes, KeyLength);
  OpenAsn1Element(AlgorithmReader, Algorithm);
  if not ReadAsn1Expected(AlgorithmReader, Asn1ObjectIdentifier, Identifier) then
    Exit;
  Certificate.PublicKeyKind := PublicKeyUnknown;
  if OidIs(Identifier, OidRsaEncryption) or OidIs(Identifier, OidRsaPss) then
  begin
    if OidIs(Identifier, OidRsaEncryption) then
    begin
      if not ParametersAreNullOrAbsent(AlgorithmReader) then
        Exit;
      Certificate.PublicKeyKind := PublicKeyRsa;
    end
    else
      { The parameters of an RSA-PSS key only restrict it further; the
        signature's own parameters are what is checked. }
      Certificate.PublicKeyKind := PublicKeyRsaPss;
    if not ReadRsaPublicKey(KeyBytes, KeyLength, Certificate) then
      Exit;
  end
  else if OidIs(Identifier, OidEcPublicKey) then
  begin
    if not ReadAsn1Expected(AlgorithmReader, Asn1ObjectIdentifier, Curve) or not Asn1ReaderAtEnd(AlgorithmReader) then
      Exit;
    if OidIs(Curve, OidCurveP256) then
      Certificate.PublicKeyKind := PublicKeyEcP256
    else if OidIs(Curve, OidCurveP384) then
      Certificate.PublicKeyKind := PublicKeyEcP384
    else if OidIs(Curve, OidCurveP521) then
      Certificate.PublicKeyKind := PublicKeyEcP521;
    Certificate.PublicKeyPoint := ByteRange(KeyBytes, KeyLength);
  end
  else if OidIs(Identifier, OidEd25519) then
  begin
    { No parameters, and a 32-byte key (RFC 8410). }
    if not Asn1ReaderAtEnd(AlgorithmReader) or (KeyLength <> 32) then
      Exit;
    Certificate.PublicKeyKind := PublicKeyEd25519;
    Certificate.PublicKeyPoint := ByteRange(KeyBytes, KeyLength);
  end;
  Result := True;
end;

{ Name ::= SEQUENCE OF RelativeDistinguishedName (SET OF
  AttributeTypeAndValue); finds the first common name. }
function ReadName(constref Element: TAsn1Element; out Encoding, CommonName: TTlsByteRange): Boolean;
var
  NameReader, SetReader, AttributeReader: TAsn1Reader;
  DistinguishedName, Attribute, AttributeType, AttributeValue: TAsn1Element;
begin
  Encoding := ByteRange(Element.Encoding, Element.EncodingLength);
  CommonName := ByteRange(nil, 0);
  Result := False;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(NameReader, Element);
  while not Asn1ReaderAtEnd(NameReader) do
  begin
    if not ReadAsn1Expected(NameReader, Asn1Set, DistinguishedName) then
      Exit;
    OpenAsn1Element(SetReader, DistinguishedName);
    if Asn1ReaderAtEnd(SetReader) then
      Exit;
    while not Asn1ReaderAtEnd(SetReader) do
    begin
      if not ReadAsn1Expected(SetReader, Asn1Sequence, Attribute) then
        Exit;
      OpenAsn1Element(AttributeReader, Attribute);
      if not ReadAsn1Expected(AttributeReader, Asn1ObjectIdentifier, AttributeType) or
         not ReadAsn1Element(AttributeReader, AttributeValue) or not Asn1ReaderAtEnd(AttributeReader) then
        Exit;
      if OidIs(AttributeType, OidCommonName) and (CommonName.Data = nil) then
        CommonName := ByteRange(AttributeValue.Contents, AttributeValue.ContentsLength);
    end;
  end;
  Result := True;
end;

function ReadValidity(constref Element: TAsn1Element; var Certificate: TTlsCertificate): Boolean;
var
  Reader: TAsn1Reader;
  NotBefore, NotAfter: TAsn1Element;
begin
  Result := False;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Element(Reader, NotBefore) or not ReadAsn1Element(Reader, NotAfter) or
     not Asn1ReaderAtEnd(Reader) then
    Exit;
  Result := ReadAsn1Time(NotBefore, Certificate.NotBefore) and ReadAsn1Time(NotAfter, Certificate.NotAfter);
end;

function ReadSignedPart(constref Element: TAsn1Element; var Certificate: TTlsCertificate;
  out InnerAlgorithm: TAsn1Element): Boolean;
var
  Reader, VersionReader: TAsn1Reader;
  VersionField, VersionNumber, Serial, Issuer, Validity, Subject, KeyInfo, Optional: TAsn1Element;
  Present: Boolean;
  Version: LongInt;
begin
  Result := False;
  FillChar(InnerAlgorithm, SizeOf(InnerAlgorithm), 0);
  if Element.Tag <> Asn1Sequence then
    Exit;
  Certificate.SignedPart := ByteRange(Element.Encoding, Element.EncodingLength);
  OpenAsn1Element(Reader, Element);

  Version := 0;
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 0, VersionField, Present) then
    Exit;
  if Present then
  begin
    OpenAsn1Element(VersionReader, VersionField);
    if not ReadAsn1Element(VersionReader, VersionNumber) or not Asn1ReaderAtEnd(VersionReader) or
       not ReadAsn1SmallInteger(VersionNumber, Version) then
      Exit;
    { DER leaves out the default v1. }
    if (Version < 1) or (Version > 2) then
      Exit;
  end;
  Certificate.Version := Version + 1;

  if not ReadAsn1Expected(Reader, Asn1Integer, Serial) or (Serial.ContentsLength = 0) then
    Exit;
  Certificate.SerialNumber := ByteRange(Serial.Contents, Serial.ContentsLength);
  if not ReadAsn1Expected(Reader, Asn1Sequence, InnerAlgorithm) then
    Exit;
  if not ReadAsn1Element(Reader, Issuer) or not ReadName(Issuer, Certificate.Issuer, Certificate.IssuerCommonName) then
    Exit;
  if not ReadAsn1Element(Reader, Validity) or not ReadValidity(Validity, Certificate) then
    Exit;
  if not ReadAsn1Element(Reader, Subject) or
     not ReadName(Subject, Certificate.Subject, Certificate.SubjectCommonName) then
    Exit;
  if not ReadAsn1Element(Reader, KeyInfo) or not ReadSubjectPublicKeyInfo(KeyInfo, Certificate) then
    Exit;

  { Unique identifiers (v2 and v3), skipped. }
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or 1, Optional, Present) then
    Exit;
  if Present and (Certificate.Version < 2) then
    Exit;
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or 2, Optional, Present) then
    Exit;
  if Present and (Certificate.Version < 2) then
    Exit;
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 3, Optional, Present) then
    Exit;
  if Present then
  begin
    if Certificate.Version <> 3 then
      Exit;
    if not ReadCertificateExtensions(Optional, Certificate) then
      Exit;
  end;
  Result := Asn1ReaderAtEnd(Reader);
end;

function ParseEncoding(var Certificate: TTlsCertificate): Boolean;
var
  Reader, CertificateReader: TAsn1Reader;
  Whole, SignedPart, InnerAlgorithm, OuterAlgorithm, SignatureBits: TAsn1Element;
begin
  Result := False;
  InitializeAsn1Reader(Reader, Certificate.Encoding.Data, Certificate.Encoding.Length);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Whole) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(CertificateReader, Whole);
  if not ReadAsn1Element(CertificateReader, SignedPart) or
     not ReadAsn1Expected(CertificateReader, Asn1Sequence, OuterAlgorithm) or
     not ReadAsn1Expected(CertificateReader, Asn1BitString, SignatureBits) or
     not Asn1ReaderAtEnd(CertificateReader) then
    Exit;
  if not ReadSignedPart(SignedPart, Certificate, InnerAlgorithm) then
    Exit;
  { The algorithm inside the signed part must be the same as outside. }
  if (InnerAlgorithm.EncodingLength <> OuterAlgorithm.EncodingLength) or
     (CompareByte(InnerAlgorithm.Encoding^, OuterAlgorithm.Encoding^, OuterAlgorithm.EncodingLength) <> 0) then
    Exit;
  if not ReadSignatureAlgorithm(OuterAlgorithm, Certificate) then
    Exit;
  Result := ReadAsn1BitStringBytes(SignatureBits, Certificate.Signature.Data, Certificate.Signature.Length);
end;

function ParseCertificate(Data: PByte; Length: PtrUInt; out Certificate: PTlsCertificate): LongInt;
var
  Copy: PByte;
begin
  Certificate := nil;
  if (Data = nil) or (Length = 0) or (Length > 64 * 1024) then
    Exit(TlsErrorCertificateMalformed);
  Certificate := AllocMem(SizeOf(TTlsCertificate));
  Copy := GetMem(Length);
  if (Certificate = nil) or (Copy = nil) then
  begin
    if Certificate <> nil then
      FreeMem(Certificate);
    if Copy <> nil then
      FreeMem(Copy);
    Certificate := nil;
    Exit(TlsErrorOutOfMemory);
  end;
  Move(Data^, Copy^, Length);
  Certificate^.Encoding := ByteRange(Copy, Length);
  Certificate^.PathLengthLimit := -1;
  if not ParseEncoding(Certificate^) then
  begin
    FreeCertificate(Certificate);
    Exit(TlsErrorCertificateMalformed);
  end;
  Result := TlsErrorNone;
end;

procedure FreeCertificate(var Certificate: PTlsCertificate);
begin
  if Certificate = nil then
    Exit;
  if Certificate^.Encoding.Data <> nil then
    FreeMem(Certificate^.Encoding.Data);
  FreeMem(Certificate);
  Certificate := nil;
end;

function CommonNameText(constref Name: TTlsByteRange): string;
var
  Index: PtrUInt;
  Character: Byte;
begin
  if Name.Length = 0 then
    Exit('(no common name)');
  SetLength(Result, Name.Length);
  for Index := 0 to Name.Length - 1 do
  begin
    Character := Name.Data[Index];
    if (Character >= 32) and (Character < 127) then
      Result[Index + 1] := Chr(Character)
    else
      Result[Index + 1] := '?';
  end;
end;

end.
