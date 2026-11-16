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
{$pointermath on}

uses
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Tls.CipherSuites,
  Util.Messages,
  Util.Options,
  Wget.Settings,
  Wget.Transfer,
  Wget.Urls;

const
  Usage: PChar = 'Usage: wget [OPTION]... URL...'#10 +
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

{ "A:B:C" into the list of cipher suites. }
procedure ParseCipherList(Text: PChar; var Settings: TWgetSettings);
var
  Name: array[0..63] of Char;
  Position, Length: Integer;
  Identifier: Word;
begin
  Settings.CipherSuites.Count := 0;
  Position := 0;
  while True do
  begin
    Length := 0;
    while (Text[Position] <> #0) and (Text[Position] <> ':') do
    begin
      if Length < High(Name) then
      begin
        Name[Length] := Text[Position];
        Inc(Length);
      end;
      Inc(Position);
    end;
    Name[Length] := #0;
    if Length > 0 then
    begin
      Identifier := CipherSuiteByName(@Name[0]);
      if Identifier = 0 then
        Fail(ExitParseError, 'unknown cipher suite ''%s''', [ArgumentText(@Name[0])]);
      if Settings.CipherSuites.Count >= MaximumCipherSuites then
        Fail(ExitParseError, 'too many cipher suites', []);
      Settings.CipherSuites.Identifiers[Settings.CipherSuites.Count] := Identifier;
      Inc(Settings.CipherSuites.Count);
    end;
    if Text[Position] = #0 then
      Break;
    Inc(Position);
  end;
  if Settings.CipherSuites.Count = 0 then
    Fail(ExitParseError, 'no cipher suites given', []);
end;

procedure ParseOptions(var Parser: TOptionParser; var Settings: TWgetSettings);
var
  Code: Integer;
  Value: PChar;
  Number: Int64;
begin
  BeginOptions(Parser, [
    OptionDefinition('O', 'output-document', True, OptionOutput),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition('S', 'server-response', False, OptionServerResponse),
    OptionDefinition('c', 'continue', False, OptionContinue),
    OptionDefinition('T', 'timeout', True, OptionTimeout),
    OptionDefinition('t', 'tries', True, OptionTries),
    OptionDefinition('U', 'user-agent', True, OptionUserAgent),
    OptionDefinition(#0, 'no-check-certificate', False, OptionNoCheckCertificate),
    OptionDefinition(#0, 'ca-certificate', True, OptionCaCertificate),
    OptionDefinition(#0, 'ciphers', True, OptionCiphers)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionOutput: Settings.OutputDocument := Value;
      OptionQuiet: Settings.Quiet := True;
      OptionServerResponse: Settings.ShowServerResponse := True;
      OptionContinue: Settings.ContinueDownload := True;
      OptionTimeout:
        begin
          if not ParseInteger(Value, Number) or (Number < 0) or (Number > 24 * 3600) then
            Fail(ExitParseError, 'invalid timeout ''%s''', [ArgumentText(Value)]);
          Settings.TimeoutMilliseconds := Number * 1000;
        end;
      OptionTries:
        begin
          if CompareTextIgnoringCase(Value, 'inf') = 0 then
            Settings.Tries := 0
          else if not ParseInteger(Value, Number) or (Number < 0) or (Number > 1000000) then
            Fail(ExitParseError, 'invalid number of tries ''%s''', [ArgumentText(Value)])
          else
            Settings.Tries := Number;
        end;
      OptionUserAgent: Settings.UserAgent := Value;
      OptionNoCheckCertificate: Settings.VerifyCertificates := False;
      OptionCaCertificate: Settings.TrustFile := Value;
      OptionCiphers: ParseCipherList(Value, Settings);
    end;
end;

var
  Parser: TOptionParser;
  Settings: TWgetSettings;
  Url: TUrl;
  Index: Integer;
  Status: Integer;
  ExitStatus: Integer;
begin
  InitializeSettings(Settings);
  ParseOptions(Parser, Settings);
  if Parser.OperandCount = 0 then
  begin
    Report('missing URL', []);
    WriteLine(StandardError, 'Usage: wget [OPTION]... URL...'#10#10'Try ''wget --help'' for more options.');
    Halt(ExitGenericError);
  end;
  if Settings.ContinueDownload and (Settings.OutputDocument <> nil) and
     (Settings.OutputDocument[0] = '-') and (Settings.OutputDocument[1] = #0) then
    Fail(ExitParseError, 'cannot continue (-c) when writing to standard output', []);
  ExitStatus := ExitSuccess;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if not ParseUrl(Parser.Operands[Index], Url) then
    begin
      Report('%s: invalid URL (only http:// and https:// are supported)', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := ExitParseError;
      Continue;
    end;
    Status := FetchUrl(Settings, Url, Settings.OutputDocument, Index > 0);
    if Status <> ExitSuccess then
      ExitStatus := Status;
  end;
  FlushStandardStreams;
  Halt(ExitStatus);
end.
