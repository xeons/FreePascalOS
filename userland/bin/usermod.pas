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
  usermod - change a user account

  usermod [-c FULL-NAME] [-G GROUP,...] [-a] NAME

  -c sets the user's full name; -G makes the listed groups the user's
  supplementary groups (their primary group stays), or with -a adds
  them to the ones they have. Root only (Util.AccountChanges; passwords
  are changed with passwd).
}
program usermod;

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
  Usage: PChar = 'Usage: usermod [-c FULL-NAME] [-G GROUP,...] [-a] NAME'#10 +
    'Change the user NAME.'#10 +
    '  -c, --comment FULL-NAME  the user''s full name'#10 +
    '  -G, --groups GROUP,...   the user''s supplementary groups'#10 +
    '  -a, --append             add the groups of -G to the user''s'#10;
  OptionComment = 1;
  OptionGroups = 2;
  OptionAppend = 3;

procedure Check(Error: LongInt; const Name: string);
begin
  if Error = ErrorNotFound then
    Fail(1, 'user ''%s'' or one of the groups does not exist', [ArgumentText(PChar(Name))]);
  if Error = ErrorInvalidArgument then
    Fail(1, 'a full name may not hold a colon', []);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot change user ''%s''', [ArgumentText(PChar(Name))]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  FullName: string;
  HasFullName: Boolean;
  GroupText: string;
  HasGroups: Boolean;
  Append: Boolean;
  Name: string;
  Groups: TGroupNames;
  Added: TGroupNames;
  Index: Integer;
begin
  HasFullName := False;
  HasGroups := False;
  Append := False;
  BeginOptions(Parser, [OptionDefinition('c', 'comment', True, OptionComment),
    OptionDefinition('G', 'groups', True, OptionGroups),
    OptionDefinition('a', 'append', False, OptionAppend)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionComment:
        begin
          FullName := Value;
          HasFullName := True;
        end;
      OptionGroups:
        begin
          GroupText := Value;
          HasGroups := True;
        end;
      OptionAppend: Append := True;
    end;
  if Parser.OperandCount <> 1 then
    FailWithUsageHint('one user name is needed', []);
  if CurrentUserId <> RootId then
    Fail(1, 'only root may change users', []);
  Name := Parser.Operands[0];
  if HasFullName then
    Check(ChangeFullName(Name, FullName), Name);
  if HasGroups then
  begin
    Groups := SplitGroupList(GroupText);
    if Append then
    begin
      Added := Groups;
      Groups := SupplementaryGroupsOf(Name);
      for Index := 0 to High(Added) do
      begin
        SetLength(Groups, Length(Groups) + 1);
        Groups[High(Groups)] := Added[Index];
      end;
    end;
    Check(ChangeGroups(Name, Groups), Name);
  end;
end.
