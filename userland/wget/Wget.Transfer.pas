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
{$H+}

interface

uses
  Wget.Settings,
  Wget.Urls;

{ Without HasOutput the file is named after the URL; Output is the -O
  target otherwise. AppendOutput adds to it (every URL after the first
  goes into the same file). }
function FetchUrl(constref Settings: TWgetSettings; constref RequestedUrl: TUrl; HasOutput: Boolean;
  const Output: string; AppendOutput: Boolean): Integer;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.LocalTime,
  Sys.Processes,
  Sys.Time,
  Util.Messages,
  Sys.Streams,
  Wget.Bodies,
  Wget.Connections,
  Wget.Files,
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

procedure AnnounceRequest(constref Fetch: TFetch);
begin
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

procedure ReportSaved(constref Fetch: TFetch; Received: Int64; Total: Int64; Milliseconds: QWord);
var
  Speed: string;
  Text: string;
begin
  if Fetch.Settings.Quiet then
    Exit;
  if Milliseconds = 0 then
    Milliseconds := 1;
  Speed := FormatSpeed((Received * 1000) div Int64(Milliseconds));
  WriteTimestamp;
  if Fetch.Target.IsStandardOutput then
    Text := Format(' (%s) - written to stdout [%d', [Speed, Fetch.StartingBytes + Received])
  else
    Text := Format(' (%s) - ''%s'' saved [%d', [Speed, Fetch.Target.Name, Fetch.StartingBytes + Received]);
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
  Result := AttemptRedirect;
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

{ A body that broke off: said, and the next try set up to continue
  where it broke if the server takes ranges. }
function HandleBrokenBody(var Fetch: TFetch; Connection: TConnection; constref Response: THttpResponseHead;
  Outcome: TBodyOutcome; Received: Int64): TAttemptOutcome;
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
  if not Fetch.Target.IsStandardOutput and ((Response.StatusCode = 206) or (Response.ContentLength >= 0)) then
    Fetch.StartingBytes := Fetch.StartingBytes + Received
  else
  begin
    Fetch.StartingBytes := 0;
    CloseOutput(Fetch.Target);
  end;
  Result := AttemptRetry;
end;

function ReceiveInto(var Fetch: TFetch; Connection: TConnection; constref Response: THttpResponseHead): TAttemptOutcome;
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
    Say(Fetch, Format('wget: %s: %s'#10, [Fetch.Target.Name, ErrorText(Error)]));
    Fetch.ExitStatus := ExitFileError;
    Exit(AttemptFailed);
  end;
  Total := -1;
  if Response.ContentLength >= 0 then
    Total := Fetch.StartingBytes + Response.ContentLength;
  BeginProgress(Progress, Fetch.Target.Name, Total, Fetch.StartingBytes, Fetch.Settings.Quiet);
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
  else
    Result := HandleBrokenBody(Fetch, Connection, Response, Outcome, Received);
  end;
end;

{ The request sent, the head read and the body received over an open
  connection. }
function Exchange(var Fetch: TFetch; Connection: TConnection): TAttemptOutcome;
var
  Response: THttpResponseHead;
  Head: THeadOutcome;
  RangeStart: Int64;
begin
  RangeStart := 0;
  if not Fetch.Target.IsStandardOutput then
    RangeStart := Fetch.StartingBytes;
  Result := AttemptFailed;
  if not SendRequest(Connection, Fetch.Url, Fetch.Settings, RangeStart) then
  begin
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

function Attempt(var Fetch: TFetch): TAttemptOutcome;
var
  Connection: TConnection;
  ConnectionSettings: TConnectionSettings;
begin
  AnnounceRequest(Fetch);
  ConnectionSettings := Default(TConnectionSettings);
  ConnectionSettings.TimeoutMilliseconds := Fetch.Settings.TimeoutMilliseconds;
  ConnectionSettings.VerifyCertificates := Fetch.Settings.VerifyCertificates;
  ConnectionSettings.HasTrustFile := Fetch.Settings.HasTrustFile;
  ConnectionSettings.TrustFile := Fetch.Settings.TrustFile;
  ConnectionSettings.CipherSuites := Fetch.Settings.CipherSuites;
  ConnectionSettings.Quiet := Fetch.Settings.Quiet;
  Connection := TConnection.Create;
  try
    if not Connection.Open(Fetch.Url, ConnectionSettings) then
    begin
      ReportConnectionFailure(Fetch, Connection);
      if Connection.Failure = FailureTimeout then
        Exit(AttemptRetry);
      Exit(AttemptFailed);
    end;
    Result := Exchange(Fetch, Connection);
  finally
    Connection.Free;
  end;
end;

{ The file to write: -O's, or one named after the URL. }
procedure ChooseTarget(var Fetch: TFetch; HasOutput: Boolean; const Output: string);
var
  Name: string;
begin
  if HasOutput then
  begin
    Fetch.Target.IsStandardOutput := Output = StandardOutputName;
    if not Fetch.Target.IsStandardOutput then
      Fetch.Target.Name := Output;
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

function FetchUrl(constref Settings: TWgetSettings; constref RequestedUrl: TUrl; HasOutput: Boolean;
  const Output: string; AppendOutput: Boolean): Integer;
var
  Fetch: TFetch;
  Tries: Integer;
  Outcome: TAttemptOutcome;
  WaitSeconds: Integer;
begin
  Fetch := Default(TFetch);
  Fetch.Settings := Settings;
  Fetch.Url := RequestedUrl;
  Fetch.ExitStatus := ExitSuccess;
  Fetch.AppendOutput := AppendOutput;
  ChooseTarget(Fetch, HasOutput, Output);

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
