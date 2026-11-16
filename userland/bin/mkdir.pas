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
  mkdir - make directories

  mkdir [-pv] DIRECTORY...

  -p creates missing parent directories and does not complain about
  directories that already exist.
}
program mkdir;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Modes,
  Util.Output;

const
  Usage = 'Usage: mkdir [OPTION]... DIRECTORY...'#10 +
    'Create the DIRECTORY(ies), if they do not already exist.'#10 +
    #10 +
    '  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask'#10 +
    '  -p, --parents     no error if existing, make parent directories as needed'#10 +
    '  -v, --verbose     print a message for each created directory'#10;

  OptionMode = 1;
  OptionParents = 2;
  OptionVerbose = 3;

var
  Verbose: Boolean;
  ModeChange: TModeChange;

function MakeOne(const Path: string): LongInt;
begin
  Result := CreateDirectory(PChar(Path));
  if (Result = ErrorNone) and Verbose then
    PrintString(Format('%s: created directory ''%s'''#10, [ProgramNameText, Path]));
end;

{ Creates every missing directory along Path. }
function MakeWithParents(const Path: string): LongInt;
var
  Position: Integer;
  Prefix: string;
begin
  Result := ErrorNone;
  { A leading '/' is part of the first component. }
  for Position := 2 to Length(Path) do
    if Path[Position] = '/' then
    begin
      Prefix := Copy(Path, 1, Position - 1);
      if not IsDirectory(PChar(Prefix)) then
      begin
        Result := MakeOne(Prefix);
        if Result <> ErrorNone then
          Exit;
      end;
    end;
  if not IsDirectory(PChar(Path)) then
    Result := MakeOne(Path);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Parents: Boolean;
  Path: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Parents := False;
  Verbose := False;
  CommandLine := TCommandLine.Create([
    CommandOption('m', 'mode', True, OptionMode),
    CommandOption('p', 'parents', False, OptionParents),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionMode:
        begin
          if not ParseModeChange(Value, ModeChange) then
            Fail(1, Format('invalid mode ''%s''', [Value]));
        end;
      OptionParents: Parents := True;
      OptionVerbose: Verbose := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Path in CommandLine.Operands do
  begin
    if Parents then
      Error := MakeWithParents(Path)
    else
      Error := MakeOne(Path);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot create directory ''%s''', [Path]));
      ExitStatus := 1;
    end
    else if CommandLine.OptionGiven(OptionMode) then
    begin
      { The mode applies to the named directory, as in GNU mkdir. }
      Error := ChangeMode(PChar(Path), ApplyModeChange(ModeChange, $1ED, True));
      if Error <> ErrorNone then
      begin
        ReportError(Error, Format('cannot set permissions of ''%s''', [Path]));
        ExitStatus := 1;
      end;
    end;
  end;
  Halt(ExitStatus);
end.
