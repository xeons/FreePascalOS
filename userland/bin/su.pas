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
  su - run a command with a substitute user and group ID

  su [-] [-l] [-m] [-s SHELL] [-c COMMAND] [USER]

  Becomes USER (root by default) and runs its shell, or "SHELL -c
  COMMAND". Callers other than root must type USER's password (checked
  against /etc/shadow, see Util.Passwords); su is installed set-user-ID
  root so that it can read that file and change ids.

  HOME, SHELL, USER and LOGNAME are set for the new user unless -m is
  given; with - or -l the command starts in USER's home directory.
}
program su;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Environment,
  Sys.Errors,
  Sys.Kernel,
  Sys.Memory,
  Sys.Processes,
  Util.Accounts,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Passwords;

const
  Usage = 'Usage: su [OPTION]... [-] [USER]'#10 +
    'Change the effective user ID and group ID to that of USER (root by default).'#10#10 +
    '  -, -l, --login                 start in USER''s home directory'#10 +
    '  -c, --command=COMMAND          pass COMMAND to the shell with -c'#10 +
    '  -m, -p, --preserve-environment do not reset environment variables'#10 +
    '  -s, --shell=SHELL              run SHELL instead of USER''s shell'#10;

  OptionLogin = 1;
  OptionCommand = 2;
  OptionPreserve = 3;
  OptionShell = 4;
  MaximumGroups = 32;
  StatusFailed = 1;
  StatusCannotRun = 126;

var
  Login: Boolean;
  Preserve: Boolean;
  RunsCommand: Boolean;
  Command: string;
  HasShell: Boolean;
  Shell: string;
  TargetName: string;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  HasTargetName: Boolean;
begin
  Login := False;
  Preserve := False;
  CommandLine := TCommandLine.Create([
    CommandOption('l', 'login', False, OptionLogin),
    CommandOption('c', 'command', True, OptionCommand),
    CommandOption('m', 'preserve-environment', False, OptionPreserve),
    CommandOption('p', '', False, OptionPreserve),
    CommandOption('s', 'shell', True, OptionShell)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionLogin: Login := True;
      OptionCommand: Command := Value;
      OptionPreserve: Preserve := True;
      OptionShell: Shell := Value;
    end;
  RunsCommand := CommandLine.OptionGiven(OptionCommand);
  HasShell := CommandLine.OptionGiven(OptionShell);

  HasTargetName := False;
  for Operand in CommandLine.Operands do
  begin
    if Operand = '-' then
      Login := True
    else if not HasTargetName then
    begin
      TargetName := Operand;
      HasTargetName := True;
    end
    else
      FailWithUsageHint(Format('extra operand ''%s''', [Operand]));
  end;
  CommandLine.Free;
  if not HasTargetName then
    TargetName := 'root';
end;

{ Root may become anyone; others must know the password. The password
  stays in a heap block of its own that is wiped after the check. }
procedure Authenticate;
var
  Check: TPasswordCheck;
  Password: PChar;
begin
  if CurrentRealUserId = RootId then
    Exit;
  Check := CheckPassword(TargetName, '');
  if Check <> PasswordAccepted then
  begin
    Password := ReadPassword('Password: ');
    if Password = nil then
      Check := PasswordRejected
    else
    begin
      Check := CheckPassword(TargetName, Password);
      ForgetPassword(Password);
    end;
  end;
  if Check <> PasswordAccepted then
    Fail(StatusFailed, 'Authentication failure');
end;

procedure BecomeUser(TargetId, TargetGroup: LongWord);
var
  Groups: TIdArray;
begin
  Groups := GroupsOfUser(TargetId);
  if Length(Groups) > MaximumGroups then
    SetLength(Groups, MaximumGroups);
  if (KernelSetGroups(LongWord(Length(Groups)), PLongWord(Groups)) < 0) or
     (KernelSetGroupIds(TargetGroup, TargetGroup, TargetGroup) < 0) or
     (KernelSetUserIds(TargetId, TargetId, TargetId) < 0) then
    Fail(StatusFailed, 'cannot set user id: ' + ErrorText(ErrorNotPermitted));
end;

var
  TargetId: LongWord;
  TargetGroup: LongWord;
  AccountName: string;
  Home: string;
  Options: TProcessOptions;
begin
  ReadOptions;

  if not FindUserId(TargetName, TargetId) or not FindUserName(TargetId, AccountName) then
    Fail(StatusFailed, Format('user %s does not exist', [TargetName]));
  TargetName := AccountName;
  if not PrimaryGroupOf(TargetId, TargetGroup) then
    TargetGroup := TargetId;

  Authenticate;
  BecomeUser(TargetId, TargetGroup);

  if not HasShell then
    Shell := UserShell(TargetId);
  Home := UserHomeDirectory(TargetId);
  if not Preserve then
  begin
    SetVariable('HOME', PChar(Home));
    SetVariable('SHELL', PChar(Shell));
    SetVariable('USER', PChar(TargetName));
    SetVariable('LOGNAME', PChar(TargetName));
  end;

  DefaultProcessOptions(Options);
  if Login then
    Options.WorkingDirectory := PChar(Home);
  if RunsCommand then
    RunCommandAndExit([Shell, '-c', Command], Options)
  else
    RunCommandAndExit([Shell, '-i'], Options);
end.
