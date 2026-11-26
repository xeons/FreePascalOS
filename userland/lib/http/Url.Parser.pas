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
  The basic URL parser of the URL Standard (section 4.4): the state
  machine from "scheme start" to "fragment", with a base URL for
  relative references and a state override for the URL API's setters
  (Url.Accessors). Validation errors are not reported; failures are.

  The input is UTF-8. Leading and trailing C0 controls and spaces are
  stripped (unless a URL is given to change), tabs and newlines removed
  anywhere. Every percent-encode set takes all bytes above 0x7E, so the
  machine works byte by byte; only the host parser decodes UTF-8 (for
  domain to ASCII).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Parser;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

type
  TUrlParserState = (StateNone, StateSchemeStart, StateScheme, StateNoScheme, StateSpecialRelativeOrAuthority,
    StatePathOrAuthority, StateRelative, StateRelativeSlash, StateSpecialAuthoritySlashes,
    StateSpecialAuthorityIgnoreSlashes, StateAuthority, StateHost, StateHostname, StatePort, StateFile,
    StateFileSlash, StateFileHost, StatePathStart, StatePath, StateOpaquePath, StateQuery, StateFragment);

{ Input against Base (nil for none). False if it is not a URL. }
function ParseUrl(const Input: string; Base: PUrlRecord; out Url: TUrlRecord): Boolean; overload;
function ParseUrl(const Input: string; out Url: TUrlRecord): Boolean; overload;
function ParseUrl(const Input: string; constref Base: TUrlRecord; out Url: TUrlRecord): Boolean; overload;
{ The parser run on an existing URL from StateOverride (a setter). False
  on failure; Url may then be partly changed, so setters work on a
  copy. }
function ParseUrlWithOverride(const Input: string; var Url: TUrlRecord; StateOverride: TUrlParserState): Boolean;

implementation

uses
  SysUtils,
  Url.Hosts,
  Url.PercentEncoding;

type
  TStep = (StepContinue, StepReturn, StepFailure);

  TUrlParser = class
  private
    FInput: string;
    FBase: PUrlRecord;
    FUrl: TUrlRecord;
    FState: TUrlParserState;
    FStateOverride: TUrlParserState;
    FPosition: Integer;
    FBuffer: string;
    FAtSignSeen: Boolean;
    FInsideBrackets: Boolean;
    FPasswordTokenSeen: Boolean;
    function C: Char;
    function AtEnd: Boolean;
    function Remaining: string;
    function RemainingStartsWith(Character: Char): Boolean;
    function HasOverride: Boolean;
    function IsSpecial: Boolean;
    { c is "/", or "\" in a special URL. }
    function IsSlash: Boolean;
    { EOF, "/", "?", "#", or "\" in a special URL. }
    function IsAuthorityEnd: Boolean;
    procedure BeginQuery;
    procedure BeginFragment;
    function SchemeStart: TStep;
    function Scheme: TStep;
    function NoScheme: TStep;
    function SpecialRelativeOrAuthority: TStep;
    function PathOrAuthority: TStep;
    function Relative: TStep;
    function RelativeSlash: TStep;
    function SpecialAuthoritySlashes: TStep;
    function SpecialAuthorityIgnoreSlashes: TStep;
    function Authority: TStep;
    function HostState: TStep;
    function Port: TStep;
    function FileState: TStep;
    function FileSlash: TStep;
    function FileHost: TStep;
    function PathStart: TStep;
    function Path: TStep;
    function OpaquePath: TStep;
    function Query: TStep;
    function Fragment: TStep;
    function RunState: TStep;
  public
    function Run(const Input: string; Base: PUrlRecord; var Url: TUrlRecord; HaveUrl: Boolean;
      StateOverride: TUrlParserState): Boolean;
  end;

function IsAsciiAlpha(Character: Char): Boolean;
begin
  Result := Character in ['a'..'z', 'A'..'Z'];
end;

function IsSingleDot(const Segment: string): Boolean;
begin
  Result := (Segment = '.') or SameText(Segment, '%2e');
end;

function IsDoubleDot(const Segment: string): Boolean;
begin
  Result := (Segment = '..') or SameText(Segment, '.%2e') or SameText(Segment, '%2e.') or
    SameText(Segment, '%2e%2e');
end;

{ The text starts with a Windows drive letter followed by nothing or
  one of / \ ? #. }
function StartsWithWindowsDriveLetter(const Text: string): Boolean;
begin
  Result := (Length(Text) >= 2) and IsWindowsDriveLetter(Copy(Text, 1, 2)) and
    ((Length(Text) = 2) or (Text[3] in ['/', '\', '?', '#']));
end;

{ C0 controls and spaces off both ends, then every tab and newline. }
function CleanInput(const Input: string; StripEnds: Boolean): string;
var
  First, Last: Integer;
  Character: Char;
begin
  First := 1;
  Last := Length(Input);
  if StripEnds then
  begin
    while (First <= Last) and (Ord(Input[First]) <= $20) do
      Inc(First);
    while (Last >= First) and (Ord(Input[Last]) <= $20) do
      Dec(Last);
  end;
  Result := '';
  for Character in Copy(Input, First, Last - First + 1) do
    if not (Character in [#9, #10, #13]) then
      Result := Result + Character;
end;

function TUrlParser.C: Char;
begin
  if FPosition <= Length(FInput) then
    Result := FInput[FPosition]
  else
    Result := #0;
end;

function TUrlParser.AtEnd: Boolean;
begin
  Result := FPosition > Length(FInput);
end;

function TUrlParser.Remaining: string;
begin
  Result := Copy(FInput, FPosition + 1, MaxInt);
end;

function TUrlParser.RemainingStartsWith(Character: Char): Boolean;
begin
  Result := (FPosition + 1 <= Length(FInput)) and (FInput[FPosition + 1] = Character);
end;

function TUrlParser.HasOverride: Boolean;
begin
  Result := FStateOverride <> StateNone;
end;

function TUrlParser.IsSpecial: Boolean;
begin
  Result := UrlIsSpecial(FUrl);
end;

function TUrlParser.IsSlash: Boolean;
begin
  Result := not AtEnd and ((C = '/') or (IsSpecial and (C = '\')));
end;

function TUrlParser.IsAuthorityEnd: Boolean;
begin
  Result := AtEnd or (C in ['/', '?', '#']) or (IsSpecial and (C = '\'));
end;

procedure TUrlParser.BeginQuery;
begin
  FUrl.HasQuery := True;
  FUrl.Query := '';
  FState := StateQuery;
end;

procedure TUrlParser.BeginFragment;
begin
  FUrl.HasFragment := True;
  FUrl.Fragment := '';
  FState := StateFragment;
end;

function TUrlParser.SchemeStart: TStep;
begin
  Result := StepContinue;
  if not AtEnd and IsAsciiAlpha(C) then
  begin
    FBuffer := FBuffer + LowerCase(C);
    FState := StateScheme;
  end
  else if not HasOverride then
  begin
    FState := StateNoScheme;
    Dec(FPosition);
  end
  else
    Result := StepFailure;
end;

function TUrlParser.Scheme: TStep;
begin
  Result := StepContinue;
  if not AtEnd and (C in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.']) then
    FBuffer := FBuffer + LowerCase(C)
  else if not AtEnd and (C = ':') then
  begin
    if HasOverride then
    begin
      if IsSpecialScheme(FUrl.Scheme) <> IsSpecialScheme(FBuffer) then
        Exit(StepReturn);
      if (UrlIncludesCredentials(FUrl) or (FUrl.Port <> UrlPortNull)) and (FBuffer = 'file') then
        Exit(StepReturn);
      if (FUrl.Scheme = 'file') and (FUrl.Host.Kind = UrlHostEmpty) then
        Exit(StepReturn);
    end;
    FUrl.Scheme := FBuffer;
    if HasOverride then
    begin
      if FUrl.Port = DefaultPortOfScheme(FUrl.Scheme) then
        FUrl.Port := UrlPortNull;
      Exit(StepReturn);
    end;
    FBuffer := '';
    if FUrl.Scheme = 'file' then
      FState := StateFile
    else if IsSpecial and (FBase <> nil) and (FBase^.Scheme = FUrl.Scheme) then
      FState := StateSpecialRelativeOrAuthority
    else if IsSpecial then
      FState := StateSpecialAuthoritySlashes
    else if RemainingStartsWith('/') then
    begin
      FState := StatePathOrAuthority;
      Inc(FPosition);
    end
    else
    begin
      FUrl.OpaquePath := True;
      FUrl.Path := '';
      FState := StateOpaquePath;
    end;
  end
  else if not HasOverride then
  begin
    FBuffer := '';
    FState := StateNoScheme;
    FPosition := 0;
  end
  else
    Result := StepFailure;
end;

function TUrlParser.NoScheme: TStep;
begin
  Result := StepContinue;
  if (FBase = nil) or (FBase^.OpaquePath and (AtEnd or (C <> '#'))) then
    Exit(StepFailure);
  if FBase^.OpaquePath then
  begin
    FUrl.Scheme := FBase^.Scheme;
    FUrl.Path := FBase^.Path;
    FUrl.OpaquePath := True;
    FUrl.HasQuery := FBase^.HasQuery;
    FUrl.Query := FBase^.Query;
    BeginFragment;
  end
  else
  begin
    if FBase^.Scheme <> 'file' then
      FState := StateRelative
    else
      FState := StateFile;
    Dec(FPosition);
  end;
end;

function TUrlParser.SpecialRelativeOrAuthority: TStep;
begin
  Result := StepContinue;
  if not AtEnd and (C = '/') and RemainingStartsWith('/') then
  begin
    FState := StateSpecialAuthorityIgnoreSlashes;
    Inc(FPosition);
  end
  else
  begin
    FState := StateRelative;
    Dec(FPosition);
  end;
end;

function TUrlParser.PathOrAuthority: TStep;
begin
  Result := StepContinue;
  if not AtEnd and (C = '/') then
    FState := StateAuthority
  else
  begin
    FState := StatePath;
    Dec(FPosition);
  end;
end;

function TUrlParser.Relative: TStep;
begin
  Result := StepContinue;
  FUrl.Scheme := FBase^.Scheme;
  if IsSlash then
    FState := StateRelativeSlash
  else
  begin
    FUrl.Username := FBase^.Username;
    FUrl.Password := FBase^.Password;
    FUrl.Host := FBase^.Host;
    FUrl.Port := FBase^.Port;
    FUrl.Path := FBase^.Path;
    FUrl.HasQuery := FBase^.HasQuery;
    FUrl.Query := FBase^.Query;
    if not AtEnd and (C = '?') then
      BeginQuery
    else if not AtEnd and (C = '#') then
      BeginFragment
    else if not AtEnd then
    begin
      FUrl.HasQuery := False;
      FUrl.Query := '';
      ShortenPath(FUrl);
      FState := StatePath;
      Dec(FPosition);
    end;
  end;
end;

function TUrlParser.RelativeSlash: TStep;
begin
  Result := StepContinue;
  if IsSpecial and IsSlash then
    FState := StateSpecialAuthorityIgnoreSlashes
  else if not AtEnd and (C = '/') then
    FState := StateAuthority
  else
  begin
    FUrl.Username := FBase^.Username;
    FUrl.Password := FBase^.Password;
    FUrl.Host := FBase^.Host;
    FUrl.Port := FBase^.Port;
    FState := StatePath;
    Dec(FPosition);
  end;
end;

function TUrlParser.SpecialAuthoritySlashes: TStep;
begin
  Result := StepContinue;
  FState := StateSpecialAuthorityIgnoreSlashes;
  if not AtEnd and (C = '/') and RemainingStartsWith('/') then
    Inc(FPosition)
  else
    Dec(FPosition);
end;

function TUrlParser.SpecialAuthorityIgnoreSlashes: TStep;
begin
  Result := StepContinue;
  if AtEnd or not (C in ['/', '\']) then
  begin
    FState := StateAuthority;
    Dec(FPosition);
  end;
end;

function TUrlParser.Authority: TStep;
var
  Character: Char;
  Encoded: string;
begin
  Result := StepContinue;
  if not AtEnd and (C = '@') then
  begin
    if FAtSignSeen then
      FBuffer := '%40' + FBuffer;
    FAtSignSeen := True;
    for Character in FBuffer do
    begin
      if (Character = ':') and not FPasswordTokenSeen then
      begin
        FPasswordTokenSeen := True;
        Continue;
      end;
      Encoded := PercentEncode(Character, EncodeUserinfo);
      if FPasswordTokenSeen then
        FUrl.Password := FUrl.Password + Encoded
      else
        FUrl.Username := FUrl.Username + Encoded;
    end;
    FBuffer := '';
  end
  else if IsAuthorityEnd then
  begin
    if FAtSignSeen and (FBuffer = '') then
      Exit(StepFailure);
    FPosition := FPosition - Length(FBuffer) - 1;
    FBuffer := '';
    FState := StateHost;
  end
  else
    FBuffer := FBuffer + C;
end;

function TUrlParser.HostState: TStep;
var
  Host: TUrlHost;
begin
  Result := StepContinue;
  if HasOverride and (FUrl.Scheme = 'file') then
  begin
    Dec(FPosition);
    FState := StateFileHost;
  end
  else if not AtEnd and (C = ':') and not FInsideBrackets then
  begin
    if FBuffer = '' then
      Exit(StepFailure);
    if FStateOverride = StateHostname then
      Exit(StepFailure);
    if not ParseHost(FBuffer, not IsSpecial, Host) then
      Exit(StepFailure);
    FUrl.Host := Host;
    FBuffer := '';
    FState := StatePort;
  end
  else if IsAuthorityEnd then
  begin
    Dec(FPosition);
    if IsSpecial and (FBuffer = '') then
      Exit(StepFailure);
    if HasOverride and (FBuffer = '') and (UrlIncludesCredentials(FUrl) or (FUrl.Port <> UrlPortNull)) then
      Exit(StepFailure);
    if not ParseHost(FBuffer, not IsSpecial, Host) then
      Exit(StepFailure);
    { An empty opaque host is the empty host. }
    if (Host.Kind = UrlHostOpaque) and (Host.Name = '') then
      Host.Kind := UrlHostEmpty;
    FUrl.Host := Host;
    FBuffer := '';
    FState := StatePathStart;
    if HasOverride then
      Exit(StepReturn);
  end
  else
  begin
    if C = '[' then
      FInsideBrackets := True;
    if C = ']' then
      FInsideBrackets := False;
    FBuffer := FBuffer + C;
  end;
end;

function TUrlParser.Port: TStep;
var
  Value: LongInt;
  Character: Char;
begin
  Result := StepContinue;
  if not AtEnd and (C in ['0'..'9']) then
    FBuffer := FBuffer + C
  else if IsAuthorityEnd or HasOverride then
  begin
    if FBuffer <> '' then
    begin
      Value := 0;
      for Character in FBuffer do
      begin
        Value := Value * 10 + Ord(Character) - Ord('0');
        if Value > 65535 then
          Exit(StepFailure);
      end;
      if Value = DefaultPortOfScheme(FUrl.Scheme) then
        FUrl.Port := UrlPortNull
      else
        FUrl.Port := Value;
      FBuffer := '';
      if HasOverride then
        Exit(StepReturn);
    end;
    if HasOverride then
      Exit(StepFailure);
    FState := StatePathStart;
    Dec(FPosition);
  end
  else
    Result := StepFailure;
end;

function TUrlParser.FileState: TStep;
begin
  Result := StepContinue;
  FUrl.Scheme := 'file';
  FUrl.Host := Default(TUrlHost);
  FUrl.Host.Kind := UrlHostEmpty;
  if not AtEnd and (C in ['/', '\']) then
    FState := StateFileSlash
  else if (FBase <> nil) and (FBase^.Scheme = 'file') then
  begin
    FUrl.Host := FBase^.Host;
    FUrl.Path := FBase^.Path;
    FUrl.HasQuery := FBase^.HasQuery;
    FUrl.Query := FBase^.Query;
    if not AtEnd and (C = '?') then
      BeginQuery
    else if not AtEnd and (C = '#') then
      BeginFragment
    else if not AtEnd then
    begin
      FUrl.HasQuery := False;
      FUrl.Query := '';
      if not StartsWithWindowsDriveLetter(Copy(FInput, FPosition, MaxInt)) then
        ShortenPath(FUrl)
      else
        FUrl.Path := '';
      FState := StatePath;
      Dec(FPosition);
    end;
  end
  else
  begin
    FState := StatePath;
    Dec(FPosition);
  end;
end;

function TUrlParser.FileSlash: TStep;
var
  FirstSegment: string;
begin
  Result := StepContinue;
  if not AtEnd and (C in ['/', '\']) then
    FState := StateFileHost
  else
  begin
    if (FBase <> nil) and (FBase^.Scheme = 'file') then
    begin
      FUrl.Host := FBase^.Host;
      FirstSegment := PathSegment(FBase^, 0);
      if not StartsWithWindowsDriveLetter(Copy(FInput, FPosition, MaxInt)) and
         (PathSegmentCount(FBase^) > 0) and IsWindowsDriveLetter(FirstSegment, True) then
        AppendPathSegment(FUrl, FirstSegment);
    end;
    FState := StatePath;
    Dec(FPosition);
  end;
end;

function TUrlParser.FileHost: TStep;
var
  Host: TUrlHost;
begin
  Result := StepContinue;
  if AtEnd or (C in ['/', '\', '?', '#']) then
  begin
    Dec(FPosition);
    if not HasOverride and IsWindowsDriveLetter(FBuffer) then
      FState := StatePath
    else if FBuffer = '' then
    begin
      FUrl.Host := Default(TUrlHost);
      FUrl.Host.Kind := UrlHostEmpty;
      if HasOverride then
        Exit(StepReturn);
      FState := StatePathStart;
    end
    else
    begin
      if not ParseHost(FBuffer, not IsSpecial, Host) then
        Exit(StepFailure);
      if (Host.Kind = UrlHostDomain) and (Host.Name = 'localhost') then
      begin
        Host := Default(TUrlHost);
        Host.Kind := UrlHostEmpty;
      end;
      FUrl.Host := Host;
      if HasOverride then
        Exit(StepReturn);
      FBuffer := '';
      FState := StatePathStart;
    end;
  end
  else
    FBuffer := FBuffer + C;
end;

function TUrlParser.PathStart: TStep;
begin
  Result := StepContinue;
  if IsSpecial then
  begin
    FState := StatePath;
    if AtEnd or not (C in ['/', '\']) then
      Dec(FPosition);
  end
  else if not HasOverride and not AtEnd and (C = '?') then
    BeginQuery
  else if not HasOverride and not AtEnd and (C = '#') then
    BeginFragment
  else if not AtEnd then
  begin
    FState := StatePath;
    if C <> '/' then
      Dec(FPosition);
  end
  else if HasOverride and (FUrl.Host.Kind = UrlHostNull) then
    AppendPathSegment(FUrl, '');
end;

function TUrlParser.Path: TStep;
begin
  Result := StepContinue;
  if AtEnd or IsSlash or (not HasOverride and (C in ['?', '#'])) then
  begin
    if IsDoubleDot(FBuffer) then
    begin
      ShortenPath(FUrl);
      if not IsSlash then
        AppendPathSegment(FUrl, '');
    end
    else if IsSingleDot(FBuffer) and not IsSlash then
      AppendPathSegment(FUrl, '')
    else if not IsSingleDot(FBuffer) then
    begin
      if (FUrl.Scheme = 'file') and (FUrl.Path = '') and IsWindowsDriveLetter(FBuffer) then
        FBuffer[2] := ':';
      AppendPathSegment(FUrl, FBuffer);
    end;
    FBuffer := '';
    if not AtEnd and (C = '?') then
      BeginQuery
    else if not AtEnd and (C = '#') then
      BeginFragment;
  end
  else
    FBuffer := FBuffer + PercentEncode(C, EncodePath);
end;

function TUrlParser.OpaquePath: TStep;
begin
  Result := StepContinue;
  if AtEnd then
    Exit;
  if C = '?' then
    BeginQuery
  else if C = '#' then
    BeginFragment
  else if (C = ' ') and (RemainingStartsWith('?') or RemainingStartsWith('#')) then
    FUrl.Path := FUrl.Path + '%20'
  else
    FUrl.Path := FUrl.Path + PercentEncode(C, EncodeC0Control);
end;

function TUrlParser.Query: TStep;
begin
  Result := StepContinue;
  if (not HasOverride and not AtEnd and (C = '#')) or AtEnd then
  begin
    if IsSpecial then
      FUrl.Query := FUrl.Query + PercentEncode(FBuffer, EncodeSpecialQuery)
    else
      FUrl.Query := FUrl.Query + PercentEncode(FBuffer, EncodeQuery);
    FBuffer := '';
    if not AtEnd then
      BeginFragment;
  end
  else
    FBuffer := FBuffer + C;
end;

function TUrlParser.Fragment: TStep;
begin
  Result := StepContinue;
  if not AtEnd then
    FUrl.Fragment := FUrl.Fragment + PercentEncode(C, EncodeFragment);
end;

function TUrlParser.RunState: TStep;
begin
  case FState of
    StateSchemeStart: Result := SchemeStart;
    StateScheme: Result := Scheme;
    StateNoScheme: Result := NoScheme;
    StateSpecialRelativeOrAuthority: Result := SpecialRelativeOrAuthority;
    StatePathOrAuthority: Result := PathOrAuthority;
    StateRelative: Result := Relative;
    StateRelativeSlash: Result := RelativeSlash;
    StateSpecialAuthoritySlashes: Result := SpecialAuthoritySlashes;
    StateSpecialAuthorityIgnoreSlashes: Result := SpecialAuthorityIgnoreSlashes;
    StateAuthority: Result := Authority;
    StateHost, StateHostname: Result := HostState;
    StatePort: Result := Port;
    StateFile: Result := FileState;
    StateFileSlash: Result := FileSlash;
    StateFileHost: Result := FileHost;
    StatePathStart: Result := PathStart;
    StatePath: Result := Path;
    StateOpaquePath: Result := OpaquePath;
    StateQuery: Result := Query;
    StateFragment: Result := Fragment;
  else
    Result := StepFailure;
  end;
end;

function TUrlParser.Run(const Input: string; Base: PUrlRecord; var Url: TUrlRecord; HaveUrl: Boolean;
  StateOverride: TUrlParserState): Boolean;
var
  Step: TStep;
begin
  FInput := CleanInput(Input, not HaveUrl);
  FBase := Base;
  if HaveUrl then
    FUrl := Url
  else
    FUrl := EmptyUrl;
  FStateOverride := StateOverride;
  if StateOverride <> StateNone then
    FState := StateOverride
  else
    FState := StateSchemeStart;
  FBuffer := '';
  FPosition := 1;
  while True do
  begin
    Step := RunState;
    if Step = StepFailure then
    begin
      { A setter's parse keeps what it changed before the failure (a host
        set before a bad port stays set). }
      if HaveUrl and (StateOverride <> StateNone) then
        Url := FUrl;
      Exit(False);
    end;
    if Step = StepReturn then
      Break;
    if AtEnd then
      Break;
    Inc(FPosition);
  end;
  Url := FUrl;
  Result := True;
end;

function ParseUrl(const Input: string; Base: PUrlRecord; out Url: TUrlRecord): Boolean;
var
  Parser: TUrlParser;
begin
  Url := EmptyUrl;
  Parser := TUrlParser.Create;
  try
    Result := Parser.Run(Input, Base, Url, False, StateNone);
  finally
    Parser.Free;
  end;
  if not Result then
    Url := EmptyUrl;
end;

function ParseUrl(const Input: string; out Url: TUrlRecord): Boolean;
begin
  Result := ParseUrl(Input, nil, Url);
end;

function ParseUrl(const Input: string; constref Base: TUrlRecord; out Url: TUrlRecord): Boolean;
begin
  Result := ParseUrl(Input, @Base, Url);
end;

function ParseUrlWithOverride(const Input: string; var Url: TUrlRecord; StateOverride: TUrlParserState): Boolean;
var
  Parser: TUrlParser;
begin
  Parser := TUrlParser.Create;
  try
    Result := Parser.Run(Input, nil, Url, True, StateOverride);
  finally
    Parser.Free;
  end;
end;

end.
