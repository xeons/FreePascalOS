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
  Packet buffers: one frame each, from the kernel heap.

  A packet holds up to PacketCapacity bytes, of which Length bytes from
  Start are in use. A packet being built starts with headroom: each
  layer on the way down prepends its header (PrependToPacket) in front
  of what the layer above wrote, so nothing is copied. A received frame
  is one packet; each layer on the way up looks past its header.

  Packets queue on a TPacketQueue (a list and a count). The heap may be
  used at dispatch level, so a driver's deferred routine can have a
  received frame copied into a packet there.
}
unit Network.Packets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList;

const
  { Room for an Ethernet, an IPv4 and a TCP header with options. }
  PacketHeadroom = 128;
  { A whole Ethernet frame (1514 bytes) after the headroom. }
  PacketCapacity = PacketHeadroom + 1536;

type
  PPacket = ^TPacket;
  TPacket = record
    Link: TListEntry;
    { The interface a received packet came in on (a PNetworkInterface),
      or the one it goes out on. }
    NetworkInterface: Pointer;
    { Where the bytes in use begin, and how many there are. }
    Start: LongWord;
    Length: LongWord;
    Bytes: array[0..PacketCapacity - 1] of Byte;
  end;

  TPacketQueue = record
    Head: TListEntry;
    Count: LongWord;
  end;

{ A packet with Headroom bytes free in front and nothing in it yet; nil
  if memory is short. }
function AllocatePacket(Headroom: LongWord): PPacket;
procedure FreePacket(Packet: PPacket);
{ The first byte in use. }
function PacketData(Packet: PPacket): PByte;
{ Makes room for Count bytes in front of the data and returns where
  they go; nil if the headroom is used up. }
function PrependToPacket(Packet: PPacket; Count: LongWord): PByte;
{ Makes room for Count more bytes at the end and returns where they go;
  nil if the packet is full. }
function AppendToPacket(Packet: PPacket; Count: LongWord): PByte;
{ A copy with the same headroom; nil if memory is short. }
function CopyPacket(Packet: PPacket): PPacket;

procedure InitializePacketQueue(out Queue: TPacketQueue);
procedure EnqueuePacket(var Queue: TPacketQueue; Packet: PPacket);
{ Puts a packet back at the front (one that could not be sent). }
procedure RequeuePacketAtFront(var Queue: TPacketQueue; Packet: PPacket);
{ The first packet, taken off the queue; nil if it is empty. }
function DequeuePacket(var Queue: TPacketQueue): PPacket;
{ Frees every packet on the queue. }
procedure DiscardPacketQueue(var Queue: TPacketQueue);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

function AllocatePacket(Headroom: LongWord): PPacket;
begin
  if Headroom > PacketCapacity then
    Exit(nil);
  Result := PPacket(AllocateKernelMemory(SizeOf(TPacket)));
  if Result = nil then
    Exit;
  Result^.Link.Next := nil;
  Result^.Link.Previous := nil;
  Result^.NetworkInterface := nil;
  Result^.Start := Headroom;
  Result^.Length := 0;
end;

procedure FreePacket(Packet: PPacket);
begin
  if Packet <> nil then
    FreeKernelMemory(Packet);
end;

function PacketData(Packet: PPacket): PByte;
begin
  Result := @Packet^.Bytes[Packet^.Start];
end;

function PrependToPacket(Packet: PPacket; Count: LongWord): PByte;
begin
  if Count > Packet^.Start then
    Exit(nil);
  Packet^.Start := Packet^.Start - Count;
  Packet^.Length := Packet^.Length + Count;
  Result := @Packet^.Bytes[Packet^.Start];
end;

function AppendToPacket(Packet: PPacket; Count: LongWord): PByte;
begin
  if Packet^.Start + Packet^.Length + Count > PacketCapacity then
    Exit(nil);
  Result := @Packet^.Bytes[Packet^.Start + Packet^.Length];
  Packet^.Length := Packet^.Length + Count;
end;

function CopyPacket(Packet: PPacket): PPacket;
begin
  Result := AllocatePacket(Packet^.Start);
  if Result = nil then
    Exit;
  Result^.NetworkInterface := Packet^.NetworkInterface;
  Result^.Length := Packet^.Length;
  CopyMemory(@Result^.Bytes[Result^.Start], @Packet^.Bytes[Packet^.Start], Packet^.Length);
end;

procedure InitializePacketQueue(out Queue: TPacketQueue);
begin
  InitializeListHead(Queue.Head);
  Queue.Count := 0;
end;

procedure EnqueuePacket(var Queue: TPacketQueue; Packet: PPacket);
begin
  InsertAtTail(Queue.Head, @Packet^.Link);
  Inc(Queue.Count);
end;

procedure RequeuePacketAtFront(var Queue: TPacketQueue; Packet: PPacket);
begin
  InsertAtHead(Queue.Head, @Packet^.Link);
  Inc(Queue.Count);
end;

function DequeuePacket(var Queue: TPacketQueue): PPacket;
var
  Entry: PListEntry;
begin
  Entry := RemoveHeadEntry(Queue.Head);
  if Entry = nil then
    Exit(nil);
  Dec(Queue.Count);
  Result := PPacket(ContainingRecord(Entry, FieldOffset(PPacket(nil)^.Link)));
end;

procedure DiscardPacketQueue(var Queue: TPacketQueue);
var
  Packet: PPacket;
begin
  Packet := DequeuePacket(Queue);
  while Packet <> nil do
  begin
    FreePacket(Packet);
    Packet := DequeuePacket(Queue);
  end;
end;

end.
