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
  Locking the user's session: the lock screen (Session.LockWindow) over
  everything, and the display server's lock (Windowing.ScreenLock), so
  no other program can show itself or take the keyboard meanwhile.

  The desktop asks for it (the Start menu's Lock, Super+L and
  Ctrl+Alt+L, through the port "session"), suspending asks for it first
  when the user's settings say so, and it happens by itself after the
  minutes without input the user's settings name (Windowing.LockSettings,
  looked at every IdleCheckMilliseconds; the server says how long the
  input has been idle). The right password - checked against
  /etc/shadow as the login window checks it (Util.Logins), from the
  password box's buffer and never a string - unlocks the screen. When
  the session ends (logged off, the system shutting down) the screen is
  unlocked for the login window.
}
unit Session.ScreenLock;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Settings,
  Session.UserSession,
  Session.LockWindow;

const
  IdleCheckMilliseconds = 5000;

type
  TScreenLock = class
  private
    FSession: TUserSession;
    FWindow: TLockWindow;
    FLocked: Boolean;
    FIdleTimer: Int64;
    { The user's settings, kept while their session lasts. }
    FStore: TSettings;
    FStoreHome: string;
    function UnlockAttempted(Password: PChar): Boolean;
    procedure IdleTimerFired(Handle: Int64);
    function UserSettings: TSettings;
  public
    constructor Create(Session: TUserSession);
    destructor Destroy; override;
    { Locks the session's screen (Reason for the log); False if there is
      no session to lock or the server refused. }
    function Lock(const Reason: string): Boolean;
    { The session is over: the screen is unlocked without a password. }
    procedure Release;
    { The user wants the screen locked before suspending. }
    function LocksOnResume: Boolean;
    property Locked: Boolean read FLocked;
  end;

implementation

uses
  SysUtils,
  Sys.Objects,
  Util.Logins,
  Configuration.Locations,
  Windowing.HandleWatches,
  Windowing.ScreenLock,
  Windowing.LockSettings,
  Session.Report;

constructor TScreenLock.Create(Session: TUserSession);
begin
  inherited Create;
  FSession := Session;
  FIdleTimer := CreateTimer(False);
  if FIdleTimer >= 0 then
  begin
    SetTimer(FIdleTimer, IdleCheckMilliseconds, IdleCheckMilliseconds);
    WatchHandle(FIdleTimer, @IdleTimerFired);
  end;
end;

destructor TScreenLock.Destroy;
begin
  if FIdleTimer >= 0 then
  begin
    StopWatchingHandle(FIdleTimer);
    CloseHandle(FIdleTimer);
  end;
  FStore.Free;
  inherited Destroy;
end;

function TScreenLock.UserSettings: TSettings;
begin
  if (FStore = nil) or (FStoreHome <> FSession.Account.Home) then
  begin
    FStore.Free;
    FStoreHome := FSession.Account.Home;
    FStore := OpenSettingsOfHome(FStoreHome);
  end;
  Result := FStore;
end;

function TScreenLock.Lock(const Reason: string): Boolean;
begin
  Result := FLocked;
  if FLocked or not FSession.IsActive or FSession.IsEnding then
    Exit;
  if FWindow = nil then
  begin
    FWindow := TLockWindow.Create;
    FWindow.OnUnlock := @UnlockAttempted;
  end;
  FWindow.Present(FSession.UserName);
  if not LockScreen(True) then
  begin
    Say('the display server did not lock the screen');
    FWindow.Hide;
    Exit(False);
  end;
  FLocked := True;
  Say(Format('screen locked (%s)', [Reason]));
  Result := True;
end;

function TScreenLock.UnlockAttempted(Password: PChar): Boolean;
begin
  Result := FLocked and FSession.IsActive and PasswordIsRight(FSession.Account, Password);
  if not Result then
  begin
    Say('unlock refused for ' + FSession.UserName);
    Exit;
  end;
  FWindow.Hide;
  LockScreen(False);
  FLocked := False;
  Say('screen unlocked by ' + FSession.UserName);
end;

procedure TScreenLock.Release;
begin
  FreeAndNil(FStore);
  if not FLocked then
    Exit;
  FWindow.Hide;
  LockScreen(False);
  FLocked := False;
  Say('screen unlocked: the session ended');
end;

function TScreenLock.LocksOnResume: Boolean;
begin
  Result := FSession.IsActive and RememberedLockSettings(UserSettings).OnResume;
end;

procedure TScreenLock.IdleTimerFired(Handle: Int64);
var
  Settings: TLockSettings;
  Idle: Int64;
begin
  if FLocked or not FSession.IsActive or FSession.IsEnding then
    Exit;
  Settings := RememberedLockSettings(UserSettings);
  if Settings.AfterMinutes = 0 then
    Exit;
  Idle := IdleMilliseconds;
  if Idle >= Int64(Settings.AfterMinutes) * 60000 then
    Lock('idle');
end;

end.
