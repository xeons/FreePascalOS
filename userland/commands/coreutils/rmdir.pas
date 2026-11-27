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
  rmdir - remove empty directories

  rmdir [-pv] [--ignore-fail-on-non-empty] DIRECTORY...
}
program rmdir;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams;

const
  Usage = 'Usage: rmdir [OPTION]... DIRECTORY...'#10 +
    'Remove the DIRECTORY(ies), if they are empty.'#10 +
    #10 +
    '      --ignore-fail-on-non-empty'#10 +
    '                    ignore each failure to remove a non-empty directory'#10 +
    '  -p, --parents     remove DIRECTORY and its ancestors'#10 +
    '  -v, --verbose     output a diagnostic for every directory processed'#10;

  OptionIgnoreNonEmpty = 1;
  OptionParents = 2;
  OptionVerbose = 3;

var
  IgnoreNonEmpty: Boolean;
  Verbose: Boolean;

{ Returns False if an error was reported. }
function RemoveOne(const Path: string): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  if Verbose then
    PrintString(Format('%s: removing directory, ''%s'''#10, [ProgramName, Path]));
  Error := GetLinkInformation(PChar(Path), Information);
  if (Error = ErrorNone) and (Information.Kind <> KindDirectory) then
    Error := ErrorNotDirectory;
  if Error = ErrorNone then
    Error := RemovePath(PChar(Path));
  if (Error = ErrorDirectoryNotEmpty) and IgnoreNonEmpty then
    Exit(True);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('failed to remove ''%s''', [Path]));
    Exit(False);
  end;
  Result := True;
end;

{ a/b/c: then a/b, then a. Returns False if an error was reported. }
function RemoveParents(Path: string): Boolean;
var
  LastSlash: Integer;
begin
  Result := True;
  repeat
    while (Length(Path) > 1) and (Path[Length(Path)] = '/') do
      SetLength(Path, Length(Path) - 1);
    LastSlash := LastDelimiter('/', Path);
    if LastSlash <= 1 then
      Break;
    SetLength(Path, LastSlash - 1);
    if not RemoveOne(Path) then
      Exit(False);
  until False;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Parents: Boolean;
  ExitStatus: LongInt;
  Path: string;
begin
  IgnoreNonEmpty := False;
  Parents := False;
  Verbose := False;
  CommandLine := TCommandLine.Create([
    CommandOption(#0, 'ignore-fail-on-non-empty', False, OptionIgnoreNonEmpty),
    CommandOption('p', 'parents', False, OptionParents),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionIgnoreNonEmpty: IgnoreNonEmpty := True;
      OptionParents: Parents := True;
      OptionVerbose: Verbose := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Path in CommandLine.Operands do
  begin
    if not RemoveOne(Path) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if Parents and not RemoveParents(Path) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
