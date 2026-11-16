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
  mktemp - create a temporary file or directory

  mktemp [-dqtu] [-p DIR] [--suffix=SUFFIX] [TEMPLATE]

  TEMPLATE ends in at least three X's, which are replaced by random
  letters and digits (default tmp.XXXXXXXXXX). The file is created
  exclusively, so it cannot be one that already existed; its name is
  printed.
}
program mktemp;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Crypto.Random,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: mktemp [OPTION]... [TEMPLATE]'#10 +
    'Create a temporary file or directory, safely, and print its name.'#10 +
    'TEMPLATE must contain at least 3 consecutive ''X''s in last component.'#10 +
    'If TEMPLATE is not specified, use tmp.XXXXXXXXXX, and --tmpdir is implied.'#10#10 +
    '  -d, --directory     create a directory, not a file'#10 +
    '  -u, --dry-run       do not create anything; merely print a name (unsafe)'#10 +
    '  -q, --quiet         suppress diagnostics about file/dir-creation failure'#10 +
    '      --suffix=SUFF   append SUFF to TEMPLATE'#10 +
    '  -p DIR, --tmpdir[=DIR]  interpret TEMPLATE relative to DIR; if DIR is not'#10 +
    '                        specified, use $TMPDIR if set, else /tmp'#10 +
    '  -t                  interpret TEMPLATE as a single file name component,'#10 +
    '                        relative to a directory: $TMPDIR, if set; else'#10 +
    '                        the directory specified via -p; else /tmp'#10;

  OptionDirectory = 1;
  OptionDryRun = 2;
  OptionQuiet = 3;
  OptionSuffix = 4;
  OptionTemporaryDirectory = 5;
  OptionRelativeToTemporary = 6;
  MaximumAttempts = 100;
  NameCharacters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

var
  MakeDirectory: Boolean;
  DryRun: Boolean;
  Quiet: Boolean;
  Suffix: string;
  Directory: string;
  UseDirectory: Boolean;
  Template: string;

procedure ReadOptions;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
begin
  MakeDirectory := False;
  DryRun := False;
  Quiet := False;
  Suffix := '';
  Directory := '';
  UseDirectory := False;
  BeginOptions(Parser, [
    OptionDefinition('d', 'directory', False, OptionDirectory),
    OptionDefinition('u', 'dry-run', False, OptionDryRun),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'suffix', True, OptionSuffix),
    OptionDefinition('p', 'tmpdir', True, OptionTemporaryDirectory),
    OptionDefinition('t', nil, False, OptionRelativeToTemporary)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDirectory: MakeDirectory := True;
      OptionDryRun: DryRun := True;
      OptionQuiet: Quiet := True;
      OptionSuffix: Suffix := Value;
      OptionTemporaryDirectory:
        begin
          Directory := Value;
          UseDirectory := True;
        end;
      OptionRelativeToTemporary: UseDirectory := True;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('too many templates', []);

  if Parser.OperandCount = 1 then
    Template := Parser.Operands[0]
  else
  begin
    Template := 'tmp.XXXXXXXXXX';
    UseDirectory := True;
  end;
  if UseDirectory and (Directory = '') then
  begin
    Directory := GetVariable('TMPDIR');
    if Directory = '' then
      Directory := '/tmp';
  end;
end;

{ Replaces the Count characters from Start with random name characters. }
procedure RandomizeName(var Path: string; Start, Count: Integer);
var
  Index: Integer;
begin
  for Index := Start to Start + Count - 1 do
    Path[Index] := NameCharacters[1 + RandomBelow(Length(NameCharacters))];
end;

{ Creates Path, failing if it exists; returns 0 or an error code. }
function CreateExclusively(const Path: string): LongInt;
var
  Handle: Int64;
begin
  if MakeDirectory then
    Exit(CreateDirectory(PChar(Path)));
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenExclusive);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  CloseFile(Handle);
  Result := ErrorNone;
end;

var
  Path: string;
  XStart: Integer;
  XCount: Integer;
  Attempt: Integer;
  Error: LongInt;
  Created: Boolean;
begin
  ReadOptions;

  Path := '';
  if UseDirectory then
  begin
    Path := Directory;
    if (Path <> '') and (Path[Length(Path)] <> '/') then
      Path := Path + '/';
  end;
  Path := Path + Template;
  XStart := Length(Path) + 1;
  XCount := 0;
  while (XStart > 1) and (Path[XStart - 1] = 'X') do
  begin
    Dec(XStart);
    Inc(XCount);
  end;
  if XCount < 3 then
    Fail(1, 'too few X''s in template ''%s''', [ArgumentText(PChar(Template))]);
  Path := Path + Suffix;

  Created := False;
  Error := ErrorExists;
  for Attempt := 1 to MaximumAttempts do
  begin
    RandomizeName(Path, XStart, XCount);
    if DryRun then
    begin
      if not PathExists(PChar(Path)) then
      begin
        Created := True;
        Break;
      end;
      Continue;
    end;
    Error := CreateExclusively(Path);
    if Error = ErrorNone then
    begin
      if not MakeDirectory then
        ChangeMode(PChar(Path), $180)   { rw------- }
      else
        ChangeMode(PChar(Path), $1C0);  { rwx------ }
      Created := True;
      Break;
    end;
    if Error <> ErrorExists then
      Break;
  end;
  if not Created then
  begin
    if not Quiet then
    begin
      if MakeDirectory then
        ReportError(Error, 'failed to create directory via template ''%s''', [ArgumentText(PChar(Template))])
      else
        ReportError(Error, 'failed to create file via template ''%s''', [ArgumentText(PChar(Template))]);
    end;
    Halt(1);
  end;
  PrintLine(PChar(Path));
end.
