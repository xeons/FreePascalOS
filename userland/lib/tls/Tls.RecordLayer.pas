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
  The TLS 1.3 record layer (RFC 8446 section 5) of a client connection.

  Reading: a record is taken whole from the transport (its length
  checked first: at most 2^14 + 256 bytes protected, 2^14 plain),
  opened with the read keys when they are set, and the inner content
  type found behind the zero padding. Dropped change_cipher_spec
  records, plaintext where protection is expected, empty records and
  application data before the handshake ends are refused as the RFC
  says. Alerts are handled here: close_notify ends the stream,
  user_canceled is ignored, anything else fails the connection.

  Handshake messages may be split over records or share one; they are
  put together in the connection's handshake buffer and handed out
  whole (NextHandshakeMessage). A message must not straddle a change of
  keys (EnsureNoBufferedHandshake).

  Writing: data goes out in records of at most 2^14 bytes, sealed with
  the write keys when they are set.

  Once the server has chosen TLS 1.2 (Connection^.Version) records are
  protected the TLS 1.2 way (no inner content type), the server's
  change_cipher_spec switches on the read keys the handshake has made
  ready (PendingReadProtection), and warning alerts other than
  close_notify are passed over.
}
unit Tls.RecordLayer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.Connections;

{ The next record: its (inner) content type and its plaintext, which
  stays valid until the next read. Alerts never come out of here:
  close_notify gives TlsErrorConnectionClosed with PeerClosed set. }
function ReadRecord(Connection: PTlsConnection; out ContentType: Byte; out Payload: PByte;
  out Length: PtrUInt): LongInt;
{ The next whole handshake message (header included), valid until the
  next call. Application data in the way is an unexpected message. }
function NextHandshakeMessage(Connection: PTlsConnection; out MessageType: Byte; out Message: PByte;
  out MessageLength: PtrUInt): LongInt;
{ TlsErrorUnexpectedMessage when handshake bytes beyond the last
  message are waiting (they would straddle a key change). }
function EnsureNoBufferedHandshake(Connection: PTlsConnection): LongInt;
{ Appends a record's handshake bytes to the handshake buffer. }
function BufferHandshakeData(Connection: PTlsConnection; Data: PByte; Length: PtrUInt): LongInt;
{ A whole message from the handshake buffer if one is there. }
function TakeBufferedHandshakeMessage(Connection: PTlsConnection; out MessageType: Byte; out Message: PByte;
  out MessageLength: PtrUInt; out Available: Boolean): LongInt;

function SendRecords(Connection: PTlsConnection; ContentType: Byte; Data: PByte; Length: PtrUInt): LongInt;
{ Best effort: errors are ignored (the connection is failing anyway or
  closing). }
procedure SendAlert(Connection: PTlsConnection; Description: LongInt);
{ The dummy change_cipher_spec of middlebox compatibility mode. }
function SendChangeCipherSpec(Connection: PTlsConnection): LongInt;

implementation

uses
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Errors,
  Tls.RecordProtection;

{ Makes at least Needed bytes available from InputStart on. }
function FillInput(Connection: PTlsConnection; Needed: PtrUInt): LongInt;
var
  Received: Int64;
begin
  if Connection^.InputEnd - Connection^.InputStart >= Needed then
    Exit(TlsErrorNone);
  { Move what is left to the front. }
  if Connection^.InputStart > 0 then
  begin
    if Connection^.InputEnd > Connection^.InputStart then
      Move(Connection^.Input[Connection^.InputStart], Connection^.Input[0],
        Connection^.InputEnd - Connection^.InputStart);
    Connection^.InputEnd := Connection^.InputEnd - Connection^.InputStart;
    Connection^.InputStart := 0;
  end;
  if Needed > InputBufferSize then
    Exit(TlsErrorRecordOverflow);
  while Connection^.InputEnd < Needed do
  begin
    Received := Connection^.Transport.Receive(Connection^.Transport.Context,
      @Connection^.Input[Connection^.InputEnd], InputBufferSize - Connection^.InputEnd);
    if Received < 0 then
      Exit(LongInt(Received));
    if Received = 0 then
      Exit(TlsErrorConnectionClosed);
    Connection^.InputEnd := Connection^.InputEnd + PtrUInt(Received);
  end;
  Result := TlsErrorNone;
end;

function HandleAlert(Connection: PTlsConnection; Payload: PByte; Length: PtrUInt; out Ignore: Boolean): LongInt;
begin
  Ignore := False;
  if Length <> 2 then
    Exit(TlsErrorMalformedMessage);
  case Payload[1] of
    TlsAlertCloseNotify:
      begin
        Connection^.PeerClosed := True;
        Connection^.CloseNotifyReceived := True;
        Result := TlsErrorConnectionClosed;
      end;
    TlsAlertUserCanceled:
      begin
        { A warning before close_notify. }
        Ignore := True;
        Result := TlsErrorNone;
      end;
  else
    { Every other alert is fatal in TLS 1.3, whatever its level. }
    Connection^.ReceivedAlert := Payload[1];
    Result := TlsErrorAlertReceived;
  end;
end;

{ The inner plaintext ends with the content type and then zeros. }
function StripPadding(Payload: PByte; var Length: PtrUInt; out ContentType: Byte): Boolean;
begin
  while (Length > 0) and (Payload[Length - 1] = 0) do
    Dec(Length);
  if Length = 0 then
    Exit(False);
  ContentType := Payload[Length - 1];
  Dec(Length);
  Result := True;
end;

function ReadRecord(Connection: PTlsConnection; out ContentType: Byte; out Payload: PByte;
  out Length: PtrUInt): LongInt;
var
  Header: PByte;
  OuterType: Byte;
  RecordLength: PtrUInt;
  Ignore: Boolean;
begin
  ContentType := 0;
  Payload := nil;
  Length := 0;
  while True do
  begin
    Result := FillInput(Connection, RecordHeaderLength);
    if Result <> TlsErrorNone then
      Exit;
    Header := @Connection^.Input[Connection^.InputStart];
    OuterType := Header[0];
    RecordLength := (PtrUInt(Header[3]) shl 8) or Header[4];
    { The record version is not checked beyond its major number. }
    if Header[1] <> 3 then
      Exit(TlsErrorMalformedMessage);
    if not (OuterType in [ContentChangeCipherSpec, ContentAlert, ContentHandshake, ContentApplicationData]) then
      Exit(TlsErrorUnexpectedMessage);
    if RecordLength > MaximumCiphertextLength then
      Exit(TlsErrorRecordOverflow);
    Result := FillInput(Connection, RecordHeaderLength + RecordLength);
    if Result <> TlsErrorNone then
      Exit;
    Header := @Connection^.Input[Connection^.InputStart];
    Payload := Header + RecordHeaderLength;
    Length := RecordLength;
    Connection^.InputStart := Connection^.InputStart + RecordHeaderLength + RecordLength;

    if OuterType = ContentChangeCipherSpec then
    begin
      if (Length <> 1) or (Payload[0] <> 1) then
        Exit(TlsErrorUnexpectedMessage);
      if Connection^.Version = VersionTls12 then
      begin
        { The server's keys start here; no handshake message may
          straddle the change. }
        if not Connection^.PendingReadProtection.Active or (EnsureNoBufferedHandshake(Connection) <> TlsErrorNone) then
          Exit(TlsErrorUnexpectedMessage);
        Connection^.ReadProtection := Connection^.PendingReadProtection;
        WipeRecordProtection(Connection^.PendingReadProtection);
        Continue;
      end;
      if not Connection^.AllowChangeCipherSpec then
        Exit(TlsErrorUnexpectedMessage);
      Continue;
    end;

    if Connection^.ReadProtection.Active and Connection^.ReadProtection.Tls12 then
    begin
      if not OpenTls12Record(Connection^.ReadProtection, OuterType, Payload, RecordLength, Payload, Length) then
        Exit(TlsErrorBadRecordMac);
      if Length > MaximumPlaintextLength then
        Exit(TlsErrorRecordOverflow);
      ContentType := OuterType;
    end
    else if Connection^.ReadProtection.Active and (OuterType = ContentApplicationData) then
    begin
      if not OpenRecord(Connection^.ReadProtection, Header, Payload, RecordLength, Length) then
        Exit(TlsErrorBadRecordMac);
      if not StripPadding(Payload, Length, ContentType) then
        Exit(TlsErrorUnexpectedMessage);
      if Length > MaximumPlaintextLength then
        Exit(TlsErrorRecordOverflow);
    end
    else
    begin
      { Without keys only handshake and alerts come; with keys only an
        alert may still come in the clear (a server that could not read
        the ClientHello's answer). }
      if Connection^.ReadProtection.Active and (OuterType <> ContentAlert) then
        Exit(TlsErrorUnexpectedMessage);
      if OuterType = ContentApplicationData then
        Exit(TlsErrorUnexpectedMessage);
      if RecordLength > MaximumPlaintextLength then
        Exit(TlsErrorRecordOverflow);
      ContentType := OuterType;
    end;

    if ContentType = ContentAlert then
    begin
      { TLS 1.2 warnings (no_renegotiation, say) are passed over. }
      if (Connection^.Version = VersionTls12) and (Length = 2) and (Payload[0] = 1) and
         (Payload[1] <> TlsAlertCloseNotify) then
        Continue;
      Result := HandleAlert(Connection, Payload, Length, Ignore);
      if Ignore then
        Continue;
      Exit;
    end;
    if (ContentType = ContentHandshake) and (Length = 0) then
      Exit(TlsErrorUnexpectedMessage);
    if not (ContentType in [ContentHandshake, ContentApplicationData]) then
      Exit(TlsErrorUnexpectedMessage);
    Exit(TlsErrorNone);
  end;
end;

function BufferHandshakeData(Connection: PTlsConnection; Data: PByte; Length: PtrUInt): LongInt;
begin
  if Connection^.HandshakeBuffer.Length + Length > MaximumHandshakeMessageLength + 4 + MaximumPlaintextLength then
    Exit(TlsErrorMalformedMessage);
  AppendBytes(Connection^.HandshakeBuffer, Data, Length);
  if Connection^.HandshakeBuffer.Failed then
    Exit(TlsErrorOutOfMemory);
  Result := TlsErrorNone;
end;

function TakeBufferedHandshakeMessage(Connection: PTlsConnection; out MessageType: Byte; out Message: PByte;
  out MessageLength: PtrUInt; out Available: Boolean): LongInt;
var
  Buffer: PByte;
  BodyLength: PtrUInt;
begin
  MessageType := 0;
  Message := nil;
  MessageLength := 0;
  Available := False;
  if Connection^.HandshakeConsumed > 0 then
  begin
    RemoveFromFront(Connection^.HandshakeBuffer, Connection^.HandshakeConsumed);
    Connection^.HandshakeConsumed := 0;
  end;
  Result := TlsErrorNone;
  if Connection^.HandshakeBuffer.Length < 4 then
    Exit;
  Buffer := Connection^.HandshakeBuffer.Data;
  BodyLength := (PtrUInt(Buffer[1]) shl 16) or (PtrUInt(Buffer[2]) shl 8) or Buffer[3];
  if BodyLength > MaximumHandshakeMessageLength then
    Exit(TlsErrorMalformedMessage);
  if Connection^.HandshakeBuffer.Length < 4 + BodyLength then
    Exit;
  MessageType := Buffer[0];
  Message := Buffer;
  MessageLength := 4 + BodyLength;
  Connection^.HandshakeConsumed := MessageLength;
  Available := True;
end;

function NextHandshakeMessage(Connection: PTlsConnection; out MessageType: Byte; out Message: PByte;
  out MessageLength: PtrUInt): LongInt;
var
  Available: Boolean;
  ContentType: Byte;
  Payload: PByte;
  Length: PtrUInt;
begin
  while True do
  begin
    Result := TakeBufferedHandshakeMessage(Connection, MessageType, Message, MessageLength, Available);
    if (Result <> TlsErrorNone) or Available then
      Exit;
    Result := ReadRecord(Connection, ContentType, Payload, Length);
    if Result <> TlsErrorNone then
      Exit;
    if ContentType <> ContentHandshake then
      Exit(TlsErrorUnexpectedMessage);
    Result := BufferHandshakeData(Connection, Payload, Length);
    if Result <> TlsErrorNone then
      Exit;
  end;
end;

function EnsureNoBufferedHandshake(Connection: PTlsConnection): LongInt;
begin
  if Connection^.HandshakeBuffer.Length > Connection^.HandshakeConsumed then
    Exit(TlsErrorUnexpectedMessage);
  Result := TlsErrorNone;
end;

function SendRaw(Connection: PTlsConnection; Data: PByte; Length: PtrUInt): LongInt;
var
  Sent: Int64;
begin
  Sent := Connection^.Transport.Send(Connection^.Transport.Context, Data, Length);
  if Sent < 0 then
    Exit(LongInt(Sent));
  if PtrUInt(Sent) <> Length then
    Exit(TlsErrorTransportFailed);
  Result := TlsErrorNone;
end;

function SendOneRecord(Connection: PTlsConnection; ContentType: Byte; Data: PByte; Length: PtrUInt): LongInt;
var
  Output: PByte;
  InnerLength: PtrUInt;
  Version: Word;
begin
  Output := Connection^.Output;
  if Connection^.WriteProtection.Active and Connection^.WriteProtection.Tls12 then
  begin
    InnerLength := Length + Tls12RecordExpansion(Connection^.WriteProtection);
    Output[0] := ContentType;
    Output[1] := 3;
    Output[2] := 3;
    Output[3] := Byte(InnerLength shr 8);
    Output[4] := Byte(InnerLength);
    if not SealTls12Record(Connection^.WriteProtection, ContentType, Data, Length, @Output[RecordHeaderLength]) then
      Exit(TlsErrorInternal);
    Exit(SendRaw(Connection, Output, RecordHeaderLength + InnerLength));
  end;
  if Connection^.WriteProtection.Active then
  begin
    { TLSInnerPlaintext: the content, its type, no padding. }
    InnerLength := Length + 1;
    Output[0] := ContentApplicationData;
    Output[1] := 3;
    Output[2] := 3;
    Output[3] := Byte((InnerLength + AeadTagLength) shr 8);
    Output[4] := Byte(InnerLength + AeadTagLength);
    if Length > 0 then
      Move(Data^, Output[RecordHeaderLength], Length);
    Output[RecordHeaderLength + Length] := ContentType;
    if not SealRecord(Connection^.WriteProtection, Output, @Output[RecordHeaderLength], InnerLength,
      @Output[RecordHeaderLength]) then
      Exit(TlsErrorInternal);
    Exit(SendRaw(Connection, Output, RecordHeaderLength + InnerLength + AeadTagLength));
  end;
  if Connection^.FirstRecordSent then
    Version := VersionTls12
  else
    Version := VersionTls10;
  Connection^.FirstRecordSent := True;
  Output[0] := ContentType;
  Output[1] := Byte(Version shr 8);
  Output[2] := Byte(Version);
  Output[3] := Byte(Length shr 8);
  Output[4] := Byte(Length);
  if Length > 0 then
    Move(Data^, Output[RecordHeaderLength], Length);
  Result := SendRaw(Connection, Output, RecordHeaderLength + Length);
end;

function SendRecords(Connection: PTlsConnection; ContentType: Byte; Data: PByte; Length: PtrUInt): LongInt;
var
  Take: PtrUInt;
begin
  repeat
    Take := Length;
    if Take > MaximumPlaintextLength then
      Take := MaximumPlaintextLength;
    Result := SendOneRecord(Connection, ContentType, Data, Take);
    if Result <> TlsErrorNone then
      Exit;
    Data := Data + Take;
    Length := Length - Take;
  until Length = 0;
end;

procedure SendAlert(Connection: PTlsConnection; Description: LongInt);
var
  Alert: array[0..1] of Byte;
begin
  { Level 2 (fatal) except for close_notify and (TLS 1.2's refusal to
    renegotiate) no_renegotiation. }
  if (Description = TlsAlertCloseNotify) or (Description = TlsAlertNoRenegotiation) then
    Alert[0] := 1
  else
    Alert[0] := 2;
  Alert[1] := Byte(Description);
  SendOneRecord(Connection, ContentAlert, @Alert[0], 2);
end;

function SendChangeCipherSpec(Connection: PTlsConnection): LongInt;
var
  Message: Byte;
  Saved: Boolean;
begin
  { Always in the clear, whatever the keys. }
  Message := 1;
  Saved := Connection^.WriteProtection.Active;
  Connection^.WriteProtection.Active := False;
  Connection^.FirstRecordSent := True;
  Result := SendOneRecord(Connection, ContentChangeCipherSpec, @Message, 1);
  Connection^.WriteProtection.Active := Saved;
end;

end.
