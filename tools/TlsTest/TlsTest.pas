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

    TlsTest CERTIFICATE-DIRECTORY CA-BUNDLE FIXTURE-DIRECTORY
        DER, host names, the test certificates and their chains, the
        Mozilla bundle, the TLS 1.3 handshake of RFC 8448 through the
        key schedule, transcript, records and Finished messages, and
        HelloRetryRequest (RFC 8448's transcript, and the client against
        a scripted server), resumption (RFC 8448 sections 3 and 4) and
        the session cache, TLS 1.2 answers, and the fixtures
        make-fixtures.py made: name constraints, Ed25519 and P-521
        chains, OCSP responses, the TLS 1.2 PRF.
    TlsTest --connect PORT SERVER-NAME TRUST-FILE [CIPHER-SUITE] [--no-verify]
            [--tls1.2] [--groups=LIST] [--resume]
        A whole connection to a server on 127.0.0.1 (run-interop.sh
        runs it against OpenSSL); --resume connects twice, the second
        time resuming the first session.
}
program TlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  TlsTest.Certificates,
  TlsTest.Interop,
  TlsTest.Fixtures,
  TlsTest.KeySchedule,
  TlsTest.Resumption,
  TlsTest.Retry;

var
  Settings: TInteropSettings;
  Argument: string;
  Index: Integer;
begin
  if (ParamCount >= 4) and (ParamStr(1) = '--connect') then
  begin
    Settings := Default(TInteropSettings);
    Settings.Port := StrToInt(ParamStr(2));
    Settings.ServerName := ParamStr(3);
    Settings.TrustFile := ParamStr(4);
    Settings.VerifyCertificates := True;
    Settings.Connections := 1;
    for Index := 5 to ParamCount do
    begin
      Argument := ParamStr(Index);
      if Argument = '--no-verify' then
        Settings.VerifyCertificates := False
      else if Argument = '--tls1.2' then
        Settings.MaximumVersion := $0303
      else if Argument = '--resume' then
        Settings.Connections := 2
      else if Copy(Argument, 1, 9) = '--groups=' then
        Settings.Groups := Copy(Argument, 10, Length(Argument))
      else
        Settings.CipherName := Argument;
    end;
    Halt(RunInteropClient(Settings));
  end;
  if ParamCount < 3 then
  begin
    WriteLn('usage: TlsTest CERTIFICATE-DIRECTORY CA-BUNDLE FIXTURE-DIRECTORY');
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
  TestNameConstraintRules;
  TestFixtureChains(ParamStr(1), ParamStr(3));
  TestOcspResponses(ParamStr(1), ParamStr(3));
  TestTls12Prf(ParamStr(3));
  FinishChecks('tls test');
end.
