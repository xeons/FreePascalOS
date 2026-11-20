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
  The network side of a browser profile, shared by its pages (and their
  threads): libhttp's client (connections, cookie jar, HTTP cache,
  authentication), the HSTS known hosts, the CORS preflight cache, and
  the fields every request carries (Accept-Language). Everything in it
  is thread safe.
}
unit Web.Fetch.NetworkContexts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.Client,
  Http.Cookies,
  Http.Cache,
  Web.Fetch.Hsts,
  Web.Fetch.Cors;

type
  TNetworkContext = class
  private
    FClient: THttpClient;
    FOwnsClient: Boolean;
    FHsts: THstsStore;
    FPreflightCache: TCorsPreflightCache;
    FOwnedCookies: TCookieJar;
    FOwnedCache: THttpCache;
    FAcceptLanguage: string;
    FAllowFileAccess: Boolean;
  public
    { Client: the HTTP client (owned when OwnsClient). A client without
      a cookie jar or cache gets one of the context's. }
    constructor Create(Client: THttpClient; OwnsClient: Boolean = True);
    destructor Destroy; override;
    property Client: THttpClient read FClient;
    property Hsts: THstsStore read FHsts;
    property PreflightCache: TCorsPreflightCache read FPreflightCache;
    property AcceptLanguage: string read FAcceptLanguage write FAcceptLanguage;
    { file: URLs may be opened (the browser; a web view may refuse). }
    property AllowFileAccess: Boolean read FAllowFileAccess write FAllowFileAccess;
  end;

implementation

constructor TNetworkContext.Create(Client: THttpClient; OwnsClient: Boolean);
begin
  inherited Create;
  FClient := Client;
  FOwnsClient := OwnsClient;
  FHsts := THstsStore.Create;
  FPreflightCache := TCorsPreflightCache.Create;
  FAcceptLanguage := 'en-US,en;q=0.9';
  FAllowFileAccess := True;
  if FClient.Cookies = nil then
  begin
    FOwnedCookies := TCookieJar.Create;
    FClient.Cookies := FOwnedCookies;
  end;
  if FClient.Cache = nil then
  begin
    FOwnedCache := THttpCache.Create;
    FClient.Cache := FOwnedCache;
  end;
end;

destructor TNetworkContext.Destroy;
begin
  if FOwnedCookies <> nil then
    FClient.Cookies := nil;
  if FOwnedCache <> nil then
    FClient.Cache := nil;
  if FOwnsClient then
    FClient.Free;
  FOwnedCookies.Free;
  FOwnedCache.Free;
  FHsts.Free;
  FPreflightCache.Free;
  inherited Destroy;
end;

end.
