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
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Util.Accounts,
  Util.Commands,
  Util.Messages,
  Util.Options,
  Util.Passwords;

const
  Usage: PChar = 'Usage: su [OPTION]... [-] [USER]'#10 +
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
  HasCommand: Boolean;
  Command: string;
  HasShell: Boolean;
  Shell: string;
  TargetName: string;

procedure ReadOptions;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  HasTargetName: Boolean;
begin
  Login := False;
  Preserve := False;
  HasCommand := False;
  HasShell := False;
  BeginOptions(Parser, [
    OptionDefinition('l', 'login', False, OptionLogin),
    OptionDefinition('c', 'command', True, OptionCommand),
    OptionDefinition('m', 'preserve-environment', False, OptionPreserve),
    OptionDefinition('p', nil, False, OptionPreserve),
    OptionDefinition('s', 'shell', True, OptionShell)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionLogin: Login := True;
      OptionCommand:
        begin
          Command := Value;
          HasCommand := True;
        end;
      OptionPreserve: Preserve := True;
      OptionShell:
        begin
          Shell := Value;
          HasShell := True;
        end;
    end;

  HasTargetName := False;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if string(Parser.Operands[Index]) = '-' then
      Login := True
    else if not HasTargetName then
    begin
      TargetName := Parser.Operands[Index];
      HasTargetName := True;
    end
    else
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[Index])]);
  end;
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
  Check := CheckPassword(PChar(TargetName), '');
  if Check <> PasswordAccepted then
  begin
    Password := ReadPassword('Password: ');
    if Password = nil then
      Check := PasswordRejected
    else
    begin
      Check := CheckPassword(PChar(TargetName), Password);
      ZeroMemory(Password, StrLen(Password));
      FreeMemory(Password);
    end;
  end;
  if Check <> PasswordAccepted then
    Fail(StatusFailed, 'Authentication failure', []);
end;

procedure BecomeUser(TargetId, TargetGroup: LongWord);
var
  Groups: array[0..MaximumGroups - 1] of LongWord;
  GroupCount: Integer;
begin
  GroupCount := GroupsOfUser(TargetId, @Groups[0], MaximumGroups);
  if (KernelSetGroups(LongWord(GroupCount), @Groups[0]) < 0) or
     (KernelSetGroupIds(TargetGroup, TargetGroup, TargetGroup) < 0) or
     (KernelSetUserIds(TargetId, TargetId, TargetId) < 0) then
    Fail(StatusFailed, 'cannot set user id: %s', [ArgumentText(ErrorMessage(ErrorNotPermitted))]);
end;

var
  TargetId: LongWord;
  TargetGroup: LongWord;
  Home: string;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
begin
  ReadOptions;

  if not FindUserId(PChar(TargetName), TargetId) or (UserNameOf(TargetId) = nil) then
    Fail(StatusFailed, 'user %s does not exist', [ArgumentText(PChar(TargetName))]);
  TargetName := UserNameOf(TargetId);
  if not PrimaryGroupOf(TargetId, TargetGroup) then
    TargetGroup := TargetId;

  Authenticate;
  BecomeUser(TargetId, TargetGroup);

  if not HasShell then
    Shell := ShellOf(TargetId);
  if HomeDirectoryOf(TargetId) <> nil then
    Home := HomeDirectoryOf(TargetId)
  else
    Home := '/';
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
  Arguments[0] := PChar(Shell);
  if HasCommand then
  begin
    Arguments[1] := '-c';
    Arguments[2] := PChar(Command);
    Arguments[3] := nil;
  end
  else
  begin
    Arguments[1] := '-i';
    Arguments[2] := nil;
  end;
  RunCommandAndExit(@Arguments[0], Options);
end.
