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
  The loopback interface lo (127.0.0.1/8): datagrams to this machine's
  own addresses go round through it. Its "adapter" takes an IPv4
  datagram (no Ethernet header) and puts it on the receive queue as if
  it had arrived, so the network thread handles it later like any other
  - nothing is processed inside the sender's call, so sending never
  re-enters the protocols. It needs no hardware and is always up.
}
unit Network.Loopback;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Interfaces;

{ Makes lo, up with 127.0.0.1/8 (under the network lock). }
procedure CreateLoopbackInterface;
function LoopbackInterface: PNetworkInterface;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Packets,
  Network.Core,
  Network.InterfaceConfiguration;

var
  LoopbackAdapter: TNetworkAdapter;
  Loopback: PNetworkInterface;

function TransmitLoopback(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
var
  Packet: PPacket;
begin
  Result := True;
  Packet := AllocatePacket(0);
  if Packet = nil then
  begin
    Inc(Loopback^.Counters.ReceiveDrops);
    Exit;
  end;
  CopyMemory(@Packet^.Bytes[0], Frame, Length);
  Packet^.Length := Length;
  Packet^.NetworkInterface := Loopback;
  if not QueueReceivedPacket(Packet) then
    Inc(Loopback^.Counters.ReceiveDrops);
end;

function LoopbackLinkUp(Context: Pointer): Boolean;
begin
  Result := True;
end;

procedure CreateLoopbackInterface;
begin
  if Loopback <> nil then
    Exit;
  FillMemory(@LoopbackAdapter, SizeOf(LoopbackAdapter), 0);
  LoopbackAdapter.Routines.Transmit := @TransmitLoopback;
  LoopbackAdapter.Routines.LinkUp := @LoopbackLinkUp;
  LoopbackAdapter.Routines.Kind := NetworkAdapterKindLoopback;
  CopyText(@LoopbackAdapter.Name[0], 'lo', SizeOf(LoopbackAdapter.Name));
  CopyText(@LoopbackAdapter.Description[0], 'loopback', SizeOf(LoopbackAdapter.Description));
  Loopback := CreateNetworkInterface(@LoopbackAdapter, True);
  if Loopback = nil then
    Exit;
  LoopbackAdapter.State := Loopback;
  SetInterfaceAddress(Loopback, LoopbackAddress, LoopbackPrefixLength);
  SetInterfaceUp(Loopback, True);
end;

function LoopbackInterface: PNetworkInterface;
begin
  Result := Loopback;
end;

end.
