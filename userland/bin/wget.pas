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
  addresses need no DNS. One connection is kept alive between requests
  to the same server; cookies are kept (and read from and written to
  Netscape cookie files); 401 is answered with Basic or Digest
  credentials (given, or from ~/.netrc); gzip bodies are decoded with
  --compression. -r fetches a site recursively (-l, -np, -A, -R,
  robots.txt), -p a page's requisites, -k converts the links of what
  was fetched. The units are in userland/wget.

  Exit status as GNU wget: 0 success, 1 generic error, 2 bad options,
  3 file error, 4 network failure, 5 certificate check failed, 6
  authentication failed, 7 protocol error, 8 the server answered with
  an error.
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
  Wget.Patterns,
  Wget.Recursion,
  Wget.Sessions,
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
    '      --no-http-keep-alive    one request per connection'#10 +
    '      --compression=TYPE      auto, gzip (ask for gzip and decode it) or none'#10 +
    '      --trust-server-names    name the file after the last URL of a redirection'#10 +
    #10 +
    '      --no-cookies            neither keep nor send cookies'#10 +
    '      --load-cookies=FILE     read cookies from FILE (Netscape format)'#10 +
    '      --save-cookies=FILE     write the cookies to FILE at the end'#10 +
    '      --keep-session-cookies  write session cookies too'#10 +
    '      --user=USER, --password=PASSWORD'#10 +
    '                              credentials for Basic and Digest authentication'#10 +
    '      --http-user=USER, --http-password=PASSWORD'#10 +
    '                              the same, for HTTP only (they win)'#10 +
    #10 +
    '  -r, --recursive             fetch recursively'#10 +
    '  -l, --level=NUMBER          the most levels to recurse (5; 0 or inf: no limit)'#10 +
    '  -np, --no-parent            never go above the starting folder'#10 +
    '  -p, --page-requisites       fetch what the pages need to be shown'#10 +
    '  -k, --convert-links         make the links of fetched pages work locally'#10 +
    '  -A, --accept=LIST           only file names ending in (or matching) LIST'#10 +
    '  -R, --reject=LIST           no file names ending in (or matching) LIST'#10 +
    '  -P, --directory-prefix=DIR  save everything under DIR'#10 +
    '  -nH, --no-host-directories  no folder per host'#10 +
    '  -nd, --no-directories       no folders at all'#10 +
    '  -e, --execute=COMMAND       robots=off, robots=on, netrc=off, netrc=on'#10 +
    #10 +
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
  OptionNoKeepAlive = 11;
  OptionCompression = 12;
  OptionTrustServerNames = 13;
  OptionNoCookies = 14;
  OptionLoadCookies = 15;
  OptionSaveCookies = 16;
  OptionKeepSessionCookies = 17;
  OptionUser = 18;
  OptionPassword = 19;
  OptionHttpUser = 20;
  OptionHttpPassword = 21;
  OptionRecursive = 22;
  OptionLevel = 23;
  OptionNoParent = 24;
  OptionPageRequisites = 25;
  OptionConvertLinks = 26;
  OptionAccept = 27;
  OptionReject = 28;
  OptionDirectoryPrefix = 29;
  OptionNoHostDirectories = 30;
  OptionNoDirectories = 31;
  OptionExecute = 32;

  MaximumTimeoutSeconds = 24 * 3600;
  MaximumTries = 1000000;
  MaximumLevel = 1000000;

type
  TUrlArray = array of TUrl;

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

procedure ParseLevel(const Value: string; var Settings: TWgetSettings);
var
  Number: Int64;
begin
  if SameText(Value, 'inf') then
    Settings.MaximumDepth := 0
  else if not ParseDecimal(Value, Number) or (Number < 0) or (Number > MaximumLevel) then
    Fail(ExitParseError, Format('invalid level ''%s''', [Value]))
  else
    Settings.MaximumDepth := Number;
end;

procedure ParseCompression(const Value: string; var Settings: TWgetSettings);
begin
  if SameText(Value, 'auto') then
    Settings.Compression := CompressionAuto
  else if SameText(Value, 'gzip') then
    Settings.Compression := CompressionGzip
  else if SameText(Value, 'none') then
    Settings.Compression := CompressionNone
  else
    Fail(ExitParseError, Format('invalid compression ''%s'' (auto, gzip or none)', [Value]));
end;

{ "on" or "off" (also yes/no, 1/0). }
function ParseSwitch(const Command, Value: string): Boolean;
begin
  Result := False;
  if SameText(Value, 'on') or SameText(Value, 'yes') or (Value = '1') then
    Result := True
  else if not (SameText(Value, 'off') or SameText(Value, 'no') or (Value = '0')) then
    Fail(ExitParseError, Format('%s: invalid value ''%s'' (on or off)', [Command, Value]));
end;

{ -e "robots = off": the few .wgetrc commands wget knows. }
procedure ParseExecute(const Text: string; var Settings: TWgetSettings);
var
  Equals: Integer;
  Command, Value: string;
begin
  Equals := Pos('=', Text);
  if Equals = 0 then
    Fail(ExitParseError, Format('invalid command ''%s''', [Text]));
  Command := LowerCase(Trim(Copy(Text, 1, Equals - 1)));
  Value := Trim(Copy(Text, Equals + 1, MaxInt));
  if Command = 'robots' then
    Settings.RespectRobots := ParseSwitch(Command, Value)
  else if Command = 'netrc' then
    Settings.UseNetrc := ParseSwitch(Command, Value)
  else
    Fail(ExitParseError, Format('unknown command ''%s''', [Command]));
end;

procedure AppendNames(var List: TNameList; const Text: string);
var
  Entry: string;
begin
  for Entry in ParseNameList(Text) do
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := Entry;
  end;
end;

{ The credentials: --http-user/--http-password over --user/--password. }
procedure ChooseCredentials(CommandLine: TCommandLine; var Settings: TWgetSettings);
begin
  if CommandLine.OptionGiven(OptionUser) then
  begin
    Settings.HasUser := True;
    Settings.User := CommandLine.OptionValue(OptionUser);
  end;
  if CommandLine.OptionGiven(OptionHttpUser) then
  begin
    Settings.HasUser := True;
    Settings.User := CommandLine.OptionValue(OptionHttpUser);
  end;
  if CommandLine.OptionGiven(OptionPassword) then
  begin
    Settings.HasPassword := True;
    Settings.Password := CommandLine.OptionValue(OptionPassword);
  end;
  if CommandLine.OptionGiven(OptionHttpPassword) then
  begin
    Settings.HasPassword := True;
    Settings.Password := CommandLine.OptionValue(OptionHttpPassword);
  end;
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
      OptionNoKeepAlive: Settings.KeepAlive := False;
      OptionCompression: ParseCompression(Value, Settings);
      OptionTrustServerNames: Settings.TrustServerNames := True;
      OptionNoCookies: Settings.UseCookies := False;
      OptionLoadCookies: Settings.LoadCookiesFile := Value;
      OptionSaveCookies: Settings.SaveCookiesFile := Value;
      OptionKeepSessionCookies: Settings.KeepSessionCookies := True;
      OptionRecursive: Settings.Recursive := True;
      OptionLevel: ParseLevel(Value, Settings);
      OptionNoParent: Settings.NoParent := True;
      OptionPageRequisites: Settings.PageRequisites := True;
      OptionConvertLinks: Settings.ConvertLinks := True;
      OptionAccept: AppendNames(Settings.AcceptList, Value);
      OptionReject: AppendNames(Settings.RejectList, Value);
      OptionDirectoryPrefix: Settings.DirectoryPrefix := Value;
      OptionNoHostDirectories: Settings.NoHostFolder := True;
      OptionNoDirectories: Settings.NoFolders := True;
      OptionExecute: ParseExecute(Value, Settings);
    end;
  ChooseCredentials(CommandLine, Settings);
end;

{ GNU wget's two-letter short options ("-np") as their long forms. }
function RewriteArguments: TStringArray;
var
  Index: Integer;
begin
  Result := ProgramArguments;
  for Index := 0 to High(Result) do
  begin
    if Result[Index] = '--' then
      Break;
    if Result[Index] = '-np' then
      Result[Index] := '--no-parent'
    else if Result[Index] = '-nH' then
      Result[Index] := '--no-host-directories'
    else if Result[Index] = '-nd' then
      Result[Index] := '--no-directories';
  end;
end;

{ The URLs of the command line (an invalid one said, and the status
  set). }
function ParseOperandUrls(CommandLine: TCommandLine; var ExitStatus: Integer): TUrlArray;
var
  Index: Integer;
  Url: TUrl;
begin
  Result := nil;
  for Index := 0 to CommandLine.OperandCount - 1 do
  begin
    if not ParseUrl(CommandLine.Operands[Index], Url) then
    begin
      Report(Format('%s: invalid URL (only http:// and https:// are supported)', [CommandLine.Operands[Index]]));
      ExitStatus := ExitParseError;
      Continue;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Url;
  end;
end;

{ Each URL in turn (over the same connection when they share a server);
  with -O every one after the first is added to the same file. }
function FetchEach(Session: TWgetSession; const Urls: TUrlArray; constref Settings: TWgetSettings): Integer;
var
  Index: Integer;
  Request: TFetchRequest;
  Outcome: TFetchResult;
  Status: Integer;
begin
  Result := ExitSuccess;
  for Index := 0 to High(Urls) do
  begin
    Request := Default(TFetchRequest);
    Request.Url := Urls[Index];
    Request.HasOutput := Settings.HasOutputDocument;
    Request.Output := Settings.OutputDocument;
    Request.AppendOutput := Index > 0;
    Status := FetchUrl(Session, Request, Outcome);
    if Status <> ExitSuccess then
      Result := Status;
  end;
end;

var
  CommandLine: TCommandLine;
  Settings: TWgetSettings;
  Session: TWgetSession;
  Urls: TUrlArray;
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
    CommandOption(#0, 'ciphers', True, OptionCiphers),
    CommandOption(#0, 'no-http-keep-alive', False, OptionNoKeepAlive),
    CommandOption(#0, 'compression', True, OptionCompression),
    CommandOption(#0, 'trust-server-names', False, OptionTrustServerNames),
    CommandOption(#0, 'no-cookies', False, OptionNoCookies),
    CommandOption(#0, 'load-cookies', True, OptionLoadCookies),
    CommandOption(#0, 'save-cookies', True, OptionSaveCookies),
    CommandOption(#0, 'keep-session-cookies', False, OptionKeepSessionCookies),
    CommandOption(#0, 'user', True, OptionUser),
    CommandOption(#0, 'password', True, OptionPassword),
    CommandOption(#0, 'http-user', True, OptionHttpUser),
    CommandOption(#0, 'http-password', True, OptionHttpPassword),
    CommandOption('r', 'recursive', False, OptionRecursive),
    CommandOption('l', 'level', True, OptionLevel),
    CommandOption(#0, 'no-parent', False, OptionNoParent),
    CommandOption('p', 'page-requisites', False, OptionPageRequisites),
    CommandOption('k', 'convert-links', False, OptionConvertLinks),
    CommandOption('A', 'accept', True, OptionAccept),
    CommandOption('R', 'reject', True, OptionReject),
    CommandOption('P', 'directory-prefix', True, OptionDirectoryPrefix),
    CommandOption(#0, 'no-host-directories', False, OptionNoHostDirectories),
    CommandOption(#0, 'no-directories', False, OptionNoDirectories),
    CommandOption('e', 'execute', True, OptionExecute)], Usage, RewriteArguments);
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
  if (Settings.Recursive or Settings.PageRequisites) and Settings.HasOutputDocument then
    Fail(ExitParseError, '-O cannot be used with -r or -p');
  ExitStatus := ExitSuccess;
  Urls := ParseOperandUrls(CommandLine, ExitStatus);
  Session := TWgetSession.Create(Settings);
  if not Session.LoadCookies then
    ExitStatus := ExitFileError;
  if Settings.Recursive or Settings.PageRequisites then
    Status := RetrieveRecursively(Session, Urls)
  else
    Status := FetchEach(Session, Urls, Settings);
  if Status <> ExitSuccess then
    ExitStatus := Status;
  if not Session.SaveCookies and (ExitStatus = ExitSuccess) then
    ExitStatus := ExitFileError;
  Session.Free;
  CommandLine.Free;
  FlushStandardStreams;
  Halt(ExitStatus);
end.
