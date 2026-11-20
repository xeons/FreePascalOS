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
  h3get - fetch a URL over HTTP/3 (libquic)

  h3get [-v] [-s] [-I] [-k] [-o FILE] [-X METHOD] [-d DATA] [-H 'NAME: VALUE']...
        [--cacert FILE] [--timeout SECONDS] [--mtu BYTES] [--fail] https://HOST[:PORT]/PATH

  Opens a QUIC connection to HOST (port 443 unless given) with ALPN h3,
  sends one request and writes the response body to standard output (or
  FILE). -v shows the connection (address, suite, RTT, packets) and the
  response head on standard error; -I sends HEAD and shows the head; -d
  sends DATA as the body (POST unless -X says otherwise); -k does not
  check the certificate; --mtu sets the datagram size (1200 to 1452;
  without it 1200 and a probe for 1452). Exit status: 0 done, 1 usage, 4
  network failure, 5 certificate or TLS failure, 7 protocol error, 8 an
  error status with --fail.
}
program h3get;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Http3.Connections,
  Http3.Constants,
  Http3.Requests,
  Qpack.StaticTable,
  Quic.Errors,
  Quic.Sessions;

const
  OptionVerbose = 1;
  OptionSilent = 2;
  OptionHead = 3;
  OptionInsecure = 4;
  OptionOutput = 5;
  OptionMethod = 6;
  OptionData = 7;
  OptionHeader = 8;
  OptionCertificates = 9;
  OptionTimeout = 10;
  OptionDatagramSize = 11;
  OptionFail = 12;

  Options: array[0..11] of TCommandOption = (
    (ShortName: 'v'; LongName: 'verbose'; TakesValue: False; Code: OptionVerbose),
    (ShortName: 's'; LongName: 'silent'; TakesValue: False; Code: OptionSilent),
    (ShortName: 'I'; LongName: 'head'; TakesValue: False; Code: OptionHead),
    (ShortName: 'k'; LongName: 'insecure'; TakesValue: False; Code: OptionInsecure),
    (ShortName: 'o'; LongName: 'output'; TakesValue: True; Code: OptionOutput),
    (ShortName: 'X'; LongName: 'request'; TakesValue: True; Code: OptionMethod),
    (ShortName: 'd'; LongName: 'data'; TakesValue: True; Code: OptionData),
    (ShortName: 'H'; LongName: 'header'; TakesValue: True; Code: OptionHeader),
    (ShortName: #0; LongName: 'cacert'; TakesValue: True; Code: OptionCertificates),
    (ShortName: #0; LongName: 'timeout'; TakesValue: True; Code: OptionTimeout),
    (ShortName: #0; LongName: 'mtu'; TakesValue: True; Code: OptionDatagramSize),
    (ShortName: #0; LongName: 'fail'; TakesValue: False; Code: OptionFail));

  Usage = 'Usage: h3get [-v] [-s] [-I] [-k] [-o FILE] [-X METHOD] [-d DATA] [-H ''NAME: VALUE'']...'#10 +
    '             [--cacert FILE] [--timeout SECONDS] [--mtu BYTES] [--fail] https://HOST[:PORT]/PATH'#10 +
    'Fetch a URL over HTTP/3.';

  ExitUsage = 1;
  ExitNetwork = 4;
  ExitTls = 5;
  ExitProtocol = 7;
  ExitServerError = 8;

type
  TTarget = record
    Host: string;
    Port: Word;
    Authority: string;
    Path: string;
  end;

var
  Verbose, Silent: Boolean;

procedure Note(const Text: string);
begin
  if Verbose then
    WriteStringLine(StandardError, '* ' + Text);
end;

{ https://host[:port]/path, host possibly an [IPv6] literal. }
function ParseTarget(const Url: string; out Target: TTarget): Boolean;
var
  Rest, HostPart: string;
  Slash, Colon, Closing, PortNumber: Integer;
begin
  Target := Default(TTarget);
  Result := False;
  if LowerCase(Copy(Url, 1, 8)) <> 'https://' then
    Exit;
  Rest := Copy(Url, 9, Length(Url));
  Slash := Pos('/', Rest);
  if Slash = 0 then
  begin
    HostPart := Rest;
    Target.Path := '/';
  end
  else
  begin
    HostPart := Copy(Rest, 1, Slash - 1);
    Target.Path := Copy(Rest, Slash, Length(Rest));
  end;
  Target.Authority := HostPart;
  Target.Port := 443;
  if (HostPart <> '') and (HostPart[1] = '[') then
  begin
    Closing := Pos(']', HostPart);
    if Closing = 0 then
      Exit;
    Target.Host := Copy(HostPart, 2, Closing - 2);
    Rest := Copy(HostPart, Closing + 1, Length(HostPart));
    if Rest <> '' then
    begin
      if (Rest[1] <> ':') or not TryStrToInt(Copy(Rest, 2, 5), PortNumber) then
        Exit;
      Target.Port := PortNumber;
    end;
  end
  else
  begin
    Colon := Pos(':', HostPart);
    if Colon > 0 then
    begin
      if not TryStrToInt(Copy(HostPart, Colon + 1, 5), PortNumber) or (PortNumber < 1) or (PortNumber > 65535) then
        Exit;
      Target.Port := PortNumber;
      Target.Host := Copy(HostPart, 1, Colon - 1);
    end
    else
      Target.Host := HostPart;
  end;
  Result := Target.Host <> '';
end;

function ExitStatusFor(Error: LongInt): Integer;
begin
  case Error of
    QuicErrorHandshakeFailed:
      Result := ExitTls;
    QuicErrorProtocolViolation, QuicErrorVersionNegotiation, QuicErrorClosedByPeer, Http3ErrorConnection,
    Http3ErrorMalformedResponse, Http3ErrorRequestReset, Http3ErrorIncomplete, Http3ErrorGoingAway:
      Result := ExitProtocol;
  else
    Result := ExitNetwork;
  end;
end;

procedure ShowHead(Request: THttp3Request);
var
  Index: Integer;
begin
  for Index := 0 to Request.InterimCount - 1 do
    WriteStringLine(StandardError, '< HTTP/3 ' + IntToStr(Request.InterimStatus[Index]) + ' (interim)');
  WriteStringLine(StandardError, '< HTTP/3 ' + IntToStr(Request.Status));
  for Index := 0 to High(Request.Headers) do
    WriteStringLine(StandardError, '< ' + Request.Headers[Index].Name + ': ' + Request.Headers[Index].Value);
end;

function Run(CommandLine: TCommandLine): Integer;
var
  Target: TTarget;
  Session: TQuicSession;
  Http: THttp3ClientConnection;
  Request: THttp3Request;
  Headers: TQpackFieldList;
  Method, Data, Text: string;
  Error: LongInt;
  Code: Integer;
  Value: string;
  Separator, Seconds, Size: Integer;
  Output: TStream;
  Buffer: array[0..65535] of Byte;
  Count: Int64;
  HeadOnly, FailOnError: Boolean;
begin
  Headers := nil;
  Method := '';
  Data := '';
  HeadOnly := False;
  FailOnError := False;
  Session := TQuicSession.Create;
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionVerbose: Verbose := True;
        OptionSilent: Silent := True;
        OptionHead: HeadOnly := True;
        OptionInsecure: Session.VerifyCertificates := False;
        OptionMethod: Method := UpperCase(Value);
        OptionData: Data := Value;
        OptionFail: FailOnError := True;
        OptionCertificates: Session.TrustFile := Value;
        OptionHeader:
          begin
            Separator := Pos(':', Value);
            if Separator < 2 then
              Fail(ExitUsage, 'a header is NAME: VALUE');
            AddField(Headers, LowerCase(Trim(Copy(Value, 1, Separator - 1))),
              Trim(Copy(Value, Separator + 1, Length(Value))));
          end;
        OptionTimeout:
          begin
            if not TryStrToInt(Value, Seconds) or (Seconds < 1) then
              Fail(ExitUsage, 'the timeout is a number of seconds');
            Session.TimeoutMilliseconds := Int64(Seconds) * 1000;
          end;
        OptionDatagramSize:
          begin
            if not TryStrToInt(Value, Size) or (Size < 1200) or (Size > 1452) then
              Fail(ExitUsage, 'the datagram size is 1200 to 1452 bytes');
            Session.MaximumDatagramSize := Size;
          end;
      end;
    if CommandLine.OperandCount <> 1 then
      FailWithUsageHint('one URL, please');
    if not ParseTarget(CommandLine.Operands[0], Target) then
      Fail(ExitUsage, 'not an https URL: ' + CommandLine.Operands[0]);
    if Method = '' then
    begin
      if HeadOnly then
        Method := 'HEAD'
      else if CommandLine.OptionGiven(OptionData) then
        Method := 'POST'
      else
        Method := 'GET';
    end;
    if FieldValue(Headers, 'user-agent') = '' then
      AddField(Headers, 'user-agent', 'h3get/1.0 (FreePascalOS)');
    if FieldValue(Headers, 'accept') = '' then
      AddField(Headers, 'accept', '*/*');
    if CommandLine.OptionGiven(OptionData) then
      AddField(Headers, 'content-length', IntToStr(Length(Data)));

    Note('connecting to ' + Target.Host + ' port ' + IntToStr(Target.Port) + ' over QUIC');
    Error := Session.Open(Target.Host, Target.Port);
    if Error <> QuicErrorNone then
    begin
      if not Silent then
        Report(Session.DescribeError(Error));
      Exit(ExitStatusFor(Error));
    end;
    Note('connected to ' + Session.AddressText + ', ' + Session.Connection.CipherSuiteName + ', ALPN ' +
      Session.Connection.ApplicationProtocol);
    Http := THttp3ClientConnection.Create(Session.Connection, False);
    try
      Error := Http.Start;
      Request := nil;
      if Error = QuicErrorNone then
        try
          Request := THttp3Request.Create(Http, Method, 'https', Target.Authority, Target.Path, Headers,
            not CommandLine.OptionGiven(OptionData));
        except
          on Failure: EQuicError do
            Error := Failure.Code;
        end;
      if Error <> 0 then
      begin
        if not Silent then
          Report(Http.ErrorDescription(Error));
        Exit(ExitStatusFor(Error));
      end;
      try
        if CommandLine.OptionGiven(OptionData) then
        begin
          if Length(Data) > 0 then
            Request.WriteBody(@Data[1], Length(Data));
          Request.FinishRequest;
        end;
        Error := Request.ReadHead;
        if Error <> 0 then
        begin
          if not Silent then
            Report(Http.ErrorDescription(Error));
          Exit(ExitStatusFor(Error));
        end;
        if Verbose or HeadOnly then
          ShowHead(Request);
        if CommandLine.OptionGiven(OptionOutput) and (CommandLine.OptionValue(OptionOutput) <> '-') then
          Output := TFileStream.Create(CommandLine.OptionValue(OptionOutput), fmCreate)
        else
          Output := nil;
        try
          repeat
            Count := Request.ReadBody(@Buffer[0], SizeOf(Buffer));
            if Count > 0 then
            begin
              if Output <> nil then
                Output.WriteBuffer(Buffer[0], Count)
              else
                WriteBytes(StandardOutput, @Buffer[0], Count);
            end;
          until Count <= 0;
        finally
          Output.Free;
        end;
        if Count < 0 then
        begin
          if not Silent then
            Report(Http.ErrorDescription(LongInt(Count)));
          Exit(ExitStatusFor(LongInt(Count)));
        end;
        for Code := 0 to High(Request.Trailers) do
          Note('trailer ' + Request.Trailers[Code].Name + ': ' + Request.Trailers[Code].Value);
        Text := Format('%d bytes, RTT %d ms, %d packets sent, %d lost, %d-byte datagrams',
          [Request.BodyReceived, Session.Connection.SmoothedRtt, Session.Connection.Statistics.PacketsSent,
          Session.Connection.Statistics.PacketsLost, Session.Connection.DatagramSize]);
        Note(Text);
        Result := 0;
        if FailOnError and (Request.Status >= 400) then
          Result := ExitServerError;
      finally
        Request.Free;
      end;
      Http.Close;
    finally
      Http.Free;
    end;
  finally
    Session.Free;
    FlushStream(StandardOutput);
  end;
end;

var
  CommandLine: TCommandLine;
begin
  CommandLine := TCommandLine.Create(Options, Usage);
  try
    ExitCode := Run(CommandLine);
  finally
    CommandLine.Free;
  end;
end.
