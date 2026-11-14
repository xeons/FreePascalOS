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
  tac - concatenate and print files in reverse

  tac [FILE]...

  Prints the lines of each FILE, last line first.
}
program tac;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Streams,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: tac [FILE]...'#10 +
    'Write each FILE to standard output, last line first.'#10;

var
  Parser: TOptionParser;
  Lines: TLineList;
  Index: Integer;
  Line: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    BeginLineList(Lines);
    ReadAllLines(Stream, Lines);
    CloseInput(Stream);
    Line := Lines.Count - 1;
    while Line >= 0 do
    begin
      WriteLine(StandardOutput, Lines.Items[Line]);
      Dec(Line);
    end;
    FreeLineList(Lines);
  end;
  Halt(ExitStatus);
end.
