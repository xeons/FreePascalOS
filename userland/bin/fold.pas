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
  fold - wrap each input line to fit in specified width

  fold [-bs] [-w WIDTH] [FILE]...
}
program fold;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: fold [OPTION]... [FILE]...'#10 +
    'Wrap input lines in each FILE, writing to standard output.'#10 +
    #10 +
    '  -b, --bytes         count bytes rather than columns'#10 +
    '  -s, --spaces        break at spaces'#10 +
    '  -w, --width=WIDTH   use WIDTH columns instead of 80'#10;

  OptionBytes = 1;
  OptionSpaces = 2;
  OptionWidth = 3;

var
  BreakAtSpaces: Boolean;
  Width: Int64;

procedure FoldLine(const Line: string);
var
  Start: Int64;
  BreakAt: Int64;
  Index: Int64;
begin
  { Start and BreakAt are offsets from 0, as in the line's bytes. }
  Start := 0;
  while Length(Line) - Start > Width do
  begin
    BreakAt := Start + Width;
    if BreakAtSpaces then
    begin
      Index := BreakAt - 1;
      while (Index > Start) and (Line[Index + 1] <> ' ') do
        Dec(Index);
      if Index > Start then
        BreakAt := Index + 1;
    end;
    PrintStringLine(Copy(Line, Start + 1, BreakAt - Start));
    Start := BreakAt;
  end;
  PrintStringLine(Copy(Line, Start + 1, MaxInt));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  BreakAtSpaces := False;
  Width := 80;
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'bytes', False, OptionBytes),
    CommandOption('s', 'spaces', False, OptionSpaces),
    CommandOption('w', 'width', True, OptionWidth)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionSpaces: BreakAtSpaces := True;
      OptionWidth:
        if not ParseDecimal(Value, Width) or (Width < 1) then
          Fail(1, Format('invalid number of columns: ''%s''', [Value]));
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadTextLine(Stream, Line, HadLineEnd) do
      FoldLine(Line);
    CloseInput(Stream);
  end;
  CommandLine.Free;
  Halt(ExitStatus);
end.
