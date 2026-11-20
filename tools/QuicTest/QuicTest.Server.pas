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
  The test's QUIC server, in a thread of its own on a loopback UDP
  socket: it takes one connection (answering the first Initial with a
  Retry first when asked, or with Version Negotiation only), runs the
  test TLS server over it with libquic's connection core in the server
  role, and then serves it:

    ServeEcho     every bidirectional stream comes back as it was sent;
                  a stream saying "reset" gets a stateless reset instead,
                  "close" a CONNECTION_CLOSE with application error
                  0x1234, "update" a key update started by the server
    ServeHttp3    an HTTP/3 server (QuicTest.Http3Server)
}
unit QuicTest.Server;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Classes,
  SysUtils,
  Quic.Connections,
  Quic.ConnectionState,
  QuicTest.HostSockets;

type
  TServerMode = (ServeEcho, ServeVersionNegotiation, ServeHttp3);

  TTestServer = class;
  TServeProcedure = procedure(Server: TTestServer; Connection: TQuicConnection);

  TTestServer = class(TThread)
  public
    Endpoint: TTestEndpoint;
    Mode: TServerMode;
    UseRetry: Boolean;
    Protocol: string;
    Options: TQuicConnectionOptions;
    { How long the server waits for anything (milliseconds). }
    Patience: Int64;
    { What went wrong ('' if nothing), and what was seen. }
    Failure: string;
    StreamsServed: Integer;
    BytesServed: QWord;
    KeyUpdates: Integer;
    PeerClosed: Boolean;
    PeerCloseCode: QWord;
    PeerCloseIsApplication: Boolean;
    PacketsLost: QWord;
    { The HTTP/3 server's routine (set by QuicTest.Http3Server). }
    Http3Handler: TServeProcedure;
    constructor Create(Ipv6: Boolean; AMode: TServerMode; Port: Word = 0);
    destructor Destroy; override;
    procedure Execute; override;
  end;

implementation

uses
  Crypto.Random,
  Quic.ConnectionCore,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.InitialSecrets,
  Quic.PacketHeaders,
  Quic.PacketReceiving,
  Quic.Streams,
  Quic.StreamTable,
  QuicTest.TlsServer;

constructor TTestServer.Create(Ipv6: Boolean; AMode: TServerMode; Port: Word);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Mode := AMode;
  Protocol := 'h3';
  Patience := 10000;
  Options := Default(TQuicConnectionOptions);
  if not OpenEndpoint(Endpoint, Ipv6, Port) then
    Failure := 'cannot bind the server socket';
end;

destructor TTestServer.Destroy;
begin
  CloseEndpoint(Endpoint);
  inherited Destroy;
end;

procedure SendVersionNegotiation(Server: TTestServer; constref Header: TQuicPacketHeader);
var
  Packet: array[0..63] of Byte;
  Length: Integer;
begin
  Packet[0] := $80 or Byte(RandomQWord and $7F);
  Packet[1] := 0;
  Packet[2] := 0;
  Packet[3] := 0;
  Packet[4] := 0;
  Length := 5;
  Packet[Length] := Header.SourceId.Length;
  Move(Header.SourceId.Bytes[0], Packet[Length + 1], Header.SourceId.Length);
  Length := Length + 1 + Header.SourceId.Length;
  Packet[Length] := Header.DestinationId.Length;
  Move(Header.DestinationId.Bytes[0], Packet[Length + 1], Header.DestinationId.Length);
  Length := Length + 1 + Header.DestinationId.Length;
  { Two versions that are not 1. }
  Packet[Length] := $1A;
  Packet[Length + 1] := $2A;
  Packet[Length + 2] := $3A;
  Packet[Length + 3] := $4A;
  Packet[Length + 4] := $FF;
  Packet[Length + 5] := $00;
  Packet[Length + 6] := $00;
  Packet[Length + 7] := $1D;
  SendRaw(Server.Endpoint, @Packet[0], Length + 8);
end;

{ A Retry with a token that is the client's original Destination ID. }
procedure SendRetry(Server: TTestServer; constref Header: TQuicPacketHeader; constref RetryId: TQuicConnectionId);
var
  Packet: array[0..127] of Byte;
  Length: Integer;
begin
  Packet[0] := $F0 or Byte(RandomQWord and $0F);
  Packet[1] := 0;
  Packet[2] := 0;
  Packet[3] := 0;
  Packet[4] := 1;
  Length := 5;
  Packet[Length] := Header.SourceId.Length;
  Move(Header.SourceId.Bytes[0], Packet[Length + 1], Header.SourceId.Length);
  Length := Length + 1 + Header.SourceId.Length;
  Packet[Length] := RetryId.Length;
  Move(RetryId.Bytes[0], Packet[Length + 1], RetryId.Length);
  Length := Length + 1 + RetryId.Length;
  Packet[Length] := Ord('T');
  Move(Header.DestinationId.Bytes[0], Packet[Length + 1], Header.DestinationId.Length);
  Length := Length + 1 + Header.DestinationId.Length;
  ComputeRetryIntegrityTag(Header.DestinationId, @Packet[0], Length, @Packet[Length]);
  SendRaw(Server.Endpoint, @Packet[0], Length + 16);
end;

{ A datagram that ends in the connection's stateless reset token. }
procedure SendStatelessReset(Server: TTestServer; State: PQuicConnectionState);
var
  Packet: array[0..63] of Byte;
begin
  RandomBytes(@Packet[0], 40);
  Packet[0] := $40 or (Packet[0] and $3F);
  Move(State^.LocalResetToken[0], Packet[40], StatelessResetTokenLength);
  SendRaw(Server.Endpoint, @Packet[0], 40 + StatelessResetTokenLength);
end;

procedure ServeEchoStreams(Server: TTestServer; Connection: TQuicConnection);
var
  StreamId: QWord;
  Data: array of Byte;
  Held: PtrUInt;
  Count: Int64;
  Text: string;
begin
  Data := nil;
  while True do
  begin
    if Connection.AcceptStream(StreamId, Server.Patience) <> QuicErrorNone then
      Exit;
    if not StreamIsBidirectional(StreamId) then
      Continue;
    Held := 0;
    repeat
      if Held + 65536 > PtrUInt(Length(Data)) then
        SetLength(Data, Held + 65536 + Length(Data));
      Count := Connection.Read(StreamId, @Data[Held], 65536);
      if Count > 0 then
        Held := Held + PtrUInt(Count);
    until Count <= 0;
    if Count < 0 then
      Exit;
    Inc(Server.StreamsServed);
    Server.BytesServed := Server.BytesServed + Held;
    SetString(Text, PChar(@Data[0]), Held);
    if Held < 16 then
    begin
      if Text = 'reset' then
      begin
        SendStatelessReset(Server, Connection.State);
        { Gone without a word, as a server that lost its state is. }
        FailSilently(Connection.State, QuicErrorClosed, 'reset');
        Exit;
      end;
      if Text = 'close' then
      begin
        Connection.Close($1234, 'closing as asked');
        Exit;
      end;
      if Text = 'update' then
        Connection.RequestKeyUpdate;
    end;
    if Held = 0 then
      Count := Connection.Write(StreamId, nil, 0, True)
    else
      Count := Connection.Write(StreamId, @Data[0], Held, True);
    if Count < 0 then
      Exit;
  end;
end;

procedure TTestServer.Execute;
var
  Buffer: array[0..2047] of Byte;
  Received: Int64;
  Header: TQuicPacketHeader;
  RetryId, OriginalId: TQuicConnectionId;
  State: PQuicConnectionState;
  Transport: TQuicDatagramTransport;
  Connection: TQuicConnection;
  Deadline: Int64;
begin
  if Failure <> '' then
    Exit;
  Deadline := QuicMilliseconds + Patience;
  repeat
    Received := ReceiveRaw(Endpoint, @Buffer[0], SizeOf(Buffer), Deadline - QuicMilliseconds);
    if Received <= 0 then
    begin
      Failure := 'no Initial came';
      Exit;
    end;
  until ParsePacketHeader(@Buffer[0], Received, LocalConnectionIdLength, Header) and
    (Header.PacketType in [PacketInitial, PacketVersionNegotiation]) or (Header.Version <> QuicVersion1);
  if Mode = ServeVersionNegotiation then
  begin
    SendVersionNegotiation(Self, Header);
    Exit;
  end;
  OriginalId := Header.DestinationId;
  RetryId := Default(TQuicConnectionId);
  if UseRetry then
  begin
    RetryId := RandomConnectionId(8);
    SendRetry(Self, Header, RetryId);
    repeat
      Received := ReceiveRaw(Endpoint, @Buffer[0], SizeOf(Buffer), Deadline - QuicMilliseconds);
      if Received <= 0 then
      begin
        Failure := 'no Initial came after the Retry';
        Exit;
      end;
    until ParsePacketHeader(@Buffer[0], Received, LocalConnectionIdLength, Header) and
      (Header.PacketType = PacketInitial) and (Header.TokenLength > 0);
    if (Header.TokenLength <> 1 + PtrUInt(OriginalId.Length)) or (Header.Token[0] <> Ord('T')) or
       (CompareByte(Header.Token[1], OriginalId.Bytes[0], OriginalId.Length) <> 0) or
       not SameConnectionId(Header.DestinationId, RetryId) then
    begin
      Failure := 'the Initial after the Retry has the wrong token or ID';
      Exit;
    end;
  end;
  MakeTransport(@Endpoint, Transport);
  Options.ApplicationProtocol := Protocol;
  State := CreateConnectionState(RoleServer, Options, Transport);
  StartServerConnection(State, Header.DestinationId, Header.SourceId, OriginalId, RetryId);
  ProcessDatagram(State, @Buffer[0], Received, QuicMilliseconds);
  Connection := TQuicConnection.CreateFromState(State);
  try
    Connection.Timeout := Patience;
    Failure := RunServerHandshake(State, Protocol);
    if Failure <> '' then
    begin
      PeerClosed := State^.PeerClosed;
      PeerCloseCode := State^.PeerCloseCode;
      Exit;
    end;
    if Mode = ServeHttp3 then
      Http3Handler(Self, Connection)
    else
      ServeEchoStreams(Self, Connection);
    { Linger until the client closes, to answer its last packets. }
    Deadline := QuicMilliseconds + 2000;
    while (Connection.LastError = QuicErrorNone) and (QuicMilliseconds < Deadline) do
      Connection.Pump(100);
    KeyUpdates := State^.Statistics.KeyUpdates;
    PacketsLost := State^.Statistics.PacketsLost;
    PeerClosed := State^.PeerClosed;
    PeerCloseCode := State^.PeerCloseCode;
    PeerCloseIsApplication := State^.PeerCloseIsApplication;
  finally
    Connection.Free;
  end;
end;

end.
