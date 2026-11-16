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
  groups - print the groups a user is in

  groups [USER]...
}
program groups;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: groups [USER]...'#10 +
    'Print group memberships for each USERNAME or, if no USERNAME is specified,'#10 +
    'for the current process.'#10;

procedure PrintGroupList(const Groups: TIdArray);
var
  Line: string;
  Index: Integer;
begin
  Line := '';
  for Index := 0 to High(Groups) do
  begin
    if Index > 0 then
      Line := Line + ' ';
    Line := Line + GroupNameOrNumber(Groups[Index]);
  end;
  PrintStringLine(Line);
end;

var
  CommandLine: TCommandLine;
  Operand: string;
  UserName: string;
  UserId: LongWord;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
  begin
    PrintGroupList(CurrentGroups);
    Halt(0);
  end;
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    if not FindUserId(Operand, UserId) or not FindUserName(UserId, UserName) then
    begin
      Report(Format('''%s'': no such user', [Operand]));
      ExitStatus := 1;
      Continue;
    end;
    PrintString(Operand + ' : ');
    PrintGroupList(GroupsOfUser(UserId));
  end;
  CommandLine.Free;
  Halt(ExitStatus);
end.
