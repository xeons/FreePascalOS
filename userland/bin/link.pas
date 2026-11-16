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

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Files,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: link FILE1 FILE2'#10 +
    'Call the link function to create a link named FILE2 to an existing FILE1.'#10;

var
  CommandLine: TCommandLine;
  Error: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount < 2 then
    FailWithUsageHint('missing operand');
  if CommandLine.OperandCount > 2 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
  Error := CreateHardLink(PChar(CommandLine.Operands[0]), PChar(CommandLine.Operands[1]));
  if Error <> 0 then
    FailWithError(1, Error, Format('cannot create link ''%s'' to ''%s''',
      [CommandLine.Operands[1], CommandLine.Operands[0]]));
  CommandLine.Free;
end.
