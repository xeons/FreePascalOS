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
  userdel - remove a user account

  userdel [-r] NAME

  Removes the account (its lines in /etc/passwd and /etc/shadow, its own
  group unless another user has it, its place in other groups); -r
  removes its home under /home too. Root's account cannot be removed.
  Root only (Util.AccountChanges, as the Control Panel through the
  system settings service).
}
program userdel;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Sys.Format,
  Util.Accounts,
  Util.AccountChanges,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: userdel [-r] NAME'#10 +
    'Remove the user NAME.'#10 +
    '  -r, --remove  remove the user''s home as well'#10;
  OptionRemove = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  RemoveHome: Boolean;
  Name: string;
  Error: LongInt;
begin
  RemoveHome := False;
  BeginOptions(Parser, [OptionDefinition('r', 'remove', False, OptionRemove)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionRemove then
      RemoveHome := True;
  if Parser.OperandCount <> 1 then
    FailWithUsageHint('one user name is needed', []);
  if CurrentUserId <> RootId then
    Fail(1, 'only root may remove users', []);
  Name := Parser.Operands[0];
  Error := RemoveUser(Name, RemoveHome);
  if Error = ErrorNotFound then
    Fail(1, 'user ''%s'' does not exist', [ArgumentText(PChar(Name))]);
  if Error = ErrorNotPermitted then
    Fail(1, 'the account ''%s'' cannot be removed', [ArgumentText(PChar(Name))]);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot remove user ''%s''', [ArgumentText(PChar(Name))]);
end.
