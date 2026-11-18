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
  ARP (RFC 826): the Ethernet address of an IPv4 neighbour.

  The cache keeps an entry per interface and address. Sending to a
  neighbour whose address is not known makes an incomplete entry: the
  datagram waits on it (up to MaximumPendingPerEntry of them, the oldest
  dropped first) while a request is broadcast, once a second up to
  RequestAttempts times. The answer completes the entry and sends what
  waited. With no answer the waiting datagrams are dropped, and each
  sender on this machine is told by an ICMP host unreachable (sent to
  itself), so ping says "Destination Host Unreachable".

  A known entry is trusted for ReachableSeconds, then forgotten and
  asked again when next needed; any ARP packet from the neighbour
  refreshes it. Requests for one of the interface's addresses are
  answered, and the asker is remembered (it is about to talk to us).
  Giving an interface an address announces it (a gratuitous request).
  Used under the network lock; the timers run on the network thread.
}
unit Network.Arp;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Packets,
  Network.Interfaces;

const
  MaximumArpEntries = 64;
  MaximumPendingPerEntry = 8;
  RequestAttempts = 3;
  RequestIntervalMilliseconds = 1000;
  ReachableSeconds = 600;

{ An ARP packet that arrived (Data: what follows the Ethernet header). }
procedure ArpInput(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
{ Sends an IPv4 datagram (the packet, with headroom for the Ethernet
  header) to NextHop on the link of NetworkInterface, asking for its
  address first if need be. Takes the packet. }
procedure SendToNeighbour(NetworkInterface: PNetworkInterface; NextHop: TIpv4Address; Packet: PPacket);
{ Announces the interface's address (a gratuitous request). }
procedure AnnounceAddress(NetworkInterface: PNetworkInterface);
{ Forgets every entry of the interface (its address changed or went). }
procedure ForgetInterfaceNeighbours(NetworkInterface: PNetworkInterface);
{ On the network thread: retries, expiries. }
procedure RunArpTimers(Now: QWord);

{ The Ethernet address of a neighbour whose answer is known; False if
  it is not (yet). }
function FindNeighbourAddress(NetworkInterface: PNetworkInterface; Address: TIpv4Address;
  out HardwareAddress: TEthernetAddress): Boolean;

function ArpEntryCount: Integer;
{ The entry at Position (from 0) as the system call shows it. }
function DescribeArpEntry(Position: Integer; out Description: TAbiArpEntry): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Network.ByteOrder,
  Network.Core,
  Network.Ethernet,
  Network.Icmp;

const
  ArpPacketBytes = 28;
  HardwareTypeEthernet = 1;
  OperationRequest = 1;
  OperationReply = 2;
  NanosecondsPerMillisecond = 1000 * 1000;
  NanosecondsPerSecond = QWord(1000) * NanosecondsPerMillisecond;
  IcmpCodeHostUnreachable = 1;

type
  TArpState = (ArpFree, ArpIncomplete, ArpReachable);

  PArpEntry = ^TArpEntry;
  TArpEntry = record
    State: TArpState;
    NetworkInterface: PNetworkInterface;
    Address: TIpv4Address;
    HardwareAddress: TEthernetAddress;
    { Reachable: when it is forgotten; incomplete: when to ask again. }
    Deadline: QWord;
    Attempts: Integer;
    Pending: TPacketQueue;
  end;

var
  Entries: array[0..MaximumArpEntries - 1] of TArpEntry;

function FindEntry(NetworkInterface: PNetworkInterface; Address: TIpv4Address): PArpEntry;
var
  Index: Integer;
begin
  for Index := 0 to MaximumArpEntries - 1 do
    if (Entries[Index].State <> ArpFree) and (Entries[Index].NetworkInterface = NetworkInterface) and
       (Entries[Index].Address = Address) then
      Exit(@Entries[Index]);
  Result := nil;
end;

procedure ReleaseEntry(Entry: PArpEntry);
begin
  DiscardPacketQueue(Entry^.Pending);
  Entry^.State := ArpFree;
end;

{ A free entry, or the reachable one that expires first. }
function AllocateEntry(NetworkInterface: PNetworkInterface; Address: TIpv4Address): PArpEntry;
var
  Index: Integer;
  Oldest: PArpEntry;
begin
  Oldest := nil;
  for Index := 0 to MaximumArpEntries - 1 do
  begin
    if Entries[Index].State = ArpFree then
    begin
      Oldest := @Entries[Index];
      Break;
    end;
    if (Entries[Index].State = ArpReachable) and
       ((Oldest = nil) or (Entries[Index].Deadline < Oldest^.Deadline)) then
      Oldest := @Entries[Index];
  end;
  if Oldest = nil then
    Exit(nil);
  if Oldest^.State <> ArpFree then
    ReleaseEntry(Oldest);
  FillMemory(Oldest, SizeOf(TArpEntry), 0);
  Oldest^.NetworkInterface := NetworkInterface;
  Oldest^.Address := Address;
  InitializePacketQueue(Oldest^.Pending);
  Result := Oldest;
end;

procedure SendArpPacket(NetworkInterface: PNetworkInterface; Operation: Word;
  const TargetHardware: TEthernetAddress; TargetAddress: TIpv4Address;
  const FrameDestination: TEthernetAddress);
var
  Packet: PPacket;
  Data: PByte;
  SenderAddress: TIpv4Address;
begin
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Data := AppendToPacket(Packet, ArpPacketBytes);
  WriteBigEndian16(Data, HardwareTypeEthernet);
  WriteBigEndian16(Data + 2, EtherTypeIpv4);
  Data[4] := EthernetAddressLength;
  Data[5] := 4;
  WriteBigEndian16(Data + 6, Operation);
  CopyMemory(Data + 8, @NetworkInterface^.HardwareAddress[0], EthernetAddressLength);
  SenderAddress := AnyAddress;
  if NetworkInterface^.HasAddress then
    SenderAddress := NetworkInterface^.Address;
  WriteIpv4Address(Data + 14, SenderAddress);
  CopyMemory(Data + 18, @TargetHardware[0], EthernetAddressLength);
  WriteIpv4Address(Data + 24, TargetAddress);
  SendEthernetFrame(NetworkInterface, FrameDestination, EtherTypeArp, Packet);
end;

procedure SendRequest(NetworkInterface: PNetworkInterface; Address: TIpv4Address);
const
  UnknownHardware: TEthernetAddress = (0, 0, 0, 0, 0, 0);
begin
  SendArpPacket(NetworkInterface, OperationRequest, UnknownHardware, Address, BroadcastEthernetAddress);
end;

procedure SendPending(Entry: PArpEntry);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(Entry^.Pending);
  while Packet <> nil do
  begin
    SendEthernetFrame(Entry^.NetworkInterface, Entry^.HardwareAddress, EtherTypeIpv4, Packet);
    Packet := DequeuePacket(Entry^.Pending);
  end;
end;

procedure LearnNeighbour(Entry: PArpEntry; Hardware: PByte);
begin
  CopyMemory(@Entry^.HardwareAddress[0], Hardware, EthernetAddressLength);
  Entry^.State := ArpReachable;
  Entry^.Deadline := NetworkNow + QWord(ReachableSeconds) * NanosecondsPerSecond;
  Entry^.Attempts := 0;
  SendPending(Entry);
end;

procedure ArpInput(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
var
  Operation: Word;
  SenderAddress: TIpv4Address;
  TargetAddress: TIpv4Address;
  Entry: PArpEntry;
  IsForUs: Boolean;
  SenderHardware: TEthernetAddress;
begin
  if (Length < ArpPacketBytes) or (ReadBigEndian16(Data) <> HardwareTypeEthernet) or
     (ReadBigEndian16(Data + 2) <> EtherTypeIpv4) or (Data[4] <> EthernetAddressLength) or (Data[5] <> 4) then
  begin
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  Operation := ReadBigEndian16(Data + 6);
  SenderAddress := ReadIpv4Address(Data + 14);
  TargetAddress := ReadIpv4Address(Data + 24);
  CopyMemory(@SenderHardware[0], Data + 8, EthernetAddressLength);
  IsForUs := NetworkInterface^.HasAddress and (TargetAddress = NetworkInterface^.Address);
  if SenderAddress = AnyAddress then
  begin
    { A probe from a host checking whether an address is taken. }
    if IsForUs and (Operation = OperationRequest) then
      SendArpPacket(NetworkInterface, OperationReply, SenderHardware, SenderAddress, SenderHardware);
    Exit;
  end;
  Entry := FindEntry(NetworkInterface, SenderAddress);
  if Entry <> nil then
    LearnNeighbour(Entry, Data + 8)
  else if IsForUs then
  begin
    Entry := AllocateEntry(NetworkInterface, SenderAddress);
    if Entry <> nil then
      LearnNeighbour(Entry, Data + 8);
  end;
  if IsForUs and (Operation = OperationRequest) then
    SendArpPacket(NetworkInterface, OperationReply, SenderHardware, SenderAddress, SenderHardware);
end;

procedure SendToNeighbour(NetworkInterface: PNetworkInterface; NextHop: TIpv4Address; Packet: PPacket);
var
  Entry: PArpEntry;
begin
  Entry := FindEntry(NetworkInterface, NextHop);
  if (Entry <> nil) and (Entry^.State = ArpReachable) then
  begin
    SendEthernetFrame(NetworkInterface, Entry^.HardwareAddress, EtherTypeIpv4, Packet);
    Exit;
  end;
  if Entry = nil then
  begin
    Entry := AllocateEntry(NetworkInterface, NextHop);
    if Entry = nil then
    begin
      Inc(NetworkInterface^.Counters.SendDrops);
      FreePacket(Packet);
      Exit;
    end;
    Entry^.State := ArpIncomplete;
    Entry^.Attempts := 1;
    Entry^.Deadline := NetworkNow + RequestIntervalMilliseconds * NanosecondsPerMillisecond;
    RequestNetworkWakeAt(Entry^.Deadline);
    SendRequest(NetworkInterface, NextHop);
  end;
  if Entry^.Pending.Count >= MaximumPendingPerEntry then
  begin
    Inc(NetworkInterface^.Counters.SendDrops);
    FreePacket(DequeuePacket(Entry^.Pending));
  end;
  EnqueuePacket(Entry^.Pending, Packet);
end;

procedure AnnounceAddress(NetworkInterface: PNetworkInterface);
begin
  if NetworkInterface^.HasAddress and not NetworkInterface^.IsLoopback and NetworkInterface^.IsUp then
    SendRequest(NetworkInterface, NetworkInterface^.Address);
end;

procedure ForgetInterfaceNeighbours(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
begin
  for Index := 0 to MaximumArpEntries - 1 do
    if (Entries[Index].State <> ArpFree) and (Entries[Index].NetworkInterface = NetworkInterface) then
      ReleaseEntry(@Entries[Index]);
end;

{ No answer came: the senders hear of it, the datagrams are dropped. }
procedure GiveUpOnEntry(Entry: PArpEntry);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(Entry^.Pending);
  while Packet <> nil do
  begin
    Inc(Entry^.NetworkInterface^.Counters.SendDrops);
    ReportUndeliverableDatagram(PacketData(Packet), Packet^.Length, IcmpCodeHostUnreachable);
    FreePacket(Packet);
    Packet := DequeuePacket(Entry^.Pending);
  end;
  ReleaseEntry(Entry);
end;

procedure RunArpTimers(Now: QWord);
var
  Index: Integer;
  Entry: PArpEntry;
begin
  for Index := 0 to MaximumArpEntries - 1 do
  begin
    Entry := @Entries[Index];
    if Entry^.State = ArpFree then
      Continue;
    if Entry^.Deadline <= Now then
    begin
      if Entry^.State = ArpReachable then
      begin
        ReleaseEntry(Entry);
        Continue;
      end;
      if Entry^.Attempts >= RequestAttempts then
      begin
        GiveUpOnEntry(Entry);
        Continue;
      end;
      Inc(Entry^.Attempts);
      Entry^.Deadline := Now + RequestIntervalMilliseconds * NanosecondsPerMillisecond;
      SendRequest(Entry^.NetworkInterface, Entry^.Address);
    end;
    RequestNetworkWakeAt(Entry^.Deadline);
  end;
end;

function FindNeighbourAddress(NetworkInterface: PNetworkInterface; Address: TIpv4Address;
  out HardwareAddress: TEthernetAddress): Boolean;
var
  Entry: PArpEntry;
begin
  FillMemory(@HardwareAddress[0], EthernetAddressLength, 0);
  Entry := FindEntry(NetworkInterface, Address);
  Result := (Entry <> nil) and (Entry^.State = ArpReachable);
  if Result then
    HardwareAddress := Entry^.HardwareAddress;
end;

function ArpEntryCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumArpEntries - 1 do
    if Entries[Index].State <> ArpFree then
      Inc(Result);
end;

function DescribeArpEntry(Position: Integer; out Description: TAbiArpEntry): Boolean;
var
  Index: Integer;
  Seen: Integer;
  Entry: PArpEntry;
  Now: QWord;
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Seen := 0;
  Now := NetworkNow;
  for Index := 0 to MaximumArpEntries - 1 do
  begin
    Entry := @Entries[Index];
    if Entry^.State = ArpFree then
      Continue;
    if Seen = Position then
    begin
      WriteIpv4Address(@Description.Address[0], Entry^.Address);
      CopyText(@Description.InterfaceName[0], @Entry^.NetworkInterface^.Name[0], NetworkInterfaceNameCapacity);
      if Entry^.State = ArpReachable then
      begin
        Description.State := ArpStateReachable;
        CopyMemory(@Description.HardwareAddress[0], @Entry^.HardwareAddress[0], EthernetAddressLength);
        if Entry^.Deadline > Now then
          Description.ExpiresInSeconds := LongWord((Entry^.Deadline - Now) div NanosecondsPerSecond);
      end
      else
        Description.State := ArpStateIncomplete;
      Exit(True);
    end;
    Inc(Seen);
  end;
  Result := False;
end;

end.
