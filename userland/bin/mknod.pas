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
  mknod - make special files

  mknod [-m MODE] NAME TYPE [MAJOR MINOR]

  Only TYPE p (a named pipe, like mkfifo) is supported: the system has
  no device files, so b and c are refused.
}
program mknod;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Modes,
  Util.Options;

const
  Usage: PChar = 'Usage: mknod [OPTION]... NAME TYPE [MAJOR MINOR]'#10 +
    'Create the special file NAME of the given TYPE.'#10#10 +
    '  -m, --mode=MODE   set file permission bits to MODE, not a=rw - umask'#10#10 +
    'TYPE may be:'#10 +
    '  b      create a block (buffered) special file (not supported)'#10 +
    '  c, u   create a character (unbuffered) special file (not supported)'#10 +
    '  p      create a FIFO'#10;

  OptionMode = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ModeText: string;
  HasMode: Boolean;
  ModeChange: TModeChange;
  Kind: string;
  Error: LongInt;
begin
  ModeText := '';
  HasMode := False;
  BeginOptions(Parser, [OptionDefinition('m', 'mode', True, OptionMode)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionMode then
    begin
      ModeText := Value;
      HasMode := True;
    end;
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing operand', []);
  if HasMode and not ParseModeChange(PChar(ModeText), ModeChange) then
    Fail(1, 'invalid mode ''%s''', [ArgumentText(PChar(ModeText))]);
  Kind := Parser.Operands[1];
  if Kind = 'p' then
  begin
    if Parser.OperandCount > 2 then
      FailWithUsageHint('Fifos do not have major and minor device numbers.', []);
    Error := CreateFifo(Parser.Operands[0]);
    if (Error = ErrorNone) and HasMode then
      Error := ChangeMode(Parser.Operands[0], ApplyModeChange(ModeChange, $1B6, False));
    if Error <> ErrorNone then
      FailWithError(1, Error, '''%s''', [ArgumentText(Parser.Operands[0])]);
  end
  else if (Kind = 'b') or (Kind = 'c') or (Kind = 'u') then
    Fail(1, '''%s'': device files are not supported', [ArgumentText(Parser.Operands[0])])
  else
    FailWithUsageHint('invalid device type ''%s''', [ArgumentText(PChar(Kind))]);
end.
