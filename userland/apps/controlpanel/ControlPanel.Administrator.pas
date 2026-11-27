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
  Making the changes only root may make, from a Control Panel run by
  anyone: they go to the system settings service (Sys.SystemSettings),
  which runs as root and decides who may.

  Root asks without a password. Anyone else is asked once for an
  administrator's password (root's, or their own if they are in
  "wheel"), which goes with every request after it until the Control
  Panel ends, so a change of time zone and a new user do not ask twice;
  a wrong one is asked for again (three times at most). The password is
  kept in the program's memory only, and never written anywhere.
}
unit ControlPanel.Administrator;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Sys.SystemSettings;

{ Sends Request as an administrator; ErrorNone, the service's refusal,
  or ErrorInterrupted when the question for the password was cancelled.
  Says "refused CODE ERROR" when the service refused. }
function SendAsAdministrator(Owner: TWindow; var Request: TSystemSettingsRequest): LongInt;
{ Sends Request with Password as the caller's proof (their own, for
  their own password or full name). }
function SendWithPassword(var Request: TSystemSettingsRequest; const Password: string): LongInt;
{ Sends a request that needs no password (the sound). }
function SendAsAnyone(var Request: TSystemSettingsRequest): LongInt;
{ A sentence saying why a request failed. }
function RefusalText(Error: LongInt): string;
function RunningAsRoot: Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Util.Accounts,
  ControlPanel.PasswordDialog,
  ControlPanel.Report;

const
  MaximumQuestions = 3;

var
  KnownPassword: string = '';
  HavePassword: Boolean = False;

function RunningAsRoot: Boolean;
begin
  Result := CurrentRealUserId = RootId;
end;

function SendWithPassword(var Request: TSystemSettingsRequest; const Password: string): LongInt;
begin
  SetRequestText(Request.Authorization, Password);
  Result := AskSystemSettings(Request);
  if Result <> ErrorNone then
    Say(Format('refused %d %d', [Request.Code, Result]));
end;

function SendAsAnyone(var Request: TSystemSettingsRequest): LongInt;
begin
  Result := SendWithPassword(Request, '');
end;

function SendAsAdministrator(Owner: TWindow; var Request: TSystemSettingsRequest): LongInt;
var
  Kept: TSystemSettingsRequest;
  Questions: LongInt;
  Password: string;
begin
  if RunningAsRoot then
    Exit(SendAsAnyone(Request));
  Kept := Request;
  if HavePassword then
  begin
    Result := SendWithPassword(Request, KnownPassword);
    if Result <> ErrorAccessDenied then
      Exit;
    HavePassword := False;
  end;
  Result := ErrorAccessDenied;
  Questions := 0;
  while (Result = ErrorAccessDenied) and (Questions < MaximumQuestions) do
  begin
    Inc(Questions);
    if not AskForPassword(Owner, 'Administrator', 'Type an administrator''s password to make this change.',
       Password) then
      Exit(ErrorInterrupted);
    Request := Kept;
    Result := SendWithPassword(Request, Password);
    if Result <> ErrorAccessDenied then
    begin
      KnownPassword := Password;
      HavePassword := Result = ErrorNone;
    end;
  end;
end;

function RefusalText(Error: LongInt): string;
begin
  case Error of
    ErrorAccessDenied: Result := 'The password is not right.';
    ErrorNotFound: Result := 'It does not exist, or the system settings service does not run.';
    ErrorExists: Result := 'It exists already.';
    ErrorInvalidArgument: Result := 'That is not a valid value.';
    ErrorNotPermitted: Result := 'That is not permitted.';
    ErrorBusy: Result := 'It is in use.';
  else
    Result := string(ErrorMessage(Error)) + '.';
  end;
end;

end.
