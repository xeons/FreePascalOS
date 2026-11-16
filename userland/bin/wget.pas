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
  wget - fetch files over HTTP and HTTPS

  wget [OPTION]... URL...

  Fetches each URL with HTTP/1.1, over TLS 1.3 (libtls) for https, and
  saves it in a file named after the URL (index.html for a directory),
  or as -O says ("-O -": standard output). Follows redirects (at most
  20), takes chunked and Content-Length bodies, continues files (-c),
  tries again after network failures (-t) and shows a progress line on
  a terminal. The server's certificate is checked against
  /etc/ssl/certs/ca-certificates.crt (or --ca-certificate) unless
  --no-check-certificate. Hosts are looked up by Sys.HostNames; numeric
  addresses need no DNS. The units are in userland/wget.

  Exit status as GNU wget: 0 success, 1 generic error, 2 bad options,
  3 file error, 4 network failure, 5 certificate check failed, 7
  protocol error, 8 the server answered with an error.
}
program wget;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Streams,
  Tls.CipherSuites,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Wget.Settings,
  Wget.Transfer,
  Wget.Urls;

const
  Usage = 'Usage: wget [OPTION]... URL...'#10 +
    'Fetch files over HTTP and HTTPS.'#10 +
    #10 +
    '  -O, --output-document=FILE  write everything to FILE ("-": standard output)'#10 +
    '  -q, --quiet                 say nothing'#10 +
    '  -S, --server-response       show the server''s response headers'#10 +
    '  -c, --continue              continue a partly fetched file'#10 +
    '  -T, --timeout=SECONDS       give up waiting for the server after SECONDS (900)'#10 +
    '  -t, --tries=NUMBER          try NUMBER times (20; 0 or inf: no limit)'#10 +
    '  -U, --user-agent=AGENT      send AGENT as the User-Agent'#10 +
    '      --no-check-certificate  do not refuse a certificate that does not check'#10 +
    '      --ca-certificate=FILE   trust the PEM certificates in FILE instead of'#10 +
    '                              /etc/ssl/certs/ca-certificates.crt'#10 +
    '      --ciphers=LIST          offer only these TLS 1.3 cipher suites (separated'#10 +
    '                              by colons: TLS_AES_128_GCM_SHA256,'#10 +
    '                              TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256)'#10 +
    '      --help                  show this help'#10 +
    '      --version               show the version'#10;

  OptionOutput = 1;
  OptionQuiet = 2;
  OptionServerResponse = 3;
  OptionContinue = 4;
  OptionTimeout = 5;
  OptionTries = 6;
  OptionUserAgent = 7;
  OptionNoCheckCertificate = 8;
  OptionCaCertificate = 9;
  OptionCiphers = 10;

  MaximumTimeoutSeconds = 24 * 3600;
  MaximumTries = 1000000;

{ "A:B:C" into the list of cipher suites. }
procedure ParseCipherList(const Text: string; var Settings: TWgetSettings);
var
  Name: string;
  Identifier: Word;
begin
  Settings.CipherSuites.Count := 0;
  for Name in Text.Split([':']) do
  begin
    if Name = '' then
      Continue;
    Identifier := CipherSuiteByName(Name);
    if Identifier = 0 then
      Fail(ExitParseError, Format('unknown cipher suite ''%s''', [Name]));
    if Settings.CipherSuites.Count >= MaximumCipherSuites then
      Fail(ExitParseError, 'too many cipher suites');
    Settings.CipherSuites.Identifiers[Settings.CipherSuites.Count] := Identifier;
    Inc(Settings.CipherSuites.Count);
  end;
  if Settings.CipherSuites.Count = 0 then
    Fail(ExitParseError, 'no cipher suites given');
end;

procedure ParseTimeout(const Value: string; var Settings: TWgetSettings);
var
  Number: Int64;
begin
  if not ParseDecimal(Value, Number) or (Number < 0) or (Number > MaximumTimeoutSeconds) then
    Fail(ExitParseError, Format('invalid timeout ''%s''', [Value]));
  Settings.TimeoutMilliseconds := Number * 1000;
end;

procedure ParseTries(const Value: string; var Settings: TWgetSettings);
var
  Number: Int64;
begin
  if SameText(Value, 'inf') then
    Settings.Tries := 0
  else if not ParseDecimal(Value, Number) or (Number < 0) or (Number > MaximumTries) then
    Fail(ExitParseError, Format('invalid number of tries ''%s''', [Value]))
  else
    Settings.Tries := Number;
end;

procedure ParseOptions(CommandLine: TCommandLine; var Settings: TWgetSettings);
var
  Code: Integer;
  Value: string;
begin
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionOutput:
        begin
          Settings.HasOutputDocument := True;
          Settings.OutputDocument := Value;
        end;
      OptionQuiet: Settings.Quiet := True;
      OptionServerResponse: Settings.ShowServerResponse := True;
      OptionContinue: Settings.ContinueDownload := True;
      OptionTimeout: ParseTimeout(Value, Settings);
      OptionTries: ParseTries(Value, Settings);
      OptionUserAgent: Settings.UserAgent := Value;
      OptionNoCheckCertificate: Settings.VerifyCertificates := False;
      OptionCaCertificate:
        begin
          Settings.HasTrustFile := True;
          Settings.TrustFile := Value;
        end;
      OptionCiphers: ParseCipherList(Value, Settings);
    end;
end;

var
  CommandLine: TCommandLine;
  Settings: TWgetSettings;
  Url: TUrl;
  Index: Integer;
  Status: Integer;
  ExitStatus: Integer;
begin
  InitializeSettings(Settings);
  CommandLine := TCommandLine.Create([
    CommandOption('O', 'output-document', True, OptionOutput),
    CommandOption('q', 'quiet', False, OptionQuiet),
    CommandOption('S', 'server-response', False, OptionServerResponse),
    CommandOption('c', 'continue', False, OptionContinue),
    CommandOption('T', 'timeout', True, OptionTimeout),
    CommandOption('t', 'tries', True, OptionTries),
    CommandOption('U', 'user-agent', True, OptionUserAgent),
    CommandOption(#0, 'no-check-certificate', False, OptionNoCheckCertificate),
    CommandOption(#0, 'ca-certificate', True, OptionCaCertificate),
    CommandOption(#0, 'ciphers', True, OptionCiphers)], Usage);
  ParseOptions(CommandLine, Settings);
  if CommandLine.OperandCount = 0 then
  begin
    Report('missing URL');
    PrintErrorStringLine('Usage: wget [OPTION]... URL...'#10#10'Try ''wget --help'' for more options.');
    Halt(ExitGenericError);
  end;
  if Settings.ContinueDownload and Settings.HasOutputDocument and
     (Settings.OutputDocument = StandardOutputName) then
    Fail(ExitParseError, 'cannot continue (-c) when writing to standard output');
  ExitStatus := ExitSuccess;
  for Index := 0 to CommandLine.OperandCount - 1 do
  begin
    if not ParseUrl(CommandLine.Operands[Index], Url) then
    begin
      Report(Format('%s: invalid URL (only http:// and https:// are supported)', [CommandLine.Operands[Index]]));
      ExitStatus := ExitParseError;
      Continue;
    end;
    Status := FetchUrl(Settings, Url, Settings.HasOutputDocument, Settings.OutputDocument, Index > 0);
    if Status <> ExitSuccess then
      ExitStatus := Status;
  end;
  CommandLine.Free;
  FlushStandardStreams;
  Halt(ExitStatus);
end.
