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
  pathchk - check whether file names are valid or portable

  pathchk [-pP] [--portability] NAME...

  Without options, checks this system's limits (255 bytes per component,
  1023 per name) and that existing leading components are directories.
  -p checks POSIX portability (14 bytes per component, 256 per name,
  only A-Z a-z 0-9 . _ -); -P rejects empty names and components
  starting with '-'.
}
program pathchk;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: pathchk [OPTION]... NAME...'#10 +
    'Diagnose invalid or non-portable file names.'#10#10 +
    '  -p                  check for most POSIX systems'#10 +
    '  -P                  check for empty names and leading "-"'#10 +
    '      --portability   check for all POSIX systems (equivalent to -p -P)'#10;

  OptionPosix = 1;
  OptionExtra = 2;
  OptionPortability = 3;

  SystemComponentLimit = 255;
  SystemPathLimit = 1023;
  PosixComponentLimit = 14;
  PosixPathLimit = 256;

  PortableCharacters = ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-', '/'];

var
  CheckPosix: Boolean;
  CheckExtra: Boolean;

function HasOnlyPortableCharacters(const Name: string): Boolean;
var
  Character: Char;
begin
  for Character in Name do
    if not (Character in PortableCharacters) then
    begin
      Report(Format('nonportable character ''%s'' in file name ''%s''', [Character, Name]));
      Exit(False);
    end;
  Result := True;
end;

{ Checks the component of Name from Start (1-based) to just before
  Finish, which is the end of Name or a '/'. }
function CheckComponent(const Name: string; Start, Finish: Integer; ComponentLimit: Integer): Boolean;
var
  Prefix: string;
  Information: TFileInformation;
begin
  if Finish - Start > ComponentLimit then
  begin
    Report(Format('limit %d exceeded by length %d of file name component ''%s''', [ComponentLimit,
      Finish - Start, Copy(Name, Start, MaxInt)]));
    Exit(False);
  end;
  if CheckExtra and (Finish > Start) and (Name[Start] = '-') then
  begin
    Report(Format('leading ''-'' in a component of file name ''%s''', [Name]));
    Exit(False);
  end;
  { Without -p, existing leading parts must be directories. }
  if not CheckPosix and (Finish <= Length(Name)) and (Finish > 1) then
  begin
    Prefix := Copy(Name, 1, Finish - 1);
    if (GetFileInformation(PChar(Prefix), Information) = 0) and (Information.Kind <> KindDirectory) then
    begin
      Report(Format('''%s'' is not a directory', [Prefix]));
      Exit(False);
    end;
  end;
  Result := True;
end;

function CheckName(const Name: string): Boolean;
var
  Position: Integer;
  ComponentStart: Integer;
  ComponentLimit: Integer;
  PathLimit: Integer;
begin
  if CheckExtra and (Name = '') then
  begin
    Report('empty file name');
    Exit(False);
  end;
  if CheckPosix then
  begin
    ComponentLimit := PosixComponentLimit;
    PathLimit := PosixPathLimit;
    if not HasOnlyPortableCharacters(Name) then
      Exit(False);
  end
  else
  begin
    ComponentLimit := SystemComponentLimit;
    PathLimit := SystemPathLimit;
  end;
  if Length(Name) > PathLimit then
  begin
    Report(Format('limit %d exceeded by length %d of file name ''%s''', [PathLimit,
      Length(Name), Name]));
    Exit(False);
  end;

  ComponentStart := 1;
  for Position := 1 to Length(Name) + 1 do
    if (Position > Length(Name)) or (Name[Position] = '/') then
    begin
      if not CheckComponent(Name, ComponentStart, Position, ComponentLimit) then
        Exit(False);
      ComponentStart := Position + 1;
    end;
  Result := True;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('p', '', False, OptionPosix),
    CommandOption('P', '', False, OptionExtra),
    CommandOption(#0, 'portability', False, OptionPortability)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionPosix: CheckPosix := True;
      OptionExtra: CheckExtra := True;
      OptionPortability:
        begin
          CheckPosix := True;
          CheckExtra := True;
        end;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
    if not CheckName(Operand) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
