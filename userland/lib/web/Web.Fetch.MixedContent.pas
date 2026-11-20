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
  Mixed content (W3C Mixed Content Level 2) and upgrade-insecure-requests
  (CSP):

  - a document that is a secure context prohibits mixed security
    contexts;
  - its requests for images, audio and video over http (not to an IP
    address) are upgraded to https ("upgradeable" content);
  - with upgrade-insecure-requests in an enforced CSP every http
    subresource request (and same-origin navigation) of the document is
    upgraded first;
  - any other request that is still not potentially trustworthy is
    blocked ("blockable" content), except top-level navigations, which
    are not mixed content.
}
unit Web.Fetch.MixedContent;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Web.Fetch.Requests;

{ Upgrades the request's current URL when the client asks for it (CSP)
  or the destination is upgradeable; True if the URL changed. }
function UpgradeMixedContentRequest(Request: TFetchRequest): Boolean;
{ True when the request must fail as blockable mixed content. }
function ShouldBlockMixedContent(Request: TFetchRequest): Boolean;
{ http -> https and ws -> wss, port 80 becoming the default. }
procedure UpgradeUrlToSecure(var Url: TUrlRecord);

implementation

uses
  Web.Fetch.ReferrerPolicy;

procedure UpgradeUrlToSecure(var Url: TUrlRecord);
begin
  if Url.Scheme = 'http' then
    Url.Scheme := 'https'
  else if Url.Scheme = 'ws' then
    Url.Scheme := 'wss'
  else
    Exit;
  if (Url.Port = 80) or (Url.Port = 443) then
    Url.Port := UrlPortNull;
end;

function ProhibitsMixedContent(Request: TFetchRequest): Boolean;
begin
  Result := (Request.Client <> nil) and Request.Client.IsSecureContext;
end;

function IsTopLevelNavigation(Request: TFetchRequest): Boolean;
begin
  Result := (Request.Mode = FetchModeNavigate) and (Request.Destination = DestinationDocument);
end;

procedure ReplaceCurrentUrl(Request: TFetchRequest; constref Url: TUrlRecord);
begin
  Request.UrlList[High(Request.UrlList)] := Url;
  if Length(Request.UrlList) = 1 then
    Request.Url := Url;
end;

function UpgradeMixedContentRequest(Request: TFetchRequest): Boolean;
var
  Current: TUrlRecord;
begin
  Result := False;
  Current := Request.CurrentUrl;
  if (Current.Scheme <> 'http') and (Current.Scheme <> 'ws') then
    Exit;
  if (Request.Client <> nil) and Request.Client.Csp.EnforcesDirective('upgrade-insecure-requests') and
     (not IsTopLevelNavigation(Request) or
      (Request.Client.HasCreationUrl and SameOriginUrl(Request.Client.CreationUrl, Current))) then
  begin
    UpgradeUrlToSecure(Current);
    ReplaceCurrentUrl(Request, Current);
    Request.Upgraded := True;
    Exit(True);
  end;
  if not ProhibitsMixedContent(Request) or UrlIsPotentiallyTrustworthy(Current) then
    Exit;
  if Current.Host.Kind in [UrlHostIpv4, UrlHostIpv6] then
    Exit;
  if not (Request.Destination in [DestinationImage, DestinationAudio, DestinationVideo]) then
    Exit;
  UpgradeUrlToSecure(Current);
  ReplaceCurrentUrl(Request, Current);
  Request.Upgraded := True;
  Result := True;
end;

function ShouldBlockMixedContent(Request: TFetchRequest): Boolean;
begin
  if not ProhibitsMixedContent(Request) or IsTopLevelNavigation(Request) then
    Exit(False);
  Result := not UrlIsPotentiallyTrustworthy(Request.CurrentUrl);
end;

end.
