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
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Sys.Processes;

const
  LoginNameCapacity = 64;
  LoginPathCapacity = 256;
  AutomaticLoginOption = 'autologin';

type
  TLoginAccount = record
    Name: array[0..LoginNameCapacity - 1] of Char;
    Identity: TAbiProcessIdentity;
    Home: array[0..LoginPathCapacity - 1] of Char;
    Shell: array[0..LoginPathCapacity - 1] of Char;
  end;

  { The environment a logged in user starts with. }
  TLoginEnvironment = record
    Texts: array[0..7] of array[0..LoginPathCapacity + 15] of Char;
    Values: array[0..8] of PChar;
  end;

{ The account named Name; False if there is no such user. }
function FindLoginAccount(Name: PChar; out Account: TLoginAccount): Boolean; overload;
function FindLoginAccount(const Name: string; out Account: TLoginAccount): Boolean; overload;
{ True if Password is the account's (or it needs none); False if it is
  wrong or the account is locked. }
function PasswordIsRight(const Account: TLoginAccount; Password: PChar): Boolean;
{ The user the kernel option autologin= names, into Name; False when
  none is named. }
function AutomaticLoginUser(Name: PChar; Capacity: PtrUInt): Boolean;
{ The same as a string. }
function AutomaticLoginName(out Name: string): Boolean;
{ Starts Path (with Arguments, nil terminated) as the account's user:
  its environment, in its home directory; the handles, group and
  session as Options say. A process handle, or minus an error. }
function StartAsUser(const Account: TLoginAccount; Path: PChar; Arguments: PPChar;
  var Options: TProcessOptions; var Environment: TLoginEnvironment): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.KernelOptions,
  Util.Accounts,
  Util.Passwords;

const
  DefaultTerminal = 'console';
  SearchPath = '/bin';

function FindLoginAccount(Name: PChar; out Account: TLoginAccount): Boolean;
var
  UserId: LongWord;
  GroupId: LongWord;
  Count: Integer;
  Text: PChar;
begin
  FillMemory(@Account, SizeOf(Account), 0);
  Result := False;
  if (Name = nil) or (Name^ = #0) or not FindUserId(Name, UserId) or (UserNameOf(UserId) = nil) then
    Exit;
  if not PrimaryGroupOf(UserId, GroupId) then
    GroupId := UserId;
  CopyText(@Account.Name[0], UserNameOf(UserId), LoginNameCapacity);
  Account.Identity.UserId := UserId;
  Account.Identity.GroupId := GroupId;
  Count := GroupsOfUser(UserId, @Account.Identity.Groups[0], MaximumSupplementaryGroups);
  Account.Identity.GroupCount := LongWord(Count);
  Text := HomeDirectoryOf(UserId);
  if (Text = nil) or (Text^ = #0) then
    Text := '/';
  CopyText(@Account.Home[0], Text, LoginPathCapacity);
  Text := ShellOf(UserId);
  if (Text = nil) or (Text^ = #0) then
    Text := '/bin/sh';
  CopyText(@Account.Shell[0], Text, LoginPathCapacity);
  Result := True;
end;

function PasswordIsRight(const Account: TLoginAccount; Password: PChar): Boolean;
begin
  if Password = nil then
    Password := '';
  Result := CheckPassword(@Account.Name[0], Password) = PasswordAccepted;
end;

function AutomaticLoginUser(Name: PChar; Capacity: PtrUInt): Boolean;
begin
  Result := GetKernelOption(AutomaticLoginOption, Name, Capacity) and (Name^ <> #0);
end;

procedure AddVariable(var Environment: TLoginEnvironment; var Count: Integer; Name, Value: PChar);
var
  NameLength: PtrUInt;
begin
  NameLength := TextLength(Name);
  CopyText(@Environment.Texts[Count][0], Name, LoginPathCapacity);
  Environment.Texts[Count][NameLength] := '=';
  CopyText(@Environment.Texts[Count][NameLength + 1], Value, LoginPathCapacity);
  Environment.Values[Count] := @Environment.Texts[Count][0];
  Inc(Count);
end;

procedure BuildEnvironment(const Account: TLoginAccount; var Environment: TLoginEnvironment);
var
  Count: Integer;
  Terminal: PChar;
begin
  Count := 0;
  Terminal := GetVariable('TERM');
  if (Terminal = nil) or (Terminal^ = #0) then
    Terminal := DefaultTerminal;
  AddVariable(Environment, Count, 'HOME', @Account.Home[0]);
  AddVariable(Environment, Count, 'SHELL', @Account.Shell[0]);
  AddVariable(Environment, Count, 'USER', @Account.Name[0]);
  AddVariable(Environment, Count, 'LOGNAME', @Account.Name[0]);
  AddVariable(Environment, Count, 'PATH', SearchPath);
  AddVariable(Environment, Count, 'TERM', Terminal);
  Environment.Values[Count] := nil;
end;

function StartAsUser(const Account: TLoginAccount; Path: PChar; Arguments: PPChar;
  var Options: TProcessOptions; var Environment: TLoginEnvironment): Int64;
begin
  BuildEnvironment(Account, Environment);
  Options.Environment := @Environment.Values[0];
  Options.WorkingDirectory := @Account.Home[0];
  Options.Identity := @Account.Identity;
  Result := StartProgram(Path, Arguments, Options);
end;

function FindLoginAccount(const Name: string; out Account: TLoginAccount): Boolean;
begin
  Result := FindLoginAccount(PChar(Name), Account);
end;

function AutomaticLoginName(out Name: string): Boolean;
var
  Buffer: array[0..LoginNameCapacity - 1] of Char;
begin
  Result := AutomaticLoginUser(@Buffer[0], LoginNameCapacity);
  if Result then
    Name := PChar(@Buffer[0])
  else
    Name := '';
end;

end.
