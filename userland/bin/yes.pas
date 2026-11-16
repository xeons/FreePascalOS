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
  SysUtils,
  Sys.Streams,
  Util.CommandLine;

const
  Usage = 'Usage: yes [STRING]...'#10 +
    'Repeatedly output a line with all specified STRING(s), or ''y''.'#10;

var
  CommandLine: TCommandLine;
  Line: string;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
    Line := 'y'
  else
    Line := String.Join(' ', CommandLine.Operands);
  Line := Line + #10;

  while not StandardOutput^.HadError do
    WriteBytes(StandardOutput, PChar(Line), Length(Line));
  Halt(0);
end.
