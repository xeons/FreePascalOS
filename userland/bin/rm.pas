{
  rm - remove files or directories

  rm [-dfirRv] FILE...

  Directories are only removed with -r (with their contents) or -d
  (when empty). -f ignores missing files and never prompts.
}
program rm;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
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

function Confirm(Question: PChar; Path: PChar): Boolean;
var
  Line: PChar;
  HadLineEnd: Boolean;
begin
  WriteFormatted(StandardError, '%s: %s ''%s''? ', [ArgumentText(ProgramName), ArgumentText(Question), ArgumentText(Path)]);
  FlushStream(StandardError);
  if not ReadLine(StandardInput, Line, HadLineEnd) then
    Exit(False);
  Result := (Line[0] = 'y') or (Line[0] = 'Y');
  FreeMemory(Line);
end;

function RemoveTree(Path: PChar): Boolean; forward;

{ Returns False if something could not be removed. }
function RemoveEntry(Path: PChar; IsOperand: Boolean): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  Error := GetLinkInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    if Force and (Error = ErrorNotFound) then
      Exit(True);
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;

  if Information.Kind = KindDirectory then
  begin
    if Recursive then
      Exit(RemoveTree(Path));
    if not RemoveEmptyDirectories then
    begin
      ReportError(ErrorIsDirectory, 'cannot remove ''%s''', [ArgumentText(Path)]);
      Exit(False);
    end;
  end;

  if Interactive and not Confirm('remove', Path) then
    Exit(True);
  Error := RemovePath(Path);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  if Verbose then
  begin
    if Information.Kind = KindDirectory then
      WriteFormatted(StandardOutput, 'removed directory ''%s'''#10, [ArgumentText(Path)])
    else
      WriteFormatted(StandardOutput, 'removed ''%s'''#10, [ArgumentText(Path)]);
  end;
  Result := True;
end;

function RemoveTree(Path: PChar): Boolean;
var
  Names: TLineList;
  Index: Integer;
  ChildPath: PChar;
  Error: LongInt;
begin
  Result := True;
  if Interactive and not Confirm('descend into directory', Path) then
    Exit;
  BeginLineList(Names);
  Error := ListDirectory(Path, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    FreeLineList(Names);
    Exit(False);
  end;
  for Index := 0 to Names.Count - 1 do
  begin
    ChildPath := JoinPath(Path, Names.Items[Index]);
    if not RemoveEntry(ChildPath, False) then
      Result := False;
    FreeMemory(ChildPath);
  end;
  FreeLineList(Names);

  if Interactive and not Confirm('remove directory', Path) then
    Exit;
  Error := RemovePath(Path);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  if Verbose then
    WriteFormatted(StandardOutput, 'removed directory ''%s'''#10, [ArgumentText(Path)]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  ExitStatus: LongInt;
  Base: PChar;
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
    Base := BaseName(Parser.Operands[Index]);
    if IsDotEntry(Base) or TextIsEqual(Base, '/') then
    begin
      Report('refusing to remove ''.'' or ''..'' or ''/'' directory: skipping ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end
    else if not RemoveEntry(Parser.Operands[Index], True) then
      ExitStatus := 1;
    FreeMemory(Base);
  end;
  Halt(ExitStatus);
end.
