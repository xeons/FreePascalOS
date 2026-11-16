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
  head - output the first part of files

  head [-n [-]NUM | -c [-]NUM] [-qv] [FILE]...

  Prints the first 10 lines of each FILE. With a leading '-' on NUM,
  prints everything except the last NUM lines (or bytes). An old style
  "-NUM" means "-n NUM".
}
program head;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Sys.Environment,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Output,
  Util.Sizes;

const
  Usage = 'Usage: head [OPTION]... [FILE]...'#10 +
    'Print the first 10 lines of each FILE to standard output.'#10 +
    'With more than one FILE, precede each with a header giving the file name.'#10 +
    #10 +
    '  -c, --bytes=[-]NUM       print the first NUM bytes of each file;'#10 +
    '                             with the leading ''-'', print all but the last'#10 +
    '                             NUM bytes of each file'#10 +
    '  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;'#10 +
    '                             with the leading ''-'', print all but the last'#10 +
    '                             NUM lines of each file'#10 +
    '  -q, --quiet, --silent    never print headers giving file names'#10 +
    '  -v, --verbose            always print headers giving file names'#10;

  OptionBytes = 1;
  OptionLines = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;

  CopyBufferSize = 4096;

var
  CountBytes: Boolean;
  AllButLast: Boolean;
  Amount: QWord;

procedure ParseAmount(const Text: string);
var
  Number: string;
begin
  AllButLast := (Text <> '') and (Text[1] = '-');
  if AllButLast then
    Number := Copy(Text, 2, MaxInt)
  else
    Number := Text;
  if not ParseSize(Number, Amount) then
  begin
    if CountBytes then
      Fail(1, Format('invalid number of bytes: ''%s''', [Number]))
    else
      Fail(1, Format('invalid number of lines: ''%s''', [Number]));
  end;
end;

procedure HeadLines(Stream: PInputStream);
var
  Character: Char;
  LinesSeen: QWord;
begin
  LinesSeen := 0;
  while (LinesSeen < Amount) and ReadCharacter(Stream, Character) do
  begin
    WriteCharacter(StandardOutput, Character);
    if Character = #10 then
      Inc(LinesSeen);
  end;
end;

procedure HeadBytes(Stream: PInputStream);
var
  Buffer: array[0..CopyBufferSize - 1] of Byte;
  Remaining: QWord;
  Wanted: QWord;
  Count: QWord;
begin
  Remaining := Amount;
  while Remaining > 0 do
  begin
    Wanted := SizeOf(Buffer);
    if Wanted > Remaining then
      Wanted := Remaining;
    Count := ReadBytes(Stream, @Buffer[0], Wanted);
    if Count = 0 then
      Break;
    WriteBytes(StandardOutput, @Buffer[0], Count);
    Remaining := Remaining - Count;
  end;
end;

{ All but the last Amount lines: collect everything, then print. }
procedure HeadAllButLastLines(Stream: PInputStream);
var
  Lines: TStringList;
  Index: Integer;
  Keep: Int64;
begin
  Lines := TStringList.Create;
  try
    ReadLinesInto(Stream, Lines);
    Keep := Int64(Lines.Count) - Int64(Amount);
    for Index := 0 to Integer(Keep) - 1 do
      PrintStringLine(Lines[Index]);
  finally
    Lines.Free;
  end;
end;

procedure HeadAllButLastBytes(Stream: PInputStream);
var
  Contents: string;
begin
  Contents := ReadAllText(Stream);
  if QWord(Length(Contents)) > Amount then
    PrintString(Copy(Contents, 1, QWord(Length(Contents)) - Amount));
end;

procedure PrintHeader(const Path: string; IsFirst: Boolean);
begin
  if not IsFirst then
    PrintString(#10);
  if Path = '-' then
    PrintStringLine('==> standard input <==')
  else
    PrintStringLine('==> ' + Path + ' <==');
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
  ShowHeaders: Integer; { -1 never, 0 automatic, 1 always }
  OldStyle: string;
  Arguments: TStringArray;
begin
  CountBytes := False;
  AllButLast := False;
  Amount := 10;
  ShowHeaders := 0;

  { "head -5 file" is the old way of writing "head -n 5 file": the
    argument becomes "--", so everything after it is an operand. }
  Arguments := ProgramArguments;
  if (Length(Arguments) > 0) and (Length(Arguments[0]) >= 2) and (Arguments[0][1] = '-') and
     (Arguments[0][2] in ['0'..'9']) then
  begin
    OldStyle := Arguments[0];
    Arguments[0] := '--';
    Delete(OldStyle, 1, 1);
    if not ParseSize(OldStyle, Amount) then
      Fail(1, Format('invalid number of lines: ''%s''', [OldStyle]));
  end;

  CommandLine := TCommandLine.Create([
    CommandOption('c', 'bytes', True, OptionBytes),
    CommandOption('n', 'lines', True, OptionLines),
    CommandOption('q', 'quiet', False, OptionQuiet),
    CommandOption(#0, 'silent', False, OptionQuiet),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage, Arguments);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBytes:
        begin
          CountBytes := True;
          ParseAmount(Value);
        end;
      OptionLines:
        begin
          CountBytes := False;
          ParseAmount(Value);
        end;
      OptionQuiet: ShowHeaders := -1;
      OptionVerbose: ShowHeaders := 1;
    end;

  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  if ShowHeaders = 0 then
  begin
    if CommandLine.OperandCount > 1 then
      ShowHeaders := 1
    else
      ShowHeaders := -1;
  end;

  ExitStatus := 0;
  for Index := 0 to CommandLine.OperandCount - 1 do
  begin
    Stream := OpenInput(CommandLine.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if ShowHeaders = 1 then
      PrintHeader(CommandLine.Operands[Index], Index = 0);
    if CountBytes and AllButLast then
      HeadAllButLastBytes(Stream)
    else if CountBytes then
      HeadBytes(Stream)
    else if AllButLast then
      HeadAllButLastLines(Stream)
    else
      HeadLines(Stream);
    CloseInput(Stream);
  end;
  CommandLine.Free;
  Halt(ExitStatus);
end.
