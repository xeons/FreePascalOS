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
  Http.Cookies,
  Http.HeaderFields,
  Http.PublicSuffixes,
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

procedure TestAltSvc;
var
  Services: THttpAltServiceArray;
  Clear: Boolean;
begin
  Check(ParseAltSvc('h3=":443"; ma=3600, h3%2D29=":8443", h2="alt.example:443"; persist=1', Now, Services, Clear) and
    (Length(Services) = 3) and (Services[0].Expires = Now + 3600) and (Services[1].ProtocolId = 'h3-29') and
    (Services[2].Host = 'alt.example') and (Services[2].Expires = Now + DefaultAltServiceMaxAge),
    'Alt-Svc: parsed');
  Check(ParseAltSvc('clear', Now, Services, Clear) and Clear, 'Alt-Svc: clear');
end;

procedure TestCookiesAndCache(const WorkDirectory: string);
begin
  TestPublicSuffixes;
  TestCookieRules;
  TestFreshness;
  TestDiskCache(WorkDirectory);
  TestAltSvc;
end;

end.
