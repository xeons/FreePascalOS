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

  - redirects (301, 302, 303, 307, 308) are followed, at most 20, to
    http or https URLs only, the Location resolved against the URL it
    came from; the file keeps the name of the URL first asked for;
  - a transfer that fails part way (a timeout, a connection that breaks
    or ends early) is tried again, up to the number of tries, waiting a
    second more each time (at most ten), and continues where it broke
    when the server allows ranges; an unknown host, a refused
    connection, a certificate that does not check and error responses
    (4xx, 5xx) are not tried again;
  - with -c an existing file is continued (Range); a server that sends
    the whole file instead is refused rather than the file truncated,
    and 416 means the file is already complete.

  Returns the exit status (Wget.Settings).
}
unit Wget.Transfer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Wget.Files,
  Wget.Settings,
  Wget.Urls;

{ Output is the -O target, or nil; AppendOutput adds to it (every URL
  after the first goes into the same file). }
function FetchUrl(constref Settings: TWgetSettings; constref RequestedUrl: TUrl; Output: PChar;
  AppendOutput: Boolean): Integer;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Format,
  Sys.LocalTime,
  Sys.Streams,
  Sys.Processes,
  Sys.Time,
  Tls.Errors,
  Wget.Bodies,
  Wget.Connections,
  Wget.Headers,
  Wget.Progress,
  Wget.Requests;

type
  TAttemptOutcome = (AttemptDone, AttemptRedirect, AttemptRetry, AttemptFailed);

  TFetch = record
    Settings: TWgetSettings;
    Url: TUrl;
    Target: TOutputTarget;
    { Bytes already in the file (continuing, or after a broken try). }
    StartingBytes: Int64;
    { The server answered a Range request with 206 before. }
    ResumeAllowed: Boolean;
    ExitStatus: Integer;
    Redirects: Integer;
    AppendOutput: Boolean;
  end;

procedure Complain(constref Fetch: TFetch; Format: PChar; const Arguments: array of TFormatArgument);
begin
  if not Fetch.Settings.Quiet then
    WriteFormatted(StandardError, Format, Arguments);
end;

procedure Say(constref Fetch: TFetch; Text: PChar);
begin
  if not Fetch.Settings.Quiet then
    WriteText(StandardError, Text);
end;

procedure WriteTimestamp;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  WriteFormatted(StandardError, '%04d-%02d-%02d %02d:%02d:%02d', [ArgumentNumber(Local.DateTime.Year),
    ArgumentNumber(Local.DateTime.Month), ArgumentNumber(Local.DateTime.Day), ArgumentNumber(Local.DateTime.Hour),
    ArgumentNumber(Local.DateTime.Minute), ArgumentNumber(Local.DateTime.Second)]);
end;

procedure AnnounceRequest(constref Fetch: TFetch);
var
  Text: array[0..MaximumPathLength + MaximumHostLength + 32] of Char;
begin
  if Fetch.Settings.Quiet then
    Exit;
  FormatUrl(Fetch.Url, @Text[0], SizeOf(Text));
  WriteText(StandardError, '--');
  WriteTimestamp;
  WriteFormatted(StandardError, '--  %s'#10, [ArgumentText(@Text[0])]);
end;

procedure ReportConnectionFailure(var Fetch: TFetch; constref Connection: TConnection);
begin
  case Connection.Failure of
    FailureLookUp:
      begin
        Complain(Fetch, 'wget: unable to resolve host address ''%s''.'#10,
          [ArgumentText(@Fetch.Url.Host[0])]);
        Fetch.ExitStatus := ExitNetworkFailure;
      end;
    FailureCertificate:
      begin
        Complain(Fetch, 'ERROR: cannot verify %s''s certificate: %s.'#10 +
          '  To connect to %s insecurely, use ''--no-check-certificate''.'#10,
          [ArgumentText(@Fetch.Url.Host[0]), ArgumentText(@Connection.ErrorText[0]),
           ArgumentText(@Fetch.Url.Host[0])]);
        Fetch.ExitStatus := ExitTlsVerificationFailure;
      end;
    FailureTls:
      begin
        Complain(Fetch, 'ERROR: TLS connection to %s failed: %s.'#10,
          [ArgumentText(@Fetch.Url.Host[0]), ArgumentText(@Connection.ErrorText[0])]);
        Fetch.ExitStatus := ExitNetworkFailure;
      end;
  else
    Fetch.ExitStatus := ExitNetworkFailure;
  end;
end;

procedure ReportSaved(constref Fetch: TFetch; Received: Int64; Total: Int64; Milliseconds: QWord);
var
  Speed: array[0..31] of Char;
begin
  if Fetch.Settings.Quiet then
    Exit;
  if Milliseconds = 0 then
    Milliseconds := 1;
  FormatSpeed((Received * 1000) div Int64(Milliseconds), @Speed[0]);
  WriteTimestamp;
  if Fetch.Target.IsStandardOutput then
    Complain(Fetch, ' (%s) - written to stdout [%d', [ArgumentText(@Speed[0]),
      ArgumentNumber(Fetch.StartingBytes + Received)])
  else
    Complain(Fetch, ' (%s) - ''%s'' saved [%d', [ArgumentText(@Speed[0]),
      ArgumentText(@Fetch.Target.Name[0]), ArgumentNumber(Fetch.StartingBytes + Received)]);
  if Total >= 0 then
    Complain(Fetch, '/%d', [ArgumentNumber(Total)]);
  Complain(Fetch, ']'#10#10, []);
end;

{ Length: 1234 (1.2K) [text/html] }
procedure AnnounceLength(constref Fetch: TFetch; constref Response: THttpResponseHead);
var
  Size: array[0..31] of Char;
begin
  if Fetch.Settings.Quiet then
    Exit;
  if Response.ContentLength >= 0 then
  begin
    FormatSize(Response.ContentLength, @Size[0]);
    if Fetch.StartingBytes > 0 then
    begin
      Complain(Fetch, 'Length: %d (%s), %d remaining', [ArgumentNumber(Fetch.StartingBytes +
        Response.ContentLength), ArgumentText(@Size[0]), ArgumentNumber(Response.ContentLength)]);
    end
    else
      Complain(Fetch, 'Length: %d (%s)', [ArgumentNumber(Response.ContentLength),
        ArgumentText(@Size[0])]);
  end
  else
    Complain(Fetch, 'Length: unspecified', []);
  if Response.ContentType[0] <> #0 then
    Complain(Fetch, ' [%s]', [ArgumentText(@Response.ContentType[0])]);
  WriteCharacter(StandardError, #10);
  if Fetch.Target.IsStandardOutput then
    WriteText(StandardError, 'Saving to: ''STDOUT'''#10#10)
  else
    Complain(Fetch, 'Saving to: ''%s'''#10#10, [ArgumentText(@Fetch.Target.Name[0])]);
end;

function HandleRedirect(var Fetch: TFetch; constref Response: THttpResponseHead): TAttemptOutcome;
var
  Next: TUrl;
begin
  if not Response.HasLocation then
  begin
    Complain(Fetch, 'ERROR %d: redirection without a location.'#10,
      [ArgumentNumber(Response.StatusCode)]);
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  if not ResolveUrl(Fetch.Url, @Response.Location[0], Next) then
  begin
    Complain(Fetch, 'wget: cannot follow the redirection to ''%s'' (only http and https).'#10,
      [ArgumentText(@Response.Location[0])]);
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  Inc(Fetch.Redirects);
  if Fetch.Redirects > MaximumRedirects then
  begin
    Complain(Fetch, '%d redirections exceeded.'#10, [ArgumentNumber(MaximumRedirects)]);
    Fetch.ExitStatus := ExitProtocolError;
    Exit(AttemptFailed);
  end;
  if not Fetch.Settings.Quiet then
    Complain(Fetch, 'Location: %s [following]'#10, [ArgumentText(@Response.Location[0])]);
  Fetch.Url := Next;
  Result := AttemptRedirect;
end;

{ What the status of a response means before any body is read. }
function CheckStatus(var Fetch: TFetch; constref Response: THttpResponseHead; RangeStart: Int64): TAttemptOutcome;
begin
  if not Fetch.Settings.Quiet then
    Complain(Fetch, '%d %s'#10, [ArgumentNumber(Response.StatusCode),
      ArgumentText(@Response.Reason[0])]);
  if StatusIsRedirect(Response.StatusCode) then
    Exit(HandleRedirect(Fetch, Response));
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
    Complain(Fetch, ' ERROR %d: %s.'#10, [ArgumentNumber(Response.StatusCode),
      ArgumentText(@Response.Reason[0])]);
    Fetch.ExitStatus := ExitServerError;
    Exit(AttemptFailed);
  end;
  if RangeStart > 0 then
  begin
    if Response.StatusCode = 206 then
    begin
      if not Response.HasContentRange or (Response.RangeStart <> RangeStart) then
      begin
        Complain(Fetch, 'wget: the server sent another part of the file than asked for.'#10, []);
        Fetch.ExitStatus := ExitProtocolError;
        Exit(AttemptFailed);
      end;
      Fetch.ResumeAllowed := True;
    end
    else if Fetch.Settings.ContinueDownload and not Fetch.ResumeAllowed then
    begin
      { The whole file came back: truncating would lose what is there. }
      Complain(Fetch, #10'    Continued download failed on this file, which conflicts with -c.'#10 +
        'Refusing to truncate existing file ''%s''.'#10#10, [ArgumentText(@Fetch.Target.Name[0])]);
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
  Result := AttemptDone;
end;

function ReceiveInto(var Fetch: TFetch; var Connection: TConnection; constref Response: THttpResponseHead): TAttemptOutcome;
var
  Progress: TProgress;
  Received: Int64;
  WriteError: LongInt;
  Outcome: TBodyOutcome;
  Total: Int64;
  Started: QWord;
  Error: LongInt;
begin
  Error := OpenOutput(Fetch.Target, (Fetch.StartingBytes > 0) or Fetch.AppendOutput);
  if Error <> ErrorNone then
  begin
    Complain(Fetch, 'wget: %s: %s'#10, [ArgumentText(@Fetch.Target.Name[0]),
      ArgumentText(ErrorMessage(Error))]);
    Fetch.ExitStatus := ExitFileError;
    Exit(AttemptFailed);
  end;
  Total := -1;
  if Response.ContentLength >= 0 then
    Total := Fetch.StartingBytes + Response.ContentLength;
  BeginProgress(Progress, @Fetch.Target.Name[0], Total, Fetch.StartingBytes, Fetch.Settings.Quiet);
  Started := UptimeMilliseconds;
  Outcome := ReceiveBody(Connection, Response, Fetch.Target, Progress, Received, WriteError);
  FinishProgress(Progress);
  case Outcome of
    BodyComplete:
      begin
        ReportSaved(Fetch, Received, Total, UptimeMilliseconds - Started);
        Fetch.ExitStatus := ExitSuccess;
        Result := AttemptDone;
      end;
    BodyWriteFailed:
      begin
        Complain(Fetch, 'wget: cannot write to ''%s'' (%s).'#10, [ArgumentText(@Fetch.Target.Name[0]),
          ArgumentText(ErrorMessage(WriteError))]);
        Fetch.ExitStatus := ExitFileError;
        Result := AttemptFailed;
      end;
    BodyMalformed:
      begin
        Complain(Fetch, 'wget: the server sent a malformed chunked body.'#10, []);
        Fetch.ExitStatus := ExitProtocolError;
        Result := AttemptFailed;
      end;
  else
    if not Fetch.Settings.Quiet then
    begin
      WriteTimestamp;
      if Outcome = BodyEndedEarly then
        Complain(Fetch, ' (%d bytes) - Connection closed at byte %d. ', [ArgumentNumber(Received),
          ArgumentNumber(Fetch.StartingBytes + Received)])
      else
        Complain(Fetch, ' - Read error at byte %d (%s). ', [ArgumentNumber(Fetch.StartingBytes +
          Received), ArgumentText(@Connection.ErrorText[0])]);
    end;
    Fetch.ExitStatus := ExitNetworkFailure;
    { Continue from here next time, if the server takes ranges. }
    if not Fetch.Target.IsStandardOutput and ((Response.StatusCode = 206) or (Response.ContentLength >= 0)) then
      Fetch.StartingBytes := Fetch.StartingBytes + Received
    else
    begin
      Fetch.StartingBytes := 0;
      CloseOutput(Fetch.Target);
    end;
    Result := AttemptRetry;
  end;
end;

function Attempt(var Fetch: TFetch): TAttemptOutcome;
var
  Connection: TConnection;
  ConnectionSettings: TConnectionSettings;
  Response: THttpResponseHead;
  Head: THeadOutcome;
  RangeStart: Int64;
begin
  AnnounceRequest(Fetch);
  FillChar(ConnectionSettings, SizeOf(ConnectionSettings), 0);
  ConnectionSettings.TimeoutMilliseconds := Fetch.Settings.TimeoutMilliseconds;
  ConnectionSettings.VerifyCertificates := Fetch.Settings.VerifyCertificates;
  ConnectionSettings.TrustFile := Fetch.Settings.TrustFile;
  ConnectionSettings.CipherSuites := Fetch.Settings.CipherSuites;
  ConnectionSettings.Quiet := Fetch.Settings.Quiet;
  if not OpenConnection(Connection, Fetch.Url, ConnectionSettings) then
  begin
    ReportConnectionFailure(Fetch, Connection);
    if Connection.Failure = FailureTimeout then
      Exit(AttemptRetry);
    Exit(AttemptFailed);
  end;

  RangeStart := 0;
  if not Fetch.Target.IsStandardOutput then
    RangeStart := Fetch.StartingBytes;
  Result := AttemptFailed;
  if not SendRequest(Connection, Fetch.Url, Fetch.Settings, RangeStart) then
  begin
    Complain(Fetch, 'wget: cannot send the request: %s.'#10, [ArgumentText(@Connection.ErrorText[0])]);
    Fetch.ExitStatus := ExitNetworkFailure;
    CloseConnection(Connection);
    Exit(AttemptRetry);
  end;
  Say(Fetch, 'HTTP request sent, awaiting response... ');
  Head := ReceiveResponseHead(Connection, Fetch.Settings, Response);
  case Head of
    HeadReceived:
      begin
        Result := CheckStatus(Fetch, Response, RangeStart);
        if Result = AttemptDone then
        begin
          AnnounceLength(Fetch, Response);
          Result := ReceiveInto(Fetch, Connection, Response);
        end;
      end;
    HeadNoData, HeadConnectionFailed:
      begin
        if Head = HeadNoData then
          Say(Fetch, 'No data received.'#10)
        else if not Fetch.Settings.Quiet then
          Complain(Fetch, 'Read error (%s) in headers.'#10, [ArgumentText(@Connection.ErrorText[0])]);
        Fetch.ExitStatus := ExitNetworkFailure;
        Result := AttemptRetry;
      end;
    HeadUnsupportedEncoding:
      begin
        Complain(Fetch, 'wget: the server used a transfer encoding other than chunked.'#10, []);
        Fetch.ExitStatus := ExitProtocolError;
      end;
  else
    Complain(Fetch, 'wget: the server sent a malformed response.'#10, []);
    Fetch.ExitStatus := ExitProtocolError;
  end;
  CloseConnection(Connection);
end;

function FetchUrl(constref Settings: TWgetSettings; constref RequestedUrl: TUrl; Output: PChar;
  AppendOutput: Boolean): Integer;
var
  Fetch: TFetch;
  Name: array[0..FileNameCapacity - 1] of Char;
  Tries: Integer;
  Outcome: TAttemptOutcome;
  WaitSeconds: Integer;
begin
  FillChar(Fetch, SizeOf(Fetch), 0);
  Fetch.Settings := Settings;
  Fetch.Url := RequestedUrl;
  Fetch.ExitStatus := ExitSuccess;
  Fetch.AppendOutput := AppendOutput;
  if Output <> nil then
  begin
    Fetch.Target.IsStandardOutput := (Output[0] = '-') and (Output[1] = #0);
    if not Fetch.Target.IsStandardOutput then
      SetOutputName(Fetch.Target, Output);
  end
  else
  begin
    DefaultFileName(RequestedUrl, @Name[0], SizeOf(Name));
    if Settings.ContinueDownload then
      SetOutputName(Fetch.Target, @Name[0])
    else
      ChooseUniqueName(@Name[0], @Fetch.Target.Name[0], SizeOf(Fetch.Target.Name));
  end;
  if Settings.ContinueDownload and not Fetch.Target.IsStandardOutput then
    Fetch.StartingBytes := ExistingFileSize(@Fetch.Target.Name[0]);

  Tries := 0;
  repeat
    Inc(Tries);
    Outcome := Attempt(Fetch);
    if Outcome = AttemptRedirect then
    begin
      { A redirect is a new request, not another try. }
      Tries := 0;
      Continue;
    end;
    if Outcome <> AttemptRetry then
      Break;
    if (Settings.Tries > 0) and (Tries >= Settings.Tries) then
    begin
      Say(Fetch, 'Giving up.'#10#10);
      Break;
    end;
    Say(Fetch, 'Retrying.'#10#10);
    WaitSeconds := Tries;
    if WaitSeconds > 10 then
      WaitSeconds := 10;
    SleepMilliseconds(WaitSeconds * 1000);
  until False;
  CloseOutput(Fetch.Target);
  Result := Fetch.ExitStatus;
end;

end.
