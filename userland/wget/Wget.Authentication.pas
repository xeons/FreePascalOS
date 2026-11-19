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
  HTTP authentication as GNU wget does it: nothing is sent until a
  server answers 401; then the strongest challenge wget can answer is
  taken (Digest with SHA-256, Digest with MD5, Basic) and the request
  made again. The server's choice is remembered, so later requests to
  it carry the credentials at once (Digest with the same nonce and the
  next count, until the server calls it stale).

  The user name and password are --http-user/--http-password, else
  --user/--password, else the host's entry in ~/.netrc (Wget.Netrc).
}
unit Wget.Authentication;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Digest,
  Wget.Urls;

type
  TAuthenticationScheme = (SchemeNone, SchemeBasic, SchemeDigest);

  TServerAuthentication = record
    Key: string;
    Scheme: TAuthenticationScheme;
    Digest: TDigestChallenge;
    NonceCount: LongWord;
    User, Password: string;
  end;

  TAuthenticator = class
  private
    FUser, FPassword: string;
    FHasUser: Boolean;
    FUseNetrc: Boolean;
    FNetrcLoaded: Boolean;
    FNetrcText: string;
    FServers: array of TServerAuthentication;
    function FindServer(const Key: string): Integer;
    function NetrcText: string;
  public
    constructor Create(const User, Password: string; HasUser, UseNetrc: Boolean);
    { The credentials for a host; False if there are none. }
    function CredentialsFor(const Host: string; out User, Password: string): Boolean;
    { The Authorization value for a request ('' while the server has not
      asked for any). }
    function AuthorizationFor(constref Url: TUrl; const Method: string): string;
    { Reads the WWW-Authenticate values of a 401 and remembers how to
      answer. False when there are no credentials or no challenge wget
      can answer. Stale says the server only wants a new nonce. }
    function AcceptChallenges(constref Url: TUrl; const Values: array of string; out Stale: Boolean): Boolean;
  end;

implementation

uses
  Classes,
  SysUtils,
  Crypto.Digests,
  Sys.Environment,
  Sys.RandomNumbers,
  Wget.Challenges,
  Wget.Netrc;

const
  ClientNonceBytes = 16;

function ServerKey(constref Url: TUrl): string;
begin
  Result := FormatHostHeader(Url);
  if Url.Scheme = SchemeHttps then
    Result := 'https://' + Result
  else
    Result := 'http://' + Result;
end;

function ExcludeTrailingSlash(const Path: string): string;
begin
  Result := Path;
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function NewClientNonce: string;
var
  Bytes: array[0..ClientNonceBytes - 1] of Byte;
begin
  FillRandomBytes(@Bytes[0], SizeOf(Bytes));
  Result := HexText(@Bytes[0], SizeOf(Bytes));
end;

constructor TAuthenticator.Create(const User, Password: string; HasUser, UseNetrc: Boolean);
begin
  inherited Create;
  FUser := User;
  FPassword := Password;
  FHasUser := HasUser;
  FUseNetrc := UseNetrc;
end;

function TAuthenticator.NetrcText: string;
var
  Lines: TStringList;
  Home: string;
begin
  if not FNetrcLoaded then
  begin
    FNetrcLoaded := True;
    FNetrcText := '';
    Home := GetVariable('HOME');
    if Home <> '' then
    begin
      Lines := TStringList.Create;
      try
        try
          Lines.LoadFromFile(ExcludeTrailingSlash(Home) + '/.netrc');
          FNetrcText := Lines.Text;
        except
          on EStreamError do
            FNetrcText := '';
        end;
      finally
        Lines.Free;
      end;
    end;
  end;
  Result := FNetrcText;
end;

function TAuthenticator.CredentialsFor(const Host: string; out User, Password: string): Boolean;
begin
  User := FUser;
  Password := FPassword;
  if FHasUser then
    Exit(True);
  Result := FUseNetrc and FindNetrcCredentials(NetrcText, Host, User, Password);
end;

function TAuthenticator.FindServer(const Key: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FServers) do
    if FServers[Index].Key = Key then
      Exit(Index);
  Result := -1;
end;

function TAuthenticator.AuthorizationFor(constref Url: TUrl; const Method: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := FindServer(ServerKey(Url));
  if Index < 0 then
    Exit;
  case FServers[Index].Scheme of
    SchemeBasic:
      Result := BasicAuthorization(FServers[Index].User, FServers[Index].Password);
    SchemeDigest:
      begin
        Inc(FServers[Index].NonceCount);
        Result := DigestAuthorization(FServers[Index].Digest, FServers[Index].User, FServers[Index].Password,
          Method, Url.Path, NewClientNonce, FServers[Index].NonceCount);
      end;
  end;
end;

{ The best challenge: Digest SHA-256, then Digest MD5, then Basic. }
function ChooseChallenge(const Challenges: TChallengeArray; out Scheme: TAuthenticationScheme;
  out Digest: TDigestChallenge): Boolean;
var
  Challenge: TChallenge;
  Candidate: TDigestChallenge;
  HasDigest, HasBasic: Boolean;
begin
  Scheme := SchemeNone;
  Digest := Default(TDigestChallenge);
  HasDigest := False;
  HasBasic := False;
  for Challenge in Challenges do
  begin
    if ReadDigestChallenge(Challenge, Candidate) then
    begin
      if not HasDigest or ((Candidate.Hash = DigestHashSha256) and (Digest.Hash <> DigestHashSha256)) then
        Digest := Candidate;
      HasDigest := True;
    end
    else if SameText(Challenge.Scheme, 'basic') then
      HasBasic := True;
  end;
  if HasDigest then
    Scheme := SchemeDigest
  else if HasBasic then
    Scheme := SchemeBasic;
  Result := Scheme <> SchemeNone;
end;

function TAuthenticator.AcceptChallenges(constref Url: TUrl; const Values: array of string; out Stale: Boolean): Boolean;
var
  Challenges: TChallengeArray;
  Value: string;
  Entry: TServerAuthentication;
  Index: Integer;
begin
  Stale := False;
  Challenges := nil;
  for Value in Values do
    ParseChallenges(Value, Challenges);
  Entry := Default(TServerAuthentication);
  Entry.Key := ServerKey(Url);
  Result := CredentialsFor(Url.Host, Entry.User, Entry.Password) and
    ChooseChallenge(Challenges, Entry.Scheme, Entry.Digest);
  if not Result then
    Exit;
  Stale := (Entry.Scheme = SchemeDigest) and Entry.Digest.Stale;
  Index := FindServer(Entry.Key);
  if Index < 0 then
  begin
    SetLength(FServers, Length(FServers) + 1);
    Index := High(FServers);
  end;
  FServers[Index] := Entry;
end;

end.
