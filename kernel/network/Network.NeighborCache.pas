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
  IPv6's neighbour cache (RFC 4861 7.3), IPv6's ARP cache: the Ethernet
  address of each neighbour a datagram went to or came from.

  An entry is INCOMPLETE while its address is asked for (a multicast
  neighbour solicitation once a second, three times; the datagrams for
  it wait, at most 8, and their senders get "address unreachable" if no
  answer comes), REACHABLE for the reachable time after a solicited
  advertisement confirmed it, then STALE: still used, and the first
  datagram sent to a stale neighbour starts a check (DELAY of 5 s, then
  PROBE: unicast solicitations once a second, three times; an
  unanswered probe removes the entry). A stale entry nobody uses is
  forgotten after ten minutes. Unsolicited advertisements, and
  solicitations and router messages with a source link-layer address
  option, make or update STALE entries. Under the network lock.
}
unit Network.NeighborCache;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Io.NetworkAdapters,
  Network.Ipv6Addresses,
  Network.Packets,
  Network.Interfaces;

const
  MaximumNeighbors = 64;
  MaximumPendingPerNeighbor = 8;
  MulticastSolicitations = 3;
  UnicastSolicitations = 3;
  DelayFirstProbeSeconds = 5;
  StaleLifetimeSeconds = 600;

{ Sends an IPv6 datagram (the packet, with headroom for the Ethernet
  header) to NextHop on the link of NetworkInterface, asking for its
  Ethernet address first if need be. Takes the packet. }
procedure SendToIpv6Neighbor(NetworkInterface: PNetworkInterface; constref NextHop: TIpv6Address; Packet: PPacket);
{ A neighbour advertisement for Target arrived (Hardware: its target
  link-layer address option, or nil). }
procedure NeighborAdvertised(NetworkInterface: PNetworkInterface; constref Target: TIpv6Address; Hardware: PByte;
  Solicited, Override, IsRouter: Boolean);
{ A message from Address came with its source link-layer address
  (solicitation, router solicitation or advertisement). IsRouter: it
  was a router advertisement. }
procedure NeighborSeen(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address; Hardware: PByte;
  IsRouter: Boolean);
{ Forgets every entry of the interface (it went down, or IPv6 off). }
procedure ForgetIpv6Neighbors(NetworkInterface: PNetworkInterface);
{ On the network thread: retries, probes, expiries. }
procedure RunNeighborTimers(Now: QWord);
function NeighborEntryCount: Integer;
{ The entry at Position (from 0) as the system call shows it. }
function DescribeNeighborEntry(Position: Integer; out Description: TAbiNeighborEntry): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Network.Core,
  Network.Ethernet,
  Network.NeighborMessages,
  Network.Icmpv6;

const
  NanosecondsPerMillisecond = 1000 * 1000;
  NanosecondsPerSecond = QWord(1000) * NanosecondsPerMillisecond;

type
  TNeighborState = (NeighborFree, NeighborIncomplete, NeighborReachable, NeighborStale, NeighborDelay, NeighborProbe);

  PNeighborEntry = ^TNeighborEntry;
  TNeighborEntry = record
    State: TNeighborState;
    NetworkInterface: PNetworkInterface;
    Address: TIpv6Address;
    HardwareAddress: TEthernetAddress;
    IsRouter: Boolean;
    { When the state's time is up. }
    Deadline: QWord;
    Attempts: Integer;
    Pending: TPacketQueue;
  end;

var
  Entries: array[0..MaximumNeighbors - 1] of TNeighborEntry;

function RetransmitNanoseconds(NetworkInterface: PNetworkInterface): QWord;
begin
  Result := QWord(NetworkInterface^.Ipv6.RetransmitMilliseconds) * NanosecondsPerMillisecond;
end;

function ReachableNanoseconds(NetworkInterface: PNetworkInterface): QWord;
begin
  Result := QWord(NetworkInterface^.Ipv6.ReachableMilliseconds) * NanosecondsPerMillisecond;
end;

procedure SetDeadline(Entry: PNeighborEntry; Deadline: QWord);
begin
  Entry^.Deadline := Deadline;
  RequestNetworkWakeAt(Deadline);
end;

function FindEntry(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): PNeighborEntry;
var
  Index: Integer;
begin
  for Index := 0 to MaximumNeighbors - 1 do
    if (Entries[Index].State <> NeighborFree) and (Entries[Index].NetworkInterface = NetworkInterface) and
       Ipv6AddressesEqual(Entries[Index].Address, Address) then
      Exit(@Entries[Index]);
  Result := nil;
end;

procedure ReleaseEntry(Entry: PNeighborEntry);
begin
  DiscardPacketQueue(Entry^.Pending);
  Entry^.State := NeighborFree;
end;

{ A free entry, or the stale (else reachable) one that expires first. }
function AllocateEntry(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): PNeighborEntry;
var
  Index: Integer;
  Oldest: PNeighborEntry;
begin
  Oldest := nil;
  for Index := 0 to MaximumNeighbors - 1 do
  begin
    if Entries[Index].State = NeighborFree then
    begin
      Oldest := @Entries[Index];
      Break;
    end;
    if (Entries[Index].State in [NeighborStale, NeighborReachable]) and
       ((Oldest = nil) or (Entries[Index].Deadline < Oldest^.Deadline)) then
      Oldest := @Entries[Index];
  end;
  if Oldest = nil then
    Exit(nil);
  if Oldest^.State <> NeighborFree then
    ReleaseEntry(Oldest);
  FillMemory(Oldest, SizeOf(TNeighborEntry), 0);
  Oldest^.NetworkInterface := NetworkInterface;
  Oldest^.Address := Address;
  InitializePacketQueue(Oldest^.Pending);
  Result := Oldest;
end;

procedure SendPending(Entry: PNeighborEntry);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(Entry^.Pending);
  while Packet <> nil do
  begin
    SendEthernetFrame(Entry^.NetworkInterface, Entry^.HardwareAddress, EtherTypeIpv6, Packet);
    Packet := DequeuePacket(Entry^.Pending);
  end;
end;

procedure EnterStale(Entry: PNeighborEntry);
begin
  Entry^.State := NeighborStale;
  Entry^.Attempts := 0;
  SetDeadline(Entry, NetworkNow + QWord(StaleLifetimeSeconds) * NanosecondsPerSecond);
end;

procedure EnterReachable(Entry: PNeighborEntry);
begin
  Entry^.State := NeighborReachable;
  Entry^.Attempts := 0;
  SetDeadline(Entry, NetworkNow + ReachableNanoseconds(Entry^.NetworkInterface));
end;

procedure SolicitMulticast(Entry: PNeighborEntry);
begin
  SendNeighborSolicitation(Entry^.NetworkInterface, Entry^.Address, SolicitedNodeAddress(Entry^.Address), False);
end;

procedure SolicitUnicast(Entry: PNeighborEntry);
begin
  SendNeighborSolicitation(Entry^.NetworkInterface, Entry^.Address, Entry^.Address, False);
end;

procedure QueuePacket(Entry: PNeighborEntry; Packet: PPacket);
begin
  if Entry^.Pending.Count >= MaximumPendingPerNeighbor then
  begin
    Inc(Entry^.NetworkInterface^.Counters.SendDrops);
    FreePacket(DequeuePacket(Entry^.Pending));
  end;
  EnqueuePacket(Entry^.Pending, Packet);
end;

procedure SendToIpv6Neighbor(NetworkInterface: PNetworkInterface; constref NextHop: TIpv6Address; Packet: PPacket);
var
  Entry: PNeighborEntry;
begin
  Entry := FindEntry(NetworkInterface, NextHop);
  if Entry = nil then
  begin
    Entry := AllocateEntry(NetworkInterface, NextHop);
    if Entry = nil then
    begin
      Inc(NetworkInterface^.Counters.SendDrops);
      FreePacket(Packet);
      Exit;
    end;
    Entry^.State := NeighborIncomplete;
    Entry^.Attempts := 1;
    SetDeadline(Entry, NetworkNow + RetransmitNanoseconds(NetworkInterface));
    QueuePacket(Entry, Packet);
    SolicitMulticast(Entry);
    Exit;
  end;
  case Entry^.State of
    NeighborIncomplete:
      QueuePacket(Entry, Packet);
    NeighborStale:
      begin
        Entry^.State := NeighborDelay;
        SetDeadline(Entry, NetworkNow + QWord(DelayFirstProbeSeconds) * NanosecondsPerSecond);
        SendEthernetFrame(NetworkInterface, Entry^.HardwareAddress, EtherTypeIpv6, Packet);
      end;
  else
    SendEthernetFrame(NetworkInterface, Entry^.HardwareAddress, EtherTypeIpv6, Packet);
  end;
end;

procedure NeighborAdvertised(NetworkInterface: PNetworkInterface; constref Target: TIpv6Address; Hardware: PByte;
  Solicited, Override, IsRouter: Boolean);
var
  Entry: PNeighborEntry;
  Changed: Boolean;
begin
  Entry := FindEntry(NetworkInterface, Target);
  if Entry = nil then
    Exit;
  if Entry^.State = NeighborIncomplete then
  begin
    if Hardware = nil then
      Exit;
    CopyMemory(@Entry^.HardwareAddress[0], Hardware, EthernetAddressLength);
    Entry^.IsRouter := IsRouter;
    if Solicited then
      EnterReachable(Entry)
    else
      EnterStale(Entry);
    SendPending(Entry);
    Exit;
  end;
  Changed := (Hardware <> nil) and not MemoryIsEqual(Hardware, @Entry^.HardwareAddress[0], EthernetAddressLength);
  if not Override and Changed then
  begin
    { Another address claimed without override: only doubt the one we
      have. }
    if Entry^.State = NeighborReachable then
      EnterStale(Entry);
    Exit;
  end;
  if Changed then
    CopyMemory(@Entry^.HardwareAddress[0], Hardware, EthernetAddressLength);
  Entry^.IsRouter := IsRouter;
  if Solicited then
    EnterReachable(Entry)
  else if Changed then
    EnterStale(Entry);
end;

procedure NeighborSeen(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address; Hardware: PByte;
  IsRouter: Boolean);
var
  Entry: PNeighborEntry;
  WasIncomplete: Boolean;
begin
  if (Hardware = nil) or IsUnspecifiedIpv6Address(Address) then
    Exit;
  Entry := FindEntry(NetworkInterface, Address);
  if Entry = nil then
  begin
    Entry := AllocateEntry(NetworkInterface, Address);
    if Entry = nil then
      Exit;
    CopyMemory(@Entry^.HardwareAddress[0], Hardware, EthernetAddressLength);
    Entry^.IsRouter := IsRouter;
    EnterStale(Entry);
    Exit;
  end;
  if IsRouter then
    Entry^.IsRouter := True;
  WasIncomplete := Entry^.State = NeighborIncomplete;
  if WasIncomplete or not MemoryIsEqual(Hardware, @Entry^.HardwareAddress[0], EthernetAddressLength) then
  begin
    CopyMemory(@Entry^.HardwareAddress[0], Hardware, EthernetAddressLength);
    EnterStale(Entry);
    if WasIncomplete then
      SendPending(Entry);
  end;
end;

procedure ForgetIpv6Neighbors(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
begin
  for Index := 0 to MaximumNeighbors - 1 do
    if (Entries[Index].State <> NeighborFree) and (Entries[Index].NetworkInterface = NetworkInterface) then
      ReleaseEntry(@Entries[Index]);
end;

{ No answer came: the senders hear of it, the datagrams are dropped. }
procedure GiveUpOnEntry(Entry: PNeighborEntry);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(Entry^.Pending);
  while Packet <> nil do
  begin
    Inc(Entry^.NetworkInterface^.Counters.SendDrops);
    ReportUndeliverableIpv6Datagram(PacketData(Packet), Packet^.Length);
    FreePacket(Packet);
    Packet := DequeuePacket(Entry^.Pending);
  end;
  ReleaseEntry(Entry);
end;

procedure RunEntryTimer(Entry: PNeighborEntry; Now: QWord);
var
  Retransmit: QWord;
begin
  Retransmit := RetransmitNanoseconds(Entry^.NetworkInterface);
  case Entry^.State of
    NeighborIncomplete:
      if Entry^.Attempts >= MulticastSolicitations then
        GiveUpOnEntry(Entry)
      else
      begin
        Inc(Entry^.Attempts);
        SetDeadline(Entry, Now + Retransmit);
        SolicitMulticast(Entry);
      end;
    NeighborReachable:
      EnterStale(Entry);
    NeighborStale:
      ReleaseEntry(Entry);
    NeighborDelay:
      begin
        Entry^.State := NeighborProbe;
        Entry^.Attempts := 1;
        SetDeadline(Entry, Now + Retransmit);
        SolicitUnicast(Entry);
      end;
    NeighborProbe:
      if Entry^.Attempts >= UnicastSolicitations then
        ReleaseEntry(Entry)
      else
      begin
        Inc(Entry^.Attempts);
        SetDeadline(Entry, Now + Retransmit);
        SolicitUnicast(Entry);
      end;
  end;
end;

procedure RunNeighborTimers(Now: QWord);
var
  Index: Integer;
  Entry: PNeighborEntry;
begin
  for Index := 0 to MaximumNeighbors - 1 do
  begin
    Entry := @Entries[Index];
    if Entry^.State = NeighborFree then
      Continue;
    if Entry^.Deadline <= Now then
      RunEntryTimer(Entry, Now)
    else
      RequestNetworkWakeAt(Entry^.Deadline);
  end;
end;

function NeighborEntryCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumNeighbors - 1 do
    if Entries[Index].State <> NeighborFree then
      Inc(Result);
end;

function AbiState(State: TNeighborState): LongWord;
begin
  case State of
    NeighborIncomplete: Result := NeighborStateIncomplete;
    NeighborReachable: Result := NeighborStateReachable;
    NeighborStale: Result := NeighborStateStale;
  else
    Result := NeighborStateProbe;
  end;
end;

function DescribeNeighborEntry(Position: Integer; out Description: TAbiNeighborEntry): Boolean;
var
  Index: Integer;
  Seen: Integer;
  Entry: PNeighborEntry;
  Now: QWord;
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Seen := 0;
  Now := NetworkNow;
  for Index := 0 to MaximumNeighbors - 1 do
  begin
    Entry := @Entries[Index];
    if Entry^.State = NeighborFree then
      Continue;
    if Seen = Position then
    begin
      CopyMemory(@Description.Address[0], @Entry^.Address[0], Ipv6AddressLength);
      CopyText(@Description.InterfaceName[0], @Entry^.NetworkInterface^.Name[0], NetworkInterfaceNameCapacity);
      Description.State := AbiState(Entry^.State);
      if Entry^.State <> NeighborIncomplete then
        CopyMemory(@Description.HardwareAddress[0], @Entry^.HardwareAddress[0], EthernetAddressLength);
      if Entry^.IsRouter then
        Description.Flags := NeighborFlagRouter;
      if Entry^.Deadline > Now then
        Description.ExpiresInSeconds := LongWord((Entry^.Deadline - Now) div NanosecondsPerSecond);
      Exit(True);
    end;
    Inc(Seen);
  end;
  Result := False;
end;

end.
