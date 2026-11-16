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

{$mode objfpc}{$H+}

uses
  Util.CommandLine,
  Util.Messages,
  Sys.Streams,
  Sys.Files;

const
  Usage = 'Usage: pwd'#10 +
    'Print the full name of the current working directory.'#10;

var
  CommandLine: TCommandLine;
  Directory: string;
  Error: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  Error := CurrentDirectoryPath(Directory);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot get the current directory');
  PrintStringLine(Directory);
end.
