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
  THttpClient over a connector that joins pipes to the small servers
  (an origin whose host starts with "h2." gets the HTTP/2 server, the
  others the HTTP/1.1 one): keep-alive and a kept connection the server
  closed, content decoding, redirects with their method rules and
  their limit, cookies, the cache (fresh, revalidated with a 304), Basic
  authentication, Alt-Svc, HTTP/2 shared by fetch tasks on threads, and
  canceling a task.
}
unit HttpTest.Client;

{$mode objfpc}
{$H+}

interface

procedure TestClient;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  HttpTest.Http1Server,
  HttpTest.Http2Server,
  HttpTest.Pipes,
  Http.AltServices,
  Http.Authentication,
  Http.BodySinks,
  Http.Cache,
  Http.Client,
  Http.Connections,
  Http.Connectors,
  Http.Cookies,
  Http.FetchTasks,
  Http.Messages,
  Http.Observers,
  Http.RequestBodies,
  Http.Results,
  Http.Transports,
  Url.Parser,
  Url.Records;

type
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

  TCountingObserver = class(THttpClientObserver)
  public
    Reused, Stale, Sent: Integer;
    procedure ReusingConnection(const HostText: string; Port: Word); override;
    procedure RequestSent; override;
    procedure StaleConnection(AfterRequestSent: Boolean); override;
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
  Server: TThread;
begin
  if Copy(Url.Host.Name, 1, 3) = 'h2.' then
  begin
    Pair := TPipePair.Create('h2');
    Server := THttp2TestServer.Create(Pair.Server);
  end
  else
  begin
    Pair := TPipePair.Create('http/1.1');
    Server := THttp1TestServer.Create(Pair.Server);
  end;
  EnterCriticalSection(FLock);
  FPairs.Add(Pair);
  FServers.Add(Server);
  Inc(FConnects);
  LeaveCriticalSection(FLock);
  Transport := Pair.Client;
  Result := HttpOk;
end;

procedure TCountingObserver.ReusingConnection(const HostText: string; Port: Word);
begin
  Inc(Reused);
end;

procedure TCountingObserver.RequestSent;
begin
  Inc(Sent);
end;

procedure TCountingObserver.StaleConnection(AfterRequestSent: Boolean);
begin
  Inc(Stale);
end;

function MakeRequest(const Method, Text: string): THttpRequest;
begin
  if not THttpRequest.FromText(Method, Text, Result) then
    raise Exception.Create('bad test URL ' + Text);
end;

function FetchText(Client: THttpClient; Request: THttpRequest; out Response: THttpResponse;
  out Outcome: THttpResult): string;
var
  Sink: THttpMemorySink;
begin
  Sink := THttpMemorySink.Create;
  try
    Outcome := Client.Fetch(Request, Sink, Response);
    Result := Sink.Text;
  finally
    Sink.Free;
  end;
end;

{ GET Text: the content ('' on a failure), Status the status. }
function GetText(Client: THttpClient; const Text: string; out Status: Integer): string;
var
  Outcome: THttpResult;
begin
  Outcome := Client.Get(Text, Result, Status);
  if not HttpSucceeded(Outcome) then
    Result := 'FAILED: ' + Outcome.Text;
end;

procedure TestHttp1Client;
var
  Connector: TPipeConnector;
  Client: THttpClient;
  Observer: TCountingObserver;
  Status: Integer;
  Request: THttpRequest;
  Response: THttpResponse;
  Outcome: THttpResult;
  Body: string;
  Jar: TCookieJar;
  Cache: THttpCache;
  Authenticator: TAuthenticator;
  Services: THttpAltServiceArray;
  First: string;
begin
  Connector := TPipeConnector.Create;
  Client := THttpClient.Create(DefaultClientSettings, Connector, False);
  Observer := TCountingObserver.Create;
  Jar := TCookieJar.Create;
  Cache := THttpCache.Create;
  Authenticator := TAuthenticator.Create('user', 'secret', True);
  Client.ObserverObject := Observer;
  try
    Check(GetText(Client, 'https://one.test/hello', Status) = 'hello', 'client: GET');
    Check(GetText(Client, 'https://one.test/count', Status) = '2', 'client: the connection kept for the next request');
    Check((Observer.Reused = 1) and (Connector.Connects = 1), 'client: one connection, reused once');
    Check(GetText(Client, 'https://one.test/gzip', Status) = 'hello hello hello hello'#10, 'client: gzip decoded');
    Check(GetText(Client, 'https://one.test/deflate', Status) = 'deflated text'#10, 'client: deflate decoded');
    Check(GetText(Client, 'https://one.test/br', Status) = 'brotli text brotli text'#10, 'client: br decoded');
    Check(GetText(Client, 'https://one.test/zstd', Status) = 'zstandard text zstandard text'#10,
      'client: zstd decoded');
    Check((GetText(Client, 'https://one.test/redirect', Status) = 'hello') and (Status = 200),
      'client: a 302 followed');
    Request := MakeRequest('POST', 'https://one.test/see-other');
    Request.SetBody(THttpBytesBody.Create('data'));
    Body := FetchText(Client, Request, Response, Outcome);
    Check((Body = 'GET ') and (Request.Method = 'GET') and (Request.Body = nil) and (Length(Response.UrlList) = 2),
      'client: 303 turns a POST into a GET without content');
    Response.Free;
    Request.Free;
    Request := MakeRequest('POST', 'https://one.test/keep');
    Request.SetBody(THttpBytesBody.Create('data'));
    Body := FetchText(Client, Request, Response, Outcome);
    Check(Body = 'POST data', 'client: 307 keeps the method and the content');
    Response.Free;
    Request.Free;
    Request := MakeRequest('GET', 'https://one.test/loop');
    Body := FetchText(Client, Request, Response, Outcome);
    Check(Outcome.Code = HttpTooManyRedirects, 'client: a redirect loop stops at the limit');
    Response.Free;
    Request.Free;
    Client.Cookies := Jar;
    GetText(Client, 'https://one.test/cookie', Status);
    Check(GetText(Client, 'https://one.test/cookie-show', Status) = 'id=42',
      'client: a cookie kept and sent, a __Host- cookie with a Domain refused');
    Client.Cache := Cache;
    First := GetText(Client, 'https://one.test/cache', Status);
    Check(Copy(First, 1, 7) = 'cached ', 'client: a cacheable response');
    Request := MakeRequest('GET', 'https://one.test/cache');
    Body := FetchText(Client, Request, Response, Outcome);
    Check((Body = First) and Response.FromCache, 'client: then served from the cache');
    Response.Free;
    Request.Free;
    GetText(Client, 'https://one.test/stale', Status);
    Request := MakeRequest('GET', 'https://one.test/stale');
    Body := FetchText(Client, Request, Response, Outcome);
    Check((Body = 'revalidated body') and Response.FromCache and (Response.Status = 200),
      'client: a no-cache response revalidated with a 304');
    Response.Free;
    Request.Free;
    Client.Cache := nil;
    Check(GetText(Client, 'https://one.test/auth', Status) = 'who?', 'client: 401 without an authenticator');
    Client.Authenticator := Authenticator;
    Check((GetText(Client, 'https://one.test/auth', Status) = 'welcome') and (Status = 200),
      'client: 401 answered with Basic credentials');
    GetText(Client, 'https://one.test/alt-svc', Status);
    Services := Client.AltServices.ServicesOf('https://one.test:443', RuntimeUnixTime);
    Check((Length(Services) = 2) and (Services[0].ProtocolId = 'h3') and (Services[0].Port = 8443) and
      (Services[1].Host = 'alt.example'), 'client: Alt-Svc kept');
    Observer.Stale := 0;
    Check(GetText(Client, 'https://two.test/close-after', Status) <> '', 'client: a server that closes when idle');
    Check(GetText(Client, 'https://two.test/hello', Status) = 'hello', 'client: the request goes again on a new connection');
    Check(Observer.Stale = 1, 'client: the closed kept connection noticed');
  finally
    Client.Free;
    Connector.Free;
    Observer.Free;
    Jar.Free;
    Cache.Free;
    Authenticator.Free;
  end;
end;

type
  TTaskCollector = class
  public
    Lock: TRTLCriticalSection;
    Texts: array[0..9] of string;
    Heads: Integer;
    Done: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Head(Task: THttpFetchTask; Response: THttpResponse);
    procedure Data(Task: THttpFetchTask; Buffer: Pointer; Count: PtrUInt);
    procedure Finished(Task: THttpFetchTask; constref Outcome: THttpResult);
  end;

constructor TTaskCollector.Create;
begin
  inherited Create;
  InitCriticalSection(Lock);
end;

destructor TTaskCollector.Destroy;
begin
  DoneCriticalSection(Lock);
  inherited Destroy;
end;

procedure TTaskCollector.Head(Task: THttpFetchTask; Response: THttpResponse);
begin
  EnterCriticalSection(Lock);
  Inc(Heads);
  LeaveCriticalSection(Lock);
end;

procedure TTaskCollector.Data(Task: THttpFetchTask; Buffer: Pointer; Count: PtrUInt);
var
  Piece: string;
begin
  SetString(Piece, PChar(Buffer), Count);
  EnterCriticalSection(Lock);
  Texts[Task.Tag] := Texts[Task.Tag] + Piece;
  LeaveCriticalSection(Lock);
end;

procedure TTaskCollector.Finished(Task: THttpFetchTask; constref Outcome: THttpResult);
begin
  EnterCriticalSection(Lock);
  if HttpSucceeded(Outcome) then
    Inc(Done);
  LeaveCriticalSection(Lock);
end;

procedure TestHttp2Client;
var
  Connector: TPipeConnector;
  Client: THttpClient;
  Collector: TTaskCollector;
  Tasks: array[0..7] of THttpFetchTask;
  Index: Integer;
  AllGood: Boolean;
  Status: Integer;
  Held: THttpFetchTask;
  Started: QWord;
  Cache: THttpCache;
  Request: THttpRequest;
  Response: THttpResponse;
  Outcome: THttpResult;
begin
  Connector := TPipeConnector.Create;
  Client := THttpClient.Create(DefaultClientSettings, Connector, False);
  Collector := TTaskCollector.Create;
  Cache := THttpCache.Create;
  try
    Check(GetText(Client, 'https://h2.test/hello', Status) = 'hello', 'client: GET over HTTP/2');
    for Index := 0 to High(Tasks) do
      Tasks[Index] := THttpFetchTask.Create(Client, MakeRequest('GET', 'https://h2.test/hello'), @Collector.Head,
        @Collector.Data, @Collector.Finished, Index);
    for Index := 0 to High(Tasks) do
      Tasks[Index].WaitFor;
    AllGood := (Collector.Done = 8) and (Collector.Heads = 8);
    for Index := 0 to High(Tasks) do
    begin
      if Collector.Texts[Index] <> 'hello' then
        AllGood := False;
      Tasks[Index].Free;
    end;
    Check(AllGood, 'client: eight fetch tasks at once');
    Check(Connector.Connects = 1, 'client: all of them on one HTTP/2 connection');
    Check(GetText(Client, 'https://h2.test/redirect', Status) = 'hello', 'client: a redirect over HTTP/2');
    Client.Cache := Cache;
    GetText(Client, 'https://h2.test/cache', Status);
    Request := MakeRequest('GET', 'https://h2.test/cache');
    Request.CacheMode := CacheModeNoCache;
    FetchText(Client, Request, Response, Outcome);
    Check(Response.FromCache and (Response.Status = 200), 'client: revalidated over HTTP/2');
    Response.Free;
    Request.Free;
    Held := THttpFetchTask.Create(Client, MakeRequest('GET', 'https://h2.test/hold'), nil, nil, nil, 0);
    Sleep(100);
    Started := GetTickCount64;
    Held.Cancel;
    Held.WaitFor;
    Check((Held.Outcome.Code = HttpCanceled) and (GetTickCount64 - Started < 3000), 'client: a task canceled');
    Held.Free;
    Check(GetText(Client, 'https://h2.test/hello', Status) = 'hello', 'client: the connection goes on after a cancel');
  finally
    Client.Free;
    Connector.Free;
    Collector.Free;
    Cache.Free;
  end;
end;

procedure TestClient;
begin
  TestHttp1Client;
  TestHttp2Client;
end;

end.
