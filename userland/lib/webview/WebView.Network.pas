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
  The network a program's web views share (a profile): one libhttp
  client over the system's sockets with a cookie jar and an in-memory
  cache, wrapped in libweb's TNetworkContext (HSTS, CORS preflights),
  made when the first web view needs it. Local files may be shown (the
  fetcher still keeps them from pages that are not local themselves).

  HTTP/3 needs libquic, which libwebview does not link: a program that
  wants it links libquic and calls Http3.SystemConnections.EnableHttp3
  before its first web view; Http3Allowed turns its use on and off.
}
unit WebView.Network;

{$mode objfpc}
{$H+}

interface

uses
  Web.Fetch.NetworkContexts;

const
  WebViewUserAgent = 'Mozilla/5.0 (FreePascalOS) libweb/1.0';

{ The program's shared network context. }
function SharedNetworkContext: TNetworkContext;
{ Whether HTTP/3 is used where an origin offers it (and libquic's
  factory is registered). }
function Http3Allowed: Boolean;
procedure SetHttp3Allowed(Allowed: Boolean);
{ Frees the shared context (at the program's end; web views must be gone). }
procedure FreeSharedNetworkContext;

implementation

uses
  Http.Observers,
  Http.Client,
  Http.Cookies,
  Http.Cache,
  Http.SocketConnector;

var
  Shared: TNetworkContext = nil;
  SharedCookies: TCookieJar = nil;
  SharedCache: THttpCache = nil;
  AllowHttp3: Boolean = True;

function SharedNetworkContext: TNetworkContext;
var
  Settings: THttpClientSettings;
  Client: THttpClient;
begin
  if Shared = nil then
  begin
    Settings := DefaultClientSettings;
    Settings.UserAgent := WebViewUserAgent;
    Settings.AllowHttp3 := AllowHttp3;
    Client := CreateSystemClient(Settings);
    { The client does not own its jar and cache. }
    SharedCookies := TCookieJar.Create;
    SharedCache := THttpCache.Create;
    Client.Cookies := SharedCookies;
    Client.Cache := SharedCache;
    Shared := TNetworkContext.Create(Client, True);
    Shared.AllowFileAccess := True;
  end;
  Result := Shared;
end;

function Http3Allowed: Boolean;
begin
  Result := AllowHttp3;
end;

procedure SetHttp3Allowed(Allowed: Boolean);
var
  Settings: THttpClientSettings;
begin
  AllowHttp3 := Allowed;
  if Shared = nil then
    Exit;
  Settings := Shared.Client.Settings;
  Settings.AllowHttp3 := Allowed;
  Shared.Client.Settings := Settings;
end;

procedure FreeSharedNetworkContext;
begin
  Shared.Free;
  Shared := nil;
  SharedCookies.Free;
  SharedCookies := nil;
  SharedCache.Free;
  SharedCache := nil;
end;

end.
