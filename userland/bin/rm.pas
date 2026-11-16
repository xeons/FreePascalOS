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
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: rm [OPTION]... [FILE]...'#10 +
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

{ Copies a heap string from the libraries and frees it. }
function TakeText(Text: PChar): string;
begin
  Result := Text;
  FreeMemory(Text);
end;

function Confirm(const Question, Path: string): Boolean;
var
  LineText: PChar;
  Answer: string;
  HadLineEnd: Boolean;
begin
  WriteFormatted(StandardError, '%s: %s ''%s''? ', [ArgumentText(ProgramName), ArgumentText(PChar(Question)),
    ArgumentText(PChar(Path))]);
  FlushStream(StandardError);
  if not ReadLine(StandardInput, LineText, HadLineEnd) then
    Exit(False);
  Answer := TakeText(LineText);
  Result := (Answer <> '') and ((Answer[1] = 'y') or (Answer[1] = 'Y'));
end;

{ Directory + '/' + Name, without doubling the slash. }
function JoinPath(const Directory, Name: string): string;
begin
  if (Directory <> '') and (Directory[Length(Directory)] <> '/') then
    Result := Directory + '/' + Name
  else
    Result := Directory + Name;
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
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(PChar(Path))]);
    Exit(False);
  end;

  if Information.Kind = KindDirectory then
  begin
    if Recursive then
      Exit(RemoveTree(Path));
    if not RemoveEmptyDirectories then
    begin
      ReportError(ErrorIsDirectory, 'cannot remove ''%s''', [ArgumentText(PChar(Path))]);
      Exit(False);
    end;
  end;

  if Interactive and not Confirm('remove', Path) then
    Exit(True);
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(PChar(Path))]);
    Exit(False);
  end;
  if Verbose then
  begin
    if Information.Kind = KindDirectory then
      WriteText(StandardOutput, PChar('removed directory ''' + Path + ''''#10))
    else
      WriteText(StandardOutput, PChar('removed ''' + Path + ''''#10));
  end;
  Result := True;
end;

function RemoveTree(const Path: string): Boolean;
var
  Names: TLineList;
  Index: Integer;
  Error: LongInt;
begin
  Result := True;
  if Interactive and not Confirm('descend into directory', Path) then
    Exit;
  BeginLineList(Names);
  Error := ListDirectory(PChar(Path), Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(PChar(Path))]);
    FreeLineList(Names);
    Exit(False);
  end;
  try
    for Index := 0 to Names.Count - 1 do
      if not RemoveEntry(JoinPath(Path, Names.Items[Index])) then
        Result := False;
  finally
    FreeLineList(Names);
  end;

  if Interactive and not Confirm('remove directory', Path) then
    Exit;
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(PChar(Path))]);
    Exit(False);
  end;
  if Verbose then
    WriteText(StandardOutput, PChar('removed directory ''' + Path + ''''#10));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  ExitStatus: LongInt;
  Base: string;
begin
  Force := False;
  Interactive := False;
  Recursive := False;
  RemoveEmptyDirectories := False;
  Verbose := False;
  BeginOptions(Parser, [
    OptionDefinition('f', 'force', False, OptionForce),
    OptionDefinition('i', nil, False, OptionInteractive),
    OptionDefinition('r', 'recursive', False, OptionRecursive),
    OptionDefinition('R', nil, False, OptionRecursive),
    OptionDefinition('d', 'dir', False, OptionDirectory),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
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
  if (Parser.OperandCount = 0) and not Force then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Base := TakeText(BaseName(Parser.Operands[Index]));
    if (Base = '.') or (Base = '..') or (Base = '/') then
    begin
      Report('refusing to remove ''.'' or ''..'' or ''/'' directory: skipping ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end
    else if not RemoveEntry(Parser.Operands[Index]) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
