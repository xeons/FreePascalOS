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

  The session lasts as long as the desktop: when the desktop ends (Log
  off, or it failed), whatever is left of the session is ended too, and
  OnEnded is called. Logging off ends the whole session at once.
}
unit Session.UserSession;

{$mode objfpc}
{$H+}

interface

uses
  Util.Logins;

const
  DesktopProgram = '/bin/desktop';

type
  TSessionEndedEvent = procedure(ExitCode: LongInt) of object;

  TUserSession = class
  private
    FAccount: TLoginAccount;
    FEnvironment: TLoginEnvironment;
    FProcess: Int64;
    FSessionId: QWord;
    FOnEnded: TSessionEndedEvent;
    procedure DesktopEnded(Handle: Int64);
  public
    constructor Create;
    { Starts the desktop as Account's user; False if it could not start. }
    function Start(const Account: TLoginAccount): Boolean;
    { Ends every program of the session (the desktop's end follows). }
    procedure LogOff;
    function IsActive: Boolean;
    { The user it runs as. }
    function UserId: LongWord;
    function UserName: string;
    property OnEnded: TSessionEndedEvent read FOnEnded write FOnEnded;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Windowing.HandleWatches,
  Session.Report;

const
  { The exit status of an ended program (128 + SIGTERM's number). }
  EndedExitCode = 143;

constructor TUserSession.Create;
begin
  inherited Create;
  FProcess := NoHandle;
end;

function TUserSession.IsActive: Boolean;
begin
  Result := FProcess <> NoHandle;
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
  Arguments[0] := DesktopProgram;
  Arguments[1] := nil;
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  Options.NewSession := True;
  Process := StartAsUser(FAccount, DesktopProgram, @Arguments[0], Options, FEnvironment);
  if Process < 0 then
  begin
    Say('cannot start the desktop for ' + UserName);
    Exit;
  end;
  FProcess := Process;
  { The desktop leads the session: its id is the session's. }
  FSessionId := QWord(ProcessIdOf(Process));
  WatchHandle(FProcess, @DesktopEnded);
  Say(Format('%s logged in (session %d)', [UserName, FSessionId]));
  Result := True;
end;

procedure TUserSession.LogOff;
begin
  if not IsActive then
    Exit;
  Say('logging off ' + UserName);
  EndSession(FSessionId, EndedExitCode);
end;

procedure TUserSession.DesktopEnded(Handle: Int64);
var
  ExitCode: LongInt;
begin
  StopWatchingHandle(FProcess);
  if WaitForProgramWithTimeout(FProcess, 0, ExitCode) <> ErrorNone then
    ExitCode := -1;
  CloseHandle(FProcess);
  FProcess := NoHandle;
  { What the user left running goes with the desktop. }
  EndSession(FSessionId, EndedExitCode);
  Say(Format('session of %s ended (status %d)', [UserName, ExitCode]));
  if Assigned(FOnEnded) then
    FOnEnded(ExitCode);
end;

end.
