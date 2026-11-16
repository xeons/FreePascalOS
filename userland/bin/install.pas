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
  install - copy files and set attributes

  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] SOURCE DEST
  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] SOURCE... DIRECTORY
  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] -t DIRECTORY SOURCE...
  install -d [-m MODE] [-o OWNER] [-g GROUP] DIRECTORY...

  Files get mode 0755 unless -m says otherwise. -D creates the missing
  parent directories of DEST; -p keeps the source's modification time.
}
program install;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.Accounts,
  Util.CommandLine,
  Util.FileTree,
  Util.Messages,
  Util.Modes,
  Util.Output,
  Util.Paths;

const
  Usage = 'Usage: install [OPTION]... [-T] SOURCE DEST'#10 +
    '  or:  install [OPTION]... SOURCE... DIRECTORY'#10 +
    '  or:  install [OPTION]... -t DIRECTORY SOURCE...'#10 +
    '  or:  install [OPTION]... -d DIRECTORY...'#10 +
    'Copy SOURCE to DEST or multiple SOURCE(s) to the existing DIRECTORY,'#10 +
    'while setting permission modes and owner/group.'#10#10 +
    '  -d, --directory     treat all arguments as directory names; create all'#10 +
    '                        components of the specified directories'#10 +
    '  -D                  create all leading components of DEST except the last'#10 +
    '  -g, --group=GROUP   set group ownership, instead of process'' current group'#10 +
    '  -m, --mode=MODE     set permission mode (as in chmod), instead of rwxr-xr-x'#10 +
    '  -o, --owner=OWNER   set ownership'#10 +
    '  -p, --preserve-timestamps  apply modification time of SOURCE files to'#10 +
    '                        corresponding destination files'#10 +
    '  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY'#10 +
    '  -T, --no-target-directory  treat DEST as a normal file'#10 +
    '  -v, --verbose       print the name of each created file or directory'#10;

  OptionDirectory = 1;
  OptionParents = 2;
  OptionGroup = 3;
  OptionMode = 4;
  OptionOwner = 5;
  OptionPreserve = 6;
  OptionTarget = 7;
  OptionNoTarget = 8;
  OptionVerbose = 9;
  OptionCompare = 10;
  OptionStrip = 11;

  DefaultMode = '755';

var
  ModeChange: TModeChange;
  Owner: Int64;
  Group: Int64;
  PreserveTimes: Boolean;
  Verbose: Boolean;

{ Creates Path and its missing parents. }
function MakeDirectories(const Path: string): Boolean;
var
  Position: Integer;
  Prefix: string;
  Error: LongInt;
begin
  Result := True;
  { Each prefix ending before a slash (a leading slash is not one), then
    the whole path. }
  Position := 2;
  while True do
  begin
    while (Position <= Length(Path)) and (Path[Position] <> '/') do
      Inc(Position);
    Prefix := Copy(Path, 1, Position - 1);
    if (Prefix <> '') and not IsDirectory(PChar(Prefix)) then
    begin
      Error := CreateDirectory(PChar(Prefix));
      if Error <> ErrorNone then
      begin
        ReportError(Error, Format('cannot create directory ''%s''', [Prefix]));
        Exit(False);
      end;
      if Verbose then
        PrintString(Format('%s: creating directory ''%s'''#10, [ProgramName, Prefix]));
    end;
    if Position > Length(Path) then
      Break;
    Inc(Position);
    if Position > Length(Path) then
      Break;
  end;
end;

function ApplyAttributes(const Path: string; IsDirectoryPath: Boolean; ModificationTime: Int64): Boolean;
var
  Error: LongInt;
begin
  Result := True;
  Error := ChangeMode(PChar(Path), ApplyModeChange(ModeChange, 0, IsDirectoryPath));
  if Error = ErrorNone then
    Error := ChangeOwner(PChar(Path), Owner, Group, True);
  if (Error = ErrorNone) and (ModificationTime >= 0) then
    Error := SetFileTimes(PChar(Path), ModificationTime, ModificationTime, True);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot set attributes of ''%s''', [Path]));
    Result := False;
  end;
end;

function InstallFile(const Source, Target: string): Boolean;
var
  Options: TCopyOptions;
  Information: TFileInformation;
  Time: Int64;
begin
  if GetFileInformation(PChar(Source), Information) <> ErrorNone then
  begin
    Report(Format('cannot stat ''%s'': No such file or directory', [Source]));
    Exit(False);
  end;
  if Information.Kind = KindDirectory then
  begin
    Report(Format('omitting directory ''%s''', [Source]));
    Exit(False);
  end;
  { Replace rather than overwrite, so a running copy is not disturbed. }
  if PathExists(PChar(Target)) and not IsDirectory(PChar(Target)) then
    RemovePath(PChar(Target));
  Options := Default(TCopyOptions);
  if not CopyPath(Source, Target, Options) then
    Exit(False);
  if Verbose then
    PrintString(Format('''%s'' -> ''%s'''#10, [Source, Target]));
  Time := -1;
  if PreserveTimes then
    Time := Information.ModificationTime;
  Result := ApplyAttributes(Target, False, Time);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  DirectoryMode: Boolean;
  CreateParents: Boolean;
  TargetDirectory: string;
  HasTargetDirectory: Boolean;
  NoTargetDirectory: Boolean;
  Index: Integer;
  SourceCount: Integer;
  Target: string;
  Operand: string;
  Id: LongWord;
  ExitStatus: LongInt;
begin
  DirectoryMode := False;
  CreateParents := False;
  TargetDirectory := '';
  HasTargetDirectory := False;
  NoTargetDirectory := False;
  Owner := -1;
  Group := -1;
  ParseModeChange(string(DefaultMode), ModeChange);
  CommandLine := TCommandLine.Create([
    CommandOption('d', 'directory', False, OptionDirectory),
    CommandOption('D', '', False, OptionParents),
    CommandOption('g', 'group', True, OptionGroup),
    CommandOption('m', 'mode', True, OptionMode),
    CommandOption('o', 'owner', True, OptionOwner),
    CommandOption('p', 'preserve-timestamps', False, OptionPreserve),
    CommandOption('t', 'target-directory', True, OptionTarget),
    CommandOption('T', 'no-target-directory', False, OptionNoTarget),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption('C', 'compare', False, OptionCompare),
    CommandOption('s', 'strip', False, OptionStrip)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionDirectory: DirectoryMode := True;
      OptionParents: CreateParents := True;
      OptionGroup:
        begin
          if not FindGroupId(Value, Id) then
            Fail(1, Format('invalid group ''%s''', [Value]));
          Group := Id;
        end;
      OptionMode:
        if not ParseModeChange(Value, ModeChange) then
          Fail(1, Format('invalid mode ''%s''', [Value]));
      OptionOwner:
        begin
          if not FindUserId(Value, Id) then
            Fail(1, Format('invalid user ''%s''', [Value]));
          Owner := Id;
        end;
      OptionPreserve: PreserveTimes := True;
      OptionTarget:
        begin
          TargetDirectory := Value;
          HasTargetDirectory := True;
        end;
      OptionNoTarget: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;

  ExitStatus := 0;
  if DirectoryMode then
  begin
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing operand');
    for Operand in CommandLine.Operands do
    begin
      if not MakeDirectories(Operand) or not ApplyAttributes(Operand, True, -1) then
        ExitStatus := 1;
    end;
    Halt(ExitStatus);
  end;

  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing file operand');
  SourceCount := CommandLine.OperandCount;
  if not HasTargetDirectory then
  begin
    if CommandLine.OperandCount = 1 then
      FailWithUsageHint(Format('missing destination file operand after ''%s''', [CommandLine.Operands[0]]));
    SourceCount := CommandLine.OperandCount - 1;
    Target := CommandLine.Operands[SourceCount];
    if NoTargetDirectory or ((SourceCount = 1) and not IsDirectory(PChar(Target))) then
    begin
      if SourceCount > 1 then
        FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
      if CreateParents and not MakeDirectories(DirectoryName(Target)) then
        Halt(1);
      if InstallFile(CommandLine.Operands[0], Target) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;
  if CreateParents and not MakeDirectories(TargetDirectory) then
    Halt(1);
  if not IsDirectory(PChar(TargetDirectory)) then
    Fail(1, Format('target ''%s'' is not a directory', [TargetDirectory]));
  for Index := 0 to SourceCount - 1 do
  begin
    Target := JoinPath(TargetDirectory, BaseName(CommandLine.Operands[Index]));
    if not InstallFile(CommandLine.Operands[Index], Target) then
      ExitStatus := 1;
  end;
  CommandLine.Free;
  Halt(ExitStatus);
end.
