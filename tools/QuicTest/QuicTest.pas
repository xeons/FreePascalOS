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
  libquic on the host (make quic-test): RFC 9001's packet protection
  vectors, variable-length integers, frames, transport parameters,
  QPACK (RFC 9204 appendix B) and HPACK's Huffman code, HTTP/3 frames,
  and whole connections over UDP on the loopback addresses between the
  client and a small server made for the test; then libhttp's client
  finding that server by Alt-Svc and fetching from it over HTTP/3, and
  falling back to TCP when it cannot.

    QuicTest            every check
    QuicTest serve PORT run the test's HTTP/3 server on 127.0.0.1:PORT
                        (for curl --http3-only; ends after one
                        connection)
}
program QuicTest;

{$mode objfpc}
{$H+}

uses
  cthreads,
  SysUtils,
  TestChecks,
  QuicTest.Protection,
  QuicTest.Framing,
  QuicTest.Qpack,
  QuicTest.Loopback,
  QuicTest.Http3,
  QuicTest.HttpClient,
  QuicTest.Http3Server,
  QuicTest.Server;

{ One connection to the test's HTTP/3 server on 127.0.0.1:Port. }
procedure Serve(Port: Word);
var
  Server: TTestServer;
begin
  Server := TTestServer.Create(False, ServeHttp3, Port);
  InstallHttp3Server(Server);
  Server.Patience := 20000;
  Server.Start;
  Server.WaitFor;
  if Server.Failure <> '' then
    WriteLn('server: ', Server.Failure)
  else
    WriteLn('server: ', Server.StreamsServed, ' requests served, closed with 0x',
      IntToHex(Server.PeerCloseCode, 1));
  Server.Free;
end;

begin
  if ParamStr(1) = 'serve' then
  begin
    Serve(StrToInt(ParamStr(2)));
    Exit;
  end;
  RunProtectionTests;
  RunFramingTests;
  RunQpackTests;
  RunLoopbackTests;
  RunHttp3Tests;
  RunHttpClientTests;
  FinishChecks('QUIC TEST');
end.
