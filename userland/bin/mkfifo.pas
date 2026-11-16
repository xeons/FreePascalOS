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
  mkfifo - make named pipes

  mkfifo [-m MODE] NAME...

  Each NAME becomes a named pipe: whatever one program writes into it
  another reads out, as with "|". Opening it for reading waits for a
  writer, and opening it for writing waits for a reader.
}
program mkfifo;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Modes;

const
  Usage = 'Usage: mkfifo [OPTION]... NAME...'#10 +
    'Create named pipes (FIFOs) with the given NAMEs.'#10#10 +
    '  -m, --mode=MODE   set file permission bits to MODE, not a=rw - umask'#10;

  OptionMode = 1;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  HasMode: Boolean;
  ModeChange: TModeChange;
  Name: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([CommandOption('m', 'mode', True, OptionMode)], Usage);
  while CommandLine.NextOption(Code, Value) do
    ;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');
  HasMode := CommandLine.OptionGiven(OptionMode);
  if HasMode and not ParseModeChange(CommandLine.OptionValue(OptionMode), ModeChange) then
    Fail(1, Format('invalid mode ''%s''', [CommandLine.OptionValue(OptionMode)]));

  ExitStatus := 0;
  for Name in CommandLine.Operands do
  begin
    Error := CreateFifo(PChar(Name));
    if (Error = ErrorNone) and HasMode then
      Error := ChangeMode(PChar(Name), ApplyModeChange(ModeChange, $1B6, False));
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot create fifo ''%s''', [Name]));
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
