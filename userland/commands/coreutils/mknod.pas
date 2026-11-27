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
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Modes;

const
  Usage = 'Usage: mknod [OPTION]... NAME TYPE [MAJOR MINOR]'#10 +
    'Create the special file NAME of the given TYPE.'#10#10 +
    '  -m, --mode=MODE   set file permission bits to MODE, not a=rw - umask'#10#10 +
    'TYPE may be:'#10 +
    '  b      create a block (buffered) special file (not supported)'#10 +
    '  c, u   create a character (unbuffered) special file (not supported)'#10 +
    '  p      create a FIFO'#10;

  OptionMode = 1;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  HasMode: Boolean;
  ModeChange: TModeChange;
  Name: string;
  Kind: string;
  Error: LongInt;
begin
  CommandLine := TCommandLine.Create([CommandOption('m', 'mode', True, OptionMode)], Usage);
  while CommandLine.NextOption(Code, Value) do
    ;
  if CommandLine.OperandCount < 2 then
    FailWithUsageHint('missing operand');
  HasMode := CommandLine.OptionGiven(OptionMode);
  if HasMode and not ParseModeChange(CommandLine.OptionValue(OptionMode), ModeChange) then
    Fail(1, Format('invalid mode ''%s''', [CommandLine.OptionValue(OptionMode)]));
  Name := CommandLine.Operands[0];
  Kind := CommandLine.Operands[1];
  if Kind = 'p' then
  begin
    if CommandLine.OperandCount > 2 then
      FailWithUsageHint('Fifos do not have major and minor device numbers.');
    Error := CreateFifo(PChar(Name));
    if (Error = ErrorNone) and HasMode then
      Error := ChangeMode(PChar(Name), ApplyModeChange(ModeChange, $1B6, False));
    if Error <> ErrorNone then
      FailWithError(1, Error, Format('''%s''', [Name]));
  end
  else if (Kind = 'b') or (Kind = 'c') or (Kind = 'u') then
    Fail(1, Format('''%s'': device files are not supported', [Name]))
  else
    FailWithUsageHint(Format('invalid device type ''%s''', [Kind]));
end.
