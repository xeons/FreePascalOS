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
  pwd - print name of current/working directory
}
program pwd;

{$mode objfpc}

uses
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: pwd'#10 +
    'Print the full name of the current working directory.'#10;

var
  Parser: TOptionParser;
  Directory: array[0..PathCapacity - 1] of Char;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  Error := GetCurrentDirectory(@Directory[0], PathCapacity);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot get the current directory', []);
  PrintLine(@Directory[0]);
end.
