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
  id - print real and effective user and group IDs

  id [-ugGnr] [USER]

  Without USER this describes the running process: its effective ids
  (real ones with -r), and euid=/egid= when they differ from the real.
}
program id;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: id [OPTION]... [USER]'#10 +
    'Print user and group information for the specified USER,'#10 +
    'or (when USER omitted) for the current user.'#10#10 +
    '  -g, --group     print only the effective group ID'#10 +
    '  -G, --groups    print all group IDs'#10 +
    '  -n, --name      print a name instead of a number, for -ugG'#10 +
    '  -r, --real      print the real ID instead of the effective ID, with -ugG'#10 +
    '  -u, --user      print only the effective user ID'#10 +
    '  -z, --zero      delimit entries with NUL characters, not whitespace'#10;

  OptionGroup = 1;
  OptionGroups = 2;
  OptionName = 3;
  OptionReal = 4;
  OptionUser = 5;
  OptionZero = 6;

{ The name (with AsName, when there is one) or the number. }
function IdentifierText(Id: LongWord; HasName: Boolean; const Name: string; AsName: Boolean): string;
begin
  if AsName and HasName then
    Result := Name
  else
    Result := IntToStr(Id);
end;

function UserIdentifier(UserId: LongWord; AsName: Boolean): string;
var
  Name: string;
begin
  Result := IdentifierText(UserId, FindUserName(UserId, Name), Name, AsName);
end;

function GroupIdentifier(GroupId: LongWord; AsName: Boolean): string;
var
  Name: string;
begin
  Result := IdentifierText(GroupId, FindGroupName(GroupId, Name), Name, AsName);
end;

{ "1000(name)", or just the number when there is no name. }
function NumberAndName(Id: LongWord; HasName: Boolean; const Name: string): string;
begin
  Result := IntToStr(Id);
  if HasName then
    Result := Result + '(' + Name + ')';
end;

function UserNumberAndName(UserId: LongWord): string;
var
  Name: string;
begin
  Result := NumberAndName(UserId, FindUserName(UserId, Name), Name);
end;

function GroupNumberAndName(GroupId: LongWord): string;
var
  Name: string;
begin
  Result := NumberAndName(GroupId, FindGroupName(GroupId, Name), Name);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Selection: Integer;
  AsName: Boolean;
  Separator: Char;
  UserId: LongWord;
  GroupId: LongWord;
  UserName: string;
  Groups: TIdArray;
  Index: Integer;
  RealIds: Boolean;
  ForProcess: Boolean;
  Line: string;
begin
  RealIds := False;
  ForProcess := False;
  Selection := 0;
  AsName := False;
  Separator := ' ';
  CommandLine := TCommandLine.Create([
    CommandOption('g', 'group', False, OptionGroup),
    CommandOption('G', 'groups', False, OptionGroups),
    CommandOption('n', 'name', False, OptionName),
    CommandOption('r', 'real', False, OptionReal),
    CommandOption('u', 'user', False, OptionUser),
    CommandOption('z', 'zero', False, OptionZero)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionGroup, OptionGroups, OptionUser:
        begin
          if (Selection <> 0) and (Selection <> Code) then
            FailWithUsageHint('cannot print "only" of more than one choice');
          Selection := Code;
        end;
      OptionName: AsName := True;
      OptionReal: RealIds := True;
      OptionZero: Separator := #0;
    end;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));

  if CommandLine.OperandCount = 1 then
  begin
    if not FindUserId(CommandLine.Operands[0], UserId) or not FindUserName(UserId, UserName) then
      Fail(1, Format('''%s'': no such user', [CommandLine.Operands[0]]));
    if not PrimaryGroupOf(UserId, GroupId) then
      GroupId := 0;
  end
  else
  begin
    ForProcess := True;
    UserId := CurrentUserId;
    GroupId := CurrentGroupId;
    { The plain form shows the real ids first, as GNU id does. }
    if RealIds or (Selection = 0) then
    begin
      UserId := CurrentRealUserId;
      GroupId := CurrentRealGroupId;
    end;
  end;
  if ForProcess then
    Groups := CurrentGroups
  else
    Groups := GroupsOfUser(UserId);
  if Length(Groups) = 0 then
    Groups := [GroupId];

  Line := '';
  case Selection of
    OptionUser: Line := UserIdentifier(UserId, AsName);
    OptionGroup: Line := GroupIdentifier(GroupId, AsName);
    OptionGroups:
      for Index := 0 to High(Groups) do
      begin
        if Index > 0 then
          Line := Line + Separator;
        Line := Line + GroupIdentifier(Groups[Index], AsName);
      end;
  else
    begin
      Line := 'uid=' + UserNumberAndName(UserId) + ' gid=' + GroupNumberAndName(GroupId);
      if ForProcess and (CurrentUserId <> UserId) then
        Line := Line + ' euid=' + UserNumberAndName(CurrentUserId);
      if ForProcess and (CurrentGroupId <> GroupId) then
        Line := Line + ' egid=' + GroupNumberAndName(CurrentGroupId);
      Line := Line + ' groups=';
      for Index := 0 to High(Groups) do
      begin
        if Index > 0 then
          Line := Line + ',';
        Line := Line + GroupNumberAndName(Groups[Index]);
      end;
    end;
  end;
  if Separator = #0 then
    PrintString(Line + #0)
  else
    PrintString(Line + #10);
  CommandLine.Free;
end.
