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
{$H+}

uses
  SysUtils,
  Sys.Memory,
  Sys.Streams,
  Util.Input,
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

var
  Delimiters: string;
  Streams: array of PInputStream;

function ReadTextLine(Stream: PInputStream; out Line: string): Boolean;
var
  Text: PChar;
  HadLineEnd: Boolean;
begin
  Result := ReadLine(Stream, Text, HadLineEnd);
  Line := '';
  if Result then
  begin
    Line := Text;
    FreeMemory(Text);
  end;
end;

{ The delimiter that goes before the field at Position (1 or more). }
function DelimiterBefore(Position: Integer): string;
begin
  if Delimiters = '' then
    Result := ''
  else
    Result := Delimiters[(Position - 1) mod Length(Delimiters) + 1];
end;

procedure PasteSerially;
var
  Index: Integer;
  Position: Integer;
  Line: string;
  Output: string;
begin
  for Index := 0 to High(Streams) do
  begin
    if Streams[Index] = nil then
      Continue;
    Output := '';
    Position := 0;
    while ReadTextLine(Streams[Index], Line) do
    begin
      if Position > 0 then
        Output := Output + DelimiterBefore(Position);
      Output := Output + Line;
      Inc(Position);
    end;
    WriteLine(StandardOutput, PChar(Output));
  end;
end;

procedure PasteInParallel;
var
  Index: Integer;
  Line: string;
  Output: string;
  AnyLine: Boolean;
begin
  repeat
    { Build the whole output line; print it only if some file still
      had a line. }
    AnyLine := False;
    Output := '';
    for Index := 0 to High(Streams) do
    begin
      if Index > 0 then
        Output := Output + DelimiterBefore(Index);
      if (Streams[Index] <> nil) and ReadTextLine(Streams[Index], Line) then
      begin
        Output := Output + Line;
        AnyLine := True;
      end;
    end;
    if AnyLine then
      WriteLine(StandardOutput, PChar(Output));
  until not AnyLine;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Serial: Boolean;
  Index: Integer;
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

  ExitStatus := 0;
  if Parser.OperandCount = 0 then
    Streams := [OpenInput('-')]
  else
  begin
    SetLength(Streams, Parser.OperandCount);
    for Index := 0 to Parser.OperandCount - 1 do
      Streams[Index] := OpenInput(Parser.Operands[Index]);
  end;
  for Index := 0 to High(Streams) do
    if Streams[Index] = nil then
      ExitStatus := 1;

  if Serial then
    PasteSerially
  else
    PasteInParallel;

  for Index := 0 to High(Streams) do
    CloseInput(Streams[Index]);
  Halt(ExitStatus);
end.
