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
  Tls.CipherSuites,
  Wget.Patterns;

const
  ExitSuccess = 0;
  ExitGenericError = 1;
  ExitParseError = 2;
  ExitFileError = 3;
  ExitNetworkFailure = 4;
  ExitTlsVerificationFailure = 5;
  ExitAuthenticationFailure = 6;
  ExitProtocolError = 7;
  ExitServerError = 8;

  MaximumRedirects = 20;
  DefaultTries = 20;
  DefaultUserAgent = 'Wget/1.21 (FreePascalOS)';
  StandardOutputName = '-';
  DefaultRecursionDepth = 5;

type
  { --compression: none asks for and decodes nothing (the default, as
    GNU wget's); auto and gzip ask for gzip and decode it, auto not for
    files that are gzip files themselves (.gz, .tgz). }
  TCompressionChoice = (CompressionNone, CompressionAuto, CompressionGzip);

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
    { Several requests over one connection (--no-http-keep-alive: not). }
    KeepAlive: Boolean;
    { Cookies kept and sent (--no-cookies: not); files to read them from
      and write them to; session cookies written too. }
    UseCookies: Boolean;
    LoadCookiesFile: string;
    SaveCookiesFile: string;
    KeepSessionCookies: Boolean;
    { --user/--password, overridden by --http-user/--http-password;
      without them ~/.netrc. }
    User: string;
    Password: string;
    HasUser: Boolean;
    HasPassword: Boolean;
    UseNetrc: Boolean;
    Compression: TCompressionChoice;
    { Name the file after the URL a redirection ends at. }
    TrustServerNames: Boolean;
    { -r, -l (0: no limit), -np, -k, -p, -A, -R, robots.txt (-e
      robots=off), -P. }
    Recursive: Boolean;
    MaximumDepth: Integer;
    NoParent: Boolean;
    ConvertLinks: Boolean;
    PageRequisites: Boolean;
    AcceptList: TNameList;
    RejectList: TNameList;
    RespectRobots: Boolean;
    DirectoryPrefix: string;
    { -nH: no folder for the host; -nd: no folders at all. }
    NoHostFolder: Boolean;
    NoFolders: Boolean;
  end;

procedure InitializeSettings(out Settings: TWgetSettings);

implementation

procedure InitializeSettings(out Settings: TWgetSettings);
begin
  Settings := Default(TWgetSettings);
  Settings.VerifyCertificates := True;
  Settings.Tries := DefaultTries;
  Settings.UserAgent := DefaultUserAgent;
  Settings.KeepAlive := True;
  Settings.UseCookies := True;
  Settings.UseNetrc := True;
  Settings.Compression := CompressionNone;
  Settings.MaximumDepth := DefaultRecursionDepth;
  Settings.RespectRobots := True;
  { GNU wget's default read timeout. }
  Settings.TimeoutMilliseconds := 900 * 1000;
end;

end.
