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
  HTTP/3: frames and SETTINGS on their own, then libquic's HTTP/3 client
  against the test's HTTP/3 server over loopback UDP: GET, a large
  body, POST with trailers, empty and interim responses, a head that
  waits for the QPACK encoder stream, several requests at once, a
  malformed response, a reset request, GOAWAY, and the close.
}
unit QuicTest.Http3;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunHttp3Tests;

implementation

uses
  SysUtils,
  TestChecks,
  Tls.TrustStore,
  Http3.Connections,
  Http3.Constants,
  Http3.FrameParser,
  Http3.Frames,
  Http3.Requests,
  Qpack.StaticTable,
  Quic.Connections,
  Quic.ConnectionState,
  Quic.DatagramTransports,
  Quic.Errors,
  QuicTest.HostSockets,
  QuicTest.Http3Server,
  QuicTest.Server;

{$I QuicTest.Generated.inc}

procedure TestFrames;
var
  Settings, Decoded: THttp3Settings;
  Frame: TBytes;
  Parser: THttp3FrameParser;
  FrameType: QWord;
  Data: PByte;
  Length: PtrUInt;
  Bytes: TByteArray;
  Index: Integer;
  Body: string;
  Outcome: THttp3ParseResult;
begin
  Settings.QpackMaxTableCapacity := 4096;
  Settings.QpackBlockedStreams := 16;
  Settings.MaxFieldSectionSize := 65536;
  Frame := EncodeSettings(Settings);
  Check(Frame[0] = Http3FrameSettings, 'SETTINGS frame type');
  Check(DecodeSettings(@Frame[2], System.Length(Frame) - 2, Decoded) and (Decoded.QpackMaxTableCapacity = 4096) and
    (Decoded.QpackBlockedStreams = 16) and (Decoded.MaxFieldSectionSize = 65536), 'SETTINGS round trip');
  Bytes := HexToBytes('0101' + '0102');
  Check(not DecodeSettings(@Bytes[0], System.Length(Bytes), Decoded), 'SETTINGS: a setting twice');
  Bytes := HexToBytes('0201');
  Check(not DecodeSettings(@Bytes[0], System.Length(Bytes), Decoded), 'SETTINGS: HTTP/2''s 0x02 refused');
  Bytes := HexToBytes('2105' + '0607');
  Check(DecodeSettings(@Bytes[0], System.Length(Bytes), Decoded) and (Decoded.MaxFieldSectionSize = 7),
    'SETTINGS: unknown setting passed over');
  Check(FrameTypeIsReserved($21) and FrameTypeIsReserved($21 + $1F * 3) and not FrameTypeIsReserved($22),
    'reserved frame types');

  { A stream fed one byte at a time: HEADERS, a reserved frame, DATA. }
  Bytes := HexToBytes('0103aabbcc' + '2104deadbeef' + '0005' + '68656c6c6f' + '0000');
  Parser := THttp3FrameParser.Create(1024);
  try
    Body := '';
    Index := 0;
    while Index <= High(Bytes) do
    begin
      Parser.Append(@Bytes[Index], 1);
      Inc(Index);
      repeat
        Outcome := Parser.Next(FrameType, Data, Length);
        if Outcome = ParseFrame then
          Check((FrameType = Http3FrameHeaders) and (Length = 3) and (Data[0] = $AA), 'parser: HEADERS whole');
        if Outcome = ParseData then
          Body := Body + Chr(Data[0]);
      until Outcome = ParseNeedMore;
    end;
    Check(Body = 'hello', 'parser: DATA streams through, the reserved frame is skipped');
    Check(Parser.AtFrameBoundary, 'parser: at a frame boundary');
    Bytes := HexToBytes('0144');
    Parser.Append(@Bytes[0], 2);
    Check(Parser.Next(FrameType, Data, Length) = ParseNeedMore, 'parser: half a frame waits');
    Check(not Parser.AtFrameBoundary, 'parser: not at a frame boundary');
  finally
    Parser.Free;
  end;
  Parser := THttp3FrameParser.Create(16);
  try
    Bytes := HexToBytes('0120');
    Parser.Append(@Bytes[0], 2);
    Check(Parser.Next(FrameType, Data, Length) = ParseFrameTooLarge, 'parser: HEADERS over the limit');
  finally
    Parser.Free;
  end;
end;

type
  TClientPair = record
    Server: TTestServer;
    Endpoint: TTestEndpoint;
    Store: PTlsTrustStore;
    Quic: TQuicConnection;
    Http: THttp3ClientConnection;
  end;

function StartPair(out Pair: TClientPair): Boolean;
var
  Options: TQuicConnectionOptions;
  Transport: TQuicDatagramTransport;
  Error: LongInt;
begin
  Pair := Default(TClientPair);
  Pair.Server := TTestServer.Create(False, ServeHttp3);
  InstallHttp3Server(Pair.Server);
  Pair.Server.Start;
  OpenEndpoint(Pair.Endpoint, False);
  SetPeerPort(Pair.Endpoint, Pair.Server.Endpoint.Port);
  MakeTransport(@Pair.Endpoint, Transport);
  Pair.Store := CreateTrustStore;
  AddTrustedCertificate(Pair.Store, @ServerCertificate[0], SizeOf(ServerCertificate));
  Options := Default(TQuicConnectionOptions);
  Options.ServerName := 'localhost';
  Options.ApplicationProtocol := 'h3';
  Options.TrustStore := Pair.Store;
  Options.VerifyCertificates := True;
  Options.VerificationTime := Trunc((Now - EncodeDate(1970, 1, 1)) * 86400);
  Options.IdleTimeout := 5000;
  Pair.Quic := TQuicConnection.Create(Transport, Options);
  Pair.Quic.Timeout := 10000;
  Error := Pair.Quic.Connect;
  Check(Error = QuicErrorNone, 'HTTP/3: QUIC handshake (' + Pair.Quic.ErrorDescription(Error) + ')');
  Pair.Http := THttp3ClientConnection.Create(Pair.Quic, False);
  Result := (Error = QuicErrorNone) and (Pair.Http.Start = QuicErrorNone);
end;

procedure StopPair(var Pair: TClientPair);
begin
  Pair.Http.Free;
  Pair.Quic.Free;
  Pair.Server.WaitFor;
  Check(Pair.Server.Failure = '', 'HTTP/3: the server had no trouble ' + Pair.Server.Failure);
  Check(Pair.Server.PeerClosed and Pair.Server.PeerCloseIsApplication and (Pair.Server.PeerCloseCode = Http3NoError),
    'the server sees H3_NO_ERROR');
  Pair.Server.Free;
  CloseEndpoint(Pair.Endpoint);
  FreeTrustStore(Pair.Store);
end;

function Get(Pair: TClientPair; const Path: string): THttp3Request;
var
  Headers: TQpackFieldList;
begin
  Headers := nil;
  AddField(Headers, 'user-agent', 'QuicTest');
  AddField(Headers, 'accept', '*/*');
  Result := THttp3Request.Create(Pair.Http, 'GET', 'https', 'localhost', Path, Headers, True);
end;

procedure TestRequests(Pair: TClientPair);
var
  Request: THttp3Request;
  Requests: array[0..4] of THttp3Request;
  Body: string;
  Error: LongInt;
  Index: Integer;
  Good: Boolean;
  Headers: TQpackFieldList;
  Upload: array of Byte;
  Deadline: Int64;
begin
  Request := Get(Pair, '/hello');
  try
    Error := Request.ReadHead;
    Check((Error = 0) and (Request.Status = 200), 'GET /hello: 200');
    Check(FieldValue(Request.Headers, 'content-type') = 'text/plain', 'GET /hello: content-type');
    Check((Request.ReadAll(Body) = 0) and (Body = 'Hello, HTTP/3!'), 'GET /hello: the body');
  finally
    Request.Free;
  end;
  Check(Pair.Http.SettingsReceived and (Pair.Http.PeerSettings.QpackMaxTableCapacity = 4096),
    'the server''s SETTINGS arrived');

  Request := Get(Pair, '/size/1000000');
  try
    Check((Request.ReadAll(Body) = 0) and (Request.Status = 200) and (Length(Body) = 1000000), 'GET 1 MB');
    Good := True;
    for Index := 0 to Length(Body) - 1 do
      if Ord(Body[Index + 1]) <> (Index * 7 + 3) and $FF then
        Good := False;
    Check(Good, 'GET 1 MB: every byte right');
  finally
    Request.Free;
  end;

  Headers := nil;
  AddField(Headers, 'content-type', 'application/octet-stream');
  Request := THttp3Request.Create(Pair.Http, 'POST', 'https', 'localhost', '/echo', Headers, False);
  try
    Upload := nil;
    SetLength(Upload, 300000);
    for Index := 0 to High(Upload) do
      Upload[Index] := Byte(Index mod 251);
    Check(Request.WriteBody(@Upload[0], 100000) = 100000, 'POST: body part 1');
    Check(Request.WriteBody(@Upload[100000], 200000) = 200000, 'POST: body part 2');
    Check(Request.FinishRequest = 0, 'POST: request ended');
    Error := Request.ReadAll(Body);
    Check((Error = 0) and (Length(Body) = 300000) and (CompareByte(Body[1], Upload[0], 300000) = 0),
      'POST /echo: the body comes back');
    Check(FieldValue(Request.Trailers, 'x-body-length') = '300000', 'POST /echo: trailers');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/status/204');
  try
    Check((Request.ReadAll(Body) = 0) and (Request.Status = 204) and (Body = ''), 'a 204 without a body');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/interim');
  try
    Check((Request.ReadAll(Body) = 0) and (Request.Status = 200) and (Request.InterimCount = 1) and
      (Request.InterimStatus[0] = 103) and (Body = 'ok'), 'a 103 before the 200');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/dynamic');
  try
    Error := Request.ReadAll(Body);
    Check((Error = 0) and (Request.Status = 200) and (FieldValue(Request.Headers, 'x-dynamic') = 'yes') and
      (Body = 'dynamic'), 'a head that waits for the QPACK encoder stream (' + Pair.Http.ErrorDescription(Error) + ')');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/headers');
  try
    Check((Request.ReadAll(Body) = 0) and (Pos('user-agent: QuicTest', Body) > 0) and
      (Pos(':method: GET', Body) > 0) and (Pos(':authority: localhost', Body) > 0), 'the request''s fields arrive');
  finally
    Request.Free;
  end;

  { Several at once, read in the other order. }
  for Index := 0 to 4 do
    Requests[Index] := Get(Pair, '/size/' + IntToStr(20000 + Index));
  Good := True;
  for Index := 4 downto 0 do
  begin
    if (Requests[Index].ReadAll(Body) <> 0) or (Length(Body) <> 20000 + Index) then
      Good := False;
    Requests[Index].Free;
  end;
  Check(Good, 'five requests at once');

  Request := Get(Pair, '/malformed');
  try
    Check(Request.ReadHead = Http3ErrorMalformedResponse, 'a four-digit :status is malformed');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/reset');
  try
    Error := Request.ReadHead;
    Check((Error = Http3ErrorRequestReset) and (Request.ResetCode = Http3RequestRejected),
      'a reset request: H3_REQUEST_REJECTED');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/missing');
  try
    Check((Request.ReadAll(Body) = 0) and (Request.Status = 404) and (Body = 'not found'), 'a 404');
  finally
    Request.Free;
  end;

  Request := Get(Pair, '/goaway');
  try
    Check((Request.ReadAll(Body) = 0) and (Body = 'ok'), 'the request before GOAWAY is answered');
  finally
    Request.Free;
  end;
  Deadline := QuicMilliseconds + 3000;
  while not Pair.Http.GoawayReceived and (QuicMilliseconds < Deadline) do
    Pair.Http.WaitForProgress(QuicMilliseconds + 50);
  Check(Pair.Http.GoawayReceived, 'GOAWAY arrives');
  Error := 0;
  try
    Get(Pair, '/hello').Free;
  except
    on Failure: EQuicError do
      Error := Failure.Code;
  end;
  Check(Error = Http3ErrorGoingAway, 'no request after GOAWAY');
  Pair.Http.Close;
end;

procedure RunHttp3Tests;
var
  Pair: TClientPair;
begin
  TestFrames;
  if StartPair(Pair) then
    TestRequests(Pair);
  StopPair(Pair);
end;

end.
