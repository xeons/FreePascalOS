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
  tail - output the last part of files

  tail [-n [+]NUM | -c [+]NUM] [-qv] [FILE]...

  Prints the last 10 lines of each FILE. With a leading '+' on NUM,
  prints starting at line (or byte) NUM instead. An old style "-NUM"
  means "-n NUM".
}
program tail;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Output,
  Util.Sizes;

const
  Usage = 'Usage: tail [OPTION]... [FILE]...'#10 +
    'Print the last 10 lines of each FILE to standard output.'#10 +
    'With more than one FILE, precede each with a header giving the file name.'#10 +
    #10 +
    '  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to'#10 +
    '                             output starting with byte NUM of each file'#10 +
    '  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;'#10 +
    '                             or use -n +NUM to skip NUM-1 lines at the start'#10 +
    '  -q, --quiet, --silent    never output headers giving file names'#10 +
    '  -v, --verbose            always output headers giving file names'#10;

  OptionBytes = 1;
  OptionLines = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;

var
  CountBytes: Boolean;
  FromStart: Boolean;
  Amount: QWord;

procedure ParseAmount(const Text: string);
var
  Number: string;
begin
  FromStart := (Text <> '') and (Text[1] = '+');
  Number := Text;
  if (Number <> '') and (Number[1] in ['+', '-']) then
    Delete(Number, 1, 1);
  if not ParseSize(Number, Amount) then
  begin
    if CountBytes then
      Fail(1, Format('invalid number of bytes: ''%s''', [Number]))
    else
      Fail(1, Format('invalid number of lines: ''%s''', [Number]));
  end;
end;

procedure TailLines(Stream: PInputStream);
var
  Lines: TStringList;
  LastLineTerminated: Boolean;
  First: Int64;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    LastLineTerminated := ReadLinesInto(Stream, Lines);
    if FromStart then
    begin
      First := Int64(Amount) - 1;
      if First < 0 then
        First := 0;
    end
    else
    begin
      First := Int64(Lines.Count) - Int64(Amount);
      if First < 0 then
        First := 0;
    end;
    Index := Integer(First);
    while Index < Lines.Count do
    begin
      if (Index < Lines.Count - 1) or LastLineTerminated then
        PrintStringLine(Lines[Index])
      else
        PrintString(Lines[Index]);
      Inc(Index);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TailBytes(Stream: PInputStream);
var
  Contents: TMemoryStream;
  Buffer: array[0..4095] of Byte;
  Count: QWord;
  Start: QWord;
  Size: QWord;
begin
  Contents := TMemoryStream.Create;
  try
    repeat
      Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
      Contents.WriteBuffer(Buffer[0], Count);
    until Count = 0;
    Size := Contents.Size;
    if FromStart then
    begin
      Start := 0;
      if Amount > 0 then
        Start := Amount - 1;
    end
    else if Size > Amount then
      Start := Size - Amount
    else
      Start := 0;
    if Start < Size then
      WriteBytes(StandardOutput, PChar(Contents.Memory) + Start, Size - Start);
  finally
    Contents.Free;
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
  ShowHeaders: Integer;
  OldStyle: string;
  Arguments: TStringArray;
begin
  CountBytes := False;
  FromStart := False;
  Amount := 10;
  ShowHeaders := 0;

  { "tail -5 file" and "tail +5 file" are the old ways of writing
    "tail -n 5 file": the argument becomes "--", so everything after it
    is an operand. }
  Arguments := ProgramArguments;
  if (Length(Arguments) > 0) and (Length(Arguments[0]) >= 2) and (Arguments[0][1] in ['-', '+']) and
     (Arguments[0][2] in ['0'..'9']) then
  begin
    OldStyle := Arguments[0];
    Arguments[0] := '--';
    ParseAmount(OldStyle);
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
    begin
      if Index > 0 then
        WriteCharacter(StandardOutput, #10);
      if CommandLine.Operands[Index] = '-' then
        PrintStringLine('==> standard input <==')
      else
        PrintStringLine('==> ' + CommandLine.Operands[Index] + ' <==');
    end;
    if CountBytes then
      TailBytes(Stream)
    else
      TailLines(Stream);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
