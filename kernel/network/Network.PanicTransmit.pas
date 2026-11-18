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
  Sending a UDP datagram when nothing else works: during a panic, with
  interrupts disabled, the other processors stopped and the network lock
  perhaps held by one of them.

  The datagram is built here whole - Ethernet, IPv4 and UDP headers, no
  UDP checksum (allowed over IPv4) - and handed straight to the driver's
  Transmit routine, past the protocols, their lock and their queues. The
  route was worked out beforehand, while the system was well, by whoever
  wants to send (Network.LogStreaming): the adapter, both Ethernet
  addresses (the next hop's from the ARP cache, or broadcast) and both
  IP addresses and ports.

  Best effort only: drivers take their own transmit lock, and if the
  processor that panicked or a stopped one held it, the send never comes
  back (the hardware watchdog, if one is armed, still resets the board).
  The drivers' Transmit routines expect dispatch level, so the caller
  lowers to it with interrupts still disabled (SendPanicDatagram does).
}
unit Network.PanicTransmit;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.NetworkAdapters,
  Network.Addresses;

type
  TPanicRoute = record
    Valid: Boolean;
    Adapter: PNetworkAdapter;
    SourceHardware: TEthernetAddress;
    DestinationHardware: TEthernetAddress;
    SourceAddress: TIpv4Address;
    DestinationAddress: TIpv4Address;
    SourcePort: Word;
    DestinationPort: Word;
  end;

{ Sends Length bytes at Payload over Route; True if the driver took the
  frame. Interrupts must be disabled. }
function SendPanicDatagram(var Route: TPanicRoute; Payload: PByte; Length: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.PriorityLevel,
  Kernel.Arch.PriorityLevel,
  Kernel.Arch.Cpu,
  Hal.Platform,
  Network.ByteOrder,
  Network.Checksums;

const
  EthernetHeaderBytes = 14;
  Ipv4HeaderBytes = 20;
  UdpHeaderBytes = 8;
  HeadersBytes = EthernetHeaderBytes + Ipv4HeaderBytes + UdpHeaderBytes;
  EtherTypeIpv4 = $0800;
  IpProtocolUdp = 17;
  TimeToLive = 64;
  DontFragment = $4000;
  { How long one frame may wait for room in the driver's ring. }
  RoomWaitNanoseconds = 50 * 1000 * 1000;

var
  Identification: Word = 1;
  Frame: array[0..MaximumFrameBytes - 1] of Byte;

procedure WriteHeaders(var Route: TPanicRoute; PayloadLength: LongWord);
var
  Ip: PByte;
  Udp: PByte;
begin
  CopyMemory(@Frame[0], @Route.DestinationHardware[0], EthernetAddressLength);
  CopyMemory(@Frame[6], @Route.SourceHardware[0], EthernetAddressLength);
  WriteBigEndian16(@Frame[12], EtherTypeIpv4);

  Ip := @Frame[EthernetHeaderBytes];
  Ip[0] := $45;
  Ip[1] := 0;
  WriteBigEndian16(Ip + 2, Ipv4HeaderBytes + UdpHeaderBytes + PayloadLength);
  WriteBigEndian16(Ip + 4, Identification);
  Inc(Identification);
  WriteBigEndian16(Ip + 6, DontFragment);
  Ip[8] := TimeToLive;
  Ip[9] := IpProtocolUdp;
  WriteBigEndian16(Ip + 10, 0);
  WriteIpv4Address(Ip + 12, Route.SourceAddress);
  WriteIpv4Address(Ip + 16, Route.DestinationAddress);
  WriteBigEndian16(Ip + 10, InternetChecksum(Ip, Ipv4HeaderBytes));

  Udp := Ip + Ipv4HeaderBytes;
  WriteBigEndian16(Udp, Route.SourcePort);
  WriteBigEndian16(Udp + 2, Route.DestinationPort);
  WriteBigEndian16(Udp + 4, UdpHeaderBytes + PayloadLength);
  WriteBigEndian16(Udp + 6, 0);
end;

function HandToDriver(Adapter: PNetworkAdapter; Length: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := HalClockNanoseconds + RoomWaitNanoseconds;
  repeat
    if Adapter^.Routines.Transmit(Adapter^.Context, @Frame[0], Length) then
      Exit(True);
    CpuRelax;
  until HalClockNanoseconds > Deadline;
  Result := False;
end;

function SendPanicDatagram(var Route: TPanicRoute; Payload: PByte; Length: LongWord): Boolean;
var
  FrameLength: LongWord;
  LevelBefore: TPriorityLevel;
begin
  Result := False;
  if not Route.Valid or (Route.Adapter = nil) or not Assigned(Route.Adapter^.Routines.Transmit) then
    Exit;
  if Length > MaximumFrameBytes - HeadersBytes then
    Length := MaximumFrameBytes - HeadersBytes;
  WriteHeaders(Route, Length);
  CopyMemory(@Frame[HeadersBytes], Payload, Length);
  FrameLength := HeadersBytes + Length;
  if FrameLength < MinimumFrameBytes then
  begin
    FillMemory(@Frame[FrameLength], MinimumFrameBytes - FrameLength, 0);
    FrameLength := MinimumFrameBytes;
  end;
  { The driver raises to dispatch level for its lock: from the panic's
    high level that would be a lowering, itself a panic. Interrupts stay
    disabled throughout. }
  LevelBefore := ArchGetPriorityLevel;
  ArchSetPriorityLevel(DispatchLevel);
  Result := HandToDriver(Route.Adapter, FrameLength);
  ArchSetPriorityLevel(LevelBefore);
end;

end.
