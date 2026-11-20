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
  HTTP authentication's answers: Basic (RFC 7617, user:password in
  base64) and Digest (RFC 7616).

  Digest with MD5, MD5-sess, SHA-256 and SHA-256-sess, qop "auth" (or
  none, RFC 2069's form, for servers that offer no qop), and userhash.
  SHA-512-256 and qop "auth-int" are not offered, so a challenge that
  only has them cannot be answered.

    HA1 = H(user ":" realm ":" password)       (-sess: H(HA1 ":" nonce ":" cnonce))
    HA2 = H(method ":" uri)
    response = H(HA1 ":" nonce ":" nc ":" cnonce ":" qop ":" HA2)
             (no qop: H(HA1 ":" nonce ":" HA2))

  The client nonce and the count are given by the caller, so the host
  test can check RFC 7616's and RFC 2617's examples.

  Plain Pascal (with libcryptography's digests), checked on the host by
  tools/WgetTest.
}
unit Http.Digest;

{$mode objfpc}
{$H+}

interface

uses
  Http.Challenges;

type
  TDigestHash = (DigestHashMd5, DigestHashSha256);

  { What a Digest challenge asked for, as far as wget answers it. }
  TDigestChallenge = record
    Realm: string;
    Nonce: string;
    Opaque: string;
    HasOpaque: Boolean;
    Hash: TDigestHash;
    Session: Boolean;
    { "MD5", "SHA-256-sess"... as the server wrote it ('' if it wrote none). }
    AlgorithmName: string;
    { qop "auth" offered; without any qop the old form is used. }
    UseQop: Boolean;
    UserHash: Boolean;
    Stale: Boolean;
  end;

{ "Basic " + base64(user ":" password). }
function BasicAuthorization(const User, Password: string): string;
function Base64Encode(const Data: string): string;
{ Reads a Digest challenge; False when it cannot be answered (an
  unknown algorithm, only auth-int, no nonce). }
function ReadDigestChallenge(constref Challenge: TChallenge; out Digest: TDigestChallenge): Boolean;
{ Lower case hexadecimal of the hash of Text. }
function HashText(Hash: TDigestHash; const Text: string): string;
{ The response value. Count is the nonce count (nc), 1 for the first
  request with a nonce. }
function DigestResponse(constref Digest: TDigestChallenge; const User, Password, Method, Uri, ClientNonce: string;
  Count: LongWord): string;
{ The whole Authorization value ("Digest username=..., response=..."). }
function DigestAuthorization(constref Digest: TDigestChallenge; const User, Password, Method, Uri,
  ClientNonce: string; Count: LongWord): string;
{ nc as eight hexadecimal digits ("00000001"). }
function NonceCountText(Count: LongWord): string;

implementation

uses
  SysUtils,
  Crypto.Digests;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Encode(const Data: string): string;
var
  Index: Integer;
  Group: LongWord;
  Remaining: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Data) do
  begin
    Remaining := Length(Data) - Index + 1;
    Group := LongWord(Ord(Data[Index])) shl 16;
    if Remaining > 1 then
      Group := Group or (LongWord(Ord(Data[Index + 1])) shl 8);
    if Remaining > 2 then
      Group := Group or LongWord(Ord(Data[Index + 2]));
    Result := Result + Base64Alphabet[(Group shr 18) and 63 + 1] + Base64Alphabet[(Group shr 12) and 63 + 1];
    if Remaining > 1 then
      Result := Result + Base64Alphabet[(Group shr 6) and 63 + 1]
    else
      Result := Result + '=';
    if Remaining > 2 then
      Result := Result + Base64Alphabet[Group and 63 + 1]
    else
      Result := Result + '=';
    Inc(Index, 3);
  end;
end;

function BasicAuthorization(const User, Password: string): string;
begin
  Result := 'Basic ' + Base64Encode(User + ':' + Password);
end;

function HashText(Hash: TDigestHash; const Text: string): string;
var
  Algorithm: TDigestAlgorithm;
  Output: TDigestOutput;
begin
  if Hash = DigestHashSha256 then
    Algorithm := DigestSha256
  else
    Algorithm := DigestMd5;
  ComputeDigest(Algorithm, PByte(PChar(Text)), Length(Text), Output);
  Result := HexText(@Output[0], DigestSize(Algorithm));
end;

{ "auth" among the comma separated qop options. }
function OffersAuth(const Options: string): Boolean;
var
  Option: string;
begin
  for Option in Options.Split([',']) do
    if SameText(Trim(Option), 'auth') then
      Exit(True);
  Result := False;
end;

function ReadDigestChallenge(constref Challenge: TChallenge; out Digest: TDigestChallenge): Boolean;
var
  Algorithm: string;
  Qop: string;
begin
  Digest := Default(TDigestChallenge);
  Result := False;
  if not SameText(Challenge.Scheme, 'digest') then
    Exit;
  Digest.Realm := ChallengeParameter(Challenge, 'realm');
  Digest.Nonce := ChallengeParameter(Challenge, 'nonce');
  Digest.Opaque := ChallengeParameter(Challenge, 'opaque');
  Digest.HasOpaque := ChallengeHasParameter(Challenge, 'opaque');
  Digest.Stale := SameText(ChallengeParameter(Challenge, 'stale'), 'true');
  Digest.UserHash := SameText(ChallengeParameter(Challenge, 'userhash'), 'true');
  if Digest.Nonce = '' then
    Exit;
  Algorithm := ChallengeParameter(Challenge, 'algorithm');
  Digest.AlgorithmName := Algorithm;
  if (Algorithm = '') or SameText(Algorithm, 'MD5') then
    Digest.Hash := DigestHashMd5
  else if SameText(Algorithm, 'MD5-sess') then
  begin
    Digest.Hash := DigestHashMd5;
    Digest.Session := True;
  end
  else if SameText(Algorithm, 'SHA-256') then
    Digest.Hash := DigestHashSha256
  else if SameText(Algorithm, 'SHA-256-sess') then
  begin
    Digest.Hash := DigestHashSha256;
    Digest.Session := True;
  end
  else
    Exit;
  if ChallengeHasParameter(Challenge, 'qop') then
  begin
    Qop := ChallengeParameter(Challenge, 'qop');
    if not OffersAuth(Qop) then
      Exit;
    Digest.UseQop := True;
  end;
  Result := True;
end;

function NonceCountText(Count: LongWord): string;
begin
  Result := LowerCase(IntToHex(Count, 8));
end;

function DigestResponse(constref Digest: TDigestChallenge; const User, Password, Method, Uri, ClientNonce: string;
  Count: LongWord): string;
var
  FirstHash, SecondHash: string;
begin
  FirstHash := HashText(Digest.Hash, User + ':' + Digest.Realm + ':' + Password);
  if Digest.Session then
    FirstHash := HashText(Digest.Hash, FirstHash + ':' + Digest.Nonce + ':' + ClientNonce);
  SecondHash := HashText(Digest.Hash, Method + ':' + Uri);
  if Digest.UseQop then
    Result := HashText(Digest.Hash, FirstHash + ':' + Digest.Nonce + ':' + NonceCountText(Count) + ':' +
      ClientNonce + ':auth:' + SecondHash)
  else
    Result := HashText(Digest.Hash, FirstHash + ':' + Digest.Nonce + ':' + SecondHash);
end;

{ A quoted string, with " and \ escaped. }
function Quoted(const Text: string): string;
var
  Character: Char;
begin
  Result := '"';
  for Character in Text do
  begin
    if Character in ['"', '\'] then
      Result := Result + '\';
    Result := Result + Character;
  end;
  Result := Result + '"';
end;

function DigestAuthorization(constref Digest: TDigestChallenge; const User, Password, Method, Uri,
  ClientNonce: string; Count: LongWord): string;
var
  UserName: string;
begin
  UserName := User;
  if Digest.UserHash then
    UserName := HashText(Digest.Hash, User + ':' + Digest.Realm);
  Result := 'Digest username=' + Quoted(UserName) + ', realm=' + Quoted(Digest.Realm) + ', uri=' + Quoted(Uri);
  if Digest.AlgorithmName <> '' then
    Result := Result + ', algorithm=' + Digest.AlgorithmName;
  Result := Result + ', nonce=' + Quoted(Digest.Nonce);
  if Digest.UseQop then
    Result := Result + ', nc=' + NonceCountText(Count) + ', cnonce=' + Quoted(ClientNonce) + ', qop=auth';
  Result := Result + ', response=' + Quoted(DigestResponse(Digest, User, Password, Method, Uri, ClientNonce,
    Count));
  if Digest.HasOpaque then
    Result := Result + ', opaque=' + Quoted(Digest.Opaque);
  if Digest.UserHash then
    Result := Result + ', userhash=true';
end;

end.
