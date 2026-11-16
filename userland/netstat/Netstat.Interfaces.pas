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

interface

procedure ShowInterfaceTable;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Format,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Util.Messages;

procedure AppendFlagLetter(Flags: LongWord; Flag: LongWord; Letter: Char; Text: PChar; var Length: Integer);
begin
  if (Flags and Flag) = 0 then
    Exit;
  Text[Length] := Letter;
  Inc(Length);
end;

{ "BRU", "LRU": net-tools' letters, in its order. }
function FormatShortFlags(Flags: LongWord; Buffer: PChar): PChar;
var
  Length: Integer;
begin
  Length := 0;
  AppendFlagLetter(Flags, InterfaceFlagBroadcast, 'B', Buffer, Length);
  AppendFlagLetter(Flags, InterfaceFlagLoopback, 'L', Buffer, Length);
  AppendFlagLetter(Flags, InterfaceFlagRunning, 'R', Buffer, Length);
  AppendFlagLetter(Flags, InterfaceFlagUp, 'U', Buffer, Length);
  Buffer[Length] := #0;
  Result := Buffer;
end;

procedure WriteInterface(constref Description: TAbiNetworkInterface);
var
  Flags: array[0..7] of Char;
  Counters: TAbiInterfaceCounters;
begin
  FormatShortFlags(Description.Flags, @Flags[0]);
  Counters := Description.Counters;
  WriteFormatted(StandardOutput, '%-15s %5u %8u %6u %6u %6u %8u %6u %6u %6u %s'#10, [
    ArgumentText(@Description.Name[0]), ArgumentUnsigned(Description.Mtu), ArgumentUnsigned(Counters.ReceivedPackets),
    ArgumentUnsigned(Counters.ReceiveErrors), ArgumentUnsigned(Counters.ReceiveDrops), ArgumentUnsigned(0),
    ArgumentUnsigned(Counters.SentPackets), ArgumentUnsigned(Counters.SendErrors),
    ArgumentUnsigned(Counters.SendDrops), ArgumentUnsigned(0), ArgumentText(@Flags[0])]);
end;

procedure ShowInterfaceTable;
var
  Interfaces: TNetworkInterfaceList;
  Index: Integer;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the interfaces', []);
  WriteLine(StandardOutput, 'Kernel Interface table');
  WriteLine(StandardOutput, 'Iface             MTU    RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg');
  for Index := 0 to High(Interfaces) do
    WriteInterface(Interfaces[Index]);
end;

end.
