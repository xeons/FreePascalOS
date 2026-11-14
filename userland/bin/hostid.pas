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
  hostid - print the numeric identifier for the current host

  Derived from the node name, as eight hexadecimal digits.
}
program hostid;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Crypto.Checksums,
  Sys.Format,
  Sys.Information,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: hostid'#10 +
    'Print the numeric identifier (in hexadecimal) for the current host.'#10;

var
  Parser: TOptionParser;
  Information: TSystemInformation;
  Identifier: LongWord;
begin
  ParseOperandsOnly(Parser, Usage);
  GetSystemInformation(Information);
  Identifier := Crc32Finish(Crc32Update(Crc32Initial, @Information.NodeName[0],
    TextLength(@Information.NodeName[0])));
  WriteFormatted(StandardOutput, '%08x'#10, [ArgumentUnsigned(Identifier)]);
end.
