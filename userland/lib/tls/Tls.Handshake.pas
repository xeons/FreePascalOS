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

(*
  The TLS 1.3 client handshake (RFC 8446 section 2, full handshake
  with (EC)DHE and certificates, no PSK and no early data):

    ClientHello              -->
                             <--  [HelloRetryRequest: once, then a new
                                   ClientHello with its cookie]
                             <--  ServerHello
                                  {EncryptedExtensions}
                                  {CertificateRequest}   (optional)
                                  {Certificate}
                                  {CertificateVerify}
                                  {Finished}
    [change_cipher_spec]
    {Certificate}  (empty, only when requested)
    {Finished}               -->

  The server's certificate chain is checked when its Certificate
  arrives (Tls.CertificateChains); the CertificateVerify signature with
  the server's key over the transcript so far (Tls.Signatures); the
  server's Finished as an HMAC of the transcript, compared in constant
  time. After the client's Finished both directions use the
  application traffic keys.
*)
unit Tls.Handshake;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.Connections;

function PerformClientHandshake(Connection: PTlsConnection): LongInt;

implementation

uses
  Crypto.Bits,
  Crypto.Digests,
  Crypto.Random,
  Crypto.X25519,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CertificateChains,
  Tls.CipherSuites,
  Tls.ClientHello,
  Tls.Constants,
  Tls.Errors,
  Tls.HostNames,
  Tls.KeySchedule,
  Tls.RecordLayer,
  Tls.RecordProtection,
  Tls.ServerMessages,
  Tls.Signatures,
  Tls.Transcript;

type
  THandshakeState = record
    Hello: TClientHelloParameters;
    PrivateKey: array[0..31] of Byte;
    CookieCopy: TTlsBuilder;
    RetryRequested: Boolean;
    RetrySuite: Word;
    CertificateRequested: Boolean;
    CertificateRequestContext: TTlsBuilder;
  end;

const
  CertificateVerifyContext: PChar = 'TLS 1.3, server CertificateVerify';

function SendHandshakeMessage(Connection: PTlsConnection; Message: PByte; Length: PtrUInt): LongInt;
begin
  AddToTranscript(Connection^.Transcript, Message, Length);
  Result := SendRecords(Connection, ContentHandshake, Message, Length);
end;

function SendClientHello(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  Message: TTlsBuilder;
  Address: array[0..3] of Byte;
begin
  { No server_name for a numeric address (RFC 6066 section 3). }
  if ParseIpv4Literal(Connection^.Options.ServerName, Address) then
    State.Hello.ServerName := ''
  else
    State.Hello.ServerName := Connection^.Options.ServerName;
  State.Hello.CipherSuites := Connection^.Options.CipherSuites;
  State.Hello.ApplicationProtocol := Connection^.Options.ApplicationProtocol;
  State.Hello.Cookie := ByteRange(State.CookieCopy.Data, State.CookieCopy.Length);
  InitializeBuilder(Message);
  BuildClientHello(Message, State.Hello);
  if Message.Failed then
  begin
    FreeBuilder(Message);
    Exit(TlsErrorOutOfMemory);
  end;
  Result := SendHandshakeMessage(Connection, Message.Data, Message.Length);
  FreeBuilder(Message);
end;

{ Checks a HelloRetryRequest and sends the second ClientHello. }
function HandleRetryRequest(Connection: PTlsConnection; var State: THandshakeState; constref Hello: TServerHello;
  Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Suite: TCipherSuiteInfo;
begin
  if State.RetryRequested then
    Exit(TlsErrorUnexpectedMessage);
  State.RetryRequested := True;
  if not CipherSuiteListContains(Connection^.Options.CipherSuites, Hello.CipherSuite) or
     not FindCipherSuite(Hello.CipherSuite, Suite) then
    Exit(TlsErrorIllegalParameter);
  { Only x25519 is offered, and its share was sent: asking for it again
    is illegal, asking for another group cannot be met. }
  if Hello.HasKeyShare then
  begin
    if Hello.KeyShareGroup = GroupX25519 then
      Exit(TlsErrorIllegalParameter);
    Exit(TlsErrorHandshakeFailure);
  end;
  { A retry must change something: here only the cookie can. }
  if not Hello.HasCookie then
    Exit(TlsErrorIllegalParameter);
  State.RetrySuite := Hello.CipherSuite;
  ClearBuilder(State.CookieCopy);
  AppendBytes(State.CookieCopy, Hello.Cookie.Data, Hello.Cookie.Length);
  if State.CookieCopy.Failed then
    Exit(TlsErrorOutOfMemory);

  StartTranscript(Connection^.Transcript, Suite.Hash);
  ReplaceWithMessageHash(Connection^.Transcript);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := SendClientHello(Connection, State);
end;

function HandleServerHello(Connection: PTlsConnection; var State: THandshakeState; constref Hello: TServerHello;
  Message: PByte; MessageLength: PtrUInt): LongInt;
var
  SharedSecret: array[0..31] of Byte;
  Hash: TDigestOutput;
begin
  if not CipherSuiteListContains(Connection^.Options.CipherSuites, Hello.CipherSuite) or
     not FindCipherSuite(Hello.CipherSuite, Connection^.Suite) then
    Exit(TlsErrorIllegalParameter);
  if State.RetryRequested and (Hello.CipherSuite <> State.RetrySuite) then
    Exit(TlsErrorIllegalParameter);
  if (Hello.KeyShareGroup <> GroupX25519) or (Hello.KeyShare.Length <> 32) then
    Exit(TlsErrorIllegalParameter);

  StartTranscript(Connection^.Transcript, Connection^.Suite.Hash);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);

  if not X25519SharedSecret(@State.PrivateKey[0], Hello.KeyShare.Data, @SharedSecret[0]) then
    Exit(TlsErrorIllegalParameter);
  BeginKeySchedule(Connection^.Schedule, Connection^.Suite.Hash);
  TranscriptHash(Connection^.Transcript, Hash);
  DeriveHandshakeSecrets(Connection^.Schedule, @SharedSecret[0], 32, @Hash[0]);
  WipeMemory(@SharedSecret[0], SizeOf(SharedSecret));
  WipeMemory(@State.PrivateKey[0], SizeOf(State.PrivateKey));

  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  SetRecordProtection(Connection^.ReadProtection, Connection^.Suite, Connection^.Schedule.ServerHandshakeTraffic);
end;

{ Waits for the ServerHello, going through one HelloRetryRequest. }
function ReceiveServerHello(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Hello: TServerHello;
begin
  while True do
  begin
    Result := NextHandshakeMessage(Connection, MessageType, Message, MessageLength);
    if Result <> TlsErrorNone then
      Exit;
    if MessageType <> HandshakeServerHello then
      Exit(TlsErrorUnexpectedMessage);
    Result := ParseServerHello(Message + 4, MessageLength - 4, Hello);
    if Result <> TlsErrorNone then
      Exit;
    { The legacy session id comes back as it was sent. }
    if (Hello.SessionIdEcho.Length <> 32) or
       (CompareByte(Hello.SessionIdEcho.Data^, State.Hello.SessionId[0], 32) <> 0) then
      Exit(TlsErrorIllegalParameter);
    if Hello.IsRetryRequest then
    begin
      Result := HandleRetryRequest(Connection, State, Hello, Message, MessageLength);
      if Result <> TlsErrorNone then
        Exit;
      Continue;
    end;
    Exit(HandleServerHello(Connection, State, Hello, Message, MessageLength));
  end;
end;

{ The next message, which must be of type Expected (or, when
  Alternative is not 0, of that type). }
function ExpectMessage(Connection: PTlsConnection; Expected, Alternative: Byte; out MessageType: Byte;
  out Message: PByte; out MessageLength: PtrUInt): LongInt;
begin
  Result := NextHandshakeMessage(Connection, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  if (MessageType <> Expected) and ((Alternative = 0) or (MessageType <> Alternative)) then
    Result := TlsErrorUnexpectedMessage;
end;

procedure DescribeCertificate(Connection: PTlsConnection; Certificate: PTlsCertificate; UseIssuer: Boolean);
begin
  if Certificate = nil then
    Exit;
  if UseIssuer then
    SetErrorDetail(Connection, 'issuer: ' + CommonNameText(Certificate^.IssuerCommonName))
  else
    SetErrorDetail(Connection, 'certificate: ' + CommonNameText(Certificate^.SubjectCommonName));
end;

function CheckServerCertificates(Connection: PTlsConnection): LongInt;
var
  Check: TChainCheck;
  Outcome: TChainResult;
begin
  Check := Default(TChainCheck);
  Check.Presented := @Connection^.ServerCertificates[0];
  Check.PresentedCount := Length(Connection^.ServerCertificates);
  Check.Anchors := Connection^.Options.TrustStore;
  Check.Time := Connection^.Options.VerificationTime;
  Check.HostName := Connection^.Options.ServerName;
  Outcome := VerifyCertificateChain(Check);
  if Outcome.Error = TlsErrorNone then
    Exit(TlsErrorNone);
  if Outcome.Error = TlsErrorCertificateNameMismatch then
  begin
    SetErrorDetail(Connection, 'host: ' + Connection^.Options.ServerName);
  end
  else
    DescribeCertificate(Connection, Outcome.Culprit, Outcome.Error = TlsErrorCertificateUnknownIssuer);
  if not Connection^.Options.VerifyCertificates then
  begin
    Connection^.IgnoredCertificateError := Outcome.Error;
    Exit(TlsErrorNone);
  end;
  Result := Outcome.Error;
end;

function HandleCertificate(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Entries: TServerCertificates;
  Index: Integer;
  Certificate: PTlsCertificate;
begin
  Result := ParseCertificateMessage(Message + 4, MessageLength - 4, Entries);
  if Result <> TlsErrorNone then
    Exit;
  for Index := 0 to Entries.Count - 1 do
  begin
    Result := ParseCertificate(Entries.Entries[Index].Data, Entries.Entries[Index].Length, Certificate);
    if Result <> TlsErrorNone then
      Exit;
    Insert(Certificate, Connection^.ServerCertificates, Length(Connection^.ServerCertificates));
  end;
  if Connection^.Options.VerifyCertificates and (Connection^.Options.TrustStore = nil) then
    Exit(TlsErrorNoTrustStore);
  Result := CheckServerCertificates(Connection);
end;

function HandleCertificateVerify(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Scheme: Word;
  Signature: TTlsByteRange;
  Hash: TDigestOutput;
  HashLength: Integer;
  Content: array[0..64 + 33 + 1 + MaximumDigestSize - 1] of Byte;
  Position: Integer;
  Outcome: TSignatureCheck;
begin
  Result := ParseCertificateVerify(Message + 4, MessageLength - 4, Scheme, Signature);
  if Result <> TlsErrorNone then
    Exit;
  { Only what was offered, and never PKCS #1 v1.5 here. }
  if not SignatureSchemeWasOffered(Scheme) or (Scheme = SchemeRsaPkcs1Sha256) or
     (Scheme = SchemeRsaPkcs1Sha384) or (Scheme = SchemeRsaPkcs1Sha512) then
    Exit(TlsErrorIllegalParameter);
  { 64 spaces, the context string, a zero byte, the transcript hash. }
  TranscriptHash(Connection^.Transcript, Hash);
  HashLength := DigestSize(Connection^.Suite.Hash);
  FillChar(Content[0], 64, $20);
  Position := 64;
  Move(CertificateVerifyContext^, Content[Position], 33);
  Position := Position + 33;
  Content[Position] := 0;
  Inc(Position);
  Move(Hash[0], Content[Position], HashLength);
  Position := Position + HashLength;
  Outcome := CheckHandshakeSignature(Connection^.ServerCertificates[0]^, Scheme, @Content[0], Position,
    Signature.Data, Signature.Length);
  if Outcome = SignatureUnsupported then
    Exit(TlsErrorIllegalParameter);
  if Outcome <> SignatureValid then
    Exit(TlsErrorBadCertificateVerify);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := TlsErrorNone;
end;

function HandleServerFinished(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Hash: TDigestOutput;
  Expected: TDigestOutput;
  HashLength: Integer;
begin
  HashLength := DigestSize(Connection^.Suite.Hash);
  if MessageLength - 4 <> PtrUInt(HashLength) then
    Exit(TlsErrorMalformedMessage);
  TranscriptHash(Connection^.Transcript, Hash);
  ComputeFinishedData(Connection^.Suite.Hash, @Connection^.Schedule.ServerHandshakeTraffic[0], @Hash[0], Expected);
  if not ConstantTimeEqual(@Expected[0], Message + 4, PtrUInt(HashLength)) then
    Exit(TlsErrorBadFinished);
  WipeMemory(@Expected[0], SizeOf(Expected));
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := TlsErrorNone;
end;

{ The answer to a CertificateRequest: a Certificate with no entries. }
function SendEmptyCertificate(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  Message: TTlsBuilder;
  Body, Context, List: PtrUInt;
begin
  InitializeBuilder(Message);
  AppendByte(Message, HandshakeCertificate);
  Body := BeginVector(Message, 3);
  Context := BeginVector(Message, 1);
  AppendBytes(Message, State.CertificateRequestContext.Data, State.CertificateRequestContext.Length);
  EndVector(Message, Context, 1);
  List := BeginVector(Message, 3);
  EndVector(Message, List, 3);
  EndVector(Message, Body, 3);
  if Message.Failed then
    Result := TlsErrorOutOfMemory
  else
    Result := SendHandshakeMessage(Connection, Message.Data, Message.Length);
  FreeBuilder(Message);
end;

function SendClientFinished(Connection: PTlsConnection): LongInt;
var
  Hash: TDigestOutput;
  VerifyData: TDigestOutput;
  Message: array[0..4 + MaximumDigestSize - 1] of Byte;
  HashLength: Integer;
begin
  HashLength := DigestSize(Connection^.Suite.Hash);
  TranscriptHash(Connection^.Transcript, Hash);
  ComputeFinishedData(Connection^.Suite.Hash, @Connection^.Schedule.ClientHandshakeTraffic[0], @Hash[0], VerifyData);
  Message[0] := HandshakeFinished;
  Message[1] := 0;
  Message[2] := 0;
  Message[3] := Byte(HashLength);
  Move(VerifyData[0], Message[4], HashLength);
  Result := SendHandshakeMessage(Connection, @Message[0], 4 + HashLength);
  WipeMemory(@VerifyData[0], SizeOf(VerifyData));
end;

function ReceiveServerFlight(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  SelectedProtocol: TTlsByteRange;
  Context: TTlsByteRange;
begin
  Result := ExpectMessage(Connection, HandshakeEncryptedExtensions, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := ParseEncryptedExtensions(Message + 4, MessageLength - 4, PChar(Connection^.Options.ApplicationProtocol),
    SelectedProtocol);
  if Result <> TlsErrorNone then
    Exit;
  SetString(Connection^.SelectedProtocol, PChar(SelectedProtocol.Data), SelectedProtocol.Length);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);

  Result := ExpectMessage(Connection, HandshakeCertificate, HandshakeCertificateRequest, MessageType, Message,
    MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  if MessageType = HandshakeCertificateRequest then
  begin
    Result := ParseCertificateRequest(Message + 4, MessageLength - 4, Context);
    if Result <> TlsErrorNone then
      Exit;
    State.CertificateRequested := True;
    AppendBytes(State.CertificateRequestContext, Context.Data, Context.Length);
    AddToTranscript(Connection^.Transcript, Message, MessageLength);
    Result := ExpectMessage(Connection, HandshakeCertificate, 0, MessageType, Message, MessageLength);
    if Result <> TlsErrorNone then
      Exit;
  end;
  Result := HandleCertificate(Connection, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  AddToTranscript(Connection^.Transcript, Message, MessageLength);

  Result := ExpectMessage(Connection, HandshakeCertificateVerify, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := HandleCertificateVerify(Connection, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;

  Result := ExpectMessage(Connection, HandshakeFinished, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := HandleServerFinished(Connection, Message, MessageLength);
end;

function FinishHandshake(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  Hash: TDigestOutput;
begin
  { The application secrets come from the transcript up to the server's
    Finished. }
  TranscriptHash(Connection^.Transcript, Hash);
  DeriveApplicationSecrets(Connection^.Schedule, @Hash[0]);
  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  SetRecordProtection(Connection^.ReadProtection, Connection^.Suite, Connection^.Schedule.ServerApplicationTraffic);
  Connection^.AllowChangeCipherSpec := False;

  Result := SendChangeCipherSpec(Connection);
  if Result <> TlsErrorNone then
    Exit;
  SetRecordProtection(Connection^.WriteProtection, Connection^.Suite, Connection^.Schedule.ClientHandshakeTraffic);
  if State.CertificateRequested then
  begin
    Result := SendEmptyCertificate(Connection, State);
    if Result <> TlsErrorNone then
      Exit;
  end;
  Result := SendClientFinished(Connection);
  if Result <> TlsErrorNone then
    Exit;
  SetRecordProtection(Connection^.WriteProtection, Connection^.Suite,
    Connection^.Schedule.ClientApplicationTraffic);
end;

function RunHandshake(Connection: PTlsConnection; var State: THandshakeState): LongInt;
begin
  RandomBytes(@State.Hello.Random[0], 32);
  RandomBytes(@State.Hello.SessionId[0], 32);
  RandomBytes(@State.PrivateKey[0], 32);
  X25519PublicKey(@State.PrivateKey[0], @State.Hello.KeyShare[0]);

  Result := SendClientHello(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  Connection^.AllowChangeCipherSpec := True;
  Result := ReceiveServerHello(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  Result := ReceiveServerFlight(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  Result := FinishHandshake(Connection, State);
end;

function PerformClientHandshake(Connection: PTlsConnection): LongInt;
var
  State: THandshakeState;
begin
  if Connection^.State = ConnectionOpen then
    Exit(TlsErrorNone);
  if Connection^.State <> ConnectionNew then
  begin
    if Connection^.State = ConnectionFailed then
      Exit(Connection^.Error);
    Exit(TlsErrorClosed);
  end;
  Connection^.State := ConnectionHandshaking;
  State := Default(THandshakeState);
  InitializeBuilder(State.CookieCopy);
  InitializeBuilder(State.CertificateRequestContext);
  Result := RunHandshake(Connection, State);
  FreeBuilder(State.CookieCopy);
  FreeBuilder(State.CertificateRequestContext);
  { The strings are let go before the wipe, which would lose them. }
  State.Hello.ServerName := '';
  State.Hello.ApplicationProtocol := '';
  WipeMemory(@State, SizeOf(State));
  if Result <> TlsErrorNone then
  begin
    { A server that closes during the handshake may have said why. }
    Result := FailConnection(Connection, Result);
    Exit;
  end;
  { The handshake secrets are no longer needed. }
  WipeMemory(@Connection^.Schedule.HandshakeSecret[0], SizeOf(Connection^.Schedule.HandshakeSecret));
  WipeMemory(@Connection^.Schedule.ClientHandshakeTraffic[0], SizeOf(Connection^.Schedule.ClientHandshakeTraffic));
  WipeMemory(@Connection^.Schedule.ServerHandshakeTraffic[0], SizeOf(Connection^.Schedule.ServerHandshakeTraffic));
  WipeMemory(@Connection^.Schedule.MasterSecret[0], SizeOf(Connection^.Schedule.MasterSecret));
  FreeTranscript(Connection^.Transcript);
  Connection^.State := ConnectionOpen;
end;

end.
