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
  hostname - show or set the machine's host name

  hostname [-s | -i | -I]
  hostname NAME

  Without arguments shows the machine's node name (what uname -n
  shows); -s shows it up to its first dot, -i the addresses the name
  resolves to (Sys.HostNames: /etc/hosts, then DNS), -I every address of
  the network interfaces but the loopback one. With NAME, root sets the
  node name (1 to 63 letters, digits, hyphens and dots) until the next
  start; the network service sets it at start from HostName in
  /etc/settings/Network.settings.

  Exit status: 0 on success, 1 on failure.
}
program hostname;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.Information,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.HostNames,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: hostname [-s | -i | -I] | hostname NAME'#10 +
    'Show or set the machine''s host name.'#10 +
    #10 +
    '  -s, --short          the name up to its first dot'#10 +
    '  -i, --ip-address     the addresses the name resolves to'#10 +
    '  -I, --all-ip-addresses   every address of the network interfaces'#10;

  OptionShort = 1;
  OptionAddresses = 2;
  OptionAllAddresses = 3;

type
  TDisplay = (DisplayName, DisplayShort, DisplayAddresses, DisplayAllAddresses);

var
  Display: TDisplay = DisplayName;
  NewName: PChar = nil;
  NodeName: array[0..AbiTextCapacity - 1] of Char;

procedure ParseArguments;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
begin
  BeginOptions(Parser, [
    OptionDefinition('s', 'short', False, OptionShort),
    OptionDefinition('i', 'ip-address', False, OptionAddresses),
    OptionDefinition('I', 'all-ip-addresses', False, OptionAllAddresses)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionShort: Display := DisplayShort;
      OptionAddresses: Display := DisplayAddresses;
      OptionAllAddresses: Display := DisplayAllAddresses;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if Parser.OperandCount = 1 then
    NewName := Parser.Operands[0];
end;

procedure SetName;
var
  Error: LongInt;
begin
  Error := SetNodeName(NewName);
  if Error = ErrorNotPermitted then
    Fail(1, 'you must be root to change the host name', []);
  if Error = ErrorInvalidArgument then
    Fail(1, 'the specified hostname is invalid', []);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot set the host name', []);
end;

procedure ShowAddresses;
var
  Found: THostAddresses;
  Error: LongInt;
  Index: Integer;
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
begin
  Error := LookUpHostAddresses(@NodeName[0], HostFamilyAny, Found);
  if Error <> ErrorNone then
    Fail(1, '%s', [ArgumentText(HostLookupErrorMessage(Error))]);
  for Index := 0 to Found.Count - 1 do
  begin
    if Index > 0 then
      WriteCharacter(StandardOutput, ' ');
    WriteText(StandardOutput, FormatInternetAddress(Found.Addresses[Index], @Text[0], SizeOf(Text)));
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure ShowAllAddresses;
var
  Interfaces: TNetworkInterfaceList;
  Position: Integer;
  AddressIndex: Integer;
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot list the interfaces', []);
  for Position := 0 to High(Interfaces) do
  begin
    if (Interfaces[Position].Flags and InterfaceFlagLoopback) <> 0 then
      Continue;
    for AddressIndex := 0 to Integer(Interfaces[Position].AddressCount) - 1 do
    begin
      WriteText(StandardOutput, FormatInternetAddress(InterfaceAddressHost(Interfaces[Position].Addresses[AddressIndex]),
        @Text[0], SizeOf(Text)));
      WriteCharacter(StandardOutput, ' ');
    end;
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure ShowName;
var
  Dot: PtrInt;
begin
  if Display = DisplayShort then
  begin
    Dot := FindCharacter(@NodeName[0], '.');
    if Dot >= 0 then
      NodeName[Dot] := #0;
  end;
  WriteLine(StandardOutput, @NodeName[0]);
end;

begin
  ParseArguments;
  if NewName <> nil then
  begin
    SetName;
    Halt(0);
  end;
  if GetNodeName(@NodeName[0], SizeOf(NodeName)) <> ErrorNone then
    Fail(1, 'cannot read the host name', []);
  case Display of
    DisplayAddresses: ShowAddresses;
    DisplayAllAddresses: ShowAllAddresses;
  else
    ShowName;
  end;
  FlushStream(StandardOutput);
end.
