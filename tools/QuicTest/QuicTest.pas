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
  client and a small server made for the test.

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
  QuicTest.Loopback;

begin
  RunProtectionTests;
  RunFramingTests;
  RunLoopbackTests;
  FinishChecks('QUIC TEST');
end.
