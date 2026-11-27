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
  sed - stream editor for filtering and transforming text

  sed [-nEsuz] [-i[SUFFIX]] [-e SCRIPT]... [-f FILE]... [SCRIPT] [FILE]...

  The script is a list of commands, each with up to two addresses:
    N  a line number      $  the last line      /RE/  lines matching RE
    \cREc  RE with another delimiter      ADDR1,+N  ADDR1 and N more lines
    FIRST~STEP  every STEP-th line from FIRST      ADDR!  lines NOT matching

  Commands:
    {  }        group commands
    s/RE/REPLACEMENT/FLAGS   substitute (flags g, N, p, I, w FILE)
    y/SOURCE/DEST/  transliterate characters
    p P         print the pattern space (P: up to the first line end)
    d D         delete the pattern space (D: up to the first line end)
    n N         next line (N: append it)
    g G h H x   copy, append or exchange with the hold space
    a i c TEXT  append, insert, change
    =           print the line number      l  print unambiguously
    r FILE      append FILE's contents     w FILE  write the pattern space
    b t T LABEL branch always / if a substitution was made / if not
    : LABEL     a label        q Q [CODE]  quit (Q: without printing)
    # comment

  Regular expressions are basic (extended with -E or -r); an empty RE
  repeats the last one used. In replacements, & is the match, \1-\9 the
  groups and \n a line end.
}
program sed;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.RegularExpressions,
  Sed.Script,
  Sed.Editor;

const
  Usage = 'Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...'#10#10 +
    '  -n, --quiet, --silent'#10 +
    '                 suppress automatic printing of pattern space'#10 +
    '  -e script, --expression=script'#10 +
    '                 add the script to the commands to be executed'#10 +
    '  -f script-file, --file=script-file'#10 +
    '                 add the contents of script-file to the commands to be executed'#10 +
    '  -i[SUFFIX], --in-place[=SUFFIX]'#10 +
    '                 edit files in place (makes backup if SUFFIX supplied)'#10 +
    '  -E, -r, --regexp-extended'#10 +
    '                 use extended regular expressions in the script'#10 +
    '  -s, --separate'#10 +
    '                 consider files as separate rather than as a single'#10 +
    '                 continuous long stream.'#10 +
    '  -z, --null-data'#10 +
    '                 separate lines by NUL characters'#10;

  OptionQuiet = 1;
  OptionExpression = 2;
  OptionScriptFile = 3;
  OptionExtended = 4;
  OptionSeparate = 5;
  OptionNullData = 6;
  OptionUnbuffered = 7;
  OptionPosix = 8;

var
  Syntax: TExpressionSyntax;
  Quiet: Boolean;
  Separate: Boolean;
  LineEnd: Char;
  InPlace: Boolean;
  InPlaceSuffix: string;
  Script: TScript;

{ -i: each file is edited separately, through a temporary file that then
  replaces it. }
procedure EditInPlace(Editor: TStreamEditor; const Path: string);
var
  TemporaryPath: string;
  BackupPath: string;
  Handle: Int64;
  Error: LongInt;
begin
  if not PathExists(PChar(Path)) then
  begin
    Report('can''t read ' + Path + ': No such file or directory');
    Editor.ExitStatus := 2;
    Exit;
  end;
  if IsDirectory(PChar(Path)) then
  begin
    Report('couldn''t edit ' + Path + ': not a regular file');
    Editor.ExitStatus := 2;
    Exit;
  end;
  TemporaryPath := Path + '.sedtmp';
  Handle := OpenFile(PChar(TemporaryPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    FailWithError(4, ErrorCodeOf(Handle), 'couldn''t open temporary file ' + TemporaryPath);
  Editor.Output := CreateOutputStream(Handle);
  Editor.SetInputFiles([Path]);
  Editor.ResetStreamState;
  Editor.ProcessStream;
  DestroyOutputStream(Editor.Output);
  CloseFile(Handle);
  Editor.Output := StandardOutput;

  if InPlaceSuffix <> '' then
  begin
    BackupPath := Path + InPlaceSuffix;
    if PathExists(PChar(BackupPath)) then
      RemovePath(PChar(BackupPath));
    RenamePath(PChar(Path), PChar(BackupPath));
  end
  else
    RemovePath(PChar(Path));
  Error := RenamePath(PChar(TemporaryPath), PChar(Path));
  if Error <> ErrorNone then
    ReportError(Error, 'cannot rename ' + TemporaryPath);
end;

{ "-i" and "-iSUFFIX" share a letter with no separate value; they are
  replaced by an option of their own before the option parser sees
  them. }
function TakeInPlaceOptions: TStringArray;
const
  LongInPlace = '--in-place';
  TakenOption = '--in-place-taken';
var
  Index: Integer;
  Text: string;
begin
  Result := ProgramArguments;
  for Index := 0 to High(Result) do
  begin
    Text := Result[Index];
    if Text = '--' then
      Break;
    if StartsStr(LongInPlace, Text) then
    begin
      InPlace := True;
      if Copy(Text, Length(LongInPlace) + 1, 1) = '=' then
        InPlaceSuffix := Copy(Text, Length(LongInPlace) + 2, MaxInt);
      Result[Index] := TakenOption;
    end
    else if StartsStr('-i', Text) then
    begin
      InPlace := True;
      if Length(Text) > 2 then
        InPlaceSuffix := Copy(Text, 3, MaxInt);
      Result[Index] := TakenOption;
    end;
  end;
end;

procedure AddScriptFile(const Path: string);
var
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(1);
  while ReadTextLine(Stream, Line, HadLineEnd) do
    Script.AddText(Line);
  CloseInput(Stream);
end;

{ Reads the options; returns the index of the first input file among
  the operands. }
function ReadOptions(out CommandLine: TCommandLine): Integer;
var
  Code: Integer;
  Value: string;
  HaveScript: Boolean;
begin
  Syntax := SyntaxBasic;
  LineEnd := #10;
  HaveScript := False;
  CommandLine := TCommandLine.Create([
    CommandOption('n', 'quiet', False, OptionQuiet),
    CommandOption(#0, 'silent', False, OptionQuiet),
    CommandOption('e', 'expression', True, OptionExpression),
    CommandOption('f', 'file', True, OptionScriptFile),
    CommandOption('E', 'regexp-extended', False, OptionExtended),
    CommandOption('r', '', False, OptionExtended),
    CommandOption('s', 'separate', False, OptionSeparate),
    CommandOption('z', 'null-data', False, OptionNullData),
    CommandOption('u', 'unbuffered', False, OptionUnbuffered),
    CommandOption(#0, 'posix', False, OptionPosix),
    CommandOption(#0, 'in-place-taken', False, 0)], Usage, TakeInPlaceOptions);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionQuiet: Quiet := True;
      OptionExpression:
        begin
          Script.AddText(Value);
          HaveScript := True;
        end;
      OptionScriptFile:
        begin
          AddScriptFile(Value);
          HaveScript := True;
        end;
      OptionExtended: Syntax := SyntaxExtended;
      OptionSeparate: Separate := True;
      OptionNullData: LineEnd := #0;
    end;
  Result := 0;
  if not HaveScript then
  begin
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('no script specified');
    Script.AddText(CommandLine.Operands[0]);
    Result := 1;
  end;
end;

procedure RunInPlace(Editor: TStreamEditor; const InputFiles: TStringArray);
var
  Path: string;
begin
  Editor.Separate := True;
  if Length(InputFiles) = 0 then
    Fail(1, 'no input files');
  for Path in InputFiles do
  begin
    EditInPlace(Editor, Path);
    if Editor.Quitting then
      Break;
  end;
end;

procedure RunOnInput(Editor: TStreamEditor; const InputFiles: TStringArray);
begin
  if Length(InputFiles) = 0 then
    Editor.SetInputFiles(['-'])
  else
    Editor.SetInputFiles(InputFiles);
  if Separate then
    while Editor.HasInputLeft and not Editor.Quitting do
    begin
      Editor.ResetStreamState;
      Editor.ProcessStream;
    end
  else
  begin
    Editor.ResetStreamState;
    Editor.ProcessStream;
  end;
end;

var
  CommandLine: TCommandLine;
  FirstFile: Integer;
  InputFiles: TStringArray;
  Editor: TStreamEditor;
  ExitStatus: LongInt;
begin
  Script := TScript.Create;
  FirstFile := ReadOptions(CommandLine);
  InputFiles := Copy(CommandLine.Operands, FirstFile, MaxInt);
  CommandLine.Free;
  Script.Parse(Syntax);

  Editor := TStreamEditor.Create(Script);
  Editor.Quiet := Quiet;
  Editor.Separate := Separate;
  Editor.LineEnd := LineEnd;
  if InPlace then
    RunInPlace(Editor, InputFiles)
  else
    RunOnInput(Editor, InputFiles);
  ExitStatus := Editor.ExitStatus;
  if Editor.Quitting and (Editor.QuitCode <> 0) then
    ExitStatus := Editor.QuitCode;
  Editor.Free;
  { Closes the files written by w. }
  Script.Free;
  Halt(ExitStatus);
end.
