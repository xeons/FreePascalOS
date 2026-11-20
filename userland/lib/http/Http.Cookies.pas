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
  A cookie jar as RFC 6265bis (draft 20) has a user agent keep one,
  for wget and for the browser:

  - Set-Cookie is read as section 5.6 says: the name and value before
    the first ";" (no "=" makes a cookie with an empty name), then
    Expires, Max-Age (which wins), Domain, Path, Secure, HttpOnly and
    SameSite; unknown attributes are ignored, attribute values over
    1024 bytes too; a name and value over 4096 bytes in all, or with
    control characters, drop the cookie; expiry is at most 400 days on;
  - storing (section 5.7): the request's host must domain-match the
    Domain, which may not be a public suffix (Http.PublicSuffixes)
    unless it is the host itself (then the cookie is host-only); a
    Secure cookie only from a secure request; a cookie from an insecure
    request may not shadow a Secure one; __Secure- needs Secure,
    __Host- needs Secure, no Domain and Path=/; SameSite Strict or Lax
    cookies are not taken from a cross-site request that is not a
    top-level navigation; SameSite=None needs Secure; scripts
    (non-HTTP) may neither set nor replace HttpOnly cookies; at most 50
    cookies per domain and 3000 in all, the least recently used going;
  - retrieval (section 5.8): domain, path, Secure (secure requests
    only), HttpOnly (HTTP only), SameSite (Strict: same-site requests;
    Lax and unspecified: same-site or top-level navigations with a
    safe method; None: any), longer paths first, then older ones.

  The request's circumstances are a TCookieRequestContext; a program
  that fetches what it was told (wget) uses DirectRequestContext.
  ReceiveSetCookie and CookieHeaderFor keep the older host and path
  form. The jar locks itself, so fetches on several threads share it.

  Times are seconds since 1970 (UTC), passed in so tests choose them.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest
  and tools/HttpTest.
}
unit Http.Cookies;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

const
  MaximumCookiesPerDomain = 50;
  MaximumCookies = 3000;
  MaximumNameValueLength = 4096;
  MaximumAttributeLength = 1024;
  MaximumLifetime = 400 * 86400;

type
  TCookieSameSite = (SameSiteDefault, SameSiteNone, SameSiteLax, SameSiteStrict);

  TCookie = record
    Name, Value: string;
    { Lower case, without a leading dot. }
    Domain: string;
    { Set without a Domain attribute: for exactly that host. }
    HostOnly: Boolean;
    Path: string;
    Secure: Boolean;
    HttpOnly: Boolean;
    SameSite: TCookieSameSite;
    { Has an expiry (else it ends with the session). }
    Persistent: Boolean;
    ExpiryTime: Int64;
    { The order cookies were first made in. }
    CreationOrder: Int64;
    LastAccess: Int64;
  end;

  TCookieArray = array of TCookie;

  TCookieRequestContext = record
    { https or wss, or a potentially trustworthy origin (localhost). }
    IsSecure: Boolean;
    { The request is same-site with what made it (its site for cookies). }
    SameSite: Boolean;
    TopLevelNavigation: Boolean;
    { GET, HEAD, OPTIONS or TRACE. }
    SafeMethod: Boolean;
    { False for a script's document.cookie. }
    HttpApi: Boolean;
  end;

  TCookieJar = class
  private
    FCookies: TCookieArray;
    FNextOrder: Int64;
    FLock: TRTLCriticalSection;
    function FindCookie(const Name, Domain, Path: string): Integer;
    procedure RemoveAt(Index: Integer);
    procedure EnforceLimits(const Domain: string);
    function GetCount: Integer;
    function GetCookie(Index: Integer): TCookie;
    function Store(const Header, Host, RequestPath: string; constref Context: TCookieRequestContext;
      Now: Int64): Boolean;
    function Retrieve(const Host, RequestPath: string; constref Context: TCookieRequestContext; Now: Int64): string;
  public
    constructor Create;
    destructor Destroy; override;
    { A Set-Cookie value received for a URL. True if the jar changed. }
    function SetCookieFromResponse(constref Url: TUrlRecord; const Header: string;
      constref Context: TCookieRequestContext; Now: Int64): Boolean;
    { The Cookie field for a request to the URL ('' if none goes). }
    function CookieFieldFor(constref Url: TUrlRecord; constref Context: TCookieRequestContext; Now: Int64): string;
    { document.cookie: what a script sees, and a script's assignment. }
    function DocumentCookie(constref Url: TUrlRecord; constref Context: TCookieRequestContext; Now: Int64): string;
    function SetDocumentCookie(constref Url: TUrlRecord; const Text: string; constref Context: TCookieRequestContext;
      Now: Int64): Boolean;
    { The older form: Host and RequestPath (the URL's path, query
      included), as a direct request over a secure connection. }
    function ReceiveSetCookie(const Header, Host, RequestPath: string; Now: Int64): Boolean;
    function CookieHeaderFor(const Host, RequestPath: string; IsSecure: Boolean; Now: Int64): string;
    { Keeps a cookie as it is (from a cookie file): replaces one with the
      same name, domain and path. }
    procedure AddCookie(Cookie: TCookie);
    { Drops expired cookies. }
    procedure RemoveExpired(Now: Int64);
    { Drops session cookies (when a browsing session ends). }
    procedure RemoveSessionCookies;
    procedure Clear;
    { A copy of every cookie (for saving or showing). }
    function Snapshot: TCookieArray;
    property Count: Integer read GetCount;
    property Cookies[Index: Integer]: TCookie read GetCookie;
  end;

{ RFC 6265 5.1.3: Host is Domain, or ends with "." + Domain and is not
  an IP address. Both lower case. }
function DomainMatches(const Host, Domain: string): Boolean;
{ RFC 6265 5.1.4. }
function PathMatches(const RequestPath, CookiePath: string): Boolean;
{ RFC 6265 5.1.4: the directory of the request's path ("/a/b" -> "/a",
  "/a" -> "/"). }
function DefaultCookiePath(const RequestPath: string): string;
{ Parses a Set-Cookie value into Cookie (its Domain as given, HostOnly
  when it had none; ExpiryTime from Max-Age or Expires). False if the
  cookie is to be ignored. }
function ParseSetCookie(const Header: string; Now: Int64; out Cookie: TCookie; out HasDomain: Boolean): Boolean;
{ A direct, top-level request (what wget makes): same-site, safe, HTTP. }
function DirectRequestContext(IsSecure: Boolean): TCookieRequestContext;

implementation

uses
  SysUtils,
  StrUtils,
  Http.CookieDates,
  Http.PublicSuffixes;

const
  Blanks = [' ', #9];
  { Max-Age 0 or less: "the earliest representable time". }
  EarliestTime = Low(Int64) div 2;

function DirectRequestContext(IsSecure: Boolean): TCookieRequestContext;
begin
  Result.IsSecure := IsSecure;
  Result.SameSite := True;
  Result.TopLevelNavigation := True;
  Result.SafeMethod := True;
  Result.HttpApi := True;
end;

function TrimBlanks(const Text: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and (Text[First] in Blanks) do
    Inc(First);
  while (Last >= First) and (Text[Last] in Blanks) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

function HasControlCharacters(const Text: string): Boolean;
var
  Character: Char;
begin
  for Character in Text do
    if ((Ord(Character) < $20) and (Character <> #9)) or (Ord(Character) = $7F) then
      Exit(True);
  Result := False;
end;

function IsIpAddress(const Host: string): Boolean;
var
  Character: Char;
  AllDigitsAndDots: Boolean;
begin
  if Pos(':', Host) > 0 then
    Exit(True);
  AllDigitsAndDots := Host <> '';
  for Character in Host do
    if not (Character in ['0'..'9', '.']) then
      AllDigitsAndDots := False;
  Result := AllDigitsAndDots;
end;

function DomainMatches(const Host, Domain: string): Boolean;
begin
  if Host = Domain then
    Exit(True);
  if (Domain = '') or IsIpAddress(Host) or (Length(Host) <= Length(Domain)) then
    Exit(False);
  Result := (Copy(Host, Length(Host) - Length(Domain) + 1, MaxInt) = Domain) and
    (Host[Length(Host) - Length(Domain)] = '.');
end;

function PathMatches(const RequestPath, CookiePath: string): Boolean;
begin
  if RequestPath = CookiePath then
    Exit(True);
  if Copy(RequestPath, 1, Length(CookiePath)) <> CookiePath then
    Exit(False);
  if (CookiePath <> '') and (CookiePath[Length(CookiePath)] = '/') then
    Exit(True);
  Result := (Length(RequestPath) > Length(CookiePath)) and (RequestPath[Length(CookiePath) + 1] = '/');
end;

{ The path without its query. }
function PathOnly(const RequestPath: string): string;
var
  QueryStart: Integer;
begin
  QueryStart := Pos('?', RequestPath);
  if QueryStart > 0 then
    Result := Copy(RequestPath, 1, QueryStart - 1)
  else
    Result := RequestPath;
end;

function DefaultCookiePath(const RequestPath: string): string;
var
  Path: string;
  LastSlash: Integer;
begin
  Path := PathOnly(RequestPath);
  if (Path = '') or (Path[1] <> '/') then
    Exit('/');
  LastSlash := Length(Path);
  while (LastSlash > 0) and (Path[LastSlash] <> '/') do
    Dec(LastSlash);
  if LastSlash <= 1 then
    Exit('/');
  Result := Copy(Path, 1, LastSlash - 1);
end;

{ Max-Age: an optional "-" and digits. }
function ParseMaxAge(const Value: string; out Seconds: Int64): Boolean;
var
  Index: Integer;
  Negative: Boolean;
begin
  Seconds := 0;
  if Value = '' then
    Exit(False);
  Negative := Value[1] = '-';
  Index := 1;
  if Negative then
    Inc(Index);
  if Index > Length(Value) then
    Exit(False);
  while Index <= Length(Value) do
  begin
    if not (Value[Index] in ['0'..'9']) then
      Exit(False);
    if Seconds < 100000000000 then
      Seconds := Seconds * 10 + Ord(Value[Index]) - Ord('0');
    Inc(Index);
  end;
  if Negative then
    Seconds := -Seconds;
  Result := True;
end;

procedure ApplyAttribute(const Name, Value: string; Now: Int64; var Cookie: TCookie; var HasDomain: Boolean;
  var HasMaxAge: Boolean);
var
  Seconds: Int64;
  Time: Int64;
  Domain: string;
begin
  if Length(Value) > MaximumAttributeLength then
    Exit;
  if SameText(Name, 'expires') then
  begin
    if not HasMaxAge and ParseCookieDate(Value, Time) then
    begin
      Cookie.Persistent := True;
      Cookie.ExpiryTime := Time;
    end;
  end
  else if SameText(Name, 'max-age') then
  begin
    if ParseMaxAge(Value, Seconds) then
    begin
      HasMaxAge := True;
      Cookie.Persistent := True;
      if Seconds <= 0 then
        Cookie.ExpiryTime := EarliestTime
      else
        Cookie.ExpiryTime := Now + Seconds;
    end;
  end
  else if SameText(Name, 'domain') then
  begin
    Domain := LowerCase(Value);
    if (Domain <> '') and (Domain[1] = '.') then
      Delete(Domain, 1, 1);
    if Domain <> '' then
    begin
      HasDomain := True;
      Cookie.Domain := Domain;
    end;
  end
  else if SameText(Name, 'path') then
  begin
    if (Value <> '') and (Value[1] = '/') then
      Cookie.Path := Value;
  end
  else if SameText(Name, 'secure') then
    Cookie.Secure := True
  else if SameText(Name, 'httponly') then
    Cookie.HttpOnly := True
  else if SameText(Name, 'samesite') then
  begin
    if SameText(Value, 'none') then
      Cookie.SameSite := SameSiteNone
    else if SameText(Value, 'lax') then
      Cookie.SameSite := SameSiteLax
    else if SameText(Value, 'strict') then
      Cookie.SameSite := SameSiteStrict
    else
      Cookie.SameSite := SameSiteDefault;
  end;
end;

function ParseSetCookie(const Header: string; Now: Int64; out Cookie: TCookie; out HasDomain: Boolean): Boolean;
var
  Parts: TStringArray;
  Pair: string;
  Equals: Integer;
  Index: Integer;
  HasMaxAge: Boolean;
begin
  Cookie := Default(TCookie);
  HasDomain := False;
  HasMaxAge := False;
  if HasControlCharacters(Header) then
    Exit(False);
  Parts := Header.Split([';']);
  if Length(Parts) = 0 then
    Exit(False);
  Pair := Parts[0];
  Equals := Pos('=', Pair);
  if Equals = 0 then
  begin
    { A nameless cookie: the whole pair is the value. }
    Cookie.Name := '';
    Cookie.Value := TrimBlanks(Pair);
  end
  else
  begin
    Cookie.Name := TrimBlanks(Copy(Pair, 1, Equals - 1));
    Cookie.Value := TrimBlanks(Copy(Pair, Equals + 1, MaxInt));
  end;
  if ((Cookie.Name = '') and (Cookie.Value = '')) or
     (Length(Cookie.Name) + Length(Cookie.Value) > MaximumNameValueLength) then
    Exit(False);
  for Index := 1 to High(Parts) do
  begin
    Equals := Pos('=', Parts[Index]);
    if Equals = 0 then
      ApplyAttribute(TrimBlanks(Parts[Index]), '', Now, Cookie, HasDomain, HasMaxAge)
    else
      ApplyAttribute(TrimBlanks(Copy(Parts[Index], 1, Equals - 1)), TrimBlanks(Copy(Parts[Index], Equals + 1,
        MaxInt)), Now, Cookie, HasDomain, HasMaxAge);
  end;
  if Cookie.Persistent and (Cookie.ExpiryTime > Now + MaximumLifetime) then
    Cookie.ExpiryTime := Now + MaximumLifetime;
  Cookie.HostOnly := not HasDomain;
  Result := True;
end;

{ The name has the prefix, compared without case (6265bis 5.7). }
function HasNamePrefix(const Name, Prefix: string): Boolean;
begin
  Result := StartsText(Prefix, Name);
end;

{ TCookieJar }

constructor TCookieJar.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor TCookieJar.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TCookieJar.GetCount: Integer;
begin
  EnterCriticalSection(FLock);
  Result := Length(FCookies);
  LeaveCriticalSection(FLock);
end;

function TCookieJar.GetCookie(Index: Integer): TCookie;
begin
  EnterCriticalSection(FLock);
  Result := FCookies[Index];
  LeaveCriticalSection(FLock);
end;

function TCookieJar.Snapshot: TCookieArray;
begin
  EnterCriticalSection(FLock);
  Result := Copy(FCookies, 0, Length(FCookies));
  LeaveCriticalSection(FLock);
end;

function TCookieJar.FindCookie(const Name, Domain, Path: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FCookies) do
    if (FCookies[Index].Name = Name) and (FCookies[Index].Domain = Domain) and (FCookies[Index].Path = Path) then
      Exit(Index);
  Result := -1;
end;

procedure TCookieJar.RemoveAt(Index: Integer);
begin
  Delete(FCookies, Index, 1);
end;

{ The least recently used cookie of the domain (or of all) goes first. }
procedure TCookieJar.EnforceLimits(const Domain: string);
var
  Index, Oldest, InDomain: Integer;
begin
  repeat
    InDomain := 0;
    Oldest := -1;
    for Index := 0 to High(FCookies) do
      if FCookies[Index].Domain = Domain then
      begin
        Inc(InDomain);
        if (Oldest < 0) or (FCookies[Index].LastAccess < FCookies[Oldest].LastAccess) then
          Oldest := Index;
      end;
    if InDomain <= MaximumCookiesPerDomain then
      Break;
    RemoveAt(Oldest);
  until False;
  while Length(FCookies) > MaximumCookies do
  begin
    Oldest := 0;
    for Index := 1 to High(FCookies) do
      if FCookies[Index].LastAccess < FCookies[Oldest].LastAccess then
        Oldest := Index;
    RemoveAt(Oldest);
  end;
end;

procedure TCookieJar.AddCookie(Cookie: TCookie);
var
  Existing: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Existing := FindCookie(Cookie.Name, Cookie.Domain, Cookie.Path);
    if Existing >= 0 then
    begin
      Cookie.CreationOrder := FCookies[Existing].CreationOrder;
      FCookies[Existing] := Cookie;
      Exit;
    end;
    Cookie.CreationOrder := FNextOrder;
    Inc(FNextOrder);
    SetLength(FCookies, Length(FCookies) + 1);
    FCookies[High(FCookies)] := Cookie;
    EnforceLimits(Cookie.Domain);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ An insecure request may not set a cookie over a Secure one of the
  same name whose domain and path cover it (6265bis 5.7 step 16). }
function ShadowsSecureCookie(constref Cookies: TCookieArray; constref Cookie: TCookie): Boolean;
var
  Existing: TCookie;
begin
  for Existing in Cookies do
    if Existing.Secure and (Existing.Name = Cookie.Name) and
       (DomainMatches(Existing.Domain, Cookie.Domain) or DomainMatches(Cookie.Domain, Existing.Domain)) and
       PathMatches(Existing.Path, Cookie.Path) then
      Exit(True);
  Result := False;
end;

function TCookieJar.Store(const Header, Host, RequestPath: string; constref Context: TCookieRequestContext;
  Now: Int64): Boolean;
var
  Cookie: TCookie;
  HasDomain: Boolean;
  LowerHost: string;
  Existing: Integer;
begin
  Result := False;
  if not ParseSetCookie(Header, Now, Cookie, HasDomain) then
    Exit;
  LowerHost := LowerCase(Host);
  if HasDomain then
  begin
    if IsPublicSuffix(Cookie.Domain) then
    begin
      { A public suffix is only the host itself, as a host-only cookie. }
      if Cookie.Domain <> LowerHost then
        Exit;
      HasDomain := False;
    end
    else if not DomainMatches(LowerHost, Cookie.Domain) then
      Exit;
    { A top-level domain (no dot) only for the host of that name. }
    if (Pos('.', Cookie.Domain) = 0) and (Cookie.Domain <> LowerHost) then
      Exit;
  end;
  if not HasDomain then
  begin
    Cookie.Domain := LowerHost;
    Cookie.HostOnly := True;
  end;
  if Cookie.Path = '' then
    Cookie.Path := DefaultCookiePath(RequestPath);
  if Cookie.Secure and not Context.IsSecure then
    Exit;
  if Cookie.HttpOnly and not Context.HttpApi then
    Exit;
  if (Cookie.SameSite = SameSiteNone) and not Cookie.Secure then
    Exit;
  if (Cookie.SameSite <> SameSiteNone) and not Context.SameSite and not Context.TopLevelNavigation then
    Exit;
  if HasNamePrefix(Cookie.Name, '__Secure-') and not (Cookie.Secure and Context.IsSecure) then
    Exit;
  if HasNamePrefix(Cookie.Name, '__Host-') and not (Cookie.Secure and Context.IsSecure and Cookie.HostOnly and
     (Cookie.Path = '/')) then
    Exit;
  Cookie.LastAccess := Now;
  EnterCriticalSection(FLock);
  try
    if not Context.IsSecure and not Cookie.Secure and ShadowsSecureCookie(FCookies, Cookie) then
      Exit;
    Existing := FindCookie(Cookie.Name, Cookie.Domain, Cookie.Path);
    if (Existing >= 0) and FCookies[Existing].HttpOnly and not Context.HttpApi then
      Exit;
    if Cookie.Persistent and (Cookie.ExpiryTime <= Now) then
    begin
      { Expired: it only removes the one it replaces. }
      if Existing >= 0 then
      begin
        RemoveAt(Existing);
        Result := True;
      end;
      Exit;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  AddCookie(Cookie);
  Result := True;
end;

procedure TCookieJar.RemoveExpired(Now: Int64);
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  Index := High(FCookies);
  while Index >= 0 do
  begin
    if FCookies[Index].Persistent and (FCookies[Index].ExpiryTime <= Now) then
      RemoveAt(Index);
    Dec(Index);
  end;
  LeaveCriticalSection(FLock);
end;

procedure TCookieJar.RemoveSessionCookies;
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  Index := High(FCookies);
  while Index >= 0 do
  begin
    if not FCookies[Index].Persistent then
      RemoveAt(Index);
    Dec(Index);
  end;
  LeaveCriticalSection(FLock);
end;

procedure TCookieJar.Clear;
begin
  EnterCriticalSection(FLock);
  FCookies := nil;
  LeaveCriticalSection(FLock);
end;

{ Longer paths first, then the older first. }
function GoesBefore(constref First, Second: TCookie): Boolean;
begin
  if Length(First.Path) <> Length(Second.Path) then
    Exit(Length(First.Path) > Length(Second.Path));
  Result := First.CreationOrder < Second.CreationOrder;
end;

function SameSiteAllows(constref Cookie: TCookie; constref Context: TCookieRequestContext): Boolean;
begin
  if Context.SameSite then
    Exit(True);
  case Cookie.SameSite of
    SameSiteNone: Result := True;
    SameSiteStrict: Result := False;
  else
    Result := Context.TopLevelNavigation and Context.SafeMethod;
  end;
end;

function TCookieJar.Retrieve(const Host, RequestPath: string; constref Context: TCookieRequestContext;
  Now: Int64): string;
var
  Chosen: TCookieArray;
  Swap: TCookie;
  LowerHost, Path: string;
  Index, Inner: Integer;
  DomainOk: Boolean;
begin
  Result := '';
  Chosen := nil;
  LowerHost := LowerCase(Host);
  Path := PathOnly(RequestPath);
  if Path = '' then
    Path := '/';
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(FCookies) do
    begin
      if FCookies[Index].HostOnly then
        DomainOk := LowerHost = FCookies[Index].Domain
      else
        DomainOk := DomainMatches(LowerHost, FCookies[Index].Domain);
      if not DomainOk or not PathMatches(Path, FCookies[Index].Path) then
        Continue;
      if FCookies[Index].Secure and not Context.IsSecure then
        Continue;
      if FCookies[Index].HttpOnly and not Context.HttpApi then
        Continue;
      if not SameSiteAllows(FCookies[Index], Context) then
        Continue;
      if FCookies[Index].Persistent and (FCookies[Index].ExpiryTime <= Now) then
        Continue;
      FCookies[Index].LastAccess := Now;
      SetLength(Chosen, Length(Chosen) + 1);
      Chosen[High(Chosen)] := FCookies[Index];
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  { A few cookies: an insertion sort is enough. }
  for Index := 1 to High(Chosen) do
  begin
    Inner := Index;
    while (Inner > 0) and GoesBefore(Chosen[Inner], Chosen[Inner - 1]) do
    begin
      Swap := Chosen[Inner];
      Chosen[Inner] := Chosen[Inner - 1];
      Chosen[Inner - 1] := Swap;
      Dec(Inner);
    end;
  end;
  for Index := 0 to High(Chosen) do
  begin
    if Index > 0 then
      Result := Result + '; ';
    if Chosen[Index].Name <> '' then
      Result := Result + Chosen[Index].Name + '=';
    Result := Result + Chosen[Index].Value;
  end;
end;

function UrlCookieHost(constref Url: TUrlRecord): string;
begin
  if Url.Host.Kind = UrlHostIpv6 then
    Result := Copy(SerializeHost(Url.Host), 2, Length(SerializeHost(Url.Host)) - 2)
  else
    Result := SerializeHost(Url.Host);
end;

function UrlCookiePath(constref Url: TUrlRecord): string;
begin
  Result := Url.Path;
  if Url.OpaquePath or (Result = '') then
    Result := '/';
end;

function TCookieJar.SetCookieFromResponse(constref Url: TUrlRecord; const Header: string;
  constref Context: TCookieRequestContext; Now: Int64): Boolean;
begin
  Result := Store(Header, UrlCookieHost(Url), UrlCookiePath(Url), Context, Now);
end;

function TCookieJar.CookieFieldFor(constref Url: TUrlRecord; constref Context: TCookieRequestContext;
  Now: Int64): string;
begin
  Result := Retrieve(UrlCookieHost(Url), UrlCookiePath(Url), Context, Now);
end;

function TCookieJar.DocumentCookie(constref Url: TUrlRecord; constref Context: TCookieRequestContext;
  Now: Int64): string;
var
  ScriptContext: TCookieRequestContext;
begin
  ScriptContext := Context;
  ScriptContext.HttpApi := False;
  Result := Retrieve(UrlCookieHost(Url), UrlCookiePath(Url), ScriptContext, Now);
end;

function TCookieJar.SetDocumentCookie(constref Url: TUrlRecord; const Text: string;
  constref Context: TCookieRequestContext; Now: Int64): Boolean;
var
  ScriptContext: TCookieRequestContext;
begin
  ScriptContext := Context;
  ScriptContext.HttpApi := False;
  Result := Store(Text, UrlCookieHost(Url), UrlCookiePath(Url), ScriptContext, Now);
end;

function TCookieJar.ReceiveSetCookie(const Header, Host, RequestPath: string; Now: Int64): Boolean;
begin
  Result := Store(Header, Host, RequestPath, DirectRequestContext(True), Now);
end;

function TCookieJar.CookieHeaderFor(const Host, RequestPath: string; IsSecure: Boolean; Now: Int64): string;
begin
  Result := Retrieve(Host, RequestPath, DirectRequestContext(IsSecure), Now);
end;

end.
