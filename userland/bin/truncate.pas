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
  truncate - shrink or extend the size of a file to the specified size

  truncate [-c] -s [+-<>]SIZE FILE...
}
program truncate;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Sizes;

const
  Usage = 'Usage: truncate OPTION... FILE...'#10 +
    'Shrink or extend the size of each FILE to the specified size.'#10 +
    #10 +
    '  -c, --no-create        do not create any files'#10 +
    '  -s, --size=SIZE        set or adjust the file size by SIZE bytes'#10 +
    #10 +
    'SIZE may have a suffix (K, M, G, T or KB, MB, ...) and a prefix:'#10 +
    '''+'' extend by, ''-'' reduce by, ''<'' at most, ''>'' at least.'#10;

  OptionNoCreate = 1;
  OptionSize = 2;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  NoCreate: Boolean;
  SizeText: string;
  Adjustment: Char;
  Size: QWord;
  Operand: string;
  Handle: Int64;
  Flags: LongWord;
  Information: TFileInformation;
  NewSize: QWord;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  NoCreate := False;
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'no-create', False, OptionNoCreate),
    CommandOption('s', 'size', True, OptionSize)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionNoCreate then
      NoCreate := True;
  if not CommandLine.OptionGiven(OptionSize) then
    FailWithUsageHint('you must specify ''--size''');
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing file operand');
  SizeText := CommandLine.OptionValue(OptionSize);

  Adjustment := ' ';
  if (SizeText <> '') and (SizeText[1] in ['+', '-', '<', '>']) then
  begin
    Adjustment := SizeText[1];
    Delete(SizeText, 1, 1);
  end;
  if not ParseSize(SizeText, Size) then
    Fail(1, Format('Invalid number: ''%s''', [SizeText]));

  Flags := OpenWrite;
  if not NoCreate then
    Flags := Flags or OpenCreate;
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    if NoCreate and not PathExists(PChar(Operand)) then
      Continue;
    Handle := OpenFile(PChar(Operand), Flags);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), Format('cannot open ''%s'' for writing', [Operand]));
      ExitStatus := 1;
      Continue;
    end;
    GetHandleInformation(Handle, Information);
    case Adjustment of
      '+': NewSize := Information.SizeInBytes + Size;
      '-':
        if Size > Information.SizeInBytes then
          NewSize := 0
        else
          NewSize := Information.SizeInBytes - Size;
      '<':
        if Information.SizeInBytes > Size then
          NewSize := Size
        else
          NewSize := Information.SizeInBytes;
      '>':
        if Information.SizeInBytes < Size then
          NewSize := Size
        else
          NewSize := Information.SizeInBytes;
    else
      NewSize := Size;
    end;
    Error := SetFileSize(Handle, NewSize);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('failed to truncate ''%s''', [Operand]));
      ExitStatus := 1;
    end;
    CloseFile(Handle);
  end;
  Halt(ExitStatus);
end.
