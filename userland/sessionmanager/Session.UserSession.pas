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
  A user's session on the screen: the desktop shell started as the user
  (Util.Logins: their ids and groups, their environment, their home) in
  a session of its own, so everything started from the desktop - the
  terminal and its shell, notepad, whatever they start - belongs to it.

  Ending the session (Log off, the session manager stopped or the
  system shutting down, or the desktop ending by itself) asks every
  program of it to end (Sys.Notifications, for the reason "log off", or
  "shutdown"), so programs with windows close them as if their user had
  - Notepad asks whether to save its text - and the others end or tidy
  up as they choose. The session is over once none of its programs runs
  (watched every PollMilliseconds); what still runs after
  EndTimeoutMilliseconds is ended outright, so nothing can keep the user
  from logging off or the system from shutting down. Then OnEnded is
  called.

  The display server is given the user's settings (the mouse's) before
  the desktop starts, and the system's when the session has ended
  (Session.UserSettings).
}
unit Session.UserSession;

{$mode objfpc}
{$H+}

interface

uses
  Util.Logins;

const
  DesktopProgram = '/bin/desktop';
  { How long the programs of a session have to end once asked: a user
    has this long to answer a program's question (save the changes?).
    The session service's stop-timeout is longer. }
  EndTimeoutMilliseconds = 8000;

type
  TSessionEndedEvent = procedure(ExitCode: LongInt) of object;

  TUserSession = class
  private
    FAccount: TLoginAccount;
    FEnvironment: TLoginEnvironment;
    FProcess: Int64;
    FSessionId: QWord;
    FDesktopExitCode: LongInt;
    FEnding: Boolean;
    FEndedOutright: Boolean;
    FDeadline: QWord;
    FTimer: Int64;
    FOnEnded: TSessionEndedEvent;
    procedure DesktopEnded(Handle: Int64);
    procedure TimerFired(Handle: Int64);
    procedure CheckWhetherOver;
    procedure Finish;
  public
    constructor Create;
    { Starts the desktop as Account's user; False if it could not start. }
    function Start(const Account: TLoginAccount): Boolean;
    { Asks every program of the session to end for Reason (EndReason*);
      OnEnded follows once none runs. }
    procedure EndFor(Reason: LongWord);
    { Log off: EndFor the reason "log off". }
    procedure LogOff;
    { Ends every program of the session outright (the display server is
      gone: nothing can be asked any more). }
    procedure EndNow;
    { A user is logged in (the session has not ended yet). }
    function IsActive: Boolean;
    function IsEnding: Boolean;
    { The user it runs as. }
    function UserId: LongWord;
    function UserName: string;
    property OnEnded: TSessionEndedEvent read FOnEnded write FOnEnded;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Notifications,
  Sys.Objects,
  Sys.Processes,
  Sys.Time,
  Windowing.HandleWatches,
  Session.UserSettings,
  Session.Report;

const
  PollMilliseconds = 100;

constructor TUserSession.Create;
begin
  inherited Create;
  FProcess := NoHandle;
  FTimer := NoHandle;
end;

function TUserSession.IsActive: Boolean;
begin
  Result := (FProcess <> NoHandle) or FEnding;
end;

function TUserSession.IsEnding: Boolean;
begin
  Result := FEnding;
end;

function TUserSession.UserId: LongWord;
begin
  Result := FAccount.Identity.UserId;
end;

function TUserSession.UserName: string;
begin
  Result := string(PChar(@FAccount.Name[0]));
end;

function TUserSession.Start(const Account: TLoginAccount): Boolean;
var
  Arguments: array[0..1] of PChar;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  if IsActive then
    Exit;
  FAccount := Account;
  ApplyUserSettings(UserName, string(PChar(@FAccount.Home[0])));
  Arguments[0] := DesktopProgram;
  Arguments[1] := nil;
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  Options.NewSession := True;
  Process := StartAsUser(FAccount, DesktopProgram, @Arguments[0], Options, FEnvironment);
  if Process < 0 then
  begin
    Say('cannot start the desktop for ' + UserName);
    ApplySystemSettings;
    Exit;
  end;
  FProcess := Process;
  FDesktopExitCode := -1;
  FEndedOutright := False;
  { The desktop leads the session: its id is the session's. }
  FSessionId := QWord(ProcessIdOf(Process));
  WatchHandle(FProcess, @DesktopEnded);
  Say(Format('%s logged in (session %d)', [UserName, FSessionId]));
  Result := True;
end;

procedure TUserSession.EndFor(Reason: LongWord);
begin
  if not IsActive or FEnding then
    Exit;
  FEnding := True;
  Say(Format('asking session %d to end (%s)', [FSessionId, EndReasonName(Reason)]));
  AskSessionToEnd(FSessionId, Reason);
  FDeadline := UptimeMilliseconds + EndTimeoutMilliseconds;
  FTimer := CreateTimer(False);
  if FTimer >= 0 then
  begin
    SetTimer(FTimer, PollMilliseconds, PollMilliseconds);
    WatchHandle(FTimer, @TimerFired);
  end;
end;

procedure TUserSession.LogOff;
begin
  if not IsActive or FEnding then
    Exit;
  Say('logging off ' + UserName);
  EndFor(EndReasonLogOff);
end;

procedure TUserSession.EndNow;
begin
  if IsActive then
    EndSession(FSessionId, EndStatusRequested);
end;

procedure TUserSession.DesktopEnded(Handle: Int64);
begin
  StopWatchingHandle(FProcess);
  if WaitForProgramWithTimeout(FProcess, 0, FDesktopExitCode) <> ErrorNone then
    FDesktopExitCode := -1;
  CloseHandle(FProcess);
  FProcess := NoHandle;
  { What the user left running goes with the desktop, asked first. }
  if not FEnding then
    EndFor(EndReasonLogOff);
  CheckWhetherOver;
end;

procedure TUserSession.TimerFired(Handle: Int64);
begin
  CheckWhetherOver;
end;

procedure TUserSession.CheckWhetherOver;
var
  Left: LongInt;
begin
  if not FEnding then
    Exit;
  Left := CountSessionProcesses(FSessionId);
  if (Left = 0) and (FProcess = NoHandle) then
  begin
    Finish;
    Exit;
  end;
  if not FEndedOutright and (UptimeMilliseconds >= FDeadline) then
  begin
    FEndedOutright := True;
    Say(Format('%d programs of session %d did not end in time: ending them', [Left, FSessionId]));
    EndSession(FSessionId, EndStatusRequested);
  end;
end;

procedure TUserSession.Finish;
begin
  if FTimer >= 0 then
  begin
    StopWatchingHandle(FTimer);
    CloseHandle(FTimer);
  end;
  FTimer := NoHandle;
  FEnding := False;
  Say(Format('session of %s ended (status %d)', [UserName, FDesktopExitCode]));
  ApplySystemSettings;
  if Assigned(FOnEnded) then
    FOnEnded(FDesktopExitCode);
end;

end.
