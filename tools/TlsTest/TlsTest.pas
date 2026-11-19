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
  TlsTest - checks libtls on the host (make tls-test).

    TlsTest CERTIFICATE-DIRECTORY CA-BUNDLE
        DER, host names, the test certificates and their chains, the
        Mozilla bundle, the TLS 1.3 handshake of RFC 8448 through the
        key schedule, transcript, records and Finished messages, and
        HelloRetryRequest (RFC 8448's transcript, and the client against
        a scripted server).
    TlsTest --connect PORT SERVER-NAME TRUST-FILE [CIPHER-SUITE] [--no-verify]
        A whole connection to a server on 127.0.0.1 (run-interop.sh
        runs it against OpenSSL).
}
program TlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  TlsTest.Certificates,
  TlsTest.Interop,
  TlsTest.KeySchedule,
  TlsTest.Resumption,
  TlsTest.Retry;

var
  CipherName: string;
  VerifyCertificates: Boolean;
  Index: Integer;
begin
  if (ParamCount >= 4) and (ParamStr(1) = '--connect') then
  begin
    CipherName := '';
    VerifyCertificates := True;
    for Index := 5 to ParamCount do
      if ParamStr(Index) = '--no-verify' then
        VerifyCertificates := False
      else
        CipherName := ParamStr(Index);
    Halt(RunInteropClient(StrToInt(ParamStr(2)), ParamStr(3), ParamStr(4), CipherName, VerifyCertificates));
  end;
  if ParamCount < 2 then
  begin
    WriteLn('usage: TlsTest CERTIFICATE-DIRECTORY CA-BUNDLE');
    Halt(2);
  end;
  TestAsn1;
  TestHostNameRules;
  TestRfc8448Handshake;
  TestRetryTranscript;
  TestRetryExchange;
  TestRfc8448Resumption;
  TestSessionCache;
  TestTestCertificates(ParamStr(1));
  TestMozillaBundle(ParamStr(2));
  FinishChecks('tls test');
end.
