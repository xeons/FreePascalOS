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
  netstat -i: each interface's MTU and packet counters, in net-tools'
  columns. Frames lost for want of room in the card (RX-OVR, TX-OVR)
  are counted among the drops by the drivers, so those columns are 0.
  Flags: B broadcast, L loopback, R running, U up.
}
unit Netstat.Interfaces;

{$mode objfpc}
{$H+}

interface

procedure ShowInterfaceTable;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.NetworkInterfaces,
  Sys.InterfaceText,
  Util.Messages,
  Sys.Streams;

{ "BRU", "LRU": net-tools' letters, in its order. }
function ShortFlagsText(Flags: LongWord): string;
begin
  Result := '';
  if (Flags and InterfaceFlagBroadcast) <> 0 then
    Result := Result + 'B';
  if (Flags and InterfaceFlagLoopback) <> 0 then
    Result := Result + 'L';
  if (Flags and InterfaceFlagRunning) <> 0 then
    Result := Result + 'R';
  if (Flags and InterfaceFlagUp) <> 0 then
    Result := Result + 'U';
end;

procedure WriteInterface(constref Description: TAbiNetworkInterface);
var
  Counters: TAbiInterfaceCounters;
begin
  Counters := Description.Counters;
  PrintString(Format('%-15s %5u %8u %6u %6u %6u %8u %6u %6u %6u %s'#10, [
    InterfaceNameToText(Description.Name), QWord(Description.Mtu), QWord(Counters.ReceivedPackets),
    QWord(Counters.ReceiveErrors), QWord(Counters.ReceiveDrops), 0,
    QWord(Counters.SentPackets), QWord(Counters.SendErrors),
    QWord(Counters.SendDrops), 0, ShortFlagsText(Description.Flags)]));
end;

procedure ShowInterfaceTable;
var
  Interfaces: TNetworkInterfaceList;
  Index: Integer;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the interfaces');
  PrintStringLine('Kernel Interface table');
  PrintStringLine('Iface             MTU    RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg');
  for Index := 0 to High(Interfaces) do
    WriteInterface(Interfaces[Index]);
end;

end.
