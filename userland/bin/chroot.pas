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
  chroot - run command with special root directory

  chroot NEWROOT [COMMAND [ARG]...]

  Without COMMAND runs "$SHELL -i" (or /bin/sh -i). The command is looked
  up inside NEWROOT; shared libraries still come from the system's /lib.
}
program chroot;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Environment,
  Sys.Processes,
  Util.Commands,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: chroot [OPTION] NEWROOT [COMMAND [ARG]...]'#10 +
    'Run COMMAND with root directory set to NEWROOT.'#10#10 +
    'If no command is given, run ''"$SHELL" -i'' (default: ''/bin/sh -i'').'#10;

  StatusChrootFailed = 125;

{ The arguments from First on. }
function ArgumentsFrom(First: Integer): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, ArgumentTotal - First);
  for Index := First to ArgumentTotal - 1 do
    Result[Index - First] := Argument(Index);
end;

{ $SHELL, or /bin/sh when it is not set. }
function ShellPath: string;
var
  Value: PChar;
begin
  Value := GetVariable('SHELL');
  if Value = nil then
    Result := '/bin/sh'
  else
    Result := Value;
end;

var
  Error: LongInt;
  Options: TProcessOptions;
  First: Integer;
  NewRoot: string;
begin
  First := 1;
  if (ArgumentTotal > 1) and (Argument(1) = '--help') then
  begin
    PrintString(Usage);
    Halt(0);
  end;
  if (ArgumentTotal > 1) and (Argument(1) = '--') then
    Inc(First);
  if First >= ArgumentTotal then
  begin
    Report('missing operand');
    Halt(StatusChrootFailed);
  end;

  NewRoot := Argument(First);
  Error := ChangeRootDirectory(PChar(NewRoot));
  if Error <> 0 then
    FailWithError(StatusChrootFailed, Error, Format('cannot change root directory to ''%s''', [NewRoot]));

  DefaultProcessOptions(Options);
  if First + 1 < ArgumentTotal then
    RunCommandAndExit(ArgumentsFrom(First + 1), Options);
  RunCommandAndExit([ShellPath, '-i'], Options);
end.
