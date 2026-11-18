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
  SshTest - checks libssh on the host (make ssh-test): the data types,
  the packet framing of each cipher, known answers worked out with
  Python and OpenSSL (SshTest.Vectors.inc, made by make-vectors.py),
  and the server's layers against a small client in memory. Prints one
  line per check and the totals; exits with 1 if any failed.
}
program SshTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  SshTest.KnownAnswers,
  SshTest.Framing,
  SshTest.Handshake,
  SshTest.TerminalOutput;

begin
  TestWireEncoding;
  TestCipherVectors;
  TestKeyExchangeVectors;
  TestHostKeyVectors;
  TestPublicKeyVectors;
  TestPacketFraming;
  TestHandshake;
  TestTerminalOutput;
  FinishChecks('ssh test');
end.
