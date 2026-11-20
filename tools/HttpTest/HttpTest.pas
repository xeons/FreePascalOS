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
  HttpTest - checks libhttp on the host (make http-test):

    HttpTest                      the URL Standard, HPACK (RFC 7541
                                  appendix C), HTTP/2 frames, HTTP/1.1
                                  and HTTP/2 over pipes, the client
    HttpTest hpack-export FILE    blocks for libnghttp2 to decode
    HttpTest hpack-import FILE    libnghttp2's blocks decoded
    HttpTest interop PORT         against scripts/test-web-server.py
                                  (https-h2) on 127.0.0.1:PORT

  run-interop.sh runs the last three.
}
program HttpTest;

{$mode objfpc}
{$H+}

uses
  {$ifdef unix}
  cthreads,
  {$endif}
  SysUtils,
  TestChecks,
  HttpTest.Hpack,
  HttpTest.HpackExchange,
  HttpTest.Http2Frames,
  HttpTest.Interop,
  HttpTest.Loopback,
  HttpTest.Client,
  HttpTest.CookiesAndCache,
  HttpTest.Urls;

begin
  if ParamStr(1) = 'hpack-export' then
  begin
    ExportHpack(ParamStr(2));
    Exit;
  end;
  if ParamStr(1) = 'hpack-import' then
  begin
    ImportHpack(ParamStr(2));
    FinishChecks('http hpack interop');
    Exit;
  end;
  if ParamStr(1) = 'interop' then
  begin
    TestInterop(StrToInt(ParamStr(2)));
    FinishChecks('http interop');
    Exit;
  end;
  TestUrls;
  TestHpack;
  TestHttp2Frames;
  TestLoopback;
  TestClient;
  TestCookiesAndCache(ExtractFilePath(ParamStr(0)));
  FinishChecks('http test');
end.
