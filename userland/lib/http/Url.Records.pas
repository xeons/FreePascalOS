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
  A URL as the WHATWG URL Standard has it (section 4.1, "URL
  representation"): scheme, username, password, host (null, empty, a
  domain, an IPv4 or IPv6 address, or an opaque host), port (null or
  0..65535), path, query and fragment (each null or a string).

  The path is kept serialized, which is compact and what most callers
  want: a list of segments ["a", "b", ""] is "/a/b/", the empty list is
  "" and [""] is "/". A URL with an opaque path ("mailto:x@y") keeps
  that path as it is, with OpaquePath set. Everything is ASCII once
  parsed (non-ASCII is percent-encoded or punycode), so strings are
  plain byte strings.

  The special schemes and their default ports (ftp 21, file none, http
  80, https 443, ws 80, wss 443) are here, and the URL serializer
  (section 4.5).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Records;

{$mode objfpc}
{$H+}

interface

uses
  Url.IpAddresses;

const
  UrlPortNull = -1;

type
  TUrlHostKind = (UrlHostNull, UrlHostEmpty, UrlHostDomain, UrlHostIpv4, UrlHostIpv6, UrlHostOpaque);

  TUrlHost = record
    Kind: TUrlHostKind;
    { A domain (ASCII, lower case) or an opaque host, as serialized. }
    Name: string;
    Ipv4: LongWord;
    Ipv6: TIpv6Groups;
  end;

  TUrlRecord = record
    { Lower case, without the ":". Empty only for a URL not parsed. }
    Scheme: string;
    Username: string;
    Password: string;
    Host: TUrlHost;
    { UrlPortNull, or the port (never the scheme's default). }
    Port: LongInt;
    { The path serialized: "/a/b" for segments, or the opaque path. }
    Path: string;
    OpaquePath: Boolean;
    HasQuery: Boolean;
    Query: string;
    HasFragment: Boolean;
    Fragment: string;
  end;

  PUrlRecord = ^TUrlRecord;

{ A URL with every component null or empty. }
function EmptyUrl: TUrlRecord;
function IsSpecialScheme(const Scheme: string): Boolean;
{ The scheme's default port, or UrlPortNull. }
function DefaultPortOfScheme(const Scheme: string): LongInt;
function UrlIsSpecial(constref Url: TUrlRecord): Boolean;
function UrlIncludesCredentials(constref Url: TUrlRecord): Boolean;
{ The port, or the scheme's default when it is null (UrlPortNull for
  schemes without one). }
function UrlEffectivePort(constref Url: TUrlRecord): LongInt;

{ Path segments. }
function PathSegmentCount(constref Url: TUrlRecord): Integer;
{ Segment Index (0 based) of a URL without an opaque path. }
function PathSegment(constref Url: TUrlRecord; Index: Integer): string;
procedure AppendPathSegment(var Url: TUrlRecord; const Segment: string);
{ Section 4.1 "shorten a URL's path". }
procedure ShortenPath(var Url: TUrlRecord);

{ The host serializer (section 3.6). }
function SerializeHost(constref Host: TUrlHost): string;
{ The URL serializer; ExcludeFragment leaves out "#...". }
function SerializeUrl(constref Url: TUrlRecord; ExcludeFragment: Boolean = False): string;
{ The URL path serializer. }
function SerializePath(constref Url: TUrlRecord): string;

{ A Windows drive letter ("c:" or "c|"); normalized: only "c:". }
function IsWindowsDriveLetter(const Text: string; Normalized: Boolean = False): Boolean;

implementation

uses
  SysUtils;

function EmptyUrl: TUrlRecord;
begin
  Result := Default(TUrlRecord);
  Result.Port := UrlPortNull;
end;

function IsSpecialScheme(const Scheme: string): Boolean;
begin
  Result := (Scheme = 'http') or (Scheme = 'https') or (Scheme = 'ws') or (Scheme = 'wss') or
    (Scheme = 'ftp') or (Scheme = 'file');
end;

function DefaultPortOfScheme(const Scheme: string): LongInt;
begin
  if (Scheme = 'http') or (Scheme = 'ws') then
    Result := 80
  else if (Scheme = 'https') or (Scheme = 'wss') then
    Result := 443
  else if Scheme = 'ftp' then
    Result := 21
  else
    Result := UrlPortNull;
end;

function UrlIsSpecial(constref Url: TUrlRecord): Boolean;
begin
  Result := IsSpecialScheme(Url.Scheme);
end;

function UrlIncludesCredentials(constref Url: TUrlRecord): Boolean;
begin
  Result := (Url.Username <> '') or (Url.Password <> '');
end;

function UrlEffectivePort(constref Url: TUrlRecord): LongInt;
begin
  if Url.Port <> UrlPortNull then
    Result := Url.Port
  else
    Result := DefaultPortOfScheme(Url.Scheme);
end;

function PathSegmentCount(constref Url: TUrlRecord): Integer;
var
  Character: Char;
begin
  Result := 0;
  if Url.OpaquePath then
    Exit(1);
  for Character in Url.Path do
    if Character = '/' then
      Inc(Result);
end;

function PathSegment(constref Url: TUrlRecord; Index: Integer): string;
var
  Position, Start: Integer;
  Current: Integer;
begin
  Result := '';
  Current := -1;
  Position := 1;
  Start := 0;
  while Position <= Length(Url.Path) do
  begin
    if Url.Path[Position] = '/' then
    begin
      if Current = Index then
        Exit(Copy(Url.Path, Start, Position - Start));
      Inc(Current);
      Start := Position + 1;
    end;
    Inc(Position);
  end;
  if Current = Index then
    Result := Copy(Url.Path, Start, MaxInt);
end;

procedure AppendPathSegment(var Url: TUrlRecord; const Segment: string);
begin
  Url.Path := Url.Path + '/' + Segment;
end;

procedure ShortenPath(var Url: TUrlRecord);
var
  Cut: Integer;
begin
  if (Url.Scheme = 'file') and (PathSegmentCount(Url) = 1) and IsWindowsDriveLetter(PathSegment(Url, 0), True) then
    Exit;
  Cut := Length(Url.Path);
  while (Cut > 0) and (Url.Path[Cut] <> '/') do
    Dec(Cut);
  if Cut > 0 then
    SetLength(Url.Path, Cut - 1);
end;

function IsWindowsDriveLetter(const Text: string; Normalized: Boolean): Boolean;
begin
  Result := (Length(Text) = 2) and (Text[1] in ['a'..'z', 'A'..'Z']) and
    ((Text[2] = ':') or (not Normalized and (Text[2] = '|')));
end;

function SerializeHost(constref Host: TUrlHost): string;
begin
  case Host.Kind of
    UrlHostIpv4: Result := SerializeIpv4(Host.Ipv4);
    UrlHostIpv6: Result := '[' + SerializeIpv6(Host.Ipv6) + ']';
    UrlHostDomain, UrlHostOpaque: Result := Host.Name;
  else
    Result := '';
  end;
end;

function SerializePath(constref Url: TUrlRecord): string;
begin
  Result := Url.Path;
end;

function SerializeUrl(constref Url: TUrlRecord; ExcludeFragment: Boolean): string;
begin
  Result := Url.Scheme + ':';
  if Url.Host.Kind <> UrlHostNull then
  begin
    Result := Result + '//';
    if UrlIncludesCredentials(Url) then
    begin
      Result := Result + Url.Username;
      if Url.Password <> '' then
        Result := Result + ':' + Url.Password;
      Result := Result + '@';
    end;
    Result := Result + SerializeHost(Url.Host);
    if Url.Port <> UrlPortNull then
      Result := Result + ':' + IntToStr(Url.Port);
  end
  else if not Url.OpaquePath and (PathSegmentCount(Url) > 1) and (Copy(Url.Path, 1, 2) = '//') then
    { "web+demo:/.//not-a-host/": the path would read as a host. }
    Result := Result + '/.';
  Result := Result + Url.Path;
  if Url.HasQuery then
    Result := Result + '?' + Url.Query;
  if not ExcludeFragment and Url.HasFragment then
    Result := Result + '#' + Url.Fragment;
end;

end.
