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
  Url.Records,
  Web.Fetch.Hsts,
  Web.Fetch.Cors,
  Web.Fetch.Transports;

type
  TNetworkContext = class
  private
    FClient: THttpClient;
    FOwnsClient: Boolean;
    FHsts: THstsStore;
    FOwnHsts: THstsStore;
    FPreflightCache: TCorsPreflightCache;
    FOwnedCookies: TCookieJar;
    FOwnedCache: THttpCache;
    FAcceptLanguage: string;
    FAllowFileAccess: Boolean;
    FTransport: TNetworkTransport;
  public
    { Client: the HTTP client (owned when OwnsClient). A client without
      a cookie jar or cache gets one of the context's. }
    constructor Create(Client: THttpClient; OwnsClient: Boolean = True);
    { The network of another process (a renderer's): no client here,
      every exchange, local file and cookie through Transport (owned). }
    constructor CreateForTransport(Transport: TNetworkTransport);
    destructor Destroy; override;
    { document.cookie of a document at Url (Secure: its context is). }
    function DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string;
    procedure SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean);
    { nil when the network is another process's (Transport). }
    property Client: THttpClient read FClient;
    property Transport: TNetworkTransport read FTransport;
    property Hsts: THstsStore read FHsts;
    { Another HSTS store in use instead of the context's own (not owned;
      it must outlive its use); nil: the own one again. A browser's
      private browsing. }
    procedure UseHstsStore(Store: THstsStore);
    property PreflightCache: TCorsPreflightCache read FPreflightCache;
    property AcceptLanguage: string read FAcceptLanguage write FAcceptLanguage;
    { file: URLs may be opened (the browser; a web view may refuse). }
    property AllowFileAccess: Boolean read FAllowFileAccess write FAllowFileAccess;
  end;

type
  TNetworkContextGoingHook = procedure(Network: TNetworkContext);

var
  { Called first when a network context is freed: what still uses it
    (worker agents, Web.Workers.Agents) goes with it. }
  NetworkContextGoingHook: TNetworkContextGoingHook;

implementation

uses
  DateUtils;

function UnixTimeNow: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now));
end;

{ What document.cookie reads and writes under (not an HTTP API). }
function ScriptCookieContext(Secure: Boolean): TCookieRequestContext;
begin
  Result := Default(TCookieRequestContext);
  Result.IsSecure := Secure;
  Result.SameSite := True;
  Result.SafeMethod := True;
  Result.HttpApi := False;
end;

constructor TNetworkContext.Create(Client: THttpClient; OwnsClient: Boolean);
begin
  inherited Create;
  FClient := Client;
  FOwnsClient := OwnsClient;
  FOwnHsts := THstsStore.Create;
  FHsts := FOwnHsts;
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

constructor TNetworkContext.CreateForTransport(Transport: TNetworkTransport);
begin
  inherited Create;
  FTransport := Transport;
  FOwnHsts := THstsStore.Create;
  FHsts := FOwnHsts;
  FPreflightCache := TCorsPreflightCache.Create;
  FAcceptLanguage := 'en-US,en;q=0.9';
  FAllowFileAccess := True;
end;

function TNetworkContext.DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string;
begin
  Result := '';
  if FTransport <> nil then
    Result := FTransport.DocumentCookie(Url, Secure)
  else if (FClient <> nil) and (FClient.Cookies <> nil) then
    Result := FClient.Cookies.DocumentCookie(Url, ScriptCookieContext(Secure), UnixTimeNow);
end;

procedure TNetworkContext.SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean);
begin
  if FTransport <> nil then
    FTransport.SetDocumentCookie(Url, Cookie, Secure)
  else if (FClient <> nil) and (FClient.Cookies <> nil) then
    FClient.Cookies.SetDocumentCookie(Url, Cookie, ScriptCookieContext(Secure), UnixTimeNow);
end;

procedure TNetworkContext.UseHstsStore(Store: THstsStore);
begin
  if Store = nil then
    FHsts := FOwnHsts
  else
    FHsts := Store;
end;

destructor TNetworkContext.Destroy;
begin
  if Assigned(NetworkContextGoingHook) then
    NetworkContextGoingHook(Self);
  FTransport.Free;
  if FOwnedCookies <> nil then
    FClient.Cookies := nil;
  if FOwnedCache <> nil then
    FClient.Cache := nil;
  if FOwnsClient then
    FClient.Free;
  FOwnedCookies.Free;
  FOwnedCache.Free;
  FOwnHsts.Free;
  FPreflightCache.Free;
  inherited Destroy;
end;

end.
