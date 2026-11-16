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
  A TLS 1.3 client connection over any transport:

    CreateTlsClient(Transport, Options, Connection);
    if TlsHandshake(Connection) <> TlsErrorNone then ... TlsDescribeError
    TlsWrite(Connection, Request, Length);
    Count := TlsRead(Connection, @Buffer, SizeOf(Buffer));   (0: closed)
    TlsClose(Connection);
    FreeTlsClient(Connection);

  Reading handles what the server sends after the handshake: session
  tickets are read and dropped (no resumption), a KeyUpdate moves the
  read keys on and, when the server asks, the write keys too (RFC 8446
  section 4.6.3). The server's close_notify ends the stream (TlsRead
  returns 0); so does the transport ending without one, which
  TlsClosedCleanly tells apart. Tls.Sessions puts this over a socket
  with the system's trusted roots and clock.
}
unit Tls.Client;

{$mode objfpc}
{$pointermath on}

interface

uses
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
function TlsDescribeError(Connection: PTlsConnection; Error: LongInt; Buffer: PChar; Capacity: PtrUInt): PChar;
{ With VerifyCertificates off: what the check would have refused. }
function TlsIgnoredCertificateError(Connection: PTlsConnection): LongInt;
function TlsCipherSuiteName(Connection: PTlsConnection): PChar;
{ The ALPN protocol the server chose, or ''. }
function TlsSelectedProtocol(Connection: PTlsConnection): PChar;
{ True when the stream ended with the server's close_notify. }
function TlsClosedCleanly(Connection: PTlsConnection): Boolean;

implementation

uses
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Errors,
  Tls.Handshake,
  Tls.KeySchedule,
  Tls.RecordLayer,
  Tls.RecordProtection,
  Tls.ServerMessages;

function CreateTlsClient(constref Transport: TTlsTransport; constref Options: TTlsClientOptions;
  out Connection: PTlsConnection): LongInt;
begin
  Connection := nil;
  if (Transport.Send = nil) or (Transport.Receive = nil) then
    Exit(TlsErrorInvalidArgument);
  if (Options.ServerName = nil) or (Options.ServerName[0] = #0) then
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
    case MessageType of
      HandshakeNewSessionTicket:
        Result := ParseNewSessionTicket(Message + 4, MessageLength - 4);
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

procedure AppendText(Buffer: PChar; Capacity: PtrUInt; var Position: PtrUInt; Text: PChar);
var
  Index: PtrUInt;
begin
  Index := 0;
  while (Text[Index] <> #0) and (Position + 1 < Capacity) do
  begin
    Buffer[Position] := Text[Index];
    Inc(Position);
    Inc(Index);
  end;
  Buffer[Position] := #0;
end;

function TlsDescribeError(Connection: PTlsConnection; Error: LongInt; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Position: PtrUInt;
begin
  Result := Buffer;
  if Capacity = 0 then
    Exit;
  Position := 0;
  Buffer[0] := #0;
  AppendText(Buffer, Capacity, Position, TlsErrorMessage(Error));
  if Connection = nil then
    Exit;
  if (Error = TlsErrorAlertReceived) and (Connection^.ReceivedAlert >= 0) then
  begin
    AppendText(Buffer, Capacity, Position, ': ');
    AppendText(Buffer, Capacity, Position, TlsAlertName(Connection^.ReceivedAlert));
  end;
  if TlsErrorIsCertificateError(Error) and (Connection^.ErrorDetail[0] <> #0) then
  begin
    AppendText(Buffer, Capacity, Position, ' (');
    AppendText(Buffer, Capacity, Position, @Connection^.ErrorDetail[0]);
    AppendText(Buffer, Capacity, Position, ')');
  end;
end;

function TlsIgnoredCertificateError(Connection: PTlsConnection): LongInt;
begin
  if Connection = nil then
    Exit(TlsErrorNone);
  Result := Connection^.IgnoredCertificateError;
end;

function TlsCipherSuiteName(Connection: PTlsConnection): PChar;
begin
  if (Connection = nil) or (Connection^.Suite.Name = nil) then
    Exit('');
  Result := Connection^.Suite.Name;
end;

function TlsSelectedProtocol(Connection: PTlsConnection): PChar;
begin
  if Connection = nil then
    Exit('');
  Result := @Connection^.SelectedProtocol[0];
end;

function TlsClosedCleanly(Connection: PTlsConnection): Boolean;
begin
  Result := (Connection <> nil) and Connection^.CloseNotifyReceived;
end;

end.
