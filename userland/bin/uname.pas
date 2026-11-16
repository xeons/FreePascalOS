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
  uname - print system information

  uname [-asnrvmpio]

  With no option, prints the kernel name (-s).
}
program uname;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Information,
  Util.CommandLine,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: uname [OPTION]...'#10 +
    'Print certain system information. With no OPTION, same as -s.'#10 +
    #10 +
    '  -a, --all                print all information, in the following order:'#10 +
    '  -s, --kernel-name        print the kernel name'#10 +
    '  -n, --nodename           print the network node hostname'#10 +
    '  -r, --kernel-release     print the kernel release'#10 +
    '  -v, --kernel-version     print the kernel version'#10 +
    '  -m, --machine            print the machine hardware name'#10 +
    '  -p, --processor          print the processor type'#10 +
    '  -i, --hardware-platform  print the hardware platform'#10 +
    '  -o, --operating-system   print the operating system'#10;

  ShowKernelName = $01;
  ShowNodeName = $02;
  ShowRelease = $04;
  ShowVersion = $08;
  ShowMachine = $10;
  ShowProcessor = $20;
  ShowPlatform = $40;
  ShowOperatingSystem = $80;
  ShowAll = $FF;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Selection: Integer;
  Information: TSystemInformation;
  Fields: string;
  FieldCount: Integer;

procedure AddField(Mask: Integer; const Text: string);
begin
  if (Selection and Mask) = 0 then
    Exit;
  if FieldCount > 0 then
    Fields := Fields + ' ';
  Fields := Fields + Text;
  Inc(FieldCount);
end;

begin
  Selection := 0;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, ShowAll),
    CommandOption('s', 'kernel-name', False, ShowKernelName),
    CommandOption('n', 'nodename', False, ShowNodeName),
    CommandOption('r', 'kernel-release', False, ShowRelease),
    CommandOption('v', 'kernel-version', False, ShowVersion),
    CommandOption('m', 'machine', False, ShowMachine),
    CommandOption('p', 'processor', False, ShowProcessor),
    CommandOption('i', 'hardware-platform', False, ShowPlatform),
    CommandOption('o', 'operating-system', False, ShowOperatingSystem)], Usage);
  while CommandLine.NextOption(Code, Value) do
    Selection := Selection or Code;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[0]]));
  if Selection = 0 then
    Selection := ShowKernelName;

  if GetSystemInformation(Information) <> 0 then
    Fail(1, 'cannot get system information');
  Fields := '';
  FieldCount := 0;
  AddField(ShowKernelName, PChar(@Information.SystemName[0]));
  AddField(ShowNodeName, PChar(@Information.NodeName[0]));
  AddField(ShowRelease, PChar(@Information.Release[0]));
  AddField(ShowVersion, PChar(@Information.Version[0]));
  AddField(ShowMachine, PChar(@Information.Machine[0]));
  AddField(ShowProcessor, PChar(@Information.Machine[0]));
  AddField(ShowPlatform, PChar(@Information.Machine[0]));
  AddField(ShowOperatingSystem, 'FreePascalOS');
  PrintStringLine(Fields);
end.
