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
  cp - copy files and directories

  cp [-afinPrRTv] SOURCE DEST
  cp [-afinPrRv] SOURCE... DIRECTORY
  cp [-afinPrRv] -t DIRECTORY SOURCE...
}
program cp;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Files,
  Util.CommandLine,
  Util.FileTree,
  Util.Messages,
  Util.Paths;

const
  Usage = 'Usage: cp [OPTION]... [-T] SOURCE DEST'#10 +
    '  or:  cp [OPTION]... SOURCE... DIRECTORY'#10 +
    '  or:  cp [OPTION]... -t DIRECTORY SOURCE...'#10 +
    'Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.'#10 +
    #10 +
    '  -a, --archive                same as -dR --preserve'#10 +
    '  -d, -P, --no-dereference     never follow symbolic links in SOURCE'#10 +
    '  -f, --force                  overwrite existing files (the default)'#10 +
    '  -n, --no-clobber             do not overwrite an existing file'#10 +
    '  -p, --preserve               keep mode, ownership and timestamps'#10 +
    '  -R, -r, --recursive          copy directories recursively'#10 +
    '  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY'#10 +
    '  -T, --no-target-directory    treat DEST as a normal file'#10 +
    '  -v, --verbose                explain what is being done'#10;

  OptionArchive = 1;
  OptionNoDereference = 2;
  OptionForce = 3;
  OptionNoClobber = 4;
  OptionRecursive = 5;
  OptionTargetDirectory = 6;
  OptionNoTargetDirectory = 7;
  OptionVerbose = 8;
  OptionPreserve = 9;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Options: TCopyOptions;
  TargetDirectory: string;
  HasTargetDirectory: Boolean;
  NoTargetDirectory: Boolean;
  SourceCount: Integer;
  Index: Integer;
  Target: string;
  ExitStatus: LongInt;
begin
  Options := Default(TCopyOptions);
  HasTargetDirectory := False;
  NoTargetDirectory := False;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'archive', False, OptionArchive),
    CommandOption('d', '', False, OptionNoDereference),
    CommandOption('P', 'no-dereference', False, OptionNoDereference),
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('n', 'no-clobber', False, OptionNoClobber),
    CommandOption('R', 'recursive', False, OptionRecursive),
    CommandOption('r', '', False, OptionRecursive),
    CommandOption('t', 'target-directory', True, OptionTargetDirectory),
    CommandOption('T', 'no-target-directory', False, OptionNoTargetDirectory),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption('p', 'preserve', False, OptionPreserve)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionArchive:
        begin
          Options.Recursive := True;
          Options.KeepLinks := True;
          Options.PreserveAttributes := True;
        end;
      OptionPreserve: Options.PreserveAttributes := True;
      OptionNoDereference: Options.KeepLinks := True;
      OptionForce: Options.NoClobber := False;
      OptionNoClobber: Options.NoClobber := True;
      OptionRecursive:
        begin
          Options.Recursive := True;
          { Like GNU cp, -R copies links inside the tree as links. }
          Options.KeepLinks := True;
        end;
      OptionTargetDirectory:
        begin
          TargetDirectory := Value;
          HasTargetDirectory := True;
        end;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Options.Verbose := True;
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
      if CopyPath(CommandLine.Operands[0], Target, Options) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;

  if not IsDirectory(PChar(TargetDirectory)) then
    Fail(1, Format('target ''%s'' is not a directory', [TargetDirectory]));
  ExitStatus := 0;
  for Index := 0 to SourceCount - 1 do
  begin
    Target := JoinPath(TargetDirectory, BaseName(CommandLine.Operands[Index]));
    if not CopyPath(CommandLine.Operands[Index], Target, Options) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
