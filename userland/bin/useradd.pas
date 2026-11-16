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
  Sys.Format,
  Util.Accounts,
  Util.AccountChanges,
  Util.Messages,
  Util.Options,
  Util.Passwords;

const
  Usage: PChar = 'Usage: useradd [-c FULL-NAME] [-a] NAME'#10 +
    'Add the user NAME, asking for their password.'#10 +
    '  -c, --comment FULL-NAME  the user''s full name'#10 +
    '  -a, --administrator      make the user an administrator (group wheel)'#10;
  OptionComment = 1;
  OptionAdministrator = 2;

{ Passwords stay in heap PChars (not reference counted strings, which
  leave copies behind) so they can be wiped once used. }
procedure Forget(var Text: PChar);
begin
  if Text = nil then
    Exit;
  ZeroMemory(Text, StrLen(Text));
  FreeMemory(Text);
  Text := nil;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  FullName: string;
  Administrator: Boolean;
  Name: string;
  NewPassword: PChar;
  Repeated: PChar;
  Error: LongInt;
begin
  FullName := '';
  Administrator := False;
  BeginOptions(Parser, [OptionDefinition('c', 'comment', True, OptionComment),
    OptionDefinition('a', 'administrator', False, OptionAdministrator)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionComment: FullName := Value;
      OptionAdministrator: Administrator := True;
    end;
  if Parser.OperandCount <> 1 then
    FailWithUsageHint('one user name is needed', []);
  if CurrentUserId <> RootId then
    Fail(1, 'only root may add users', []);
  Name := Parser.Operands[0];
  if not IsValidUserName(Name) then
    Fail(1, 'invalid user name ''%s''', [ArgumentText(PChar(Name))]);
  if not IsValidFullName(FullName) then
    Fail(1, 'a full name may not hold a colon', []);
  NewPassword := ReadPassword('New password: ');
  Repeated := ReadPassword('Retype new password: ');
  if (NewPassword = nil) or (Repeated = nil) or (StrComp(NewPassword, Repeated) <> 0) then
  begin
    Forget(NewPassword);
    Forget(Repeated);
    Fail(1, 'Passwords do not match', []);
  end;
  Error := AddUser(Name, FullName, NewPassword, Administrator);
  Forget(NewPassword);
  Forget(Repeated);
  if Error = ErrorExists then
    Fail(1, 'user ''%s'' already exists', [ArgumentText(PChar(Name))]);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot add user ''%s''', [ArgumentText(PChar(Name))]);
end.
