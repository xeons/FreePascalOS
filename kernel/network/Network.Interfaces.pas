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
  Network interfaces: what the protocols see of an adapter.

  Every adapter a driver registers becomes an interface (eth0, eth1,
  ...), and the loopback interface lo is made first, so it is always
  number 1. An interface has its state (turned on or off, whether the
  link is there, the MTU), at most one IPv4 address with its prefix,
  and the counters ifconfig shows.

  Frames go to the driver through TransmitInterfaceFrame. When the
  driver has no room, the frame waits on the interface's transmit queue
  (bounded; beyond it frames are dropped and counted) until the driver
  says it has room again (NetworkTransmitReady, at dispatch level),
  which only marks the interface and wakes the network thread: the
  thread sends what waits (ProcessInterfaceEvents). A changed link is
  passed on the same way.

  Everything here is used under the network lock, except the pending
  events, which drivers set atomically.
}
unit Network.Interfaces;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Ipv6Types,
  Network.Packets;

const
  MaximumNetworkInterfaces = 16;
  DefaultMtu = 1500;
  MinimumMtu = 576;
  MaximumTransmitQueue = 128;
  EthernetHeaderBytes = 14;

  InterfaceEventTransmitReady = $01;
  InterfaceEventLinkChanged = $02;

type
  PNetworkInterface = ^TNetworkInterface;
  TNetworkInterface = record
    { 1 for the first (lo). }
    Index: LongWord;
    Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
    Description: array[0..NetworkInterfaceDescriptionCapacity - 1] of Char;
    Adapter: PNetworkAdapter;
    IsLoopback: Boolean;
    HardwareAddress: TEthernetAddress;
    { Turned on (ifconfig up), and whether the link is there. }
    IsUp: Boolean;
    LinkIsUp: Boolean;
    Mtu: LongWord;
    HasAddress: Boolean;
    Address: TIpv4Address;
    PrefixLength: LongWord;
    { Addresses, router information and timers of IPv6. }
    Ipv6: TIpv6InterfaceState;
    Counters: TAbiInterfaceCounters;
    TransmitQueue: TPacketQueue;
    { InterfaceEvent*, set by drivers at dispatch level. }
    PendingEvents: PtrUInt;
    { Frames the driver handed over that found the receive queue full
      (counted at dispatch level). }
    QueueDrops: Int64;
  end;

{ Makes the interface of Adapter (named as the adapter is). nil if
  memory or room is short. }
function CreateNetworkInterface(Adapter: PNetworkAdapter; IsLoopback: Boolean): PNetworkInterface;
function NetworkInterfaceCount: Integer;
{ Position from 0. }
function NetworkInterfaceAt(Position: Integer): PNetworkInterface;
function FindInterfaceByName(Name: PChar): PNetworkInterface;
function FindInterfaceByIndex(Index: LongWord): PNetworkInterface;
{ The interface that has Address as its own; nil if none has. }
function FindInterfaceWithAddress(Address: TIpv4Address): PNetworkInterface;
{ True if Address is one of this machine's (127.x.x.x included). }
function IsLocalAddress(Address: TIpv4Address): Boolean;
{ Turned on, with its link. }
function InterfaceIsUsable(NetworkInterface: PNetworkInterface): Boolean;
{ The subnet broadcast address of an interface with an address. }
function InterfaceBroadcastAddress(NetworkInterface: PNetworkInterface): TIpv4Address;

{ Sends a whole frame (an Ethernet frame, or an IPv4 datagram on lo) and
  takes the packet: sent, queued for later, or dropped. }
procedure TransmitInterfaceFrame(NetworkInterface: PNetworkInterface; Packet: PPacket);
{ For the network thread: sends what waits and takes in a changed
  link, for every interface a driver marked. }
procedure ProcessInterfaceEvents;
{ Marks an interface for the network thread (drivers, any level up to
  dispatch). }
procedure PostInterfaceEvent(NetworkInterface: PNetworkInterface; Event: PtrUInt);
{ Counts a received frame of Length bytes. }
procedure CountReceivedFrame(NetworkInterface: PNetworkInterface; Length: LongWord);
procedure CountReceiveDrop(NetworkInterface: PNetworkInterface);
procedure CountReceiveError(NetworkInterface: PNetworkInterface);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Atomic,
  Memory.KernelHeap,
  Network.Core,
  Network.ChangeWatchers,
  Network.Ipv6Interfaces,
  Debug.Output;

var
  Interfaces: array[0..MaximumNetworkInterfaces - 1] of PNetworkInterface;
  InterfaceCount: Integer;

function CreateNetworkInterface(Adapter: PNetworkAdapter; IsLoopback: Boolean): PNetworkInterface;
begin
  if InterfaceCount >= MaximumNetworkInterfaces then
    Exit(nil);
  Result := PNetworkInterface(AllocateZeroedKernelMemory(SizeOf(TNetworkInterface)));
  if Result = nil then
    Exit;
  Result^.Index := InterfaceCount + 1;
  CopyText(@Result^.Name[0], @Adapter^.Name[0], NetworkInterfaceNameCapacity);
  CopyText(@Result^.Description[0], @Adapter^.Description[0], NetworkInterfaceDescriptionCapacity);
  Result^.Adapter := Adapter;
  Result^.IsLoopback := IsLoopback;
  Result^.HardwareAddress := Adapter^.Address;
  Result^.Mtu := DefaultMtu;
  Result^.LinkIsUp := Adapter^.Routines.LinkUp(Adapter^.Context);
  InitializeIpv6Interface(Result);
  InitializePacketQueue(Result^.TransmitQueue);
  Interfaces[InterfaceCount] := Result;
  Inc(InterfaceCount);
  NoteNetworkChange;
end;

function NetworkInterfaceCount: Integer;
begin
  Result := InterfaceCount;
end;

function NetworkInterfaceAt(Position: Integer): PNetworkInterface;
begin
  if (Position < 0) or (Position >= InterfaceCount) then
    Exit(nil);
  Result := Interfaces[Position];
end;

function FindInterfaceByName(Name: PChar): PNetworkInterface;
var
  Position: Integer;
begin
  for Position := 0 to InterfaceCount - 1 do
    if TextIsEqual(@Interfaces[Position]^.Name[0], Name) then
      Exit(Interfaces[Position]);
  Result := nil;
end;

function FindInterfaceByIndex(Index: LongWord): PNetworkInterface;
begin
  if (Index = 0) or (Index > LongWord(InterfaceCount)) then
    Exit(nil);
  Result := Interfaces[Index - 1];
end;

function FindInterfaceWithAddress(Address: TIpv4Address): PNetworkInterface;
var
  Position: Integer;
begin
  for Position := 0 to InterfaceCount - 1 do
    if Interfaces[Position]^.HasAddress and (Interfaces[Position]^.Address = Address) then
      Exit(Interfaces[Position]);
  Result := nil;
end;

function IsLocalAddress(Address: TIpv4Address): Boolean;
begin
  Result := IsLoopbackAddress(Address) or (FindInterfaceWithAddress(Address) <> nil);
end;

function InterfaceIsUsable(NetworkInterface: PNetworkInterface): Boolean;
begin
  Result := NetworkInterface^.IsUp and NetworkInterface^.LinkIsUp;
end;

function InterfaceBroadcastAddress(NetworkInterface: PNetworkInterface): TIpv4Address;
begin
  Result := SubnetBroadcast(NetworkInterface^.Address, NetworkInterface^.PrefixLength);
end;

{ Hands one frame to the driver; True if it took it. }
function TryTransmit(NetworkInterface: PNetworkInterface; Packet: PPacket): Boolean;
var
  Adapter: PNetworkAdapter;
begin
  Adapter := NetworkInterface^.Adapter;
  Result := Adapter^.Routines.Transmit(Adapter^.Context, PacketData(Packet), Packet^.Length);
  if Result then
  begin
    Inc(NetworkInterface^.Counters.SentPackets);
    NetworkInterface^.Counters.SentBytes := NetworkInterface^.Counters.SentBytes + Packet^.Length;
    FreePacket(Packet);
  end;
end;

procedure FlushTransmitQueue(NetworkInterface: PNetworkInterface);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(NetworkInterface^.TransmitQueue);
  while Packet <> nil do
  begin
    if not TryTransmit(NetworkInterface, Packet) then
    begin
      RequeuePacketAtFront(NetworkInterface^.TransmitQueue, Packet);
      Exit;
    end;
    Packet := DequeuePacket(NetworkInterface^.TransmitQueue);
  end;
end;

procedure TransmitInterfaceFrame(NetworkInterface: PNetworkInterface; Packet: PPacket);
begin
  if not NetworkInterface^.IsUp or (Packet^.Length > NetworkInterface^.Mtu + EthernetHeaderBytes) then
  begin
    Inc(NetworkInterface^.Counters.SendErrors);
    FreePacket(Packet);
    Exit;
  end;
  { Frames already waiting go first. }
  if NetworkInterface^.TransmitQueue.Count > 0 then
    FlushTransmitQueue(NetworkInterface);
  if (NetworkInterface^.TransmitQueue.Count = 0) and TryTransmit(NetworkInterface, Packet) then
    Exit;
  if NetworkInterface^.TransmitQueue.Count >= MaximumTransmitQueue then
  begin
    Inc(NetworkInterface^.Counters.SendDrops);
    FreePacket(Packet);
    Exit;
  end;
  EnqueuePacket(NetworkInterface^.TransmitQueue, Packet);
end;

procedure WriteLinkChange(NetworkInterface: PNetworkInterface);
begin
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  if NetworkInterface^.LinkIsUp then
    DebugWriteLine(': link up')
  else
    DebugWriteLine(': link down');
  DebugEndMessage;
end;

procedure ProcessInterfaceEvents;
var
  Position: Integer;
  NetworkInterface: PNetworkInterface;
  Events: PtrUInt;
  Adapter: PNetworkAdapter;
  LinkNow: Boolean;
begin
  for Position := 0 to InterfaceCount - 1 do
  begin
    NetworkInterface := Interfaces[Position];
    Events := AtomicExchange(NetworkInterface^.PendingEvents, 0);
    if (Events and InterfaceEventLinkChanged) <> 0 then
    begin
      Adapter := NetworkInterface^.Adapter;
      LinkNow := Adapter^.Routines.LinkUp(Adapter^.Context);
      if LinkNow <> NetworkInterface^.LinkIsUp then
      begin
        NetworkInterface^.LinkIsUp := LinkNow;
        WriteLinkChange(NetworkInterface);
        Ipv6InterfaceChanged(NetworkInterface);
        NoteNetworkChange;
      end;
    end;
    if NetworkInterface^.TransmitQueue.Count > 0 then
      FlushTransmitQueue(NetworkInterface);
  end;
end;

procedure PostInterfaceEvent(NetworkInterface: PNetworkInterface; Event: PtrUInt);
begin
  AtomicOr(NetworkInterface^.PendingEvents, Event);
  SignalNetworkWork;
end;

procedure CountReceivedFrame(NetworkInterface: PNetworkInterface; Length: LongWord);
begin
  Inc(NetworkInterface^.Counters.ReceivedPackets);
  NetworkInterface^.Counters.ReceivedBytes := NetworkInterface^.Counters.ReceivedBytes + Length;
end;

procedure CountReceiveDrop(NetworkInterface: PNetworkInterface);
begin
  Inc(NetworkInterface^.Counters.ReceiveDrops);
end;

procedure CountReceiveError(NetworkInterface: PNetworkInterface);
begin
  Inc(NetworkInterface^.Counters.ReceiveErrors);
end;

end.
