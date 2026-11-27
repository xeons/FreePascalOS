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
  sh - the command shell

  sh                      read commands from standard input (with a
                          prompt when it is the console)
  sh -i                   the same (su and login start the shell so)
  sh -c COMMAND [NAME [ARG]...]
                          run COMMAND; NAME becomes $0, ARGs $1...
  sh FILE [ARG]...        run the script FILE

  See Shell.Syntax for the supported grammar and Shell.Expansion for
  quoting and expansions.

  An interactive shell on a terminal takes requests to end (kill, a log
  off, a stopped service, the shutdown: Sys.Notifications) and acts on
  one at its prompt, or as soon as the command it runs is over: it
  saves its history, ends its stopped jobs as it does on exit, and ends
  with the request's status (143). Ctrl-C does not end it, and a
  terminal's hang-up ends it at once (129), as before.
}
program sh;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Kernel,
  Sys.Memory,
  Sys.Notifications,
  Sys.Processes,
  Sys.Streams,
  Util.Input,
  Util.LineEditor,
  Shell.Output,
  Shell.Host,
  Shell.Nodes,
  Shell.Syntax,
  Shell.Variables,
  Shell.Execution,
  Shell.Jobs;

const
  { 128 + SIGHUP. }
  HangUpStatus = 129;
  StatusSyntaxError = 2;
  StatusScriptUnreadable = 127;

type
  { Reads command lines: from the console with editing and history, or
    plainly from standard input. }
  TCommandReader = class
  private
    FOnConsole: Boolean;
    FEditor: TLineEditor;
    function ReadFromConsole(Continuation: Boolean; out Line: string): Boolean;
    function ReadFromInput(out Line: string): Boolean;
  public
    constructor Create(OnConsole: Boolean);
    destructor Destroy; override;
    { False at the end of input, or when a request to end the shell came
      (then ExitRequested is set). Continuation: the line goes on with a
      command already begun. }
    function ReadCommandLine(Continuation: Boolean; out Line: string): Boolean;
  end;

{ "fpos:/current/directory$ ", or "> " while a command continues. }
function MakePrompt(Continuation: Boolean): string;
var
  Directory: string;
begin
  if Continuation then
    Exit('> ');
  if CurrentDirectoryPath(Directory) <> ErrorNone then
    Directory := '?';
  Result := 'fpos:' + Directory + '$ ';
end;

function HistoryFilePath: string;
begin
  Result := VariableValue('HOME');
  if Result = '' then
    Result := '/';
  if Result[Length(Result)] <> '/' then
    Result := Result + '/';
  Result := Result + '.sh_history';
end;

{ Stopped jobs would wait forever once the shell is gone: they end as
  if the terminal had hung up (status 129). Running ones carry on. }
procedure EndStoppedJobs;
var
  Index: Integer;
  Job: TJob;
begin
  UpdateJobs;
  for Index := 0 to MaximumJobs - 1 do
  begin
    Job := JobInSlot(Index);
    if (Job <> nil) and (Job.State = JobStopped) then
      Job.Terminate(HangUpStatus);
  end;
end;

{ True if the shell was asked to end; Status is what it then ends with.
  Other notifications are not taken, so there are none. }
function TakeEndRequest(out Status: LongInt): Boolean;
var
  Notification: TAbiNotification;
begin
  Result := False;
  Status := 0;
  while ReceiveNotification(Notification) do
    if Notification.Kind = NotificationEndRequested then
    begin
      Result := True;
      Status := EndStatusOf(Notification.Reason);
    end;
end;

{ --- TCommandReader ---------------------------------------------------- }

constructor TCommandReader.Create(OnConsole: Boolean);
begin
  inherited Create;
  FOnConsole := OnConsole;
  if not OnConsole then
    Exit;
  FEditor := TLineEditor.Create(HistoryFilePath, StandardErrorHandle);
  { The prompt wakes for a request to end; one that comes while a
    command runs waits in the queue until the prompt. }
  TakeNotifications(NotifyEndRequests);
  FEditor.WakeHandle := NotificationsHandle;
end;

destructor TCommandReader.Destroy;
begin
  if FOnConsole then
  begin
    FEditor.SaveHistory;
    FEditor.Free;
  end;
  inherited Destroy;
end;

function TCommandReader.ReadFromInput(out Line: string): Boolean;
var
  HadLineEnd: Boolean;
begin
  Result := ReadTextLine(StandardInput, Line, HadLineEnd);
end;

function TCommandReader.ReadFromConsole(Continuation: Boolean; out Line: string): Boolean;
var
  EditResult: TEditResult;
  EndStatus: LongInt;
begin
  Line := '';
  repeat
    { "[1]+  Done  sleep 5" for jobs that ended since the last prompt. }
    if not Continuation then
      NotifyFinishedJobs;
    EditResult := FEditor.EditLine(MakePrompt(Continuation), Line);
    if EditResult = EditLineReady then
    begin
      FEditor.AddHistoryLine(Line);
      Exit(True);
    end;
    if (EditResult = EditWoken) and TakeEndRequest(EndStatus) then
    begin
      ExitRequested := True;
      RequestedExitCode := EndStatus;
      Exit(False);
    end;
  until EditResult <> EditWoken;
  Result := False;
end;

function TCommandReader.ReadCommandLine(Continuation: Boolean; out Line: string): Boolean;
begin
  if FOnConsole then
    Result := ReadFromConsole(Continuation, Line)
  else
    Result := ReadFromInput(Line);
end;

{ --- Running ----------------------------------------------------------- }

{ Reads and runs commands line by line until end of input or exit. A
  command spanning several lines (an open quote or an unfinished if,
  while, ...) is collected before it runs. On the console, lines are read
  with editing and history, and Ctrl-C does not end the shell. }
procedure RunInteractive(OnConsole: Boolean);
var
  Reader: TCommandReader;
  Pending: string;
  Line: string;
  Tree: TShellNode;
  Message: string;
begin
  if OnConsole then
  begin
    ShellIsInteractive := True;
    IgnoreInterrupts(True);
  end;
  Pending := '';
  Reader := TCommandReader.Create(OnConsole);
  try
    while not ExitRequested do
    begin
      if not Reader.ReadCommandLine(Pending <> '', Line) then
        Break;
      Pending := Pending + Line + #10;

      case ParseInput(Pending, Tree, Message) of
        ParseIncomplete:
          Continue;
        ParseSuccess:
          begin
            InterruptRequested := False;
            try
              ExecuteNode(Tree);
            finally
              Tree.Free;
            end;
          end;
      else
        begin
          ShellErrorWithoutFlush(Message);
          LastStatus := StatusSyntaxError;
        end;
      end;
      Pending := '';
    end;
    if (Pending <> '') and not ExitRequested then
    begin
      ShellErrorWithoutFlush('syntax error: unexpected end of input');
      LastStatus := StatusSyntaxError;
    end;
  finally
    Reader.Free;
  end;
  if OnConsole then
    EndStoppedJobs;
end;

procedure RunScriptFile(const Path: string);
var
  Text: string;
  Error: LongInt;
begin
  Error := ReadTextFile(Path, Text);
  if Error <> ErrorNone then
  begin
    WriteStringLine(StandardError, 'sh: ' + Path + ': ' + ErrorMessage(Error));
    Halt(StatusScriptUnreadable);
  end;
  ExecuteText(Text);
end;

procedure SetDefaultVariables;
var
  Directory: string;
begin
  if CurrentDirectoryPath(Directory) = ErrorNone then
    AssignVariable('PWD', Directory);
  if not VariableIsSet('PATH') then
    SetVariable('PATH', '/bin:/usr/local/bin');
end;

{ The program's arguments from First on. }
function ArgumentsFrom(First: Integer): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  if First >= ArgumentTotal then
    Exit;
  SetLength(Result, ArgumentTotal - First);
  for Index := First to ArgumentTotal - 1 do
    Result[Index - First] := string(Argument(Index));
end;

function StandardInputIsConsole: Boolean;
begin
  Result := KernelGetHandleKind(StandardInputHandle) = HandleKindConsole;
end;

var
  FirstArgument: string;
begin
  SetDefaultVariables;
  ScriptName := string(Argument(0));
  FirstArgument := '';
  if ArgumentTotal >= 2 then
    FirstArgument := string(Argument(1));

  if (ArgumentTotal >= 3) and (FirstArgument = '-c') then
  begin
    if ArgumentTotal >= 4 then
      ScriptName := string(Argument(3));
    SetPositionalParameters(ArgumentsFrom(4));
    ExecuteText(string(Argument(2)));
  end
  else if (ArgumentTotal = 2) and (FirstArgument = '-c') then
  begin
    WriteStringLine(StandardError, 'sh: -c: option requires an argument');
    Halt(StatusSyntaxError);
  end
  else if (ArgumentTotal = 2) and (FirstArgument = '-i') then
    RunInteractive(StandardInputIsConsole)
  else if ArgumentTotal >= 2 then
  begin
    ScriptName := FirstArgument;
    SetPositionalParameters(ArgumentsFrom(2));
    RunScriptFile(FirstArgument);
  end
  else
    RunInteractive(StandardInputIsConsole);

  if ExitRequested then
    Halt(RequestedExitCode);
  Halt(LastStatus);
end.
