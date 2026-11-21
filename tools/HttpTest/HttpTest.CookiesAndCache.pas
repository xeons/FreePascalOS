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
  RFC 6265bis's rules in the cookie jar (public suffixes, Secure from
  insecure requests, the __Secure- and __Host- prefixes, SameSite on
  storing and sending, HttpOnly against scripts), RFC 9111's freshness
  and age arithmetic, the disk cache read back by another cache, and
  Alt-Svc parsing.
}
unit HttpTest.CookiesAndCache;

{$mode objfpc}
{$H+}

interface

procedure TestCookiesAndCache(const WorkDirectory: string);

implementation

uses
  SysUtils,
  TestChecks,
  Http.AltServices,
  Http.Cache,
  Http.Connections,
  Http.Client,
  Http.Connectors,
  Http.CookiePolicies,
  Http.Cookies,
  Http.HeaderFields,
  Http.Messages,
  Http.Transports,
  Http.Observers,
  Http.PublicSuffixes,
  Http.Results,
  Url.Parser,
  Url.Records;

const
  Now = 1767225600;

function UrlOf(const Text: string): TUrlRecord;
begin
  if not ParseUrl(Text, Result) then
    raise Exception.Create('bad test URL');
end;

function CrossSite(TopLevel: Boolean): TCookieRequestContext;
begin
  Result := DirectRequestContext(True);
  Result.SameSite := False;
  Result.TopLevelNavigation := TopLevel;
end;

procedure TestPublicSuffixes;
begin
  Check(IsPublicSuffix('com') and IsPublicSuffix('co.uk') and not IsPublicSuffix('example.co.uk'),
    'public suffixes: com and co.uk');
  Check(RegistrableDomainOf('www.example.co.uk') = 'example.co.uk', 'public suffixes: a registrable domain');
  Check(RegistrableDomainOf('a.b.example.com') = 'example.com', 'public suffixes: under a top-level domain');
  Check(IsPublicSuffix('anything.ck') and not IsPublicSuffix('www.ck'), 'public suffixes: a wildcard and its exception');
  Check(HostsAreSameSite('a.example.com', 'b.example.com') and not HostsAreSameSite('a.github.io', 'b.github.io'),
    'public suffixes: same site, not across a hosting suffix');
end;

procedure TestCookieRules;
var
  Jar: TCookieJar;
  Secure, Plain: TCookieRequestContext;
  Script: TCookieRequestContext;
begin
  Jar := TCookieJar.Create;
  Secure := DirectRequestContext(True);
  Plain := DirectRequestContext(False);
  Script := Secure;
  Script.HttpApi := False;
  try
    Check(not Jar.SetCookieFromResponse(UrlOf('https://www.example.co.uk/'), 'a=1; Domain=co.uk', Secure, Now),
      'cookies: a public suffix domain refused');
    Check(not Jar.SetCookieFromResponse(UrlOf('http://example.com/'), 's=1; Secure', Plain, Now),
      'cookies: Secure from an insecure request refused');
    Check(Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'id=secure; Secure', Secure, Now) and
      not Jar.SetCookieFromResponse(UrlOf('http://example.com/'), 'id=plain', Plain, Now),
      'cookies: an insecure request may not shadow a Secure cookie');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), '__Secure-a=1', Secure, Now) and
      Jar.SetCookieFromResponse(UrlOf('https://example.com/'), '__Secure-a=1; Secure', Secure, Now),
      'cookies: __Secure- needs Secure');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/x/'), '__Host-b=1; Secure; Path=/x', Secure, Now) and
      Jar.SetCookieFromResponse(UrlOf('https://example.com/'), '__Host-b=1; Secure; Path=/', Secure, Now),
      'cookies: __Host- needs Path=/ and no Domain');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'n=1; SameSite=None', Secure, Now),
      'cookies: SameSite=None without Secure refused');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'lax=1; SameSite=Lax', CrossSite(False), Now) and
      Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'lax=1; SameSite=Lax', CrossSite(True), Now),
      'cookies: a Lax cookie from a cross-site request only in a top-level navigation');
    Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'strict=1; SameSite=Strict', Secure, Now);
    Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'none=1; SameSite=None; Secure', Secure, Now);
    Check(Pos('strict=1', Jar.CookieFieldFor(UrlOf('https://example.com/'), CrossSite(True), Now)) = 0,
      'cookies: Strict is not sent cross-site');
    Check(Pos('lax=1', Jar.CookieFieldFor(UrlOf('https://example.com/'), CrossSite(True), Now)) > 0,
      'cookies: Lax is sent in a cross-site top-level navigation');
    Check(Pos('none=1', Jar.CookieFieldFor(UrlOf('https://example.com/'), CrossSite(False), Now)) > 0,
      'cookies: None is sent cross-site');
    Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'hidden=1; HttpOnly', Secure, Now);
    Check((Pos('hidden=1', Jar.DocumentCookie(UrlOf('https://example.com/'), Secure, Now)) = 0) and
      (Pos('hidden=1', Jar.CookieFieldFor(UrlOf('https://example.com/'), Secure, Now)) > 0),
      'cookies: HttpOnly hidden from scripts');
    Check(not Jar.SetDocumentCookie(UrlOf('https://example.com/'), 'hidden=2', Script, Now) and
      Jar.SetDocumentCookie(UrlOf('https://example.com/'), 'visible=1', Script, Now),
      'cookies: scripts may not replace an HttpOnly cookie');
    Check(Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'long=1; Max-Age=999999999', Secure, Now) and
      (Jar.Snapshot[High(Jar.Snapshot)].ExpiryTime = Now + MaximumLifetime), 'cookies: at most 400 days');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'bad=a'#1'b', Secure, Now),
      'cookies: control characters refused');
  finally
    Jar.Free;
  end;
end;

function Fields(const Pairs: array of string): THttpHeaderFieldArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Pairs) div 2);
  for Index := 0 to High(Result) do
  begin
    Result[Index].Name := Pairs[Index * 2];
    Result[Index].Value := Pairs[Index * 2 + 1];
  end;
end;

procedure TestFreshness;
begin
  Check(FreshnessLifetime(Fields(['cache-control', 'max-age=600', 'expires', 'Thu, 01 Jan 1970 00:00:00 GMT']), 200) =
    600, 'cache: max-age wins over Expires');
  Check(FreshnessLifetime(Fields(['date', 'Sun, 06 Nov 1994 08:49:37 GMT', 'expires', 'Sun, 06 Nov 1994 09:49:37 GMT']),
    200) = 3600, 'cache: Expires minus Date');
  Check(FreshnessLifetime(Fields(['date', 'Sun, 06 Nov 1994 08:49:37 GMT', 'expires', '0']), 200) = 0,
    'cache: a bad Expires is already stale');
  Check(FreshnessLifetime(Fields(['date', 'Sun, 06 Nov 1994 08:49:37 GMT',
    'last-modified', 'Sun, 06 Nov 1994 06:49:37 GMT']), 200) = 720, 'cache: 10% of the time since Last-Modified');
  Check(FreshnessLifetime(Fields(['date', 'Sun, 06 Nov 1994 08:49:37 GMT',
    'last-modified', 'Sun, 06 Nov 1994 06:49:37 GMT']), 201) = 0, 'cache: no heuristic for a 201');
  Check(CurrentAge(Fields(['date', 'Sun, 06 Nov 1994 08:49:37 GMT', 'age', '30']), 784111777, 784111779, 784111800) =
    53, 'cache: Age, the response delay and the time since');
end;

procedure TestDiskCache(const WorkDirectory: string);
var
  Folder: string;
  First, Second: THttpCache;
  Url: TUrlRecord;
  Request: THttpHeaders;
  Entry: THttpCacheEntry;
  Body: TBytes;
begin
  Folder := IncludeTrailingPathDelimiter(WorkDirectory) + 'http-cache';
  ForceDirectories(Folder);
  Url := UrlOf('https://example.com/page?x=1#top');
  Request := THttpHeaders.Create;
  First := THttpCache.Create(DefaultCacheMemoryLimit, Folder);
  Second := THttpCache.Create(DefaultCacheMemoryLimit, Folder);
  try
    Request.Add('accept-encoding', 'gzip');
    Body := nil;
    SetLength(Body, 3);
    Body[0] := 1;
    Body[1] := 10;
    Body[2] := 255;
    Check(First.IsStorable('GET', 200, Request, Fields(['cache-control', 'max-age=60', 'vary', 'Accept-Encoding'])) and
      not First.IsStorable('GET', 200, Request, Fields(['vary', '*', 'cache-control', 'max-age=60'])) and
      not First.IsStorable('POST', 200, Request, Fields(['cache-control', 'max-age=60'])),
      'cache: what may be stored');
    First.Store(Url, Request, 200, 'OK', Fields(['cache-control', 'max-age=60', 'vary', 'Accept-Encoding']), Body,
      Now - 5, Now - 5);
    Check(Second.Lookup(Url, Request, Now, Entry) = CacheFresh, 'cache: read back from the disk by another cache');
    Check((Entry <> nil) and (Length(Entry.Body) = 3) and (Entry.Body[2] = 255) and (Entry.Status = 200),
      'cache: the content and status kept');
    Entry.Free;
    Request.SetValue('accept-encoding', 'identity');
    Check(Second.Lookup(Url, Request, Now, Entry) = CacheMiss, 'cache: another Vary value misses');
    Request.SetValue('accept-encoding', 'gzip');
    Check(Second.Lookup(Url, Request, Now + 120, Entry) = CacheStale, 'cache: stale after max-age');
    Entry.Free;
    Second.Invalidate(Url);
    Check((Second.Lookup(Url, Request, Now, Entry) = CacheMiss) and not FileExists(Folder + '/x'),
      'cache: invalidated');
  finally
    Second.Free;
    First.Free;
    Request.Free;
  end;
end;

function RefusingFactory(constref Url: TUrlRecord; constref Service: THttpAltService;
  constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Failure: THttpResult): THttpConnection;
begin
  Failure := HttpFailure(HttpConnectFailed, 'not here');
  Result := nil;
end;

procedure TestAltSvc;
const
  Origin = 'https://alt.test:443';
var
  Services: THttpAltServiceArray;
  Service: THttpAltService;
  Factory: THttpConnectionFactory;
  Clear: Boolean;
  Cache, Copy_: THttpAltServiceCache;
  Index: Integer;
  Text: string;
begin
  Check(ParseAltSvc('h3=":443"; ma=3600, h3%2D29=":8443", h2="alt.example:443"; persist=1', Now, Services, Clear) and
    (Length(Services) = 3) and (Services[0].Expires = Now + 3600) and (Services[1].ProtocolId = 'h3-29') and
    (Services[2].Host = 'alt.example') and (Services[2].Expires = Now + DefaultAltServiceMaxAge),
    'Alt-Svc: parsed');
  Check(not Services[0].Persist and Services[2].Persist, 'Alt-Svc: persist=1');
  Check(ParseAltSvc('clear', Now, Services, Clear) and Clear, 'Alt-Svc: clear');
  Check(ParseAltSvc('h3="[2001:db8::1]:443", h3=":0", h3="host", h3=":70000", h3=":443"; ma=0, ' +
    'h3=":443"; ma=x', Now, Services, Clear) and (Length(Services) = 2) and (Services[0].Host = '2001:db8::1') and
    (Services[1].Expires = Now + DefaultAltServiceMaxAge),
    'Alt-Svc: IPv6 host; bad ports and ma=0 dropped; a bad ma ignored');
  Check(IsHttp3ProtocolId('h3') and IsHttp3ProtocolId('h3-29') and not IsHttp3ProtocolId('h2'),
    'Alt-Svc: HTTP/3 protocol ids');

  RegisterConnectionFactory('x-test', @RefusingFactory);
  Cache := THttpAltServiceCache.Create;
  Copy_ := THttpAltServiceCache.Create;
  try
    Cache.Update(Origin, 'x-test=":8443"; ma=60, h3=":443"; persist=1', Now);
    Check(Length(Cache.ServicesOf(Origin, Now)) = 2, 'Alt-Svc cache: kept');
    Check(Length(Cache.ServicesOf(Origin, Now + 61)) = 1, 'Alt-Svc cache: expired by ma');
    Check(Cache.Choose(Origin, Now, True, Service, Factory) and (Service.ProtocolId = 'x-test') and
      (Service.Port = 8443), 'Alt-Svc cache: chooses an alternative with a factory');
    Cache.MarkBroken(Origin, 'x-test', Now);
    Check(not Cache.Choose(Origin, Now, True, Service, Factory), 'Alt-Svc cache: broken for a while');
    Cache.Update(Origin, 'x-test=":8443"', Now);
    Check(not Cache.Choose(Origin, Now, True, Service, Factory), 'Alt-Svc cache: still broken when advertised again');
    Check(Cache.Choose(Origin, Now + BrokenAltServiceSeconds + 1, True, Service, Factory),
      'Alt-Svc cache: broken only five minutes');
    Cache.Update(Origin, 'h3=":443"; persist=1, x-test=":9443"', Now);
    Text := Cache.SaveText(Now);
    Check(Text = Origin + ' h3 - 443 ' + IntToStr(Now + DefaultAltServiceMaxAge) + ' 1'#10 + Origin + ' x-test - 9443 ' +
      IntToStr(Now + DefaultAltServiceMaxAge) + ' 0'#10, 'Alt-Svc cache: saved as text');
    Copy_.LoadText(Text + 'garbage line'#10 + Origin + ' h3 - 443 ' + IntToStr(Now - 1) + ' 0'#10, Now);
    Services := Copy_.ServicesOf(Origin, Now);
    Check((Length(Services) = 2) and Services[0].Persist and (Services[1].Port = 9443) and (Services[0].Host = ''),
      'Alt-Svc cache: read back (bad and expired lines skipped)');
    Check(Copy_.Choose(Origin, Now, False, Service, Factory) and (Service.ProtocolId = 'x-test'),
      'Alt-Svc cache: h3 passed over when HTTP/3 is not allowed');
    Cache.Update(Origin, 'clear', Now);
    Check(Length(Cache.ServicesOf(Origin, Now)) = 0, 'Alt-Svc cache: clear forgets the origin');
    for Index := 1 to MaximumAltServiceOrigins + 10 do
      Cache.Update('https://o' + IntToStr(Index) + '.test:443', 'h3=":443"', Now);
    Check((Cache.OriginCount = MaximumAltServiceOrigins) and
      (Length(Cache.ServicesOf('https://o1.test:443', Now)) = 0) and
      (Length(Cache.ServicesOf('https://o522.test:443', Now)) = 1), 'Alt-Svc cache: bounded, oldest out first');
    Text := '';
    for Index := 1 to 20 do
      Text := Text + 'h3=":' + IntToStr(1000 + Index) + '", ';
    Cache.Update(Origin, Text, Now);
    Check(Length(Cache.ServicesOf(Origin, Now)) = MaximumAltServicesPerOrigin, 'Alt-Svc cache: eight per origin');
  finally
    Copy_.Free;
    Cache.Free;
  end;
end;


procedure TestCookieExceptions;
var
  Policy: TCookieUsePolicy;
begin
  Check(HostMatchesException('www.example.com', 'example.com') and HostMatchesException('EXAMPLE.com', '.example.COM') and
    not HostMatchesException('badexample.com', 'example.com') and not HostMatchesException('example.com', 'www.example.com'),
    'cookie policies: a host or a parent domain');
  Check(HostMatchesException('10.0.0.1', '10.0.0.1') and not HostMatchesException('1.10.0.0.1', '10.0.0.1'),
    'cookie policies: an address only exactly');
  Policy := DefaultCookieUsePolicy;
  Check(CookieUseAllowed(Policy, 'a.example', True) and CookieUseAllowed(Policy, 'a.example', False),
    'cookie policies: everything accepted by default');
  Policy.Acceptance := CookieRefuseThirdParty;
  Check(not CookieUseAllowed(Policy, 'a.example', True) and CookieUseAllowed(Policy, 'a.example', False),
    'cookie policies: third parties refused');
  Policy.Acceptance := CookieRefuseAll;
  Policy.AllowedHosts := ['example.com'];
  Check(CookieUseAllowed(Policy, 'mail.example.com', True) and not CookieUseAllowed(Policy, 'other.org', False),
    'cookie policies: an allowed parent domain over refusing all');
  Policy.Acceptance := CookieAcceptAll;
  Policy.BlockedHosts := ['ads.example.com'];
  Check(not CookieUseAllowed(Policy, 'x.ads.example.com', False) and CookieUseAllowed(Policy, 'www.example.com', False),
    'cookie policies: the longer blocked exception wins');
  Policy.AllowedHosts := ['x.ads.example.com'];
  Check(CookieUseAllowed(Policy, 'x.ads.example.com', False), 'cookie policies: the longer allowed exception wins');
  Policy.BlockedHosts := ['x.ads.example.com'];
  Check(not CookieUseAllowed(Policy, 'x.ads.example.com', False), 'cookie policies: a tie blocks');
end;

procedure TestJarPolicy;
var
  Jar: TCookieJar;
  Secure: TCookieRequestContext;
  Policy: TCookieUsePolicy;
  Cookies: TCookieArray;
begin
  Jar := TCookieJar.Create;
  Secure := DirectRequestContext(True);
  try
    Check(Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'kept=1', Secure, Now) and
      Jar.SetCookieFromResponse(UrlOf('https://example.com/a/'), 'pathy=1; Path=/a', Secure, Now),
      'cookie policies: stored while accepted');
    Policy := DefaultCookieUsePolicy;
    Policy.BlockedHosts := ['example.com'];
    Jar.SetPolicy(Policy);
    Check((Length(Jar.Policy.BlockedHosts) = 1) and (Jar.Policy.BlockedHosts[0] = 'example.com'),
      'cookie policies: the jar keeps its policy');
    Check(not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'new=1', Secure, Now) and
      not Jar.SetDocumentCookie(UrlOf('https://www.example.com/'), 'doc=1', Secure, Now) and
      not Jar.ReceiveSetCookie('old=1', 'example.com', '/', Now),
      'cookie policies: a blocked host stores nothing');
    Check((Jar.CookieFieldFor(UrlOf('https://example.com/'), Secure, Now) = '') and
      (Jar.DocumentCookie(UrlOf('https://example.com/'), Secure, Now) = '') and
      (Jar.CookieHeaderFor('example.com', '/', True, Now) = ''), 'cookie policies: a blocked host gets nothing');
    Policy := DefaultCookieUsePolicy;
    Policy.Acceptance := CookieRefuseThirdParty;
    Jar.SetPolicy(Policy);
    Check((Jar.CookieFieldFor(UrlOf('https://example.com/'), CrossSite(False), Now) = '') and
      not Jar.SetCookieFromResponse(UrlOf('https://example.com/'), 'third=1; SameSite=None; Secure', CrossSite(False),
      Now), 'cookie policies: a third party neither gets nor stores');
    Check(Pos('kept=1', Jar.CookieFieldFor(UrlOf('https://example.com/'), Secure, Now)) > 0,
      'cookie policies: the first party gets its cookies');
    Check(not Jar.RemoveCookie('example.com', 'kept', '/a') and Jar.RemoveCookie('example.com', 'kept', '/'),
      'cookies: removed by domain, name and path');
    Cookies := Jar.Snapshot;
    Check((Length(Cookies) = 1) and (Cookies[0].Name = 'pathy') and (Cookies[0].Path = '/a'),
      'cookies: the snapshot after a removal');
  finally
    Jar.Free;
  end;
end;

procedure TestCacheLimit;
var
  Cache: THttpCache;
  Request: THttpHeaders;
  Entry: THttpCacheEntry;
  Body: TBytes;
  Index: Integer;
begin
  Cache := THttpCache.Create(1024 * 1024);
  Request := THttpHeaders.Create;
  try
    Body := nil;
    SetLength(Body, 10000);
    for Index := 1 to 5 do
      Cache.Store(UrlOf('https://example.com/' + IntToStr(Index)), Request, 200, 'OK',
        Fields(['cache-control', 'max-age=600']), Body, Now, Now);
    { The first is used again: the second is the least recently used. }
    if Cache.Lookup(UrlOf('https://example.com/1'), Request, Now, Entry) = CacheFresh then
      Entry.Free;
    Check(Cache.MemoryUsed > 40000, 'cache: entries stored');
    Cache.SetMemoryLimit(Cache.MemoryUsed - 1);
    Check(Cache.MemoryUsed <= Cache.MemoryLimit, 'cache: a lower limit is kept at once');
    Check(Cache.Lookup(UrlOf('https://example.com/2'), Request, Now, Entry) = CacheMiss,
      'cache: a lower limit drops the least recently used');
    Entry.Free;
    Check(Cache.Lookup(UrlOf('https://example.com/1'), Request, Now, Entry) <> CacheMiss,
      'cache: the recently used one stays');
    Entry.Free;
    Cache.SetMemoryLimit(0);
    Check(Cache.MemoryUsed = 0, 'cache: a limit of nothing empties it');
  finally
    Request.Free;
    Cache.Free;
  end;
end;

type
  { Fails the test if anything connects. }
  TForbiddenConnector = class(THttpConnector)
  public
    Called: Boolean;
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
  end;

function TForbiddenConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
begin
  Called := True;
  Transport := nil;
  Result := HttpFailure(HttpConnectFailed, 'connected');
end;

procedure TestOffline;
var
  Connector: TForbiddenConnector;
  Client: THttpClient;
  Request: THttpRequest;
  Response: THttpResponse;
  Outcome: THttpResult;
begin
  Connector := TForbiddenConnector.Create;
  Client := THttpClient.Create(DefaultClientSettings, Connector, False);
  Request := THttpRequest.Create('GET', UrlOf('https://example.com/'));
  try
    Client.Offline := True;
    Outcome := Client.Execute(Request, Response);
    Check((Outcome.Code = HttpConnectFailed) and (Outcome.Text = 'offline') and not Connector.Called and
      (Response = nil), 'client: offline fails at once');
    Response.Free;
  finally
    Request.Free;
    Client.Free;
    Connector.Free;
  end;
end;

procedure TestCookiesAndCache(const WorkDirectory: string);
begin
  TestCookieExceptions;
  TestJarPolicy;
  TestCacheLimit;
  TestOffline;
  TestPublicSuffixes;
  TestCookieRules;
  TestFreshness;
  TestDiskCache(WorkDirectory);
  TestAltSvc;
end;

end.
