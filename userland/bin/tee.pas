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
  tee - read from standard input and write to standard output and files

  tee [-a] [FILE]...
}
program tee;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: tee [OPTION]... [FILE]...'#10 +
    'Copy standard input to each FILE, and also to standard output.'#10 +
    #10 +
    '  -a, --append              append to the given FILEs, do not overwrite'#10 +
    '  -i, --ignore-interrupts   ignore interrupt signals (no effect here)'#10;

  OptionAppend = 1;
  OptionIgnore = 2;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Append: Boolean;
  Paths: TStringArray;
  Handles: array of Int64;
  Index: Integer;
  Flags: LongWord;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  ExitStatus: LongInt;
  Error: LongInt;
begin
  Append := False;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'append', False, OptionAppend),
    CommandOption('i', 'ignore-interrupts', False, OptionIgnore)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionAppend then
      Append := True;
  Paths := CommandLine.Operands;
  SetLength(Handles, Length(Paths));

  if Append then
    Flags := OpenWrite or OpenCreate or OpenAppend
  else
    Flags := OpenWrite or OpenCreate or OpenTruncate;
  ExitStatus := 0;
  for Index := 0 to High(Paths) do
  begin
    Handles[Index] := OpenFile(PChar(Paths[Index]), Flags);
    if Handles[Index] < 0 then
    begin
      ReportError(ErrorCodeOf(Handles[Index]), Paths[Index]);
      ExitStatus := 1;
    end;
  end;

  repeat
    Count := ReadFile(StandardInputHandle, @Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    WriteAll(StandardOutputHandle, @Buffer[0], QWord(Count));
    for Index := 0 to High(Handles) do
    begin
      if Handles[Index] < 0 then
        Continue;
      Error := WriteAll(Handles[Index], @Buffer[0], QWord(Count));
      if Error <> ErrorNone then
      begin
        ReportError(Error, Paths[Index]);
        CloseFile(Handles[Index]);
        Handles[Index] := -1;
        ExitStatus := 1;
      end;
    end;
  until False;

  for Index := 0 to High(Handles) do
    if Handles[Index] >= 0 then
      CloseFile(Handles[Index]);
  Halt(ExitStatus);
end.
