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
  The URLs wget fetches (RFC 3986, http and https only):

    [http:// | https://]host[:port][/path][?query][#fragment]

  A URL without a scheme is http. The host is a name, an IPv4 address
  or an IPv6 address in brackets ([::1]:8080; kept without them in
  Host, and put back in the Host header); user names are refused, and
  so are IPv6 zones (fe80::1%25eth0). The fragment is dropped;
  characters that may not appear in a request line (controls, spaces,
  bytes above 127) are percent-encoded. A redirect's Location is
  resolved against the URL it came from, relative paths and dot
  segments included. The file a URL is saved to is the last segment of
  its path, decoded, or index.html.

  Plain Pascal (the RTL only), so tools/WgetTest checks it on the host.
}
unit Wget.Urls;

{$mode objfpc}
{$H+}

interface

const
  { The longest host name DNS allows. }
  MaximumHostLength = 255;

type
  TUrlScheme = (SchemeHttp, SchemeHttps);

  TUrl = record
    Scheme: TUrlScheme;
    Host: string;
    Port: Word;
    { From the first "/" on, the query included; at least "/". }
    Path: string;
  end;

function ParseUrl(const Text: string; out Url: TUrl): Boolean;
{ Reference (absolute, "//host/...", "/path" or a relative path)
  against Base. False when the result is not an http or https URL. }
function ResolveUrl(constref Base: TUrl; const Reference: string; out Resolved: TUrl): Boolean;
function DefaultPort(Scheme: TUrlScheme): Word;
{ "https://host:port/path" (the port only when not the default). }
function FormatUrl(constref Url: TUrl): string;
{ True if the URL's host is an IPv6 address (it has a colon). }
function UrlHostIsIpv6(constref Url: TUrl): Boolean;
{ The Host header: the host (an IPv6 address in brackets), and the port
  when not the default. }
function FormatHostHeader(constref Url: TUrl): string;
{ The local file name: the last path segment, decoded, or
  "index.html"; never with a "/" or a leading dot only. }
function DefaultFileName(constref Url: TUrl): string;
{ A path segment with its %XX escapes decoded, but for those that would
  put a "/", a NUL or a control character in a file name. }
function DecodeFileName(const Segment: string): string;

implementation

uses
  SysUtils,
  StrUtils;

const
  SchemeCharacters = ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'];
  UnsafePathCharacters = ['"', '<', '>', '\', '^', '`', '{', '|', '}'];
  HttpPrefix = 'http://';
  HttpsPrefix = 'https://';
  IndexName = 'index.html';

function DefaultPort(Scheme: TUrlScheme): Word;
begin
  if Scheme = SchemeHttps then
    Result := 443
  else
    Result := 80;
end;

{ A path, percent-encoding what may not be sent as it is. }
function EncodePath(const Source: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Source do
    if (Ord(Character) <= 32) or (Ord(Character) >= 127) or (Character in UnsafePathCharacters) then
      Result := Result + '%' + IntToHex(Ord(Character), 2)
    else
      Result := Result + Character;
end;

{ "[ipv6]" at the start of the authority: the address (hexadecimal
  digits, colons and dots) goes into Url.Host without the brackets;
  HostEnd is where what follows the closing bracket begins. }
function ParseBracketedHost(const Authority: string; var Url: TUrl; out HostEnd: Integer): Boolean;
var
  Closing: Integer;
  Index: Integer;
begin
  Result := False;
  HostEnd := 0;
  Closing := Pos(']', Authority);
  if (Closing = 0) or (Closing = 2) or (Closing - 2 > MaximumHostLength) then
    Exit;
  for Index := 2 to Closing - 1 do
    if not (Authority[Index] in ['0'..'9', 'a'..'f', 'A'..'F', ':', '.']) then
      Exit;
  Url.Host := LowerCase(Copy(Authority, 2, Closing - 2));
  HostEnd := Closing + 1;
  Result := (HostEnd > Length(Authority)) or (Authority[HostEnd] = ':');
end;

{ A name or an IPv4 address up to the port's colon. }
function ParsePlainHost(const Authority: string; var Url: TUrl; out HostEnd: Integer): Boolean;
var
  Index: Integer;
begin
  Result := False;
  HostEnd := Pos(':', Authority);
  if HostEnd = 0 then
    HostEnd := Length(Authority) + 1;
  if (HostEnd = 1) or (HostEnd - 1 > MaximumHostLength) then
    Exit;
  for Index := 1 to HostEnd - 1 do
    if not (Authority[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_']) then
      Exit;
  Url.Host := LowerCase(Copy(Authority, 1, HostEnd - 1));
  Result := True;
end;

{ ":port" after the host: 1 to 65535; an empty port means the default. }
function ParsePort(const Text: string; var Url: TUrl): Boolean;
var
  Port: LongWord;
  Character: Char;
begin
  Result := False;
  if Text = '' then
    Exit(True);
  Port := 0;
  for Character in Text do
  begin
    if not (Character in ['0'..'9']) then
      Exit;
    Port := Port * 10 + LongWord(Ord(Character) - Ord('0'));
    if Port > 65535 then
      Exit;
  end;
  if Port = 0 then
    Exit;
  Url.Port := Port;
  Result := True;
end;

function ParseAuthority(const Authority: string; var Url: TUrl): Boolean;
var
  HostEnd: Integer;
begin
  Result := False;
  { No user names. }
  if (Authority = '') or (Pos('@', Authority) > 0) then
    Exit;
  if Authority[1] = '[' then
  begin
    if not ParseBracketedHost(Authority, Url, HostEnd) then
      Exit;
  end
  else if not ParsePlainHost(Authority, Url, HostEnd) then
    Exit;
  Url.Port := DefaultPort(Url.Scheme);
  Result := ParsePort(Copy(Authority, HostEnd + 1, MaxInt), Url);
end;

{ The position of the first of Characters in Text from Start on, or
  just past its end. }
function FindAny(const Text: string; Start: Integer; Characters: TSysCharSet): Integer;
begin
  Result := Start;
  while (Result <= Length(Text)) and not (Text[Result] in Characters) do
    Inc(Result);
end;

{ Text starts with "scheme://" of a scheme other than http(s). }
function HasOtherScheme(const Text: string): Boolean;
var
  SchemeEnd: Integer;
begin
  SchemeEnd := 1;
  while (SchemeEnd <= Length(Text)) and (Text[SchemeEnd] in SchemeCharacters) do
    Inc(SchemeEnd);
  Result := Copy(Text, SchemeEnd, 3) = '://';
end;

function ParseUrl(const Text: string; out Url: TUrl): Boolean;
var
  Rest: string;
  AuthorityEnd, PathEnd: Integer;
  PathText: string;
begin
  Url := Default(TUrl);
  Result := False;
  if Text = '' then
    Exit;
  Url.Scheme := SchemeHttp;
  if StartsText(HttpsPrefix, Text) then
  begin
    Url.Scheme := SchemeHttps;
    Rest := Copy(Text, Length(HttpsPrefix) + 1, MaxInt);
  end
  else if StartsText(HttpPrefix, Text) then
    Rest := Copy(Text, Length(HttpPrefix) + 1, MaxInt)
  else
  begin
    { Another scheme ("ftp:") is refused; "host:port" is not a scheme. }
    if HasOtherScheme(Text) then
      Exit;
    Rest := Text;
  end;
  AuthorityEnd := FindAny(Rest, 1, ['/', '?', '#']);
  if not ParseAuthority(Copy(Rest, 1, AuthorityEnd - 1), Url) then
    Exit;
  PathEnd := FindAny(Rest, AuthorityEnd, ['#']);
  PathText := Copy(Rest, AuthorityEnd, PathEnd - AuthorityEnd);
  if PathText = '' then
    Url.Path := '/'
  else if PathText[1] = '?' then
    { "host?query": the path is "/". }
    Url.Path := '/' + EncodePath(PathText)
  else
    Url.Path := EncodePath(PathText);
  Result := True;
end;

{ Drops the last segment (and its "/") of Output. }
procedure DropLastSegment(var Output: string);
var
  Cut: Integer;
begin
  Cut := Length(Output);
  while (Cut > 0) and (Output[Cut] <> '/') do
    Dec(Cut);
  if Cut > 0 then
    Dec(Cut);
  SetLength(Output, Cut);
end;

{ RFC 3986 section 5.2.4 on a path that starts with "/" (the query, if
  any, left alone). }
function RemoveDotSegments(const Path: string): string;
var
  QueryStart, Input, SegmentEnd: Integer;
  Segment: string;
begin
  QueryStart := FindAny(Path, 1, ['?']);
  Result := '';
  Input := 1;
  while Input < QueryStart do
  begin
    { Path[Input] is "/" here. }
    SegmentEnd := FindAny(Path, Input + 1, ['/']);
    if SegmentEnd > QueryStart then
      SegmentEnd := QueryStart;
    Segment := Copy(Path, Input, SegmentEnd - Input);
    if (Segment = '/.') or (Segment = '/..') then
    begin
      if Segment = '/..' then
        DropLastSegment(Result);
      if SegmentEnd = QueryStart then
        Result := Result + '/';
    end
    else
      Result := Result + Segment;
    Input := SegmentEnd;
  end;
  if Result = '' then
    Result := '/';
  Result := Result + Copy(Path, QueryStart, MaxInt);
end;

{ The base path without its query. }
function PathWithoutQuery(const Path: string): string;
begin
  Result := Copy(Path, 1, FindAny(Path, 1, ['?']) - 1);
end;

{ The base path up to and including its last "/" (before the query). }
function PathDirectory(const Path: string): string;
begin
  Result := PathWithoutQuery(Path);
  SetLength(Result, RPos('/', Result));
end;

function ResolveUrl(constref Base: TUrl; const Reference: string; out Resolved: TUrl): Boolean;
var
  Merged: string;
  SchemeEnd: Integer;
begin
  Resolved := Base;
  Result := False;
  if Reference = '' then
    Exit;
  if StartsText(HttpPrefix, Reference) or StartsText(HttpsPrefix, Reference) then
    Exit(ParseUrl(Reference, Resolved));
  { Another scheme: refused. }
  SchemeEnd := 1;
  while (SchemeEnd <= Length(Reference)) and (Reference[SchemeEnd] in SchemeCharacters) do
    Inc(SchemeEnd);
  if (SchemeEnd > 1) and (SchemeEnd <= Length(Reference)) and (Reference[SchemeEnd] = ':') then
    Exit;
  if StartsStr('//', Reference) then
  begin
    { Network path: the base's scheme. }
    if Base.Scheme = SchemeHttps then
      Exit(ParseUrl('https:' + Reference, Resolved))
    else
      Exit(ParseUrl('http:' + Reference, Resolved));
  end;

  if Reference[1] = '/' then
    Merged := Reference
  else if Reference[1] = '?' then
    { The base path with a new query. }
    Merged := PathWithoutQuery(Base.Path) + Reference
  else
    { The base path up to its last "/", then the reference. }
    Merged := PathDirectory(Base.Path) + Reference;
  { Drop a fragment. }
  Merged := Copy(Merged, 1, FindAny(Merged, 1, ['#']) - 1);
  Resolved.Path := RemoveDotSegments(EncodePath(Merged));
  Result := True;
end;

function UrlHostIsIpv6(constref Url: TUrl): Boolean;
begin
  Result := Pos(':', Url.Host) > 0;
end;

function FormatHostHeader(constref Url: TUrl): string;
begin
  if UrlHostIsIpv6(Url) then
    Result := '[' + Url.Host + ']'
  else
    Result := Url.Host;
  if Url.Port <> DefaultPort(Url.Scheme) then
    Result := Result + ':' + IntToStr(Url.Port);
end;

function FormatUrl(constref Url: TUrl): string;
begin
  if Url.Scheme = SchemeHttps then
    Result := HttpsPrefix
  else
    Result := HttpPrefix;
  Result := Result + FormatHostHeader(Url) + Url.Path;
end;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ Segment with its %XX escapes decoded, but for those that would put a
  "/", a NUL or a control character in a file name. }
function DecodeFileName(const Segment: string): string;
var
  Index: Integer;
  Character: Char;
  Decoded: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Segment) do
  begin
    Character := Segment[Index];
    if (Character = '%') and (Index + 2 <= Length(Segment)) and (HexValue(Segment[Index + 1]) >= 0) and
       (HexValue(Segment[Index + 2]) >= 0) then
    begin
      Decoded := HexValue(Segment[Index + 1]) * 16 + HexValue(Segment[Index + 2]);
      if (Decoded >= 32) and (Decoded <> Ord('/')) and (Decoded <> 127) then
      begin
        Character := Chr(Decoded);
        Index := Index + 2;
      end;
    end;
    Result := Result + Character;
    Inc(Index);
  end;
end;

function DefaultFileName(constref Url: TUrl): string;
var
  Path: string;
begin
  Path := PathWithoutQuery(Url.Path);
  Result := DecodeFileName(Copy(Path, RPos('/', Path) + 1, MaxInt));
  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := IndexName;
end;

end.
