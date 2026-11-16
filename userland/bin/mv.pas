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
  mv - move (rename) files

  mv [-fintTv] SOURCE DEST
  mv [-finv] SOURCE... DIRECTORY
  mv [-finv] -t DIRECTORY SOURCE...

  Within a volume this is a rename. Between volumes the source is copied
  and then removed.
}
program mv;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.FileTree,
  Util.Messages,
  Util.Output,
  Util.Paths;

const
  Usage = 'Usage: mv [OPTION]... [-T] SOURCE DEST'#10 +
    '  or:  mv [OPTION]... SOURCE... DIRECTORY'#10 +
    '  or:  mv [OPTION]... -t DIRECTORY SOURCE...'#10 +
    'Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.'#10 +
    #10 +
    '  -f, --force                  do not prompt before overwriting'#10 +
    '  -n, --no-clobber             do not overwrite an existing file'#10 +
    '  -t, --target-directory=DIRECTORY  move all SOURCE arguments into DIRECTORY'#10 +
    '  -T, --no-target-directory    treat DEST as a normal file'#10 +
    '  -v, --verbose                explain what is being done'#10;

  OptionForce = 1;
  OptionNoClobber = 2;
  OptionTargetDirectory = 3;
  OptionNoTargetDirectory = 4;
  OptionVerbose = 5;

var
  NoClobber: Boolean;
  Verbose: Boolean;

{ Copies Source to Target and removes Source: moving between volumes. }
function CopyAndRemove(const Source, Target: string): Boolean;
var
  CopyOptions: TCopyOptions;
begin
  CopyOptions.Recursive := True;
  CopyOptions.KeepLinks := True;
  CopyOptions.NoClobber := False;
  CopyOptions.Verbose := False;
  CopyOptions.PreserveAttributes := True;
  Result := CopyPath(Source, Target, CopyOptions) and RemoveTree(Source);
end;

function MoveOne(const Source, Target: string): Boolean;
var
  Error: LongInt;
  Information: TFileInformation;
begin
  Error := GetLinkInformation(PChar(Source), Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot stat ''%s''', [Source]));
    Exit(False);
  end;
  if NoClobber and PathExists(PChar(Target)) then
    Exit(True);

  { Renaming onto an existing file replaces it. }
  if PathExists(PChar(Target)) and not IsDirectory(PChar(Target)) and (Information.Kind <> KindDirectory) then
    RemovePath(PChar(Target));

  Error := RenamePath(PChar(Source), PChar(Target));
  if Error = ErrorCrossVolume then
  begin
    if not CopyAndRemove(Source, Target) then
      Exit(False);
    Error := ErrorNone;
  end;
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot move ''%s'' to ''%s''', [Source, Target]));
    Exit(False);
  end;
  if Verbose then
    PrintString(Format('renamed ''%s'' -> ''%s'''#10, [Source, Target]));
  Result := True;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  TargetDirectory: string;
  NoTargetDirectory: Boolean;
  SourceCount: Integer;
  Index: Integer;
  Target: string;
  ExitStatus: LongInt;
begin
  NoClobber := False;
  Verbose := False;
  NoTargetDirectory := False;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('i', 'interactive', False, OptionForce),
    CommandOption('n', 'no-clobber', False, OptionNoClobber),
    CommandOption('t', 'target-directory', True, OptionTargetDirectory),
    CommandOption('T', 'no-target-directory', False, OptionNoTargetDirectory),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionForce: NoClobber := False;
      OptionNoClobber: NoClobber := True;
      OptionTargetDirectory: TargetDirectory := Value;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;

  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing file operand');
  SourceCount := CommandLine.OperandCount;
  if not CommandLine.OptionGiven(OptionTargetDirectory) then
  begin
    if CommandLine.OperandCount = 1 then
      FailWithUsageHint(Format('missing destination file operand after ''%s''', [CommandLine.Operands[0]]));
    SourceCount := CommandLine.OperandCount - 1;
    Target := CommandLine.Operands[SourceCount];
    if NoTargetDirectory or ((SourceCount = 1) and not IsDirectory(PChar(Target))) then
    begin
      if SourceCount > 1 then
        FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
      if MoveOne(CommandLine.Operands[0], Target) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;

  if not IsDirectory(PChar(TargetDirectory)) then
    Fail(1, Format('target ''%s'' is not a directory', [TargetDirectory]));
  ExitStatus := 0;
  for Index := 0 to SourceCount - 1 do
    if not MoveOne(CommandLine.Operands[Index],
      JoinPath(TargetDirectory, BaseName(CommandLine.Operands[Index]))) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
