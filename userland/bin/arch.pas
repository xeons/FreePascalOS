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

{$mode objfpc}

uses
  Sys.Information,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: arch'#10 +
    'Print machine architecture.'#10;

var
  Parser: TOptionParser;
  Information: TSystemInformation;
begin
  ParseOperandsOnly(Parser, Usage);
  GetSystemInformation(Information);
  PrintLine(@Information.Machine[0]);
end.
