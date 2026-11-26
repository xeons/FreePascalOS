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
  Content Security Policy Level 3, parsed and stored (section 2.2):
  Content-Security-Policy and Content-Security-Policy-Report-Only fields
  (a comma separated list of policies) and <meta http-equiv> policies.
  A policy is directives separated by ";": the name in lower case (ASCII
  alphanumerics and "-" only, else the directive is skipped), its values
  split at ASCII whitespace, a repeated name ignored. A meta policy drops
  report-uri, frame-ancestors and sandbox.

  The checks are Web.Fetch.CspChecks (source lists in
  Web.Fetch.CspSources); a violation is described by a TCspViolation and
  handed to the client's TCspViolationReporter (the document's: the
  securitypolicyviolation event and the reports, Web.Loading.CspReports).
}
unit Web.Fetch.ContentSecurityPolicy;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TCspDisposition = (CspEnforce, CspReport);
  TCspSource = (CspFromHeader, CspFromMeta);

  TCspDirective = record
    Name: string;
    Values: TStringArray;
  end;

  TCspPolicy = class
  public
    Directives: array of TCspDirective;
    Disposition: TCspDisposition;
    Source: TCspSource;
    function HasDirective(const Name: string): Boolean;
    function DirectiveValues(const Name: string; out Values: TStringArray): Boolean;
    function Serialize: string;
  end;

  { One violation (CSP 2.4): what was blocked ('inline', 'eval', a URL),
    the directive, the policy, where. }
  TCspViolation = record
    DocumentUrl: string;
    Referrer: string;
    BlockedUri: string;
    EffectiveDirective: string;
    OriginalPolicy: string;
    Disposition: TCspDisposition;
    { The first 40 characters of the inline script or style, or eval's
      string, when the directive has 'report-sample'. }
    Sample: string;
    StatusCode: Integer;
    SourceFile: string;
    LineNumber, ColumnNumber: Integer;
    { The element the violation is about (nil: the document). }
    Element: TObject;
    { The policy's report-uri URLs and report-to group. }
    ReportUris: TStringArray;
    ReportTo: string;
  end;

  TCspViolationReporter = class
  public
    procedure ViolationOccurred(constref Violation: TCspViolation); virtual; abstract;
  end;

  { A document's CSP list (part of its policy container). }
  TCspList = class
  private
    FPolicies: array of TCspPolicy;
    function GetPolicy(Index: Integer): TCspPolicy;
  public
    destructor Destroy; override;
    procedure Clear;
    { Every policy of a field value. }
    procedure AddFromField(const Value: string; Disposition: TCspDisposition);
    procedure AddFromMeta(const Value: string);
    procedure Assign(Source: TCspList);
    { Some enforced policy has the directive. }
    function EnforcesDirective(const Name: string): Boolean;
    function Count: Integer;
    property Policies[Index: Integer]: TCspPolicy read GetPolicy; default;
  end;

{ One serialized policy; nil when it has no directives. }
function ParseCspPolicy(const Text: string; Source: TCspSource; Disposition: TCspDisposition): TCspPolicy;

implementation

function IsAsciiWhitespace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function SplitOnWhitespace(const Text: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and IsAsciiWhitespace(Text[Position]) do
      Inc(Position);
    Start := Position;
    while (Position <= Length(Text)) and not IsAsciiWhitespace(Text[Position]) do
      Inc(Position);
    if Position > Start then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Text, Start, Position - Start);
    end;
  end;
end;

function IsDirectiveName(const Name: string): Boolean;
var
  Index: Integer;
begin
  if Name = '' then
    Exit(False);
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['a'..'z', '0'..'9', '-']) then
      Exit(False);
  Result := True;
end;

function TCspPolicy.HasDirective(const Name: string): Boolean;
var
  Values: TStringArray;
begin
  Result := DirectiveValues(Name, Values);
end;

function TCspPolicy.DirectiveValues(const Name: string; out Values: TStringArray): Boolean;
var
  Index: Integer;
begin
  Values := nil;
  for Index := 0 to High(Directives) do
    if Directives[Index].Name = Name then
    begin
      Values := Directives[Index].Values;
      Exit(True);
    end;
  Result := False;
end;

function TCspPolicy.Serialize: string;
var
  Index, ValueIndex: Integer;
begin
  Result := '';
  for Index := 0 to High(Directives) do
  begin
    if Index > 0 then
      Result := Result + '; ';
    Result := Result + Directives[Index].Name;
    for ValueIndex := 0 to High(Directives[Index].Values) do
      Result := Result + ' ' + Directives[Index].Values[ValueIndex];
  end;
end;

function ParseCspPolicy(const Text: string; Source: TCspSource; Disposition: TCspDisposition): TCspPolicy;
var
  Tokens, Parts: TStringArray;
  Index: Integer;
  Name: string;
  Directive: TCspDirective;
begin
  Result := TCspPolicy.Create;
  Result.Source := Source;
  Result.Disposition := Disposition;
  Tokens := Text.Split([';']);
  for Index := 0 to High(Tokens) do
  begin
    Parts := SplitOnWhitespace(Tokens[Index]);
    if Length(Parts) = 0 then
      Continue;
    Name := LowerCase(Parts[0]);
    if not IsDirectiveName(Name) or Result.HasDirective(Name) then
      Continue;
    if (Source = CspFromMeta) and ((Name = 'report-uri') or (Name = 'frame-ancestors') or (Name = 'sandbox')) then
      Continue;
    Directive.Name := Name;
    Directive.Values := Copy(Parts, 1, Length(Parts) - 1);
    SetLength(Result.Directives, Length(Result.Directives) + 1);
    Result.Directives[High(Result.Directives)] := Directive;
  end;
  if Length(Result.Directives) = 0 then
    FreeAndNil(Result);
end;

destructor TCspList.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TCspList.Clear;
var
  Index: Integer;
begin
  for Index := 0 to High(FPolicies) do
    FPolicies[Index].Free;
  FPolicies := nil;
end;

function TCspList.GetPolicy(Index: Integer): TCspPolicy;
begin
  Result := FPolicies[Index];
end;

procedure TCspList.AddFromField(const Value: string; Disposition: TCspDisposition);
var
  Texts: TStringArray;
  Index: Integer;
  Policy: TCspPolicy;
begin
  Texts := Value.Split([',']);
  for Index := 0 to High(Texts) do
  begin
    Policy := ParseCspPolicy(Texts[Index], CspFromHeader, Disposition);
    if Policy <> nil then
    begin
      SetLength(FPolicies, Length(FPolicies) + 1);
      FPolicies[High(FPolicies)] := Policy;
    end;
  end;
end;

procedure TCspList.AddFromMeta(const Value: string);
var
  Policy: TCspPolicy;
begin
  Policy := ParseCspPolicy(Value, CspFromMeta, CspEnforce);
  if Policy = nil then
    Exit;
  SetLength(FPolicies, Length(FPolicies) + 1);
  FPolicies[High(FPolicies)] := Policy;
end;

procedure TCspList.Assign(Source: TCspList);
var
  Index: Integer;
begin
  Clear;
  if Source = nil then
    Exit;
  for Index := 0 to Source.Count - 1 do
  begin
    SetLength(FPolicies, Length(FPolicies) + 1);
    FPolicies[High(FPolicies)] := ParseCspPolicy(Source[Index].Serialize, Source[Index].Source,
      Source[Index].Disposition);
  end;
end;

function TCspList.EnforcesDirective(const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FPolicies) do
    if (FPolicies[Index].Disposition = CspEnforce) and FPolicies[Index].HasDirective(Name) then
      Exit(True);
  Result := False;
end;

function TCspList.Count: Integer;
begin
  Result := Length(FPolicies);
end;

end.
