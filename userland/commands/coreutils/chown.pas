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
  chown, chgrp - change file owner and group

  chown [-cfhvR] OWNER[:[GROUP]] FILE...
  chown [-cfhvR] :GROUP FILE...
  chgrp [-cfhvR] GROUP FILE...
  ... --reference=RFILE FILE...

  OWNER and GROUP are names from /etc/passwd and /etc/group, or numbers.
  "OWNER:" also sets the group to OWNER's primary group. -h changes
  symbolic links themselves. FAT and exFAT have no owners; only 0 is
  accepted there.
}
program chown;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Files,
  Util.Accounts,
  Util.CommandLine,
  Util.FileTree,
  Util.Messages,
  Sys.Streams,
  Util.Paths;

const
  ChownUsage = 'Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...'#10 +
    '  or:  chown [OPTION]... --reference=RFILE FILE...'#10 +
    'Change the owner and/or group of each FILE to OWNER and/or GROUP.'#10#10 +
    '  -c, --changes          like verbose but report only when a change is made'#10 +
    '  -f, --silent, --quiet  suppress most error messages'#10 +
    '  -v, --verbose          output a diagnostic for every file processed'#10 +
    '  -h, --no-dereference   affect symbolic links instead of any referenced file'#10 +
    '      --reference=RFILE  use RFILE''s owner and group'#10 +
    '  -R, --recursive        operate on files and directories recursively'#10;
  ChgrpUsage = 'Usage: chgrp [OPTION]... GROUP FILE...'#10 +
    '  or:  chgrp [OPTION]... --reference=RFILE FILE...'#10 +
    'Change the group of each FILE to GROUP.'#10#10 +
    '  -c, --changes          like verbose but report only when a change is made'#10 +
    '  -f, --silent, --quiet  suppress most error messages'#10 +
    '  -v, --verbose          output a diagnostic for every file processed'#10 +
    '  -h, --no-dereference   affect symbolic links instead of any referenced file'#10 +
    '      --reference=RFILE  use RFILE''s group'#10 +
    '  -R, --recursive        operate on files and directories recursively'#10;

  OptionChanges = 1;
  OptionSilent = 2;
  OptionVerbose = 3;
  OptionNoDereference = 4;
  OptionReference = 5;
  OptionRecursive = 6;
  OptionDereference = 7;

type
  { Gives files a new owner and group, reporting as the options ask. }
  TOwnerChanger = class
  public
    NewOwner: Int64;   { -1 = unchanged }
    NewGroup: Int64;
    ReportChanges: Boolean;
    Silent: Boolean;
    Verbose: Boolean;
    FollowLinks: Boolean;
    constructor Create;
    { Parses OWNER, OWNER:GROUP, OWNER:, :GROUP (also with '.'). }
    procedure ParseOwnerSpecification(const Text: string);
    function ChangeOne(const Path: string): Boolean;
    function VisitInWalk(const Path: string; IsDirectory: Boolean): Boolean;
  end;

function NameOfOwner(Id: LongWord): string;
begin
  if not FindUserName(Id, Result) then
    Result := '?';
end;

constructor TOwnerChanger.Create;
begin
  inherited Create;
  NewOwner := -1;
  NewGroup := -1;
  FollowLinks := True;
end;

function TOwnerChanger.ChangeOne(const Path: string): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
  Changed: Boolean;
begin
  Result := True;
  if FollowLinks then
    Error := GetFileInformation(PChar(Path), Information)
  else
    Error := GetLinkInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    if not Silent then
      ReportError(Error, Format('cannot access ''%s''', [Path]));
    Exit(False);
  end;
  Changed := ((NewOwner >= 0) and (LongWord(NewOwner) <> Information.OwnerId)) or
    ((NewGroup >= 0) and (LongWord(NewGroup) <> Information.GroupId));
  if Changed then
  begin
    Error := ChangeOwner(PChar(Path), NewOwner, NewGroup, FollowLinks);
    if Error <> ErrorNone then
    begin
      if not Silent then
        ReportError(Error, Format('changing ownership of ''%s''', [Path]));
      Exit(False);
    end;
  end;
  if Verbose or (ReportChanges and Changed) then
  begin
    if Changed then
      PrintString(Format('ownership of ''%s'' changed'#10, [Path]))
    else
      PrintString(Format('ownership of ''%s'' retained as %s'#10, [Path,
        NameOfOwner(Information.OwnerId)]));
  end;
end;

procedure TOwnerChanger.ParseOwnerSpecification(const Text: string);
var
  Separator: Integer;
  OwnerPart: string;
  GroupPart: string;
  HasGroupPart: Boolean;
  Id: LongWord;
  Primary: LongWord;
begin
  Separator := Pos(':', Text);
  if Separator = 0 then
    Separator := Pos('.', Text);
  HasGroupPart := Separator > 0;
  if HasGroupPart then
  begin
    OwnerPart := Copy(Text, 1, Separator - 1);
    GroupPart := Copy(Text, Separator + 1, MaxInt);
  end
  else
  begin
    OwnerPart := Text;
    GroupPart := '';
  end;
  if OwnerPart <> '' then
  begin
    if not FindUserId(OwnerPart, Id) then
      Fail(1, Format('invalid user: ''%s''', [Text]));
    NewOwner := Id;
  end;
  if HasGroupPart then
  begin
    if GroupPart <> '' then
    begin
      if not FindGroupId(GroupPart, Id) then
        Fail(1, Format('invalid group: ''%s''', [Text]));
      NewGroup := Id;
    end
    else if (NewOwner >= 0) and PrimaryGroupOf(LongWord(NewOwner), Primary) then
      NewGroup := Primary;
  end;
end;

function TOwnerChanger.VisitInWalk(const Path: string; IsDirectory: Boolean): Boolean;
begin
  Result := ChangeOne(Path);
end;

var
  CommandLine: TCommandLine;
  Changer: TOwnerChanger;
  Code: Integer;
  Value: string;
  IsChgrp: Boolean;
  Recursive: Boolean;
  HasReference: Boolean;
  Reference: string;
  FirstFile: Integer;
  Index: Integer;
  Information: TFileInformation;
  Id: LongWord;
  ExitStatus: LongInt;
  Usage: string;
begin
  IsChgrp := BaseName(string(Argument(0))) = 'chgrp';
  Changer := TOwnerChanger.Create;
  Recursive := False;
  HasReference := False;
  if IsChgrp then
    Usage := ChgrpUsage
  else
    Usage := ChownUsage;
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'changes', False, OptionChanges),
    CommandOption('f', 'silent', False, OptionSilent),
    CommandOption(#0, 'quiet', False, OptionSilent),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption('h', 'no-dereference', False, OptionNoDereference),
    CommandOption(#0, 'dereference', False, OptionDereference),
    CommandOption(#0, 'reference', True, OptionReference),
    CommandOption('R', 'recursive', False, OptionRecursive)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionChanges: Changer.ReportChanges := True;
      OptionSilent: Changer.Silent := True;
      OptionVerbose: Changer.Verbose := True;
      OptionNoDereference: Changer.FollowLinks := False;
      OptionDereference: Changer.FollowLinks := True;
      OptionReference:
        begin
          HasReference := True;
          Reference := Value;
        end;
      OptionRecursive: Recursive := True;
    end;
  { A recursive walk never follows links. }
  if Recursive then
    Changer.FollowLinks := False;

  FirstFile := 0;
  if HasReference then
  begin
    if GetFileInformation(PChar(Reference), Information) <> ErrorNone then
      Fail(1, Format('failed to get attributes of ''%s''', [Reference]));
    if not IsChgrp then
      Changer.NewOwner := Information.OwnerId;
    Changer.NewGroup := Information.GroupId;
  end
  else
  begin
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing operand');
    if IsChgrp then
    begin
      if not FindGroupId(CommandLine.Operands[0], Id) then
        Fail(1, Format('invalid group: ''%s''', [CommandLine.Operands[0]]));
      Changer.NewGroup := Id;
    end
    else
      Changer.ParseOwnerSpecification(CommandLine.Operands[0]);
    FirstFile := 1;
  end;
  if FirstFile >= CommandLine.OperandCount then
  begin
    { With --reference and no files there is no operand to name. }
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing operand after ''(null)''');
    FailWithUsageHint(Format('missing operand after ''%s''', [CommandLine.Operands[0]]));
  end;

  ExitStatus := 0;
  for Index := FirstFile to CommandLine.OperandCount - 1 do
  begin
    if Recursive then
    begin
      if not WalkTree(CommandLine.Operands[Index], @Changer.VisitInWalk) then
        ExitStatus := 1;
    end
    else if not Changer.ChangeOne(CommandLine.Operands[Index]) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
