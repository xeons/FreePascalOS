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
  The client handshake. TLS 1.3 (RFC 8446 section 2), with (EC)DHE and
  certificates, or resuming with a session ticket (a PSK with (EC)DHE,
  no early data):

    ClientHello              -->
    (+ pre_shared_key)
                             <--  [HelloRetryRequest: once, then a new
                                   ClientHello with its cookie and/or
                                   a share in the group it asks for]
                             <--  ServerHello
                                  {EncryptedExtensions}
                                  {CertificateRequest}   (not resuming)
                                  {Certificate}          (not resuming)
                                  {CertificateVerify}    (not resuming)
                                  {Finished}
    [change_cipher_spec]
    {Certificate}  (empty, only when requested)
    {Finished}               -->

  A server that answers with TLS 1.2 goes on in Tls.Handshake12 - unless
  its random carries the downgrade sentinel (RFC 8446 section 4.1.3),
  which means something in between removed TLS 1.3.

  The key share sent first is for the first group offered (x25519 by
  default); a HelloRetryRequest may ask for another of the offered
  groups. The server's certificate chain and stapled OCSP response are
  checked when its Certificate arrives (Tls.ServerAuthentication); the
  CertificateVerify signature with its key over the transcript so far
  (Tls.Signatures); the server's Finished as an HMAC of the transcript,
  compared in constant time. In QUIC mode (Tls.Quic) the secrets go to
  the QUIC connection instead of the record layer. After the client's Finished both
  directions use the application traffic keys, and the resumption
  master secret is kept for the tickets the server sends (Tls.Client).
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
  Tls.ByteBuffers,
  Tls.CipherSuites,
  Tls.ClientHello,
  Tls.Constants,
  Tls.Errors,
  Tls.Handshake12,
  Tls.HandshakeMessages,
  Tls.HostNames,
  Tls.KeySchedule,
  Tls.KeyShares,
  Tls.Quic,
  Tls.RecordLayer,
  Tls.RecordProtection,
  Tls.ServerAuthentication,
  Tls.ServerMessages,
  Tls.SessionCache,
  Tls.Signatures,
  Tls.Transcript;

type
  THandshakeState = record
    Hello: TClientHelloParameters;
    Share: TTlsKeyShare;
    CookieCopy: TTlsBuilder;
    RetryRequested: Boolean;
    RetrySuite: Word;
    CertificateRequested: Boolean;
    CertificateRequestContext: TTlsBuilder;
    { A ticket to resume with, and whether the last ClientHello
      offered it. }
    HasTicket: Boolean;
    Ticket: TTlsSessionTicket;
    OfferedPsk: Boolean;
  end;

const
  CertificateVerifyContext: PChar = 'TLS 1.3, server CertificateVerify';

{ QUIC mode: a traffic secret to the QUIC connection. }
function HandOverQuicSecret(Connection: PTlsConnection; Level: TTlsQuicLevel; Direction: TTlsQuicDirection;
  constref Secret: TTlsSecret): LongInt;
begin
  Result := Connection^.Options.Quic^.InstallSecret(Connection^.Options.Quic^.Context, Level, Direction,
    Connection^.Suite.Identifier, @Secret[0], DigestSize(Connection^.Suite.Hash));
end;

{ The server's traffic secret of a level: the record keys, or in QUIC
  mode the QUIC connection's, whose CRYPTO frames of that level are read
  from now on. }
function InstallReadSecret(Connection: PTlsConnection; Level: TTlsQuicLevel; constref Secret: TTlsSecret): LongInt;
begin
  if Connection^.Options.Quic = nil then
  begin
    SetRecordProtection(Connection^.ReadProtection, Connection^.Suite, Secret);
    Exit(TlsErrorNone);
  end;
  Connection^.QuicReadLevel := Level;
  Result := HandOverQuicSecret(Connection, Level, QuicDirectionRead, Secret);
end;

{ The client's traffic secret of a level, likewise. QUIC has the
  handshake write secret already (with the read one: it acknowledges
  the server's Handshake packets with it), so only the level changes. }
function InstallWriteSecret(Connection: PTlsConnection; Level: TTlsQuicLevel; constref Secret: TTlsSecret): LongInt;
begin
  if Connection^.Options.Quic = nil then
  begin
    SetRecordProtection(Connection^.WriteProtection, Connection^.Suite, Secret);
    Exit(TlsErrorNone);
  end;
  Connection^.QuicWriteLevel := Level;
  if Level = QuicLevelHandshake then
    Exit(TlsErrorNone);
  Result := HandOverQuicSecret(Connection, Level, QuicDirectionWrite, Secret);
end;

function CurrentMilliseconds(Connection: PTlsConnection): Int64;
begin
  Result := Connection^.Options.VerificationTime * 1000;
end;

{ HMAC(binder key, hash of the transcript and the truncated ClientHello)
  into the ClientHello's zeroed binder. }
procedure FillBinder(Connection: PTlsConnection; var State: THandshakeState; Message: PByte; BindersOffset: PtrUInt);
var
  Schedule: TTlsKeySchedule;
  BinderKey: TTlsSecret;
  Hash, Binder: TDigestOutput;
  HashLength: Integer;
begin
  HashLength := DigestSize(State.Ticket.Hash);
  BeginKeyScheduleWithPsk(Schedule, State.Ticket.Hash, @State.Ticket.Psk[0], HashLength);
  DeriveBinderKey(Schedule, BinderKey);
  PeekTranscriptHash(Connection^.Transcript, State.Ticket.Hash, Message, BindersOffset, Hash);
  ComputeFinishedData(State.Ticket.Hash, @BinderKey[0], @Hash[0], Binder);
  (* binders<33..2^16-1>, each opaque binder<32..255> *)
  Move(Binder[0], Message[BindersOffset + 2 + 1], HashLength);
  WipeKeySchedule(Schedule);
  WipeMemory(@BinderKey[0], SizeOf(BinderKey));
  WipeMemory(@Binder[0], SizeOf(Binder));
end;

function SendClientHello(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  Message: TTlsBuilder;
  Address: array[0..3] of Byte;
  BindersOffset: PtrUInt;
  Age: Int64;
begin
  { No server_name for a numeric address (RFC 6066 section 3). }
  if ParseIpv4Literal(Connection^.Options.ServerName, Address) then
    State.Hello.ServerName := ''
  else
    State.Hello.ServerName := Connection^.Options.ServerName;
  State.Hello.CipherSuites := Connection^.Options.CipherSuites;
  State.Hello.Groups := Connection^.Options.Groups;
  State.Hello.MinimumVersion := Connection^.Options.MinimumVersion;
  State.Hello.MaximumVersion := Connection^.Options.MaximumVersion;
  State.Hello.ApplicationProtocol := Connection^.Options.ApplicationProtocol;
  State.Hello.Cookie := ByteRange(State.CookieCopy.Data, State.CookieCopy.Length);
  State.Hello.AllowResumption := Connection^.Options.SessionCacheKey <> '';
  State.Hello.KeyShareCount := 0;
  if State.Share.PublicLength > 0 then
  begin
    State.Hello.KeyShares[0].Group := State.Share.Group;
    State.Hello.KeyShares[0].Data := @State.Share.PublicKey[0];
    State.Hello.KeyShares[0].Length := State.Share.PublicLength;
    State.Hello.KeyShareCount := 1;
  end;
  State.Hello.PskIdentity := nil;
  State.Hello.Quic := Connection^.Options.Quic <> nil;
  if State.Hello.Quic then
    State.Hello.QuicTransportParameters := Connection^.Options.Quic^.TransportParameters;
  State.OfferedPsk := State.HasTicket;
  if State.OfferedPsk then
  begin
    State.Hello.PskIdentity := State.Ticket.Ticket;
    Age := CurrentMilliseconds(Connection) - State.Ticket.ReceivedAt;
    State.Hello.ObfuscatedTicketAge := LongWord((QWord(Age) + State.Ticket.AgeAdd) and $FFFFFFFF);
    State.Hello.BinderLength := DigestSize(State.Ticket.Hash);
  end;

  InitializeBuilder(Message);
  BuildClientHello(Message, State.Hello, BindersOffset);
  if Message.Failed then
  begin
    FreeBuilder(Message);
    Exit(TlsErrorOutOfMemory);
  end;
  if BindersOffset > 0 then
    FillBinder(Connection, State, Message.Data, BindersOffset);
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
     not FindCipherSuite(Hello.CipherSuite, Suite) or Suite.IsTls12 then
    Exit(TlsErrorIllegalParameter);
  { A group that was offered and has no share yet; asking for the
    share that was sent, or for a group not offered, is illegal. }
  if Hello.HasKeyShare then
  begin
    if (Hello.KeyShareGroup = State.Share.Group) or not GroupIsSupported(Hello.KeyShareGroup) or
       not GroupListContains(Connection^.Options.Groups, Hello.KeyShareGroup) then
      Exit(TlsErrorIllegalParameter);
    WipeKeyShare(State.Share);
    if not MakeKeyShare(Hello.KeyShareGroup, State.Share) then
      Exit(TlsErrorInternal);
  end
  else if not Hello.HasCookie then
    { A retry must change something. }
    Exit(TlsErrorIllegalParameter);
  State.RetrySuite := Hello.CipherSuite;
  ClearBuilder(State.CookieCopy);
  if Hello.HasCookie then
  begin
    AppendBytes(State.CookieCopy, Hello.Cookie.Data, Hello.Cookie.Length);
    if State.CookieCopy.Failed then
      Exit(TlsErrorOutOfMemory);
  end;
  { The ticket can go again only with a suite of its hash. }
  if State.HasTicket and (State.Ticket.Hash <> Suite.Hash) then
    State.HasTicket := False;

  StartTranscript(Connection^.Transcript, Suite.Hash);
  ReplaceWithMessageHash(Connection^.Transcript);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := SendClientHello(Connection, State);
end;

{ The PSK the server took, if it took one. }
function AcceptPreSharedKey(Connection: PTlsConnection; var State: THandshakeState;
  constref Hello: TServerHello): LongInt;
begin
  Result := TlsErrorNone;
  if not Hello.HasPreSharedKey then
  begin
    BeginKeySchedule(Connection^.Schedule, Connection^.Suite.Hash);
    Exit;
  end;
  if not State.OfferedPsk or (Hello.SelectedIdentity <> 0) or (State.Ticket.Hash <> Connection^.Suite.Hash) then
    Exit(TlsErrorIllegalParameter);
  Connection^.Resumed := True;
  BeginKeyScheduleWithPsk(Connection^.Schedule, Connection^.Suite.Hash, @State.Ticket.Psk[0],
    DigestSize(State.Ticket.Hash));
end;

function HandleServerHello(Connection: PTlsConnection; var State: THandshakeState; constref Hello: TServerHello;
  Message: PByte; MessageLength: PtrUInt): LongInt;
var
  SharedSecret: array[0..MaximumSharedSecretLength - 1] of Byte;
  SecretLength: Integer;
  Hash: TDigestOutput;
begin
  if not CipherSuiteListContains(Connection^.Options.CipherSuites, Hello.CipherSuite) or
     not FindCipherSuite(Hello.CipherSuite, Connection^.Suite) or Connection^.Suite.IsTls12 then
    Exit(TlsErrorIllegalParameter);
  if State.RetryRequested and (Hello.CipherSuite <> State.RetrySuite) then
    Exit(TlsErrorIllegalParameter);
  if Hello.KeyShareGroup <> State.Share.Group then
    Exit(TlsErrorIllegalParameter);
  Connection^.Version := VersionTls13;
  Connection^.Group := Hello.KeyShareGroup;

  Result := AcceptPreSharedKey(Connection, State, Hello);
  if Result <> TlsErrorNone then
    Exit;
  StartTranscript(Connection^.Transcript, Connection^.Suite.Hash);
  AddToTranscript(Connection^.Transcript, Message, MessageLength);

  Result := CompleteKeyShare(State.Share, Hello.KeyShare.Data, Hello.KeyShare.Length, @SharedSecret[0], SecretLength);
  WipeKeyShare(State.Share);
  if Result <> TlsErrorNone then
    Exit;
  TranscriptHash(Connection^.Transcript, Hash);
  DeriveHandshakeSecrets(Connection^.Schedule, @SharedSecret[0], SecretLength, @Hash[0]);
  WipeMemory(@SharedSecret[0], SizeOf(SharedSecret));

  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := InstallReadSecret(Connection, QuicLevelHandshake, Connection^.Schedule.ServerHandshakeTraffic);
  if (Result = TlsErrorNone) and (Connection^.Options.Quic <> nil) then
    Result := HandOverQuicSecret(Connection, QuicLevelHandshake, QuicDirectionWrite,
      Connection^.Schedule.ClientHandshakeTraffic);
end;

{ A TLS 1.2 answer: only when it was offered, and never from a TLS 1.3
  server pushed down. }
function CheckTls12Answer(Connection: PTlsConnection; var State: THandshakeState;
  constref Hello: TServerHello): LongInt;
begin
  if Connection^.Options.MinimumVersion > VersionTls12 then
    Exit(TlsErrorProtocolVersion);
  if State.RetryRequested then
    Exit(TlsErrorIllegalParameter);
  if (Connection^.Options.MaximumVersion >= VersionTls13) and
     ((CompareByte(Hello.Random[24], DowngradeToTls12Sentinel[0], 8) = 0) or
      (CompareByte(Hello.Random[24], DowngradeToTls11Sentinel[0], 8) = 0)) then
    Exit(TlsErrorIllegalParameter);
  Result := TlsErrorNone;
end;

{ Waits for the ServerHello, going through one HelloRetryRequest; a
  TLS 1.2 ServerHello hands the rest to Tls.Handshake12 (IsTls12). }
function ReceiveServerHello(Connection: PTlsConnection; var State: THandshakeState; out IsTls12: Boolean): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Hello: TServerHello;
begin
  IsTls12 := False;
  while True do
  begin
    Result := NextHandshakeMessage(Connection, MessageType, Message, MessageLength);
    if Result <> TlsErrorNone then
      Exit;
    if MessageType <> HandshakeServerHello then
      Exit(TlsErrorUnexpectedMessage);
    Result := ParseServerHello(Message + 4, MessageLength - 4, Connection^.Options.ApplicationProtocol, Hello);
    if Result <> TlsErrorNone then
      Exit;
    if Hello.Version = VersionTls12 then
    begin
      Result := CheckTls12Answer(Connection, State, Hello);
      if Result <> TlsErrorNone then
        Exit;
      IsTls12 := True;
      WipeKeyShare(State.Share);
      Exit(RunTls12Handshake(Connection, Hello, Message, MessageLength, @State.Hello.Random[0]));
    end;
    if Connection^.Options.MaximumVersion < VersionTls13 then
      Exit(TlsErrorIllegalParameter);
    { The legacy session id comes back as it was sent (empty in QUIC). }
    if State.Hello.Quic then
    begin
      if Hello.SessionIdEcho.Length <> 0 then
        Exit(TlsErrorIllegalParameter);
    end
    else if (Hello.SessionIdEcho.Length <> 32) or
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

function HandleCertificate(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Entries: TServerCertificates;
  Staple: TTlsByteRange;
begin
  Result := ParseCertificateMessage(Message + 4, MessageLength - 4, Entries, Staple);
  if Result <> TlsErrorNone then
    Exit;
  Result := AcceptServerCertificates(Connection, Entries);
  if Result <> TlsErrorNone then
    Exit;
  Result := CheckRevocationStatus(Connection, Staple);
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

{ Certificate (after an optional CertificateRequest) and
  CertificateVerify: not when resuming. }
function ReceiveServerAuthentication(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Context: TTlsByteRange;
begin
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
end;

function ReceiveServerFlight(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  SelectedProtocol, QuicParameters: TTlsByteRange;
begin
  Result := ExpectMessage(Connection, HandshakeEncryptedExtensions, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := ParseEncryptedExtensions(Message + 4, MessageLength - 4, PChar(Connection^.Options.ApplicationProtocol),
    Connection^.Options.Quic <> nil, SelectedProtocol, QuicParameters);
  if Result <> TlsErrorNone then
    Exit;
  SetString(Connection^.SelectedProtocol, PChar(SelectedProtocol.Data), SelectedProtocol.Length);
  if Connection^.Options.Quic <> nil then
  begin
    { QUIC needs an application protocol (RFC 9001 section 8.1). }
    if Connection^.SelectedProtocol = '' then
      Exit(TlsErrorApplicationProtocolMissing);
    SetLength(Connection^.QuicPeerParameters, QuicParameters.Length);
    if QuicParameters.Length > 0 then
      Move(QuicParameters.Data^, Connection^.QuicPeerParameters[0], QuicParameters.Length);
  end;
  AddToTranscript(Connection^.Transcript, Message, MessageLength);

  if not Connection^.Resumed then
  begin
    Result := ReceiveServerAuthentication(Connection, State);
    if Result <> TlsErrorNone then
      Exit;
  end;

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
  Result := InstallReadSecret(Connection, QuicLevelApplication, Connection^.Schedule.ServerApplicationTraffic);
  if Result <> TlsErrorNone then
    Exit;
  Connection^.AllowChangeCipherSpec := False;

  Result := SendChangeCipherSpec(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := InstallWriteSecret(Connection, QuicLevelHandshake, Connection^.Schedule.ClientHandshakeTraffic);
  if Result <> TlsErrorNone then
    Exit;
  if State.CertificateRequested then
  begin
    Result := SendEmptyCertificate(Connection, State.CertificateRequestContext.Data,
      State.CertificateRequestContext.Length, True);
    if Result <> TlsErrorNone then
      Exit;
  end;
  Result := SendClientFinished(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := InstallWriteSecret(Connection, QuicLevelApplication, Connection^.Schedule.ClientApplicationTraffic);
  if Result <> TlsErrorNone then
    Exit;
  { For the tickets to come: the transcript through the client's
    Finished. }
  if Connection^.Options.SessionCacheKey <> '' then
  begin
    TranscriptHash(Connection^.Transcript, Hash);
    DeriveResumptionMasterSecret(Connection^.Schedule, @Hash[0]);
  end;
end;

{ A ticket for this server, of a suite that may be offered. }
procedure FindTicket(Connection: PTlsConnection; var State: THandshakeState);
begin
  State.HasTicket := False;
  if (Connection^.Options.SessionCacheKey = '') or (Connection^.Options.MaximumVersion < VersionTls13) then
    Exit;
  if not TakeSessionTicket(Connection^.Options.SessionCacheKey, CurrentMilliseconds(Connection), State.Ticket) then
    Exit;
  State.HasTicket := CipherSuiteListContains(Connection^.Options.CipherSuites, State.Ticket.Suite);
end;

function RunHandshake(Connection: PTlsConnection; var State: THandshakeState): LongInt;
var
  IsTls12: Boolean;
begin
  RandomBytes(@State.Hello.Random[0], 32);
  RandomBytes(@State.Hello.SessionId[0], 32);
  if Connection^.Options.MaximumVersion >= VersionTls13 then
  begin
    if (Connection^.Options.Groups.Count = 0) or
       not MakeKeyShare(Connection^.Options.Groups.Groups[0], State.Share) then
      Exit(TlsErrorInvalidArgument);
    FindTicket(Connection, State);
  end;

  Result := SendClientHello(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  Connection^.AllowChangeCipherSpec := True;
  Result := ReceiveServerHello(Connection, State, IsTls12);
  if (Result <> TlsErrorNone) or IsTls12 then
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
  WipeKeyShare(State.Share);
  WipeSessionTicket(State.Ticket);
  { The managed fields are let go before the wipe, which would lose them. }
  State.Hello.ServerName := '';
  State.Hello.ApplicationProtocol := '';
  State.Hello.PskIdentity := nil;
  State.Hello.QuicTransportParameters := nil;
  WipeMemory(@State, SizeOf(State));
  if Result <> TlsErrorNone then
  begin
    { A server that closes during the handshake may have said why. }
    Result := FailConnection(Connection, Result);
    Exit;
  end;
  { The handshake secrets are no longer needed. }
  WipeMemory(@Connection^.Schedule.EarlySecret[0], SizeOf(Connection^.Schedule.EarlySecret));
  WipeMemory(@Connection^.Schedule.HandshakeSecret[0], SizeOf(Connection^.Schedule.HandshakeSecret));
  WipeMemory(@Connection^.Schedule.ClientHandshakeTraffic[0], SizeOf(Connection^.Schedule.ClientHandshakeTraffic));
  WipeMemory(@Connection^.Schedule.ServerHandshakeTraffic[0], SizeOf(Connection^.Schedule.ServerHandshakeTraffic));
  WipeMemory(@Connection^.Schedule.MasterSecret[0], SizeOf(Connection^.Schedule.MasterSecret));
  FreeTranscript(Connection^.Transcript);
  Connection^.State := ConnectionOpen;
end;

end.
