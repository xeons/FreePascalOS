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
  The network thread: where received frames are handled and the
  protocols' timers run.

  It sleeps on the network's work event until a frame arrives (drivers
  and lo signal it), a driver marks an interface (room to send, a
  changed link), or the earliest timer is due. Then, under the network
  lock, it takes every queued frame through Ethernet (or straight to
  IPv4 for lo), sends what waited on the interfaces, and when the
  timers are due, runs those of ARP, fragment reassembly and TCP. The
  frames are taken a batch at a time, so that timers still run under a
  flood.
}
unit Network.Thread;

{$mode objfpc}
{$pointermath on}

interface

procedure RunNetworkThread(Context: Pointer);

implementation

uses
  Kernel.Events,
  Kernel.Clock,
  Network.Core,
  Network.Packets,
  Network.Interfaces,
  Network.Ethernet,
  Network.Ipv4,
  Network.Ipv6,
  Network.Arp,
  Network.Fragments,
  Network.NeighborCache,
  Network.Ipv6Fragments,
  Network.Ipv6Interfaces,
  Network.TcpTimers;

const
  FramesPerBatch = 64;

{ A datagram that went round lo: IPv4 or IPv6 as its version says. }
procedure LoopbackInput(NetworkInterface: PNetworkInterface; Packet: PPacket);
var
  Data: PByte;
begin
  Data := PacketData(Packet);
  if (Packet^.Length > 0) and ((Data[0] shr 4) = 6) then
    Ipv6Input(NetworkInterface, Data, Packet^.Length)
  else
    Ipv4Input(NetworkInterface, Data, Packet^.Length);
end;

procedure HandleFrame(Packet: PPacket);
var
  NetworkInterface: PNetworkInterface;
begin
  NetworkInterface := PNetworkInterface(Packet^.NetworkInterface);
  CountReceivedFrame(NetworkInterface, Packet^.Length);
  if NetworkInterface^.IsLoopback then
    LoopbackInput(NetworkInterface, Packet)
  else if NetworkInterface^.IsUp then
    EthernetInput(NetworkInterface, Packet)
  else
    CountReceiveDrop(NetworkInterface);
end;

{ True if frames are still waiting. }
function HandleFrameBatch: Boolean;
var
  Count: Integer;
  Packet: PPacket;
begin
  for Count := 1 to FramesPerBatch do
  begin
    Packet := TakeReceivedPacket;
    if Packet = nil then
      Exit(False);
    HandleFrame(Packet);
    FreePacket(Packet);
  end;
  Result := True;
end;

procedure RunTimers;
var
  Now: QWord;
begin
  Now := NetworkNow;
  if Now < NextNetworkWake then
    Exit;
  BeginNetworkTimerRound;
  RunArpTimers(Now);
  RunReassemblyTimers(Now);
  RunNeighborTimers(Now);
  RunIpv6ReassemblyTimers(Now);
  RunIpv6InterfaceTimers(Now);
  RunTcpTimers(Now);
end;

function MillisecondsUntilWake: QWord;
var
  Now: QWord;
  Wake: QWord;
begin
  Now := NetworkNow;
  Wake := NextNetworkWake;
  if Wake <= Now then
    Exit(0);
  Result := (Wake - Now + NanosecondsPerMillisecond - 1) div NanosecondsPerMillisecond;
end;

procedure RunNetworkThread(Context: Pointer);
var
  MoreFrames: Boolean;
  Timeout: QWord;
begin
  MoreFrames := False;
  while True do
  begin
    if not MoreFrames then
    begin
      LockNetwork;
      Timeout := MillisecondsUntilWake;
      UnlockNetwork;
      if Timeout > 0 then
        WaitForEventWithOptions(NetworkWorkEvent^, Timeout, False);
    end;
    LockNetwork;
    MoreFrames := HandleFrameBatch;
    ProcessInterfaceEvents;
    RunTimers;
    UnlockNetwork;
  end;
end;

end.
