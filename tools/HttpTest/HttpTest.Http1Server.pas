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
  A small HTTP/1.1 server for the loopback test, in a thread, on one
  pipe transport, answering requests one after another until the
  client closes or asks to:

    /hello         "hello" with Content-Length (HEAD: the head only)
    /chunked       "Wikipedia" chunked, with a trailer
    /until-close   an HTTP/1.0 body that ends with the connection
    /interim       a 100 Continue, then "ok"
    /echo          the request's content back (Content-Length or chunked)
    /count         how many requests this connection carried
    /redirect      302 to /hello; /see-other 303 to /hello; /keep 307 to /echo
    /gzip          gzip coded text; /deflate zlib coded; /br brotli
                   coded; /zstd Zstandard coded
    /cookie        sets a cookie; /cookie-show the Cookie sent
    /cache         Cache-Control max-age=60 with an ETag; a matching
                   If-None-Match gets 304
    /auth          Basic authentication (user, secret)
    /alt-svc       an Alt-Svc field
    /close-after   a response that says nothing of closing, then the
                   connection closed (a kept connection gone stale)
}
unit HttpTest.Http1Server;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Http.Transports;

type
  THttp1TestServer = class(TThread)
  private
    FTransport: THttpTransport;
    FPending: string;
    FRequests: Integer;
    function Fill: Boolean;
    function ReadHead(out Head: string): Boolean;
    function ReadBody(const Head: string; out Body: string): Boolean;
    procedure Reply(const Text: string);
    function Serve(const Head, Body: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Transport: THttpTransport);
  end;

function HeadField(const Head, Name: string): string;

implementation

uses
  StrUtils,
  TestChecks;

const
  GzipHex = '1f8b08000000000002ffcb48cdc9c957c84027b9000088590b18000000';
  DeflateHex = '789c4b494dcb492c494d512849ad28e1020028c70529';
  BrotliHex = '1f1700f8057463fd253de78341100459b014012a16e8dc326dea3101';
  ZstdHex = '28b52ffd0468b50000807a7374616e646172642074657874200a010022cf3ab6122d9f';

function HeadField(const Head, Name: string): string;
var
  Line: string;
  Colon: Integer;
begin
  Result := '';
  for Line in Head.Split([#13#10]) do
  begin
    Colon := Pos(':', Line);
    if (Colon > 0) and SameText(Trim(Copy(Line, 1, Colon - 1)), Name) then
      Exit(Trim(Copy(Line, Colon + 1, MaxInt)));
  end;
end;

function BytesText(const Hex: string): string;
var
  Bytes: TByteArray;
begin
  Bytes := HexToBytes(Hex);
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

constructor THttp1TestServer.Create(Transport: THttpTransport);
begin
  FTransport := Transport;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function THttp1TestServer.Fill: Boolean;
var
  Buffer: array[0..4095] of Char;
  Count: Int64;
  Text: string;
begin
  Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
  if Count <= 0 then
    Exit(False);
  SetString(Text, PChar(@Buffer[0]), Count);
  FPending := FPending + Text;
  Result := True;
end;

function THttp1TestServer.ReadHead(out Head: string): Boolean;
var
  Ending: Integer;
begin
  Head := '';
  repeat
    Ending := Pos(#13#10#13#10, FPending);
    if Ending > 0 then
      Break;
    if not Fill then
      Exit(False);
  until False;
  Head := Copy(FPending, 1, Ending + 1);
  Delete(FPending, 1, Ending + 3);
  Result := True;
end;

function THttp1TestServer.ReadBody(const Head: string; out Body: string): Boolean;
var
  Length_: Integer;
  LineEnd, Size: Integer;
begin
  Body := '';
  if HeadField(Head, 'Content-Length') <> '' then
  begin
    Length_ := StrToInt(HeadField(Head, 'Content-Length'));
    while Length(FPending) < Length_ do
      if not Fill then
        Exit(False);
    Body := Copy(FPending, 1, Length_);
    Delete(FPending, 1, Length_);
  end
  else if SameText(HeadField(Head, 'Transfer-Encoding'), 'chunked') then
    repeat
      while Pos(#13#10, FPending) = 0 do
        if not Fill then
          Exit(False);
      LineEnd := Pos(#13#10, FPending);
      Size := Hex2Dec(Copy(FPending, 1, LineEnd - 1));
      while Length(FPending) < LineEnd + 1 + Size + 2 do
        if not Fill then
          Exit(False);
      Body := Body + Copy(FPending, LineEnd + 2, Size);
      Delete(FPending, 1, LineEnd + 1 + Size + 2);
    until Size = 0;
  Result := True;
end;

procedure THttp1TestServer.Reply(const Text: string);
begin
  FTransport.Write(PChar(Text), Length(Text));
end;

procedure Response(Server: THttp1TestServer; const Status, Fields, Body: string);
begin
  Server.Reply('HTTP/1.1 ' + Status + #13#10 + Fields + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 +
    Body);
end;

function THttp1TestServer.Serve(const Head, Body: string): Boolean;
var
  RequestLine, Method, Path: string;
  Parts: TStringArray;
begin
  Result := True;
  Inc(FRequests);
  RequestLine := Copy(Head, 1, Pos(#13#10, Head) - 1);
  Parts := RequestLine.Split([' ']);
  Method := Parts[0];
  Path := Parts[1];
  if Path = '/hello' then
  begin
    if Method = 'HEAD' then
      Reply('HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10)
    else
      Response(Self, '200 OK', 'Content-Type: text/plain'#13#10, 'hello');
  end
  else if Path = '/chunked' then
    Reply('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10'4'#13#10'Wiki'#13#10'5;x=y'#13#10'pedia'#13#10 +
      '0'#13#10'X-Trailer: yes'#13#10#13#10)
  else if Path = '/until-close' then
  begin
    Reply('HTTP/1.0 200 OK'#13#10#13#10'all of it');
    Exit(False);
  end
  else if Path = '/close-after' then
  begin
    Response(Self, '200 OK', '', 'closing when idle');
    Exit(False);
  end
  else if Path = '/interim' then
    Reply('HTTP/1.1 100 Continue'#13#10#13#10'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok')
  else if Path = '/echo' then
    Response(Self, '200 OK', '', Method + ' ' + Body)
  else if Path = '/count' then
    Response(Self, '200 OK', '', IntToStr(FRequests))
  else if Path = '/redirect' then
    Response(Self, '302 Found', 'Location: /hello'#13#10, '')
  else if Path = '/see-other' then
    Response(Self, '303 See Other', 'Location: /echo'#13#10, '')
  else if Path = '/keep' then
    Response(Self, '307 Temporary Redirect', 'Location: /echo'#13#10, '')
  else if Path = '/loop' then
    Response(Self, '302 Found', 'Location: /loop'#13#10, '')
  else if Path = '/gzip' then
    Response(Self, '200 OK', 'Content-Encoding: gzip'#13#10, BytesText(GzipHex))
  else if Path = '/deflate' then
    Response(Self, '200 OK', 'Content-Encoding: deflate'#13#10, BytesText(DeflateHex))
  else if Path = '/br' then
    Response(Self, '200 OK', 'Content-Encoding: br'#13#10, BytesText(BrotliHex))
  else if Path = '/zstd' then
    Response(Self, '200 OK', 'Content-Encoding: zstd'#13#10, BytesText(ZstdHex))
  else if Path = '/cookie' then
    Response(Self, '200 OK', 'Set-Cookie: id=42; Path=/; SameSite=Lax'#13#10 +
      'Set-Cookie: __Host-bad=1; Path=/; Domain=example.com'#13#10, 'set')
  else if Path = '/cookie-show' then
    Response(Self, '200 OK', '', HeadField(Head, 'Cookie'))
  else if Path = '/cache' then
  begin
    if HeadField(Head, 'If-None-Match') = '"v1"' then
      Reply('HTTP/1.1 304 Not Modified'#13#10'ETag: "v1"'#13#10'Cache-Control: max-age=60'#13#10#13#10)
    else
      Response(Self, '200 OK', 'ETag: "v1"'#13#10'Cache-Control: max-age=60'#13#10, 'cached ' + IntToStr(FRequests));
  end
  else if Path = '/stale' then
  begin
    if HeadField(Head, 'If-None-Match') = '"s1"' then
      Reply('HTTP/1.1 304 Not Modified'#13#10'ETag: "s1"'#13#10'Cache-Control: no-cache'#13#10#13#10)
    else
      Response(Self, '200 OK', 'ETag: "s1"'#13#10'Cache-Control: no-cache'#13#10, 'revalidated body');
  end
  else if Path = '/auth' then
  begin
    if HeadField(Head, 'Authorization') = 'Basic dXNlcjpzZWNyZXQ=' then
      Response(Self, '200 OK', '', 'welcome')
    else
      Response(Self, '401 Unauthorized', 'WWW-Authenticate: Basic realm="test"'#13#10, 'who?');
  end
  else if Path = '/alt-svc' then
    Response(Self, '200 OK', 'Alt-Svc: h3=":8443"; ma=3600, h2="alt.example:443"'#13#10, 'alt')
  else
    Response(Self, '404 Not Found', '', 'not found');
  if SameText(HeadField(Head, 'Connection'), 'close') then
    Result := False;
end;

procedure THttp1TestServer.Execute;
var
  Head, Body: string;
begin
  while ReadHead(Head) do
  begin
    if not ReadBody(Head, Body) then
      Break;
    if not Serve(Head, Body) then
      Break;
  end;
  FTransport.Close;
end;

end.
