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
  A TLS client connection (TLS 1.3, or TLS 1.2 with a server that has
  nothing newer) over any transport:

    CreateTlsClient(Transport, Options, Connection);
    if TlsHandshake(Connection) <> TlsErrorNone then ... TlsErrorDescription
    TlsWrite(Connection, Request, Length);
    Count := TlsRead(Connection, @Buffer, SizeOf(Buffer));   (0: closed)
    TlsClose(Connection);
    FreeTlsClient(Connection);

  Reading handles what the server sends after the handshake: session
  tickets go into the session cache (Tls.SessionCache) when the
  connection has a cache key and its certificate was verified, a
  KeyUpdate moves the read keys on and, when the server asks, the write
  keys too (RFC 8446 section 4.6.3). A TLS 1.2 server's HelloRequest is
  answered with a no_renegotiation warning. The server's close_notify ends the stream (TlsRead
  returns 0); so does the transport ending without one, which
  TlsClosedCleanly tells apart. Tls.Sessions puts this over a socket
  with the system's trusted roots and clock.

  With Options.Quic set the connection is a QUIC connection's handshake
  (Tls.Quic): no transport, only TlsHandshake, and afterwards
  TlsQuicPeerTransportParameters; TlsQuicAlert after a failure.
}
unit Tls.Client;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Tls.Connections,
  Tls.Transport;

function CreateTlsClient(constref Transport: TTlsTransport; constref Options: TTlsClientOptions;
  out Connection: PTlsConnection): LongInt;
procedure FreeTlsClient(var Connection: PTlsConnection);

function TlsHandshake(Connection: PTlsConnection): LongInt;
{ Bytes read, 0 at the end of the stream, or a TlsError code. }
function TlsRead(Connection: PTlsConnection; Buffer: Pointer; Length: PtrUInt): Int64;
{ Length, or a TlsError code. }
function TlsWrite(Connection: PTlsConnection; Buffer: Pointer; Length: PtrUInt): Int64;
{ Sends close_notify (once). }
function TlsClose(Connection: PTlsConnection): LongInt;

function TlsLastError(Connection: PTlsConnection): LongInt;
{ The error in words, with the server's alert and the certificate or
  host it is about: "the certificate has expired (certificate:
  example.com)". }
function TlsErrorDescription(Connection: PTlsConnection; Error: LongInt): string;
{ With VerifyCertificates off: what the check would have refused. }
function TlsIgnoredCertificateError(Connection: PTlsConnection): LongInt;
function TlsCipherSuiteName(Connection: PTlsConnection): string;
{ The ALPN protocol the server chose, or ''. }
function TlsSelectedProtocol(Connection: PTlsConnection): string;
{ True when the stream ended with the server's close_notify. }
function TlsClosedCleanly(Connection: PTlsConnection): Boolean;
{ "TLSv1.3" or "TLSv1.2" ('' before the handshake). }
function TlsProtocolVersionName(Connection: PTlsConnection): string;
{ The key exchange group's name ("x25519", "secp256r1", ...). }
function TlsKeyExchangeGroupName(Connection: PTlsConnection): string;
{ True when the handshake resumed a session from a ticket. }
function TlsSessionResumed(Connection: PTlsConnection): Boolean;
{ What the stapled OCSP response said. }
function TlsCertificateStatus(Connection: PTlsConnection): TTlsCertificateStatus;
{ QUIC mode (Tls.Quic): the server's transport parameters as it sent
  them (empty before its EncryptedExtensions). }
function TlsQuicPeerTransportParameters(Connection: PTlsConnection): TBytes;
{ QUIC mode: the alert the handshake's failure stands for (QUIC's
  CRYPTO_ERROR is 0x100 + it), or -1. }
function TlsQuicAlert(Connection: PTlsConnection): LongInt;

implementation

uses
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Errors,
  Tls.Handshake,
  Tls.KeySchedule,
  Tls.KeyShares,
  Tls.SessionCache,
  Tls.RecordLayer,
  Tls.RecordProtection,
  Tls.ServerMessages;

function CreateTlsClient(constref Transport: TTlsTransport; constref Options: TTlsClientOptions;
  out Connection: PTlsConnection): LongInt;
begin
  Connection := nil;
  if Options.Quic <> nil then
  begin
    if (Options.Quic^.SendHandshake = nil) or (Options.Quic^.ReceiveHandshake = nil) or
       (Options.Quic^.InstallSecret = nil) or (Options.ApplicationProtocol = '') then
      Exit(TlsErrorInvalidArgument);
  end
  else if (Transport.Send = nil) or (Transport.Receive = nil) then
    Exit(TlsErrorInvalidArgument);
  if Options.ServerName = '' then
    Exit(TlsErrorInvalidArgument);
  Connection := AllocateConnection(Transport, Options);
  if Connection = nil then
    Exit(TlsErrorOutOfMemory);
  Result := TlsErrorNone;
end;

procedure FreeTlsClient(var Connection: PTlsConnection);
begin
  ReleaseConnection(Connection);
end;

function TlsHandshake(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorInvalidArgument);
  Result := PerformClientHandshake(Connection);
end;

function HandleKeyUpdate(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  UpdateRequested: Boolean;
  Reply: array[0..4] of Byte;
begin
  Result := ParseKeyUpdate(Message + 4, MessageLength - 4, UpdateRequested);
  if Result <> TlsErrorNone then
    Exit;
  { The new keys start with the next record: nothing may follow the
    message in this one. }
  Result := EnsureNoBufferedHandshake(Connection);
  if Result <> TlsErrorNone then
    Exit;
  NextTrafficSecret(Connection^.Suite.Hash, Connection^.Schedule.ServerApplicationTraffic);
  SetRecordProtection(Connection^.ReadProtection, Connection^.Suite, Connection^.Schedule.ServerApplicationTraffic);
  if UpdateRequested then
  begin
    { Answer with update_not_requested under the old keys, then change. }
    Reply[0] := HandshakeKeyUpdate;
    Reply[1] := 0;
    Reply[2] := 0;
    Reply[3] := 1;
    Reply[4] := 0;
    Result := SendRecords(Connection, ContentHandshake, @Reply[0], 5);
    if Result <> TlsErrorNone then
      Exit;
    NextTrafficSecret(Connection^.Suite.Hash, Connection^.Schedule.ClientApplicationTraffic);
    SetRecordProtection(Connection^.WriteProtection, Connection^.Suite,
      Connection^.Schedule.ClientApplicationTraffic);
  end;
end;

{ A ticket into the cache, when resumption is on and the certificate
  that made the session was not merely ignored. }
function HandleNewSessionTicket(Connection: PTlsConnection; Message: PByte; MessageLength: PtrUInt): LongInt;
var
  Lifetime, AgeAdd: LongWord;
  Nonce, TicketBytes: TTlsByteRange;
  Ticket: TTlsSessionTicket;
begin
  Result := ParseNewSessionTicket(Message + 4, MessageLength - 4, Lifetime, AgeAdd, Nonce, TicketBytes);
  if Result <> TlsErrorNone then
    Exit;
  if (Connection^.Options.SessionCacheKey = '') or (Connection^.IgnoredCertificateError <> TlsErrorNone) then
    Exit;
  Ticket := Default(TTlsSessionTicket);
  SetLength(Ticket.Ticket, TicketBytes.Length);
  Move(TicketBytes.Data^, Ticket.Ticket[0], TicketBytes.Length);
  DeriveResumptionPsk(Connection^.Suite.Hash, @Connection^.Schedule.ResumptionMasterSecret[0], Nonce.Data,
    Nonce.Length, Ticket.Psk);
  Ticket.Hash := Connection^.Suite.Hash;
  Ticket.Suite := Connection^.Suite.Identifier;
  Ticket.AgeAdd := AgeAdd;
  Ticket.LifetimeSeconds := Lifetime;
  Ticket.ReceivedAt := Connection^.Options.VerificationTime * 1000;
  StoreSessionTicket(Connection^.Options.SessionCacheKey, Ticket);
  WipeSessionTicket(Ticket);
end;

{ TLS 1.2: a HelloRequest (renegotiation is never done) gets a warning. }
function HandleTls12Message(Connection: PTlsConnection; MessageType: Byte; MessageLength: PtrUInt): LongInt;
begin
  if (MessageType <> HandshakeHelloRequest) or (MessageLength <> 4) then
    Exit(TlsErrorUnexpectedMessage);
  SendAlert(Connection, TlsAlertNoRenegotiation);
  Result := TlsErrorNone;
end;

{ Messages after the handshake. }
function HandlePostHandshakeMessages(Connection: PTlsConnection): LongInt;
var
  MessageType: Byte;
  Message: PByte;
  MessageLength: PtrUInt;
  Available: Boolean;
begin
  while True do
  begin
    Result := TakeBufferedHandshakeMessage(Connection, MessageType, Message, MessageLength, Available);
    if (Result <> TlsErrorNone) or not Available then
      Exit;
    if Connection^.Version = VersionTls12 then
    begin
      Result := HandleTls12Message(Connection, MessageType, MessageLength);
      if Result <> TlsErrorNone then
        Exit;
      Continue;
    end;
    case MessageType of
      HandshakeNewSessionTicket:
        Result := HandleNewSessionTicket(Connection, Message, MessageLength);
      HandshakeKeyUpdate:
        Result := HandleKeyUpdate(Connection, Message, MessageLength);
    else
      { post_handshake_auth was not offered. }
      Result := TlsErrorUnexpectedMessage;
    end;
    if Result <> TlsErrorNone then
      Exit;
  end;
end;

function TlsRead(Connection: PTlsConnection; Buffer: Pointer; Length: PtrUInt): Int64;
var
  ContentType: Byte;
  Payload: PByte;
  PayloadLength: PtrUInt;
  Take: PtrUInt;
  Error: LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorInvalidArgument);
  if Connection^.State = ConnectionFailed then
    Exit(Connection^.Error);
  if Connection^.State = ConnectionNew then
  begin
    Error := TlsHandshake(Connection);
    if Error <> TlsErrorNone then
      Exit(Error);
  end;
  if Length = 0 then
    Exit(0);
  while Connection^.PlainStart = Connection^.PlainEnd do
  begin
    if Connection^.PeerClosed or (Connection^.State <> ConnectionOpen) then
      Exit(0);
    Error := ReadRecord(Connection, ContentType, Payload, PayloadLength);
    if Error = TlsErrorConnectionClosed then
    begin
      { close_notify, or the transport ended: the end of the stream. }
      Connection^.PeerClosed := True;
      Exit(0);
    end;
    if Error <> TlsErrorNone then
      Exit(FailConnection(Connection, Error));
    if ContentType = ContentHandshake then
    begin
      Error := BufferHandshakeData(Connection, Payload, PayloadLength);
      if Error = TlsErrorNone then
        Error := HandlePostHandshakeMessages(Connection);
      if Error <> TlsErrorNone then
        Exit(FailConnection(Connection, Error));
      Continue;
    end;
    { Application data; empty records are allowed. }
    if PayloadLength > 0 then
    begin
      Move(Payload^, Connection^.Plain[0], PayloadLength);
      Connection^.PlainStart := 0;
      Connection^.PlainEnd := PayloadLength;
    end;
  end;
  Take := Connection^.PlainEnd - Connection^.PlainStart;
  if Take > Length then
    Take := Length;
  Move(Connection^.Plain[Connection^.PlainStart], Buffer^, Take);
  Connection^.PlainStart := Connection^.PlainStart + Take;
  Result := Take;
end;

function TlsWrite(Connection: PTlsConnection; Buffer: Pointer; Length: PtrUInt): Int64;
var
  Error: LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorInvalidArgument);
  if Connection^.State = ConnectionFailed then
    Exit(Connection^.Error);
  if Connection^.State = ConnectionNew then
  begin
    Error := TlsHandshake(Connection);
    if Error <> TlsErrorNone then
      Exit(Error);
  end;
  if (Connection^.State <> ConnectionOpen) or Connection^.CloseNotifySent then
    Exit(TlsErrorClosed);
  if Length = 0 then
    Exit(0);
  Error := SendRecords(Connection, ContentApplicationData, Buffer, Length);
  if Error <> TlsErrorNone then
    Exit(FailConnection(Connection, Error));
  Result := Int64(Length);
end;

function TlsClose(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorInvalidArgument);
  if (Connection^.State = ConnectionOpen) and not Connection^.CloseNotifySent then
  begin
    SendAlert(Connection, TlsAlertCloseNotify);
    Connection^.CloseNotifySent := True;
  end;
  if Connection^.State <> ConnectionFailed then
    Connection^.State := ConnectionClosed;
  Result := TlsErrorNone;
end;

function TlsLastError(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorInvalidArgument);
  Result := Connection^.Error;
end;

function TlsErrorDescription(Connection: PTlsConnection; Error: LongInt): string;
begin
  Result := TlsErrorMessage(Error);
  if Connection = nil then
    Exit;
  if (Error = TlsErrorAlertReceived) and (Connection^.ReceivedAlert >= 0) then
    Result := Result + ': ' + TlsAlertName(Connection^.ReceivedAlert);
  if TlsErrorIsCertificateError(Error) and (Connection^.ErrorDetail <> '') then
    Result := Result + ' (' + Connection^.ErrorDetail + ')';
end;

function TlsIgnoredCertificateError(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorNone);
  Result := Connection^.IgnoredCertificateError;
end;

function TlsCipherSuiteName(Connection: PTlsConnection): string;
begin
  if Connection = nil then
    Exit('');
  Result := string(Connection^.Suite.Name);
end;

function TlsSelectedProtocol(Connection: PTlsConnection): string;
begin
  if Connection = nil then
    Exit('');
  Result := Connection^.SelectedProtocol;
end;

function TlsClosedCleanly(Connection: PTlsConnection): Boolean;
begin
  Result := (Connection <> nil) and Connection^.CloseNotifyReceived;
end;

function TlsProtocolVersionName(Connection: PTlsConnection): string;
begin
  Result := '';
  if Connection = nil then
    Exit;
  if Connection^.Version = VersionTls13 then
    Result := 'TLSv1.3'
  else if Connection^.Version = VersionTls12 then
    Result := 'TLSv1.2';
end;

function TlsKeyExchangeGroupName(Connection: PTlsConnection): string;
begin
  if (Connection = nil) or (Connection^.Group = 0) then
    Exit('');
  Result := GroupName(Connection^.Group);
end;

function TlsSessionResumed(Connection: PTlsConnection): Boolean;
begin
  Result := (Connection <> nil) and Connection^.Resumed;
end;

function TlsCertificateStatus(Connection: PTlsConnection): TTlsCertificateStatus;
begin
  if Connection = nil then
    Exit(StatusNotChecked);
  Result := Connection^.CertificateStatus;
end;

function TlsQuicPeerTransportParameters(Connection: PTlsConnection): TBytes;
begin
  Result := nil;
  if Connection = nil then
    Exit;
  Result := Copy(Connection^.QuicPeerParameters);
end;

function TlsQuicAlert(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(-1);
  Result := Connection^.QuicAlert;
end;

end.
