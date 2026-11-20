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
  wget's authentication on the host: WWW-Authenticate challenges, Basic
  (RFC 7617's example), Digest's responses against the examples of RFC
  7616 (MD5 and SHA-256) and RFC 2617, userhash, and .netrc.
}
unit WgetTest.Authentication;

{$mode objfpc}
{$H+}

interface

procedure TestAuthentication;

implementation

uses
  SysUtils,
  TestChecks,
  Http.Challenges,
  Http.Digest,
  Wget.Netrc;

const
  Rfc7616Nonce = '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v';
  Rfc7616Opaque = 'FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS';
  Rfc7616ClientNonce = 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ';

procedure TestChallenges;
var
  Challenges: TChallengeArray;
begin
  Challenges := nil;
  ParseChallenges('Basic realm="simple"', Challenges);
  Check((Length(Challenges) = 1) and (Challenges[0].Scheme = 'Basic') and
    (ChallengeParameter(Challenges[0], 'realm') = 'simple'), 'challenge: Basic with a realm');
  Challenges := nil;
  ParseChallenges('Digest realm="a, b", qop="auth, auth-int", nonce=abc123, Basic realm=x, Negotiate', Challenges);
  Check(Length(Challenges) = 3, 'challenge: three in one field');
  Check((Challenges[0].Scheme = 'Digest') and (ChallengeParameter(Challenges[0], 'REALM') = 'a, b') and
    (ChallengeParameter(Challenges[0], 'qop') = 'auth, auth-int') and
    (ChallengeParameter(Challenges[0], 'nonce') = 'abc123'), 'challenge: quoted commas and a bare token');
  Check((Challenges[1].Scheme = 'Basic') and (ChallengeParameter(Challenges[1], 'realm') = 'x'),
    'challenge: the second scheme');
  Check((Challenges[2].Scheme = 'Negotiate') and (Length(Challenges[2].Parameters) = 0),
    'challenge: a scheme alone');
  Challenges := nil;
  ParseChallenges('Digest realm="quote \" and \\ in it"', Challenges);
  Check(ChallengeParameter(Challenges[0], 'realm') = 'quote " and \ in it', 'challenge: escapes in quotes');
  Challenges := nil;
  ParseChallenges('Negotiate dGVzdA==, Basic realm="r"', Challenges);
  Check((Length(Challenges) = 2) and (ChallengeParameter(Challenges[0], '') = 'dGVzdA==') and
    (Challenges[1].Scheme = 'Basic'), 'challenge: a token68');
  Challenges := nil;
  ParseChallenges('Basic realm="one"', Challenges);
  ParseChallenges('Digest realm="two", nonce="n"', Challenges);
  Check(Length(Challenges) = 2, 'challenge: two fields add up');
end;

function Rfc7616Challenge(const Algorithm: string): TChallenge;
var
  Challenges: TChallengeArray;
begin
  Challenges := nil;
  ParseChallenges('Digest realm="http-auth@example.org", qop="auth, auth-int", algorithm=' + Algorithm +
    ', nonce="' + Rfc7616Nonce + '", opaque="' + Rfc7616Opaque + '"', Challenges);
  Result := Challenges[0];
end;

procedure TestDigest;
var
  Digest: TDigestChallenge;
  Challenges: TChallengeArray;
  Header: string;
begin
  Check(Base64Encode('') = '', 'base64: empty');
  Check(Base64Encode('f') = 'Zg==', 'base64: one byte');
  Check(Base64Encode('fo') = 'Zm8=', 'base64: two bytes');
  Check(Base64Encode('foobar') = 'Zm9vYmFy', 'base64: six bytes');
  Check(BasicAuthorization('Aladdin', 'open sesame') = 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
    'basic: RFC 7617''s example');
  Check(HashText(DigestHashMd5, '') = 'd41d8cd98f00b204e9800998ecf8427e', 'digest: MD5 of nothing');

  Check(ReadDigestChallenge(Rfc7616Challenge('MD5'), Digest) and (Digest.Hash = DigestHashMd5) and
    Digest.UseQop and not Digest.Session and Digest.HasOpaque, 'digest: RFC 7616''s MD5 challenge read');
  Check(DigestResponse(Digest, 'Mufasa', 'Circle of Life', 'GET', '/dir/index.html', Rfc7616ClientNonce, 1) =
    '8ca523f5e9506fed4657c9700eebdbec', 'digest: RFC 7616''s MD5 response');
  Header := DigestAuthorization(Digest, 'Mufasa', 'Circle of Life', 'GET', '/dir/index.html', Rfc7616ClientNonce, 1);
  Check(Header = 'Digest username="Mufasa", realm="http-auth@example.org", uri="/dir/index.html", ' +
    'algorithm=MD5, nonce="' + Rfc7616Nonce + '", nc=00000001, cnonce="' + Rfc7616ClientNonce +
    '", qop=auth, response="8ca523f5e9506fed4657c9700eebdbec", opaque="' + Rfc7616Opaque + '"',
    'digest: RFC 7616''s MD5 Authorization');

  Check(ReadDigestChallenge(Rfc7616Challenge('SHA-256'), Digest) and (Digest.Hash = DigestHashSha256),
    'digest: RFC 7616''s SHA-256 challenge read');
  Check(DigestResponse(Digest, 'Mufasa', 'Circle of Life', 'GET', '/dir/index.html', Rfc7616ClientNonce, 1) =
    '753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1', 'digest: RFC 7616''s SHA-256 response');

  Digest.UserHash := True;
  Header := DigestAuthorization(Digest, 'Mufasa', 'Circle of Life', 'GET', '/dir/index.html', Rfc7616ClientNonce, 1);
  Check(Pos('username="a947aad205e80e429958a387394944c6b496301e79f89d35a4cc23b6ee12b5b6"', Header) > 0,
    'digest: userhash sends the hashed name');
  Check(Pos('userhash=true', Header) > 0, 'digest: and says so');

  Challenges := nil;
  ParseChallenges('Digest realm="testrealm@host.com", qop="auth,auth-int", ' +
    'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"', Challenges);
  Check(ReadDigestChallenge(Challenges[0], Digest) and (Digest.AlgorithmName = ''),
    'digest: RFC 2617''s challenge (no algorithm: MD5)');
  Check(DigestResponse(Digest, 'Mufasa', 'Circle Of Life', 'GET', '/dir/index.html', '0a4f113b', 1) =
    '6629fae49393a05397450978507c4ef1', 'digest: RFC 2617''s response');
  Check(Pos(', algorithm=', DigestAuthorization(Digest, 'Mufasa', 'Circle Of Life', 'GET', '/dir/index.html',
    '0a4f113b', 1)) = 0, 'digest: no algorithm sent when none was given');
  Check(NonceCountText(255) = '000000ff', 'digest: the nonce count in hexadecimal');

  Challenges := nil;
  ParseChallenges('Digest realm="r", nonce="n"', Challenges);
  Check(ReadDigestChallenge(Challenges[0], Digest) and not Digest.UseQop, 'digest: without qop (RFC 2069)');
  Check(DigestResponse(Digest, 'u', 'p', 'GET', '/', 'c', 1) =
    HashText(DigestHashMd5, HashText(DigestHashMd5, 'u:r:p') + ':n:' + HashText(DigestHashMd5, 'GET:/')),
    'digest: the RFC 2069 response');

  Challenges := nil;
  ParseChallenges('Digest realm="r", nonce="n", qop="auth", algorithm=MD5-sess, stale=TRUE', Challenges);
  Check(ReadDigestChallenge(Challenges[0], Digest) and Digest.Session and Digest.Stale, 'digest: MD5-sess, stale');
  Check(DigestResponse(Digest, 'u', 'p', 'GET', '/', 'c', 2) =
    HashText(DigestHashMd5, HashText(DigestHashMd5, HashText(DigestHashMd5, 'u:r:p') + ':n:c') +
    ':n:00000002:c:auth:' + HashText(DigestHashMd5, 'GET:/')), 'digest: the -sess response');

  Challenges := nil;
  ParseChallenges('Digest realm="r", nonce="n", algorithm=SHA-512-256', Challenges);
  Check(not ReadDigestChallenge(Challenges[0], Digest), 'digest: SHA-512-256 cannot be answered');
  Challenges := nil;
  ParseChallenges('Digest realm="r", nonce="n", qop="auth-int"', Challenges);
  Check(not ReadDigestChallenge(Challenges[0], Digest), 'digest: auth-int alone cannot be answered');
  Challenges := nil;
  ParseChallenges('Digest realm="r"', Challenges);
  Check(not ReadDigestChallenge(Challenges[0], Digest), 'digest: no nonce cannot be answered');
end;

procedure TestNetrc;
const
  Text = 'machine example.com login alice password secret'#10 +
    'macdef init'#10 +
    'machine fake login nobody'#10 +
    #10 +
    'machine Other.Org'#10 +
    '  login bob'#10 +
    '  password "quoted"'#10 +
    'default login anonymous password me@example.com'#10;
var
  User, Password: string;
begin
  Check(FindNetrcCredentials(Text, 'example.com', User, Password) and (User = 'alice') and (Password = 'secret'),
    'netrc: a machine on one line');
  Check(FindNetrcCredentials(Text, 'other.org', User, Password) and (User = 'bob') and (Password = '"quoted"'),
    'netrc: over lines, the name without case');
  Check(FindNetrcCredentials(Text, 'elsewhere', User, Password) and (User = 'anonymous'),
    'netrc: the default for the rest');
  Check(not FindNetrcCredentials(Text, 'fake', User, Password) or (User = 'anonymous'),
    'netrc: a macro''s text is not an entry');
  Check(not FindNetrcCredentials('machine a login b password c', 'x', User, Password),
    'netrc: no entry, no default');
end;

procedure TestAuthentication;
begin
  TestChallenges;
  TestDigest;
  TestNetrc;
end;

end.
