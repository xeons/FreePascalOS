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
  A "session" channel (RFC 4254 section 6): a program run as the user
  who logged in, in a pseudo-terminal when the client asked for one
  (pty-req), else on pipes.

  Requests: pty-req (the terminal type and size), env (LANG and LC_*
  only), shell (the user's shell, interactive on a terminal), exec
  (SHELL -c COMMAND), subsystem sftp (the configured sftp-server),
  window-change (the terminal's new size) and signal (INT on a terminal
  is Ctrl-C typed into it; otherwise the program is ended with 128 plus
  the signal's number).

  The program runs in a session of its own (ProcessNewSession), so
  ending the channel ends everything it started, and with HOME, USER,
  SHELL, PATH, TERM, SSH_CONNECTION, SSH_CLIENT and SSH_TTY (on a
  terminal). Its output (standard error apart, without a terminal) is
  sent as channel data (from a terminal with a carriage return before
  each line feed, Ssh.TerminalOutput, as the client's terminal expects); what the client sends goes to its input through
  an input writer (Sshd.InputWriters). When the program has ended and
  its output is read to the end (on a terminal: what is there when it
  ends), the channel ends with its exit status.
}
unit Sshd.Sessions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Util.Logins,
  Ssh.Wire,
  Ssh.Connection,
  Ssh.TerminalOutput,
  Sshd.Configuration,
  Sshd.InputWriters;

type
  TSessionContext = record
    Account: TLoginAccount;
    Configuration: TSshdConfiguration;
    { "CLIENT-ADDRESS CLIENT-PORT SERVER-ADDRESS SERVER-PORT" }
    ConnectionText: string;
    { Signaled by the input writers. }
    ProgressEvent: Int64;
  end;

  TSessionHandleRole = (RoleOutput, RoleErrorOutput, RoleProcess);

  TSessionChannel = class;

  TSessionWait = record
    Handle: Int64;
    Session: TSessionChannel;
    Role: TSessionHandleRole;
  end;
  TSessionWaitArray = array of TSessionWait;

  TSessionChannel = class(TSshChannel)
  private
    FContext: TSessionContext;
    FWantsTerminal: Boolean;
    FTerminalType: string;
    FRows, FColumns: LongInt;
    FTerminal: TAbiPseudoTerminal;
    FHasTerminal: Boolean;
    { Line feeds from the terminal get their carriage returns. }
    FTerminalOutput: TTerminalOutputTranslator;
    FVariables: TStringArray;
    FStarted: Boolean;
    FProcess: Int64;
    FProcessId: Int64;
    FProcessEnded: Boolean;
    FExitCode: LongInt;
    FOutputHandle: Int64;
    FErrorHandle: Int64;
    FWriter: TInputWriter;
    FFinished: Boolean;
    FDescription: string;
    function StartProgram(const Arguments: array of string; const What: string): Boolean;
    function OpenTerminal: Boolean;
    function StartOnTerminal(const Arguments: array of string; const Variables: array of string): Int64;
    function StartOnPipes(const Arguments: array of string; const Variables: array of string): Int64;
    function HandlePseudoTerminalRequest(var Reader: TSshReader): Boolean;
    function HandleEnvironmentRequest(var Reader: TSshReader): Boolean;
    function HandleWindowChange(var Reader: TSshReader): Boolean;
    function HandleSignal(var Reader: TSshReader): Boolean;
    function ReadAvailable(var Handle: Int64; Extended: Boolean): Boolean;
    procedure EndProgram;
    procedure ReleaseHandles;
  protected
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; override;
    procedure HandleData(const Data: string); override;
    procedure HandleEof; override;
    procedure HandleClose; override;
  public
    constructor Create(Owner: TSshConnection; const Context: TSessionContext);
    destructor Destroy; override;
    { The handles to wait on now (output only while little is queued). }
    procedure CollectWaits(var Waits: TSessionWaitArray);
    procedure HandleReady(Role: TSessionHandleRole);
    { After every wait: input written, and whether the program is done. }
    procedure Poll;
  end;

implementation

uses
  Sys.Console,
  Sys.Errors,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes,
  Sys.PseudoTerminals,
  Sshd.Log;

const
  ReadChunkBytes = 16 * 1024;
  { Output is read while less than this waits for the client's window. }
  OutputBackLog = 64 * 1024;
  MaximumCommandLength = 64 * 1024;

function SignalNumber(const Name: string): Integer;
begin
  if Name = 'HUP' then
    Result := 1
  else if Name = 'INT' then
    Result := 2
  else if Name = 'QUIT' then
    Result := 3
  else if Name = 'KILL' then
    Result := 9
  else if Name = 'USR1' then
    Result := 10
  else if Name = 'USR2' then
    Result := 12
  else if Name = 'TERM' then
    Result := 15
  else
    Result := 0;
end;

constructor TSessionChannel.Create(Owner: TSshConnection; const Context: TSessionContext);
begin
  inherited Create(Owner);
  FContext := Context;
  FProcess := NoHandle;
  FOutputHandle := NoHandle;
  FErrorHandle := NoHandle;
  FTerminal.OutputHandle := NoHandle;
  FTerminal.InputHandle := NoHandle;
  FTerminal.TerminalHandle := NoHandle;
  FTerminal.Number := -1;
  FRows := 24;
  FColumns := 80;
end;

destructor TSessionChannel.Destroy;
begin
  EndProgram;
  ReleaseHandles;
  inherited Destroy;
end;

function TSessionChannel.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
var
  Command, Subsystem: string;
begin
  Result := False;
  if RequestType = 'pty-req' then
    Result := HandlePseudoTerminalRequest(Reader)
  else if RequestType = 'env' then
    Result := HandleEnvironmentRequest(Reader)
  else if RequestType = 'window-change' then
    Result := HandleWindowChange(Reader)
  else if RequestType = 'signal' then
    Result := HandleSignal(Reader)
  else if FStarted then
    Exit(False)
  else if RequestType = 'shell' then
  begin
    if FWantsTerminal then
      Result := StartProgram([FContext.Account.Shell, '-i'], 'shell')
    else
      Result := StartProgram([FContext.Account.Shell], 'shell');
  end
  else if RequestType = 'exec' then
  begin
    Command := Reader.ReadString;
    if Length(Command) > MaximumCommandLength then
      Exit(False);
    Result := StartProgram([FContext.Account.Shell, '-c', Command], 'command "' + Command + '"');
  end
  else if RequestType = 'subsystem' then
  begin
    Subsystem := Reader.ReadString;
    if Subsystem = 'sftp' then
      Result := StartProgram([FContext.Configuration.SftpServerPath], 'subsystem sftp')
    else
      LogLine('subsystem ' + Subsystem + ' refused');
  end;
end;

function TSessionChannel.HandlePseudoTerminalRequest(var Reader: TSshReader): Boolean;
var
  Columns, Rows: LongWord;
begin
  if FStarted then
    Exit(False);
  FTerminalType := Reader.ReadString;
  Columns := Reader.ReadUInt32;
  Rows := Reader.ReadUInt32;
  { The size in pixels and the terminal modes are not used. }
  if (Columns > 0) and (Columns < 10000) then
    FColumns := Columns;
  if (Rows > 0) and (Rows < 10000) then
    FRows := Rows;
  FWantsTerminal := True;
  Result := True;
end;

function TSessionChannel.HandleEnvironmentRequest(var Reader: TSshReader): Boolean;
var
  Name, Value: string;
begin
  Name := Reader.ReadString;
  Value := Reader.ReadString;
  Result := not FStarted and ((Name = 'LANG') or (Copy(Name, 1, 3) = 'LC_')) and (Pos('=', Name) = 0) and
    (Pos(#0, Value) = 0);
  if Result then
  begin
    SetLength(FVariables, Length(FVariables) + 1);
    FVariables[High(FVariables)] := Name + '=' + Value;
  end;
end;

function TSessionChannel.HandleWindowChange(var Reader: TSshReader): Boolean;
var
  Columns, Rows: LongWord;
begin
  Columns := Reader.ReadUInt32;
  Rows := Reader.ReadUInt32;
  if (Columns > 0) and (Columns < 10000) then
    FColumns := Columns;
  if (Rows > 0) and (Rows < 10000) then
    FRows := Rows;
  if FHasTerminal and (FTerminal.InputHandle >= 0) then
    SetConsoleSize(FTerminal.InputHandle, FRows, FColumns);
  Result := True;
end;

function TSessionChannel.HandleSignal(var Reader: TSshReader): Boolean;
var
  Number: Integer;
  Name: string;
begin
  Name := Reader.ReadString;
  Number := SignalNumber(Name);
  Result := False;
  if (Number = 0) or not FStarted or FProcessEnded then
    Exit;
  if (Number = 2) and FHasTerminal and (FWriter <> nil) then
    FWriter.Write(#3)
  else
    TerminateProgram(QWord(FProcessId), 128 + Number);
  Result := True;
end;

function TSessionChannel.OpenTerminal: Boolean;
var
  Error: LongInt;
begin
  Error := CreatePseudoTerminal(FRows, FColumns, FTerminal);
  if Error <> ErrorNone then
  begin
    LogLine('no pseudo-terminal for the session: ' + ErrorMessage(Error));
    Exit(False);
  end;
  FHasTerminal := True;
  Result := True;
end;

function TSessionChannel.StartOnTerminal(const Arguments: array of string; const Variables: array of string): Int64;
var
  Options: TProcessOptions;
begin
  DefaultProcessOptions(Options);
  Options.InputHandle := FTerminal.TerminalHandle;
  Options.OutputHandle := FTerminal.TerminalHandle;
  Options.ErrorHandle := FTerminal.TerminalHandle;
  Options.GroupId := GroupNewInForeground;
  Options.NewSession := True;
  Result := StartAsUserWithVariables(FContext.Account, Arguments, Variables, Options);
  { Only the program (and what it starts) holds the terminal now, so the
    master reads end of file once they are all gone. }
  KernelClose(FTerminal.TerminalHandle);
  FTerminal.TerminalHandle := NoHandle;
  FOutputHandle := FTerminal.OutputHandle;
  FTerminal.OutputHandle := NoHandle;
  FWriter := TInputWriter.Create(FTerminal.InputHandle, FContext.ProgressEvent, False);
end;

function TSessionChannel.StartOnPipes(const Arguments: array of string; const Variables: array of string): Int64;
var
  Options: TProcessOptions;
  InputRead, InputWrite, OutputRead, OutputWrite, ErrorRead, ErrorWrite: Int64;
  Error: LongInt;
begin
  Error := CreatePipe(InputRead, InputWrite);
  if Error <> ErrorNone then
    Exit(-Error);
  Error := CreatePipe(OutputRead, OutputWrite);
  if Error <> ErrorNone then
  begin
    KernelClose(InputRead);
    KernelClose(InputWrite);
    Exit(-Error);
  end;
  Error := CreatePipe(ErrorRead, ErrorWrite);
  if Error <> ErrorNone then
  begin
    KernelClose(InputRead);
    KernelClose(InputWrite);
    KernelClose(OutputRead);
    KernelClose(OutputWrite);
    Exit(-Error);
  end;
  DefaultProcessOptions(Options);
  Options.InputHandle := InputRead;
  Options.OutputHandle := OutputWrite;
  Options.ErrorHandle := ErrorWrite;
  Options.GroupId := GroupNew;
  Options.NewSession := True;
  Result := StartAsUserWithVariables(FContext.Account, Arguments, Variables, Options);
  KernelClose(InputRead);
  KernelClose(OutputWrite);
  KernelClose(ErrorWrite);
  FOutputHandle := OutputRead;
  FErrorHandle := ErrorRead;
  FWriter := TInputWriter.Create(InputWrite, FContext.ProgressEvent, True);
end;

{ SSH_CLIENT: the client's address and port and the server's port,
  from SSH_CONNECTION's four words. }
function ClientText(const ConnectionText: string): string;
var
  LastSpace, SecondSpace: Integer;
begin
  Result := ConnectionText;
  SecondSpace := Pos(' ', ConnectionText);
  if SecondSpace > 0 then
    SecondSpace := Pos(' ', ConnectionText, SecondSpace + 1);
  LastSpace := LastDelimiter(' ', ConnectionText);
  if (SecondSpace > 0) and (LastSpace > SecondSpace) then
    Result := Copy(ConnectionText, 1, SecondSpace) + Copy(ConnectionText, LastSpace + 1, MaxInt);
end;

procedure AddVariable(var Variables: TStringArray; const Assignment: string);
begin
  SetLength(Variables, Length(Variables) + 1);
  Variables[High(Variables)] := Assignment;
end;

function TSessionChannel.StartProgram(const Arguments: array of string; const What: string): Boolean;
var
  Variables: TStringArray;
  Process: Int64;
begin
  FStarted := True;
  Variables := Copy(FVariables);
  AddVariable(Variables, 'SSH_CONNECTION=' + FContext.ConnectionText);
  AddVariable(Variables, 'SSH_CLIENT=' + ClientText(FContext.ConnectionText));
  if FWantsTerminal then
  begin
    if FTerminalType <> '' then
      AddVariable(Variables, 'TERM=' + FTerminalType);
    if OpenTerminal then
    begin
      AddVariable(Variables, 'SSH_TTY=' + PseudoTerminalPath(FTerminal.Number));
      Process := StartOnTerminal(Arguments, Variables);
    end
    else
      Process := -ErrorBusy;
  end
  else
  begin
    AddVariable(Variables, 'TERM=dumb');
    Process := StartOnPipes(Arguments, Variables);
  end;
  if Process < 0 then
  begin
    LogLine(Format('cannot start the %s for %s: %s', [What, FContext.Account.Name,
      ErrorMessage(LongInt(-Process))]));
    FProcessEnded := True;
    FExitCode := 127;
    { The channel still ends the orderly way, with status 127. }
    Exit(True);
  end;
  FProcess := Process;
  FProcessId := ProcessIdOf(Process);
  FDescription := What;
  if FHasTerminal then
    LogLine(Format('%s for %s started (process %d) on %s', [What, FContext.Account.Name, FProcessId,
      PseudoTerminalPath(FTerminal.Number)]))
  else
    LogLine(Format('%s for %s started (process %d)', [What, FContext.Account.Name, FProcessId]));
  Result := True;
end;

procedure TSessionChannel.HandleData(const Data: string);
begin
  if (FWriter = nil) or FWriter.Broken then
    { Nobody reads it: the window opens again at once. }
    InputConsumed(Length(Data))
  else
    FWriter.Write(Data);
end;

procedure TSessionChannel.HandleEof;
begin
  { On pipes the program reads end of file; a terminal has no such
    thing (Ctrl-D is typed, not sent as EOF). }
  if (FWriter <> nil) and not FHasTerminal then
    FWriter.FinishWhenEmpty;
end;

procedure TSessionChannel.HandleClose;
begin
  EndProgram;
  ReleaseHandles;
end;

procedure TSessionChannel.CollectWaits(var Waits: TSessionWaitArray);

  procedure Add(Handle: Int64; Role: TSessionHandleRole);
  begin
    SetLength(Waits, Length(Waits) + 1);
    Waits[High(Waits)].Handle := Handle;
    Waits[High(Waits)].Session := Self;
    Waits[High(Waits)].Role := Role;
  end;

begin
  if FFinished or CloseSent then
    Exit;
  if PendingOutput < OutputBackLog then
  begin
    if FOutputHandle >= 0 then
      Add(FOutputHandle, RoleOutput);
    if FErrorHandle >= 0 then
      Add(FErrorHandle, RoleErrorOutput);
  end;
  if (FProcess >= 0) and not FProcessEnded then
    Add(FProcess, RoleProcess);
end;

{ Reads once (the handle is ready); at the end of the output the handle
  is closed. False at the end. }
function TSessionChannel.ReadAvailable(var Handle: Int64; Extended: Boolean): Boolean;
var
  Buffer: array[0..ReadChunkBytes - 1] of Byte;
  Count: Int64;
begin
  Count := KernelRead(Handle, @Buffer[0], SizeOf(Buffer));
  Result := Count > 0;
  if Result then
  begin
    if Extended then
      SendErrorData(BytesToString(@Buffer[0], Integer(Count)))
    else if FHasTerminal then
      SendData(TranslateTerminalOutput(FTerminalOutput, BytesToString(@Buffer[0], Integer(Count))))
    else
      SendData(BytesToString(@Buffer[0], Integer(Count)));
  end
  else
  begin
    KernelClose(Handle);
    Handle := NoHandle;
  end;
end;

procedure TSessionChannel.HandleReady(Role: TSessionHandleRole);
var
  ExitCode: LongInt;
begin
  case Role of
    RoleOutput:
      if FOutputHandle >= 0 then
        ReadAvailable(FOutputHandle, False);
    RoleErrorOutput:
      if FErrorHandle >= 0 then
        ReadAvailable(FErrorHandle, True);
    RoleProcess:
      if WaitForProgramWithTimeout(FProcess, 0, ExitCode) = ErrorNone then
      begin
        FProcessEnded := True;
        FExitCode := ExitCode;
        LogLine(Format('%s for %s ended (status %d)', [FDescription, FContext.Account.Name, ExitCode]));
      end;
  end;
end;

procedure TSessionChannel.Poll;
var
  Written: QWord;
begin
  if FFinished then
    Exit;
  if FWriter <> nil then
  begin
    Written := FWriter.TakeWrittenCount;
    if Written > 0 then
      InputConsumed(Written);
  end;
  if not FProcessEnded then
    Exit;
  if FHasTerminal then
  begin
    { What the program wrote last, then the terminal goes: programs it
      left behind are hung up. }
    while (FOutputHandle >= 0) and (WaitForHandles([FOutputHandle], 0) = 0) and
      ReadAvailable(FOutputHandle, False) do
      ;
  end
  else if (FOutputHandle >= 0) or (FErrorHandle >= 0) then
    { Without a terminal the output is read to its end. }
    Exit;
  FFinished := True;
  Finish(True, LongWord(FExitCode));
  EndProgram;
  ReleaseHandles;
end;

procedure TSessionChannel.EndProgram;
begin
  if (FProcess >= 0) and not FProcessEnded then
  begin
    EndSession(QWord(FProcessId), 129);
    TerminateProgram(QWord(FProcessId), 129);
    FProcessEnded := True;
  end
  else if FProcessId > 0 then
    { What the program left running in its session goes too. }
    EndSession(QWord(FProcessId), 129);
end;

procedure TSessionChannel.ReleaseHandles;
begin
  FreeAndNil(FWriter);
  if FOutputHandle >= 0 then
    KernelClose(FOutputHandle);
  FOutputHandle := NoHandle;
  if FErrorHandle >= 0 then
    KernelClose(FErrorHandle);
  FErrorHandle := NoHandle;
  { The input side last: closing it hangs the terminal up. }
  if FTerminal.InputHandle >= 0 then
    KernelClose(FTerminal.InputHandle);
  FTerminal.InputHandle := NoHandle;
  if FProcess >= 0 then
    CloseHandle(FProcess);
  FProcess := NoHandle;
  FProcessId := 0;
end;

end.
