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

  What a browser's options and tools set, for the whole program (the
  browser process: its content processes' exchanges, cookies and
  storage go through this network): private browsing (a fresh cookie
  jar, HTTP cache, HSTS store and local storage in memory, dropped when
  it ends), working offline, the HTTP cache's size, the cookies (listed,
  removed, the policy with its host exceptions), clearing local storage
  and HSTS, and what TLS said of the last connection to a host (the
  site identity, Page Info's Security tab) and the system's trust store.
  Called on the GUI thread; the stores are locked for the network's
  threads.
}
unit WebView.Network;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Tls.CertificateSummaries,
  Web.Fetch.NetworkContexts,
  Web.Storage,
  Web.UserAgent;

type
  TCookieInfo = record
    { The domain the cookie is for (lower case, no leading dot). }
    Host: string;
    Name, Value, Path: string;
    { Unix time; 0: a session cookie. }
    Expires: Int64;
    Secure, HttpOnly: Boolean;
  end;
  TCookieInfoList = array of TCookieInfo;

  TCookiePolicy = (CookiesAccept, CookiesRefuse, CookiesRefuseThirdParty);

  { Subject, issuer (distinguished names), the subject's common name and
    organization, validity ('yyyy-mm-dd hh:nn:ss UTC'), serial number and
    SHA-256 fingerprint (upper-case hexadecimal pairs joined by ':'). }
  TCertificateSummary = TTlsCertificateSummary;
  TCertificateSummaryList = TTlsCertificateSummaryList;

  TConnectionSecurity = record
    Secure: Boolean;
    { 'TLS 1.3' or 'TLS 1.2'. }
    Protocol: string;
    { The cipher suite's name. }
    Cipher: string;
    Host: string;
    { The server's certificate first, then what it sent, then the root
      when it was not sent. }
    Chain: TCertificateSummaryList;
  end;

const
  { What the web views say they are (libweb's). }
  WebViewUserAgent = EngineUserAgent;

{ The program's shared network context. }
function SharedNetworkContext: TNetworkContext;
{ Whether HTTP/3 is used where an origin offers it (and libquic's
  factory is registered). }
function Http3Allowed: Boolean;
procedure SetHttp3Allowed(Allowed: Boolean);
{ Frees the shared context (at the program's end; web views must be gone). }
procedure FreeSharedNetworkContext;
{ Where localStorage is kept, a file per origin (set before the first
  page; '' keeps it in memory). }
procedure SetWebStorageFolder(const Folder: string);
{ The program's local storage, shared by its web views (the private
  one while private browsing). }
function SharedLocalStorage: TWebStorageRegistry;
{ The lock of local storage: the network service's thread and the GUI
  thread both change it (taken around every use of SharedLocalStorage
  off the GUI thread, and by the routines below that change it). }
procedure EnterLocalStorage;
procedure LeaveLocalStorage;

{ Private browsing: cookies, the HTTP cache, the HSTS hosts learned and
  local storage are fresh ones in memory (nothing is written to disk)
  until it is turned off, which drops them and brings the usual ones
  back. Pages open across the switch keep what they read already (a
  browser closes or reloads them, as Firefox's private sessions did). }
procedure SetPrivateBrowsing(Enabled: Boolean);
function PrivateBrowsing: Boolean;
{ Every http and https exchange fails at once with the reason
  'offline' (responses the HTTP cache holds fresh are still served). }
procedure SetWorkOffline(Offline: Boolean);
function WorkOffline: Boolean;
procedure ClearHttpCache;
{ What the HTTP cache holds (bytes in memory). }
function HttpCacheBytes: Int64;
procedure SetHttpCacheLimit(Bytes: Int64);
function ListCookies: TCookieInfoList;
procedure RemoveCookie(const Host, Name, Path: string);
procedure ClearCookies;
{ Which cookies are kept and sent; an exception names a host or a parent
  domain (example.com covers www.example.com), the longest matching one
  deciding, a blocked one winning a tie. }
procedure SetCookiePolicy(Policy: TCookiePolicy; const AllowedHosts, BlockedHosts: TStringArray);
{ The local storage of every origin. }
procedure ClearWebStorage;
{ The HSTS hosts learned. }
procedure ClearHsts;
{ What TLS said of the last connection the program's network made to
  Url's host and port; False when there was none (or not over TLS, or
  over HTTP/3, which is not recorded yet). }
function ConnectionSecurityOf(const Url: string; out Info: TConnectionSecurity): Boolean;
{ The certificates of the system's trust store (libtls's
  Tls.SystemTrust.SystemTrustSummaries), for "View Certificates". }
function SystemTrustSummaries: TCertificateSummaryList;

implementation

uses
  Url.Records,
  Url.Parser,
  Http.Observers,
  Http.Client,
  Http.Cookies,
  Http.CookiePolicies,
  Http.Cache,
  Http.ConnectionSecurity,
  Http.SocketConnector,
  Web.Fetch.Hsts,
  Tls.SystemTrust;

var
  Shared: TNetworkContext = nil;
  SharedCookies: TCookieJar = nil;
  SharedCache: THttpCache = nil;
  AllowHttp3: Boolean = True;
  StorageFolder: string = '';
  SharedStorage: TWebStorageRegistry = nil;
  { Private browsing's stores: made the first time, emptied (not freed:
    a page or an exchange may still hold them) when it ends. }
  PrivateMode: Boolean = False;
  PrivateCookies: TCookieJar = nil;
  PrivateCache: THttpCache = nil;
  PrivateHsts: THstsStore = nil;
  PrivateStorage: TWebStorageRegistry = nil;
  OfflineMode: Boolean = False;
  CacheLimit: Int64 = -1;
  CookieRules: TCookieUsePolicy;
  StorageLock: TRTLCriticalSection;

procedure EnterLocalStorage;
begin
  EnterCriticalSection(StorageLock);
end;

procedure LeaveLocalStorage;
begin
  LeaveCriticalSection(StorageLock);
end;

procedure SetWebStorageFolder(const Folder: string);
begin
  StorageFolder := Folder;
end;

function PersistentLocalStorage: TWebStorageRegistry;
begin
  if SharedStorage = nil then
    SharedStorage := TWebStorageRegistry.Create(StorageFolder);
  Result := SharedStorage;
end;

function SharedLocalStorage: TWebStorageRegistry;
begin
  if PrivateMode and (PrivateStorage <> nil) then
    Result := PrivateStorage
  else
    Result := PersistentLocalStorage;
end;

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
    SharedCookies.SetPolicy(CookieRules);
    if CacheLimit >= 0 then
      SharedCache.SetMemoryLimit(CacheLimit);
    Client.Cookies := SharedCookies;
    Client.Cache := SharedCache;
    Client.Offline := OfflineMode;
    Shared := TNetworkContext.Create(Client, True);
    Shared.AllowFileAccess := True;
    if PrivateMode then
    begin
      Client.Cookies := PrivateCookies;
      Client.Cache := PrivateCache;
      Shared.UseHstsStore(PrivateHsts);
    end;
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

{ ---- private browsing ---- }

procedure EnsurePrivateStores;
begin
  if PrivateCookies = nil then
    PrivateCookies := TCookieJar.Create;
  PrivateCookies.SetPolicy(CookieRules);
  if PrivateCache = nil then
    PrivateCache := THttpCache.Create;
  if CacheLimit >= 0 then
    PrivateCache.SetMemoryLimit(CacheLimit);
  if PrivateHsts = nil then
    PrivateHsts := THstsStore.Create;
  if PrivateStorage = nil then
    PrivateStorage := TWebStorageRegistry.Create('');
end;

procedure EmptyPrivateStores;
begin
  if PrivateCookies <> nil then
    PrivateCookies.Clear;
  if PrivateCache <> nil then
    PrivateCache.Clear;
  if PrivateHsts <> nil then
    PrivateHsts.Clear;
  if PrivateStorage <> nil then
    PrivateStorage.ClearAll;
end;

procedure SwitchPrivateBrowsing(Enabled: Boolean);
begin
  if Enabled then
  begin
    EnsurePrivateStores;
    EmptyPrivateStores;
    PrivateMode := True;
    if Shared <> nil then
    begin
      Shared.Client.Cookies := PrivateCookies;
      Shared.Client.Cache := PrivateCache;
      Shared.UseHstsStore(PrivateHsts);
    end;
  end
  else
  begin
    PrivateMode := False;
    if Shared <> nil then
    begin
      Shared.Client.Cookies := SharedCookies;
      Shared.Client.Cache := SharedCache;
      Shared.UseHstsStore(nil);
    end;
    EmptyPrivateStores;
  end;
end;

procedure SetPrivateBrowsing(Enabled: Boolean);
begin
  if Enabled = PrivateMode then
    Exit;
  EnterLocalStorage;
  try
    SwitchPrivateBrowsing(Enabled);
  finally
    LeaveLocalStorage;
  end;
  { Which TLS connections were made tells where one went. }
  ClearConnectionSecurity;
end;

function PrivateBrowsing: Boolean;
begin
  Result := PrivateMode;
end;

{ ---- offline, the cache ---- }

procedure SetWorkOffline(Offline: Boolean);
begin
  OfflineMode := Offline;
  if Shared <> nil then
    Shared.Client.Offline := Offline;
end;

function WorkOffline: Boolean;
begin
  Result := OfflineMode;
end;

{ The cache and the jar in use (the private ones while private
  browsing). }
function ActiveCache: THttpCache;
begin
  SharedNetworkContext;
  if PrivateMode then
    Result := PrivateCache
  else
    Result := SharedCache;
end;

function ActiveCookies: TCookieJar;
begin
  SharedNetworkContext;
  if PrivateMode then
    Result := PrivateCookies
  else
    Result := SharedCookies;
end;

procedure ClearHttpCache;
begin
  ActiveCache.Clear;
end;

function HttpCacheBytes: Int64;
begin
  Result := ActiveCache.MemoryUsed;
end;

procedure SetHttpCacheLimit(Bytes: Int64);
begin
  if Bytes < 0 then
    Bytes := 0;
  CacheLimit := Bytes;
  SharedNetworkContext;
  SharedCache.SetMemoryLimit(Bytes);
  if PrivateCache <> nil then
    PrivateCache.SetMemoryLimit(Bytes);
end;

{ ---- cookies ---- }

function ListCookies: TCookieInfoList;
var
  Cookies: TCookieArray;
  Index: Integer;
begin
  Cookies := ActiveCookies.Snapshot;
  Result := nil;
  SetLength(Result, Length(Cookies));
  for Index := 0 to High(Cookies) do
  begin
    Result[Index].Host := Cookies[Index].Domain;
    Result[Index].Name := Cookies[Index].Name;
    Result[Index].Value := Cookies[Index].Value;
    Result[Index].Path := Cookies[Index].Path;
    if Cookies[Index].Persistent then
      Result[Index].Expires := Cookies[Index].ExpiryTime
    else
      Result[Index].Expires := 0;
    Result[Index].Secure := Cookies[Index].Secure;
    Result[Index].HttpOnly := Cookies[Index].HttpOnly;
  end;
end;

procedure RemoveCookie(const Host, Name, Path: string);
var
  Domain: string;
begin
  Domain := LowerCase(Host);
  if (Domain <> '') and (Domain[1] = '.') then
    Delete(Domain, 1, 1);
  ActiveCookies.RemoveCookie(Domain, Name, Path);
end;

procedure ClearCookies;
begin
  ActiveCookies.Clear;
end;

procedure SetCookiePolicy(Policy: TCookiePolicy; const AllowedHosts, BlockedHosts: TStringArray);
begin
  case Policy of
    CookiesRefuse: CookieRules.Acceptance := CookieRefuseAll;
    CookiesRefuseThirdParty: CookieRules.Acceptance := CookieRefuseThirdParty;
  else
    CookieRules.Acceptance := CookieAcceptAll;
  end;
  CookieRules.AllowedHosts := Copy(AllowedHosts);
  CookieRules.BlockedHosts := Copy(BlockedHosts);
  SharedNetworkContext;
  SharedCookies.SetPolicy(CookieRules);
  if PrivateCookies <> nil then
    PrivateCookies.SetPolicy(CookieRules);
end;

{ ---- storage, HSTS ---- }

procedure ClearWebStorage;
begin
  EnterLocalStorage;
  try
    SharedLocalStorage.ClearAll;
  finally
    LeaveLocalStorage;
  end;
end;

procedure ClearHsts;
begin
  SharedNetworkContext.Hsts.Clear;
end;

{ ---- TLS ---- }

function ConnectionSecurityOf(const Url: string; out Info: TConnectionSecurity): Boolean;
var
  Parsed: TUrlRecord;
  Port: LongInt;
  Recorded: THttpConnectionSecurity;
begin
  Info := Default(TConnectionSecurity);
  Result := False;
  if not ParseUrl(Url, Parsed) or ((Parsed.Scheme <> 'https') and (Parsed.Scheme <> 'wss')) then
    Exit;
  Port := Parsed.Port;
  if Port = UrlPortNull then
    Port := 443;
  if (Port <= 0) or (Port > 65535) then
    Exit;
  if not FindConnectionSecurity(SerializeHost(Parsed.Host), Port, Recorded) then
    Exit;
  Info.Secure := Recorded.Secure;
  Info.Protocol := Recorded.Protocol;
  Info.Cipher := Recorded.Cipher;
  Info.Host := Recorded.Host;
  Info.Chain := Recorded.Chain;
  Result := True;
end;

function SystemTrustSummaries: TCertificateSummaryList;
begin
  Result := Tls.SystemTrust.SystemTrustSummaries;
end;

procedure FreeSharedNetworkContext;
begin
  Shared.Free;
  Shared := nil;
  SharedCookies.Free;
  SharedCookies := nil;
  SharedCache.Free;
  SharedCache := nil;
  SharedStorage.Free;
  SharedStorage := nil;
  PrivateCookies.Free;
  PrivateCookies := nil;
  PrivateCache.Free;
  PrivateCache := nil;
  PrivateHsts.Free;
  PrivateHsts := nil;
  PrivateStorage.Free;
  PrivateStorage := nil;
end;

initialization
  CookieRules := DefaultCookieUsePolicy;
  InitCriticalSection(StorageLock);

finalization
  DoneCriticalSection(StorageLock);
end.
