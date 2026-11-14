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
{$pointermath on}

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Modes,
  Util.Options;

const
  Usage: PChar = 'Usage: mkfifo [OPTION]... NAME...'#10 +
    'Create named pipes (FIFOs) with the given NAMEs.'#10#10 +
    '  -m, --mode=MODE   set file permission bits to MODE, not a=rw - umask'#10;

  OptionMode = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ModeText: PChar;
  ModeChange: TModeChange;
  Index: Integer;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  ModeText := nil;
  BeginOptions(Parser, [OptionDefinition('m', 'mode', True, OptionMode)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionMode then
      ModeText := Value;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  if (ModeText <> nil) and not ParseModeChange(ModeText, ModeChange) then
    Fail(1, 'invalid mode ''%s''', [ArgumentText(ModeText)]);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Error := CreateFifo(Parser.Operands[Index]);
    if (Error = ErrorNone) and (ModeText <> nil) then
      Error := ChangeMode(Parser.Operands[Index], ApplyModeChange(ModeChange, $1B6, False));
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'cannot create fifo ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
