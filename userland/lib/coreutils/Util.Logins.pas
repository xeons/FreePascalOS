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
  Logging a user in: who the user is (Util.Accounts: the user and group
  ids, the supplementary groups from /etc/group, the home directory and
  the shell), whether the password is right (Util.Passwords), and the
  first program started as that user, with a fresh environment (HOME,
  SHELL, USER, LOGNAME, PATH and TERM) in the home directory. The
  program is started with the user's identity by the kernel
  (TAbiProcessIdentity), so the caller - login on the console, the
  session manager on the screen, both root - stays root and sees the
  program end.

  The kernel option autologin=USER names a user logged in without a
  password: by login -a on the console in text mode, and by the session
  manager for the first session of a boot.
}
unit Util.Logins;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.Processes;

const
  AutomaticLoginOption = 'autologin';

type
  TLoginAccount = record
    Name: string;
    Identity: TAbiProcessIdentity;
    Home: string;
    Shell: string;
  end;

{ The account named Name; False if there is no such user. }
function FindLoginAccount(const Name: string; out Account: TLoginAccount): Boolean;
{ True if Password is the account's (or it needs none); False if it is
  wrong or the account is locked. nil counts as empty. }
function PasswordIsRight(const Account: TLoginAccount; Password: PChar): Boolean;
{ The user the kernel option autologin= names; False when none is
  named. }
function AutomaticLoginName(out Name: string): Boolean;
{ Starts Arguments[0] (with Arguments) as the account's user: its
  environment, in its home directory; the handles, group and session as
  Options say. A process handle, or minus an error. }
function StartAsUser(const Account: TLoginAccount; const Arguments: array of string;
  const Options: TProcessOptions): Int64;
{ The same with Variables ("NAME=value") added to the user's
  environment, replacing those of the same name (the SSH server's TERM,
  SSH_CONNECTION, LANG, ...). }
function StartAsUserWithVariables(const Account: TLoginAccount; const Arguments: array of string;
  const Variables: array of string; const Options: TProcessOptions): Int64;

implementation

uses
  SysUtils,
  Sys.Environment,
  Sys.KernelOptions,
  Util.Accounts,
  Util.Commands,
  Util.Passwords;

const
  DefaultTerminal = 'console';
  SearchPath = '/bin:/usr/local/bin';

function FindLoginAccount(const Name: string; out Account: TLoginAccount): Boolean;
var
  UserId: LongWord;
  GroupId: LongWord;
  Groups: TIdArray;
  Index: Integer;
begin
  Account := Default(TLoginAccount);
  Result := False;
  if (Name = '') or not FindUserId(Name, UserId) or not FindUserName(UserId, Account.Name) then
    Exit;
  if not PrimaryGroupOf(UserId, GroupId) then
    GroupId := UserId;
  Account.Identity.UserId := UserId;
  Account.Identity.GroupId := GroupId;
  Groups := GroupsOfUser(UserId);
  if Length(Groups) > MaximumSupplementaryGroups then
    SetLength(Groups, MaximumSupplementaryGroups);
  for Index := 0 to High(Groups) do
    Account.Identity.Groups[Index] := Groups[Index];
  Account.Identity.GroupCount := LongWord(Length(Groups));
  Account.Home := UserHomeDirectory(UserId);
  if Account.Home = '' then
    Account.Home := '/';
  Account.Shell := UserShell(UserId);
  if Account.Shell = '' then
    Account.Shell := '/bin/sh';
  Result := True;
end;

function PasswordIsRight(const Account: TLoginAccount; Password: PChar): Boolean;
begin
  if Password = nil then
    Password := '';
  Result := CheckPassword(Account.Name, Password) = PasswordAccepted;
end;

function AutomaticLoginName(out Name: string): Boolean;
begin
  Result := GetKernelOption(AutomaticLoginOption, Name) and (Name <> '');
end;

{ The environment a logged in user starts with: NAME=value texts. }
function LoginEnvironment(const Account: TLoginAccount): TStringArray;
var
  Terminal: string;
begin
  Terminal := GetVariable('TERM');
  if Terminal = '' then
    Terminal := DefaultTerminal;
  Result := nil;
  SetLength(Result, 6);
  Result[0] := 'HOME=' + Account.Home;
  Result[1] := 'SHELL=' + Account.Shell;
  Result[2] := 'USER=' + Account.Name;
  Result[3] := 'LOGNAME=' + Account.Name;
  Result[4] := 'PATH=' + SearchPath;
  Result[5] := 'TERM=' + Terminal;
end;

{ Sets NAME=value in Environment, in place of a variable of that name. }
procedure PutVariable(var Environment: TStringArray; const Assignment: string);
var
  NameLength: Integer;
  Index: Integer;
begin
  NameLength := Pos('=', Assignment);
  if NameLength <= 1 then
    Exit;
  for Index := 0 to High(Environment) do
    if Copy(Environment[Index], 1, NameLength) = Copy(Assignment, 1, NameLength) then
    begin
      Environment[Index] := Assignment;
      Exit;
    end;
  SetLength(Environment, Length(Environment) + 1);
  Environment[High(Environment)] := Assignment;
end;

function StartWithEnvironment(const Account: TLoginAccount; const Arguments: array of string;
  const Environment: TStringArray; const Options: TProcessOptions): Int64;
var
  EnvironmentVector: TTextVector;
  ArgumentVector: TTextVector;
  UserOptions: TProcessOptions;
begin
  EnvironmentVector := TextVector(Environment);
  ArgumentVector := TextVector(Arguments);
  UserOptions := Options;
  UserOptions.Environment := @EnvironmentVector[0];
  UserOptions.WorkingDirectory := PChar(Account.Home);
  UserOptions.Identity := @Account.Identity;
  Result := StartProgram(ArgumentVector[0], @ArgumentVector[0], UserOptions);
end;

function StartAsUser(const Account: TLoginAccount; const Arguments: array of string;
  const Options: TProcessOptions): Int64;
begin
  Result := StartWithEnvironment(Account, Arguments, LoginEnvironment(Account), Options);
end;

function StartAsUserWithVariables(const Account: TLoginAccount; const Arguments: array of string;
  const Variables: array of string; const Options: TProcessOptions): Int64;
var
  Environment: TStringArray;
  Index: Integer;
begin
  Environment := LoginEnvironment(Account);
  for Index := 0 to High(Variables) do
    PutVariable(Environment, Variables[Index]);
  Result := StartWithEnvironment(Account, Arguments, Environment, Options);
end;

end.
