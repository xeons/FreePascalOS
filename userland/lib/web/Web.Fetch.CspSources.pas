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
  CSP Level 3 source lists (section 6.7.2): whether a URL matches a list
  - '*', scheme sources ("https:"), host sources ("*.example.com:443/
  path/", the scheme, port and path optional), 'self', 'none' - with
  the scheme-part matching that lets an http: source cover https: and
  ws: cover wss:, http: and https:, the default ports, and paths ignored
  after a redirect; and the keyword, nonce and hash sources elements
  are matched with: 'unsafe-inline', 'unsafe-eval', 'unsafe-hashes',
  'strict-dynamic', 'report-sample', 'wasm-unsafe-eval', 'nonce-...',
  'sha256-...', 'sha384-...', 'sha512-...' (base64 or base64url).

  Keywords compare without regard to case.
}
unit Web.Fetch.CspSources;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Url.Records,
  Url.Origins;

{ The URL matches some expression of the list (an empty list or one with
  'none' alone matches nothing). RedirectCount above 0 ignores paths. }
function UrlMatchesSourceList(constref Url: TUrlRecord; const Sources: TStringArray; constref Origin: TUrlOrigin;
  RedirectCount: Integer = 0): Boolean;
function UrlMatchesExpression(constref Url: TUrlRecord; const Expression: string; constref Origin: TUrlOrigin;
  RedirectCount: Integer): Boolean;
{ The list has the keyword ("'unsafe-inline'", quotes included). }
function SourceListHasKeyword(const Sources: TStringArray; const Keyword: string): Boolean;
{ The list has a 'nonce-' source equal to Nonce (never for ''). }
function SourceListMatchesNonce(const Sources: TStringArray; const Nonce: string): Boolean;
{ The list has a hash source of Text (UTF-8). }
function SourceListMatchesHash(const Sources: TStringArray; const Text: string): Boolean;
{ The list has a nonce or hash source ('unsafe-inline' is then ignored). }
function SourceListHasNonceOrHash(const Sources: TStringArray): Boolean;
{ An integrity attribute's metadata ("sha384-... sha512-...") whose
  every hash is a hash source of the list (and that has one). }
function IntegrityMatchesSourceList(const Integrity: string; const Sources: TStringArray): Boolean;
{ base64 of the digest of Text, Algorithm 'sha256', 'sha384' or 'sha512'. }
function CspDigestBase64(const Algorithm, Text: string): string;

implementation

uses
  StrUtils,
  Url.PercentEncoding,
  Crypto.Digests;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Of(Data: PByte; Count: Integer): string;
var
  Index, Remaining: Integer;
  Group: LongWord;
begin
  Result := '';
  Index := 0;
  while Index < Count do
  begin
    Remaining := Count - Index;
    Group := LongWord(Data[Index]) shl 16;
    if Remaining > 1 then
      Group := Group or (LongWord(Data[Index + 1]) shl 8);
    if Remaining > 2 then
      Group := Group or LongWord(Data[Index + 2]);
    Result := Result + Base64Alphabet[((Group shr 18) and 63) + 1] + Base64Alphabet[((Group shr 12) and 63) + 1];
    if Remaining > 1 then
      Result := Result + Base64Alphabet[((Group shr 6) and 63) + 1]
    else
      Result := Result + '=';
    if Remaining > 2 then
      Result := Result + Base64Alphabet[(Group and 63) + 1]
    else
      Result := Result + '=';
    Inc(Index, 3);
  end;
end;

function CspDigestBase64(const Algorithm, Text: string): string;
var
  Kind: TDigestAlgorithm;
  Digest: TDigestOutput;
begin
  if Algorithm = 'sha256' then
    Kind := DigestSha256
  else if Algorithm = 'sha384' then
    Kind := DigestSha384
  else if Algorithm = 'sha512' then
    Kind := DigestSha512
  else
    Exit('');
  ComputeDigest(Kind, PByte(PChar(Text)), Length(Text), Digest);
  Result := Base64Of(@Digest[0], DigestSize(Kind));
end;

{ base64url to base64, padding left as given. }
function NormalizedBase64(const Value: string): string;
var
  Index: Integer;
begin
  Result := Value;
  for Index := 1 to Length(Result) do
    if Result[Index] = '-' then
      Result[Index] := '+'
    else if Result[Index] = '_' then
      Result[Index] := '/';
end;

function WithoutPadding(const Value: string): string;
begin
  Result := Value;
  while (Result <> '') and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
end;

function IsQuoted(const Expression: string): Boolean;
begin
  Result := (Length(Expression) >= 2) and (Expression[1] = '''') and (Expression[Length(Expression)] = '''');
end;

function SourceListHasKeyword(const Sources: TStringArray; const Keyword: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Sources) do
    if SameText(Sources[Index], Keyword) then
      Exit(True);
  Result := False;
end;

function SourceListMatchesNonce(const Sources: TStringArray; const Nonce: string): Boolean;
var
  Index: Integer;
  Inner: string;
begin
  if Nonce = '' then
    Exit(False);
  for Index := 0 to High(Sources) do
    if IsQuoted(Sources[Index]) then
    begin
      Inner := Copy(Sources[Index], 2, Length(Sources[Index]) - 2);
      if SameText(Copy(Inner, 1, 6), 'nonce-') and (Copy(Inner, 7, MaxInt) = Nonce) then
        Exit(True);
    end;
  Result := False;
end;

{ A hash source's algorithm (lower case) and value; False when it is not
  one. }
function ParseHashSource(const Expression: string; out Algorithm, Value: string): Boolean;
var
  Inner: string;
  Dash: Integer;
begin
  Result := False;
  Algorithm := '';
  Value := '';
  if not IsQuoted(Expression) then
    Exit;
  Inner := Copy(Expression, 2, Length(Expression) - 2);
  Dash := Pos('-', Inner);
  if Dash = 0 then
    Exit;
  Algorithm := LowerCase(Copy(Inner, 1, Dash - 1));
  Value := Copy(Inner, Dash + 1, MaxInt);
  Result := ((Algorithm = 'sha256') or (Algorithm = 'sha384') or (Algorithm = 'sha512')) and (Value <> '');
end;

function SourceListMatchesHash(const Sources: TStringArray; const Text: string): Boolean;
var
  Index: Integer;
  Algorithm, Value: string;
begin
  for Index := 0 to High(Sources) do
    if ParseHashSource(Sources[Index], Algorithm, Value) and
       (WithoutPadding(NormalizedBase64(Value)) = WithoutPadding(CspDigestBase64(Algorithm, Text))) then
      Exit(True);
  Result := False;
end;

function SourceListHasNonceOrHash(const Sources: TStringArray): Boolean;
var
  Index: Integer;
  Algorithm, Value: string;
begin
  for Index := 0 to High(Sources) do
    if ParseHashSource(Sources[Index], Algorithm, Value) or
       (IsQuoted(Sources[Index]) and SameText(Copy(Sources[Index], 2, 6), 'nonce-')) then
      Exit(True);
  Result := False;
end;

function IntegrityMatchesSourceList(const Integrity: string; const Sources: TStringArray): Boolean;
var
  Items: TStringArray;
  Index, SourceIndex, Question: Integer;
  Item, Algorithm, Value, SourceAlgorithm, SourceValue: string;
  Found: Boolean;
begin
  Result := False;
  Items := Integrity.Split([' ', #9, #10, #12, #13], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Items) do
  begin
    Item := Items[Index];
    Question := Pos('?', Item);
    if Question > 0 then
      Item := Copy(Item, 1, Question - 1);
    if not ParseHashSource('''' + Item + '''', Algorithm, Value) then
      Continue;
    Found := False;
    for SourceIndex := 0 to High(Sources) do
      if ParseHashSource(Sources[SourceIndex], SourceAlgorithm, SourceValue) and (SourceAlgorithm = Algorithm) and
         (WithoutPadding(NormalizedBase64(SourceValue)) = WithoutPadding(NormalizedBase64(Value))) then
        Found := True;
    if not Found then
      Exit(False);
    Result := True;
  end;
end;

{ CSP 6.7.2.9: scheme A (an expression's) covers scheme B (a URL's). }
function SchemePartMatches(const A, B: string): Boolean;
begin
  Result := SameText(A, B) or (SameText(A, 'http') and (B = 'https')) or
    (SameText(A, 'ws') and ((B = 'wss') or (B = 'http') or (B = 'https'))) or (SameText(A, 'wss') and (B = 'https'));
end;

function IsHttpLikeScheme(const Scheme: string): Boolean;
begin
  Result := (Scheme = 'http') or (Scheme = 'https') or (Scheme = 'ws') or (Scheme = 'wss');
end;

function HostPartMatches(const Pattern: string; constref Url: TUrlRecord): Boolean;
var
  Host, Rest: string;
begin
  Host := LowerCase(SerializeHost(Url.Host));
  if Host = '' then
    Exit(False);
  if Pattern = '*' then
    Exit(True);
  if Copy(Pattern, 1, 2) = '*.' then
  begin
    if Url.Host.Kind <> UrlHostDomain then
      Exit(False);
    Rest := LowerCase(Copy(Pattern, 2, MaxInt));
    Exit((Length(Host) > Length(Rest)) and EndsStr(Rest, Host));
  end;
  Result := LowerCase(Pattern) = Host;
end;

function PortPartMatches(const PortText: string; constref Url: TUrlRecord): Boolean;
var
  Port, UrlPort: LongInt;
begin
  UrlPort := UrlEffectivePort(Url);
  if PortText = '' then
    Exit((Url.Port = UrlPortNull) or (Url.Port = DefaultPortOfScheme(Url.Scheme)));
  if PortText = '*' then
    Exit(True);
  if not TryStrToInt(PortText, Port) then
    Exit(False);
  if Port = UrlPort then
    Exit(True);
  Result := (Port = 80) and (UrlPort = 443) and ((Url.Scheme = 'https') or (Url.Scheme = 'wss'));
end;

function PathPartMatches(const PathText: string; constref Url: TUrlRecord): Boolean;
var
  Expected, Actual: string;
begin
  if (PathText = '') or (PathText = '/') then
    Exit(True);
  if Url.OpaquePath then
    Exit(False);
  Expected := PercentDecode(PathText);
  Actual := PercentDecode(Url.Path);
  if Expected[Length(Expected)] = '/' then
    Result := Copy(Actual, 1, Length(Expected)) = Expected
  else
    Result := Actual = Expected;
end;

function UrlMatchesHostSource(constref Url: TUrlRecord; const Expression: string; constref Origin: TUrlOrigin;
  RedirectCount: Integer): Boolean;
var
  Rest, Scheme, Host, PortText, PathText: string;
  Marker, Slash, Colon: Integer;
begin
  Rest := Expression;
  Scheme := '';
  Marker := Pos('://', Rest);
  if Marker > 0 then
  begin
    Scheme := LowerCase(Copy(Rest, 1, Marker - 1));
    Rest := Copy(Rest, Marker + 3, MaxInt);
  end;
  Slash := Pos('/', Rest);
  PathText := '';
  if Slash > 0 then
  begin
    PathText := Copy(Rest, Slash, MaxInt);
    Rest := Copy(Rest, 1, Slash - 1);
  end;
  PortText := '';
  { An IPv6 address in brackets has colons of its own. }
  if (Rest <> '') and (Rest[1] = '[') then
  begin
    Colon := Pos(']', Rest);
    if (Colon > 0) and (Colon < Length(Rest)) and (Rest[Colon + 1] = ':') then
    begin
      PortText := Copy(Rest, Colon + 2, MaxInt);
      Rest := Copy(Rest, 1, Colon);
    end;
  end
  else
  begin
    Colon := Pos(':', Rest);
    if Colon > 0 then
    begin
      PortText := Copy(Rest, Colon + 1, MaxInt);
      Rest := Copy(Rest, 1, Colon - 1);
    end;
  end;
  Host := Rest;
  if Host = '' then
    Exit(False);
  if Scheme <> '' then
  begin
    if not SchemePartMatches(Scheme, Url.Scheme) then
      Exit(False);
  end
  else if Origin.Opaque or not SchemePartMatches(Origin.Scheme, Url.Scheme) then
    Exit(False);
  if not HostPartMatches(Host, Url) then
    Exit(False);
  if not PortPartMatches(PortText, Url) then
    Exit(False);
  if RedirectCount > 0 then
    Exit(True);
  Result := PathPartMatches(PathText, Url);
end;

function SelfMatches(constref Url: TUrlRecord; constref Origin: TUrlOrigin): Boolean;
var
  UrlOrigin: TUrlOrigin;
begin
  if Origin.Opaque then
    Exit(False);
  UrlOrigin := OriginOfUrl(Url);
  if SameOrigin(Origin, UrlOrigin) then
    Exit(True);
  if LowerCase(SerializeHost(Origin.Host)) <> LowerCase(SerializeHost(Url.Host)) then
    Exit(False);
  { The same host on default ports: http to https or ws/wss upgrades. }
  if not ((Origin.Port = Url.Port) or ((Origin.Port = UrlPortNull) and (Url.Port = UrlPortNull))) then
    Exit(False);
  Result := (Url.Scheme = 'https') or (Url.Scheme = 'wss') or
    ((Origin.Scheme = 'http') and ((Url.Scheme = 'http') or (Url.Scheme = 'ws')));
end;

function UrlMatchesExpression(constref Url: TUrlRecord; const Expression: string; constref Origin: TUrlOrigin;
  RedirectCount: Integer): Boolean;
var
  Scheme: string;
begin
  if Expression = '*' then
    Exit(IsHttpLikeScheme(Url.Scheme) or (not Origin.Opaque and (Origin.Scheme = Url.Scheme)));
  if SameText(Expression, '''self''') then
    Exit(SelfMatches(Url, Origin));
  if IsQuoted(Expression) then
    Exit(False);
  { A scheme source: "https:". }
  if (Length(Expression) > 1) and (Expression[Length(Expression)] = ':') and (Pos('/', Expression) = 0) then
  begin
    Scheme := Copy(Expression, 1, Length(Expression) - 1);
    Exit(SchemePartMatches(Scheme, Url.Scheme));
  end;
  Result := UrlMatchesHostSource(Url, Expression, Origin, RedirectCount);
end;

function UrlMatchesSourceList(constref Url: TUrlRecord; const Sources: TStringArray; constref Origin: TUrlOrigin;
  RedirectCount: Integer): Boolean;
var
  Index: Integer;
begin
  if (Length(Sources) = 1) and SameText(Sources[0], '''none''') then
    Exit(False);
  for Index := 0 to High(Sources) do
    if UrlMatchesExpression(Url, Sources[Index], Origin, RedirectCount) then
      Exit(True);
  Result := False;
end;

end.
