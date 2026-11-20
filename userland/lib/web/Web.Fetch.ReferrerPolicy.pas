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
  Referrer Policy (W3C Referrer Policy): the policies, parsing them from
  a Referrer-Policy field (the last token known wins) or a referrerpolicy
  attribute, stripping a URL for use as a referrer (no credentials, no
  fragment; origin only when asked; nothing for local schemes), and
  "determine request's referrer" for each policy, the default being
  strict-origin-when-cross-origin. Also "potentially trustworthy URL"
  (Secure Contexts), which the policies and mixed content use.
}
unit Web.Fetch.ReferrerPolicy;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Url.Origins;

const
  MaximumReferrerLength = 4096;

type
  TReferrerPolicy = (
    ReferrerPolicyEmpty,
    ReferrerPolicyNoReferrer,
    ReferrerPolicyNoReferrerWhenDowngrade,
    ReferrerPolicySameOrigin,
    ReferrerPolicyOrigin,
    ReferrerPolicyStrictOrigin,
    ReferrerPolicyOriginWhenCrossOrigin,
    ReferrerPolicyStrictOriginWhenCrossOrigin,
    ReferrerPolicyUnsafeUrl);

const
  DefaultReferrerPolicy = ReferrerPolicyStrictOriginWhenCrossOrigin;

{ A token as a policy; False when it is not one ('' is the empty policy). }
function ReferrerPolicyFromToken(const Token: string; out Policy: TReferrerPolicy): Boolean;
function ReferrerPolicyToken(Policy: TReferrerPolicy): string;
{ The Referrer-Policy field: the last known token, or the empty policy. }
function ParseReferrerPolicyField(const Value: string): TReferrerPolicy;
{ A referrerpolicy attribute: its value when known, else the empty one. }
function ReferrerPolicyFromAttribute(const Value: string): TReferrerPolicy;

{ Secure Contexts: about:blank, about:srcdoc, data:, file: and URLs
  whose origin is potentially trustworthy. }
function UrlIsPotentiallyTrustworthy(constref Url: TUrlRecord): Boolean;
{ "Strip url for use as a referrer"; False for no referrer. }
function StripUrlForReferrer(constref Url: TUrlRecord; OriginOnly: Boolean; out Stripped: string): Boolean;
{ The Referer value for a request to Target from a document at Source
  (its URL) under Policy; False: send none. }
function DetermineReferrer(constref Source, Target: TUrlRecord; Policy: TReferrerPolicy; out Referrer: string): Boolean;

implementation

uses
  Web.Fetch.MimeTypes;

const
  PolicyTokens: array[TReferrerPolicy] of string = ('', 'no-referrer', 'no-referrer-when-downgrade', 'same-origin',
    'origin', 'strict-origin', 'origin-when-cross-origin', 'strict-origin-when-cross-origin', 'unsafe-url');

function ReferrerPolicyFromToken(const Token: string; out Policy: TReferrerPolicy): Boolean;
var
  Candidate: TReferrerPolicy;
  Lowered: string;
begin
  Lowered := LowerCase(Token);
  for Candidate := Low(TReferrerPolicy) to High(TReferrerPolicy) do
    if PolicyTokens[Candidate] = Lowered then
    begin
      Policy := Candidate;
      Exit(True);
    end;
  Policy := ReferrerPolicyEmpty;
  Result := False;
end;

function ReferrerPolicyToken(Policy: TReferrerPolicy): string;
begin
  Result := PolicyTokens[Policy];
end;

function ParseReferrerPolicyField(const Value: string): TReferrerPolicy;
var
  Tokens: TStringArray;
  Index: Integer;
  Candidate: TReferrerPolicy;
begin
  Result := ReferrerPolicyEmpty;
  Tokens := Value.Split([',']);
  for Index := 0 to High(Tokens) do
    if (TrimHttpWhitespace(Tokens[Index]) <> '') and
       ReferrerPolicyFromToken(TrimHttpWhitespace(Tokens[Index]), Candidate) then
      Result := Candidate;
end;

function ReferrerPolicyFromAttribute(const Value: string): TReferrerPolicy;
begin
  if not ReferrerPolicyFromToken(Value, Result) then
    Result := ReferrerPolicyEmpty;
end;

function UrlIsPotentiallyTrustworthy(constref Url: TUrlRecord): Boolean;
var
  Origin: TUrlOrigin;
begin
  if (Url.Scheme = 'about') and ((Url.Path = 'blank') or (Url.Path = 'srcdoc')) then
    Exit(True);
  if (Url.Scheme = 'data') or (Url.Scheme = 'file') then
    Exit(True);
  Origin := OriginOfUrl(Url);
  Result := not Origin.Opaque and OriginIsPotentiallyTrustworthy(Origin);
end;

function StripUrlForReferrer(constref Url: TUrlRecord; OriginOnly: Boolean; out Stripped: string): Boolean;
var
  Copy_: TUrlRecord;
begin
  Stripped := '';
  if (Url.Scheme = '') or (Url.Scheme = 'about') or (Url.Scheme = 'blob') or (Url.Scheme = 'data') then
    Exit(False);
  Copy_ := Url;
  Copy_.Username := '';
  Copy_.Password := '';
  Copy_.HasFragment := False;
  Copy_.Fragment := '';
  if OriginOnly then
  begin
    if Copy_.OpaquePath then
      Exit(False);
    Copy_.Path := '/';
    Copy_.HasQuery := False;
    Copy_.Query := '';
  end;
  Stripped := SerializeUrl(Copy_);
  Result := True;
end;

function SameOriginUrls(constref First, Second: TUrlRecord): Boolean;
begin
  Result := SameOrigin(OriginOfUrl(First), OriginOfUrl(Second));
end;

function DetermineReferrer(constref Source, Target: TUrlRecord; Policy: TReferrerPolicy; out Referrer: string): Boolean;
var
  FullUrl, OriginUrl: string;
  HasFull, HasOrigin, Downgrade: Boolean;
begin
  Referrer := '';
  if Policy = ReferrerPolicyEmpty then
    Policy := DefaultReferrerPolicy;
  HasFull := StripUrlForReferrer(Source, False, FullUrl);
  HasOrigin := StripUrlForReferrer(Source, True, OriginUrl);
  if not HasFull then
    Exit(False);
  if Length(FullUrl) > MaximumReferrerLength then
    FullUrl := OriginUrl;
  Downgrade := UrlIsPotentiallyTrustworthy(Source) and not UrlIsPotentiallyTrustworthy(Target);
  case Policy of
    ReferrerPolicyNoReferrer:
      Exit(False);
    ReferrerPolicyOrigin:
      Referrer := OriginUrl;
    ReferrerPolicyUnsafeUrl:
      Referrer := FullUrl;
    ReferrerPolicyStrictOrigin:
      if Downgrade then
        Exit(False)
      else
        Referrer := OriginUrl;
    ReferrerPolicyStrictOriginWhenCrossOrigin:
      if SameOriginUrls(Source, Target) then
        Referrer := FullUrl
      else if Downgrade then
        Exit(False)
      else
        Referrer := OriginUrl;
    ReferrerPolicySameOrigin:
      if SameOriginUrls(Source, Target) then
        Referrer := FullUrl
      else
        Exit(False);
    ReferrerPolicyOriginWhenCrossOrigin:
      if SameOriginUrls(Source, Target) then
        Referrer := FullUrl
      else
        Referrer := OriginUrl;
    ReferrerPolicyNoReferrerWhenDowngrade:
      if Downgrade then
        Exit(False)
      else
        Referrer := FullUrl;
  end;
  Result := HasOrigin or (Referrer <> '');
  if Referrer = '' then
    Result := False;
end;

end.
