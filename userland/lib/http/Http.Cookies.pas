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
  wget's cookie jar, as RFC 6265 has a user agent keep cookies:

  - Set-Cookie is read as section 5.2 says: the name and value before
    the first ";", then Expires, Max-Age (which wins over Expires),
    Domain, Path, Secure and HttpOnly; unknown attributes are ignored;
  - a cookie is stored (5.3) only if the request's host domain-matches
    its Domain (a cookie without one is for that host alone); a Domain
    without a dot (a top-level domain) is refused unless it is the host
    itself, as is a Domain for an IP address that is not that address;
    without a Path (or one not starting with "/") the default path is
    the request's directory; a cookie with the name, domain and path of
    one already kept replaces it, and an expired one removes it;
  - a request gets (5.4) the cookies whose domain and path match it,
    only the Secure ones over https, longer paths first, then older
    ones first, as "name=value; name2=value2".

  Times are seconds since 1970 (UTC); "now" is passed in, so the host
  test can choose it.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Http.Cookies;

{$mode objfpc}
{$H+}

interface

type
  TCookie = record
    Name, Value: string;
    { Lower case, without a leading dot. }
    Domain: string;
    { Set without a Domain attribute: for exactly that host. }
    HostOnly: Boolean;
    Path: string;
    Secure: Boolean;
    HttpOnly: Boolean;
    { Has an expiry (else it ends with the session). }
    Persistent: Boolean;
    ExpiryTime: Int64;
    { The order cookies were first made in. }
    CreationOrder: Int64;
  end;

  TCookieArray = array of TCookie;

  TCookieJar = class
  private
    FCookies: TCookieArray;
    FNextOrder: Int64;
    function FindCookie(const Name, Domain, Path: string): Integer;
    procedure RemoveAt(Index: Integer);
    function GetCount: Integer;
    function GetCookie(Index: Integer): TCookie;
  public
    { Reads one Set-Cookie value received for Host and RequestPath (the
      URL's path, query included). Returns True if the jar changed. }
    function ReceiveSetCookie(const Header, Host, RequestPath: string; Now: Int64): Boolean;
    { Keeps a cookie as it is (from a cookie file): replaces one with the
      same name, domain and path. }
    procedure AddCookie(Cookie: TCookie);
    { The Cookie header for a request ('' if no cookie goes). }
    function CookieHeaderFor(const Host, RequestPath: string; IsSecure: Boolean; Now: Int64): string;
    { Drops expired cookies. }
    procedure RemoveExpired(Now: Int64);
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
  when it had none; ExpiryTime from Max-Age or Expires). False if it
  has no name-value pair. }
function ParseSetCookie(const Header: string; Now: Int64; out Cookie: TCookie; out HasDomain: Boolean): Boolean;

implementation

uses
  SysUtils,
  Http.CookieDates;

const
  Blanks = [' ', #9];
  { Max-Age 0 or less: "the earliest representable time". }
  EarliestTime = Low(Int64) div 2;

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
    Cookie.HttpOnly := True;
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
  Parts := Header.Split([';']);
  if Length(Parts) = 0 then
    Exit(False);
  Pair := Parts[0];
  Equals := Pos('=', Pair);
  if Equals = 0 then
    Exit(False);
  Cookie.Name := TrimBlanks(Copy(Pair, 1, Equals - 1));
  Cookie.Value := TrimBlanks(Copy(Pair, Equals + 1, MaxInt));
  if Cookie.Name = '' then
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
  Cookie.HostOnly := not HasDomain;
  Result := True;
end;

function TCookieJar.GetCount: Integer;
begin
  Result := Length(FCookies);
end;

function TCookieJar.GetCookie(Index: Integer): TCookie;
begin
  Result := FCookies[Index];
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

procedure TCookieJar.AddCookie(Cookie: TCookie);
var
  Existing: Integer;
begin
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
end;

function TCookieJar.ReceiveSetCookie(const Header, Host, RequestPath: string; Now: Int64): Boolean;
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
    if not DomainMatches(LowerHost, Cookie.Domain) then
      Exit;
    { A top-level domain (no dot) only for the host of that name. }
    if (Pos('.', Cookie.Domain) = 0) and (Cookie.Domain <> LowerHost) then
      Exit;
  end
  else
    Cookie.Domain := LowerHost;
  if Cookie.Path = '' then
    Cookie.Path := DefaultCookiePath(RequestPath);
  if Cookie.Persistent and (Cookie.ExpiryTime <= Now) then
  begin
    { Expired: it only removes the one it replaces. }
    Existing := FindCookie(Cookie.Name, Cookie.Domain, Cookie.Path);
    if Existing >= 0 then
    begin
      RemoveAt(Existing);
      Result := True;
    end;
    Exit;
  end;
  AddCookie(Cookie);
  Result := True;
end;

procedure TCookieJar.RemoveExpired(Now: Int64);
var
  Index: Integer;
begin
  Index := High(FCookies);
  while Index >= 0 do
  begin
    if FCookies[Index].Persistent and (FCookies[Index].ExpiryTime <= Now) then
      RemoveAt(Index);
    Dec(Index);
  end;
end;

{ Longer paths first, then the older first. }
function GoesBefore(constref First, Second: TCookie): Boolean;
begin
  if Length(First.Path) <> Length(Second.Path) then
    Exit(Length(First.Path) > Length(Second.Path));
  Result := First.CreationOrder < Second.CreationOrder;
end;

function TCookieJar.CookieHeaderFor(const Host, RequestPath: string; IsSecure: Boolean; Now: Int64): string;
var
  Chosen: TCookieArray;
  Cookie, Swap: TCookie;
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
  for Cookie in FCookies do
  begin
    if Cookie.HostOnly then
      DomainOk := LowerHost = Cookie.Domain
    else
      DomainOk := DomainMatches(LowerHost, Cookie.Domain);
    if not DomainOk or not PathMatches(Path, Cookie.Path) then
      Continue;
    if Cookie.Secure and not IsSecure then
      Continue;
    if Cookie.Persistent and (Cookie.ExpiryTime <= Now) then
      Continue;
    SetLength(Chosen, Length(Chosen) + 1);
    Chosen[High(Chosen)] := Cookie;
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
    Result := Result + Chosen[Index].Name + '=' + Chosen[Index].Value;
  end;
end;

end.
