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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Crypto.Checksums,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: sum [OPTION]... [FILE]...'#10 +
    'Print checksum and block counts for each FILE.'#10#10 +
    '  -r              use BSD sum algorithm (the default), use 1K blocks'#10 +
    '  -s, --sysv      use System V sum algorithm, use 512 bytes blocks'#10;

  OptionBsd = 1;
  OptionSystemV = 2;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  UseSystemV: Boolean;
  Index: Integer;
  Handle: Int64;
  Buffer: PByte;
  Count: Int64;
  BsdSum: Word;
  SystemVSum: QWord;
  ByteCount: QWord;
  ExitStatus: LongInt;
  ShowNames: Boolean;
begin
  UseSystemV := False;
  BeginOptions(Parser, [
    OptionDefinition('r', nil, False, OptionBsd),
    OptionDefinition('s', 'sysv', False, OptionSystemV)], Usage);
  while NextOption(Parser, Code, Value) do
    UseSystemV := Code = OptionSystemV;
  ShowNames := Parser.OperandCount > 1;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  Buffer := PByte(AllocateMemory(65536));
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if TextIsEqual(Parser.Operands[Index], '-') then
      Handle := StandardInputHandle
    else
      Handle := OpenFile(Parser.Operands[Index], OpenRead);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    BsdSum := 0;
    SystemVSum := 0;
    ByteCount := 0;
    repeat
      Count := ReadFile(Handle, Buffer, 65536);
      if Count <= 0 then
        Break;
      BsdSum := BsdSumUpdate(BsdSum, Buffer, QWord(Count));
      SystemVSum := SystemVSumUpdate(SystemVSum, Buffer, QWord(Count));
      ByteCount := ByteCount + QWord(Count);
    until False;
    if Handle <> StandardInputHandle then
      CloseFile(Handle);
    if UseSystemV then
      WriteFormatted(StandardOutput, '%u %u', [ArgumentUnsigned(SystemVSumFinish(SystemVSum)),
        ArgumentUnsigned((ByteCount + 511) div 512)])
    else
      WriteFormatted(StandardOutput, '%05u %5u', [ArgumentUnsigned(BsdSum),
        ArgumentUnsigned((ByteCount + 1023) div 1024)]);
    if ShowNames or (UseSystemV and not TextIsEqual(Parser.Operands[Index], '-')) then
      WriteFormatted(StandardOutput, ' %s', [ArgumentText(Parser.Operands[Index])]);
    WriteCharacter(StandardOutput, #10);
  end;
  FreeMemory(Buffer);
  Halt(ExitStatus);
end.
