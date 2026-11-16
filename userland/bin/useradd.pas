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
  useradd - add a user account

  useradd [-c FULL-NAME] [-a] NAME

  Asks for the new user's password twice (on the terminal without echo,
  or two lines of standard input), then adds the account as
  Util.AccountChanges does: the next free id from 1000, a group of the
  same name, the home /home/NAME (theirs, mode 755), /bin/sh. -a makes
  the user an administrator (a member of "wheel"). Root only; the
  Control Panel adds users through the system settings service, with
  the same routines.
}
program useradd;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Memory,
  Util.Accounts,
  Util.AccountChanges,
  Util.CommandLine,
  Util.Messages,
  Util.Passwords;

const
  Usage = 'Usage: useradd [-c FULL-NAME] [-a] NAME'#10 +
    'Add the user NAME, asking for their password.'#10 +
    '  -c, --comment FULL-NAME  the user''s full name'#10 +
    '  -a, --administrator      make the user an administrator (group wheel)'#10;
  OptionComment = 1;
  OptionAdministrator = 2;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  FullName: string;
  Administrator: Boolean;
  Name: string;
  NewPassword: PChar;
  Repeated: PChar;
  Error: LongInt;
begin
  FullName := '';
  Administrator := False;
  CommandLine := TCommandLine.Create([CommandOption('c', 'comment', True, OptionComment),
    CommandOption('a', 'administrator', False, OptionAdministrator)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionComment: FullName := Value;
      OptionAdministrator: Administrator := True;
    end;
  if CommandLine.OperandCount <> 1 then
    FailWithUsageHint('one user name is needed');
  if CurrentUserId <> RootId then
    Fail(1, 'only root may add users');
  Name := CommandLine.Operands[0];
  if not IsValidUserName(Name) then
    Fail(1, Format('invalid user name ''%s''', [Name]));
  if not IsValidFullName(FullName) then
    Fail(1, 'a full name may not hold a colon');
  NewPassword := ReadPassword('New password: ');
  Repeated := ReadPassword('Retype new password: ');
  if (NewPassword = nil) or (Repeated = nil) or (StrComp(NewPassword, Repeated) <> 0) then
  begin
    ForgetPassword(NewPassword);
    ForgetPassword(Repeated);
    Fail(1, 'Passwords do not match');
  end;
  Error := AddUser(Name, FullName, NewPassword, Administrator);
  ForgetPassword(NewPassword);
  ForgetPassword(Repeated);
  if Error = ErrorExists then
    Fail(1, Format('user ''%s'' already exists', [Name]));
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('cannot add user ''%s''', [Name]));
end.
