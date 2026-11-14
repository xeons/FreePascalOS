{
  uname - print system information

  uname [-asnrvmpio]

  With no option, prints the kernel name (-s).
}
program uname;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Information,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: uname [OPTION]...'#10 +
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
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Selection: Integer;
  Information: TSystemInformation;
  PrintedAny: Boolean;

procedure PrintField(Mask: Integer; Text: PChar);
begin
  if (Selection and Mask) = 0 then
    Exit;
  if PrintedAny then
    WriteCharacter(StandardOutput, ' ');
  WriteText(StandardOutput, Text);
  PrintedAny := True;
end;

begin
  Selection := 0;
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, ShowAll),
    OptionDefinition('s', 'kernel-name', False, ShowKernelName),
    OptionDefinition('n', 'nodename', False, ShowNodeName),
    OptionDefinition('r', 'kernel-release', False, ShowRelease),
    OptionDefinition('v', 'kernel-version', False, ShowVersion),
    OptionDefinition('m', 'machine', False, ShowMachine),
    OptionDefinition('p', 'processor', False, ShowProcessor),
    OptionDefinition('i', 'hardware-platform', False, ShowPlatform),
    OptionDefinition('o', 'operating-system', False, ShowOperatingSystem)], Usage);
  while NextOption(Parser, Code, Value) do
    Selection := Selection or Code;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[0])]);
  if Selection = 0 then
    Selection := ShowKernelName;

  if GetSystemInformation(Information) <> 0 then
    Fail(1, 'cannot get system information', []);
  PrintedAny := False;
  PrintField(ShowKernelName, @Information.SystemName[0]);
  PrintField(ShowNodeName, @Information.NodeName[0]);
  PrintField(ShowRelease, @Information.Release[0]);
  PrintField(ShowVersion, @Information.Version[0]);
  PrintField(ShowMachine, @Information.Machine[0]);
  PrintField(ShowProcessor, @Information.Machine[0]);
  PrintField(ShowPlatform, @Information.Machine[0]);
  PrintField(ShowOperatingSystem, 'FreePascalOS');
  WriteCharacter(StandardOutput, #10);
end.
