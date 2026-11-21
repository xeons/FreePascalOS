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
  The rules a document shown in a frame is checked against:

  - The sandbox attribute (HTML 7.1.5): its tokens as the things a
    sandboxed frame is still allowed (scripts, same origin, forms,
    popups, modals, top navigation, ...). Nested frames keep their
    ancestors' restrictions.
  - Whether a response may be shown in a frame of these ancestors
    (HTML 7.4.2.3.3 "check a navigation response's adherence to its
    embedder policy" and its X-Frame-Options part, CSP 3's
    frame-ancestors): an enforced frame-ancestors directive decides when
    there is one (each ancestor's origin must match its source list:
    'none', 'self', *, schemes, hosts with a "*." prefix, ports, paths
    ignored), else X-Frame-Options (DENY; SAMEORIGIN: every ancestor
    same origin as the response; ALLOWALL and anything invalid let it
    through).
}
unit Web.Navigation.FramePolicy;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Url.Origins;

type
  TFrameAllowance = (AllowScripts, AllowSameOrigin, AllowForms, AllowPopups, AllowModals, AllowTopNavigation,
    AllowTopNavigationByUserActivation, AllowPopupsToEscapeSandbox, AllowDownloads, AllowPointerLock,
    AllowPresentation, AllowOrientationLock, AllowStorageAccessByUserActivation);
  TFrameAllowances = set of TFrameAllowance;

  TOriginArray = array of TUrlOrigin;

const
  AllFrameAllowances = [Low(TFrameAllowance)..High(TFrameAllowance)];

{ What a sandbox attribute's value still allows. }
function ParseSandboxAllowances(const Value: string): TFrameAllowances;
{ Whether a response at ResponseUrl with these Content-Security-Policy
  (enforced, comma-joined) and X-Frame-Options field values may be
  shown in a frame whose ancestors' documents have Ancestors' origins
  (the parent first). }
function MayBeFramed(constref ResponseUrl: TUrlRecord; const CspValue, FrameOptionsValue: string;
  const Ancestors: TOriginArray): Boolean;
{ One frame-ancestors source list against an origin. }
function FrameAncestorSourcesMatch(const Sources: TStringArray; constref Origin, SelfOrigin: TUrlOrigin): Boolean;

implementation

uses
  Web.Fetch.ContentSecurityPolicy;

function ParseSandboxAllowances(const Value: string): TFrameAllowances;
var
  Tokens: TStringArray;
  Token: string;
  Index: Integer;
begin
  Result := [];
  Tokens := LowerCase(Value).Split([' ', #9, #10, #12, #13], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Tokens) do
  begin
    Token := Tokens[Index];
    if Token = 'allow-scripts' then
      Include(Result, AllowScripts)
    else if Token = 'allow-same-origin' then
      Include(Result, AllowSameOrigin)
    else if Token = 'allow-forms' then
      Include(Result, AllowForms)
    else if Token = 'allow-popups' then
      Include(Result, AllowPopups)
    else if Token = 'allow-modals' then
      Include(Result, AllowModals)
    else if Token = 'allow-top-navigation' then
      Include(Result, AllowTopNavigation)
    else if Token = 'allow-top-navigation-by-user-activation' then
      Include(Result, AllowTopNavigationByUserActivation)
    else if Token = 'allow-popups-to-escape-sandbox' then
      Include(Result, AllowPopupsToEscapeSandbox)
    else if Token = 'allow-downloads' then
      Include(Result, AllowDownloads)
    else if Token = 'allow-pointer-lock' then
      Include(Result, AllowPointerLock)
    else if Token = 'allow-presentation' then
      Include(Result, AllowPresentation)
    else if Token = 'allow-orientation-lock' then
      Include(Result, AllowOrientationLock)
    else if Token = 'allow-storage-access-by-user-activation' then
      Include(Result, AllowStorageAccessByUserActivation);
  end;
end;

function DefaultPortOf(const Scheme: string): LongInt;
begin
  if (Scheme = 'http') or (Scheme = 'ws') then
    Result := 80
  else if (Scheme = 'https') or (Scheme = 'wss') then
    Result := 443
  else
    Result := -1;
end;

function OriginPort(constref Origin: TUrlOrigin): LongInt;
begin
  if Origin.Port = UrlPortNull then
    Result := DefaultPortOf(Origin.Scheme)
  else
    Result := Origin.Port;
end;

{ A source's scheme matches the origin's (http also lets https in, ws
  wss, as CSP 3's "scheme-part matching" says). }
function SchemeMatches(const SourceScheme, OriginScheme: string): Boolean;
begin
  Result := (SourceScheme = OriginScheme) or ((SourceScheme = 'http') and (OriginScheme = 'https')) or
    ((SourceScheme = 'ws') and ((OriginScheme = 'wss') or (OriginScheme = 'http') or (OriginScheme = 'https'))) or
    ((SourceScheme = 'wss') and (OriginScheme = 'https'));
end;

function HostMatches(const SourceHost, OriginHost: string): Boolean;
var
  Suffix: string;
begin
  if Copy(SourceHost, 1, 2) = '*.' then
  begin
    Suffix := Copy(SourceHost, 2, MaxInt);
    Result := (Length(OriginHost) > Length(Suffix)) and
      (Copy(OriginHost, Length(OriginHost) - Length(Suffix) + 1, MaxInt) = Suffix);
  end
  else
    Result := SourceHost = OriginHost;
end;

{ One host-source ("https://*.example.com:443/path") against an origin. }
function HostSourceMatches(const Source: string; constref Origin: TUrlOrigin): Boolean;
var
  Rest, Scheme, Host, PortText: string;
  Position, Port: Integer;
begin
  Rest := Source;
  Scheme := '';
  Position := Pos('://', Rest);
  if Position > 0 then
  begin
    Scheme := Copy(Rest, 1, Position - 1);
    Rest := Copy(Rest, Position + 3, MaxInt);
  end;
  Position := Pos('/', Rest);
  if Position > 0 then
    Rest := Copy(Rest, 1, Position - 1);
  PortText := '';
  Position := LastDelimiter(':', Rest);
  if (Position > 0) and (Pos(']', Rest) < Position) then
  begin
    PortText := Copy(Rest, Position + 1, MaxInt);
    Rest := Copy(Rest, 1, Position - 1);
  end;
  Host := Rest;
  if Scheme <> '' then
  begin
    if not SchemeMatches(Scheme, Origin.Scheme) then
      Exit(False);
  end
  else if (Origin.Scheme <> 'http') and (Origin.Scheme <> 'https') then
    Exit(False);
  if (Host <> '*') and not HostMatches(Host, SerializeHost(Origin.Host)) then
    Exit(False);
  if PortText = '*' then
    Exit(True);
  if PortText = '' then
  begin
    if Scheme <> '' then
      Port := DefaultPortOf(Scheme)
    else
      Port := DefaultPortOf(Origin.Scheme);
    Result := (OriginPort(Origin) = Port) or ((Port = 80) and (OriginPort(Origin) = 443));
    Exit;
  end;
  Port := StrToIntDef(PortText, -2);
  Result := OriginPort(Origin) = Port;
end;

function FrameAncestorSourcesMatch(const Sources: TStringArray; constref Origin, SelfOrigin: TUrlOrigin): Boolean;
var
  Index: Integer;
  Source: string;
begin
  Result := False;
  if Origin.Opaque then
    Exit;
  for Index := 0 to High(Sources) do
  begin
    Source := LowerCase(Sources[Index]);
    if Source = '''none''' then
      Continue;
    if Source = '''self''' then
    begin
      if SameOrigin(Origin, SelfOrigin) then
        Exit(True);
      Continue;
    end;
    if Source = '*' then
    begin
      if (Origin.Scheme = 'http') or (Origin.Scheme = 'https') or (Origin.Scheme = 'ws') or (Origin.Scheme = 'wss') or
         SameOrigin(Origin, SelfOrigin) then
        Exit(True);
      Continue;
    end;
    if (Length(Source) > 1) and (Source[Length(Source)] = ':') and (Pos('/', Source) = 0) then
    begin
      if SchemeMatches(Copy(Source, 1, Length(Source) - 1), Origin.Scheme) then
        Exit(True);
      Continue;
    end;
    if HostSourceMatches(Source, Origin) then
      Exit(True);
  end;
end;

function FrameOptionsAllow(const Value: string; constref ResponseOrigin: TUrlOrigin;
  const Ancestors: TOriginArray): Boolean;
var
  Parts: TStringArray;
  First, Part: string;
  Index: Integer;
begin
  Result := True;
  Parts := Value.Split([',']);
  First := '';
  for Index := 0 to High(Parts) do
  begin
    Part := LowerCase(Trim(Parts[Index]));
    if Part = '' then
      Continue;
    if First = '' then
      First := Part
    else if Part <> First then
      Exit(True);
  end;
  if First = 'deny' then
    Exit(False);
  if First = 'sameorigin' then
    for Index := 0 to High(Ancestors) do
      if not SameOrigin(Ancestors[Index], ResponseOrigin) then
        Exit(False);
end;

function MayBeFramed(constref ResponseUrl: TUrlRecord; const CspValue, FrameOptionsValue: string;
  const Ancestors: TOriginArray): Boolean;
var
  Policies: TCspList;
  Values: TStringArray;
  ResponseOrigin: TUrlOrigin;
  PolicyIndex, AncestorIndex: Integer;
  HasFrameAncestors: Boolean;
begin
  ResponseOrigin := OriginOfUrl(ResponseUrl);
  HasFrameAncestors := False;
  Result := True;
  if CspValue <> '' then
  begin
    Policies := TCspList.Create;
    try
      Policies.AddFromField(CspValue, CspEnforce);
      for PolicyIndex := 0 to Policies.Count - 1 do
        if Policies[PolicyIndex].DirectiveValues('frame-ancestors', Values) then
        begin
          HasFrameAncestors := True;
          for AncestorIndex := 0 to High(Ancestors) do
            if not FrameAncestorSourcesMatch(Values, Ancestors[AncestorIndex], ResponseOrigin) then
              Result := False;
        end;
    finally
      Policies.Free;
    end;
  end;
  if HasFrameAncestors or not Result then
    Exit;
  if FrameOptionsValue <> '' then
    Result := FrameOptionsAllow(FrameOptionsValue, ResponseOrigin, Ancestors);
end;

end.
