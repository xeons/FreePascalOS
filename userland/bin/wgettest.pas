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
  each certificate failure. Prints a line per check and
  "wgettest: N of N checks passed" at the end; exits with 1 if any
  failed.
}
program wgettest;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.FileTree;

type
  TCommandTest = record
    Command: PChar;
    ExpectedOutput: PChar;
    ExpectedStatus: LongInt;
  end;

const
  WorkDirectory = '/tmp/wgettest';
  DataHash = 'df0f6306fcfb22cadc19e9868af0728ea9444c363c55ac205c4782a827176d9e';
  Hello = 'Hello from the FreePascalOS test server'#10;
  Trust = '--ca-certificate=ca.pem ';

  CommandTests: array[0..31] of TCommandTest = (
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
       'cannot verify"'; ExpectedOutput: '1'#10; ExpectedStatus: 0));

var
  PassedCount: Integer;
  FailedCount: Integer;

procedure WriteVisible(Text: PChar);
var
  Index: Integer;
begin
  Index := 0;
  while Text[Index] <> #0 do
  begin
    case Text[Index] of
      #10: WriteText(StandardOutput, '\n');
      #9: WriteText(StandardOutput, '\t');
    else
      WriteCharacter(StandardOutput, Text[Index]);
    end;
    Inc(Index);
  end;
end;

{ Runs Command through the shell; returns its exit status and output. }
function RunShellCommand(Command: PChar; out Output: PChar): LongInt;
var
  ReadHandle, WriteHandle: Int64;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Builder: TTextBuilder;
  Buffer: array[0..1023] of Char;
  Count: Int64;
begin
  BeginText(Builder);
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
  begin
    Output := FinishText(Builder);
    Exit(-1);
  end;
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Command;
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
  CloseFile(WriteHandle);
  if Process < 0 then
  begin
    CloseFile(ReadHandle);
    Output := FinishText(Builder);
    Exit(LongInt(Process));
  end;
  repeat
    Count := ReadFile(ReadHandle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
      AppendBytes(Builder, @Buffer[0], Count);
  until Count <= 0;
  CloseFile(ReadHandle);
  Result := WaitForProgram(Process);
  Output := FinishText(Builder);
end;

procedure RunCommandTest(const Test: TCommandTest);
var
  Output: PChar;
  Status: LongInt;
begin
  ChangeDirectory(WorkDirectory);
  Status := RunShellCommand(Test.Command, Output);
  if (Status = Test.ExpectedStatus) and TextIsEqual(Output, Test.ExpectedOutput) then
  begin
    Inc(PassedCount);
    WriteFormatted(StandardOutput, 'pass: %s'#10, [ArgumentText(Test.Command)]);
  end
  else
  begin
    Inc(FailedCount);
    WriteFormatted(StandardOutput, 'FAIL: %s'#10'  expected status %d, output "', [ArgumentText(Test.Command),
      ArgumentNumber(Test.ExpectedStatus)]);
    WriteVisible(Test.ExpectedOutput);
    WriteFormatted(StandardOutput, '"'#10'  got      status %d, output "', [ArgumentNumber(Status)]);
    WriteVisible(Output);
    WriteLine(StandardOutput, '"');
  end;
  FreeMemory(Output);
end;

var
  Index: Integer;
begin
  PassedCount := 0;
  FailedCount := 0;
  if PathExists(WorkDirectory) then
    RemoveTree(WorkDirectory);
  CreateDirectory(WorkDirectory);
  for Index := 0 to High(CommandTests) do
    RunCommandTest(CommandTests[Index]);
  ChangeDirectory('/');
  RemoveTree(WorkDirectory);
  if FailedCount > 0 then
  begin
    WriteFormatted(StandardOutput, 'wgettest: %d of %d checks failed'#10, [ArgumentNumber(FailedCount),
      ArgumentNumber(PassedCount + FailedCount)]);
    Halt(1);
  end;
  WriteFormatted(StandardOutput, 'wgettest: %d of %d checks passed'#10, [ArgumentNumber(PassedCount),
    ArgumentNumber(PassedCount + FailedCount)]);
  Halt(0);
end.
