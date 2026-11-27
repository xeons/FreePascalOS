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
  Fetching one URL the way GNU wget does, each request through
  libhttp's client (THttpClient.Execute):

  - the connection kept from an earlier request is used when it goes to
    the same server (if the server closed it meanwhile libhttp sends the
    request again on a new one); it is kept afterwards when the body had
    a known end and the server did not close; the bodies of
    redirections and errors are read for that (Discard);
  - cookies go out with the request and come back into the jar, and a
    server that asked for credentials gets them at once (libhttp);
  - a 401 is answered once with the credentials (libhttp's
    authenticator), again only when the server calls its nonce stale;
  - redirects (301, 302, 303, 307, 308) are followed, at most 20, to
    http or https URLs only, the Location resolved against the URL it
    came from; the file keeps the name of the URL first asked for, or
    takes the last one's with --trust-server-names;
  - with --compression, gzip (=gzip) or every coding libhttp undoes
    (=auto: gzip, deflate, br, zstd) is asked for (not when continuing)
    and the body is decoded on its way to the file (libhttp's decoders);
  - a transfer that fails part way (a timeout, a connection that breaks
    or ends early) is tried again, up to the number of tries, waiting a
    second more each time (at most ten), and continues where it broke
    when the server allows ranges (a decoded body starts again); an
    unknown host, a refused connection, a certificate that does not
    check and error responses (4xx, 5xx) are not tried again;
  - with -c an existing file is continued (Range); a server that sends
    the whole file instead is refused rather than the file truncated,
    and 416 means the file is already complete.

  Returns the exit status (Wget.Settings).
}
unit Wget.Transfer;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Sessions,
  Wget.Urls;

type
  TFetchRequest = record
    Url: TUrl;
    { Without HasOutput the file is named after the URL; Output is the
      file otherwise ("-": standard output). AppendOutput adds to it. }
    HasOutput: Boolean;
    Output: string;
    AppendOutput: Boolean;
  end;

  TFetchResult = record
    ExitStatus: Integer;
    { A body was saved (a 2xx response). }
    Saved: Boolean;
    { The file it went to ('' for standard output). }
    FileName: string;
    { Where the redirections ended. }
    FinalUrl: TUrl;
    ContentType: string;
  end;

function FetchUrl(Session: TWgetSession; constref Request: TFetchRequest; out Outcome: TFetchResult): Integer;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.LocalTime,
  Sys.Processes,
  Sys.Time,
  Util.Messages,
  Sys.Streams,
  Http.BodySinks,
  Http.ContentDecoding,
  Http.Messages,
  Http.ResponseHeads,
  Http.Results,
  Http.StatusCodes,
  Wget.Files,
  Wget.Progress,
  Wget.Settings,
  Wget.Sinks;

const
  MaximumAuthenticationRounds = 2;
  ReadSize = 16 * 1024;

type
  TAttemptOutcome = (AttemptDone, AttemptRedirect, AttemptRetry, AttemptFailed, AttemptAuthenticate);

  TFetch = record
    Session: TWgetSession;
    Settings: TWgetSettings;
    Request: TFetchRequest;
    Url: TUrl;
    Target: TOutputTarget;
    { Bytes already in the file (continuing, or after a broken try). }
    StartingBytes: Int64;
    { The server answered a Range request with 206 before. }
    ResumeAllowed: Boolean;
    ExitStatus: Integer;
    Redirects: Integer;
    AuthenticationRounds: Integer;
    { The "--time--  URL" line was written for this URL and try. }
    Announced: Boolean;
    Saved: Boolean;
    ContentType: string;
  end;

{ Text on error output unless quiet. }
procedure Say(constref Fetch: TFetch; const Text: string);
begin
  if not Fetch.Settings.Quiet then
    PrintErrorString(Text);
end;

procedure WriteTimestamp;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  PrintErrorString(Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [Local.DateTime.Year, Local.DateTime.Month,
    Local.DateTime.Day, Local.DateTime.Hour, Local.DateTime.Minute, Local.DateTime.Second]));
end;

procedure AnnounceRequest(var Fetch: TFetch);
begin
  if Fetch.Announced then
    Exit;
  Fetch.Announced := True;
  if Fetch.Settings.Quiet then
    Exit;
  PrintErrorString('--');
  WriteTimestamp;
  PrintErrorString('--  ' + FormatUrl(Fetch.Url) + #10);
end;

procedure ReportSaved(constref Fetch: TFetch; Written: Int64; Total: Int64; Milliseconds: QWord);
var
  Speed: string;
  Text: string;
begin
  if Fetch.Settings.Quiet then
    Exit;
  if Milliseconds = 0 then
    Milliseconds := 1;
  Speed := FormatSpeed((Written * 1000) div Int64(Milliseconds));
  WriteTimestamp;
  if Fetch.Target.IsStandardOutput then
    Text := Format(' (%s) - written to stdout [%d', [Speed, Fetch.StartingBytes + Written])
  else
    Text := Format(' (%s) - ''%s'' saved [%d', [Speed, Fetch.Target.Name, Fetch.StartingBytes + Written]);
  if Total >= 0 then
    Text := Text + '/' + IntToStr(Total);
  PrintErrorString(Text + ']'#10#10);
end;

{ Length: 1234 (1.2K) [text/html] }
procedure AnnounceLength(constref Fetch: TFetch; Response: THttpResponse);
var
  Text: string;
  ContentType: string;
begin
  if Fetch.Settings.Quiet then
    Exit;
  if Response.ContentLength < 0 then
    Text := 'Length: unspecified'
  else if Fetch.StartingBytes > 0 then
    Text := Format('Length: %d (%s), %d remaining', [Fetch.StartingBytes + Response.ContentLength,
      FormatSize(Response.ContentLength), Response.ContentLength])
  else
    Text := Format('Length: %d (%s)', [Response.ContentLength, FormatSize(Response.ContentLength)]);
  ContentType := Response.Headers.Value('content-type');
  if ContentType <> '' then
    Text := Text + ' [' + ContentType + ']';
  PrintErrorStringLine(Text);
  if Fetch.Target.IsStandardOutput then
    PrintErrorString('Saving to: ''STDOUT'''#10#10)
  else
    PrintErrorString('Saving to: ''' + Fetch.Target.Name + ''''#10#10);
end;

{ The file to write: the request's, or one named after the URL. }
procedure ChooseTarget(var Fetch: TFetch);
var
  Name: string;
begin
  Fetch.Target := Default(TOutputTarget);
  Fetch.StartingBytes := 0;
  if Fetch.Request.HasOutput then
  begin
    Fetch.Target.IsStandardOutput := Fetch.Request.Output = StandardOutputName;
    if not Fetch.Target.IsStandardOutput then
      Fetch.Target.Name := Fetch.Request.Output;
  end
  else
  begin
    Name := DefaultFileName(Fetch.Url);
    if Fetch.Settings.ContinueDownload then
      Fetch.Target.Name := Name
    else
      Fetch.Target.Name := ChooseUniqueName(Name);
  end;
  if Fetch.Settings.ContinueDownload and not Fetch.Target.IsStandardOutput then
    Fetch.StartingBytes := ExistingFileSize(Fetch.Target.Name);
end;

{ A request that failed before a response: said, and what to do next. }
function HandleFailure(var Fetch: TFetch; constref Failure: THttpResult): TAttemptOutcome;
var
  Host: string;
begin
  Host := Fetch.Url.Host;
  Fetch.ExitStatus := ExitNetworkFailure;
  Result := AttemptFailed;
  case Failure.Code of
    HttpLookupFailed:
      Say(Fetch, Format('wget: unable to resolve host address ''%s''.'#10, [Host]));
    HttpCertificateFailed:
      begin
        Say(Fetch, Format('ERROR: cannot verify %s''s certificate: %s.'#10 +
          '  To connect to %s insecurely, use ''--no-check-certificate''.'#10, [Host, Failure.Text, Host]));
        Fetch.ExitStatus := ExitTlsVerificationFailure;
      end;
    HttpTlsFailed:
      Say(Fetch, Format('ERROR: TLS connection to %s failed: %s.'#10, [Host, Failure.Text]));
    HttpConnectFailed:
      ;
    HttpTimedOut:
      begin
        if Fetch.Session.Observer.RequestWasSent then
          Say(Fetch, Format('Read error (%s) in headers.'#10, [Failure.Text]));
        Result := AttemptRetry;
      end;
    HttpSendFailed:
      begin
        Say(Fetch, Format('wget: cannot send the request: %s.'#10, [Failure.Text]));
        Result := AttemptRetry;
      end;
    HttpNoResponse:
      begin
        Say(Fetch, 'No data received.'#10);
        Result := AttemptRetry;
      end;
    HttpReadFailed, HttpStreamReset:
      begin
        Say(Fetch, Format('Read error (%s) in headers.'#10, [Failure.Text]));
        Result := AttemptRetry;
      end;
    HttpUnsupportedTransferCoding:
      begin
        Say(Fetch, 'wget: the server used a transfer encoding other than chunked.'#10);
        Fetch.ExitStatus := ExitProtocolError;
      end;
  else
    Say(Fetch, 'wget: the server sent a malformed response.'#10);
    Fetch.ExitStatus := ExitProtocolError;
  end;
end;

function HandleRedirect(var Fetch: TFetch; Response: THttpResponse): TAttemptOutcome;
var
  Next: TUrl;
  Location: string;
begin
  if not Response.Headers.Has('location') or (Response.Headers.Value('location') = '') then
  begin
    Say(Fetch, Format('ERROR %d: redirection without a location.'#10, [Response.Status]));
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  Location := Response.Headers.Value('location');
  if not ResolveUrl(Fetch.Url, Location, Next) then
  begin
    Say(Fetch, Format('wget: cannot follow the redirection to ''%s'' (only http and https).'#10, [Location]));
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  Inc(Fetch.Redirects);
  if Fetch.Redirects > MaximumRedirects then
  begin
    Say(Fetch, Format('%d redirections exceeded.'#10, [MaximumRedirects]));
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  Say(Fetch, 'Location: ' + Location + ' [following]'#10);
  Fetch.Url := Next;
  Fetch.Announced := False;
  { The file has not been opened yet: it can take the new name. }
  if Fetch.Settings.TrustServerNames and not Fetch.Request.HasOutput then
    ChooseTarget(Fetch);
  Result := AttemptRedirect;
end;

function HandleUnauthorized(var Fetch: TFetch; Response: THttpResponse): TAttemptOutcome;
var
  Stale: Boolean;
begin
  if (Fetch.AuthenticationRounds < MaximumAuthenticationRounds) and
     Fetch.Session.Authenticator.AcceptChallenges(UrlRecordOf(Fetch.Url), Response.Headers.GetAll('www-authenticate'),
     Stale) and (not Response.SentAuthorization or Stale) then
  begin
    Inc(Fetch.AuthenticationRounds);
    Exit(AttemptAuthenticate);
  end;
  Say(Fetch, 'Username/Password Authentication Failed.'#10);
  Fetch.ExitStatus := ExitAuthenticationFailure;
  Result := AttemptFailed;
end;

{ A 2xx answer to a Range request: what it means for the file. }
function CheckRangeAnswer(var Fetch: TFetch; Response: THttpResponse; RangeStart: Int64): TAttemptOutcome;
var
  First, Last, Total: Int64;
begin
  Result := AttemptDone;
  if Response.Status = 206 then
  begin
    if not ParseContentRange(Response.Headers.Value('content-range'), First, Last, Total) or (First <> RangeStart) then
    begin
      Say(Fetch, 'wget: the server sent another part of the file than asked for.'#10);
      Fetch.ExitStatus := ExitProtocolError;
      Exit(AttemptFailed);
    end;
    Fetch.ResumeAllowed := True;
  end
  else if Fetch.Settings.ContinueDownload and not Fetch.ResumeAllowed then
  begin
    { The whole file came back: truncating would lose what is there. }
    Say(Fetch, Format(#10'    Continued download failed on this file, which conflicts with -c.'#10 +
      'Refusing to truncate existing file ''%s''.'#10#10, [Fetch.Target.Name]));
    Fetch.ExitStatus := ExitGenericError;
    Exit(AttemptFailed);
  end
  else
  begin
    { A retry that has to start again from the beginning: the file is
      opened again, emptied. }
    Fetch.StartingBytes := 0;
    CloseOutput(Fetch.Target);
  end;
end;

{ What the status of a response means before any body is read. }
function CheckStatus(var Fetch: TFetch; Response: THttpResponse; RangeStart: Int64): TAttemptOutcome;
begin
  Say(Fetch, Format('%d %s'#10, [Response.Status, Response.Reason]));
  if StatusIsRedirect(Response.Status) then
    Exit(HandleRedirect(Fetch, Response));
  if Response.Status = 401 then
    Exit(HandleUnauthorized(Fetch, Response));
  if (Response.Status = 416) and (RangeStart > 0) then
  begin
    Say(Fetch, #10'    The file is already fully retrieved; nothing to do.'#10#10);
    Fetch.ExitStatus := ExitSuccess;
    Exit(AttemptFailed);
  end;
  if (Response.Status < 200) or (Response.Status >= 300) then
  begin
    if not Fetch.Settings.Quiet then
      WriteTimestamp;
    Say(Fetch, Format(' ERROR %d: %s.'#10, [Response.Status, Response.Reason]));
    Fetch.ExitStatus := ExitServerError;
    Exit(AttemptFailed);
  end;
  if RangeStart > 0 then
    Exit(CheckRangeAnswer(Fetch, Response, RangeStart));
  Result := AttemptDone;
end;

{ A file that is a gzip file itself (auto leaves it as it is). }
function NamesGzipFile(const Name: string): Boolean;
begin
  Result := EndsText('.gz', Name) or EndsText('.tgz', Name) or EndsText('.svgz', Name);
end;

{ True if the body is to be decoded on its way to the file. }
function ShouldDecode(constref Fetch: TFetch; const ContentEncoding: string): Boolean;
begin
  Result := False;
  if (Fetch.Settings.Compression = CompressionNone) or not EncodingCanBeDecoded(ContentEncoding) then
    Exit;
  if (Fetch.Settings.Compression = CompressionAuto) and NamesGzipFile(DefaultFileName(Fetch.Url)) then
    Exit;
  Result := True;
end;

{ A body that broke off: said, and the next try set up to continue
  where it broke if the server takes ranges (and nothing was decoded). }
function HandleBrokenBody(var Fetch: TFetch; Response: THttpResponse; constref Failure: THttpResult;
  Received: Int64; Decoded: Boolean): TAttemptOutcome;
begin
  if not Fetch.Settings.Quiet then
  begin
    WriteTimestamp;
    if Failure.Code = HttpBodyEndedEarly then
      PrintErrorString(Format(' (%d bytes) - Connection closed at byte %d. ', [Received,
        Fetch.StartingBytes + Received]))
    else
      PrintErrorString(Format(' - Read error at byte %d (%s). ', [Fetch.StartingBytes + Received, Failure.Text]));
  end;
  Fetch.ExitStatus := ExitNetworkFailure;
  if not Decoded and not Fetch.Target.IsStandardOutput and
     ((Response.Status = 206) or (Response.ContentLength >= 0)) then
    Fetch.StartingBytes := Fetch.StartingBytes + Received
  else
  begin
    Fetch.StartingBytes := 0;
    CloseOutput(Fetch.Target);
  end;
  Result := AttemptRetry;
end;

{ A sink that failed: said. }
function HandleWriteFailure(var Fetch: TFetch; Sink: THttpBodySink; const Encoding: string): TAttemptOutcome;
begin
  if Sink.DamagedData then
    Say(Fetch, Format('wget: the server sent damaged %s data.'#10, [Encoding]))
  else
    Say(Fetch, Format('wget: cannot write to ''%s'' (%s).'#10, [Fetch.Target.Name, ErrorText(Sink.ErrorCode)]));
  if Sink.DamagedData then
    Fetch.ExitStatus := ExitProtocolError
  else
    Fetch.ExitStatus := ExitFileError;
  Result := AttemptFailed;
end;

{ The body read into the output (decoded on the way when wanted). }
function ReceiveInto(var Fetch: TFetch; Response: THttpResponse): TAttemptOutcome;
var
  Progress: TProgress;
  Buffer: array[0..ReadSize - 1] of Byte;
  Count, Received, Total: Int64;
  Started: QWord;
  Error: LongInt;
  OutputSink: TOutputSink;
  Sink: THttpBodySink;
  Decoded: Boolean;
  Encoding: string;
begin
  Error := OpenOutput(Fetch.Target, (Fetch.StartingBytes > 0) or Fetch.Request.AppendOutput);
  if Error <> ErrorNone then
  begin
    Say(Fetch, Format('wget: %s: %s'#10, [Fetch.Target.Name, ErrorText(Error)]));
    Fetch.ExitStatus := ExitFileError;
    Exit(AttemptFailed);
  end;
  Encoding := LowerCase(Response.Headers.Combined('content-encoding'));
  Decoded := ShouldDecode(Fetch, Encoding);
  OutputSink := TOutputSink.Create(Fetch.Target);
  Sink := OutputSink;
  if Decoded then
    Sink := CreateDecodingChain(OutputSink, Encoding);
  try
    Total := -1;
    if Response.ContentLength >= 0 then
      Total := Fetch.StartingBytes + Response.ContentLength;
    BeginProgress(Progress, Fetch.Target.Name, Total, Fetch.StartingBytes, Fetch.Settings.Quiet);
    Started := UptimeMilliseconds;
    Received := 0;
    repeat
      Count := Response.Read(@Buffer[0], SizeOf(Buffer));
      if Count > 0 then
      begin
        Inc(Received, Count);
        AdvanceProgress(Progress, Count);
        if not Sink.Write(@Buffer[0], Count) then
        begin
          FinishProgress(Progress);
          Exit(HandleWriteFailure(Fetch, Sink, Encoding));
        end;
      end;
    until Count <= 0;
    FinishProgress(Progress);
    if Count < 0 then
    begin
      if Response.LastResult.Code = HttpMalformedBody then
      begin
        Say(Fetch, 'wget: the server sent a malformed chunked body.'#10);
        Fetch.ExitStatus := ExitProtocolError;
        Exit(AttemptFailed);
      end;
      Exit(HandleBrokenBody(Fetch, Response, Response.LastResult, Received, Decoded));
    end;
    if not Sink.Finish then
      Exit(HandleWriteFailure(Fetch, Sink, Encoding));
    { Decoded, the length on the wire says nothing of the file's. }
    if Decoded then
      Total := -1;
    ReportSaved(Fetch, OutputSink.Written, Total, UptimeMilliseconds - Started);
    Fetch.ExitStatus := ExitSuccess;
    Fetch.Saved := True;
    Fetch.ContentType := Response.Headers.Value('content-type');
    Result := AttemptDone;
  finally
    if Sink <> OutputSink then
      Sink.Free;
    OutputSink.Free;
  end;
end;

{ Each line that is not empty, indented by two spaces (-S). }
procedure ShowHead(const Head: string);
var
  Line: string;
begin
  for Line in Head.Split([#10]) do
    if (Line <> '') and (Line <> #13) then
    begin
      if Line[Length(Line)] = #13 then
        PrintErrorStringLine('  ' + Copy(Line, 1, Length(Line) - 1))
      else
        PrintErrorStringLine('  ' + Line);
    end;
end;

{ The request for this try: Accept-Encoding, a Range when continuing,
  and keep-alive as asked. }
function MakeRequest(constref Fetch: TFetch; RangeStart: Int64): THttpRequest;
begin
  Result := THttpRequest.Create('GET', UrlRecordOf(Fetch.Url));
  Result.DecodeContent := False;
  if (Fetch.Settings.Compression = CompressionAuto) and (RangeStart = 0) then
    Result.Headers.Add('Accept-Encoding', SupportedAcceptEncoding)
  else if (Fetch.Settings.Compression = CompressionGzip) and (RangeStart = 0) then
    Result.Headers.Add('Accept-Encoding', 'gzip')
  else
    Result.Headers.Add('Accept-Encoding', 'identity');
  if RangeStart > 0 then
    Result.Headers.Add('Range', 'bytes=' + IntToStr(RangeStart) + '-');
  if Fetch.Settings.KeepAlive then
    Result.Headers.Add('Connection', 'Keep-Alive')
  else
  begin
    Result.Headers.Add('Connection', 'close');
    Result.CloseConnection := True;
  end;
end;

{ A received head: its status acted on, the body received or drained. }
function HandleResponse(var Fetch: TFetch; Response: THttpResponse; RangeStart: Int64): TAttemptOutcome;
begin
  Result := CheckStatus(Fetch, Response, RangeStart);
  if Result = AttemptDone then
  begin
    AnnounceLength(Fetch, Response);
    Exit(ReceiveInto(Fetch, Response));
  end;
  { Not wanted: read so the connection can go on. }
  if Fetch.Settings.KeepAlive then
    Response.Discard;
end;

function Attempt(var Fetch: TFetch): TAttemptOutcome;
var
  Request: THttpRequest;
  Response: THttpResponse;
  Status: THttpResult;
  RangeStart: Int64;
begin
  AnnounceRequest(Fetch);
  RangeStart := 0;
  if not Fetch.Target.IsStandardOutput then
    RangeStart := Fetch.StartingBytes;
  Request := MakeRequest(Fetch, RangeStart);
  Response := nil;
  try
    Fetch.Session.Observer.BeginRequest;
    Status := Fetch.Session.Client.Execute(Request, Response);
    if not HttpSucceeded(Status) then
      Exit(HandleFailure(Fetch, Status));
    if Fetch.Settings.ShowServerResponse and not Fetch.Settings.Quiet then
      ShowHead(Response.RawHead);
    Result := HandleResponse(Fetch, Response, RangeStart);
  finally
    Response.Free;
    Request.Free;
  end;
end;

function FetchUrl(Session: TWgetSession; constref Request: TFetchRequest; out Outcome: TFetchResult): Integer;
var
  Fetch: TFetch;
  Tries: Integer;
  Attempted: TAttemptOutcome;
  WaitSeconds: Integer;
begin
  Fetch := Default(TFetch);
  Fetch.Session := Session;
  Fetch.Settings := Session.Settings;
  Fetch.Request := Request;
  Fetch.Url := Request.Url;
  Fetch.ExitStatus := ExitSuccess;
  ChooseTarget(Fetch);

  Tries := 0;
  repeat
    Inc(Tries);
    Attempted := Attempt(Fetch);
    if Attempted in [AttemptRedirect, AttemptAuthenticate] then
    begin
      { A new request, not another try. }
      Tries := 0;
      Continue;
    end;
    if Attempted <> AttemptRetry then
      Break;
    if (Fetch.Settings.Tries > 0) and (Tries >= Fetch.Settings.Tries) then
    begin
      Say(Fetch, 'Giving up.'#10#10);
      Break;
    end;
    Say(Fetch, 'Retrying.'#10#10);
    Fetch.Announced := False;
    WaitSeconds := Tries;
    if WaitSeconds > 10 then
      WaitSeconds := 10;
    SleepMilliseconds(WaitSeconds * 1000);
  until False;
  CloseOutput(Fetch.Target);
  Outcome := Default(TFetchResult);
  Outcome.ExitStatus := Fetch.ExitStatus;
  Outcome.Saved := Fetch.Saved and (Fetch.ExitStatus = ExitSuccess);
  Outcome.FileName := Fetch.Target.Name;
  Outcome.FinalUrl := Fetch.Url;
  Outcome.ContentType := Fetch.ContentType;
  Result := Fetch.ExitStatus;
end;

end.
