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
  Fetching one URL the way GNU wget does:

  - the connection the session kept alive is used when it goes to the
    same server (and if it turns out the server closed it meanwhile, a
    new one is made at once); the connection is kept afterwards when
    the response's body had a known end and the server did not close;
    the bodies of redirections and errors are read for that;
  - cookies go out with the request and come back into the jar;
  - a 401 is answered once with the credentials (Http.Authentication),
    again only when the server calls its nonce stale;
  - redirects (301, 302, 303, 307, 308) are followed, at most 20, to
    http or https URLs only, the Location resolved against the URL it
    came from; the file keeps the name of the URL first asked for, or
    takes the last one's with --trust-server-names;
  - with --compression, gzip is asked for (not when continuing) and a
    gzip or deflate body is decoded on its way to the file;
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
  Wget.Bodies,
  Wget.Connections,
  Wget.Files,
  Http.ResponseHeads,
  Wget.Progress,
  Wget.Requests,
  Wget.Settings,
  Wget.Sinks;

const
  MaximumAuthenticationRounds = 2;

type
  TAttemptOutcome = (AttemptDone, AttemptRedirect, AttemptRetry, AttemptFailed, AttemptAuthenticate,
    AttemptStale);

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
    { The last request carried an Authorization. }
    SentAuthorization: Boolean;
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

procedure ReportConnectionFailure(var Fetch: TFetch; Connection: TConnection);
begin
  case Connection.Failure of
    FailureLookUp:
      begin
        Say(Fetch, Format('wget: unable to resolve host address ''%s''.'#10, [Fetch.Url.Host]));
        Fetch.ExitStatus := ExitNetworkFailure;
      end;
    FailureCertificate:
      begin
        Say(Fetch, Format('ERROR: cannot verify %s''s certificate: %s.'#10 +
          '  To connect to %s insecurely, use ''--no-check-certificate''.'#10,
          [Fetch.Url.Host, Connection.ErrorText, Fetch.Url.Host]));
        Fetch.ExitStatus := ExitTlsVerificationFailure;
      end;
    FailureTls:
      begin
        Say(Fetch, Format('ERROR: TLS connection to %s failed: %s.'#10, [Fetch.Url.Host, Connection.ErrorText]));
        Fetch.ExitStatus := ExitNetworkFailure;
      end;
  else
    Fetch.ExitStatus := ExitNetworkFailure;
  end;
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
procedure AnnounceLength(constref Fetch: TFetch; constref Response: THttpResponseHead);
var
  Text: string;
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
  if Response.ContentType <> '' then
    Text := Text + ' [' + Response.ContentType + ']';
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

function HandleRedirect(var Fetch: TFetch; constref Response: THttpResponseHead): TAttemptOutcome;
var
  Next: TUrl;
begin
  if not Response.HasLocation then
  begin
    Say(Fetch, Format('ERROR %d: redirection without a location.'#10, [Response.StatusCode]));
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  if not ResolveUrl(Fetch.Url, Response.Location, Next) then
  begin
    Say(Fetch, Format('wget: cannot follow the redirection to ''%s'' (only http and https).'#10,
      [Response.Location]));
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
  Say(Fetch, 'Location: ' + Response.Location + ' [following]'#10);
  Fetch.Url := Next;
  Fetch.Announced := False;
  { The file has not been opened yet: it can take the new name. }
  if Fetch.Settings.TrustServerNames and not Fetch.Request.HasOutput then
    ChooseTarget(Fetch);
  Result := AttemptRedirect;
end;

function HandleUnauthorized(var Fetch: TFetch; constref Response: THttpResponseHead): TAttemptOutcome;
var
  Stale: Boolean;
begin
  if (Fetch.AuthenticationRounds < MaximumAuthenticationRounds) and
     Fetch.Session.Authenticator.AcceptChallenges(Fetch.Url, Response.Challenges, Stale) and
     (not Fetch.SentAuthorization or Stale) then
  begin
    Inc(Fetch.AuthenticationRounds);
    Exit(AttemptAuthenticate);
  end;
  Say(Fetch, 'Username/Password Authentication Failed.'#10);
  Fetch.ExitStatus := ExitAuthenticationFailure;
  Result := AttemptFailed;
end;

{ A 2xx answer to a Range request: what it means for the file. }
function CheckRangeAnswer(var Fetch: TFetch; constref Response: THttpResponseHead;
  RangeStart: Int64): TAttemptOutcome;
begin
  Result := AttemptDone;
  if Response.StatusCode = 206 then
  begin
    if not Response.HasContentRange or (Response.RangeStart <> RangeStart) then
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
function CheckStatus(var Fetch: TFetch; constref Response: THttpResponseHead; RangeStart: Int64): TAttemptOutcome;
begin
  Say(Fetch, Format('%d %s'#10, [Response.StatusCode, Response.Reason]));
  if StatusIsRedirect(Response.StatusCode) then
    Exit(HandleRedirect(Fetch, Response));
  if Response.StatusCode = 401 then
    Exit(HandleUnauthorized(Fetch, Response));
  if (Response.StatusCode = 416) and (RangeStart > 0) then
  begin
    Say(Fetch, #10'    The file is already fully retrieved; nothing to do.'#10#10);
    Fetch.ExitStatus := ExitSuccess;
    Exit(AttemptFailed);
  end;
  if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then
  begin
    if not Fetch.Settings.Quiet then
      WriteTimestamp;
    Say(Fetch, Format(' ERROR %d: %s.'#10, [Response.StatusCode, Response.Reason]));
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
function ShouldDecode(constref Fetch: TFetch; constref Response: THttpResponseHead): Boolean;
begin
  Result := False;
  if (Fetch.Settings.Compression = CompressionNone) or not EncodingCanBeDecoded(Response.ContentEncoding) then
    Exit;
  if (Fetch.Settings.Compression = CompressionAuto) and NamesGzipFile(DefaultFileName(Fetch.Url)) then
    Exit;
  Result := True;
end;

{ A body that broke off: said, and the next try set up to continue
  where it broke if the server takes ranges (and nothing was decoded). }
function HandleBrokenBody(var Fetch: TFetch; Connection: TConnection; constref Response: THttpResponseHead;
  Outcome: TBodyOutcome; Received: Int64; Decoded: Boolean): TAttemptOutcome;
begin
  if not Fetch.Settings.Quiet then
  begin
    WriteTimestamp;
    if Outcome = BodyEndedEarly then
      PrintErrorString(Format(' (%d bytes) - Connection closed at byte %d. ', [Received,
        Fetch.StartingBytes + Received]))
    else
      PrintErrorString(Format(' - Read error at byte %d (%s). ', [Fetch.StartingBytes + Received,
        Connection.ErrorText]));
  end;
  Fetch.ExitStatus := ExitNetworkFailure;
  if not Decoded and not Fetch.Target.IsStandardOutput and
     ((Response.StatusCode = 206) or (Response.ContentLength >= 0)) then
    Fetch.StartingBytes := Fetch.StartingBytes + Received
  else
  begin
    Fetch.StartingBytes := 0;
    CloseOutput(Fetch.Target);
  end;
  Result := AttemptRetry;
end;

{ The body has a known end, so the connection can go on after it. }
function BodyIsDelimited(constref Response: THttpResponseHead): Boolean;
begin
  Result := Response.Chunked or (Response.ContentLength >= 0) or StatusHasNoBody(Response.StatusCode);
end;

function ReceiveInto(var Fetch: TFetch; Connection: TConnection; constref Response: THttpResponseHead;
  out KeepConnection: Boolean): TAttemptOutcome;
var
  Progress: TProgress;
  Received: Int64;
  WriteError: LongInt;
  Outcome: TBodyOutcome;
  Total: Int64;
  Started: QWord;
  Error: LongInt;
  OutputSink: TOutputSink;
  Sink: TBodySink;
  Decoded: Boolean;
begin
  KeepConnection := False;
  Error := OpenOutput(Fetch.Target, (Fetch.StartingBytes > 0) or Fetch.Request.AppendOutput);
  if Error <> ErrorNone then
  begin
    Say(Fetch, Format('wget: %s: %s'#10, [Fetch.Target.Name, ErrorText(Error)]));
    Fetch.ExitStatus := ExitFileError;
    Exit(AttemptFailed);
  end;
  Decoded := ShouldDecode(Fetch, Response);
  OutputSink := TOutputSink.Create(Fetch.Target);
  Sink := OutputSink;
  if Decoded then
    Sink := TInflatingSink.Create(OutputSink, EncodingIsGzip(Response.ContentEncoding));
  try
    Total := -1;
    if Response.ContentLength >= 0 then
      Total := Fetch.StartingBytes + Response.ContentLength;
    BeginProgress(Progress, Fetch.Target.Name, Total, Fetch.StartingBytes, Fetch.Settings.Quiet);
    Started := UptimeMilliseconds;
    Outcome := ReceiveBody(Connection, Response, Sink, Progress, Received, WriteError);
    FinishProgress(Progress);
    case Outcome of
      BodyComplete:
        begin
          { Decoded, the length on the wire says nothing of the file's. }
          if Decoded then
            Total := -1;
          ReportSaved(Fetch, OutputSink.Written, Total, UptimeMilliseconds - Started);
          Fetch.ExitStatus := ExitSuccess;
          Fetch.Saved := True;
          Fetch.ContentType := Response.ContentType;
          KeepConnection := BodyIsDelimited(Response) and ConnectionPersists(Response);
          Result := AttemptDone;
        end;
      BodyWriteFailed:
        begin
          Say(Fetch, Format('wget: cannot write to ''%s'' (%s).'#10, [Fetch.Target.Name, ErrorText(WriteError)]));
          Fetch.ExitStatus := ExitFileError;
          Result := AttemptFailed;
        end;
      BodyMalformed:
        begin
          Say(Fetch, 'wget: the server sent a malformed chunked body.'#10);
          Fetch.ExitStatus := ExitProtocolError;
          Result := AttemptFailed;
        end;
      BodyDecodeFailed:
        begin
          Say(Fetch, Format('wget: the server sent damaged %s data.'#10, [Response.ContentEncoding]));
          Fetch.ExitStatus := ExitProtocolError;
          Result := AttemptFailed;
        end;
    else
      Result := HandleBrokenBody(Fetch, Connection, Response, Outcome, Received, Decoded);
    end;
  finally
    if Sink <> OutputSink then
      Sink.Free;
    OutputSink.Free;
  end;
end;

{ Accept-Encoding, Cookie and Authorization for the request. }
procedure PrepareExtras(var Fetch: TFetch; RangeStart: Int64; out Extras: TRequestExtras);
begin
  Extras := Default(TRequestExtras);
  Extras.KeepAlive := Fetch.Settings.KeepAlive;
  if (Fetch.Settings.Compression <> CompressionNone) and (RangeStart = 0) then
    Extras.AcceptEncoding := 'gzip'
  else
    Extras.AcceptEncoding := 'identity';
  if Fetch.Settings.UseCookies then
    Extras.Cookie := Fetch.Session.Cookies.CookieHeaderFor(Fetch.Url.Host, Fetch.Url.Path,
      Fetch.Url.Scheme = SchemeHttps, CurrentUnixTime);
  Extras.Authorization := Fetch.Session.Authenticator.AuthorizationFor(Fetch.Url, 'GET');
  Fetch.SentAuthorization := Extras.Authorization <> '';
end;

procedure StoreCookies(constref Fetch: TFetch; constref Response: THttpResponseHead);
var
  Value: string;
begin
  if not Fetch.Settings.UseCookies then
    Exit;
  for Value in Response.SetCookies do
    Fetch.Session.Cookies.ReceiveSetCookie(Value, Fetch.Url.Host, Fetch.Url.Path, CurrentUnixTime);
end;

{ A received head: its status acted on, the body received or drained. }
function HandleResponse(var Fetch: TFetch; Connection: TConnection; constref Response: THttpResponseHead;
  RangeStart: Int64; out KeepConnection: Boolean): TAttemptOutcome;
begin
  KeepConnection := False;
  StoreCookies(Fetch, Response);
  Result := CheckStatus(Fetch, Response, RangeStart);
  if Result = AttemptDone then
  begin
    AnnounceLength(Fetch, Response);
    Exit(ReceiveInto(Fetch, Connection, Response, KeepConnection));
  end;
  { Not wanted: read so the connection can go on. }
  if (Result <> AttemptRetry) and Fetch.Settings.KeepAlive and ConnectionPersists(Response) then
    KeepConnection := DrainBody(Connection, Response);
end;

{ The request sent, the head read and the body received over an open
  connection. AttemptStale: a kept connection the server had closed. }
function Exchange(var Fetch: TFetch; Connection: TConnection; Reused: Boolean;
  out KeepConnection: Boolean): TAttemptOutcome;
var
  Response: THttpResponseHead;
  Head: THeadOutcome;
  RangeStart: Int64;
  Extras: TRequestExtras;
begin
  KeepConnection := False;
  RangeStart := 0;
  if not Fetch.Target.IsStandardOutput then
    RangeStart := Fetch.StartingBytes;
  Result := AttemptFailed;
  PrepareExtras(Fetch, RangeStart, Extras);
  if not SendRequest(Connection, Fetch.Url, Fetch.Settings, RangeStart, Extras) then
  begin
    if Reused then
      Exit(AttemptStale);
    Say(Fetch, Format('wget: cannot send the request: %s.'#10, [Connection.ErrorText]));
    Fetch.ExitStatus := ExitNetworkFailure;
    Exit(AttemptRetry);
  end;
  Say(Fetch, 'HTTP request sent, awaiting response... ');
  { With -S the response's head follows on lines of its own, as GNU wget
    shows it. }
  if Fetch.Settings.ShowServerResponse then
    Say(Fetch, #10);
  Head := ReceiveResponseHead(Connection, Fetch.Settings, Response);
  { A kept connection that ends (or breaks) before any answer was closed
    by the server meanwhile; one that times out is a slow server. }
  if Reused and ((Head = HeadNoData) or ((Head = HeadConnectionFailed) and
     (Connection.Failure <> FailureTimeout))) then
  begin
    Say(Fetch, #10);
    Exit(AttemptStale);
  end;
  case Head of
    HeadReceived:
      Result := HandleResponse(Fetch, Connection, Response, RangeStart, KeepConnection);
    HeadNoData, HeadConnectionFailed:
      begin
        if Head = HeadNoData then
          Say(Fetch, 'No data received.'#10)
        else
          Say(Fetch, Format('Read error (%s) in headers.'#10, [Connection.ErrorText]));
        Fetch.ExitStatus := ExitNetworkFailure;
        Result := AttemptRetry;
      end;
    HeadUnsupportedEncoding:
      begin
        Say(Fetch, 'wget: the server used a transfer encoding other than chunked.'#10);
        Fetch.ExitStatus := ExitProtocolError;
      end;
  else
    Say(Fetch, 'wget: the server sent a malformed response.'#10);
    Fetch.ExitStatus := ExitProtocolError;
  end;
end;

procedure MakeConnectionSettings(constref Fetch: TFetch; out ConnectionSettings: TConnectionSettings);
begin
  ConnectionSettings := Default(TConnectionSettings);
  ConnectionSettings.TimeoutMilliseconds := Fetch.Settings.TimeoutMilliseconds;
  ConnectionSettings.VerifyCertificates := Fetch.Settings.VerifyCertificates;
  ConnectionSettings.HasTrustFile := Fetch.Settings.HasTrustFile;
  ConnectionSettings.TrustFile := Fetch.Settings.TrustFile;
  ConnectionSettings.CipherSuites := Fetch.Settings.CipherSuites;
  ConnectionSettings.Quiet := Fetch.Settings.Quiet;
end;

{ A new connection to the URL's server, or nil (the failure said and
  Outcome set). }
function OpenConnection(var Fetch: TFetch; out Outcome: TAttemptOutcome): TConnection;
var
  ConnectionSettings: TConnectionSettings;
begin
  Outcome := AttemptDone;
  MakeConnectionSettings(Fetch, ConnectionSettings);
  Result := TConnection.Create;
  if Result.Open(Fetch.Url, ConnectionSettings) then
    Exit;
  ReportConnectionFailure(Fetch, Result);
  if Result.Failure = FailureTimeout then
    Outcome := AttemptRetry
  else
    Outcome := AttemptFailed;
  FreeAndNil(Result);
end;

{ The host, an IPv6 address in brackets. }
function HostForDisplay(constref Url: TUrl): string;
begin
  if UrlHostIsIpv6(Url) then
    Result := '[' + Url.Host + ']'
  else
    Result := Url.Host;
end;

function Attempt(var Fetch: TFetch): TAttemptOutcome;
var
  Connection: TConnection;
  ConnectionUrl: TUrl;
  Reused: Boolean;
  KeepConnection: Boolean;
begin
  AnnounceRequest(Fetch);
  Connection := nil;
  if Fetch.Settings.KeepAlive then
    Connection := Fetch.Session.Connections.Take(Fetch.Url);
  Reused := Connection <> nil;
  repeat
    if Connection = nil then
    begin
      Connection := OpenConnection(Fetch, Result);
      if Connection = nil then
        Exit;
    end
    else
      Say(Fetch, Format('Reusing existing connection to %s:%d.'#10, [HostForDisplay(Fetch.Url), Fetch.Url.Port]));
    ConnectionUrl := Fetch.Url;
    KeepConnection := False;
    try
      Result := Exchange(Fetch, Connection, Reused, KeepConnection);
    finally
      if KeepConnection and (Result <> AttemptStale) then
        Fetch.Session.Connections.Keep(ConnectionUrl, Connection)
      else
        Connection.Free;
      Connection := nil;
    end;
    { A kept connection the server had closed: once more on a new one. }
    Reused := False;
  until Result <> AttemptStale;
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
