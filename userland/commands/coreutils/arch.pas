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
  arch - print machine hardware name (same as uname -m)
}
program arch;

{$mode objfpc}{$H+}

uses
  Sys.Information,
  Util.CommandLine,
  Sys.Streams;

const
  Usage = 'Usage: arch'#10 +
    'Print machine architecture.'#10;

var
  CommandLine: TCommandLine;
  Information: TSystemInformation;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  CommandLine.Free;
  GetSystemInformation(Information);
  PrintStringLine(PChar(@Information.Machine[0]));
end.
