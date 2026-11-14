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
  yes - output a string repeatedly until killed

  yes [STRING]...

  Writes the arguments separated by spaces (or "y") followed by a line
  end, over and over. It stops when the output can no longer be written,
  for example when the reading end of a pipe closes.
}
program yes;

{$mode objfpc}

uses
  Sys.Environment,
  Sys.Streams,
  Sys.Text,
  Util.Options;

const
  Usage: PChar = 'Usage: yes [STRING]...'#10 +
    'Repeatedly output a line with all specified STRING(s), or ''y''.'#10;

var
  Parser: TOptionParser;
  Line: TTextBuilder;
  Index: Integer;
begin
  ParseOperandsOnly(Parser, Usage);
  BeginText(Line);
  if Parser.OperandCount = 0 then
    AppendText(Line, 'y')
  else
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      if Index > 0 then
        AppendCharacter(Line, ' ');
      AppendText(Line, Parser.Operands[Index]);
    end;
  AppendCharacter(Line, #10);

  while not StandardOutput^.HadError do
    WriteBytes(StandardOutput, Line.Text, Line.Length);
  Halt(0);
end.
