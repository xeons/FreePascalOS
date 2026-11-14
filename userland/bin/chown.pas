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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Accounts,
  Util.FileTree,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  ChownUsage: PChar = 'Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...'#10 +
    '  or:  chown [OPTION]... --reference=RFILE FILE...'#10 +
    'Change the owner and/or group of each FILE to OWNER and/or GROUP.'#10#10 +
    '  -c, --changes          like verbose but report only when a change is made'#10 +
    '  -f, --silent, --quiet  suppress most error messages'#10 +
    '  -v, --verbose          output a diagnostic for every file processed'#10 +
    '  -h, --no-dereference   affect symbolic links instead of any referenced file'#10 +
    '      --reference=RFILE  use RFILE''s owner and group'#10 +
    '  -R, --recursive        operate on files and directories recursively'#10;
  ChgrpUsage: PChar = 'Usage: chgrp [OPTION]... GROUP FILE...'#10 +
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

var
  NewOwner: Int64;   { -1 = unchanged }
  NewGroup: Int64;
  ReportChanges: Boolean;
  Silent: Boolean;
  Verbose: Boolean;
  FollowLinks: Boolean;

function NameOfOwner(Id: LongWord): PChar;
begin
  Result := UserNameOf(Id);
  if Result = nil then
    Result := '?';
end;

function ChangeOne(Path: PChar; IsDirectory: Boolean; Context: Pointer): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
  Changed: Boolean;
begin
  Result := True;
  if FollowLinks then
    Error := GetFileInformation(Path, Information)
  else
    Error := GetLinkInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    if not Silent then
      ReportError(Error, 'cannot access ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  Changed := ((NewOwner >= 0) and (LongWord(NewOwner) <> Information.OwnerId)) or
    ((NewGroup >= 0) and (LongWord(NewGroup) <> Information.GroupId));
  if Changed then
  begin
    Error := ChangeOwner(Path, NewOwner, NewGroup, FollowLinks);
    if Error <> ErrorNone then
    begin
      if not Silent then
        ReportError(Error, 'changing ownership of ''%s''', [ArgumentText(Path)]);
      Exit(False);
    end;
  end;
  if Verbose or (ReportChanges and Changed) then
  begin
    if Changed then
      WriteFormatted(StandardOutput, 'ownership of ''%s'' changed'#10, [ArgumentText(Path)])
    else
      WriteFormatted(StandardOutput, 'ownership of ''%s'' retained as %s'#10, [ArgumentText(Path),
        ArgumentText(NameOfOwner(Information.OwnerId))]);
  end;
end;

{ Parses OWNER, OWNER:GROUP, OWNER:, :GROUP (also with '.'). }
procedure ParseOwnerSpecification(Text: PChar);
var
  Separator: PtrInt;
  OwnerPart: PChar;
  GroupPart: PChar;
  Id: LongWord;
  Primary: LongWord;
begin
  OwnerPart := DuplicateText(Text);
  Separator := FindCharacter(OwnerPart, ':');
  if Separator < 0 then
    Separator := FindCharacter(OwnerPart, '.');
  GroupPart := nil;
  if Separator >= 0 then
  begin
    OwnerPart[Separator] := #0;
    GroupPart := OwnerPart + Separator + 1;
  end;
  if OwnerPart^ <> #0 then
  begin
    if not FindUserId(OwnerPart, Id) then
      Fail(1, 'invalid user: ''%s''', [ArgumentText(Text)]);
    NewOwner := Id;
  end;
  if GroupPart <> nil then
  begin
    if GroupPart^ <> #0 then
    begin
      if not FindGroupId(GroupPart, Id) then
        Fail(1, 'invalid group: ''%s''', [ArgumentText(Text)]);
      NewGroup := Id;
    end
    else if (NewOwner >= 0) and PrimaryGroupOf(LongWord(NewOwner), Primary) then
      NewGroup := Primary;
  end;
end;

function VisitInWalk(Path: PChar; IsDirectory: Boolean; Context: Pointer): Boolean;
begin
  Result := ChangeOne(Path, IsDirectory, Context);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  IsChgrp: Boolean;
  Recursive: Boolean;
  Reference: PChar;
  First: Integer;
  Index: Integer;
  Information: TFileInformation;
  Id: LongWord;
  ExitStatus: LongInt;
  Name: PChar;
  Usage: PChar;
begin
  Name := BaseName(Argument(0));
  IsChgrp := TextIsEqual(Name, 'chgrp');
  NewOwner := -1;
  NewGroup := -1;
  FollowLinks := True;
  Recursive := False;
  Reference := nil;
  if IsChgrp then
    Usage := ChgrpUsage
  else
    Usage := ChownUsage;
  BeginOptions(Parser, [
    OptionDefinition('c', 'changes', False, OptionChanges),
    OptionDefinition('f', 'silent', False, OptionSilent),
    OptionDefinition(#0, 'quiet', False, OptionSilent),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('h', 'no-dereference', False, OptionNoDereference),
    OptionDefinition(#0, 'dereference', False, OptionDereference),
    OptionDefinition(#0, 'reference', True, OptionReference),
    OptionDefinition('R', 'recursive', False, OptionRecursive)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionChanges: ReportChanges := True;
      OptionSilent: Silent := True;
      OptionVerbose: Verbose := True;
      OptionNoDereference: FollowLinks := False;
      OptionDereference: FollowLinks := True;
      OptionReference: Reference := Value;
      OptionRecursive: Recursive := True;
    end;
  { A recursive walk never follows links. }
  if Recursive then
    FollowLinks := False;

  First := 0;
  if Reference <> nil then
  begin
    if GetFileInformation(Reference, Information) <> ErrorNone then
      Fail(1, 'failed to get attributes of ''%s''', [ArgumentText(Reference)]);
    if not IsChgrp then
      NewOwner := Information.OwnerId;
    NewGroup := Information.GroupId;
  end
  else
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('missing operand', []);
    if IsChgrp then
    begin
      if not FindGroupId(Parser.Operands[0], Id) then
        Fail(1, 'invalid group: ''%s''', [ArgumentText(Parser.Operands[0])]);
      NewGroup := Id;
    end
    else
      ParseOwnerSpecification(Parser.Operands[0]);
    First := 1;
  end;
  if First >= Parser.OperandCount then
    FailWithUsageHint('missing operand after ''%s''', [ArgumentText(Parser.Operands[0])]);

  ExitStatus := 0;
  for Index := First to Parser.OperandCount - 1 do
  begin
    if Recursive then
    begin
      if not WalkTree(Parser.Operands[Index], @VisitInWalk, nil) then
        ExitStatus := 1;
    end
    else if not ChangeOne(Parser.Operands[Index], False, nil) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
