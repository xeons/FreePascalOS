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
  paste - merge lines of files

  paste [-s] [-d LIST] [FILE]...

  Writes lines made of the corresponding lines of each FILE, separated
  by TABs (or the characters of LIST, used in turn). With -s, each file
  is pasted onto one line instead.
}
program paste;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: paste [OPTION]... [FILE]...'#10 +
    'Write lines consisting of the sequentially corresponding lines from'#10 +
    'each FILE, separated by TABs, to standard output.'#10 +
    #10 +
    '  -d, --delimiters=LIST   reuse characters from LIST instead of TABs'#10 +
    '  -s, --serial            paste one file at a time instead of in parallel'#10;

  OptionDelimiters = 1;
  OptionSerial = 2;
  MaximumFiles = 32;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Delimiters: PChar;
  DelimiterCount: Integer;
  Serial: Boolean;
  Streams: array[0..MaximumFiles - 1] of PInputStream;
  Index: Integer;
  Line: PChar;
  HadLineEnd: Boolean;
  AnyLine: Boolean;
  Position: Integer;
  Output: TTextBuilder;
  ExitStatus: LongInt;
begin
  Delimiters := #9;
  Serial := False;
  BeginOptions(Parser, [
    OptionDefinition('d', 'delimiters', True, OptionDelimiters),
    OptionDefinition('s', 'serial', False, OptionSerial)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDelimiters: Delimiters := Value;
      OptionSerial: Serial := True;
    end;
  DelimiterCount := Integer(TextLength(Delimiters));
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  if Parser.OperandCount > MaximumFiles then
    Fail(1, 'too many files', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Streams[Index] := OpenInput(Parser.Operands[Index]);
    if Streams[Index] = nil then
      ExitStatus := 1;
  end;

  if Serial then
  begin
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      if Streams[Index] = nil then
        Continue;
      Position := 0;
      while ReadLine(Streams[Index], Line, HadLineEnd) do
      begin
        if (Position > 0) and (DelimiterCount > 0) then
          WriteCharacter(StandardOutput, Delimiters[(Position - 1) mod DelimiterCount]);
        WriteText(StandardOutput, Line);
        FreeMemory(Line);
        Inc(Position);
      end;
      WriteCharacter(StandardOutput, #10);
    end;
  end
  else
    repeat
      { Build the whole output line; print it only if some file still
        had a line. }
      AnyLine := False;
      BeginText(Output);
      for Index := 0 to Parser.OperandCount - 1 do
      begin
        if (Index > 0) and (DelimiterCount > 0) then
          AppendCharacter(Output, Delimiters[(Index - 1) mod DelimiterCount]);
        if (Streams[Index] <> nil) and ReadLine(Streams[Index], Line, HadLineEnd) then
        begin
          AppendText(Output, Line);
          FreeMemory(Line);
          AnyLine := True;
        end;
      end;
      if AnyLine then
        WriteLine(StandardOutput, Output.Text);
      DiscardText(Output);
    until not AnyLine;

  for Index := 0 to Parser.OperandCount - 1 do
    CloseInput(Streams[Index]);
  Halt(ExitStatus);
end.
