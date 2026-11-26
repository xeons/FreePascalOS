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
  Content Security Policy Level 3 enforcement: the checks the engine
  makes against a document's CSP list (its fetch client's).

    requests        the effective directive of the request's destination
                    (connect-src for fetch, XHR, EventSource, WebSocket
                    and beacons; script-src-elem, style-src-elem,
                    img-src, font-src, media-src, frame-src, worker-src,
                    object-src, manifest-src), found through its
                    fallback list (script-src-elem, script-src,
                    default-src...); scripts and workers pass by nonce,
                    by integrity hashes, or with 'strict-dynamic' when
                    not parser-inserted, else by URL (section 6.7.2.5)
    inline          <script> and <style> contents, event handler and
                    style attributes, javascript: URLs: 'unsafe-inline'
                    (ignored beside a nonce or hash, and beside
                    'strict-dynamic' for scripts), a nonce (elements),
                    a hash (attributes and javascript: URLs only with
                    'unsafe-hashes')
    eval            eval(), Function() and string timers: script-src or
                    default-src with 'unsafe-eval'
    wasm            compiling WebAssembly: script-src or default-src
                    with 'unsafe-eval' or 'wasm-unsafe-eval'
    form-action     form submissions (no fallback)
    base-uri        <base href> (no fallback)

  Every policy is checked; each one violated is reported to the
  client's reporter, and only enforced ones block.
}
unit Web.Fetch.CspChecks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Web.Fetch.ContentSecurityPolicy,
  Web.Fetch.Requests;

type
  TCspInlineKind = (CspInlineScript, CspInlineScriptAttribute, CspInlineStyle, CspInlineStyleAttribute,
    CspInlineNavigation);

{ The effective directive of a request ('' when CSP does not apply:
  documents, reports). }
function CspEffectiveDirective(Destination: TFetchDestination): string;
{ The directives a directive falls back to, itself first. }
function CspFallbackList(const Directive: string): TStringArray;
{ Should the request be blocked (CSP 4.1.2, before it goes and after
  each redirect)? Nonce: the request's cryptographic nonce; Integrity:
  its integrity metadata. }
function CspBlocksRequest(Client: TFetchClient; constref Url: TUrlRecord; Destination: TFetchDestination;
  const Nonce, Integrity: string; ParserInserted: Boolean; RedirectCount: Integer = 0): Boolean;
{ Should an element's inline behaviour be blocked (CSP 4.2.3)? Source:
  the script or style text, the attribute's value, or the javascript:
  URL. Element: the element (the violation's target). }
function CspBlocksInline(Client: TFetchClient; Kind: TCspInlineKind; const Source, Nonce: string; Element: TObject;
  const SourceFile: string = ''; Line: Integer = 0; Column: Integer = 0): Boolean;
{ Should compiling a string as script be blocked (CSP 4.4.1)? }
function CspBlocksEval(Client: TFetchClient; const Source: string): Boolean;
{ CSP 4.2.4 (EnsureCSPDoesNotBlockWasmByteCompilation): script-src
  without 'unsafe-eval' or 'wasm-unsafe-eval' blocks compiling
  WebAssembly (reported as "wasm-eval"). }
function CspBlocksWasm(Client: TFetchClient): Boolean;
{ form-action for a form's submission to Url. }
function CspBlocksFormAction(Client: TFetchClient; constref Url: TUrlRecord; Element: TObject): Boolean;
{ base-uri for a <base> element's URL. }
function CspBlocksBaseUrl(Client: TFetchClient; constref Url: TUrlRecord; Element: TObject): Boolean;

implementation

uses
  Url.Origins,
  Web.Fetch.CspSources;

function CspEffectiveDirective(Destination: TFetchDestination): string;
begin
  case Destination of
    DestinationEmpty: Result := 'connect-src';
    DestinationIframe, DestinationFrame: Result := 'frame-src';
    DestinationScript: Result := 'script-src-elem';
    DestinationStyle: Result := 'style-src-elem';
    DestinationImage: Result := 'img-src';
    DestinationFont: Result := 'font-src';
    DestinationAudio, DestinationVideo, DestinationTrack: Result := 'media-src';
    DestinationManifest: Result := 'manifest-src';
    DestinationWorker: Result := 'worker-src';
    DestinationObject: Result := 'object-src';
  else
    Result := '';
  end;
end;

function Names(const Items: array of string): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Items));
  for Index := 0 to High(Items) do
    Result[Index] := Items[Index];
end;

function CspFallbackList(const Directive: string): TStringArray;
begin
  if Directive = 'script-src-elem' then
    Result := Names(['script-src-elem', 'script-src', 'default-src'])
  else if Directive = 'script-src-attr' then
    Result := Names(['script-src-attr', 'script-src', 'default-src'])
  else if Directive = 'style-src-elem' then
    Result := Names(['style-src-elem', 'style-src', 'default-src'])
  else if Directive = 'style-src-attr' then
    Result := Names(['style-src-attr', 'style-src', 'default-src'])
  else if Directive = 'worker-src' then
    Result := Names(['worker-src', 'child-src', 'script-src', 'default-src'])
  else if Directive = 'frame-src' then
    Result := Names(['frame-src', 'child-src', 'default-src'])
  else if Directive = 'script-src' then
    Result := Names(['script-src', 'default-src'])
  else if (Directive = 'connect-src') or (Directive = 'manifest-src') or (Directive = 'img-src') or
     (Directive = 'font-src') or (Directive = 'media-src') or (Directive = 'object-src') or
     (Directive = 'child-src') or (Directive = 'style-src') then
    Result := Names([Directive, 'default-src'])
  else
    Result := Names([Directive]);
end;

{ The directive of Policy that governs Effective (its values), if any. }
function GoverningDirective(Policy: TCspPolicy; const Effective: string; out Values: TStringArray): Boolean;
var
  List: TStringArray;
  Index: Integer;
begin
  List := CspFallbackList(Effective);
  for Index := 0 to High(List) do
    if Policy.DirectiveValues(List[Index], Values) then
      Exit(True);
  Values := nil;
  Result := False;
end;

function SampleOf(const Values: TStringArray; const Source: string): string;
begin
  if SourceListHasKeyword(Values, '''report-sample''') then
    Result := Copy(Source, 1, 40)
  else
    Result := '';
end;

procedure Report(Client: TFetchClient; Policy: TCspPolicy; const Effective, BlockedUri, Sample: string;
  Element: TObject; const SourceFile: string; Line, Column: Integer);
var
  Violation: TCspViolation;
  Values: TStringArray;
begin
  if Client.CspReporter = nil then
    Exit;
  Violation := Default(TCspViolation);
  if Client.HasCreationUrl then
    Violation.DocumentUrl := SerializeUrl(Client.CreationUrl, True);
  Violation.Referrer := Client.DocumentReferrer;
  Violation.BlockedUri := BlockedUri;
  Violation.EffectiveDirective := Effective;
  Violation.OriginalPolicy := Policy.Serialize;
  Violation.Disposition := Policy.Disposition;
  Violation.Sample := Sample;
  if Client.HasCreationUrl and ((Client.CreationUrl.Scheme = 'http') or (Client.CreationUrl.Scheme = 'https')) then
    Violation.StatusCode := 200;
  Violation.SourceFile := SourceFile;
  Violation.LineNumber := Line;
  Violation.ColumnNumber := Column;
  Violation.Element := Element;
  if Policy.DirectiveValues('report-uri', Values) then
    Violation.ReportUris := Values;
  if Policy.DirectiveValues('report-to', Values) and (Length(Values) > 0) then
    Violation.ReportTo := Values[0];
  Client.CspReporter.ViolationOccurred(Violation);
end;

{ What a violation shows of a blocked URL (CSP 5.4's strip: no
  fragment; the origin alone for another origin's redirect target). }
function BlockedUriText(Client: TFetchClient; constref Url: TUrlRecord; RedirectCount: Integer): string;
var
  Origin: TUrlOrigin;
begin
  if (RedirectCount > 0) and not SameOrigin(Client.Origin, OriginOfUrl(Url)) then
  begin
    Origin := OriginOfUrl(Url);
    Exit(SerializeOrigin(Origin));
  end;
  Result := SerializeUrl(Url, True);
end;

function ScriptRequestAllowed(const Values: TStringArray; constref Url: TUrlRecord; constref Origin: TUrlOrigin;
  const Nonce, Integrity: string; ParserInserted: Boolean; RedirectCount: Integer): Boolean;
begin
  if SourceListMatchesNonce(Values, Nonce) then
    Exit(True);
  if (Integrity <> '') and IntegrityMatchesSourceList(Integrity, Values) then
    Exit(True);
  if SourceListHasKeyword(Values, '''strict-dynamic''') then
    Exit(not ParserInserted);
  Result := UrlMatchesSourceList(Url, Values, Origin, RedirectCount);
end;

function CspBlocksRequest(Client: TFetchClient; constref Url: TUrlRecord; Destination: TFetchDestination;
  const Nonce, Integrity: string; ParserInserted: Boolean; RedirectCount: Integer): Boolean;
var
  Effective: string;
  Index: Integer;
  Policy: TCspPolicy;
  Values: TStringArray;
  Allowed: Boolean;
begin
  Result := False;
  if (Client = nil) or (Client.Csp.Count = 0) then
    Exit;
  Effective := CspEffectiveDirective(Destination);
  if Effective = '' then
    Exit;
  for Index := 0 to Client.Csp.Count - 1 do
  begin
    Policy := Client.Csp[Index];
    if not GoverningDirective(Policy, Effective, Values) then
      Continue;
    if Destination in [DestinationScript, DestinationWorker] then
      Allowed := ScriptRequestAllowed(Values, Url, Client.Origin, Nonce, Integrity, ParserInserted, RedirectCount)
    else
      Allowed := UrlMatchesSourceList(Url, Values, Client.Origin, RedirectCount);
    if Allowed then
      Continue;
    Report(Client, Policy, Effective, BlockedUriText(Client, Url, RedirectCount), '', nil, '', 0, 0);
    if Policy.Disposition = CspEnforce then
      Result := True;
  end;
end;

{ CSP 6.7.3.3: does the element match the source list for its type? }
function InlineMatches(const Values: TStringArray; Kind: TCspInlineKind; const Source, Nonce: string): Boolean;
var
  IsScript, AllowAllInline: Boolean;
begin
  IsScript := Kind in [CspInlineScript, CspInlineScriptAttribute, CspInlineNavigation];
  AllowAllInline := SourceListHasKeyword(Values, '''unsafe-inline''') and not SourceListHasNonceOrHash(Values) and
    not (IsScript and SourceListHasKeyword(Values, '''strict-dynamic'''));
  if AllowAllInline then
    Exit(True);
  if (Kind in [CspInlineScript, CspInlineStyle]) and SourceListMatchesNonce(Values, Nonce) then
    Exit(True);
  if ((Kind in [CspInlineScript, CspInlineStyle]) or SourceListHasKeyword(Values, '''unsafe-hashes''')) and
     SourceListMatchesHash(Values, Source) then
    Exit(True);
  Result := False;
end;

function CspBlocksInline(Client: TFetchClient; Kind: TCspInlineKind; const Source, Nonce: string; Element: TObject;
  const SourceFile: string; Line, Column: Integer): Boolean;
const
  Directives: array[TCspInlineKind] of string = ('script-src-elem', 'script-src-attr', 'style-src-elem',
    'style-src-attr', 'script-src-elem');
var
  Index: Integer;
  Policy: TCspPolicy;
  Values: TStringArray;
begin
  Result := False;
  if (Client = nil) or (Client.Csp.Count = 0) then
    Exit;
  for Index := 0 to Client.Csp.Count - 1 do
  begin
    Policy := Client.Csp[Index];
    if not GoverningDirective(Policy, Directives[Kind], Values) then
      Continue;
    if InlineMatches(Values, Kind, Source, Nonce) then
      Continue;
    Report(Client, Policy, Directives[Kind], 'inline', SampleOf(Values, Source), Element, SourceFile, Line, Column);
    if Policy.Disposition = CspEnforce then
      Result := True;
  end;
end;

function CspBlocksEval(Client: TFetchClient; const Source: string): Boolean;
var
  Index: Integer;
  Policy: TCspPolicy;
  Values: TStringArray;
begin
  Result := False;
  if (Client = nil) or (Client.Csp.Count = 0) then
    Exit;
  for Index := 0 to Client.Csp.Count - 1 do
  begin
    Policy := Client.Csp[Index];
    if not GoverningDirective(Policy, 'script-src', Values) then
      Continue;
    if SourceListHasKeyword(Values, '''unsafe-eval''') then
      Continue;
    Report(Client, Policy, 'script-src', 'eval', SampleOf(Values, Source), nil, '', 0, 0);
    if Policy.Disposition = CspEnforce then
      Result := True;
  end;
end;

function CspBlocksWasm(Client: TFetchClient): Boolean;
var
  Index: Integer;
  Policy: TCspPolicy;
  Values: TStringArray;
begin
  Result := False;
  if (Client = nil) or (Client.Csp.Count = 0) then
    Exit;
  for Index := 0 to Client.Csp.Count - 1 do
  begin
    Policy := Client.Csp[Index];
    if not GoverningDirective(Policy, 'script-src', Values) then
      Continue;
    if SourceListHasKeyword(Values, '''unsafe-eval''') or SourceListHasKeyword(Values, '''wasm-unsafe-eval''') then
      Continue;
    Report(Client, Policy, 'script-src', 'wasm-eval', '', nil, '', 0, 0);
    if Policy.Disposition = CspEnforce then
      Result := True;
  end;
end;

{ A directive without fallback: form-action, base-uri. }
function BlocksByOwnDirective(Client: TFetchClient; const Directive: string; constref Url: TUrlRecord;
  Element: TObject): Boolean;
var
  Index: Integer;
  Policy: TCspPolicy;
  Values: TStringArray;
begin
  Result := False;
  if (Client = nil) or (Client.Csp.Count = 0) then
    Exit;
  for Index := 0 to Client.Csp.Count - 1 do
  begin
    Policy := Client.Csp[Index];
    if not Policy.DirectiveValues(Directive, Values) then
      Continue;
    if UrlMatchesSourceList(Url, Values, Client.Origin, 0) then
      Continue;
    Report(Client, Policy, Directive, SerializeUrl(Url, True), '', Element, '', 0, 0);
    if Policy.Disposition = CspEnforce then
      Result := True;
  end;
end;

function CspBlocksFormAction(Client: TFetchClient; constref Url: TUrlRecord; Element: TObject): Boolean;
begin
  Result := BlocksByOwnDirective(Client, 'form-action', Url, Element);
end;

function CspBlocksBaseUrl(Client: TFetchClient; constref Url: TUrlRecord; Element: TObject): Boolean;
begin
  Result := BlocksByOwnDirective(Client, 'base-uri', Url, Element);
end;

end.
