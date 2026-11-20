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
  How a client gets a transport to an origin: a connector. The system's
  (Http.SocketConnector) looks the host up, connects over TCP and runs
  TLS for https, offering "h2" by ALPN when HTTP/2 is allowed; the host
  test's joins pipes to a server thread. A connector may be called
  from several threads at once.

  Connections that do not run over such a transport (HTTP/3 over QUIC)
  come from the connection factories registered in Http.AltServices.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Connectors;

{$mode objfpc}
{$H+}

interface

uses
  Http.Observers,
  Http.Results,
  Http.Transports,
  Url.Records;

type
  THttpConnector = class
  public
    { A transport to the URL's origin (its NegotiatedProtocol says
      whether HTTP/2 was chosen); the failure otherwise. }
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; virtual; abstract;
  end;

{ "https://host:port" }
function OriginKeyOf(constref Url: TUrlRecord): string;
{ The host as the Host field and :authority write it, the port when not
  the scheme's default. }
function AuthorityOf(constref Url: TUrlRecord): string;
{ The host to look up or show: an IPv6 address without brackets. }
function HostNameOf(constref Url: TUrlRecord): string;

implementation

uses
  SysUtils;

function OriginKeyOf(constref Url: TUrlRecord): string;
begin
  Result := Url.Scheme + '://' + SerializeHost(Url.Host) + ':' + IntToStr(UrlEffectivePort(Url));
end;

function AuthorityOf(constref Url: TUrlRecord): string;
begin
  Result := SerializeHost(Url.Host);
  if Url.Port <> UrlPortNull then
    Result := Result + ':' + IntToStr(Url.Port);
end;

function HostNameOf(constref Url: TUrlRecord): string;
begin
  Result := SerializeHost(Url.Host);
  if Url.Host.Kind = UrlHostIpv6 then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

end.
