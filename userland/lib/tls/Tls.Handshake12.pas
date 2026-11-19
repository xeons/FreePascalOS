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
  The TLS 1.2 client handshake (RFC 5246 section 7.3), for a server
  that answered the ClientHello with TLS 1.2, ECDHE only:

    ClientHello              -->
                             <--  ServerHello
                                  Certificate
                                  [CertificateStatus]
                                  ServerKeyExchange
                                  [CertificateRequest]
                                  ServerHelloDone
    [Certificate]  (empty, only when requested)
    ClientKeyExchange
    [ChangeCipherSpec]
    Finished                 -->
                             <--  [ChangeCipherSpec]
                                  Finished

  The server must use the extended master secret (RFC 7627) and secure
  renegotiation (RFC 5746, an empty renegotiation_info); it must not
  have been a TLS 1.3 server pushed down (the DOWNGRD sentinel in its
  random, checked by Tls.Handshake). The ServerKeyExchange is signed
  over both randoms and the curve parameters with the server's key,
  which must suit the suite (ECDSA or Ed25519 for the ECDSA suites, RSA
  for the RSA ones). No session ids, tickets or renegotiation.
*)
unit Tls.Handshake12;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.Connections,
  Tls.ServerMessages;

{ Carries on after the ServerHello (already parsed, Hello.Version
  TLS 1.2, not yet in the transcript). ClientRandom is the
  ClientHello's random. }
function RunTls12Handshake(Connection: PTlsConnection; constref Hello: TServerHello; ServerHello: PByte;
  ServerHelloLength: PtrUInt; ClientRandom: PByte): LongInt;

implementation

uses
  Crypto.Bits,
  Crypto.Digests,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CipherSuites,
  Tls.ClientHello,
  Tls.Constants,
  Tls.Errors,
  Tls.HandshakeMessages,
  Tls.KeySchedule12,
  Tls.KeyShares,
  Tls.RecordLayer,
  Tls.RecordProtection,
  Tls.ServerAuthentication,
  Tls.ServerMessages12,
  Tls.Signatures,
  Tls.Transcript;

type
  TTls12State = record
    ClientRandom: array[0..31] of Byte;
    ServerRandom: array[0..31] of Byte;
    Exchange: TServerKeyExchange;
    Share: TTlsKeyShare;
    CertificateRequested: Boolean;
    MasterSecret: array[0..Tls12MasterSecretLength - 1] of Byte;
  end;

{ The key the server signs with must suit the suite. }
function KeySuitsSuite(constref Leaf: TTlsCertificate; constref Suite: TCipherSuiteInfo): Boolean;
begin
  if Suite.Authentication = AuthenticationEcdsa then
    Result := Leaf.PublicKeyKind in [PublicKeyEcP256, PublicKeyEcP384, PublicKeyEcP521, PublicKeyEd25519]
  else
    Result := Leaf.PublicKeyKind in [PublicKeyRsa, PublicKeyRsaPss];
end;

function CheckServerHello(Connection: PTlsConnection; constref Hello: TServerHello): LongInt;
begin
  if not CipherSuiteListContains(Connection^.Options.CipherSuites, Hello.CipherSuite) or
     not FindCipherSuite(Hello.CipherSuite, Connection^.Suite) or not Connection^.Suite.IsTls12 then
    Exit(TlsErrorIllegalParameter);
  if not Hello.HasExtendedMasterSecret or not Hello.HasRenegotiationInfo then
    Exit(TlsErrorHandshakeFailure);
  SetString(Connection^.SelectedProtocol, PChar(Hello.SelectedProtocol.Data), Hello.SelectedProtocol.Length);
  Result := TlsErrorNone;
end;

function ReceiveCertificate(Connection: PTlsConnection): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Entries: TServerCertificates;
begin
  Result := ExpectMessage(Connection, HandshakeCertificate, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := ParseTls12CertificateMessage(Message + 4, MessageLength - 4, Entries);
  if Result <> TlsErrorNone then
    Exit;
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := AcceptServerCertificates(Connection, Entries);
  if (Result = TlsErrorNone) and not KeySuitsSuite(Connection^.ServerCertificates[0]^, Connection^.Suite) then
    Result := TlsErrorIllegalParameter;
end;

function CheckKeyExchangeSignature(Connection: PTlsConnection; var State: TTls12State): LongInt;
var
  Signed: TTlsBuilder;
  Outcome: TSignatureCheck;
begin
  if not SignatureSchemeWasOffered(State.Exchange.Scheme) then
    Exit(TlsErrorIllegalParameter);
  InitializeBuilder(Signed);
  AppendBytes(Signed, @State.ClientRandom[0], 32);
  AppendBytes(Signed, @State.ServerRandom[0], 32);
  AppendBytes(Signed, State.Exchange.Parameters.Data, State.Exchange.Parameters.Length);
  if Signed.Failed then
  begin
    FreeBuilder(Signed);
    Exit(TlsErrorOutOfMemory);
  end;
  Outcome := CheckHandshakeSignature(Connection^.ServerCertificates[0]^, State.Exchange.Scheme, Signed.Data,
    Signed.Length, State.Exchange.Signature.Data, State.Exchange.Signature.Length, True);
  FreeBuilder(Signed);
  if Outcome = SignatureUnsupported then
    Exit(TlsErrorIllegalParameter);
  if Outcome <> SignatureValid then
    Exit(TlsErrorBadCertificateVerify);
  Result := TlsErrorNone;
end;

{ CertificateStatus (when the server takes status_request, and only
  then; it may still leave it out), then ServerKeyExchange. }
function ReceiveKeyExchange(Connection: PTlsConnection; constref Hello: TServerHello; var State: TTls12State): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Staple: TTlsByteRange;
  Alternative: Byte;
begin
  Staple := ByteRange(nil, 0);
  Alternative := 0;
  if Hello.StatusRequestAcknowledged then
    Alternative := HandshakeCertificateStatus;
  Result := ExpectMessage(Connection, HandshakeServerKeyExchange, Alternative, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  if MessageType = HandshakeCertificateStatus then
  begin
    Result := ParseCertificateStatus(Message + 4, MessageLength - 4, Staple);
    if Result <> TlsErrorNone then
      Exit;
    AddToTranscript(Connection^.Transcript, Message, MessageLength);
    { The response lies in the handshake buffer only until the next
      message: check it now. }
    Result := CheckRevocationStatus(Connection, Staple);
    if Result <> TlsErrorNone then
      Exit;
    Result := ExpectMessage(Connection, HandshakeServerKeyExchange, 0, MessageType, Message, MessageLength);
    if Result <> TlsErrorNone then
      Exit;
  end
  else
  begin
    Result := CheckRevocationStatus(Connection, Staple);
    if Result <> TlsErrorNone then
      Exit;
  end;

  Result := ParseServerKeyExchange(Message + 4, MessageLength - 4, State.Exchange);
  if Result <> TlsErrorNone then
    Exit;
  if not GroupWorksWithTls12(State.Exchange.Group) or
     not GroupListContains(Connection^.Options.Groups, State.Exchange.Group) then
    Exit(TlsErrorIllegalParameter);
  Result := CheckKeyExchangeSignature(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  if not MakeKeyShare(State.Exchange.Group, State.Share) then
    Exit(TlsErrorInternal);
  Connection^.Group := State.Exchange.Group;
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
end;

{ The server's key share stays in the handshake buffer until the next
  message, so the shared secret is made after ServerHelloDone from a
  copy. }
function ReceiveServerHelloDone(Connection: PTlsConnection; var State: TTls12State;
  var ServerKey: TTlsBuilder): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
begin
  AppendBytes(ServerKey, State.Exchange.PublicKey.Data, State.Exchange.PublicKey.Length);
  if ServerKey.Failed then
    Exit(TlsErrorOutOfMemory);
  Result := ExpectMessage(Connection, HandshakeServerHelloDone, HandshakeCertificateRequest, MessageType, Message,
    MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  if MessageType = HandshakeCertificateRequest then
  begin
    Result := ParseTls12CertificateRequest(Message + 4, MessageLength - 4);
    if Result <> TlsErrorNone then
      Exit;
    State.CertificateRequested := True;
    AddToTranscript(Connection^.Transcript, Message, MessageLength);
    Result := ExpectMessage(Connection, HandshakeServerHelloDone, 0, MessageType, Message, MessageLength);
    if Result <> TlsErrorNone then
      Exit;
  end;
  Result := ParseServerHelloDone(MessageLength - 4);
  if Result <> TlsErrorNone then
    Exit;
  AddToTranscript(Connection^.Transcript, Message, MessageLength);
  Result := EnsureNoBufferedHandshake(Connection);
end;

function SendClientKeyExchange(Connection: PTlsConnection; var State: TTls12State): LongInt;
var
  Message: TTlsBuilder;
  Body, Point: PtrUInt;
begin
  InitializeBuilder(Message);
  AppendByte(Message, HandshakeClientKeyExchange);
  Body := BeginVector(Message, 3);
  Point := BeginVector(Message, 1);
  AppendBytes(Message, @State.Share.PublicKey[0], State.Share.PublicLength);
  EndVector(Message, Point, 1);
  EndVector(Message, Body, 3);
  if Message.Failed then
    Result := TlsErrorOutOfMemory
  else
    Result := SendHandshakeMessage(Connection, Message.Data, Message.Length);
  FreeBuilder(Message);
end;

{ The pre-master secret, the master secret from the session hash (the
  transcript through ClientKeyExchange), and the keys of both ways. }
function DeriveKeys(Connection: PTlsConnection; var State: TTls12State; constref ServerKey: TTlsBuilder): LongInt;
var
  PreMaster: array[0..MaximumSharedSecretLength - 1] of Byte;
  PreMasterLength: Integer;
  SessionHash: TDigestOutput;
  Keys: TTls12Keys;
begin
  Result := CompleteKeyShare(State.Share, ServerKey.Data, ServerKey.Length, @PreMaster[0], PreMasterLength);
  if Result <> TlsErrorNone then
    Exit;
  Result := SendClientKeyExchange(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  TranscriptHash(Connection^.Transcript, SessionHash);
  DeriveExtendedMasterSecret(Connection^.Suite.Hash, @PreMaster[0], PreMasterLength, @SessionHash[0],
    @State.MasterSecret[0]);
  WipeMemory(@PreMaster[0], SizeOf(PreMaster));
  DeriveTls12Keys(Connection^.Suite, @State.MasterSecret[0], @State.ClientRandom[0], @State.ServerRandom[0], Keys);
  SetTls12RecordProtection(Connection^.PendingReadProtection, Connection^.Suite, @Keys.ServerKey[0],
    @Keys.ServerIv[0], Keys.IvLength);
  { Ours start after our change_cipher_spec. }
  Result := SendChangeCipherSpec(Connection);
  if Result = TlsErrorNone then
    SetTls12RecordProtection(Connection^.WriteProtection, Connection^.Suite, @Keys.ClientKey[0], @Keys.ClientIv[0],
      Keys.IvLength);
  WipeMemory(@Keys, SizeOf(Keys));
end;

function SendFinished(Connection: PTlsConnection; var State: TTls12State): LongInt;
var
  Hash: TDigestOutput;
  Message: array[0..4 + Tls12VerifyDataLength - 1] of Byte;
begin
  TranscriptHash(Connection^.Transcript, Hash);
  Message[0] := HandshakeFinished;
  Message[1] := 0;
  Message[2] := 0;
  Message[3] := Tls12VerifyDataLength;
  ComputeTls12VerifyData(Connection^.Suite.Hash, @State.MasterSecret[0], True, @Hash[0], @Message[4]);
  Result := SendHandshakeMessage(Connection, @Message[0], SizeOf(Message));
end;

function ReceiveFinished(Connection: PTlsConnection; var State: TTls12State): LongInt;
var
  Hash: TDigestOutput;
  Expected: array[0..Tls12VerifyDataLength - 1] of Byte;
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
begin
  TranscriptHash(Connection^.Transcript, Hash);
  ComputeTls12VerifyData(Connection^.Suite.Hash, @State.MasterSecret[0], False, @Hash[0], @Expected[0]);
  Result := ExpectMessage(Connection, HandshakeFinished, 0, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  { It must have come under the new keys, after change_cipher_spec. }
  if not Connection^.ReadProtection.Active then
    Exit(TlsErrorUnexpectedMessage);
  if MessageLength - 4 <> Tls12VerifyDataLength then
    Exit(TlsErrorMalformedMessage);
  if not ConstantTimeEqual(@Expected[0], Message + 4, Tls12VerifyDataLength) then
    Exit(TlsErrorBadFinished);
  Result := EnsureNoBufferedHandshake(Connection);
end;

function RunSteps(Connection: PTlsConnection; constref Hello: TServerHello; var State: TTls12State): LongInt;
var
  ServerKey: TTlsBuilder;
begin
  Result := ReceiveCertificate(Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := ReceiveKeyExchange(Connection, Hello, State);
  if Result <> TlsErrorNone then
    Exit;
  InitializeBuilder(ServerKey);
  try
    Result := ReceiveServerHelloDone(Connection, State, ServerKey);
    if Result <> TlsErrorNone then
      Exit;
    if State.CertificateRequested then
    begin
      Result := SendEmptyCertificate(Connection, nil, 0, False);
      if Result <> TlsErrorNone then
        Exit;
    end;
    Result := DeriveKeys(Connection, State, ServerKey);
  finally
    FreeBuilder(ServerKey);
  end;
  if Result <> TlsErrorNone then
    Exit;
  Result := SendFinished(Connection, State);
  if Result <> TlsErrorNone then
    Exit;
  Result := ReceiveFinished(Connection, State);
end;

function RunTls12Handshake(Connection: PTlsConnection; constref Hello: TServerHello; ServerHello: PByte;
  ServerHelloLength: PtrUInt; ClientRandom: PByte): LongInt;
var
  State: TTls12State;
begin
  Result := CheckServerHello(Connection, Hello);
  if Result <> TlsErrorNone then
    Exit;
  Connection^.Version := VersionTls12;
  Connection^.AllowChangeCipherSpec := False;
  State := Default(TTls12State);
  Move(ClientRandom^, State.ClientRandom[0], 32);
  Move(Hello.Random^, State.ServerRandom[0], 32);
  StartTranscript(Connection^.Transcript, Connection^.Suite.Hash);
  AddToTranscript(Connection^.Transcript, ServerHello, ServerHelloLength);
  Result := RunSteps(Connection, Hello, State);
  WipeKeyShare(State.Share);
  WipeMemory(@State, SizeOf(State));
end;

end.
