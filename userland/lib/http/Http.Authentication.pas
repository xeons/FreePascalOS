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
  HTTP authentication (RFC 9110 section 11): nothing is sent until a
  server answers 401; then the strongest challenge that can be answered
  is taken (Digest with SHA-256, Digest with MD5, Basic) and the
  request made again. The server's choice is remembered per origin, so
  later requests to it carry the credentials at once (Digest with the
  same nonce and the next count, until the server calls it stale).

  The credentials are the ones given, else what the credentials
  provider says for the host (wget's reads ~/.netrc; a browser asks
  the user). Thread safe.

  Plain Pascal (with libcryptography's digests and random
  numbers), checked on the host by tools/HttpTest.
}
unit Http.Authentication;

{$mode objfpc}
{$H+}

interface

uses
  Http.Digest,
  Url.Records;

type
  TAuthenticationScheme = (SchemeNone, SchemeBasic, SchemeDigest);

  { Credentials for a host (and the realm asked for); False if none. }
  TCredentialsProvider = function(const Host, Realm: string; out User, Password: string): Boolean of object;

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
    FProvider: TCredentialsProvider;
    FServers: array of TServerAuthentication;
    FLock: TRTLCriticalSection;
    function FindServer(const Key: string): Integer;
  public
    { HasUser: User and Password go to every server that asks. }
    constructor Create(const User, Password: string; HasUser: Boolean; Provider: TCredentialsProvider = nil);
    destructor Destroy; override;
    { The credentials for a host; False if there are none. }
    function CredentialsFor(const Host, Realm: string; out User, Password: string): Boolean;
    { The Authorization value for a request ('' while the server has not
      asked for any). Target is the request target (path and query). }
    function AuthorizationFor(constref Url: TUrlRecord; const Method: string): string;
    { Reads the WWW-Authenticate values of a 401 and remembers how to
      answer. False when there are no credentials or no challenge that
      can be answered. Stale says the server only wants a new nonce. }
    function AcceptChallenges(constref Url: TUrlRecord; const Values: array of string; out Stale: Boolean): Boolean;
    { Forgets what a server asked for (its credentials were refused). }
    procedure Forget(constref Url: TUrlRecord);
  end;

{ The request target of a URL: its path and query. }
function RequestTargetOf(constref Url: TUrlRecord): string;

implementation

uses
  SysUtils,
  Crypto.Digests,
  Crypto.Random,
  Http.Challenges;

const
  ClientNonceBytes = 16;

function RequestTargetOf(constref Url: TUrlRecord): string;
begin
  Result := Url.Path;
  if Result = '' then
    Result := '/';
  if Url.HasQuery then
    Result := Result + '?' + Url.Query;
end;

function ServerKey(constref Url: TUrlRecord): string;
begin
  Result := Url.Scheme + '://' + SerializeHost(Url.Host) + ':' + IntToStr(UrlEffectivePort(Url));
end;

function NewClientNonce: string;
var
  Bytes: array[0..ClientNonceBytes - 1] of Byte;
begin
  RandomBytes(@Bytes[0], SizeOf(Bytes));
  Result := HexText(@Bytes[0], SizeOf(Bytes));
end;

constructor TAuthenticator.Create(const User, Password: string; HasUser: Boolean; Provider: TCredentialsProvider);
begin
  inherited Create;
  FUser := User;
  FPassword := Password;
  FHasUser := HasUser;
  FProvider := Provider;
  InitCriticalSection(FLock);
end;

destructor TAuthenticator.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TAuthenticator.CredentialsFor(const Host, Realm: string; out User, Password: string): Boolean;
begin
  User := FUser;
  Password := FPassword;
  if FHasUser then
    Exit(True);
  Result := Assigned(FProvider) and FProvider(Host, Realm, User, Password);
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

function TAuthenticator.AuthorizationFor(constref Url: TUrlRecord; const Method: string): string;
var
  Index: Integer;
  Entry: TServerAuthentication;
begin
  Result := '';
  EnterCriticalSection(FLock);
  try
    Index := FindServer(ServerKey(Url));
    if Index < 0 then
      Exit;
    if FServers[Index].Scheme = SchemeDigest then
      Inc(FServers[Index].NonceCount);
    Entry := FServers[Index];
  finally
    LeaveCriticalSection(FLock);
  end;
  case Entry.Scheme of
    SchemeBasic:
      Result := BasicAuthorization(Entry.User, Entry.Password);
    SchemeDigest:
      Result := DigestAuthorization(Entry.Digest, Entry.User, Entry.Password, Method, RequestTargetOf(Url),
        NewClientNonce, Entry.NonceCount);
  end;
end;

{ The best challenge: Digest SHA-256, then Digest MD5, then Basic. }
function ChooseChallenge(const Challenges: TChallengeArray; out Scheme: TAuthenticationScheme;
  out Digest: TDigestChallenge; out Realm: string): Boolean;
var
  Challenge: TChallenge;
  Candidate: TDigestChallenge;
  HasDigest, HasBasic: Boolean;
  BasicRealm: string;
begin
  Scheme := SchemeNone;
  Digest := Default(TDigestChallenge);
  Realm := '';
  BasicRealm := '';
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
    begin
      HasBasic := True;
      BasicRealm := ChallengeParameter(Challenge, 'realm');
    end;
  end;
  if HasDigest then
  begin
    Scheme := SchemeDigest;
    Realm := Digest.Realm;
  end
  else if HasBasic then
  begin
    Scheme := SchemeBasic;
    Realm := BasicRealm;
  end;
  Result := Scheme <> SchemeNone;
end;

function TAuthenticator.AcceptChallenges(constref Url: TUrlRecord; const Values: array of string;
  out Stale: Boolean): Boolean;
var
  Challenges: TChallengeArray;
  Value, Realm: string;
  Entry: TServerAuthentication;
  Index: Integer;
begin
  Stale := False;
  Challenges := nil;
  for Value in Values do
    ParseChallenges(Value, Challenges);
  Entry := Default(TServerAuthentication);
  Entry.Key := ServerKey(Url);
  Result := ChooseChallenge(Challenges, Entry.Scheme, Entry.Digest, Realm) and
    CredentialsFor(SerializeHost(Url.Host), Realm, Entry.User, Entry.Password);
  if not Result then
    Exit;
  Stale := (Entry.Scheme = SchemeDigest) and Entry.Digest.Stale;
  EnterCriticalSection(FLock);
  try
    Index := FindServer(Entry.Key);
    if Index < 0 then
    begin
      SetLength(FServers, Length(FServers) + 1);
      Index := High(FServers);
    end;
    FServers[Index] := Entry;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TAuthenticator.Forget(constref Url: TUrlRecord);
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  Index := FindServer(ServerKey(Url));
  if Index >= 0 then
    Delete(FServers, Index, 1);
  LeaveCriticalSection(FLock);
end;

end.
