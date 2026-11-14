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
  link - make a hard link

  link FILE1 FILE2

  Only ext2/3/4 volumes support hard links.
}
program link;

{$mode objfpc}

uses
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: link FILE1 FILE2'#10 +
    'Call the link function to create a link named FILE2 to an existing FILE1.'#10;

var
  Parser: TOptionParser;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing operand', []);
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
  Error := CreateHardLink(Parser.Operands[0], Parser.Operands[1]);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot create link ''%s'' to ''%s''', [ArgumentText(Parser.Operands[1]),
      ArgumentText(Parser.Operands[0])]);
end.
