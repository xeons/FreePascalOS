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
  Which hosts may use cookies: the browser's cookie settings (accept
  all, refuse all, refuse third-party cookies) with exceptions, a list
  of hosts always allowed and one always blocked. An exception names a
  host or a parent domain ("example.com" covers "www.example.com");
  the longest matching exception of either list decides, a tie
  blocks. Plain logic: TCookieJar applies it (Http.Cookies).
}
unit Http.CookiePolicies;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TCookieAcceptance = (CookieAcceptAll, CookieRefuseAll, CookieRefuseThirdParty);

  TCookieUsePolicy = record
    Acceptance: TCookieAcceptance;
    AllowedHosts, BlockedHosts: TStringArray;
  end;

{ Accept all, no exceptions. }
function DefaultCookieUsePolicy: TCookieUsePolicy;
{ Host is Pattern or a subdomain of it (case-insensitive, a leading dot
  in Pattern ignored, IP addresses only exactly). }
function HostMatchesException(const Host, Pattern: string): Boolean;
{ Exceptions first: the longest matching pattern of either list decides
  (a tie: blocked); otherwise the acceptance: RefuseAll refuses,
  RefuseThirdParty refuses when ThirdParty. }
function CookieUseAllowed(constref Policy: TCookieUsePolicy; const Host: string; ThirdParty: Boolean): Boolean;

implementation

function DefaultCookieUsePolicy: TCookieUsePolicy;
begin
  Result.Acceptance := CookieAcceptAll;
  Result.AllowedHosts := nil;
  Result.BlockedHosts := nil;
end;

function LooksLikeIpAddress(const Host: string): Boolean;
var
  Character: Char;
begin
  if Pos(':', Host) > 0 then
    Exit(True);
  Result := Host <> '';
  for Character in Host do
    if not (Character in ['0'..'9', '.']) then
      Exit(False);
end;

function NormalizedPattern(const Pattern: string): string;
begin
  Result := LowerCase(Trim(Pattern));
  while (Result <> '') and (Result[1] = '.') do
    Delete(Result, 1, 1);
  if (Length(Result) >= 2) and (Result[1] = '[') and (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function HostMatchesException(const Host, Pattern: string): Boolean;
var
  LowerHost, Wanted: string;
begin
  Wanted := NormalizedPattern(Pattern);
  LowerHost := NormalizedPattern(Host);
  if (Wanted = '') or (LowerHost = '') then
    Exit(False);
  if LowerHost = Wanted then
    Exit(True);
  if LooksLikeIpAddress(LowerHost) or LooksLikeIpAddress(Wanted) then
    Exit(False);
  Result := (Length(LowerHost) > Length(Wanted)) and
    (Copy(LowerHost, Length(LowerHost) - Length(Wanted), Length(Wanted) + 1) = '.' + Wanted);
end;

{ The length of the longest pattern of List that Host matches, -1 for none. }
function LongestMatch(const List: TStringArray; const Host: string): Integer;
var
  Index, Size: Integer;
begin
  Result := -1;
  for Index := 0 to High(List) do
    if HostMatchesException(Host, List[Index]) then
    begin
      Size := Length(NormalizedPattern(List[Index]));
      if Size > Result then
        Result := Size;
    end;
end;

function CookieUseAllowed(constref Policy: TCookieUsePolicy; const Host: string; ThirdParty: Boolean): Boolean;
var
  Allowed, Blocked: Integer;
begin
  Allowed := LongestMatch(Policy.AllowedHosts, Host);
  Blocked := LongestMatch(Policy.BlockedHosts, Host);
  if (Blocked >= 0) and (Blocked >= Allowed) then
    Exit(False);
  if Allowed >= 0 then
    Exit(True);
  case Policy.Acceptance of
    CookieRefuseAll: Result := False;
    CookieRefuseThirdParty: Result := not ThirdParty;
  else
    Result := True;
  end;
end;

end.
