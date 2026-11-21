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
  free - show the system's memory

  free [-kmb]

  The RAM there is, used and free (GetSystemUsage), then what the used
  memory is for, as the kernel's page allocator counts it: processes'
  own pages, the pages of mapped files (programs, libraries and files
  mapped with CallMapHandle, each page once however many processes map
  it), sections, the block cache and the kernel's own; and the commit
  charge of all processes (what they may come to use, touched or not).
}
program free;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.SystemUsage,
  Util.CommandLine,
  Sys.Streams;

const
  Usage = 'Usage: free [OPTION]...'#10 +
    'Display the amount of free and used memory in the system, and what'#10 +
    'the used memory is for.'#10#10 +
    '  -b, --bytes     show the amounts in bytes'#10 +
    '  -k, --kibi      show the amounts in KiB (the default)'#10 +
    '  -m, --mebi      show the amounts in MiB'#10;

  OptionBytes = 1;
  OptionKibi = 2;
  OptionMebi = 3;

var
  Divisor: QWord = 1024;

function Amount(Bytes: QWord): string;
begin
  Result := Format('%12d', [Bytes div Divisor]);
end;

procedure PrintLine(const Name: string; Bytes: QWord);
begin
  PrintString(Format('%-24s', [Name]) + Amount(Bytes) + #10);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Memory: TSystemUsage;
  Resources: TAbiProcessResources;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'bytes', False, OptionBytes),
    CommandOption('k', 'kibi', False, OptionKibi),
    CommandOption('m', 'mebi', False, OptionMebi)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBytes: Divisor := 1;
      OptionKibi: Divisor := 1024;
      OptionMebi: Divisor := 1024 * 1024;
    end;

  if GetSystemUsage(Memory) < 0 then
  begin
    PrintErrorStringLine('free: the system''s memory could not be read');
    Halt(1);
  end;
  PrintString(Format('%-12s', ['']) + Format('%12s%12s%12s', ['total', 'used', 'free']) + #10);
  PrintString(Format('%-12s', ['Mem:']) + Amount(Memory.TotalMemory) + Amount(UsedMemory(Memory)) +
    Amount(Memory.FreeMemory) + #10);
  PrintLine('  processes', Memory.UserMemory);
  PrintLine('  mapped files', Memory.ProgramImageMemory);
  PrintLine('  sections', Memory.SectionMemory);
  PrintLine('  block cache', Memory.BlockCacheMemory);
  PrintLine('  kernel heap', Memory.KernelHeapMemory);
  PrintLine('  kernel stacks', Memory.KernelStackMemory);
  PrintLine('  page tables', Memory.PageTableMemory);
  PrintLine('  kernel image', Memory.KernelImageMemory);
  PrintLine('  drivers', Memory.DriverMemory);
  if KernelGetProcessResources(0, Resources) >= 0 then
    PrintLine('Committed:', Resources.SystemCommitChargePages * 4096);
end.
