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
  Following a redirect (RFC 9110 section 15.4, Fetch's "HTTP-redirect
  fetch"):

  - the Location is a URL reference resolved against the request's
    URL; without a fragment it keeps the request's;
  - 301 and 302 turn a POST into a GET, 303 turns anything but HEAD
    into a GET; then the content goes, with the fields describing it
    (Content-Type, Content-Encoding, Content-Language,
    Content-Location, Content-Length); 307 and 308 keep the method and
    the content (which must be readable again);
  - credentials (Authorization, Proxy-Authorization) do not go to
    another origin; cookies are worked out again for the new URL.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Redirects;

{$mode objfpc}
{$H+}

interface

uses
  Http.HeaderFields,
  Url.Records;

const
  DefaultMaximumRedirects = 20;

{ The method of the next request; DropContent: the content and its
  fields go. }
function RedirectedMethod(Status: Integer; const Method: string; out DropContent: Boolean): string;
{ The Location against the request's URL (the fragment kept when the
  Location has none). False if it is not a URL. }
function ResolveLocation(constref Current: TUrlRecord; const Location: string; out Target: TUrlRecord): Boolean;
{ Takes out of Headers what may not follow the redirect. }
procedure PrepareRedirectedFields(Headers: THttpHeaders; DropContent, CrossOrigin: Boolean);

implementation

uses
  Url.Parser;

function RedirectedMethod(Status: Integer; const Method: string; out DropContent: Boolean): string;
begin
  Result := Method;
  DropContent := False;
  if ((Status = 301) or (Status = 302)) and (Method = 'POST') then
  begin
    Result := 'GET';
    DropContent := True;
  end
  else if (Status = 303) and (Method <> 'HEAD') then
  begin
    Result := 'GET';
    DropContent := Method <> 'GET';
  end;
end;

function ResolveLocation(constref Current: TUrlRecord; const Location: string; out Target: TUrlRecord): Boolean;
begin
  Result := ParseUrl(Location, Current, Target);
  if Result and not Target.HasFragment and Current.HasFragment then
  begin
    Target.HasFragment := True;
    Target.Fragment := Current.Fragment;
  end;
end;

procedure PrepareRedirectedFields(Headers: THttpHeaders; DropContent, CrossOrigin: Boolean);
begin
  if DropContent then
  begin
    Headers.Remove('content-type');
    Headers.Remove('content-encoding');
    Headers.Remove('content-language');
    Headers.Remove('content-location');
    Headers.Remove('content-length');
  end;
  if CrossOrigin then
  begin
    Headers.Remove('authorization');
    Headers.Remove('proxy-authorization');
  end;
  Headers.Remove('cookie');
end;

end.
