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
  WgetTest - checks wget's plain logic on the host (make wget-test):
  parsing and resolving URLs (RFC 3986's examples among them), file
  names, response heads, Content-Range, and the chunked coding fed in
  pieces of every size; cookies (WgetTest.Cookies), authentication
  (WgetTest.Authentication) and what recursion is made of
  (WgetTest.Recursion).
}
program WgetTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  WgetTest.Authentication,
  WgetTest.Cookies,
  WgetTest.Recursion,
  Http.Chunks,
  Http.ResponseHeads,
  Wget.Urls;

function UrlText(constref Url: TUrl): string;
begin
  Result := FormatUrl(Url);
end;

procedure CheckParse(const Text, Expected: string);
var
  Url: TUrl;
begin
  if Expected = '' then
    Check(not ParseUrl(Text, Url), 'URL refused: ' + Text)
  else
    Check(ParseUrl(Text, Url) and (UrlText(Url) = Expected), 'URL ' + Text + ' -> ' + Expected);
end;

procedure CheckResolve(const Base, Reference, Expected: string);
var
  BaseUrl, Resolved: TUrl;
  Worked: Boolean;
begin
  ParseUrl(Base, BaseUrl);
  Worked := ResolveUrl(BaseUrl, Reference, Resolved);
  if Expected = '' then
    Check(not Worked, 'resolve refused: ' + Reference)
  else
  begin
    Check(Worked and (UrlText(Resolved) = Expected), 'resolve ' + Reference + ' -> ' + Expected);
    if Worked and (UrlText(Resolved) <> Expected) then
      WriteLn('     got ', UrlText(Resolved));
  end;
end;

procedure CheckFileName(const Text, Expected: string);
var
  Url: TUrl;
begin
  ParseUrl(Text, Url);
  Check(DefaultFileName(Url) = Expected, 'file name of ' + Text + ' is ' + Expected);
end;

procedure TestUrls;
var
  Url: TUrl;
begin
  CheckParse('http://example.com', 'http://example.com/');
  CheckParse('example.com/a/b', 'http://example.com/a/b');
  CheckParse('HTTPS://Example.COM:443/x?y=1#frag', 'https://example.com/x?y=1');
  CheckParse('https://10.0.2.101:8443/file.txt', 'https://10.0.2.101:8443/file.txt');
  CheckParse('http://host:80/', 'http://host/');
  CheckParse('http://host?q', 'http://host/?q');
  CheckParse('http://host/a b', 'http://host/a%20b');
  CheckParse('ftp://example.com/', '');
  CheckParse('http://user@example.com/', '');
  CheckParse('http://[::1]/', 'http://[::1]/');
  CheckParse('http://[FEC0::2]:8080/x', 'http://[fec0::2]:8080/x');
  CheckParse('http://[::1', '');
  CheckParse('http://[::1]x/', '');
  CheckParse('http://[fe80::1%25eth0]/', '');
  CheckParse('http://host:0/', '');
  CheckParse('http://host:65536/', '');
  CheckParse('http://:80/', '');
  CheckParse('', '');
  ParseUrl('http://example.com:8080/x', Url);
  Check(FormatHostHeader(Url) = 'example.com:8080', 'Host header with a port');
  Check(Url.Port = 8080, 'port 8080');
  ParseUrl('http://[::1]:8080/x', Url);
  Check((FormatHostHeader(Url) = '[::1]:8080') and (Url.Host = '::1'),
    'an IPv6 host: no brackets in Host, brackets in the Host header');

  { RFC 3986 section 5.4.1, base http://a/b/c/d;p?q }
  CheckResolve('http://a/b/c/d;p?q', 'g', 'http://a/b/c/g');
  CheckResolve('http://a/b/c/d;p?q', './g', 'http://a/b/c/g');
  CheckResolve('http://a/b/c/d;p?q', 'g/', 'http://a/b/c/g/');
  CheckResolve('http://a/b/c/d;p?q', '/g', 'http://a/g');
  CheckResolve('http://a/b/c/d;p?q', '//g', 'http://g/');
  CheckResolve('http://a/b/c/d;p?q', '?y', 'http://a/b/c/d;p?y');
  CheckResolve('http://a/b/c/d;p?q', 'g?y', 'http://a/b/c/g?y');
  CheckResolve('http://a/b/c/d;p?q', 'g#s', 'http://a/b/c/g');
  CheckResolve('http://a/b/c/d;p?q', '.', 'http://a/b/c/');
  CheckResolve('http://a/b/c/d;p?q', './', 'http://a/b/c/');
  CheckResolve('http://a/b/c/d;p?q', '..', 'http://a/b/');
  CheckResolve('http://a/b/c/d;p?q', '../', 'http://a/b/');
  CheckResolve('http://a/b/c/d;p?q', '../g', 'http://a/b/g');
  CheckResolve('http://a/b/c/d;p?q', '../..', 'http://a/');
  CheckResolve('http://a/b/c/d;p?q', '../../g', 'http://a/g');
  CheckResolve('http://a/b/c/d;p?q', '../../../g', 'http://a/g');
  CheckResolve('https://a/b/c', '//other/x', 'https://other/x');
  CheckResolve('https://a/b/c', 'http://plain/x', 'http://plain/x');
  CheckResolve('https://a/b/c', 'ftp://other/x', '');
  CheckResolve('https://a/b/c', 'javascript:alert(1)', '');

  CheckFileName('http://example.com/', 'index.html');
  CheckFileName('http://example.com', 'index.html');
  CheckFileName('http://example.com/dir/', 'index.html');
  CheckFileName('http://example.com/dir/file.tar.gz', 'file.tar.gz');
  CheckFileName('http://example.com/file.txt?version=2', 'file.txt');
  CheckFileName('http://example.com/a%20b.txt', 'a b.txt');
  CheckFileName('http://example.com/a%2Fb', 'a%2Fb');
  CheckFileName('http://example.com/..', 'index.html');
end;

function Parse(const Head: string; out Response: THttpResponseHead): THeadParseResult;
begin
  Result := ParseResponseHead(Head, Response);
end;

procedure TestHeads;
var
  Response: THttpResponseHead;
  Head: string;
  First, Last, Total: Int64;
begin
  Head := 'HTTP/1.1 200 OK'#13#10'Content-Length: 1234'#13#10'Content-Type: text/html'#13#10 +
    'Connection: close'#13#10#13#10'body';
  Check(FindHeadEnd(PChar(Head), Length(Head)) = Length(Head) - 4, 'head: its end found');
  Check(FindHeadEnd(PChar(Head), 20) = 0, 'head: not ended yet');
  Check(Parse(Copy(Head, 1, Length(Head) - 4), Response) = HeadParsed, 'head: parsed');
  Check((Response.StatusCode = 200) and (Response.Reason = 'OK'), 'head: 200 OK');
  Check(Response.ContentLength = 1234, 'head: Content-Length');
  Check(Response.ContentType = 'text/html', 'head: Content-Type');
  Check(Response.ConnectionClose, 'head: Connection: close');

  Check(Parse('HTTP/1.1 301 Moved Permanently'#10'location:  /new/place '#10#10, Response) = HeadParsed,
    'head: bare LF lines');
  Check(Response.HasLocation and (Response.Location = '/new/place'), 'head: Location trimmed');
  Check(StatusIsRedirect(Response.StatusCode), 'head: 301 is a redirect');

  Check((Parse('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10'Content-Length: 5'#13#10#13#10,
    Response) = HeadParsed) and Response.Chunked and (Response.ContentLength = -1),
    'head: chunked wins over Content-Length');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: gzip, chunked'#13#10#13#10, Response) =
    HeadUnsupportedCoding, 'head: gzip refused');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10'Content-Length: 6'#13#10#13#10, Response) =
    HeadMalformed, 'head: two different lengths refused');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10'Content-Length: 5'#13#10#13#10, Response) =
    HeadParsed, 'head: the same length twice is fine');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Content-Length: -5'#13#10#13#10, Response) = HeadMalformed,
    'head: negative length refused');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Content-Length: 12x'#13#10#13#10, Response) = HeadMalformed,
    'head: length with junk refused');
  Check(Parse('HTTP/2 200 OK'#13#10#13#10, Response) = HeadMalformed, 'head: HTTP/2 status line refused');
  Check(Parse('HTTP/1.1 2000 OK'#13#10#13#10, Response) = HeadMalformed, 'head: four digit status refused');
  Check(Parse('HTTP/1.1 200 OK'#13#10' folded: line'#13#10#13#10, Response) = HeadMalformed,
    'head: folded line refused');
  Check(Parse('HTTP/1.1 200 OK'#13#10'Bad Name: x'#13#10#13#10, Response) = HeadMalformed,
    'head: space in a field name refused');
  Check((Parse('HTTP/1.0 204'#13#10#13#10, Response) = HeadParsed) and StatusHasNoBody(Response.StatusCode),
    'head: 204 without a reason');
  Check((Parse('HTTP/1.1 206 Partial Content'#13#10'Content-Range: bytes 100-199/1000'#13#10#13#10,
    Response) = HeadParsed) and Response.HasContentRange and (Response.RangeStart = 100) and
    (Response.RangeEnd = 199) and (Response.RangeTotal = 1000), 'head: Content-Range');
  Check(ParseContentRange('bytes 0-0/*', First, Last, Total) and (Total = -1), 'range: unknown total');
  Check(not ParseContentRange('bytes 5-4/10', First, Last, Total), 'range: backwards refused');
  Check(not ParseContentRange('bytes 0-10/10', First, Last, Total), 'range: past the total refused');
  Check(not ParseContentRange('items 0-1/2', First, Last, Total), 'range: other units refused');

  Check(Parse('HTTP/1.1 401 Unauthorized'#13#10'WWW-Authenticate: Basic realm="a"'#13#10 +
    'Set-Cookie: a=1; Path=/'#13#10'www-authenticate: Digest realm="b", nonce="n"'#13#10 +
    'SET-COOKIE: b=2'#13#10#13#10, Response) = HeadParsed, 'head: repeated fields');
  Check((Length(Response.Challenges) = 2) and (Response.Challenges[1] = 'Digest realm="b", nonce="n"'),
    'head: each WWW-Authenticate kept');
  Check((Length(Response.SetCookies) = 2) and (Response.SetCookies[0] = 'a=1; Path=/') and
    (Response.SetCookies[1] = 'b=2'), 'head: each Set-Cookie kept');
  Check((Parse('HTTP/1.1 200 OK'#13#10'Content-Encoding: GZIP'#13#10#13#10, Response) = HeadParsed) and
    (Response.ContentEncoding = 'gzip'), 'head: Content-Encoding, lower case');
  Check((Parse('HTTP/1.1 200 OK'#13#10'Content-Encoding: identity'#13#10#13#10, Response) = HeadParsed) and
    (Response.ContentEncoding = ''), 'head: identity is no encoding');
  Check((Parse('HTTP/1.1 200 OK'#13#10#13#10, Response) = HeadParsed) and ConnectionPersists(Response),
    'head: HTTP/1.1 persists');
  Check((Parse('HTTP/1.1 200 OK'#13#10'Connection: Upgrade, close'#13#10#13#10, Response) = HeadParsed) and
    not ConnectionPersists(Response), 'head: close in a list');
  Check((Parse('HTTP/1.0 200 OK'#13#10#13#10, Response) = HeadParsed) and not ConnectionPersists(Response),
    'head: HTTP/1.0 closes');
  Check((Parse('HTTP/1.0 200 OK'#13#10'Connection: Keep-Alive'#13#10#13#10, Response) = HeadParsed) and
    ConnectionPersists(Response), 'head: HTTP/1.0 with keep-alive persists');
end;

{ Decodes Encoded in pieces of PieceSize; the data, or 'FAIL'. }
function DecodeInPieces(const Encoded: string; PieceSize: Integer; out Finished: Boolean): string;
var
  Decoder: TChunkDecoder;
  Output: array[0..4095] of Byte;
  OutputLength, Consumed: PtrUInt;
  Position, Take: Integer;
  Text: string;
begin
  Result := '';
  BeginChunkDecoder(Decoder);
  Position := 1;
  while (Position <= Length(Encoded)) and not ChunkDecoderFinished(Decoder) do
  begin
    Take := PieceSize;
    if Position + Take - 1 > Length(Encoded) then
      Take := Length(Encoded) - Position + 1;
    while Take > 0 do
    begin
      if not DecodeChunks(Decoder, PByte(@Encoded[Position]), Take, @Output[0], OutputLength, Consumed) then
        Exit('FAIL');
      SetString(Text, PChar(@Output[0]), OutputLength);
      Result := Result + Text;
      Position := Position + Integer(Consumed);
      Take := Take - Integer(Consumed);
      if ChunkDecoderFinished(Decoder) then
        Break;
    end;
  end;
  Finished := ChunkDecoderFinished(Decoder);
end;

procedure TestChunks;
const
  Encoded = '4'#13#10'Wiki'#13#10'5;name=value'#13#10'pedia'#13#10'E'#13#10' in'#13#10#13#10'chunks.'#13#10 +
    '0'#13#10'Trailer: x'#13#10#13#10;
var
  PieceSize: Integer;
  AllGood: Boolean;
  Finished: Boolean;
  Decoded: string;
begin
  AllGood := True;
  for PieceSize := 1 to Length(Encoded) do
  begin
    Decoded := DecodeInPieces(Encoded + 'NEXT', PieceSize, Finished);
    if (Decoded <> 'Wikipedia in'#13#10#13#10'chunks.') or not Finished then
      AllGood := False;
  end;
  Check(AllGood, 'chunks: decoded in pieces of every size, trailers skipped, nothing past the end');
  Check(DecodeInPieces('3'#10'abc'#10'0'#10#10, 2, Finished) = 'abc', 'chunks: bare LF');
  Check(Finished, 'chunks: bare LF ends');
  Check(DecodeInPieces('zz'#13#10, 3, Finished) = 'FAIL', 'chunks: bad size refused');
  Check(DecodeInPieces('3'#13#10'abcX'#13#10, 3, Finished) = 'FAIL', 'chunks: missing CRLF after data refused');
  Check(DecodeInPieces('1000000000000000'#13#10, 64, Finished) = 'FAIL', 'chunks: 16 digit size refused');
  Decoded := DecodeInPieces('5'#13#10'ab', 64, Finished);
  Check((Decoded = 'ab') and not Finished, 'chunks: a body cut short is not finished');
end;

begin
  TestUrls;
  TestHeads;
  TestChunks;
  TestCookies;
  TestAuthentication;
  TestRecursion;
  FinishChecks('wget test');
end.
