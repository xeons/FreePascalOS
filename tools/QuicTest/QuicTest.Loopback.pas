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
  Whole QUIC connections over UDP on 127.0.0.1 and ::1 between
  libquic's client (TQuicConnection, libtls in QUIC mode) and the test
  server: each cipher suite, both address families, a large transfer
  through the flow control windows, loss on both sides, a Retry, key
  updates from either side, many streams in a row, path MTU probing,
  and the failures: Version Negotiation without version 1, a stateless
  reset, an application close, a certificate the client does not trust.
}
unit QuicTest.Loopback;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunLoopbackTests;

implementation

uses
  SysUtils,
  TestChecks,
  Tls.CipherSuites,
  Tls.TrustStore,
  Quic.Connections,
  Quic.ConnectionState,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  QuicTest.HostSockets,
  QuicTest.Server;

{$I QuicTest.Generated.inc}

var
  TrustStore: PTlsTrustStore;

type
  TClientSetup = record
    Ipv6: Boolean;
    Suite: Word;
    DropEverySent: Integer;
    ProbePathMtu: Boolean;
    Trusted: Boolean;
  end;

function DefaultSetup: TClientSetup;
begin
  Result := Default(TClientSetup);
  Result.Trusted := True;
end;

{ A client connection to Server (not connected yet). }
function MakeClient(Server: TTestServer; constref Setup: TClientSetup; Endpoint: PTestEndpoint): TQuicConnection;
var
  Options: TQuicConnectionOptions;
  Transport: TQuicDatagramTransport;
begin
  OpenEndpoint(Endpoint^, Setup.Ipv6);
  SetPeerPort(Endpoint^, Server.Endpoint.Port);
  Endpoint^.DropEverySent := Setup.DropEverySent;
  MakeTransport(Endpoint, Transport);
  Options := Default(TQuicConnectionOptions);
  { (libtls matches IPv4 literals only against addresses.) }
  Options.ServerName := 'localhost';
  Options.ApplicationProtocol := 'h3';
  if Setup.Trusted then
    Options.TrustStore := TrustStore
  else
    Options.TrustStore := CreateTrustStore;
  Options.VerifyCertificates := True;
  Options.VerificationTime := Trunc((Now - EncodeDate(1970, 1, 1)) * 86400);
  Options.HandshakeTimeout := 5000;
  Options.IdleTimeout := 5000;
  Options.ProbePathMtu := Setup.ProbePathMtu;
  if Setup.Suite <> 0 then
  begin
    Options.CipherSuites.Count := 1;
    Options.CipherSuites.Identifiers[0] := Setup.Suite;
  end;
  Result := TQuicConnection.Create(Transport, Options);
  Result.Timeout := 10000;
end;

function SuiteName(Identifier: Word): string;
var
  Info: TCipherSuiteInfo;
begin
  Result := '';
  if FindCipherSuite(Identifier, Info) then
    Result := string(Info.Name);
end;

function PatternByte(Index: PtrUInt): Byte;
begin
  Result := Byte((Index * 131 + (Index shr 8) * 7 + 11) and $FF);
end;

{ Sends Size bytes on a new stream and reads them back. }
function EchoRoundTrip(Client: TQuicConnection; Size: PtrUInt; const Name: string): Boolean;
var
  Sent, Back: array of Byte;
  Index: PtrUInt;
  StreamId: QWord;
  Held: PtrUInt;
  Count: Int64;
begin
  Result := False;
  Sent := nil;
  Back := nil;
  SetLength(Sent, Size + 1);
  SetLength(Back, Size + 65536);
  for Index := 0 to Size - 1 do
    Sent[Index] := PatternByte(Index);
  if Client.OpenStream(True, StreamId) <> QuicErrorNone then
  begin
    Check(False, Name + ': stream opens');
    Exit;
  end;
  Count := Client.Write(StreamId, @Sent[0], Size, True);
  if Count <> Int64(Size) then
  begin
    Check(False, Name + ': written (' + Client.ErrorDescription(Count) + ')');
    Exit;
  end;
  Held := 0;
  repeat
    Count := Client.Read(StreamId, @Back[Held], 65536);
    if Count > 0 then
      Held := Held + PtrUInt(Count);
  until Count <= 0;
  if Count < 0 then
  begin
    Check(False, Name + ': read back (' + Client.ErrorDescription(Count) + ')');
    Exit;
  end;
  Result := (Held = Size) and (CompareByte(Sent[0], Back[0], Size) = 0);
  Check(Result, Name + ': ' + IntToStr(Size) + ' bytes come back intact');
end;

function SendCommand(Client: TQuicConnection; const Command: string): Int64;
var
  StreamId: QWord;
  Buffer: array[0..15] of Byte;
begin
  Result := Client.OpenStream(True, StreamId);
  if Result <> QuicErrorNone then
    Exit;
  Result := Client.Write(StreamId, PChar(Command), Length(Command), True);
  if Result < 0 then
    Exit;
  Result := Client.Read(StreamId, @Buffer[0], SizeOf(Buffer));
  while Result > 0 do
    Result := Client.Read(StreamId, @Buffer[0], SizeOf(Buffer));
end;

procedure FinishServer(Server: TTestServer; const Name: string);
begin
  Server.WaitFor;
  Check(Server.Failure = '', Name + ': the server had no trouble' + ' ' + Server.Failure);
end;

procedure TestEcho(const Name: string; Setup: TClientSetup; Size: PtrUInt; Rounds: Integer);
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Error: LongInt;
  Round: Integer;
  Started: Int64;
begin
  Started := QuicMilliseconds;
  Server := TTestServer.Create(Setup.Ipv6, ServeEcho);
  Server.Endpoint.DropEverySent := Setup.DropEverySent;
  Server.Start;
  Client := MakeClient(Server, Setup, @Endpoint);
  try
    Error := Client.Connect;
    Check(Error = QuicErrorNone, Name + ': handshake (' + Client.ErrorDescription(Error) + ')');
    if Error = QuicErrorNone then
    begin
      Check(Client.ApplicationProtocol = 'h3', Name + ': ALPN h3');
      for Round := 1 to Rounds do
        if not EchoRoundTrip(Client, Size, Name) then
          Break;
      if Setup.Suite <> 0 then
        Check(Client.CipherSuiteName = SuiteName(Setup.Suite), Name + ': suite ' + Client.CipherSuiteName);
      if Setup.DropEverySent > 0 then
        Check(Client.Statistics.PacketsLost > 0, Name + ': losses were noticed and repaired');
      WriteLn('info ', Name, ': ', QuicMilliseconds - Started, ' ms, ', Client.Statistics.PacketsSent,
        ' packets sent, ', Client.Statistics.PacketsLost, ' lost, window ', Client.CongestionWindow);
      Client.Close(0, '');
    end;
  finally
    Client.Free;
    FinishServer(Server, Name);
    if Error = QuicErrorNone then
      Check(Server.PeerClosed and Server.PeerCloseIsApplication and (Server.PeerCloseCode = 0),
        Name + ': the server saw the client close');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestSuites;
var
  Setup: TClientSetup;
begin
  Setup := DefaultSetup;
  Setup.Suite := CipherSuiteAes128GcmSha256;
  TestEcho('AES-128-GCM', Setup, 1000, 1);
  Setup.Suite := CipherSuiteAes256GcmSha384;
  TestEcho('AES-256-GCM', Setup, 1000, 1);
  Setup.Suite := CipherSuiteChaCha20Poly1305Sha256;
  TestEcho('ChaCha20-Poly1305', Setup, 1000, 1);
  Setup := DefaultSetup;
  Setup.Ipv6 := True;
  TestEcho('IPv6', Setup, 5000, 2);
end;

procedure TestBulkAndLoss;
var
  Setup: TClientSetup;
begin
  Setup := DefaultSetup;
  TestEcho('bulk', Setup, 3 * 1024 * 1024, 1);
  TestEcho('many streams', Setup, 100, 150);
  Setup.DropEverySent := 10;
  TestEcho('loss', Setup, 400 * 1024, 1);
end;

procedure TestRetry;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Error: LongInt;
begin
  Server := TTestServer.Create(False, ServeEcho);
  Server.UseRetry := True;
  Server.Start;
  Client := MakeClient(Server, DefaultSetup, @Endpoint);
  try
    Error := Client.Connect;
    Check(Error = QuicErrorNone, 'Retry: handshake (' + Client.ErrorDescription(Error) + ')');
    Check(Client.State^.RetryReceived, 'Retry: taken');
    if Error = QuicErrorNone then
      EchoRoundTrip(Client, 20000, 'Retry');
    Client.Close(0, '');
  finally
    Client.Free;
    FinishServer(Server, 'Retry');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestKeyUpdates;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Error: LongInt;
begin
  Server := TTestServer.Create(False, ServeEcho);
  Server.Start;
  Client := MakeClient(Server, DefaultSetup, @Endpoint);
  try
    Error := Client.Connect;
    Check(Error = QuicErrorNone, 'key update: handshake');
    if Error = QuicErrorNone then
    begin
      EchoRoundTrip(Client, 50000, 'before a key update');
      Client.RequestKeyUpdate;
      EchoRoundTrip(Client, 300000, 'across a client key update');
      Check(Client.Statistics.KeyUpdates = 1, 'the client moved its keys once');
      SendCommand(Client, 'update');
      EchoRoundTrip(Client, 300000, 'across a server key update');
      Check(Client.Statistics.KeyUpdates = 2, 'the client followed the server''s key update');
    end;
    Client.Close(0, '');
  finally
    Client.Free;
    FinishServer(Server, 'key update');
    Check(Server.KeyUpdates = 2, 'the server took part in both key updates');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestPathMtu;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Setup: TClientSetup;
  Deadline: Int64;
begin
  Server := TTestServer.Create(False, ServeEcho);
  Server.Options.ProbePathMtu := True;
  Server.Start;
  Setup := DefaultSetup;
  Setup.ProbePathMtu := True;
  Client := MakeClient(Server, Setup, @Endpoint);
  try
    if Client.Connect = QuicErrorNone then
    begin
      Check(Client.DatagramSize = MinimumDatagramSize, 'path MTU: 1200 bytes at first');
      EchoRoundTrip(Client, 10000, 'path MTU');
      Deadline := QuicMilliseconds + 2000;
      while (Client.DatagramSize < MaximumDatagramSize) and (QuicMilliseconds < Deadline) do
        Client.Pump(50);
      Check(Client.DatagramSize = MaximumDatagramSize, 'path MTU: 1452-byte datagrams after the probe');
      EchoRoundTrip(Client, 200000, 'with large datagrams');
    end
    else
      Check(False, 'path MTU: handshake');
    Client.Close(0, '');
  finally
    Client.Free;
    FinishServer(Server, 'path MTU');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestVersionNegotiation;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Error: LongInt;
begin
  Server := TTestServer.Create(False, ServeVersionNegotiation);
  Server.Start;
  Client := MakeClient(Server, DefaultSetup, @Endpoint);
  try
    Error := Client.Connect;
    Check(Error = QuicErrorVersionNegotiation, 'Version Negotiation without version 1 ends the attempt (' +
      Client.ErrorDescription(Error) + ')');
  finally
    Client.Free;
    FinishServer(Server, 'Version Negotiation');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestStatelessResetAndClose;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Error: Int64;
begin
  Server := TTestServer.Create(False, ServeEcho);
  Server.Start;
  Client := MakeClient(Server, DefaultSetup, @Endpoint);
  try
    if Client.Connect = QuicErrorNone then
    begin
      EchoRoundTrip(Client, 1000, 'before a stateless reset');
      Error := SendCommand(Client, 'reset');
      Check(Error = QuicErrorStatelessReset, 'a stateless reset is recognized (' + Client.ErrorDescription(Error) + ')');
    end
    else
      Check(False, 'stateless reset: handshake');
  finally
    Client.Free;
    FinishServer(Server, 'stateless reset');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;

  Server := TTestServer.Create(False, ServeEcho);
  Server.Start;
  Client := MakeClient(Server, DefaultSetup, @Endpoint);
  try
    if Client.Connect = QuicErrorNone then
    begin
      Error := SendCommand(Client, 'close');
      Check(Error = QuicErrorClosedByPeer, 'the server''s close is seen (' + Client.ErrorDescription(Error) + ')');
      Check(Client.State^.PeerCloseIsApplication and (Client.State^.PeerCloseCode = $1234) and
        (Client.State^.PeerCloseReason = 'closing as asked'), 'with its error code and reason');
    end
    else
      Check(False, 'close: handshake');
  finally
    Client.Free;
    FinishServer(Server, 'close');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure TestUntrustedCertificate;
var
  Server: TTestServer;
  Client: TQuicConnection;
  Endpoint: TTestEndpoint;
  Setup: TClientSetup;
  Error: LongInt;
begin
  Server := TTestServer.Create(False, ServeEcho);
  Server.Patience := 3000;
  Server.Start;
  Setup := DefaultSetup;
  Setup.Trusted := False;
  Client := MakeClient(Server, Setup, @Endpoint);
  try
    Error := Client.Connect;
    Check(Error = QuicErrorHandshakeFailed, 'an untrusted certificate fails the handshake (' +
      Client.ErrorDescription(Error) + ')');
  finally
    Client.Free;
    Server.WaitFor;
    Check(Server.PeerClosed and (Server.PeerCloseCode = TransportCryptoError + 48),
      'the server gets CRYPTO_ERROR unknown_ca (0x130)');
    Server.Free;
    CloseEndpoint(Endpoint);
  end;
end;

procedure RunLoopbackTests;
begin
  TrustStore := CreateTrustStore;
  AddTrustedCertificate(TrustStore, @ServerCertificate[0], SizeOf(ServerCertificate));
  TestSuites;
  TestBulkAndLoss;
  TestRetry;
  TestKeyUpdates;
  TestPathMtu;
  TestVersionNegotiation;
  TestStatelessResetAndClose;
  TestUntrustedCertificate;
  FreeTrustStore(TrustStore);
end;

end.
