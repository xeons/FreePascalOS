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
  rm - remove files or directories

  rm [-dfirRv] FILE...

  Directories are only removed with -r (with their contents) or -d
  (when empty). -f ignores missing files and never prompts.
}
program rm;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Output,
  Util.Paths;

const
  Usage = 'Usage: rm [OPTION]... [FILE]...'#10 +
    'Remove (unlink) the FILE(s).'#10 +
    #10 +
    '  -f, --force           ignore nonexistent files and arguments, never prompt'#10 +
    '  -i                    prompt before every removal'#10 +
    '  -r, -R, --recursive   remove directories and their contents recursively'#10 +
    '  -d, --dir             remove empty directories'#10 +
    '  -v, --verbose         explain what is being done'#10;

  OptionForce = 1;
  OptionInteractive = 2;
  OptionRecursive = 3;
  OptionDirectory = 4;
  OptionVerbose = 5;

var
  Force: Boolean;
  Interactive: Boolean;
  Recursive: Boolean;
  RemoveEmptyDirectories: Boolean;
  Verbose: Boolean;

function Confirm(const Question, Path: string): Boolean;
var
  Answer: string;
  HadLineEnd: Boolean;
begin
  PrintErrorString(Format('%s: %s ''%s''? ', [ProgramName, Question, Path]));
  FlushStream(StandardError);
  if not ReadTextLine(StandardInput, Answer, HadLineEnd) then
    Exit(False);
  Result := (Answer <> '') and ((Answer[1] = 'y') or (Answer[1] = 'Y'));
end;

{ Reports that Path could not be removed. }
procedure ReportCannotRemove(Error: LongInt; const Path: string);
begin
  ReportError(Error, Format('cannot remove ''%s''', [Path]));
end;

function RemoveTree(const Path: string): Boolean; forward;

{ Returns False if something could not be removed. }
function RemoveEntry(const Path: string): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  Error := GetLinkInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    if Force and (Error = ErrorNotFound) then
      Exit(True);
    ReportCannotRemove(Error, Path);
    Exit(False);
  end;

  if Information.Kind = KindDirectory then
  begin
    if Recursive then
      Exit(RemoveTree(Path));
    if not RemoveEmptyDirectories then
    begin
      ReportCannotRemove(ErrorIsDirectory, Path);
      Exit(False);
    end;
  end;

  if Interactive and not Confirm('remove', Path) then
    Exit(True);
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportCannotRemove(Error, Path);
    Exit(False);
  end;
  if Verbose then
  begin
    if Information.Kind = KindDirectory then
      PrintStringLine('removed directory ''' + Path + '''')
    else
      PrintStringLine('removed ''' + Path + '''');
  end;
  Result := True;
end;

function RemoveTree(const Path: string): Boolean;
var
  Names: TStringList;
  Name: string;
  Error: LongInt;
begin
  Result := True;
  if Interactive and not Confirm('descend into directory', Path) then
    Exit;
  Names := TStringList.Create;
  try
    Error := ListDirectory(Path, Names);
    if Error <> ErrorNone then
    begin
      ReportCannotRemove(Error, Path);
      Exit(False);
    end;
    for Name in Names do
      if not RemoveEntry(JoinPath(Path, Name)) then
        Result := False;
  finally
    Names.Free;
  end;

  if Interactive and not Confirm('remove directory', Path) then
    Exit;
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportCannotRemove(Error, Path);
    Exit(False);
  end;
  if Verbose then
    PrintStringLine('removed directory ''' + Path + '''');
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  ExitStatus: LongInt;
  Base: string;
begin
  Force := False;
  Interactive := False;
  Recursive := False;
  RemoveEmptyDirectories := False;
  Verbose := False;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('i', '', False, OptionInteractive),
    CommandOption('r', 'recursive', False, OptionRecursive),
    CommandOption('R', '', False, OptionRecursive),
    CommandOption('d', 'dir', False, OptionDirectory),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionForce:
        begin
          Force := True;
          Interactive := False;
        end;
      OptionInteractive:
        begin
          Interactive := True;
          Force := False;
        end;
      OptionRecursive: Recursive := True;
      OptionDirectory: RemoveEmptyDirectories := True;
      OptionVerbose: Verbose := True;
    end;
  if (CommandLine.OperandCount = 0) and not Force then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    Base := BaseName(Operand);
    if (Base = '.') or (Base = '..') or (Base = '/') then
    begin
      Report(Format('refusing to remove ''.'' or ''..'' or ''/'' directory: skipping ''%s''', [Operand]));
      ExitStatus := 1;
    end
    else if not RemoveEntry(Operand) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
