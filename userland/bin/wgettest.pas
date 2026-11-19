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
  wgettest - wget and libtls against the test web servers on the host

  Run by coretest under "make test". QEMU's user network hands the
  connections to these addresses to scripts/test-web-server.py (and to
  OpenSSL's s_server) on the host, with the test certificates of
  tools/TlsTest/certificates, so nothing here needs the Internet:

    10.0.2.102:80    plain HTTP
    10.0.2.101:443   HTTPS, a P-256 certificate under an intermediate
    10.0.2.103:443   openssl s_server -www, an RSA certificate signed
                     with RSA-PSS
    10.0.2.104:443   HTTPS with a certificate for another name
    10.0.2.105:443   HTTPS with a certificate from an unknown authority
    10.0.2.106:443   HTTPS with an expired certificate

  The test root is fetched over HTTP first and given to wget with
  --ca-certificate. Each check runs a command line through sh and
  compares its output and exit status: contents (sha256sum), every
  cipher suite, redirects, chunked and close-delimited bodies,
  continuing, -S, -O -, the user agent, timeouts, error responses and
  each certificate failure; keep-alive (several requests on one
  connection, over HTTP and HTTPS, after redirections and errors),
  cookies (kept across a redirection, written to and read from cookie
  files), Basic and Digest authentication (and ~/.netrc), gzip bodies
  (--compression), --trust-server-names, and recursion over a small
  site (-r, -l, -np, -A, -R, -p, -k, robots.txt). Prints a line per check and
  "wgettest: N of N checks passed" at the end; exits with 1 if any
  failed.
}
program wgettest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Processes,
  Util.FileTree,
  Sys.Streams;

type
  TCommandTest = record
    Command: string;
    ExpectedOutput: string;
    ExpectedStatus: LongInt;
  end;

const
  WorkDirectory: string = '/tmp/wgettest';
  DataHash = 'df0f6306fcfb22cadc19e9868af0728ea9444c363c55ac205c4782a827176d9e';
  Hello = 'Hello from the FreePascalOS test server'#10;
  Trust = '--ca-certificate=ca.pem ';

  CommandTests: array[0..61] of TCommandTest = (
    { Plain HTTP, and the test root for the rest. }
    (Command: 'wget -q http://10.0.2.102/hello.txt && cat hello.txt'; ExpectedOutput: Hello; ExpectedStatus: 0),
    (Command: 'wget -q http://10.0.2.102/hello.txt && ls hello.txt*'; ExpectedOutput: 'hello.txt'#10'hello.txt.1'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O ca.pem http://10.0.2.102/ca.pem && head -n 1 ca.pem';
     ExpectedOutput: '-----BEGIN CERTIFICATE-----'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - http://10.0.2.102/data.bin | sha256sum'; ExpectedOutput: DataHash + '  -'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O - http://10.0.2.102/stream.bin | sha256sum'; ExpectedOutput: DataHash + '  -'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q http://10.0.2.102/chunked.bin && sha256sum chunked.bin';
     ExpectedOutput: DataHash + '  chunked.bin'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - -U "FreePascalOS-Test/1.0" http://10.0.2.102/agent';
     ExpectedOutput: 'FreePascalOS-Test/1.0'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - http://10.0.2.102/agent'; ExpectedOutput: 'Wget/1.21 (FreePascalOS)'#10; ExpectedStatus: 0),
    (Command: 'wget -S -O s.txt http://10.0.2.102/hello.txt 2>&1 | grep "^  HTTP/"';
     ExpectedOutput: '  HTTP/1.1 200 OK'#10; ExpectedStatus: 0),

    { Redirects. }
    (Command: 'wget -q -O r.txt http://10.0.2.102/redirect/19 && cat r.txt'; ExpectedOutput: Hello; ExpectedStatus: 0),
    (Command: 'wget -O r.txt http://10.0.2.102/redirect/20 2>&1 | tail -n 1; wget -q -O r.txt ' +
       'http://10.0.2.102/redirect/20; echo $?'; ExpectedOutput: '20 redirections exceeded.'#10'7'#10;
     ExpectedStatus: 0),
    (Command: 'for p in relative see-other temporary permanent; do wget -q -O - http://10.0.2.102/$p; done';
     ExpectedOutput: Hello + Hello + Hello + Hello; ExpectedStatus: 0),
    (Command: 'wget -q ' + Trust + '-O - http://10.0.2.102/to-https'; ExpectedOutput: Hello; ExpectedStatus: 0),
    (Command: 'wget -q http://10.0.2.102/redirect/2 && cat 2'; ExpectedOutput: Hello; ExpectedStatus: 0),

    { HTTPS. }
    (Command: 'wget -q ' + Trust + 'https://10.0.2.101/data.bin && sha256sum data.bin';
     ExpectedOutput: DataHash + '  data.bin'#10; ExpectedStatus: 0),
    (Command: 'wget -q ' + Trust + '-O - https://10.0.2.101/chunked.bin | sha256sum';
     ExpectedOutput: DataHash + '  -'#10; ExpectedStatus: 0),
    (Command: 'for c in TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256; do ' +
       'wget -q ' + Trust + '--ciphers=$c -O - https://10.0.2.101/hello.txt; done';
     ExpectedOutput: Hello + Hello + Hello; ExpectedStatus: 0),
    (Command: 'wget -q ' + Trust + '-O www.html https://10.0.2.103/ && grep -c "Protocol  : TLSv1.3" www.html';
     ExpectedOutput: '1'#10; ExpectedStatus: 0),

    { Continuing. }
    (Command: 'head -c 123456 data.bin > part.bin && wget -q -c ' + Trust + '-O part.bin https://10.0.2.101/data.bin ' +
       '&& sha256sum part.bin'; ExpectedOutput: DataHash + '  part.bin'#10; ExpectedStatus: 0),
    (Command: 'wget -c ' + Trust + '-O part.bin https://10.0.2.101/data.bin 2>&1 | grep -c "fully retrieved"';
     ExpectedOutput: '1'#10; ExpectedStatus: 0),

    { Failures. }
    (Command: 'wget -q http://10.0.2.102/missing; echo $?; test -e missing; echo $?';
     ExpectedOutput: '8'#10'1'#10; ExpectedStatus: 0),
    (Command: 'wget http://10.0.2.102/missing 2>&1 | grep -c "ERROR 404: Not Found."'; ExpectedOutput: '1'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -T 2 -t 1 http://10.0.2.102/slow; echo $?'; ExpectedOutput: '4'#10; ExpectedStatus: 0),
    (Command: 'wget -q -T 3 -t 1 http://10.0.2.102:81/; echo $?'; ExpectedOutput: '4'#10; ExpectedStatus: 0),
    (Command: 'wget -q -t 1 http://nosuchhost.invalid/; echo $?'; ExpectedOutput: '4'#10; ExpectedStatus: 0),
    (Command: 'wget -q ftp://10.0.2.102/; echo $?'; ExpectedOutput: '2'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - https://10.0.2.101/hello.txt; echo $?'; ExpectedOutput: '5'#10; ExpectedStatus: 0),
    (Command: 'wget ' + Trust + 'https://10.0.2.104/hello.txt 2>&1 | grep "^ERROR"';
     ExpectedOutput: 'ERROR: cannot verify 10.0.2.104''s certificate: the certificate is not valid for this host ' +
       'name (host: 10.0.2.104).'#10; ExpectedStatus: 0),
    (Command: 'wget ' + Trust + 'https://10.0.2.105/hello.txt 2>&1 | grep "^ERROR"';
     ExpectedOutput: 'ERROR: cannot verify 10.0.2.105''s certificate: the certificate was issued by an unknown ' +
       'authority (issuer: Untrusted Test Root).'#10; ExpectedStatus: 0),
    (Command: 'wget ' + Trust + 'https://10.0.2.106/hello.txt 2>&1 | grep "^ERROR"; ' +
       'wget -q ' + Trust + 'https://10.0.2.106/hello.txt; echo $?';
     ExpectedOutput: 'ERROR: cannot verify 10.0.2.106''s certificate: the certificate has expired (certificate: ' +
       'localhost expired).'#10'5'#10; ExpectedStatus: 0),
    (Command: 'wget -q --no-check-certificate -O - https://10.0.2.105/hello.txt'; ExpectedOutput: Hello;
     ExpectedStatus: 0),
    (Command: 'wget --no-check-certificate -O w.txt https://10.0.2.104/hello.txt 2>&1 | grep -c "^WARNING: ' +
       'cannot verify"'; ExpectedOutput: '1'#10; ExpectedStatus: 0),
    { Keep-alive. }
    (Command: 'wget -q -O - http://10.0.2.102/count http://10.0.2.102/count http://10.0.2.102/count';
     ExpectedOutput: '1'#10'2'#10'3'#10; ExpectedStatus: 0),
    (Command: 'wget -q --no-http-keep-alive -O - http://10.0.2.102/count http://10.0.2.102/count';
     ExpectedOutput: '1'#10'1'#10; ExpectedStatus: 0),
    (Command: 'wget -O r.txt http://10.0.2.102/redirect/2 2>&1 | grep -c "^Reusing existing connection to 10.0.2.102:80."';
     ExpectedOutput: '3'#10; ExpectedStatus: 0),
    (Command: 'wget -q ' + Trust + '-O - https://10.0.2.101/count https://10.0.2.101/count';
     ExpectedOutput: '1'#10'2'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - http://10.0.2.102/missing http://10.0.2.102/count; echo $?';
     ExpectedOutput: '2'#10'8'#10; ExpectedStatus: 0),

    { Cookies. }
    (Command: 'wget -q -O - http://10.0.2.102/cookie/redirect'; ExpectedOutput: 'session=abc123; persistent=yes'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O - --no-cookies http://10.0.2.102/cookie/redirect'; ExpectedOutput: 'none'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O c.out --save-cookies c1.txt http://10.0.2.102/cookie/set && grep -c persistent c1.txt; ' +
       'grep -c session c1.txt'; ExpectedOutput: '1'#10'0'#10; ExpectedStatus: 1),
    (Command: 'wget -q -O c.out --save-cookies c2.txt --keep-session-cookies http://10.0.2.102/cookie/set && ' +
       'grep session c2.txt | cut -f 1,3,5,6,7'; ExpectedOutput: '10.0.2.102'#9'/cookie'#9'0'#9'session'#9'abc123'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O - --load-cookies c2.txt http://10.0.2.102/cookie/show';
     ExpectedOutput: 'session=abc123; persistent=yes'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - --load-cookies c1.txt http://10.0.2.102/cookie/show'; ExpectedOutput: 'persistent=yes'#10;
     ExpectedStatus: 0),

    { Authentication. }
    (Command: 'wget -q -O - http://10.0.2.102/basic; echo $?'; ExpectedOutput: '6'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - --user=user --password=secret http://10.0.2.102/basic'; ExpectedOutput: 'basic ok'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O - --user=user --password=wrong http://10.0.2.102/basic; echo $?'; ExpectedOutput: '6'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q -O - --user=nobody --password=x --http-user=user --http-password=secret ' +
       'http://10.0.2.102/digest'; ExpectedOutput: 'digest ok'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O - --user=user --password=secret http://10.0.2.102/digest-md5'; ExpectedOutput: 'digest ok'#10;
     ExpectedStatus: 0),
    (Command: 'wget -O - --user=user --password=secret http://10.0.2.102/digest http://10.0.2.102/digest > d.out ' +
       '2> d.err; grep -c "response... 401" d.err; cat d.out'; ExpectedOutput: '1'#10'digest ok'#10'digest ok'#10;
     ExpectedStatus: 0),
    (Command: 'printf "machine 10.0.2.102 login user password secret\n" > .netrc; export HOME=/tmp/wgettest; ' +
       'wget -q -O - http://10.0.2.102/basic; wget -q -O - -e netrc=off http://10.0.2.102/basic; echo $?';
     ExpectedOutput: 'basic ok'#10'6'#10; ExpectedStatus: 0),

    { gzip. }
    (Command: 'wget -q -O - http://10.0.2.102/accept-encoding; wget -q -O - --compression=auto ' +
       'http://10.0.2.102/accept-encoding'; ExpectedOutput: 'identity'#10'gzip'#10; ExpectedStatus: 0),
    (Command: 'wget -q -O plain.txt http://10.0.2.102/gzip.txt; wget -q -O dec.txt --compression=gzip ' +
       'http://10.0.2.102/gzip.txt; wget -q -O chk.txt --compression=auto http://10.0.2.102/gzip-chunked.txt; ' +
       'test "$(sha256sum < plain.txt)" = "$(sha256sum < dec.txt)" && test "$(sha256sum < plain.txt)" = ' +
       '"$(sha256sum < chk.txt)" && head -n 1 dec.txt && tail -n 1 chk.txt';
     ExpectedOutput: 'line 1 of the compressible text'#10'line 100 of the compressible text'#10; ExpectedStatus: 0),
    (Command: 'wget -q --compression=auto http://10.0.2.102/archive.gz && gzip -dc archive.gz | tail -n 1; ' +
       'wget -q --compression=gzip -O arch.txt http://10.0.2.102/archive.gz && tail -n 1 arch.txt';
     ExpectedOutput: 'line 100 of the compressible text'#10'line 100 of the compressible text'#10;
     ExpectedStatus: 0),
    (Command: 'wget -q --compression=gzip -O bad.txt http://10.0.2.102/gzip-bad.txt; echo $?'; ExpectedOutput: '7'#10;
     ExpectedStatus: 0),

    { --trust-server-names. }
    (Command: 'mkdir names && cd names && wget -q http://10.0.2.102/see-other && wget -q --trust-server-names ' +
       'http://10.0.2.102/see-other && ls'; ExpectedOutput: 'hello.txt'#10'see-other'#10; ExpectedStatus: 0),

    { Recursion over /site/ (robots.txt keeps /site/private/ out). }
    (Command: 'mkdir r1 && cd r1 && wget -q -r -np http://10.0.2.102/site/ && find 10.0.2.102 -type f | sort';
     ExpectedOutput: '10.0.2.102/robots.txt'#10'10.0.2.102/site/index.html'#10'10.0.2.102/site/notes.tmp'#10 +
       '10.0.2.102/site/page1.html'#10'10.0.2.102/site/pic.png'#10'10.0.2.102/site/style.css'#10 +
       '10.0.2.102/site/sub/deep/deep.png'#10'10.0.2.102/site/sub/deep/page3.html'#10 +
       '10.0.2.102/site/sub/page2.html'#10; ExpectedStatus: 0),
    (Command: 'mkdir r2 && cd r2 && wget -q -r -l 1 -np -R tmp http://10.0.2.102/site/ && ' +
       'find 10.0.2.102 -type f | sort';
     ExpectedOutput: '10.0.2.102/robots.txt'#10'10.0.2.102/site/index.html'#10'10.0.2.102/site/page1.html'#10 +
       '10.0.2.102/site/pic.png'#10'10.0.2.102/site/style.css'#10'10.0.2.102/site/sub/page2.html'#10;
     ExpectedStatus: 0),
    (Command: 'mkdir r3 && cd r3 && wget -q -r -np -A html http://10.0.2.102/site/ && find 10.0.2.102 -type f | sort';
     ExpectedOutput: '10.0.2.102/robots.txt'#10'10.0.2.102/site/index.html'#10'10.0.2.102/site/page1.html'#10 +
       '10.0.2.102/site/sub/deep/page3.html'#10'10.0.2.102/site/sub/page2.html'#10; ExpectedStatus: 0),
    (Command: 'mkdir r4 && cd r4 && wget -q -p http://10.0.2.102/site/sub/page2.html && find 10.0.2.102 -type f | sort';
     ExpectedOutput: '10.0.2.102/robots.txt'#10'10.0.2.102/site/pic.png'#10'10.0.2.102/site/sub/page2.html'#10;
     ExpectedStatus: 0),
    (Command: 'mkdir r5 && cd r5 && wget -q -r -np -k http://10.0.2.102/site/ && ' +
       'grep -o "href=[^ >]*" 10.0.2.102/site/index.html';
     ExpectedOutput: 'href="style.css"'#10'href="page1.html"'#10'href="sub/page2.html"'#10 +
       'href="http://10.0.2.102/hello.txt"'#10'href="http://10.0.2.102/site/private/secret.html"'#10 +
       'href="notes.tmp"'#10'href="http://10.0.2.101/hello.txt"'#10; ExpectedStatus: 0),
    (Command: 'mkdir r6 && cd r6 && wget -q -r -np -e robots=off http://10.0.2.102/site/ && ' +
       'find 10.0.2.102 -type f | grep -c secret; test -e 10.0.2.102/robots.txt; echo $?';
     ExpectedOutput: '1'#10'1'#10; ExpectedStatus: 0),
    (Command: 'wget -q -r -O x http://10.0.2.102/site/; echo $?'; ExpectedOutput: '2'#10; ExpectedStatus: 0));

var
  PassedCount: Integer;
  FailedCount: Integer;

{ Text with its line feeds and tabs written as \n and \t. }
function VisibleText(const Text: string): string;
begin
  Result := StringReplace(StringReplace(Text, #10, '\n', [rfReplaceAll]), #9, '\t', [rfReplaceAll]);
end;

{ Runs Command through the shell; returns its exit status and output. }
function RunShellCommand(const Command: string; out Output: string): LongInt;
var
  ReadHandle, WriteHandle: Int64;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Buffer: array[0..1023] of Char;
  Chunk: string;
  Count: Int64;
begin
  Output := '';
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    Exit(-1);
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := PChar(Command);
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
  CloseFile(WriteHandle);
  if Process < 0 then
  begin
    CloseFile(ReadHandle);
    Exit(LongInt(Process));
  end;
  repeat
    Count := ReadFile(ReadHandle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
    begin
      SetString(Chunk, PChar(@Buffer[0]), Count);
      Output := Output + Chunk;
    end;
  until Count <= 0;
  CloseFile(ReadHandle);
  Result := WaitForProgram(Process);
end;

procedure RunCommandTest(const Test: TCommandTest);
var
  Output: string;
  Status: LongInt;
begin
  ChangeDirectory(PChar(WorkDirectory));
  Status := RunShellCommand(Test.Command, Output);
  if (Status = Test.ExpectedStatus) and (Output = Test.ExpectedOutput) then
  begin
    Inc(PassedCount);
    PrintStringLine('pass: ' + Test.Command);
  end
  else
  begin
    Inc(FailedCount);
    PrintString(Format('FAIL: %s'#10'  expected status %d, output "', [Test.Command, Test.ExpectedStatus]));
    PrintString(VisibleText(Test.ExpectedOutput));
    PrintString(Format('"'#10'  got      status %d, output "', [Status]));
    PrintString(VisibleText(Output));
    PrintStringLine('"');
  end;
end;

var
  Test: TCommandTest;
begin
  PassedCount := 0;
  FailedCount := 0;
  if PathExists(PChar(WorkDirectory)) then
    RemoveTree(WorkDirectory);
  CreateDirectory(PChar(WorkDirectory));
  for Test in CommandTests do
    RunCommandTest(Test);
  ChangeDirectory('/');
  RemoveTree(WorkDirectory);
  if FailedCount > 0 then
  begin
    PrintString(Format('wgettest: %d of %d checks failed'#10, [FailedCount, PassedCount + FailedCount]));
    Halt(1);
  end;
  PrintString(Format('wgettest: %d of %d checks passed'#10, [PassedCount, PassedCount + FailedCount]));
  Halt(0);
end.
