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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.FileTree,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: mv [OPTION]... [-T] SOURCE DEST'#10 +
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

function MoveOne(Source, Target: PChar): Boolean;
var
  Error: LongInt;
  Information: TFileInformation;
  CopyOptions: TCopyOptions;
begin
  Error := GetLinkInformation(Source, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot stat ''%s''', [ArgumentText(Source)]);
    Exit(False);
  end;
  if NoClobber and PathExists(Target) then
    Exit(True);

  { Renaming onto an existing file replaces it. }
  if PathExists(Target) and not IsDirectory(Target) and (Information.Kind <> KindDirectory) then
    RemovePath(Target);

  Error := RenamePath(Source, Target);
  if Error = ErrorCrossVolume then
  begin
    CopyOptions.Recursive := True;
    CopyOptions.KeepLinks := True;
    CopyOptions.NoClobber := False;
    CopyOptions.Verbose := False;
    CopyOptions.PreserveAttributes := True;
    if not CopyPath(Source, Target, CopyOptions) then
      Exit(False);
    if not RemoveTree(Source) then
      Exit(False);
    Error := ErrorNone;
  end;
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot move ''%s'' to ''%s''', [ArgumentText(Source), ArgumentText(Target)]);
    Exit(False);
  end;
  if Verbose then
    WriteFormatted(StandardOutput, 'renamed ''%s'' -> ''%s'''#10, [ArgumentText(Source), ArgumentText(Target)]);
  Result := True;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  TargetDirectory: PChar;
  NoTargetDirectory: Boolean;
  SourceCount: Integer;
  Index: Integer;
  Base: PChar;
  Target: PChar;
  ExitStatus: LongInt;
begin
  NoClobber := False;
  Verbose := False;
  TargetDirectory := nil;
  NoTargetDirectory := False;
  BeginOptions(Parser, [
    OptionDefinition('f', 'force', False, OptionForce),
    OptionDefinition('i', 'interactive', False, OptionForce),
    OptionDefinition('n', 'no-clobber', False, OptionNoClobber),
    OptionDefinition('t', 'target-directory', True, OptionTargetDirectory),
    OptionDefinition('T', 'no-target-directory', False, OptionNoTargetDirectory),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionForce: NoClobber := False;
      OptionNoClobber: NoClobber := True;
      OptionTargetDirectory: TargetDirectory := Value;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;

  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);
  SourceCount := Parser.OperandCount;
  if TargetDirectory = nil then
  begin
    if Parser.OperandCount = 1 then
      FailWithUsageHint('missing destination file operand after ''%s''', [ArgumentText(Parser.Operands[0])]);
    SourceCount := Parser.OperandCount - 1;
    Target := Parser.Operands[SourceCount];
    if NoTargetDirectory or ((SourceCount = 1) and not IsDirectory(Target)) then
    begin
      if SourceCount > 1 then
        FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
      if MoveOne(Parser.Operands[0], Target) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;

  if not IsDirectory(TargetDirectory) then
    Fail(1, 'target ''%s'' is not a directory', [ArgumentText(TargetDirectory)]);
  ExitStatus := 0;
  for Index := 0 to SourceCount - 1 do
  begin
    Base := BaseName(Parser.Operands[Index]);
    Target := JoinPath(TargetDirectory, Base);
    if not MoveOne(Parser.Operands[Index], Target) then
      ExitStatus := 1;
    FreeMemory(Base);
    FreeMemory(Target);
  end;
  Halt(ExitStatus);
end.
