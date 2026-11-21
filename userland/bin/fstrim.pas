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
  fstrim - discard the unused blocks of mounted volumes

  fstrim [-v] MOUNTPOINT...

  Tells the disk of each volume that the volume's free space holds
  nothing (TRIM, deallocate, unmap), so an SSD can reuse it and a disk
  image file can shrink. Root only. -v reports how much was discarded.
  A volume whose disk cannot discard is reported and skipped (exit
  status 1).
}
program fstrim;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.MemoryStatus,
  Sys.Streams,
  Util.CommandLine,
  Util.Sizes;

const
  Usage = 'Usage: fstrim [OPTION]... MOUNTPOINT...'#10 +
    'Discard the unused blocks of the mounted volumes holding MOUNTPOINT.'#10 +
    #10 +
    '  -v, --verbose  print the number of discarded bytes'#10;

  OptionVerbose = 1;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Verbose: Boolean;
  Index: Integer;
  Error: LongInt;
  Discarded: QWord;
  Status: Integer;
begin
  Verbose := False;
  CommandLine := TCommandLine.Create([CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionVerbose then
      Verbose := True;
  if CommandLine.OperandCount = 0 then
  begin
    PrintErrorString(Usage);
    Halt(1);
  end;
  Status := 0;
  for Index := 0 to CommandLine.OperandCount - 1 do
  begin
    Error := TrimVolume(CommandLine.Operands[Index], Discarded);
    if Error <> ErrorNone then
    begin
      PrintErrorStringLine('fstrim: ' + CommandLine.Operands[Index] + ': ' + ErrorMessage(Error));
      Status := 1;
      Continue;
    end;
    if Verbose then
      PrintStringLine(Format('%s: %s (%d bytes) trimmed',
        [CommandLine.Operands[Index], FormatHumanSize(Discarded), Discarded]));
  end;
  CommandLine.Free;
  Halt(Status);
end.
