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
  sessionmanager - logs users in on the screen and runs their desktop

  sessionmanager

  The graphical mode's session service (/etc/services/session.service),
  started once the display server is ready. It shows the login window
  (a user name and a password, checked against /etc/shadow); on success
  it starts the desktop shell as that user, in a session of its own.
  Log off on the desktop's Start menu (which asks here) asks every
  program of the session to end, so they can save their work (Notepad
  asks about unsaved text); what still runs after a few seconds is ended
  outright (Session.UserSession). When the session is over - after Log
  off, or when the desktop ended by itself and the rest went the same
  way - the login window comes back. The kernel option autologin=USER
  logs USER in without asking for the first session of a boot (after
  logging off, the window asks).

  Asked to end itself (its service stopped, the system shutting down),
  it ends the user's session the same way first (telling the programs
  the reason: shutdown, or log off), then ends.

  It serves the port "session" for the desktop: log off, shut down and
  restart (see Session.Requests). Runs as root, as it starts programs as
  other users and may turn the computer off.

  Prints (to its log, /var/log/session.log, which the desktop's lines go
  to as well): "session: login window shown" with the places of its
  boxes and button ("session: place login-user-name X Y", login-password,
  login-ok), "session: login refused for NAME", "session: NAME logged in
  (session N)", "session: logging off NAME", "session: asking session N
  to end (REASON)", "session: C programs of session N did not end in
  time: ending them", "session: session of NAME ended (status S)",
  "session: shutting down", "session: asked to end (REASON)".

  Its units are in userland/sessionmanager: Session.LoginWindow,
  Session.UserSession, Session.Requests and Session.Report.
}
program sessionmanager;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Util.Accounts,
  Util.Logins,
  Util.Messages,
  Sys.Notifications,
  Windowing.Connection,
  Windowing.EndRequests,
  Windowing.Windows,
  Session.LoginWindow,
  Session.Report,
  Session.Requests,
  Session.UserSession;

type
  TSessionManager = class
  private
    FWindow: TLoginWindow;
    FSession: TUserSession;
    FQuitting: Boolean;
    function LoginAttempted(const Name, Password: string): Boolean;
    procedure SessionEnded(ExitCode: LongInt);
    function StartSessionOf(const Name: string): Boolean;
    procedure EndRequested(Reason: LongWord);
  public
    constructor Create;
    { Logs the automatic user in, or asks. }
    procedure Start;
    property Session: TUserSession read FSession;
    { It was asked to end, and has (or the session is ending first). }
    property Quitting: Boolean read FQuitting;
  end;

constructor TSessionManager.Create;
begin
  inherited Create;
  FSession := TUserSession.Create;
  FSession.OnEnded := @SessionEnded;
  FWindow := TLoginWindow.Create;
  FWindow.OnLogin := @LoginAttempted;
  OnEndRequested := @EndRequested;
end;

{ The user's programs hear that the system shuts down, or that their
  session ends (the service was stopped, or someone asked). }
procedure TSessionManager.EndRequested(Reason: LongWord);
begin
  Say('asked to end (' + EndReasonName(Reason) + ')');
  FQuitting := True;
  if not FSession.IsActive then
  begin
    QuitMessageLoop(0);
    Exit;
  end;
  if Reason = EndReasonShutdown then
    FSession.EndFor(EndReasonShutdown)
  else
    FSession.EndFor(EndReasonLogOff);
end;

function TSessionManager.StartSessionOf(const Name: string): Boolean;
var
  Account: TLoginAccount;
begin
  Result := FindLoginAccount(PChar(Name), Account) and FSession.Start(Account);
end;

function TSessionManager.LoginAttempted(const Name, Password: string): Boolean;
var
  Account: TLoginAccount;
begin
  Result := FindLoginAccount(PChar(Name), Account) and PasswordIsRight(Account, PChar(Password));
  if not Result then
  begin
    Say('login refused for ' + Name);
    Exit;
  end;
  FWindow.Hide;
  Result := FSession.Start(Account);
  if not Result then
    FWindow.Present;
end;

procedure TSessionManager.SessionEnded(ExitCode: LongInt);
begin
  if FQuitting then
    QuitMessageLoop(0)
  else
    FWindow.Present;
end;

procedure TSessionManager.Start;
var
  AutomaticName: array[0..LoginNameCapacity - 1] of Char;
begin
  if AutomaticLoginUser(@AutomaticName[0], LoginNameCapacity) then
  begin
    Say('logging ' + string(PChar(@AutomaticName[0])) + ' in automatically');
    if StartSessionOf(string(PChar(@AutomaticName[0]))) then
      Exit;
  end;
  FWindow.Present;
end;

var
  Manager: TSessionManager;
  Error: LongInt;
begin
  if CurrentUserId <> RootId then
    Fail(1, 'only root may run the session manager', []);
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  { The login window comes and goes; the manager stays. }
  QuitWhenLastWindowCloses := False;
  Manager := TSessionManager.Create;
  if not OpenSessionPort(Manager.Session) then
    Fail(1, 'another session manager is running', []);
  Manager.Start;
  RunMessageLoop;
  if Manager.Quitting then
    Halt(0);
  { Otherwise the display server has gone: the user's programs cannot go
    on without it, and the service manager starts this one again (a
    failure) once the server is back. }
  Manager.Session.EndNow;
  Halt(1);
end.
