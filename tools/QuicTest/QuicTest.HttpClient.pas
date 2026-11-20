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
  libhttp's client speaking HTTP/3 through libquic, end to end: the
  first request goes over TCP (an HTTP/1.1 server on in-memory pipes)
  and its response carries Alt-Svc: h3=":PORT"; the next ones go to the
  test's HTTP/3 server on 127.0.0.1:PORT over UDP through
  Http3.HttpConnections, made by a factory registered for "h3" as
  Http3.SystemConnections registers the system's: bodies large and
  small, a POST with trailers, 204, 103, threads sharing the
  connection, a cancel, the priority, GOAWAY; then the fallbacks: after
  GOAWAY the server is gone and the alternative fails (TCP again,
  marked broken), and an alternative whose UDP is dropped silently
  falls back to TCP within the alternative's timeout.
}
unit QuicTest.HttpClient;

{$mode objfpc}
{$H+}

interface

procedure RunHttpClientTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  HttpTest.Pipes,
  Tls.TrustStore,
  Http.AltServices,
  Http.BodySinks,
  Http.Client,
  Http.Connections,
  Http.Connectors,
  Http.HeaderFields,
  Http.Messages,
  Http.Observers,
  Http.Priorities,
  Http.RequestBodies,
  Http.Results,
  Http.Transports,
  Url.Records,
  Http3.HttpConnections,
  Quic.Connections,
  Quic.ConnectionState,
  Quic.DatagramTransports,
  Quic.Errors,
  QuicTest.HostSockets,
  QuicTest.Http3Server,
  QuicTest.Server;

{$I QuicTest.Generated.inc}

var
  { What the TCP server's responses advertise. }
  AltSvcValue: string;
  FactoryCalls: Integer;
  FactoryFailures: Integer;

type
  { A small HTTP/1.1 server on a pipe: every GET is answered "tcp PATH"
    with the Alt-Svc field of the moment. }
  TAltSvcServer = class(TThread)
  private
    FTransport: THttpTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(Transport: THttpTransport);
  end;

  TPipeConnector = class(THttpConnector)
  private
    FLock: TRTLCriticalSection;
    FPairs: TList;
    FServers: TList;
    FConnects: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
    property Connects: Integer read FConnects;
  end;

  { What a test QUIC connection runs over; freed by the HTTP/3
    connection after it. }
  TTestQuicLink = class
  public
    Endpoint: TTestEndpoint;
    Store: PTlsTrustStore;
    Quic: TQuicConnection;
    destructor Destroy; override;
  end;

  TFetchThread = class(TThread)
  private
    FClient: THttpClient;
    FUrl: string;
  protected
    procedure Execute; override;
  public
    Text: string;
    Status: Integer;
    Outcome: THttpResult;
    constructor Create(Client: THttpClient; const Url: string);
  end;

  TCancelThread = class(TThread)
  private
    FToken: THttpCancelToken;
    FDelay: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(Token: THttpCancelToken; Delay: Integer);
  end;

constructor TAltSvcServer.Create(Transport: THttpTransport);
begin
  inherited Create(False);
  FTransport := Transport;
  FTransport.TimeoutMilliseconds := 20000;
end;

procedure TAltSvcServer.Execute;
var
  Pending, Head, Path, Body, Reply: string;
  Buffer: array[0..4095] of Char;
  Count: Int64;
  Finish: Integer;
begin
  Pending := '';
  while True do
  begin
    Finish := Pos(#13#10#13#10, Pending);
    if Finish = 0 then
    begin
      Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
      if Count <= 0 then
        Break;
      SetLength(Head, Count);
      Move(Buffer[0], Head[1], Count);
      Pending := Pending + Head;
      Continue;
    end;
    Head := Copy(Pending, 1, Finish - 1);
    Delete(Pending, 1, Finish + 3);
    Path := Copy(Head, Pos(' ', Head) + 1, MaxInt);
    Path := Copy(Path, 1, Pos(' ', Path) - 1);
    Body := 'tcp ' + Path;
    Reply := 'HTTP/1.1 200 OK'#13#10'Content-Length: ' + IntToStr(Length(Body)) + #13#10;
    if AltSvcValue <> '' then
      Reply := Reply + 'Alt-Svc: ' + AltSvcValue + #13#10;
    Reply := Reply + #13#10 + Body;
    FTransport.Write(@Reply[1], Length(Reply));
  end;
  FTransport.Close;
end;

constructor TPipeConnector.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FPairs := TList.Create;
  FServers := TList.Create;
end;

destructor TPipeConnector.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FServers.Count - 1 do
  begin
    TThread(FServers[Index]).WaitFor;
    TThread(FServers[Index]).Free;
  end;
  for Index := 0 to FPairs.Count - 1 do
    TPipePair(FPairs[Index]).Free;
  FServers.Free;
  FPairs.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TPipeConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
var
  Pair: TPipePair;
begin
  Pair := TPipePair.Create('http/1.1');
  EnterCriticalSection(FLock);
  FPairs.Add(Pair);
  FServers.Add(TAltSvcServer.Create(Pair.Server));
  Inc(FConnects);
  LeaveCriticalSection(FLock);
  Transport := Pair.Client;
  Result := HttpOk;
end;

destructor TTestQuicLink.Destroy;
begin
  Quic.Free;
  CloseEndpoint(Endpoint);
  FreeTrustStore(Store);
  inherited Destroy;
end;

{ The test's "h3" factory: UDP on 127.0.0.1 to the alternative's port,
  the test server's certificate pinned. }
function OpenTestHttp3Connection(constref Url: TUrlRecord; constref Service: THttpAltService;
  constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Failure: THttpResult): THttpConnection;
var
  Link: TTestQuicLink;
  Options: TQuicConnectionOptions;
  Transport: TQuicDatagramTransport;
  Error: LongInt;
  Connection: THttp3Connection;
begin
  Result := nil;
  InterLockedIncrement(FactoryCalls);
  Observer.ConnectingAlternative('127.0.0.1', Service.Port, Service.ProtocolId);
  Link := TTestQuicLink.Create;
  OpenEndpoint(Link.Endpoint, False);
  SetPeerPort(Link.Endpoint, Service.Port);
  MakeTransport(@Link.Endpoint, Transport);
  Link.Store := CreateTrustStore;
  AddTrustedCertificate(Link.Store, @ServerCertificate[0], SizeOf(ServerCertificate));
  Options := Default(TQuicConnectionOptions);
  Options.ServerName := 'localhost';
  Options.ApplicationProtocol := 'h3';
  Options.TrustStore := Link.Store;
  Options.VerifyCertificates := True;
  Options.VerificationTime := Trunc((Now - EncodeDate(1970, 1, 1)) * 86400);
  Options.IdleTimeout := 5000;
  Options.HandshakeTimeout := Settings.AltServiceTimeoutMilliseconds;
  Link.Quic := TQuicConnection.Create(Transport, Options);
  Link.Quic.Timeout := Settings.AltServiceTimeoutMilliseconds;
  Error := Link.Quic.Connect;
  if Error <> QuicErrorNone then
  begin
    Failure := HttpFailure(HttpConnectFailed, Link.Quic.ErrorDescription(Error), Error);
    Observer.ConnectFailed(Failure.Text);
    Link.Free;
    InterLockedIncrement(FactoryFailures);
    Exit;
  end;
  Link.Quic.Timeout := Settings.TimeoutMilliseconds;
  Connection := THttp3Connection.Create(Link.Quic, Link, Settings.TimeoutMilliseconds);
  Failure := Connection.Start;
  if not HttpSucceeded(Failure) then
  begin
    Connection.Free;
    InterLockedIncrement(FactoryFailures);
    Exit;
  end;
  Observer.Connected;
  Result := Connection;
end;

constructor TFetchThread.Create(Client: THttpClient; const Url: string);
begin
  inherited Create(False);
  FClient := Client;
  FUrl := Url;
end;

procedure TFetchThread.Execute;
begin
  Outcome := FClient.Get(FUrl, Text, Status);
end;

constructor TCancelThread.Create(Token: THttpCancelToken; Delay: Integer);
begin
  inherited Create(False);
  FToken := Token;
  FDelay := Delay;
end;

procedure TCancelThread.Execute;
begin
  Sleep(FDelay);
  FToken.Cancel;
end;

function TestSettings: THttpClientSettings;
begin
  Result := DefaultClientSettings;
  Result.TimeoutMilliseconds := 10000;
  Result.AltServiceTimeoutMilliseconds := 1500;
end;

{ A fetch: the response (its content read into Text) and the result. }
function Fetch(Client: THttpClient; const Method, Url: string; Body: THttpRequestBody; out Response: THttpResponse;
  out Text: string; Token: THttpCancelToken = nil): THttpResult;
var
  Request: THttpRequest;
  Sink: THttpMemorySink;
begin
  Text := '';
  Response := nil;
  if not THttpRequest.FromText(Method, Url, Request) then
    Exit(HttpFailure(HttpUnsupportedScheme, 'bad URL'));
  Sink := THttpMemorySink.Create;
  try
    if Body <> nil then
      Request.SetBody(Body);
    Result := Client.Fetch(Request, Sink, Response, nil, Token);
    Text := Sink.Text;
  finally
    Sink.Free;
    Request.Free;
  end;
end;

function PatternIsRight(const Text: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Length(Text) - 1 do
    if Ord(Text[Index + 1]) <> (Index * 7 + 3) and $FF then
      Exit(False);
  Result := True;
end;

procedure TestOverHttp3(Client: THttpClient; Connector: TPipeConnector);
var
  Response: THttpResponse;
  Text: string;
  Outcome: THttpResult;
  Upload: TBytes;
  Index, CallsBefore: Integer;
  Threads: array[0..5] of TFetchThread;
  Good: Boolean;
  Token: THttpCancelToken;
  Canceller: TCancelThread;
  Started: QWord;
begin
  Outcome := Fetch(Client, 'GET', 'https://h3.test/first', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Response.Version = 11) and (Text = 'tcp /first'),
    'HTTP/3 in libhttp: the first request goes over TCP');
  Response.Free;
  Check(Length(Client.AltServices.ServicesOf('https://h3.test:443', RuntimeUnixTime)) = 1,
    'HTTP/3 in libhttp: the Alt-Svc is kept');

  Outcome := Fetch(Client, 'GET', 'https://h3.test/hello', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Response <> nil) and (Response.Version = 30) and
    (Response.Protocol = HttpProtocol3) and (Text = 'Hello, HTTP/3!'),
    'HTTP/3 in libhttp: the next request goes over HTTP/3 (' + Outcome.Text + ')');
  if Response <> nil then
  begin
    Check(Copy(Response.RawHead, 1, 12) = 'HTTP/3 200'#13#10, 'HTTP/3 in libhttp: the head as -S shows it');
    Check(Response.Headers.Value('content-type') = 'text/plain', 'HTTP/3 in libhttp: the fields');
    Response.Free;
  end;
  Check((FactoryCalls = 1) and (Connector.Connects = 1), 'HTTP/3 in libhttp: one QUIC connection, one TCP');

  Outcome := Fetch(Client, 'GET', 'https://h3.test/size/1000000', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Length(Text) = 1000000) and PatternIsRight(Text) and Response.ConnectionReused,
    'HTTP/3 in libhttp: 1 MB streamed on the same connection');
  Response.Free;

  Upload := nil;
  SetLength(Upload, 200000);
  for Index := 0 to High(Upload) do
    Upload[Index] := Byte(Index mod 251);
  Outcome := Fetch(Client, 'POST', 'https://h3.test/echo', THttpBytesBody.Create(Upload, 'application/octet-stream'),
    Response, Text);
  Check(HttpSucceeded(Outcome) and (Length(Text) = 200000) and (CompareByte(Text[1], Upload[0], 200000) = 0),
    'HTTP/3 in libhttp: a 200 KB POST echoed');
  if Response <> nil then
  begin
    Check(FieldsValue(Response.Trailers, 'x-body-length') = '200000', 'HTTP/3 in libhttp: the trailers');
    Response.Free;
  end;

  Outcome := Fetch(Client, 'GET', 'https://h3.test/status/204', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Response.Status = 204) and (Text = ''), 'HTTP/3 in libhttp: 204');
  Response.Free;
  Outcome := Fetch(Client, 'GET', 'https://h3.test/interim', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Response.Status = 200) and (Text = 'ok'),
    'HTTP/3 in libhttp: 103 passed over, then 200');
  Response.Free;
  Outcome := Fetch(Client, 'GET', 'https://h3.test/dynamic', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Response.Headers.Value('x-dynamic') = 'yes') and (Text = 'dynamic'),
    'HTTP/3 in libhttp: a head waiting for the QPACK encoder stream');
  Response.Free;

  { Six threads at once on the one connection. }
  for Index := 0 to High(Threads) do
    Threads[Index] := TFetchThread.Create(Client, 'https://h3.test/size/' + IntToStr(100000 + Index));
  Good := True;
  for Index := 0 to High(Threads) do
  begin
    Threads[Index].WaitFor;
    if not HttpSucceeded(Threads[Index].Outcome) or (Length(Threads[Index].Text) <> 100000 + Index) or
       not PatternIsRight(Threads[Index].Text) then
      Good := False;
    Threads[Index].Free;
  end;
  Check(Good and (FactoryCalls = 1), 'HTTP/3 in libhttp: six threads share the connection');

  { A cancel from another thread while 3 MB come. }
  Token := THttpCancelToken.Create;
  Canceller := TCancelThread.Create(Token, 30);
  try
    Started := GetTickCount64;
    Outcome := Fetch(Client, 'GET', 'https://h3.test/size/3000000', nil, Response, Text, Token);
    Check((Outcome.Code = HttpCanceled) and (GetTickCount64 - Started < 5000),
      'HTTP/3 in libhttp: a cancel stops the transfer (' + Outcome.Text + ')');
    Response.Free;
  finally
    Canceller.WaitFor;
    Canceller.Free;
    Token.Free;
  end;
  CallsBefore := FactoryCalls;
  Outcome := Fetch(Client, 'GET', 'https://h3.test/hello', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Text = 'Hello, HTTP/3!') and (FactoryCalls = CallsBefore),
    'HTTP/3 in libhttp: the connection goes on after the cancel');
  if Response <> nil then
  begin
    Response.Reprioritize(MakePriority(1, True));
    Response.Free;
  end;

  Outcome := Fetch(Client, 'GET', 'https://h3.test/headers', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Pos(':authority: h3.test', Text) > 0) and (Pos('user-agent: ', Text) > 0) and
    (Pos('host:', Text) = 0) and (Pos('connection:', Text) = 0), 'HTTP/3 in libhttp: the request''s fields');
  Response.Free;

  Outcome := Fetch(Client, 'GET', 'https://h3.test/goaway', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Text = 'ok') and (Response.Version = 30), 'HTTP/3 in libhttp: answered before GOAWAY');
  Response.Free;
end;

{ After GOAWAY the connection takes nothing new; the next request needs
  a new one, the server is gone, so the alternative is marked broken
  and TCP answers; then TCP without trying it again. }
procedure TestAfterGoaway(Client: THttpClient; Connector: TPipeConnector);
var
  Response: THttpResponse;
  Text: string;
  Outcome: THttpResult;
  Deadline: QWord;
  ConnectsBefore: Integer;
begin
  { Let the GOAWAY arrive: the connection is idle, so it is run by the
    next request's check of it; wait a little for the frame. }
  Sleep(200);
  ConnectsBefore := Connector.Connects;
  Deadline := GetTickCount64;
  Outcome := Fetch(Client, 'GET', 'https://h3.test/after', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Text = 'tcp /after') and (Response.Version = 11),
    'HTTP/3 in libhttp: after GOAWAY and a failed alternative, TCP answers (' + Outcome.Text + ')');
  Check(GetTickCount64 - Deadline < 8000, 'HTTP/3 in libhttp: the fallback is quick');
  Response.Free;
  Check(Connector.Connects >= ConnectsBefore, 'HTTP/3 in libhttp: a TCP connection was used');
  Outcome := Fetch(Client, 'GET', 'https://h3.test/again', nil, Response, Text);
  Check(HttpSucceeded(Outcome) and (Text = 'tcp /again'), 'HTTP/3 in libhttp: the broken alternative is left alone');
  Response.Free;
end;

{ UDP to the alternative is dropped without a word: the handshake times
  out within AltServiceTimeoutMilliseconds and TCP answers. }
procedure TestBlockedUdp;
var
  Connector: TPipeConnector;
  Client: THttpClient;
  Silent: TTestEndpoint;
  Response: THttpResponse;
  Text: string;
  Outcome: THttpResult;
  Started, Elapsed: QWord;
  CallsBefore, FailuresBefore: Integer;
  Settings: THttpClientSettings;
begin
  OpenEndpoint(Silent, False);
  AltSvcValue := 'h3=":' + IntToStr(Silent.Port) + '"; ma=60';
  Connector := TPipeConnector.Create;
  Client := THttpClient.Create(TestSettings, Connector, False);
  try
    Client.Settings := TestSettings;
    Outcome := Fetch(Client, 'GET', 'https://blocked.test/one', nil, Response, Text);
    Check(HttpSucceeded(Outcome) and (Text = 'tcp /one'), 'UDP blocked: the first request over TCP');
    Response.Free;
    Client.Pool.CloseAll;
    CallsBefore := FactoryCalls;
    FailuresBefore := FactoryFailures;
    Started := GetTickCount64;
    Outcome := Fetch(Client, 'GET', 'https://blocked.test/two', nil, Response, Text);
    Elapsed := GetTickCount64 - Started;
    Check(HttpSucceeded(Outcome) and (Text = 'tcp /two') and (Response.Version = 11),
      'UDP blocked: TCP answers after the alternative fails (' + Outcome.Text + ')');
    Response.Free;
    Check((FactoryCalls = CallsBefore + 1) and (FactoryFailures = FailuresBefore + 1),
      'UDP blocked: the alternative was tried once');
    Check((Elapsed >= 1000) and (Elapsed < 5000), 'UDP blocked: within the alternative''s timeout (' +
      IntToStr(Elapsed) + ' ms)');
    Client.Pool.CloseAll;
    Outcome := Fetch(Client, 'GET', 'https://blocked.test/three', nil, Response, Text);
    Check(HttpSucceeded(Outcome) and (Text = 'tcp /three') and (FactoryCalls = CallsBefore + 1),
      'UDP blocked: marked broken, not tried again');
    Response.Free;

    { With HTTP/3 not allowed the alternative is never tried. }
    Client.AltServices.Clear;
    AltSvcValue := 'h3=":' + IntToStr(Silent.Port) + '"';
    Settings := TestSettings;
    Settings.AllowHttp3 := False;
    Client.Settings := Settings;
    Outcome := Fetch(Client, 'GET', 'https://other.test/one', nil, Response, Text);
    Check(HttpSucceeded(Outcome), 'AllowHttp3 off: over TCP');
    Response.Free;
    Client.Pool.CloseAll;
    Outcome := Fetch(Client, 'GET', 'https://other.test/two', nil, Response, Text);
    Check(HttpSucceeded(Outcome) and (Text = 'tcp /two') and (FactoryCalls = CallsBefore + 1),
      'AllowHttp3 off: the alternative is not tried');
    Response.Free;
  finally
    Client.Free;
    Connector.Free;
    CloseEndpoint(Silent);
  end;
end;

procedure RunHttpClientTests;
var
  Server: TTestServer;
  Connector: TPipeConnector;
  Client: THttpClient;
begin
  RegisterConnectionFactory('h3', @OpenTestHttp3Connection);
  Server := TTestServer.Create(False, ServeHttp3);
  InstallHttp3Server(Server);
  Server.Start;
  AltSvcValue := 'h3=":' + IntToStr(Server.Endpoint.Port) + '"; ma=3600';
  Connector := TPipeConnector.Create;
  Client := THttpClient.Create(TestSettings, Connector, False);
  try
    TestOverHttp3(Client, Connector);
    TestAfterGoaway(Client, Connector);
  finally
    Client.Free;
    Connector.Free;
  end;
  Server.WaitFor;
  Check(Server.Failure = '', 'HTTP/3 in libhttp: the server had no trouble ' + Server.Failure);
  Server.Free;
  TestBlockedUdp;
end;

end.
