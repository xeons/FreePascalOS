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
  sum - checksum and count the blocks in a file

  sum [-rs] [FILE]...

  -r (the default) prints the BSD checksum and 1 KiB blocks; -s the
  System V checksum and 512 byte blocks.
}
program sum;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Crypto.Checksums,
  Sys.Errors,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams;

const
  Usage = 'Usage: sum [OPTION]... [FILE]...'#10 +
    'Print checksum and block counts for each FILE.'#10#10 +
    '  -r              use BSD sum algorithm (the default), use 1K blocks'#10 +
    '  -s, --sysv      use System V sum algorithm, use 512 bytes blocks'#10;

  OptionBsd = 1;
  OptionSystemV = 2;

var
  UseSystemV: Boolean;
  ShowNames: Boolean;
  Buffer: array of Byte;

{ Prints the checksum line of one file; False if it could not be opened. }
function SumFile(const Path: string): Boolean;
var
  Handle: Int64;
  Count: Int64;
  BsdSum: Word;
  SystemVSum: QWord;
  ByteCount: QWord;
  Line: string;
begin
  if Path = '-' then
    Handle := StandardInputHandle
  else
    Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
  begin
    ReportError(ErrorCodeOf(Handle), Path);
    Exit(False);
  end;
  BsdSum := 0;
  SystemVSum := 0;
  ByteCount := 0;
  repeat
    Count := ReadFile(Handle, @Buffer[0], Length(Buffer));
    if Count <= 0 then
      Break;
    BsdSum := BsdSumUpdate(BsdSum, @Buffer[0], QWord(Count));
    SystemVSum := SystemVSumUpdate(SystemVSum, @Buffer[0], QWord(Count));
    ByteCount := ByteCount + QWord(Count);
  until False;
  if Handle <> StandardInputHandle then
    CloseFile(Handle);
  if UseSystemV then
    Line := Format('%u %u', [QWord(SystemVSumFinish(SystemVSum)), (ByteCount + 511) div 512])
  else
    Line := Format('%.5u %5u', [BsdSum, (ByteCount + 1023) div 1024]);
  if ShowNames or (UseSystemV and (Path <> '-')) then
    Line := Line + ' ' + Path;
  PrintStringLine(Line);
  Result := True;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  ExitStatus: LongInt;
begin
  UseSystemV := False;
  CommandLine := TCommandLine.Create([
    CommandOption('r', '', False, OptionBsd),
    CommandOption('s', 'sysv', False, OptionSystemV)], Usage);
  while CommandLine.NextOption(Code, Value) do
    UseSystemV := Code = OptionSystemV;
  ShowNames := CommandLine.OperandCount > 1;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  SetLength(Buffer, 65536);
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
    if not SumFile(Operand) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
