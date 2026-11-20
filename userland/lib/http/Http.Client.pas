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
  The HTTP client, in two layers:

  Execute: one request on a connection of the pool (shared HTTP/2, an
  idle HTTP/1.1 one, or a new one from the connector, or from a
  registered factory when the origin advertised an alternative service
  such as h3), the response head returned and its content left to read.
  It adds User-Agent, Accept, Accept-Encoding, Cookie (from the jar)
  and Authorization (once the server asked), takes Set-Cookie into the
  jar and Alt-Svc into the alternative services, and sends the request
  again on a new connection when a kept one turned out closed, or a
  server refused it unprocessed (HTTP/2 REFUSED_STREAM, GOAWAY). An
  alternative service that fails (its factory finds no connection, or
  its new connection carries no answer to a request that may go again)
  is marked broken for five minutes and the request goes over TCP.

  Fetch: Execute with what Fetch (the WHATWG standard) adds - the
  cache (fresh responses served, stale ones revalidated, 304 freshened,
  unsafe requests invalidating), redirects (Http.Redirects' method and
  field rules, at most MaximumRedirects), 401 answered with credentials
  (once, again only for a stale nonce), content codings undone, and the
  content handed piece by piece to a sink as it arrives. OnHead sees
  the final head before any content and may stop the fetch; a cancel
  token stops it from another thread. Http.FetchTasks runs fetches on
  threads; Get is the one-line form.

  Thread safe: one client serves any number of threads.

  Plain Pascal over a connector, checked on the host by tools/HttpTest.
}
unit Http.Client;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.AltServices,
  Http.Authentication,
  Http.BodySinks,
  Http.Cache,
  Http.ConnectionPool,
  Http.Connections,
  Http.Connectors,
  Http.Cookies,
  Http.Messages,
  Http.Observers,
  Http.Results,
  Url.Records;

type
  { Unix seconds, for cookies and the cache. }
  THttpClock = function: Int64;

  { The final head arrived; False stops the fetch (HttpCanceled). }
  THttpHeadEvent = function(Response: THttpResponse): Boolean of object;

  THttpCancelToken = class
  private
    FLock: TRTLCriticalSection;
    FCanceled: Boolean;
    FResponse: THttpResponse;
    FExchange: THttpExchange;
  public
    constructor Create;
    destructor Destroy; override;
    { From any thread: the fetch stops at once. }
    procedure Cancel;
    procedure Track(Response: THttpResponse);
    procedure TrackExchange(Exchange: THttpExchange);
    procedure Untrack;
    property Canceled: Boolean read FCanceled;
  end;

  THttpClient = class
  private
    FSettings: THttpClientSettings;
    FConnector: THttpConnector;
    FOwnsConnector: Boolean;
    FPool: THttpConnectionPool;
    FCookies: TCookieJar;
    FAuthenticator: TAuthenticator;
    FCache: THttpCache;
    FAltServices: THttpAltServiceCache;
    FObserver: THttpClientObserver;
    FSilentObserver: THttpClientObserver;
    FClock: THttpClock;
    function Observer: THttpClientObserver;
    function Now: Int64;
    procedure PrepareHead(Request: THttpRequest; out Head: THttpRequestHead; out SentAuthorization: Boolean);
    function OpenAlternative(constref Url: TUrlRecord; constref Service: THttpAltService;
      Factory: THttpConnectionFactory; out Connection: THttpConnection; out Exchange: THttpExchange): Boolean;
    function OpenConnection(constref Url: TUrlRecord; out Connection: THttpConnection;
      out Exchange: THttpExchange): THttpResult;
    function ObtainConnection(constref Url: TUrlRecord; ForceNew: Boolean; out Connection: THttpConnection;
      out Exchange: THttpExchange; out Reused: Boolean): THttpResult;
    procedure Abandon(Exchange: THttpExchange; Connection: THttpConnection);
    function ShouldFallBack(Request: THttpRequest; WasAlternative: Boolean; constref Failure: THttpResult;
      SendFailed: Boolean): Boolean;
    procedure TakeResponseFields(Request: THttpRequest; Response: THttpResponse);
    function ResponseFromCache(Request: THttpRequest; Entry: THttpCacheEntry): THttpResponse;
    function DeliverBody(Request: THttpRequest; Response: THttpResponse; Sink: THttpBodySink;
      CacheIt: Boolean; RequestTime, ResponseTime: Int64; Token: THttpCancelToken): THttpResult;
    function FollowRedirect(Request: THttpRequest; Response: THttpResponse; var Redirects: Integer;
      out Followed: Boolean): THttpResult;
  public
    { The connector is freed with the client when OwnsConnector. }
    constructor Create(constref Settings: THttpClientSettings; Connector: THttpConnector;
      OwnsConnector: Boolean = True);
    destructor Destroy; override;
    { One request: the head, the content left in the response. }
    function Execute(Request: THttpRequest; out Response: THttpResponse; Token: THttpCancelToken = nil): THttpResult;
    { The whole fetch, the content into Sink (decoded unless the request
      says not). Request is changed as redirects go (URL, method,
      fields). Response is the final one (its content already read). }
    function Fetch(Request: THttpRequest; Sink: THttpBodySink; out Response: THttpResponse;
      OnHead: THttpHeadEvent = nil; Token: THttpCancelToken = nil): THttpResult;
    { GET a URL into a string. }
    function Get(const UrlText: string; out Text: string; out Status: Integer): THttpResult;
    property Settings: THttpClientSettings read FSettings write FSettings;
    property Pool: THttpConnectionPool read FPool;
    { Not owned; nil: no cookies. }
    property Cookies: TCookieJar read FCookies write FCookies;
    { Not owned; nil: no authentication. }
    property Authenticator: TAuthenticator read FAuthenticator write FAuthenticator;
    { Not owned; nil: no cache. }
    property Cache: THttpCache read FCache write FCache;
    property AltServices: THttpAltServiceCache read FAltServices;
    { Not owned; nil: nobody is told. }
    property ObserverObject: THttpClientObserver read FObserver write FObserver;
    property Clock: THttpClock read FClock write FClock;
  end;

{ Unix time from the RTL's clock (UTC). }
function RuntimeUnixTime: Int64;

implementation

uses
  DateUtils,
  Http.ContentDecoding,
  Http.HeaderFields,
  Http.Http1Connections,
  Http.Http2Connections,
  Http.Methods,
  Http.Redirects,
  Http.StatusCodes,
  Http.Transports,
  Url.Origins;

const
  MaximumAttempts = 3;
  MaximumAuthenticationRounds = 2;

type
  { Writes to two sinks: the content as received for the cache, and on. }
  TTeeSink = class(THttpBodySink)
  private
    FFirst, FSecond: THttpBodySink;
  public
    constructor Create(First, Second: THttpBodySink);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
    function Finish: Boolean; override;
  end;

function RuntimeUnixTime: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(SysUtils.Now));
end;

constructor TTeeSink.Create(First, Second: THttpBodySink);
begin
  inherited Create;
  FFirst := First;
  FSecond := Second;
end;

function TTeeSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  Result := FFirst.Write(Data, Count);
  if Result then
    Result := FSecond.Write(Data, Count);
  if not Result then
  begin
    FErrorCode := FSecond.ErrorCode;
    FDamagedData := FSecond.DamagedData;
    FErrorText := FSecond.ErrorText;
  end
  else
    Inc(FWritten, Count);
end;

function TTeeSink.Finish: Boolean;
begin
  Result := FFirst.Finish and FSecond.Finish;
  if not Result then
  begin
    FDamagedData := FSecond.DamagedData;
    FErrorText := FSecond.ErrorText;
  end;
end;

{ THttpCancelToken }

constructor THttpCancelToken.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor THttpCancelToken.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure THttpCancelToken.Cancel;
begin
  EnterCriticalSection(FLock);
  try
    FCanceled := True;
    if FResponse <> nil then
      FResponse.Abort
    else if FExchange <> nil then
      FExchange.Abort;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpCancelToken.Track(Response: THttpResponse);
begin
  EnterCriticalSection(FLock);
  FResponse := Response;
  FExchange := nil;
  LeaveCriticalSection(FLock);
end;

procedure THttpCancelToken.TrackExchange(Exchange: THttpExchange);
begin
  EnterCriticalSection(FLock);
  FResponse := nil;
  FExchange := Exchange;
  if FCanceled and (Exchange <> nil) then
    Exchange.Abort;
  LeaveCriticalSection(FLock);
end;

procedure THttpCancelToken.Untrack;
begin
  EnterCriticalSection(FLock);
  FResponse := nil;
  FExchange := nil;
  LeaveCriticalSection(FLock);
end;

{ THttpClient }

constructor THttpClient.Create(constref Settings: THttpClientSettings; Connector: THttpConnector;
  OwnsConnector: Boolean);
begin
  inherited Create;
  FSettings := Settings;
  FConnector := Connector;
  FOwnsConnector := OwnsConnector;
  FPool := THttpConnectionPool.Create;
  FAltServices := THttpAltServiceCache.Create;
  FSilentObserver := THttpClientObserver.Create;
  FClock := @RuntimeUnixTime;
end;

destructor THttpClient.Destroy;
begin
  FPool.Free;
  FAltServices.Free;
  FSilentObserver.Free;
  if FOwnsConnector then
    FConnector.Free;
  inherited Destroy;
end;

function THttpClient.Observer: THttpClientObserver;
begin
  if FObserver <> nil then
    Result := FObserver
  else
    Result := FSilentObserver;
end;

function THttpClient.Now: Int64;
begin
  Result := FClock();
end;

procedure THttpClient.PrepareHead(Request: THttpRequest; out Head: THttpRequestHead; out SentAuthorization: Boolean);
var
  Fields: THttpHeaders;
  Index: Integer;
  Field: THttpHeaderField;
  Cookie, Authorization, ConnectionField: string;
  Url: TUrlRecord;
  Target: string;
begin
  Url := Request.Url;
  Head := Default(THttpRequestHead);
  Head.Method := Request.Method;
  Head.Scheme := Url.Scheme;
  Head.Authority := AuthorityOf(Url);
  Target := Url.Path;
  if Target = '' then
    Target := '/';
  if Url.HasQuery then
    Target := Target + '?' + Url.Query;
  Head.Target := Target;
  Head.Priority := Request.Priority;
  Head.Body := Request.Body;
  Head.CloseConnection := Request.CloseConnection;
  SentAuthorization := Request.Headers.Has('authorization');
  Fields := THttpHeaders.Create;
  try
    if not Request.Headers.Has('user-agent') and (FSettings.UserAgent <> '') then
      Fields.Add('user-agent', FSettings.UserAgent);
    if not Request.Headers.Has('accept') then
      Fields.Add('accept', '*/*');
    if not Request.Headers.Has('accept-encoding') and Request.DecodeContent and (FSettings.AcceptEncoding <> '') then
      Fields.Add('accept-encoding', FSettings.AcceptEncoding);
    ConnectionField := '';
    for Index := 0 to Request.Headers.Count - 1 do
    begin
      Field := Request.Headers[Index];
      if Field.Name = 'connection' then
        ConnectionField := Field.Value
      else if Field.Name <> 'host' then
        Fields.Add(Field.Name, Field.Value);
    end;
    if (FAuthenticator <> nil) and not SentAuthorization and (Request.CredentialsMode <> CredentialsOmit) then
    begin
      Authorization := FAuthenticator.AuthorizationFor(Url, Request.Method);
      if Authorization <> '' then
      begin
        Fields.Add('authorization', Authorization);
        SentAuthorization := True;
      end;
    end;
    if (FCookies <> nil) and (Request.CredentialsMode <> CredentialsOmit) and not Request.Headers.Has('cookie') then
    begin
      Cookie := FCookies.CookieFieldFor(Url, Request.CookieContext, Now);
      if Cookie <> '' then
        Fields.Add('cookie', Cookie);
    end;
    if ConnectionField <> '' then
      Fields.Add('connection', ConnectionField);
    SetLength(Head.Fields, Fields.Count);
    for Index := 0 to Fields.Count - 1 do
      Head.Fields[Index] := Fields[Index];
  finally
    Fields.Free;
  end;
end;

{ A new connection to an alternative service (pooled); False, and the
  alternative marked broken, when there is none. }
function THttpClient.OpenAlternative(constref Url: TUrlRecord; constref Service: THttpAltService;
  Factory: THttpConnectionFactory; out Connection: THttpConnection; out Exchange: THttpExchange): Boolean;
var
  Failure: THttpResult;
begin
  Exchange := nil;
  Connection := Factory(Url, Service, FSettings, Observer, Failure);
  if Connection = nil then
  begin
    FAltServices.MarkBroken(OriginKeyOf(Url), Service.ProtocolId, Now);
    Exit(False);
  end;
  Connection.OriginKey := OriginKeyOf(Url);
  Exchange := Connection.StartExchange;
  FPool.Add(Connection);
  Result := True;
end;

function THttpClient.OpenConnection(constref Url: TUrlRecord; out Connection: THttpConnection;
  out Exchange: THttpExchange): THttpResult;
var
  Transport: THttpTransport;
  Key: string;
  Service: THttpAltService;
  Factory: THttpConnectionFactory;
  Http2: THttp2Connection;
begin
  Connection := nil;
  Exchange := nil;
  Key := OriginKeyOf(Url);
  if (Url.Scheme = 'https') and FAltServices.Choose(Key, Now, FSettings.AllowHttp3, Service, Factory) and
     OpenAlternative(Url, Service, Factory, Connection, Exchange) then
    Exit(HttpOk);
  Result := FConnector.Connect(Url, FSettings, Observer, Transport);
  if not HttpSucceeded(Result) then
    Exit;
  if FSettings.AllowHttp2 and (Transport.NegotiatedProtocol = 'h2') then
  begin
    Http2 := THttp2Connection.Create(Transport, Key);
    Result := Http2.Open;
    if not HttpSucceeded(Result) then
    begin
      Http2.Free;
      Exit;
    end;
    Connection := Http2;
  end
  else
    Connection := THttp1Connection.Create(Transport, Key);
  Exchange := Connection.StartExchange;
  FPool.Add(Connection);
  Result := HttpOk;
end;

function THttpClient.ObtainConnection(constref Url: TUrlRecord; ForceNew: Boolean; out Connection: THttpConnection;
  out Exchange: THttpExchange; out Reused: Boolean): THttpResult;
var
  Service: THttpAltService;
  Factory: THttpConnectionFactory;
  Protocols: THttpProtocols;
begin
  Reused := False;
  if not ForceNew then
  begin
    { Once an origin advertised an alternative, new requests move to it
      (a connection to it, or a new one) and leave the origin's own
      connections; while it is broken they stay. }
    if (Url.Scheme = 'https') and FAltServices.Choose(OriginKeyOf(Url), Now, FSettings.AllowHttp3, Service,
       Factory) then
    begin
      Protocols := [Low(THttpProtocol)..High(THttpProtocol)];
      if IsHttp3ProtocolId(Service.ProtocolId) then
        Protocols := [HttpProtocol3];
      Connection := FPool.Acquire(OriginKeyOf(Url), Exchange, Protocols);
      if Connection <> nil then
      begin
        Reused := True;
        Observer.ReusingConnection(SerializeHost(Url.Host), UrlEffectivePort(Url));
        Exit(HttpOk);
      end;
      if OpenAlternative(Url, Service, Factory, Connection, Exchange) then
        Exit(HttpOk);
    end;
    Connection := FPool.Acquire(OriginKeyOf(Url), Exchange);
    if Connection <> nil then
    begin
      Reused := True;
      Observer.ReusingConnection(SerializeHost(Url.Host), UrlEffectivePort(Url));
      Exit(HttpOk);
    end;
  end;
  Result := OpenConnection(Url, Connection, Exchange);
end;

procedure THttpClient.Abandon(Exchange: THttpExchange; Connection: THttpConnection);
begin
  Exchange.Abort;
  Exchange.Finish;
  Exchange.Free;
  FPool.Release(Connection);
end;

{ A new connection to an alternative service failed the request before
  its answer: when the request may simply go again, the alternative is
  marked broken and the origin's own connection used. }
function THttpClient.ShouldFallBack(Request: THttpRequest; WasAlternative: Boolean; constref Failure: THttpResult;
  SendFailed: Boolean): Boolean;
begin
  Result := False;
  if not WasAlternative or (Failure.Code = HttpCanceled) then
    Exit;
  if not (SendFailed or Failure.Retryable or (MethodIsIdempotent(Request.Method) and
     (Failure.Code in [HttpNoResponse, HttpReadFailed, HttpTimedOut, HttpProtocolError, HttpStreamReset]))) then
    Exit;
  FAltServices.MarkBroken(OriginKeyOf(Request.Url), 'h3', Now);
  Result := True;
end;

procedure THttpClient.TakeResponseFields(Request: THttpRequest; Response: THttpResponse);
var
  Value: string;
begin
  if (FCookies <> nil) and (Request.CredentialsMode <> CredentialsOmit) then
    for Value in Response.Headers.GetAll('set-cookie') do
      FCookies.SetCookieFromResponse(Request.Url, Value, Request.CookieContext, Now);
  if (Request.Url.Scheme = 'https') and Response.Headers.Has('alt-svc') then
    FAltServices.Update(OriginKeyOf(Request.Url), Response.Headers.Combined('alt-svc'), Now);
end;

function THttpClient.Execute(Request: THttpRequest; out Response: THttpResponse; Token: THttpCancelToken): THttpResult;
var
  Head: THttpRequestHead;
  Info: THttpResponseHeadInfo;
  Connection: THttpConnection;
  Exchange: THttpExchange;
  Reused, ForceNew, SentAuthorization, WasAlternative: Boolean;
  Attempt: Integer;
begin
  Response := nil;
  if (Request.Url.Scheme <> 'http') and (Request.Url.Scheme <> 'https') then
    Exit(HttpFailure(HttpUnsupportedScheme, 'only http and https are supported'));
  PrepareHead(Request, Head, SentAuthorization);
  ForceNew := False;
  Result := HttpOk;
  for Attempt := 1 to MaximumAttempts do
  begin
    if (Attempt > 1) and (Request.Body <> nil) and not Request.Body.Rewind then
      Exit;
    Result := ObtainConnection(Request.Url, ForceNew, Connection, Exchange, Reused);
    if not HttpSucceeded(Result) then
      Exit;
    if Exchange = nil then
      Exit(HttpFailure(HttpConnectFailed, 'the connection takes no request'));
    ForceNew := True;
    WasAlternative := not Reused and (Connection.Protocol = HttpProtocol3);
    if Token <> nil then
      Token.TrackExchange(Exchange);
    Result := Exchange.Send(Head);
    if (Token <> nil) and Token.Canceled then
      Result := HttpFailure(HttpCanceled, 'canceled');
    if not HttpSucceeded(Result) then
    begin
      if Token <> nil then
        Token.Untrack;
      Abandon(Exchange, Connection);
      if Result.Code = HttpCanceled then
        Exit;
      if Reused and (Result.Code = HttpSendFailed) then
      begin
        Observer.StaleConnection(False);
        Continue;
      end;
      if Result.Retryable or ShouldFallBack(Request, WasAlternative, Result, True) then
        Continue;
      Exit;
    end;
    Observer.RequestSent;
    Result := Exchange.ReceiveHead(Info);
    if (Token <> nil) and Token.Canceled then
      Result := HttpFailure(HttpCanceled, 'canceled');
    if not HttpSucceeded(Result) then
    begin
      if Token <> nil then
        Token.Untrack;
      Abandon(Exchange, Connection);
      if Result.Code = HttpCanceled then
        Exit;
      if Reused and (Result.Code in [HttpNoResponse, HttpReadFailed]) then
      begin
        Observer.StaleConnection(True);
        Continue;
      end;
      if Result.Retryable or ShouldFallBack(Request, WasAlternative, Result, False) then
        Continue;
      Exit;
    end;
    Response := THttpResponse.Create;
    Response.ApplyHead(Info);
    Response.Attach(Exchange, Connection, FPool);
    Response.Url := Request.Url;
    Response.ConnectionReused := Reused;
    Response.SentAuthorization := SentAuthorization;
    if Token <> nil then
      Token.Track(Response);
    TakeResponseFields(Request, Response);
    Exit(HttpOk);
  end;
end;

function THttpClient.ResponseFromCache(Request: THttpRequest; Entry: THttpCacheEntry): THttpResponse;
var
  Field: THttpHeaderField;
begin
  Result := THttpResponse.Create;
  Result.Status := Entry.Status;
  Result.Reason := Entry.Reason;
  Result.Version := 11;
  Result.Url := Request.Url;
  for Field in Entry.Fields do
    Result.Headers.Add(Field.Name, Field.Value);
  Result.AttachCachedBody(Entry.Body);
end;

function THttpClient.DeliverBody(Request: THttpRequest; Response: THttpResponse; Sink: THttpBodySink;
  CacheIt: Boolean; RequestTime, ResponseTime: Int64; Token: THttpCancelToken): THttpResult;
var
  Buffer: array[0..32767] of Byte;
  Count: Int64;
  Chain, Target: THttpBodySink;
  Copy_: THttpMemorySink;
  Tee: TTeeSink;
begin
  Result := HttpOk;
  Chain := nil;
  if Request.DecodeContent and Response.Headers.Has('content-encoding') then
    Chain := CreateDecodingChain(Sink, Response.Headers.Combined('content-encoding'));
  if Chain = nil then
    Chain := Sink;
  Copy_ := nil;
  Tee := nil;
  Target := Chain;
  if CacheIt then
  begin
    Copy_ := THttpMemorySink.Create(DefaultCacheMemoryLimit div 8);
    Tee := TTeeSink.Create(Copy_, Chain);
    Target := Tee;
  end;
  try
    repeat
      if (Token <> nil) and Token.Canceled then
        Exit(HttpFailure(HttpCanceled, 'canceled'));
      Count := Response.Read(@Buffer[0], SizeOf(Buffer));
      if Count < 0 then
      begin
        if (Token <> nil) and Token.Canceled then
          Exit(HttpFailure(HttpCanceled, 'canceled'));
        Exit(Response.LastResult);
      end;
      if (Count > 0) and not Target.Write(@Buffer[0], Count) then
      begin
        if CacheIt and not Chain.DamagedData and (Chain.ErrorText = '') then
        begin
          { Only the copy for the cache overflowed: go on without it. }
          CacheIt := False;
          Target := Chain;
          if not Target.Write(@Buffer[0], Count) then
            Exit(HttpFailure(HttpWriteFailed, Target.ErrorText, Target.ErrorCode));
          Continue;
        end;
        if Target.DamagedData then
          Exit(HttpFailure(HttpDecodeFailed, Target.ErrorText));
        Exit(HttpFailure(HttpWriteFailed, Target.ErrorText, Target.ErrorCode));
      end;
    until Count = 0;
    if not Chain.Finish then
    begin
      if Chain.DamagedData then
        Exit(HttpFailure(HttpDecodeFailed, Chain.ErrorText));
      Exit(HttpFailure(HttpWriteFailed, Chain.ErrorText, Chain.ErrorCode));
    end;
    if CacheIt and (FCache <> nil) then
      FCache.Store(Request.Url, Request.Headers, Response.Status, Response.Reason, Response.Headers.FieldArray,
        Copy_.Bytes, RequestTime, ResponseTime);
  finally
    Tee.Free;
    Copy_.Free;
    if Chain <> Sink then
      Chain.Free;
  end;
end;

function THttpClient.FollowRedirect(Request: THttpRequest; Response: THttpResponse; var Redirects: Integer;
  out Followed: Boolean): THttpResult;
var
  Target: TUrlRecord;
  Maximum: Integer;
  DropContent, CrossOrigin: Boolean;
begin
  Followed := False;
  Result := HttpOk;
  if not StatusIsRedirect(Response.Status) or not Response.Headers.Has('location') or
     (Request.RedirectMode = RedirectManual) then
    Exit;
  if Request.RedirectMode = RedirectError then
    Exit(HttpFailure(HttpRedirectRefused, 'the request does not follow redirects'));
  Maximum := Request.MaximumRedirects;
  if Maximum < 0 then
    Maximum := FSettings.MaximumRedirects;
  if Redirects >= Maximum then
    Exit(HttpFailure(HttpTooManyRedirects, IntToStr(Maximum) + ' redirections exceeded'));
  if not ResolveLocation(Request.Url, Response.Headers.Value('location'), Target) or
     ((Target.Scheme <> 'http') and (Target.Scheme <> 'https')) then
    Exit(HttpFailure(HttpRedirectRefused, 'cannot follow the redirection to ' + Response.Headers.Value('location')));
  Inc(Redirects);
  Request.Method := RedirectedMethod(Response.Status, Request.Method, DropContent);
  if DropContent then
    Request.SetBody(nil)
  else if (Request.Body <> nil) and not Request.Body.Rewind then
    Exit(HttpFailure(HttpRedirectRefused, 'the request content cannot be sent again'));
  CrossOrigin := OriginKeyOf(Request.Url) <> OriginKeyOf(Target);
  PrepareRedirectedFields(Request.Headers, DropContent, CrossOrigin);
  Request.Url := Target;
  if (Target.Scheme = 'https') <> Request.CookieContext.IsSecure then
    Request.CookieContext.IsSecure := Target.Scheme = 'https';
  Followed := True;
end;

function THttpClient.Fetch(Request: THttpRequest; Sink: THttpBodySink; out Response: THttpResponse;
  OnHead: THttpHeadEvent; Token: THttpCancelToken): THttpResult;
var
  Redirects, AuthenticationRounds: Integer;
  Lookup: THttpCacheLookup;
  Entry, Updated: THttpCacheEntry;
  Validated, Followed, Stale, CacheIt: Boolean;
  RequestTime, ResponseTime: Int64;
  UrlList: array of TUrlRecord;
  Fields: THttpHeaderFieldArray;
begin
  Response := nil;
  Redirects := 0;
  AuthenticationRounds := 0;
  UrlList := nil;
  while True do
  begin
    if (Token <> nil) and Token.Canceled then
      Exit(HttpFailure(HttpCanceled, 'canceled'));
    SetLength(UrlList, Length(UrlList) + 1);
    UrlList[High(UrlList)] := Request.Url;
    Entry := nil;
    Validated := False;
    Lookup := CacheMiss;
    if (FCache <> nil) and (Request.Method = 'GET') and
       not (Request.CacheMode in [CacheModeNoStore, CacheModeReload]) then
      Lookup := FCache.Lookup(Request.Url, Request.Headers, Now, Entry);
    if (Lookup = CacheFresh) and (Request.CacheMode <> CacheModeNoCache) or
       (Lookup <> CacheMiss) and (Request.CacheMode in [CacheModeForceCache, CacheModeOnlyIfCached]) then
    begin
      Response := ResponseFromCache(Request, Entry);
      Entry.Free;
      Response.UrlList := UrlList;
      if Assigned(OnHead) and not OnHead(Response) then
        Exit(HttpFailure(HttpCanceled, 'stopped'));
      Exit(DeliverBody(Request, Response, Sink, False, 0, 0, Token));
    end;
    if Request.CacheMode = CacheModeOnlyIfCached then
      Exit(HttpFailure(HttpNotCached, 'not in the cache'));
    if (Entry <> nil) and HasValidator(Entry.Fields) and not Request.Headers.Has('if-none-match') and
       not Request.Headers.Has('if-modified-since') then
    begin
      AddValidators(Entry, Request.Headers);
      Validated := True;
    end;
    RequestTime := Now;
    Result := Execute(Request, Response, Token);
    ResponseTime := Now;
    if Validated then
    begin
      Request.Headers.Remove('if-none-match');
      Request.Headers.Remove('if-modified-since');
    end;
    if not HttpSucceeded(Result) then
    begin
      Entry.Free;
      Exit;
    end;
    Response.UrlList := UrlList;
    if Validated and (Response.Status = 304) then
    begin
      Fields := Response.Headers.FieldArray;
      Response.Discard;
      FreeAndNil(Response);
      Updated := FCache.Freshen(Request.Url, Request.Headers, Fields, RequestTime, ResponseTime);
      if Updated = nil then
        Updated := Entry
      else
        Entry.Free;
      Entry := nil;
      Response := ResponseFromCache(Request, Updated);
      Updated.Free;
      Response.UrlList := UrlList;
      if Token <> nil then
        Token.Untrack;
      if Assigned(OnHead) and not OnHead(Response) then
        Exit(HttpFailure(HttpCanceled, 'stopped'));
      Exit(DeliverBody(Request, Response, Sink, False, 0, 0, Token));
    end;
    Entry.Free;
    Result := FollowRedirect(Request, Response, Redirects, Followed);
    if Followed or not HttpSucceeded(Result) then
    begin
      if Token <> nil then
        Token.Untrack;
      Response.Discard;
      if not HttpSucceeded(Result) then
        Exit;
      FreeAndNil(Response);
      Continue;
    end;
    if (Response.Status = 401) and (FAuthenticator <> nil) and (AuthenticationRounds < MaximumAuthenticationRounds) and
       (Request.CredentialsMode <> CredentialsOmit) and
       FAuthenticator.AcceptChallenges(Request.Url, Response.Headers.GetAll('www-authenticate'), Stale) and
       (not Response.SentAuthorization or Stale) and ((Request.Body = nil) or Request.Body.Rewind) then
    begin
      if Token <> nil then
        Token.Untrack;
      Inc(AuthenticationRounds);
      Response.Discard;
      FreeAndNil(Response);
      Continue;
    end;
    if (FCache <> nil) and not MethodIsSafe(Request.Method) and (Response.Status < 400) then
      FCache.Invalidate(Request.Url);
    if Assigned(OnHead) and not OnHead(Response) then
      Exit(HttpFailure(HttpCanceled, 'stopped'));
    CacheIt := (FCache <> nil) and (Request.CacheMode <> CacheModeNoStore) and
      FCache.IsStorable(Request.Method, Response.Status, Request.Headers, Response.Headers.FieldArray);
    Result := DeliverBody(Request, Response, Sink, CacheIt, RequestTime, ResponseTime, Token);
    if Token <> nil then
      Token.Untrack;
    Exit;
  end;
end;

function THttpClient.Get(const UrlText: string; out Text: string; out Status: Integer): THttpResult;
var
  Request: THttpRequest;
  Response: THttpResponse;
  Sink: THttpMemorySink;
begin
  Text := '';
  Status := 0;
  if not THttpRequest.FromText('GET', UrlText, Request) then
    Exit(HttpFailure(HttpUnsupportedScheme, 'not a URL: ' + UrlText));
  Sink := THttpMemorySink.Create;
  try
    Result := Fetch(Request, Sink, Response);
    if Response <> nil then
      Status := Response.Status;
    Text := Sink.Text;
  finally
    Response.Free;
    Sink.Free;
    Request.Free;
  end;
end;

end.
