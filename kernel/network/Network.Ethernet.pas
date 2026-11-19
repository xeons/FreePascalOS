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
  Ethernet II framing: a destination and a source address and the type
  of what follows (IPv4, ARP, IPv6), then the payload. Frames for another
  station are dropped; broadcasts are taken, and IPv6 multicast frames
  (33:33 and the group's last four bytes) and IPv4 ones (01:00:5e and
  the group's low 23 bits), which IP filters by the groups the
  interface listens to. Other multicast is dropped.
}
unit Network.Ethernet;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.NetworkAdapters,
  Network.Packets,
  Network.Interfaces;

const
  EtherTypeIpv4 = $0800;
  EtherTypeArp = $0806;
  EtherTypeIpv6 = $86DD;

  BroadcastEthernetAddress: TEthernetAddress = ($FF, $FF, $FF, $FF, $FF, $FF);

{ A frame that arrived on an Ethernet interface (the packet is the
  caller's). }
procedure EthernetInput(NetworkInterface: PNetworkInterface; Packet: PPacket);
{ Puts the Ethernet header in front of the packet and sends it (takes
  the packet). }
procedure SendEthernetFrame(NetworkInterface: PNetworkInterface; const Destination: TEthernetAddress;
  EtherType: Word; Packet: PPacket);

implementation

uses
  Runtime.Memory,
  Network.ByteOrder,
  Network.Arp,
  Network.Ipv4,
  Network.Ipv6;

function IsForThisStation(NetworkInterface: PNetworkInterface; Destination: PByte): Boolean;
begin
  if MemoryIsEqual(Destination, @NetworkInterface^.HardwareAddress[0], EthernetAddressLength) then
    Exit(True);
  if MemoryIsEqual(Destination, @BroadcastEthernetAddress[0], EthernetAddressLength) then
    Exit(True);
  { An IPv6 multicast group, or an IPv4 one (IP filters by group). }
  Result := ((Destination[0] = $33) and (Destination[1] = $33)) or
    ((Destination[0] = $01) and (Destination[1] = $00) and (Destination[2] = $5E) and ((Destination[3] and $80) = 0));
end;

procedure EthernetInput(NetworkInterface: PNetworkInterface; Packet: PPacket);
var
  Frame: PByte;
  EtherType: Word;
begin
  if Packet^.Length < EthernetHeaderBytes then
  begin
    CountReceiveError(NetworkInterface);
    Exit;
  end;
  Frame := PacketData(Packet);
  if not IsForThisStation(NetworkInterface, Frame) then
  begin
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  EtherType := ReadBigEndian16(Frame + 12);
  case EtherType of
    EtherTypeIpv4:
      Ipv4Input(NetworkInterface, Frame + EthernetHeaderBytes, Packet^.Length - EthernetHeaderBytes);
    EtherTypeArp:
      ArpInput(NetworkInterface, Frame + EthernetHeaderBytes, Packet^.Length - EthernetHeaderBytes);
    EtherTypeIpv6:
      Ipv6Input(NetworkInterface, Frame + EthernetHeaderBytes, Packet^.Length - EthernetHeaderBytes);
  else
    CountReceiveDrop(NetworkInterface);
  end;
end;

procedure SendEthernetFrame(NetworkInterface: PNetworkInterface; const Destination: TEthernetAddress;
  EtherType: Word; Packet: PPacket);
var
  Header: PByte;
begin
  Header := PrependToPacket(Packet, EthernetHeaderBytes);
  if Header = nil then
  begin
    Inc(NetworkInterface^.Counters.SendErrors);
    FreePacket(Packet);
    Exit;
  end;
  CopyMemory(Header, @Destination[0], EthernetAddressLength);
  CopyMemory(Header + EthernetAddressLength, @NetworkInterface^.HardwareAddress[0], EthernetAddressLength);
  WriteBigEndian16(Header + 12, EtherType);
  TransmitInterfaceFrame(NetworkInterface, Packet);
end;

end.
