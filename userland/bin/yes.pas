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
{$H+}

uses
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: yes [STRING]...'#10 +
    'Repeatedly output a line with all specified STRING(s), or ''y''.'#10;

var
  Parser: TOptionParser;
  Line: string;
  Index: Integer;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
    Line := 'y'
  else
  begin
    Line := Parser.Operands[0];
    for Index := 1 to Parser.OperandCount - 1 do
      Line := Line + ' ' + Parser.Operands[Index];
  end;
  Line := Line + #10;

  while not StandardOutput^.HadError do
    WriteBytes(StandardOutput, PChar(Line), Length(Line));
  Halt(0);
end.
