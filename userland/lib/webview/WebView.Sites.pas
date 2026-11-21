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
  Sites, what content processes are given to (process per site): a
  scheme and a registrable domain (libhttp's public suffix rules), so
  https://www.example.com and https://mail.example.com are one site and
  https://example.org another; an IP address or a host without one
  (localhost) is a site of its own. All local files are the site
  "file:", the browser's own pages "about:". A URL that has no site of
  its own (about:blank, data:, javascript:) takes the site of whatever
  opened it: SiteOfUrl gives '' for those.
}
unit WebView.Sites;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

const
  SiteLocalFiles = 'file:';
  SiteBrowserPages = 'about:';

{ The site of a URL ('' when it inherits its opener's, or is no URL). }
function SiteOfUrl(constref Url: TUrlRecord): string;
function SiteOfText(const Url: string): string;
{ The registrable domain (or host) of a site's key, '' for the special
  sites. }
function SiteHost(const Site: string): string;
{ Whether a URL belongs to Site (a URL without a site of its own belongs
  to any). }
function UrlBelongsToSite(constref Url: TUrlRecord; const Site: string): Boolean;

implementation

uses
  Url.Parser,
  Http.PublicSuffixes;

function SiteOfUrl(constref Url: TUrlRecord): string;
var
  Host, Domain: string;
begin
  Result := '';
  if Url.Scheme = 'file' then
    Exit(SiteLocalFiles);
  if Url.Scheme = 'about' then
  begin
    if (Url.Path = 'blank') or (Url.Path = 'srcdoc') then
      Exit('');
    Exit(SiteBrowserPages);
  end;
  if (Url.Scheme <> 'http') and (Url.Scheme <> 'https') then
    Exit('');
  Host := SerializeHost(Url.Host);
  if Url.Host.Kind = UrlHostDomain then
  begin
    Domain := RegistrableDomainOf(Host);
    if Domain <> '' then
      Host := Domain;
  end;
  Result := Url.Scheme + '://' + Host;
end;

function SiteOfText(const Url: string): string;
var
  Parsed: TUrlRecord;
begin
  if not ParseUrl(Url, Parsed) then
    Exit('');
  Result := SiteOfUrl(Parsed);
end;

function SiteHost(const Site: string): string;
var
  Start: Integer;
begin
  Start := Pos('://', Site);
  if Start = 0 then
    Exit('');
  Result := Copy(Site, Start + 3, Length(Site));
end;

function UrlBelongsToSite(constref Url: TUrlRecord; const Site: string): Boolean;
var
  Own: string;
begin
  Own := SiteOfUrl(Url);
  Result := (Own = '') or (Own = Site);
end;

end.
