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
  Origins (HTML Standard section 7.1.1, URL Standard section 4.7): a
  tuple origin (scheme, host, port) for ftp, http, https, ws and wss
  URLs, a blob: URL's from the URL in its path (when that is http or
  https), and an opaque origin for everything else (file: included),
  each opaque origin different from every other.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Origins;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

type
  TUrlOrigin = record
    Opaque: Boolean;
    { Tells opaque origins apart. }
    OpaqueIdentity: Int64;
    Scheme: string;
    Host: TUrlHost;
    { UrlPortNull for the scheme's default. }
    Port: LongInt;
  end;

function OriginOfUrl(constref Url: TUrlRecord): TUrlOrigin;
function NewOpaqueOrigin: TUrlOrigin;
function SameOrigin(constref First, Second: TUrlOrigin): Boolean;
{ "https://example.com:8443", or "null" for an opaque origin. }
function SerializeOrigin(constref Origin: TUrlOrigin): string;
{ The origin's scheme is https or wss, or its host is a loopback
  address or "localhost" (a potentially trustworthy origin, Secure
  Contexts section 3.1, without the configuration part). }
function OriginIsPotentiallyTrustworthy(constref Origin: TUrlOrigin): Boolean;

implementation

uses
  SysUtils,
  StrUtils,
  Url.Parser;

var
  NextOpaqueIdentity: Int64 = 0;

function NewOpaqueOrigin: TUrlOrigin;
begin
  Result := Default(TUrlOrigin);
  Result.Opaque := True;
  Result.OpaqueIdentity := InterLockedIncrement64(NextOpaqueIdentity);
  Result.Port := UrlPortNull;
end;

function OriginOfUrl(constref Url: TUrlRecord): TUrlOrigin;
var
  Inner: TUrlRecord;
begin
  if Url.Scheme = 'blob' then
  begin
    if ParseUrl(Url.Path, Inner) and ((Inner.Scheme = 'http') or (Inner.Scheme = 'https')) then
      Exit(OriginOfUrl(Inner));
    Exit(NewOpaqueOrigin);
  end;
  if (Url.Scheme = 'ftp') or (Url.Scheme = 'http') or (Url.Scheme = 'https') or (Url.Scheme = 'ws') or
     (Url.Scheme = 'wss') then
  begin
    Result := Default(TUrlOrigin);
    Result.Scheme := Url.Scheme;
    Result.Host := Url.Host;
    Result.Port := Url.Port;
    Exit;
  end;
  Result := NewOpaqueOrigin;
end;

function SameOrigin(constref First, Second: TUrlOrigin): Boolean;
begin
  if First.Opaque or Second.Opaque then
    Exit(First.Opaque and Second.Opaque and (First.OpaqueIdentity = Second.OpaqueIdentity));
  Result := (First.Scheme = Second.Scheme) and (First.Port = Second.Port) and
    (SerializeHost(First.Host) = SerializeHost(Second.Host));
end;

function SerializeOrigin(constref Origin: TUrlOrigin): string;
begin
  if Origin.Opaque then
    Exit('null');
  Result := Origin.Scheme + '://' + SerializeHost(Origin.Host);
  if Origin.Port <> UrlPortNull then
    Result := Result + ':' + IntToStr(Origin.Port);
end;

function OriginIsPotentiallyTrustworthy(constref Origin: TUrlOrigin): Boolean;
var
  Name: string;
begin
  if Origin.Opaque then
    Exit(False);
  if (Origin.Scheme = 'https') or (Origin.Scheme = 'wss') then
    Exit(True);
  case Origin.Host.Kind of
    UrlHostIpv4: Exit((Origin.Host.Ipv4 shr 24) = 127);
    UrlHostIpv6: Exit((Origin.Host.Ipv6[0] = 0) and (Origin.Host.Ipv6[1] = 0) and (Origin.Host.Ipv6[2] = 0) and
      (Origin.Host.Ipv6[3] = 0) and (Origin.Host.Ipv6[4] = 0) and (Origin.Host.Ipv6[5] = 0) and
      (Origin.Host.Ipv6[6] = 0) and (Origin.Host.Ipv6[7] = 1));
    UrlHostDomain:
      begin
        Name := Origin.Host.Name;
        Exit((Name = 'localhost') or EndsStr('.localhost', Name));
      end;
  end;
  Result := False;
end;

end.
