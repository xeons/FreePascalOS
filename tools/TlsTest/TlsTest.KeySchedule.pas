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
  The TLS 1.3 handshake of RFC 8448 section 3 ("Simple 1-RTT
  Handshake") step by step through the library's own units: the X25519
  shared secret, the transcript hash, every secret of the key schedule,
  the traffic keys, opening the server's encrypted flight, the messages
  in it, its CertificateVerify signature, both Finished messages, and
  the protected records that follow (session ticket, application data,
  alerts), byte for byte.
}
unit TlsTest.KeySchedule;

{$mode objfpc}
{$H+}

interface

procedure TestRfc8448Handshake;

implementation

uses
  TestChecks,
  Crypto.Digests,
  Crypto.Rsa,
  Crypto.X25519,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CipherSuites,
  Tls.Constants,
  Tls.Errors,
  Tls.KeySchedule,
  Tls.RecordProtection,
  Tls.ServerMessages,
  Tls.Signatures,
  Tls.Transcript;

{$i TlsTest.Rfc8448.inc}

procedure CheckSecret(constref Secret: TTlsSecret; const ExpectedHex: string; const Name: string);
begin
  CheckBytes(@Secret[0], 32, ExpectedHex, Name);
end;

function Concatenate(const First, Second: TByteArray): TByteArray;
begin
  Result := nil;
  SetLength(Result, Length(First) + Length(Second));
  if Length(First) > 0 then
    Move(First[0], Result[0], Length(First));
  if Length(Second) > 0 then
    Move(Second[0], Result[Length(First)], Length(Second));
end;

{ Opens a protected record and checks its inner plaintext. }
procedure CheckOpenRecord(var Protection: TRecordProtection; const RecordHex: string; const ExpectedHex: string;
  ExpectedType: Byte; const Name: string);
var
  RecordBytes: TByteArray;
  PlainLength: PtrUInt;
  Opened: Boolean;
begin
  RecordBytes := HexToBytes(RecordHex);
  Opened := OpenRecord(Protection, @RecordBytes[0], @RecordBytes[5], Length(RecordBytes) - 5, PlainLength);
  Check(Opened, Name + ': opens');
  if not Opened then
    Exit;
  Check(RecordBytes[5 + PlainLength - 1] = ExpectedType, Name + ': content type');
  CheckBytes(@RecordBytes[5], PlainLength - 1, ExpectedHex, Name + ': contents');
end;

{ Seals Contents with the content type, as the record layer does, and
  compares the record with the RFC's. }
procedure CheckSealRecord(var Protection: TRecordProtection; const ContentsHex: string; ContentType: Byte;
  const ExpectedRecordHex: string; const Name: string);
var
  Contents, Output: TByteArray;
  InnerLength: Integer;
begin
  Contents := HexToBytes(ContentsHex);
  InnerLength := Length(Contents) + 1;
  SetLength(Output, 5 + InnerLength + AeadTagLength);
  Output[0] := ContentApplicationData;
  Output[1] := 3;
  Output[2] := 3;
  Output[3] := Byte((InnerLength + AeadTagLength) shr 8);
  Output[4] := Byte(InnerLength + AeadTagLength);
  if Length(Contents) > 0 then
    Move(Contents[0], Output[5], Length(Contents));
  Output[5 + Length(Contents)] := ContentType;
  Check(SealRecord(Protection, @Output[0], @Output[5], InnerLength, @Output[5]), Name + ': seals');
  CheckBytes(@Output[0], Length(Output), ExpectedRecordHex, Name + ': record');
end;

procedure TestCertificateVerify(var Transcript: TTlsTranscript);
var
  CertificateBody, VerifyBody: TByteArray;
  Entries: TServerCertificates;
  Certificate: PTlsCertificate;
  Scheme: Word;
  Signature: TTlsByteRange;
  Hash, SignedDigest: TDigestOutput;
  Content: TByteArray;
  ContextText: string;
  Key: TRsaPublicKey;
  Index: Integer;
begin
  CertificateBody := HexToBytes(CertificateMessage);
  Check(ParseCertificateMessage(@CertificateBody[4], Length(CertificateBody) - 4, Entries) = TlsErrorNone,
    'RFC 8448: Certificate message parses');
  Check(Entries.Count = 1, 'RFC 8448: one certificate');
  Check(ParseCertificate(Entries.Entries[0].Data, Entries.Entries[0].Length, Certificate) = TlsErrorNone,
    'RFC 8448: the server certificate parses');
  if Certificate = nil then
    Exit;
  Check(Certificate^.PublicKeyKind = PublicKeyRsa, 'RFC 8448: RSA key');
  Check(Certificate^.SignatureAlgorithm = SignatureRsaPkcs1Sha256, 'RFC 8448: signed with SHA-256 RSA');

  TranscriptHash(Transcript, Hash);
  VerifyBody := HexToBytes(CertificateVerifyMessage);
  Check(ParseCertificateVerify(@VerifyBody[4], Length(VerifyBody) - 4, Scheme, Signature) = TlsErrorNone,
    'RFC 8448: CertificateVerify parses');
  Check(Scheme = SchemeRsaPssRsaeSha256, 'RFC 8448: rsa_pss_rsae_sha256');

  { 64 spaces, the context string, a zero, the transcript hash. }
  ContextText := 'TLS 1.3, server CertificateVerify';
  SetLength(Content, 64 + Length(ContextText) + 1 + 32);
  for Index := 0 to 63 do
    Content[Index] := $20;
  Move(ContextText[1], Content[64], Length(ContextText));
  Content[64 + Length(ContextText)] := 0;
  Move(Hash[0], Content[64 + Length(ContextText) + 1], 32);

  { The RFC's key is 1024 bits: below what the library accepts for TLS,
    so it is checked with Crypto.Rsa directly. }
  Check(CheckHandshakeSignature(Certificate^, Scheme, @Content[0], Length(Content), Signature.Data,
    Signature.Length) = SignatureUnsupported, 'RFC 8448: a 1024-bit key is refused for TLS');
  Check(PrepareRsaPublicKey(Key, Certificate^.RsaModulus.Data, Certificate^.RsaModulus.Length,
    Certificate^.RsaExponent.Data, Certificate^.RsaExponent.Length), 'RFC 8448: RSA key prepared');
  ComputeDigest(DigestSha256, @Content[0], Length(Content), SignedDigest);
  Check(VerifyRsaPssSignature(Key, DigestSha256, @SignedDigest[0], 32, Signature.Data, Signature.Length),
    'RFC 8448: CertificateVerify signature (RSA-PSS SHA-256)');
  SignedDigest[0] := SignedDigest[0] xor 1;
  Check(not VerifyRsaPssSignature(Key, DigestSha256, @SignedDigest[0], 32, Signature.Data, Signature.Length),
    'RFC 8448: CertificateVerify over another transcript refused');
  FreeCertificate(Certificate);
end;

procedure TestRfc8448Handshake;
var
  Suite: TCipherSuiteInfo;
  PrivateKey, ServerKey, ClientHello, ServerHello: TByteArray;
  EncryptedExtensions, CertificateBytes, CertificateVerify, ServerFinished, Flight: TByteArray;
  Shared: array[0..31] of Byte;
  Transcript: TTlsTranscript;
  Hash: TDigestOutput;
  Schedule: TTlsKeySchedule;
  ServerRead, ClientWrite: TRecordProtection;
  VerifyData: TDigestOutput;
  Selected: TTlsByteRange;
  ClientFinished: TByteArray;
begin
  Check(FindCipherSuite(CipherSuiteAes128GcmSha256, Suite), 'RFC 8448: TLS_AES_128_GCM_SHA256');

  PrivateKey := HexToBytes(ClientPrivateKey);
  ServerKey := HexToBytes(ServerPublicKey);
  Check(X25519SharedSecret(@PrivateKey[0], @ServerKey[0], @Shared[0]), 'RFC 8448: X25519');
  CheckBytes(@Shared[0], 32, SharedSecret, 'RFC 8448: shared secret');

  ClientHello := HexToBytes(ClientHelloMessage);
  ServerHello := HexToBytes(ServerHelloMessage);
  InitializeTranscript(Transcript);
  AddToTranscript(Transcript, @ClientHello[0], Length(ClientHello));
  StartTranscript(Transcript, Suite.Hash);
  AddToTranscript(Transcript, @ServerHello[0], Length(ServerHello));
  TranscriptHash(Transcript, Hash);
  CheckBytes(@Hash[0], 32, HelloHash, 'RFC 8448: transcript hash of ClientHello..ServerHello');

  BeginKeySchedule(Schedule, Suite.Hash);
  DeriveHandshakeSecrets(Schedule, @Shared[0], 32, @Hash[0]);
  CheckSecret(Schedule.HandshakeSecret, HandshakeSecret, 'RFC 8448: handshake secret');
  CheckSecret(Schedule.ClientHandshakeTraffic, ClientHandshakeTraffic, 'RFC 8448: client handshake traffic secret');
  CheckSecret(Schedule.ServerHandshakeTraffic, ServerHandshakeTraffic, 'RFC 8448: server handshake traffic secret');

  SetRecordProtection(ServerRead, Suite, Schedule.ServerHandshakeTraffic);
  CheckBytes(@ServerRead.Key[0], 16, ServerHandshakeKey, 'RFC 8448: server handshake key');
  CheckBytes(@ServerRead.Iv[0], 12, ServerHandshakeIv, 'RFC 8448: server handshake IV');

  EncryptedExtensions := HexToBytes(EncryptedExtensionsMessage);
  CertificateBytes := HexToBytes(CertificateMessage);
  CertificateVerify := HexToBytes(CertificateVerifyMessage);
  ServerFinished := HexToBytes(ServerFinishedMessage);
  Flight := Concatenate(Concatenate(EncryptedExtensions, CertificateBytes), Concatenate(CertificateVerify,
    ServerFinished));
  CheckOpenRecord(ServerRead, ServerHandshakeRecord, BytesToHex(@Flight[0], Length(Flight)), ContentHandshake,
    'RFC 8448: server''s encrypted flight');

  { The RFC's client offered record_size_limit, which this one does
    not: the server's answer to it must be refused. }
  Check(ParseEncryptedExtensions(@EncryptedExtensions[4], Length(EncryptedExtensions) - 4, nil, Selected) =
    TlsErrorUnsupportedExtension, 'RFC 8448: EncryptedExtensions with an extension not offered refused');

  AddToTranscript(Transcript, @EncryptedExtensions[0], Length(EncryptedExtensions));
  AddToTranscript(Transcript, @CertificateBytes[0], Length(CertificateBytes));
  TestCertificateVerify(Transcript);
  AddToTranscript(Transcript, @CertificateVerify[0], Length(CertificateVerify));

  TranscriptHash(Transcript, Hash);
  ComputeFinishedData(Suite.Hash, @Schedule.ServerHandshakeTraffic[0], @Hash[0], VerifyData);
  CheckBytes(@VerifyData[0], 32, ServerFinishedData, 'RFC 8448: server Finished verify data');
  AddToTranscript(Transcript, @ServerFinished[0], Length(ServerFinished));

  TranscriptHash(Transcript, Hash);
  DeriveApplicationSecrets(Schedule, @Hash[0]);
  CheckSecret(Schedule.MasterSecret, MasterSecret, 'RFC 8448: master secret');
  CheckSecret(Schedule.ClientApplicationTraffic, ClientApplicationTraffic,
    'RFC 8448: client application traffic secret');
  CheckSecret(Schedule.ServerApplicationTraffic, ServerApplicationTraffic,
    'RFC 8448: server application traffic secret');

  { The client's Finished, over the transcript through the server's. }
  ComputeFinishedData(Suite.Hash, @Schedule.ClientHandshakeTraffic[0], @Hash[0], VerifyData);
  CheckBytes(@VerifyData[0], 32, ClientFinishedData, 'RFC 8448: client Finished verify data');
  SetRecordProtection(ClientWrite, Suite, Schedule.ClientHandshakeTraffic);
  ClientFinished := HexToBytes(ClientFinishedMessage);
  CheckSealRecord(ClientWrite, BytesToHex(@ClientFinished[0], Length(ClientFinished)), ContentHandshake,
    ClientFinishedRecord, 'RFC 8448: client Finished record');

  { After the handshake: the server's ticket and data, the client's
    data, the alerts. }
  SetRecordProtection(ServerRead, Suite, Schedule.ServerApplicationTraffic);
  CheckOpenRecord(ServerRead, NewSessionTicketRecord, NewSessionTicketMessage, ContentHandshake,
    'RFC 8448: NewSessionTicket record');
  ClientFinished := HexToBytes(NewSessionTicketMessage);
  Check(ParseNewSessionTicket(@ClientFinished[4], Length(ClientFinished) - 4) = TlsErrorNone,
    'RFC 8448: NewSessionTicket parses');
  SetRecordProtection(ClientWrite, Suite, Schedule.ClientApplicationTraffic);
  CheckSealRecord(ClientWrite, ClientApplicationData, ContentApplicationData, ClientApplicationRecord,
    'RFC 8448: client application data record');
  CheckOpenRecord(ServerRead, ServerApplicationRecord, ServerApplicationData, ContentApplicationData,
    'RFC 8448: server application data record');
  CheckSealRecord(ClientWrite, '0100', ContentAlert, ClientAlertRecord, 'RFC 8448: client close_notify record');
  CheckOpenRecord(ServerRead, ServerAlertRecord, '0100', ContentAlert, 'RFC 8448: server close_notify record');

  { A record changed in transit, and one replayed (its sequence number
    is gone), must not open. }
  SetRecordProtection(ServerRead, Suite, Schedule.ServerApplicationTraffic);
  Flight := HexToBytes(NewSessionTicketRecord);
  Flight[20] := Flight[20] xor 1;
  Check(not OpenRecord(ServerRead, @Flight[0], @Flight[5], Length(Flight) - 5, Selected.Length),
    'RFC 8448: a changed record is refused');
  SetRecordProtection(ServerRead, Suite, Schedule.ServerApplicationTraffic);
  Flight := HexToBytes(NewSessionTicketRecord);
  Check(OpenRecord(ServerRead, @Flight[0], @Flight[5], Length(Flight) - 5, Selected.Length),
    'RFC 8448: the ticket record opens at sequence 0');
  Flight := HexToBytes(NewSessionTicketRecord);
  Check(not OpenRecord(ServerRead, @Flight[0], @Flight[5], Length(Flight) - 5, Selected.Length),
    'RFC 8448: the same record replayed is refused');

  FreeTranscript(Transcript);
  WipeKeySchedule(Schedule);
end;

end.
