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
  Checking an OCSP response a server stapled to its certificate (RFC
  6960, RFC 6066 section 8):

  - it must be a successful response of the basic type;
  - it must be signed by the certificate's issuer, or by a responder
    certificate it carries that the issuer signed directly, that allows
    OCSP signing (id-kp-OCSPSigning) and is valid now; the responder id
    (by name or by key hash) must name the signer;
  - one of its single responses must be for the certificate: the
    issuer's name and key hashed with the response's hash (SHA-1 or
    SHA-2) and the serial number;
  - that response must be current: thisUpdate not in the future,
    nextUpdate not past (five minutes of clock skew either way), or
    when there is no nextUpdate, thisUpdate within the last four days.

  Then "good" is good, "revoked" fails the connection and "unknown" is
  reported (the caller decides: must-staple certificates need "good").
  Anything else wrong with the response makes it invalid.
}
unit Tls.Ocsp;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.Certificates;

type
  TOcspStatus = (OcspGood, OcspRevoked, OcspUnknown);

const
  OcspClockSkewSeconds = 5 * 60;
  OcspMaximumAgeWithoutNextUpdate = 4 * 24 * 60 * 60;

{ For a valid response: TlsErrorNone (Status good or unknown) or
  TlsErrorCertificateRevoked; else TlsErrorCertificateStatusInvalid. }
function CheckOcspResponse(Response: PByte; ResponseLength: PtrUInt; constref Subject, Issuer: TTlsCertificate;
  Time: Int64; out Status: TOcspStatus): LongInt;

implementation

uses
  Crypto.Digests,
  Tls.Asn1,
  Tls.ByteBuffers,
  Tls.Errors,
  Tls.ObjectIdentifiers,
  Tls.Signatures;

const
  Asn1Enumerated = $0A;

type
  TResponderId = record
    ByKey: Boolean;
    { The Name (DER) or the SHA-1 key hash. }
    Value: TTlsByteRange;
  end;

  TBasicResponse = record
    SignedData: TTlsByteRange;
    Signature: TTlsSignatureParameters;
    SignatureBits: TTlsByteRange;
    Responder: TResponderId;
    { The contents of responses (SEQUENCE OF SingleResponse). }
    Responses: TTlsByteRange;
    { The contents of certs, or empty. }
    Certificates: TTlsByteRange;
  end;

function OidIs(constref Element: TAsn1Element; const Identifier: array of Byte): Boolean;
begin
  Result := Asn1ObjectIdentifierIs(Element, @Identifier[0], Length(Identifier));
end;

function RangeOfContents(constref Element: TAsn1Element): TTlsByteRange;
begin
  Result := ByteRange(Element.Contents, Element.ContentsLength);
end;

(* OCSPResponse ::= SEQUENCE { responseStatus ENUMERATED, responseBytes
   [0] EXPLICIT SEQUENCE { responseType OID, response OCTET STRING } } *)
function ReadBasicResponseBytes(Data: PByte; Length: PtrUInt; out Basic: TTlsByteRange): Boolean;
var
  Reader, ResponseReader, WrapperReader, BytesReader: TAsn1Reader;
  Whole, Status, Wrapper, ResponseBytes, ResponseType, Response: TAsn1Element;
begin
  Result := False;
  Basic := ByteRange(nil, 0);
  InitializeAsn1Reader(Reader, Data, Length);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Whole) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(ResponseReader, Whole);
  { successful (0) }
  if not ReadAsn1Expected(ResponseReader, Asn1Enumerated, Status) or (Status.ContentsLength <> 1) or
     (Status.Contents[0] <> 0) then
    Exit;
  if not ReadAsn1Expected(ResponseReader, Asn1ContextSpecific or Asn1Constructed or 0, Wrapper) or
     not Asn1ReaderAtEnd(ResponseReader) then
    Exit;
  OpenAsn1Element(WrapperReader, Wrapper);
  if not ReadAsn1Expected(WrapperReader, Asn1Sequence, ResponseBytes) or not Asn1ReaderAtEnd(WrapperReader) then
    Exit;
  OpenAsn1Element(BytesReader, ResponseBytes);
  if not ReadAsn1Expected(BytesReader, Asn1ObjectIdentifier, ResponseType) or not OidIs(ResponseType, OidOcspBasic) or
     not ReadAsn1Expected(BytesReader, Asn1OctetString, Response) or not Asn1ReaderAtEnd(BytesReader) then
    Exit;
  Basic := RangeOfContents(Response);
  Result := True;
end;

(* ResponseData ::= SEQUENCE { version [0] EXPLICIT DEFAULT v1,
   responderID CHOICE { byName [1] Name, byKey [2] KeyHash },
   producedAt GeneralizedTime, responses SEQUENCE OF SingleResponse,
   responseExtensions [1] EXPLICIT Extensions OPTIONAL } *)
function ReadResponseData(constref Element: TAsn1Element; var Basic: TBasicResponse): Boolean;
var
  Reader, ChoiceReader: TAsn1Reader;
  Field, Choice, Inner, Responses: TAsn1Element;
  Present: Boolean;
  Version: LongInt;
  ProducedAt: Int64;
begin
  Result := False;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 0, Field, Present) then
    Exit;
  if Present then
  begin
    OpenAsn1Element(ChoiceReader, Field);
    if not ReadAsn1Element(ChoiceReader, Inner) or not ReadAsn1SmallInteger(Inner, Version) or (Version <> 0) then
      Exit;
  end;
  if not ReadAsn1Element(Reader, Choice) then
    Exit;
  OpenAsn1Element(ChoiceReader, Choice);
  if not ReadAsn1Element(ChoiceReader, Inner) or not Asn1ReaderAtEnd(ChoiceReader) then
    Exit;
  if Choice.Tag = Asn1ContextSpecific or Asn1Constructed or 1 then
  begin
    if Inner.Tag <> Asn1Sequence then
      Exit;
    Basic.Responder.ByKey := False;
    Basic.Responder.Value := ByteRange(Inner.Encoding, Inner.EncodingLength);
  end
  else if Choice.Tag = Asn1ContextSpecific or Asn1Constructed or 2 then
  begin
    if (Inner.Tag <> Asn1OctetString) or (Inner.ContentsLength <> 20) then
      Exit;
    Basic.Responder.ByKey := True;
    Basic.Responder.Value := RangeOfContents(Inner);
  end
  else
    Exit;
  if not ReadAsn1Element(Reader, Field) or not ReadAsn1Time(Field, ProducedAt) then
    Exit;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Responses) then
    Exit;
  Basic.Responses := RangeOfContents(Responses);
  { Extensions (a nonce, say) are not acted on: a staple has none. }
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 1, Field, Present) then
    Exit;
  Result := Asn1ReaderAtEnd(Reader);
end;

(* BasicOCSPResponse ::= SEQUENCE { tbsResponseData ResponseData,
   signatureAlgorithm AlgorithmIdentifier, signature BIT STRING,
   certs [0] EXPLICIT SEQUENCE OF Certificate OPTIONAL } *)
function ReadBasicResponse(constref Bytes: TTlsByteRange; out Basic: TBasicResponse): Boolean;
var
  Reader, BasicReader, CertificatesReader: TAsn1Reader;
  Whole, Data, Algorithm, Signature, Wrapper, List: TAsn1Element;
  Present: Boolean;
begin
  Result := False;
  Basic := Default(TBasicResponse);
  InitializeAsn1Reader(Reader, Bytes.Data, Bytes.Length);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Whole) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(BasicReader, Whole);
  if not ReadAsn1Element(BasicReader, Data) or not ReadResponseData(Data, Basic) then
    Exit;
  Basic.SignedData := ByteRange(Data.Encoding, Data.EncodingLength);
  if not ReadAsn1Expected(BasicReader, Asn1Sequence, Algorithm) or
     not ReadSignatureAlgorithmIdentifier(Algorithm, Basic.Signature) then
    Exit;
  if not ReadAsn1Expected(BasicReader, Asn1BitString, Signature) or
     not ReadAsn1BitStringBytes(Signature, Basic.SignatureBits.Data, Basic.SignatureBits.Length) then
    Exit;
  if not ReadAsn1Optional(BasicReader, Asn1ContextSpecific or Asn1Constructed or 0, Wrapper, Present) then
    Exit;
  if Present then
  begin
    OpenAsn1Element(CertificatesReader, Wrapper);
    if not ReadAsn1Expected(CertificatesReader, Asn1Sequence, List) or not Asn1ReaderAtEnd(CertificatesReader) then
      Exit;
    Basic.Certificates := RangeOfContents(List);
  end;
  Result := Asn1ReaderAtEnd(BasicReader);
end;

function ResponderIs(constref Responder: TResponderId; constref Candidate: TTlsCertificate): Boolean;
var
  KeyHash: TDigestOutput;
begin
  if not Responder.ByKey then
    Exit(ByteRangesEqual(Responder.Value, Candidate.Subject));
  ComputeDigest(DigestSha1, Candidate.PublicKeyBits.Data, Candidate.PublicKeyBits.Length, KeyHash);
  Result := CompareByte(KeyHash[0], Responder.Value.Data^, 20) = 0;
end;

function SignedBy(constref Basic: TBasicResponse; constref Signer: TTlsCertificate): Boolean;
begin
  Result := CheckSignedData(Signer, Basic.Signature, Basic.SignedData.Data, Basic.SignedData.Length,
    Basic.SignatureBits.Data, Basic.SignatureBits.Length) = SignatureValid;
end;

{ A delegated responder among the certificates the response carries. }
function SignedByDelegate(constref Basic: TBasicResponse; constref Issuer: TTlsCertificate; Time: Int64): Boolean;
var
  Reader: TAsn1Reader;
  Element: TAsn1Element;
  Delegate: PTlsCertificate;
  Usable: Boolean;
begin
  Result := False;
  InitializeAsn1Reader(Reader, Basic.Certificates.Data, Basic.Certificates.Length);
  while ReadAsn1Element(Reader, Element) do
  begin
    if ParseCertificate(Element.Encoding, Element.EncodingLength, Delegate) <> TlsErrorNone then
      Continue;
    Usable := ResponderIs(Basic.Responder, Delegate^) and ByteRangesEqual(Delegate^.Issuer, Issuer.Subject) and
      Delegate^.HasExtendedKeyUsage and Delegate^.AllowsOcspSigning and not Delegate^.HasUnsupportedCriticalExtension and
      (Time >= Delegate^.NotBefore) and (Time <= Delegate^.NotAfter) and
      (CheckCertificateSignature(Issuer, Delegate^) = SignatureValid);
    if Usable and SignedBy(Basic, Delegate^) then
      Result := True;
    FreeCertificate(Delegate);
    if Result then
      Exit;
  end;
end;

function DigestOfOid(constref Identifier: TAsn1Element; out Algorithm: TDigestAlgorithm): Boolean;
begin
  Result := True;
  Algorithm := DigestSha1;
  if OidIs(Identifier, OidSha1) then
    Algorithm := DigestSha1
  else if OidIs(Identifier, OidSha256) then
    Algorithm := DigestSha256
  else if OidIs(Identifier, OidSha384) then
    Algorithm := DigestSha384
  else if OidIs(Identifier, OidSha512) then
    Algorithm := DigestSha512
  else
    Result := False;
end;

function HashMatches(Algorithm: TDigestAlgorithm; constref Data: TTlsByteRange; constref Expected: TAsn1Element): Boolean;
var
  Hash: TDigestOutput;
begin
  ComputeDigest(Algorithm, Data.Data, Data.Length, Hash);
  Result := (Expected.ContentsLength = PtrUInt(DigestSize(Algorithm))) and
    (CompareByte(Hash[0], Expected.Contents^, Expected.ContentsLength) = 0);
end;

(* CertID ::= SEQUENCE { hashAlgorithm AlgorithmIdentifier,
   issuerNameHash OCTET STRING, issuerKeyHash OCTET STRING,
   serialNumber INTEGER } *)
function CertificateIdMatches(constref Element: TAsn1Element; constref Subject, Issuer: TTlsCertificate): Boolean;
var
  Reader, AlgorithmReader: TAsn1Reader;
  Algorithm, Identifier, NameHash, KeyHash, Serial: TAsn1Element;
  Digest: TDigestAlgorithm;
begin
  Result := False;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Expected(Reader, Asn1Sequence, Algorithm) or not ReadAsn1Expected(Reader, Asn1OctetString, NameHash) or
     not ReadAsn1Expected(Reader, Asn1OctetString, KeyHash) or not ReadAsn1Expected(Reader, Asn1Integer, Serial) or
     not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(AlgorithmReader, Algorithm);
  if not ReadAsn1Expected(AlgorithmReader, Asn1ObjectIdentifier, Identifier) or not DigestOfOid(Identifier, Digest) then
    Exit;
  Result := HashMatches(Digest, Subject.Issuer, NameHash) and HashMatches(Digest, Issuer.PublicKeyBits, KeyHash) and
    ByteRangesEqual(RangeOfContents(Serial), Subject.SerialNumber);
end;

(* SingleResponse ::= SEQUENCE { certID CertID, certStatus CHOICE {
   good [0] IMPLICIT NULL, revoked [1] IMPLICIT RevokedInfo,
   unknown [2] IMPLICIT NULL }, thisUpdate GeneralizedTime,
   nextUpdate [0] EXPLICIT GeneralizedTime OPTIONAL,
   singleExtensions [1] EXPLICIT Extensions OPTIONAL }
   Found is set for the response about Subject; the result is whether
   it is well formed and current. *)
function ReadSingleResponse(constref Element: TAsn1Element; constref Subject, Issuer: TTlsCertificate; Time: Int64;
  out Found: Boolean; out Status: TOcspStatus): Boolean;
var
  Reader, NextReader: TAsn1Reader;
  CertificateId, CertificateStatus, ThisUpdateField, NextField, Inner, Extensions: TAsn1Element;
  ThisUpdate, NextUpdate: Int64;
  HasNext, Present: Boolean;
begin
  Result := False;
  Found := False;
  Status := OcspUnknown;
  if Element.Tag <> Asn1Sequence then
    Exit;
  OpenAsn1Element(Reader, Element);
  if not ReadAsn1Element(Reader, CertificateId) or not ReadAsn1Element(Reader, CertificateStatus) or
     not ReadAsn1Element(Reader, ThisUpdateField) or not ReadAsn1Time(ThisUpdateField, ThisUpdate) then
    Exit;
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 0, NextField, HasNext) then
    Exit;
  NextUpdate := 0;
  if HasNext then
  begin
    OpenAsn1Element(NextReader, NextField);
    if not ReadAsn1Element(NextReader, Inner) or not ReadAsn1Time(Inner, NextUpdate) then
      Exit;
  end;
  if not ReadAsn1Optional(Reader, Asn1ContextSpecific or Asn1Constructed or 1, Extensions, Present) or
     not Asn1ReaderAtEnd(Reader) then
    Exit;
  Result := True;
  if not CertificateIdMatches(CertificateId, Subject, Issuer) then
    Exit;
  Found := True;
  if CertificateStatus.Tag = Asn1ContextSpecific or 0 then
    Status := OcspGood
  else if CertificateStatus.Tag = Asn1ContextSpecific or Asn1Constructed or 1 then
    Status := OcspRevoked
  else if CertificateStatus.Tag = Asn1ContextSpecific or 2 then
    Status := OcspUnknown
  else
    Exit(False);
  { Current? }
  if ThisUpdate > Time + OcspClockSkewSeconds then
    Exit(False);
  if HasNext then
  begin
    if (NextUpdate < ThisUpdate) or (Time > NextUpdate + OcspClockSkewSeconds) then
      Exit(False);
  end
  else if Time - ThisUpdate > OcspMaximumAgeWithoutNextUpdate then
    Exit(False);
end;

function CheckOcspResponse(Response: PByte; ResponseLength: PtrUInt; constref Subject, Issuer: TTlsCertificate;
  Time: Int64; out Status: TOcspStatus): LongInt;
var
  BasicBytes: TTlsByteRange;
  Basic: TBasicResponse;
  Reader: TAsn1Reader;
  Single: TAsn1Element;
  Found, Current: Boolean;
  SingleStatus: TOcspStatus;
begin
  Status := OcspUnknown;
  Result := TlsErrorCertificateStatusInvalid;
  if not ReadBasicResponseBytes(Response, ResponseLength, BasicBytes) or not ReadBasicResponse(BasicBytes, Basic) then
    Exit;
  if ResponderIs(Basic.Responder, Issuer) then
  begin
    if not SignedBy(Basic, Issuer) then
      Exit;
  end
  else if not SignedByDelegate(Basic, Issuer, Time) then
    Exit;
  InitializeAsn1Reader(Reader, Basic.Responses.Data, Basic.Responses.Length);
  while ReadAsn1Element(Reader, Single) do
  begin
    Current := ReadSingleResponse(Single, Subject, Issuer, Time, Found, SingleStatus);
    if not Found then
    begin
      if not Current then
        Exit;
      Continue;
    end;
    if not Current then
      Exit;
    Status := SingleStatus;
    if Status = OcspRevoked then
      Exit(TlsErrorCertificateRevoked);
    Exit(TlsErrorNone);
  end;
end;

end.
