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
  What wget was told on its command line, and its exit statuses (those
  of GNU wget).
}
unit Wget.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Tls.CipherSuites;

const
  ExitSuccess = 0;
  ExitGenericError = 1;
  ExitParseError = 2;
  ExitFileError = 3;
  ExitNetworkFailure = 4;
  ExitTlsVerificationFailure = 5;
  ExitProtocolError = 7;
  ExitServerError = 8;

  MaximumRedirects = 20;
  DefaultTries = 20;
  DefaultUserAgent = 'Wget/1.21 (FreePascalOS)';
  StandardOutputName = '-';

type
  TWgetSettings = record
    { Without it the name comes from the URL; "-": standard output. }
    HasOutputDocument: Boolean;
    OutputDocument: string;
    Quiet: Boolean;
    ShowServerResponse: Boolean;
    ContinueDownload: Boolean;
    VerifyCertificates: Boolean;
    { A PEM file of trusted certificates instead of the system's. }
    HasTrustFile: Boolean;
    TrustFile: string;
    { 0: no limit. }
    TimeoutMilliseconds: Int64;
    { 0: as many as it takes. }
    Tries: Integer;
    UserAgent: string;
    CipherSuites: TCipherSuiteList;
  end;

procedure InitializeSettings(out Settings: TWgetSettings);

implementation

procedure InitializeSettings(out Settings: TWgetSettings);
begin
  Settings := Default(TWgetSettings);
  Settings.VerifyCertificates := True;
  Settings.Tries := DefaultTries;
  Settings.UserAgent := DefaultUserAgent;
  { GNU wget's default read timeout. }
  Settings.TimeoutMilliseconds := 900 * 1000;
end;

end.
