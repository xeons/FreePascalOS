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

{$mode objfpc}{$H+}

uses
  Classes,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages;

const
  Usage = 'Usage: tac [FILE]...'#10 +
    'Write each FILE to standard output, last line first.'#10;

var
  CommandLine: TCommandLine;
  Lines: TStringList;
  Operand: string;
  Line: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  ExitStatus := 0;
  Lines := TStringList.Create;
  try
    for Operand in CommandLine.Operands do
    begin
      Stream := OpenInput(Operand);
      if Stream = nil then
      begin
        ExitStatus := 1;
        Continue;
      end;
      Lines.Clear;
      ReadLinesInto(Stream, Lines);
      CloseInput(Stream);
      for Line := Lines.Count - 1 downto 0 do
        PrintStringLine(Lines[Line]);
    end;
  finally
    Lines.Free;
  end;
  Halt(ExitStatus);
end.
