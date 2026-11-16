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

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Sys.Information,
  Sys.InternetAddresses,
  Sys.AddressText,
  Sys.NetworkInterfaces,
  Sys.HostNames,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: hostname [-s | -i | -I] | hostname NAME'#10 +
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
  NewName: string = '';
  SettingName: Boolean = False;
  NodeName: string;

procedure ParseArguments;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('s', 'short', False, OptionShort),
    CommandOption('i', 'ip-address', False, OptionAddresses),
    CommandOption('I', 'all-ip-addresses', False, OptionAllAddresses)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionShort: Display := DisplayShort;
        OptionAddresses: Display := DisplayAddresses;
        OptionAllAddresses: Display := DisplayAllAddresses;
      end;
    if CommandLine.OperandCount > 1 then
      FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
    if CommandLine.OperandCount = 1 then
    begin
      NewName := CommandLine.Operands[0];
      SettingName := True;
    end;
  finally
    CommandLine.Free;
  end;
end;

procedure SetName;
var
  Error: LongInt;
begin
  Error := SetNodeName(PChar(NewName));
  if Error = ErrorNotPermitted then
    Fail(1, 'you must be root to change the host name');
  if Error = ErrorInvalidArgument then
    Fail(1, 'the specified hostname is invalid');
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot set the host name');
end;

{ The node name; False if it cannot be read. }
function NodeNameKnown(out Name: string): Boolean;
begin
  Result := ReadNodeName(Name) = ErrorNone;
end;

procedure ShowAddresses;
var
  Found: THostAddresses;
  Error: LongInt;
  Index: Integer;
begin
  Error := LookUpHostAddresses(NodeName, HostFamilyAny, Found);
  if Error <> ErrorNone then
    Fail(1, HostLookupErrorMessage(Error));
  for Index := 0 to High(Found.Addresses) do
  begin
    if Index > 0 then
      PrintString(' ');
    PrintString(AddressToText(Found.Addresses[Index]));
  end;
  PrintStringLine('');
end;

function AddressIsShown(constref Address: TAbiInterfaceAddress): Boolean;
begin
  Result := not AddressIsLinkLocal(InterfaceAddressHost(Address)) and
    ((Address.Flags and InterfaceAddressFlagTentative) = 0);
end;

procedure ShowAllAddresses;
var
  Interfaces: TNetworkInterfaceList;
  Position: Integer;
  AddressIndex: Integer;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot list the interfaces');
  for Position := 0 to High(Interfaces) do
  begin
    if (Interfaces[Position].Flags and InterfaceFlagLoopback) <> 0 then
      Continue;
    for AddressIndex := 0 to Integer(Interfaces[Position].AddressCount) - 1 do
    begin
      { As Linux's: no IPv6 link-local addresses, nor ones not ready. }
      if not AddressIsShown(Interfaces[Position].Addresses[AddressIndex]) then
        Continue;
      PrintString(AddressToText(InterfaceAddressHost(Interfaces[Position].Addresses[AddressIndex])) + ' ');
    end;
  end;
  PrintStringLine('');
end;

procedure ShowName;
var
  Dot: Integer;
begin
  if Display = DisplayShort then
  begin
    Dot := Pos('.', NodeName);
    if Dot > 0 then
      NodeName := Copy(NodeName, 1, Dot - 1);
  end;
  PrintStringLine(NodeName);
end;

begin
  ParseArguments;
  if SettingName then
  begin
    SetName;
    Halt(0);
  end;
  if not NodeNameKnown(NodeName) then
    Fail(1, 'cannot read the host name');
  case Display of
    DisplayAddresses: ShowAddresses;
    DisplayAllAddresses: ShowAllAddresses;
  else
    ShowName;
  end;
  FlushStream(StandardOutput);
end.
