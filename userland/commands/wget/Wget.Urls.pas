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
  The URLs wget fetches, http and https only:

    [http:// | https://]host[:port][/path][?query][#fragment]

  A URL without a scheme is http. Parsing and resolving are libhttp's
  URL Standard parser (Url.Parser): hosts lower cased, IDN hosts in
  Punycode, IPv4 and IPv6 hosts read every way the standard reads them,
  dot segments removed, what may not be sent percent-encoded, a
  redirect's Location or a page's link resolved against the URL it
  came from. On top of the standard wget refuses other schemes, user
  names and port 0, and drops the fragment. The host is kept without
  the brackets of an IPv6 address (they are put back in the Host
  header). The file a URL is saved to is the last segment of its path,
  decoded, or index.html.

  Plain Pascal (the RTL and libhttp's URL units), so tools/WgetTest
  checks it on the host.
}
unit Wget.Urls;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

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
{ The URL as libhttp's URL record (for requests). }
function UrlRecordOf(constref Url: TUrl): TUrlRecord;

implementation

uses
  SysUtils,
  StrUtils,
  Url.Parser;

const
  SchemeCharacters = ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'];
  HttpPrefix = 'http://';
  HttpsPrefix = 'https://';
  IndexName = 'index.html';

{ libhttp's parser (its name is hidden by this unit's ParseUrl). }
function ParseUrlRecord(const Text: string; out Parsed: TUrlRecord): Boolean;
begin
  Result := Url.Parser.ParseUrl(Text, Parsed);
end;

function ResolveUrlRecord(const Text: string; constref Base: TUrlRecord; out Parsed: TUrlRecord): Boolean;
begin
  Result := Url.Parser.ParseUrl(Text, Base, Parsed);
end;

function DefaultPort(Scheme: TUrlScheme): Word;
begin
  if Scheme = SchemeHttps then
    Result := 443
  else
    Result := 80;
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

{ A parsed URL as wget's, or False when wget does not take it. }
function FromRecord(constref Parsed: TUrlRecord; out Url: TUrl): Boolean;
var
  Host: string;
begin
  Url := Default(TUrl);
  Result := False;
  if (Parsed.Scheme <> 'http') and (Parsed.Scheme <> 'https') then
    Exit;
  if UrlIncludesCredentials(Parsed) or (Parsed.Port = 0) then
    Exit;
  if not (Parsed.Host.Kind in [UrlHostDomain, UrlHostIpv4, UrlHostIpv6]) then
    Exit;
  Host := SerializeHost(Parsed.Host);
  if Parsed.Host.Kind = UrlHostIpv6 then
    Host := Copy(Host, 2, Length(Host) - 2);
  if (Host = '') or (Length(Host) > MaximumHostLength) then
    Exit;
  if Parsed.Scheme = 'https' then
    Url.Scheme := SchemeHttps
  else
    Url.Scheme := SchemeHttp;
  Url.Host := Host;
  Url.Port := UrlEffectivePort(Parsed);
  Url.Path := Parsed.Path;
  if Url.Path = '' then
    Url.Path := '/';
  if Parsed.HasQuery then
    Url.Path := Url.Path + '?' + Parsed.Query;
  Result := True;
end;

function UrlRecordOf(constref Url: TUrl): TUrlRecord;
begin
  if not ParseUrlRecord(FormatUrl(Url), Result) then
    Result := EmptyUrl;
end;

function ParseUrl(const Text: string; out Url: TUrl): Boolean;
var
  Parsed: TUrlRecord;
  Input: string;
begin
  Url := Default(TUrl);
  Result := False;
  if Trim(Text) = '' then
    Exit;
  Input := Text;
  if not StartsText(HttpPrefix, Input) and not StartsText(HttpsPrefix, Input) then
  begin
    { Another scheme ("ftp://") is refused; "host:port" is not a scheme. }
    if HasOtherScheme(Input) then
      Exit;
    Input := HttpPrefix + Input;
  end;
  Result := ParseUrlRecord(Input, Parsed) and FromRecord(Parsed, Url);
end;

function ResolveUrl(constref Base: TUrl; const Reference: string; out Resolved: TUrl): Boolean;
var
  BaseRecord, Parsed: TUrlRecord;
begin
  Resolved := Base;
  Result := False;
  if Reference = '' then
    Exit;
  if not ParseUrlRecord(FormatUrl(Base), BaseRecord) then
    Exit;
  Result := ResolveUrlRecord(Reference, BaseRecord, Parsed) and FromRecord(Parsed, Resolved);
  if not Result then
    Resolved := Base;
end;

{ The path without its query. }
function PathWithoutQuery(const Path: string): string;
var
  QueryStart: Integer;
begin
  QueryStart := Pos('?', Path);
  if QueryStart > 0 then
    Result := Copy(Path, 1, QueryStart - 1)
  else
    Result := Path;
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
