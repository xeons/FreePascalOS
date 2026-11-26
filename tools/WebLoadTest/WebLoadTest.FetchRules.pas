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
  The fetch layer's rules on their own: MIME type parsing and
  extraction, data: URLs and forgiving-base64, content sniffing, the
  referrer policies, HSTS, CSP parsing, mixed content upgrades and
  blocking, and CORS (safelisted headers, preflight decisions, the CORS
  check, preflight responses and their cache, exposed headers).
}
unit WebLoadTest.FetchRules;

{$mode objfpc}
{$H+}

interface

procedure RunFetchRuleTests;

implementation

uses
  SysUtils,
  TestChecks,
  Url.Records,
  Url.Parser,
  Http.HeaderFields,
  Web.Fetch.MimeTypes,
  Web.Fetch.DataUrls,
  Web.Fetch.Sniffing,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.Hsts,
  Web.Fetch.ContentSecurityPolicy,
  Web.Fetch.Requests,
  Web.Fetch.MixedContent,
  Web.Fetch.CspSources,
  Web.Fetch.CspChecks,
  Url.Origins,
  Web.Fetch.Cors;

var
  FakeUnixTime: Int64 = 1000000;

function FakeClock: Int64;
begin
  Result := FakeUnixTime;
end;

function MakeUrl(const Text: string): TUrlRecord;
begin
  if not ParseUrl(Text, Result) then
    raise Exception.Create('bad test URL ' + Text);
end;

procedure CheckMimeTypes;
var
  MimeType: TMimeType;
  Value: string;
begin
  MimeType := ParseMimeType(' Text/HTML ; Charset="utf-8" ; charset=latin1; =x; bad name=1; q="a\"b"');
  Check(MimeType.Valid and (MimeEssence(MimeType) = 'text/html'), 'mime: essence lower cased');
  Check(MimeParameter(MimeType, 'charset', Value) and (Value = 'utf-8'), 'mime: quoted value, first wins');
  Check(SerializeMimeType(MimeType) = 'text/html;charset=utf-8;q="a\"b"', 'mime: serialized (' +
    SerializeMimeType(MimeType) + ')');
  Check(not ParseMimeType('text').Valid, 'mime: no slash');
  Check(not ParseMimeType('text/').Valid, 'mime: no subtype');
  Check(not ParseMimeType('te xt/plain').Valid, 'mime: bad type');
  Check(SerializeMimeType(ParseMimeType('image/svg+xml;x=')) = 'image/svg+xml', 'mime: empty value dropped');
  MimeType := ExtractMimeType(['text/plain;charset=gbk, text/html']);
  Check(SerializeMimeType(MimeType) = 'text/html', 'mime: extract takes the last essence');
  MimeType := ExtractMimeType(['text/html;charset=gbk;a=b, text/html;x=y']);
  Check(SerializeMimeType(MimeType) = 'text/html;x=y;charset=gbk', 'mime: charset kept for the same essence (' +
    SerializeMimeType(MimeType) + ')');
  MimeType := ExtractMimeType(['text/html;charset=gbk', '*/*']);
  Check(SerializeMimeType(MimeType) = 'text/html;charset=gbk', 'mime: */* skipped');
  Check(not ExtractMimeType(['']).Valid, 'mime: nothing to extract');
  Check(IsJavaScriptMimeType('text/javascript') and IsJavaScriptMimeType('application/x-javascript') and
    not IsJavaScriptMimeType('text/plain'), 'mime: JavaScript types');
  Check(IsXmlMimeType('image/svg+xml') and IsJsonMimeType('application/ld+json'), 'mime: +xml and +json');
end;

procedure CheckDataUrls;
var
  Result_: TDataUrlResult;
  Decoded: string;
begin
  Result_ := ProcessDataUrl(MakeUrl('data:,Hello%2C%20World!'));
  Check(Result_.Valid and (Result_.Body = 'Hello, World!') and
    (SerializeMimeType(Result_.MimeType) = 'text/plain;charset=US-ASCII'), 'data: default type, percent-decoded');
  Result_ := ProcessDataUrl(MakeUrl('data:text/html;base64,PGI+aGk8L2I+'));
  Check(Result_.Valid and (Result_.Body = '<b>hi</b>') and (MimeEssence(Result_.MimeType) = 'text/html'),
    'data: base64');
  Result_ := ProcessDataUrl(MakeUrl('data:;charset=utf-8,x'));
  Check(SerializeMimeType(Result_.MimeType) = 'text/plain;charset=utf-8', 'data: text/plain put before ;');
  Result_ := ProcessDataUrl(MakeUrl('data:image/png ; BASE64 ,aGk='));
  Check(Result_.Valid and (Result_.Body = 'hi') and (MimeEssence(Result_.MimeType) = 'image/png'),
    'data: spaces and case around base64');
  Check(not ProcessDataUrl(MakeUrl('data:;base64,a')).Valid, 'data: bad base64 fails');
  Check(not ProcessDataUrl(MakeUrl('data:text/plain')).Valid, 'data: no comma fails');
  Result_ := ProcessDataUrl(MakeUrl('data:text/plain,a#frag'));
  Check(Result_.Body = 'a', 'data: fragment not in the body');
  Check(ForgivingBase64Decode(' YW Jj ', Decoded) and (Decoded = 'abc'), 'base64: whitespace dropped');
  Check(ForgivingBase64Decode('YQ', Decoded) and (Decoded = 'a'), 'base64: no padding');
  Check(ForgivingBase64Decode('YQ==', Decoded) and (Decoded = 'a'), 'base64: padding');
  Check(not ForgivingBase64Decode('YQ=', Decoded), 'base64: half padding fails');
  Check(not ForgivingBase64Decode('Y', Decoded), 'base64: one character fails');
  Check(not ForgivingBase64Decode('Y!==', Decoded), 'base64: bad character fails');
end;

procedure CheckSniffing;
var
  Options: TSniffOptions;
begin
  Options := Default(TSniffOptions);
  Check(SniffMimeType('', '  <!DOCTYPE html><p>', Options) = 'text/html', 'sniff: doctype');
  Check(SniffMimeType('', #10'<SCRIPT>x', Options) = 'text/html', 'sniff: tag after whitespace');
  Check(SniffMimeType('', '<scriptx', Options) = 'text/plain', 'sniff: tag needs a terminating byte');
  Check(SniffMimeType('', '<?xml version="1.0"?>', Options) = 'text/xml', 'sniff: xml');
  Check(SniffMimeType('', '%PDF-1.7', Options) = 'application/pdf', 'sniff: pdf');
  Check(SniffMimeType('', #$89'PNG'#13#10#26#10'rest', Options) = 'image/png', 'sniff: png');
  Check(SniffMimeType('', 'GIF89a...', Options) = 'image/gif', 'sniff: gif');
  Check(SniffMimeType('', 'RIFF1234WEBPVP8 ', Options) = 'image/webp', 'sniff: webp');
  Check(SniffMimeType('', #$1F#$8B#$08'x', Options) = 'application/x-gzip', 'sniff: gzip');
  Check(SniffMimeType('', 'plain words', Options) = 'text/plain', 'sniff: text');
  Check(SniffMimeType('', 'a'#1'b', Options) = 'application/octet-stream', 'sniff: binary');
  Check(SniffMimeType('unknown/unknown', '<html>', Options) = 'text/html', 'sniff: unknown/unknown sniffed');
  Check(SniffMimeType('image/gif', #$FF#$D8#$FF#$E0, Options) = 'image/jpeg', 'sniff: image type checked');
  Check(SniffMimeType('text/html', 'plain', Options) = 'text/html', 'sniff: html kept');
  Options.CheckForApacheBug := True;
  Check(SniffMimeType('text/plain', 'a'#0'b', Options) = 'application/octet-stream', 'sniff: Apache bug binary');
  Check(SniffMimeType('text/plain', '<html>', Options) = 'text/plain', 'sniff: Apache bug text stays text');
  Options.CheckForApacheBug := False;
  Options.NoSniff := True;
  Check(SniffMimeType('', '<html>', Options) = 'text/plain', 'sniff: nosniff, no scriptable sniffing');
  Check(SniffMimeType('image/gif', #$FF#$D8#$FF#$E0, Options) = 'image/gif', 'sniff: nosniff keeps the type');
  Check(SniffImageMimeType('text/plain', #0#0#1#0) = 'image/x-icon', 'sniff: image context');
  Check(SniffImageMimeType('image/svg+xml', 'GIF89a') = 'image/svg+xml', 'sniff: image context keeps xml');
  Check(IsApacheBugContentType('text/plain; charset=UTF-8') and not IsApacheBugContentType('text/plain;charset=utf-8'),
    'sniff: Apache bug values exact');
end;

procedure CheckReferrers;
var
  Referrer: string;
  Policy: TReferrerPolicy;
begin
  Check(DetermineReferrer(MakeUrl('https://a.example/p?q#f'), MakeUrl('https://a.example/x'),
    ReferrerPolicyEmpty, Referrer) and (Referrer = 'https://a.example/p?q'), 'referrer: same origin full URL');
  Check(DetermineReferrer(MakeUrl('https://u:p@a.example/p?q#f'), MakeUrl('https://b.example/x'),
    ReferrerPolicyEmpty, Referrer) and (Referrer = 'https://a.example/'), 'referrer: cross origin origin only');
  Check(not DetermineReferrer(MakeUrl('https://a.example/p'), MakeUrl('http://b.example/x'), ReferrerPolicyEmpty, Referrer),
    'referrer: no downgrade by default');
  Check(DetermineReferrer(MakeUrl('https://a.example/p'), MakeUrl('http://b.example/x'), ReferrerPolicyUnsafeUrl, Referrer) and
    (Referrer = 'https://a.example/p'), 'referrer: unsafe-url');
  Check(not DetermineReferrer(MakeUrl('https://a.example/p'), MakeUrl('https://a.example/x'), ReferrerPolicyNoReferrer,
    Referrer), 'referrer: no-referrer');
  Check(not DetermineReferrer(MakeUrl('https://a.example/p'), MakeUrl('https://b.example/x'), ReferrerPolicySameOrigin,
    Referrer), 'referrer: same-origin across origins');
  Check(DetermineReferrer(MakeUrl('http://a.example/p'), MakeUrl('http://b.example/x'), ReferrerPolicyNoReferrerWhenDowngrade,
    Referrer) and (Referrer = 'http://a.example/p'), 'referrer: no-referrer-when-downgrade');
  Check(DetermineReferrer(MakeUrl('https://a.example/p'), MakeUrl('https://b.example/x'), ReferrerPolicyOriginWhenCrossOrigin,
    Referrer) and (Referrer = 'https://a.example/'), 'referrer: origin-when-cross-origin');
  Check(not DetermineReferrer(MakeUrl('data:text/html,x'), MakeUrl('https://b.example/x'), ReferrerPolicyUnsafeUrl, Referrer),
    'referrer: none from data:');
  Check(ParseReferrerPolicyField('origin, bogus, no-referrer, nonsense') = ReferrerPolicyNoReferrer,
    'referrer: last known token of the field');
  Check(ReferrerPolicyFromToken('Strict-Origin', Policy) and (Policy = ReferrerPolicyStrictOrigin),
    'referrer: tokens without case');
end;

procedure CheckHsts;
var
  Store: THstsStore;
  Policy: THstsPolicy;
  Target: TUrlRecord;
begin
  Policy := ParseStrictTransportSecurity('max-age="31536000"; includeSubDomains; preload');
  Check(Policy.Valid and (Policy.MaxAge = 31536000) and Policy.IncludeSubDomains, 'hsts: field parsed');
  Check(not ParseStrictTransportSecurity('includeSubDomains').Valid, 'hsts: max-age needed');
  Check(not ParseStrictTransportSecurity('max-age=1; max-age=2').Valid, 'hsts: repeated directive ignored');
  Check(not ParseStrictTransportSecurity('max-age=abc').Valid, 'hsts: bad number');
  Store := THstsStore.Create(@FakeClock);
  try
    Store.ProcessResponseField(MakeUrl('http://plain.example/'), 'max-age=100');
    Check(not Store.IsKnownHost('plain.example'), 'hsts: not from http');
    Store.ProcessResponseField(MakeUrl('https://127.0.0.1/'), 'max-age=100');
    Check(Store.Count = 0, 'hsts: not from an address');
    Store.ProcessResponseField(MakeUrl('https://Secure.Example/'), 'max-age=100; includeSubDomains');
    Store.ProcessResponseField(MakeUrl('https://only.example/'), 'max-age=100');
    Target := MakeUrl('http://a.b.secure.example:80/x?y');
    Check(Store.UpgradeUrl(Target) and (SerializeUrl(Target) = 'https://a.b.secure.example/x?y'),
      'hsts: subdomain upgraded, port 80 dropped');
    Target := MakeUrl('http://sub.only.example/');
    Check(not Store.UpgradeUrl(Target), 'hsts: no includeSubDomains, subdomain kept');
    Target := MakeUrl('http://only.example:8080/');
    Check(Store.UpgradeUrl(Target) and (SerializeUrl(Target) = 'https://only.example:8080/'),
      'hsts: other ports kept');
    FakeUnixTime := FakeUnixTime + 101;
    Target := MakeUrl('http://only.example/');
    Check(not Store.UpgradeUrl(Target), 'hsts: entry expired');
    Store.ProcessResponseField(MakeUrl('https://secure.example/'), 'max-age=0');
    Check(not Store.IsKnownHost('secure.example'), 'hsts: max-age=0 forgets');
    Store.AddHost('kept.example', 1000, True);
    Store.LoadFromText(Store.SaveToText + 'junk line' + LineEnding);
    Check(Store.IsKnownHost('x.kept.example'), 'hsts: saved and loaded');
  finally
    Store.Free;
  end;
end;

procedure CheckCsp;
var
  List: TCspList;
  Values: TStringArray;
begin
  List := TCspList.Create;
  try
    List.AddFromField('default-src ''self''; SCRIPT-SRC a.example  b.example; script-src c; bad_name x, ' +
      'upgrade-insecure-requests', CspEnforce);
    Check(List.Count = 2, 'csp: two policies in one field');
    Check(List[0].DirectiveValues('script-src', Values) and (Length(Values) = 2) and (Values[1] = 'b.example'),
      'csp: lower cased name, values, first directive wins');
    Check(not List[0].HasDirective('bad_name'), 'csp: bad names skipped');
    Check(List.EnforcesDirective('upgrade-insecure-requests'), 'csp: directive without values');
    List.AddFromMeta('frame-ancestors none; img-src *');
    Check(not List[2].HasDirective('frame-ancestors') and List[2].HasDirective('img-src'),
      'csp: meta drops frame-ancestors');
    List.AddFromField('upgrade-insecure-requests', CspReport);
    Check(List[3].Disposition = CspReport, 'csp: report-only kept apart');
  finally
    List.Free;
  end;
end;

type
  TViolationLog = class(TCspViolationReporter)
  public
    Text: string;
    procedure ViolationOccurred(constref Violation: TCspViolation); override;
  end;

procedure TViolationLog.ViolationOccurred(constref Violation: TCspViolation);
const
  Names: array[TCspDisposition] of string = ('enforce', 'report');
begin
  Text := Text + Violation.EffectiveDirective + ' ' + Violation.BlockedUri + ' ' + Names[Violation.Disposition];
  if Violation.Sample <> '' then
    Text := Text + ' "' + Violation.Sample + '"';
  Text := Text + ';';
end;

function Sources(const Text: string): TStringArray;
begin
  Result := Text.Split([' '], TStringSplitOptions.ExcludeEmpty);
end;

procedure ExpectMatch(const List, Url, Origin: string; Expected: Boolean; RedirectCount: Integer = 0);
var
  OriginRecord: TUrlOrigin;
begin
  OriginRecord := OriginOfUrl(MakeUrl(Origin));
  Check(UrlMatchesSourceList(MakeUrl(Url), Sources(List), OriginRecord, RedirectCount) = Expected,
    'csp match: [' + List + '] ' + Url + ' from ' + Origin + ' ' + BoolToStr(Expected, 'matches', 'does not match'));
end;

{ Source lists as CSP 3 section 6.7.2 matches them (cases after the
  specification's examples and web-platform-tests' content-security-
  policy/ matching tests). }
procedure CheckCspMatching;
const
  AlertHash = 'bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI=';
begin
  ExpectMatch('''self''', 'https://a.example/x', 'https://a.example/', True);
  ExpectMatch('''self''', 'http://a.example/x', 'https://a.example/', False);
  ExpectMatch('''self''', 'wss://a.example/socket', 'https://a.example/', True);
  ExpectMatch('''self''', 'https://a.example/', 'http://a.example/', True);
  ExpectMatch('''self''', 'ws://a.example/', 'http://a.example/', True);
  ExpectMatch('''self''', 'https://b.example/', 'https://a.example/', False);
  ExpectMatch('''SELF''', 'https://a.example/', 'https://a.example/', True);
  ExpectMatch('*', 'https://anything.example/', 'https://a.example/', True);
  ExpectMatch('*', 'wss://anything.example/', 'https://a.example/', True);
  ExpectMatch('*', 'data:text/plain,x', 'https://a.example/', False);
  ExpectMatch('*', 'blob:https://a.example/1', 'https://a.example/', False);
  ExpectMatch('https:', 'https://x.example/', 'https://a.example/', True);
  ExpectMatch('https:', 'http://x.example/', 'https://a.example/', False);
  ExpectMatch('http:', 'https://x.example/', 'https://a.example/', True);
  ExpectMatch('ws:', 'wss://x.example/', 'https://a.example/', True);
  ExpectMatch('ws:', 'https://x.example/', 'https://a.example/', True);
  ExpectMatch('wss:', 'https://x.example/', 'https://a.example/', True);
  ExpectMatch('data:', 'data:image/png;base64,AA', 'https://a.example/', True);
  ExpectMatch('*.example.com', 'https://a.example.com/', 'https://a.example/', True);
  ExpectMatch('*.example.com', 'https://a.b.example.com/', 'https://a.example/', True);
  ExpectMatch('*.example.com', 'https://example.com/', 'https://a.example/', False);
  ExpectMatch('example.com', 'https://example.com/', 'https://a.example/', True);
  ExpectMatch('example.com', 'http://example.com/', 'https://a.example/', False);
  ExpectMatch('example.com', 'https://example.com:8443/', 'https://a.example/', False);
  ExpectMatch('EXAMPLE.com:8443', 'https://example.com:8443/', 'https://a.example/', True);
  ExpectMatch('example.com:*', 'https://example.com:1234/', 'https://a.example/', True);
  ExpectMatch('http://example.com:80', 'https://example.com/', 'https://a.example/', True);
  ExpectMatch('https://example.com', 'http://example.com/', 'https://a.example/', False);
  ExpectMatch('example.com/path/', 'https://example.com/path/file.js', 'https://a.example/', True);
  ExpectMatch('example.com/path/', 'https://example.com/other/file.js', 'https://a.example/', False);
  ExpectMatch('example.com/file.js', 'https://example.com/file.js', 'https://a.example/', True);
  ExpectMatch('example.com/file.js', 'https://example.com/file.js/more', 'https://a.example/', False);
  ExpectMatch('example.com/file.js', 'https://example.com/elsewhere.js', 'https://a.example/', True, 1);
  ExpectMatch('example.com/a%20b', 'https://example.com/a%20b', 'https://a.example/', True);
  ExpectMatch('''none''', 'https://a.example/', 'https://a.example/', False);
  ExpectMatch('', 'https://a.example/', 'https://a.example/', False);
  ExpectMatch('''unsafe-inline'' ''nonce-abc''', 'https://a.example/', 'https://a.example/', False);
  ExpectMatch('[::1]:8080', 'http://[::1]:8080/', 'http://[::1]:8080/', True);
  Check(SourceListMatchesNonce(Sources('''nonce-abc+/='''), 'abc+/=') and
    not SourceListMatchesNonce(Sources('''nonce-abc'''), 'abd') and not SourceListMatchesNonce(Sources('''nonce-'''), ''),
    'csp: nonce sources');
  Check(SourceListMatchesHash(Sources('''sha256-' + AlertHash + ''''), 'alert(1)'), 'csp: a sha256 hash source');
  Check(SourceListMatchesHash(Sources('''SHA256-bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF-pI'''), 'alert(1)'),
    'csp: base64url without padding, algorithm in any case');
  Check(not SourceListMatchesHash(Sources('''sha256-' + AlertHash + ''''), 'alert(2)'), 'csp: a hash of other text');
  Check(SourceListMatchesHash(Sources('''sha384-' + CspDigestBase64('sha384', 'x') + ''''), 'x') and
    SourceListMatchesHash(Sources('''sha512-' + CspDigestBase64('sha512', 'x') + ''''), 'x'), 'csp: sha384 and sha512');
  Check(IntegrityMatchesSourceList('sha256-' + AlertHash + '?opt', Sources('''sha256-' + AlertHash + '''')) and
    not IntegrityMatchesSourceList('sha256-' + AlertHash + ' sha384-xyz', Sources('''sha256-' + AlertHash + '''')),
    'csp: integrity metadata against hashes');
end;

procedure CheckCspDecisions;
var
  Client: TFetchClient;
  Log: TViolationLog;
begin
  Client := TFetchClient.ForDocument(MakeUrl('https://site.example/page'));
  Log := TViolationLog.Create;
  try
    Client.CspReporter := Log;
    Client.Csp.AddFromField('default-src ''none''; img-src *; script-src ''self'' ''nonce-n'' ''report-sample''; ' +
      'style-src ''unsafe-inline'' ''sha256-bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI=''', CspEnforce);
    Client.Csp.AddFromField('connect-src ''self''', CspReport);
    Check(not CspBlocksRequest(Client, MakeUrl('https://cdn.example/a.png'), DestinationImage, '', '', False),
      'csp: img-src * allows an image');
    Check(CspBlocksRequest(Client, MakeUrl('https://cdn.example/f.woff'), DestinationFont, '', '', False),
      'csp: font-src falls back to default-src ''none''');
    Check(not CspBlocksRequest(Client, MakeUrl('https://site.example/a.js'), DestinationScript, '', '', True),
      'csp: script-src ''self''');
    Check(not CspBlocksRequest(Client, MakeUrl('https://cdn.example/a.js'), DestinationScript, 'n', '', True),
      'csp: a nonced script of another origin');
    Check(CspBlocksRequest(Client, MakeUrl('https://cdn.example/a.js'), DestinationScript, 'x', '', True),
      'csp: a script with the wrong nonce');
    Check(not CspBlocksRequest(Client, MakeUrl('https://site.example/w.js'), DestinationWorker, '', '', False),
      'csp: worker-src falls back to script-src');
    Check(CspBlocksRequest(Client, MakeUrl('https://cdn.example/frame'), DestinationIframe, '', '', False),
      'csp: frame-src falls back to default-src');
    Log.Text := '';
    Check(CspBlocksRequest(Client, MakeUrl('https://api.example/x#frag'), DestinationEmpty, '', '', False),
      'csp: connect-src from default-src');
    Check(Log.Text = 'connect-src https://api.example/x enforce;connect-src https://api.example/x report;',
      'csp: both policies report, the fragment stripped (' + Log.Text + ')');
    Log.Text := '';
    CspBlocksRequest(Client, MakeUrl('https://other.example/path?q'), DestinationEmpty, '', '', False, 1);
    Check(Pos('connect-src https://other.example enforce', Log.Text) = 1,
      'csp: a redirect target of another origin is reported as its origin (' + Log.Text + ')');
    Check(CspBlocksInline(Client, CspInlineScript, 'alert(1)', '', nil) and
      not CspBlocksInline(Client, CspInlineScript, 'alert(1)', 'n', nil), 'csp: inline script by nonce');
    Log.Text := '';
    CspBlocksInline(Client, CspInlineScript, 'var a = "a long script that goes past forty characters";', '', nil);
    Check(Log.Text = 'script-src-elem inline enforce "var a = "a long script that goes past fo";',
      'csp: report-sample gives the first 40 characters (' + Log.Text + ')');
    Check(not CspBlocksInline(Client, CspInlineStyle, 'alert(1)', '', nil), 'csp: a style block by hash');
    Check(CspBlocksInline(Client, CspInlineStyle, 'p { color: red }', '', nil),
      'csp: ''unsafe-inline'' is ignored beside a hash');
    Check(CspBlocksInline(Client, CspInlineStyleAttribute, 'alert(1)', '', nil),
      'csp: a style attribute needs ''unsafe-hashes'' for its hash');
    Check(CspBlocksEval(Client, 'x'), 'csp: eval without ''unsafe-eval''');
    Check(not CspBlocksFormAction(Client, MakeUrl('https://elsewhere.example/'), nil),
      'csp: form-action does not fall back to default-src');
    Client.Csp.Clear;
    Client.Csp.AddFromField('script-src ''nonce-n'' ''strict-dynamic'' https://site.example ''unsafe-inline'' ' +
      '''unsafe-eval''; form-action ''self''; base-uri ''none''', CspEnforce);
    Check(CspBlocksRequest(Client, MakeUrl('https://site.example/a.js'), DestinationScript, '', '', True) and
      not CspBlocksRequest(Client, MakeUrl('https://cdn.example/a.js'), DestinationScript, '', '', False),
      'csp: strict-dynamic: host sources ignored, inserted scripts trusted');
    Check(CspBlocksInline(Client, CspInlineScript, 'x()', '', nil), 'csp: strict-dynamic: ''unsafe-inline'' ignored');
    Check(CspBlocksFormAction(Client, MakeUrl('https://elsewhere.example/'), nil) and
      not CspBlocksFormAction(Client, MakeUrl('https://site.example/post'), nil), 'csp: form-action ''self''');
    Check(CspBlocksBaseUrl(Client, MakeUrl('https://site.example/'), nil), 'csp: base-uri ''none''');
    Check(not CspBlocksEval(Client, 'x'), 'csp: ''unsafe-eval'' allows eval');
  finally
    Client.Free;
    Log.Free;
  end;
end;


procedure CheckMixedContent;
var
  Client: TFetchClient;
  Request: TFetchRequest;
begin
  Client := TFetchClient.ForDocument(MakeUrl('https://secure.example/page'));
  try
    Request := TFetchRequest.Create('GET', MakeUrl('http://img.example/a.png'));
    Request.Client := Client;
    Request.Destination := DestinationImage;
    Check(UpgradeMixedContentRequest(Request) and (SerializeUrl(Request.CurrentUrl) = 'https://img.example/a.png'),
      'mixed: image upgraded');
    Check(not ShouldBlockMixedContent(Request), 'mixed: upgraded image allowed');
    Request.Free;
    Request := TFetchRequest.Create('GET', MakeUrl('http://10.0.0.1/a.png'));
    Request.Client := Client;
    Request.Destination := DestinationImage;
    Check(not UpgradeMixedContentRequest(Request) and ShouldBlockMixedContent(Request),
      'mixed: image at an address not upgraded, blocked');
    Request.Free;
    Request := TFetchRequest.Create('GET', MakeUrl('http://cdn.example/a.js'));
    Request.Client := Client;
    Request.Destination := DestinationScript;
    Check(not UpgradeMixedContentRequest(Request) and ShouldBlockMixedContent(Request), 'mixed: script blocked');
    Request.Free;
    Request := TFetchRequest.Create('GET', MakeUrl('http://localhost/a.js'));
    Request.Client := Client;
    Request.Destination := DestinationScript;
    Check(not ShouldBlockMixedContent(Request), 'mixed: localhost is trustworthy');
    Request.Free;
    Request := TFetchRequest.Create('GET', MakeUrl('http://other.example/'));
    Request.Client := Client;
    Request.Destination := DestinationDocument;
    Request.Mode := FetchModeNavigate;
    Check(not ShouldBlockMixedContent(Request), 'mixed: top-level navigation allowed');
    Request.Free;
    Client.Csp.AddFromField('upgrade-insecure-requests', CspEnforce);
    Request := TFetchRequest.Create('GET', MakeUrl('http://cdn.example:80/a.js'));
    Request.Client := Client;
    Request.Destination := DestinationScript;
    Check(UpgradeMixedContentRequest(Request) and (SerializeUrl(Request.CurrentUrl) = 'https://cdn.example/a.js') and
      not ShouldBlockMixedContent(Request), 'mixed: upgrade-insecure-requests upgrades scripts');
    Request.Free;
  finally
    Client.Free;
  end;
  Client := TFetchClient.ForDocument(MakeUrl('http://plain.example/'));
  try
    Request := TFetchRequest.Create('GET', MakeUrl('http://cdn.example/a.js'));
    Request.Client := Client;
    Request.Destination := DestinationScript;
    Check(not UpgradeMixedContentRequest(Request) and not ShouldBlockMixedContent(Request),
      'mixed: nothing on an http page');
    Request.Free;
  finally
    Client.Free;
  end;
end;

procedure CheckCors;
var
  Headers, Response: THttpHeaders;
  Names: TStringArray;
  Reason: string;
  Preflight: TCorsPreflightResult;
  Cache: TCorsPreflightCache;
  Key: string;
begin
  Check(IsCorsSafelistedRequestHeader('Accept', 'text/html') and
    IsCorsSafelistedRequestHeader('Content-Type', 'text/plain;charset=utf-8') and
    not IsCorsSafelistedRequestHeader('Content-Type', 'application/json') and
    IsCorsSafelistedRequestHeader('Range', 'bytes=10-') and not IsCorsSafelistedRequestHeader('Range', 'bytes=5-1') and
    not IsCorsSafelistedRequestHeader('Accept', 'a"b') and not IsCorsSafelistedRequestHeader('X-Thing', 'a') and
    not IsCorsSafelistedRequestHeader('Accept-Language', StringOfChar('a', 129)), 'cors: safelisted headers');
  Headers := THttpHeaders.Create;
  Response := THttpHeaders.Create;
  Cache := TCorsPreflightCache.Create;
  try
    Headers.Add('Accept', '*/*');
    Check(not CorsNeedsPreflight('GET', Headers, False) and not CorsNeedsPreflight('POST', Headers, False),
      'cors: simple requests need no preflight');
    Check(CorsNeedsPreflight('PUT', Headers, False), 'cors: PUT needs a preflight');
    Headers.Add('X-B', '1');
    Headers.Add('Content-Type', 'application/json');
    Headers.Add('x-a', '2');
    Names := CorsUnsafeRequestHeaderNames(Headers);
    Check((Length(Names) = 3) and (Names[0] = 'content-type') and (Names[1] = 'x-a') and (Names[2] = 'x-b'),
      'cors: unsafe names sorted, lower case');
    Check(CorsNeedsPreflight('GET', Headers, False), 'cors: unsafe header needs a preflight');

    Check(not CorsCheck(Response, 'https://a.example', False, Reason), 'cors check: no field fails');
    Response.Add('Access-Control-Allow-Origin', '*');
    Check(CorsCheck(Response, 'https://a.example', False, Reason), 'cors check: * without credentials');
    Check(not CorsCheck(Response, 'https://a.example', True, Reason), 'cors check: * with credentials fails');
    Response.SetValue('Access-Control-Allow-Origin', 'https://a.example');
    Check(not CorsCheck(Response, 'https://a.example', True, Reason), 'cors check: credentials need the field');
    Response.Add('Access-Control-Allow-Credentials', 'true');
    Check(CorsCheck(Response, 'https://a.example', True, Reason), 'cors check: origin and credentials');
    Check(not CorsCheck(Response, 'https://b.example', False, Reason), 'cors check: other origin fails');
    Response.Add('Access-Control-Allow-Origin', 'https://a.example');
    Check(not CorsCheck(Response, 'https://a.example', False, Reason), 'cors check: two values fail');

    Response.Clear;
    Response.Add('Access-Control-Allow-Methods', 'PUT, DELETE');
    Response.Add('Access-Control-Allow-Headers', 'X-A, x-b, Content-Type');
    Response.Add('Access-Control-Max-Age', '600');
    Preflight := CheckPreflightResponse(Response, 204, 'PUT', Names, False, False);
    Check(Preflight.Ok and (Preflight.MaxAge = 600), 'preflight: allowed');
    Preflight := CheckPreflightResponse(Response, 500, 'PUT', Names, False, False);
    Check(not Preflight.Ok, 'preflight: error status fails');
    Preflight := CheckPreflightResponse(Response, 200, 'PATCH', Names, False, False);
    Check(not Preflight.Ok, 'preflight: method not allowed');
    Response.SetValue('Access-Control-Allow-Headers', '*');
    Response.SetValue('Access-Control-Allow-Methods', '*');
    Check(CheckPreflightResponse(Response, 200, 'PATCH', Names, False, False).Ok, 'preflight: * without credentials');
    Check(not CheckPreflightResponse(Response, 200, 'PATCH', Names, True, False).Ok,
      'preflight: * does not cover credentials');
    SetLength(Names, 1);
    Names[0] := 'authorization';
    Check(not CheckPreflightResponse(Response, 200, 'GET', Names, False, False).Ok,
      'preflight: * never covers Authorization');
    Response.SetValue('Access-Control-Max-Age', '999999');
    Preflight := CheckPreflightResponse(Response, 200, 'GET', nil, False, False);
    Check(Preflight.MaxAge = MaximumPreflightMaxAge, 'preflight: max-age capped');

    Key := TCorsPreflightCache.KeyFor('https://a.example', 'https://api.example/x', False);
    Preflight.MaxAge := 10;
    Cache.Add(Key, Preflight, 'PUT', TStringArray.Create('X-A'), 1000);
    Check(Cache.HasMethod(Key, 'PUT', 5000) and Cache.HasHeader(Key, 'x-a', 5000), 'preflight cache: stored');
    Check(not Cache.HasMethod(Key, 'PUT', 11001), 'preflight cache: expired');
    Check(not Cache.HasMethod(TCorsPreflightCache.KeyFor('https://a.example', 'https://api.example/x', True), 'PUT',
      5000), 'preflight cache: credentials kept apart');

    Response.Clear;
    Response.Add('Content-Type', 'text/plain');
    Response.Add('X-Secret', '1');
    Response.Add('X-Shown', '2');
    Response.Add('Set-Cookie', 'a=b');
    Response.Add('Access-Control-Expose-Headers', 'x-shown');
    Names := CorsExposedHeaderNames(Response, False);
    Check((Length(Names) = 2) and (Names[0] = 'content-type') and (Names[1] = 'x-shown'), 'cors: exposed headers');
    Response.SetValue('Access-Control-Expose-Headers', '*');
    Names := CorsExposedHeaderNames(Response, False);
    Check(Length(Names) = 4, 'cors: * exposes all but Set-Cookie');
    Check(IsForbiddenRequestHeader('Sec-Fetch-Mode') and IsForbiddenRequestHeader('Cookie') and
      not IsForbiddenRequestHeader('X-Thing'), 'cors: forbidden request headers');
  finally
    Headers.Free;
    Response.Free;
    Cache.Free;
  end;
end;

procedure RunFetchRuleTests;
begin
  CheckMimeTypes;
  CheckDataUrls;
  CheckSniffing;
  CheckReferrers;
  CheckHsts;
  CheckCsp;
  CheckCspMatching;
  CheckCspDecisions;
  CheckMixedContent;
  CheckCors;
end;

end.
