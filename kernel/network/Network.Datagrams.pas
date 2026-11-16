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
  The queue of datagrams a UDP or ICMP socket has received and not yet
  read: each with where it came from and its time to live. The queue is
  bounded by count and by bytes; a datagram that does not fit is
  dropped, as UDP allows.
}
unit Network.Datagrams;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Network.Addresses;

const
  MaximumQueuedDatagrams = 64;
  MaximumQueuedDatagramBytes = 128 * 1024;

type
  PDatagramEntry = ^TDatagramEntry;
  TDatagramEntry = record
    Link: TListEntry;
    Source: TNetworkEndpoint;
    TimeToLive: Byte;
    Length: LongWord;
    { Length bytes follow the record. }
  end;

  TDatagramQueue = record
    Head: TListEntry;
    Count: LongWord;
    Bytes: LongWord;
  end;

procedure InitializeDatagramQueue(out Queue: TDatagramQueue);
{ Copies a datagram in; False (nothing kept) if the queue is full. }
function EnqueueDatagram(var Queue: TDatagramQueue; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord): Boolean;
{ The first datagram, still queued; nil if none. }
function FirstDatagram(constref Queue: TDatagramQueue): PDatagramEntry;
function DatagramData(Entry: PDatagramEntry): PByte;
procedure RemoveFirstDatagram(var Queue: TDatagramQueue);
procedure DiscardDatagrams(var Queue: TDatagramQueue);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

procedure InitializeDatagramQueue(out Queue: TDatagramQueue);
begin
  InitializeListHead(Queue.Head);
  Queue.Count := 0;
  Queue.Bytes := 0;
end;

function EnqueueDatagram(var Queue: TDatagramQueue; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord): Boolean;
var
  Entry: PDatagramEntry;
begin
  if (Queue.Count >= MaximumQueuedDatagrams) or (Queue.Bytes + Length > MaximumQueuedDatagramBytes) then
    Exit(False);
  Entry := PDatagramEntry(AllocateKernelMemory(SizeOf(TDatagramEntry) + Length));
  if Entry = nil then
    Exit(False);
  Entry^.Source := Source;
  Entry^.TimeToLive := TimeToLive;
  Entry^.Length := Length;
  CopyMemory(DatagramData(Entry), Data, Length);
  InsertAtTail(Queue.Head, @Entry^.Link);
  Inc(Queue.Count);
  Queue.Bytes := Queue.Bytes + Length;
  Result := True;
end;

function FirstDatagram(constref Queue: TDatagramQueue): PDatagramEntry;
var
  Entry: PListEntry;
begin
  Entry := FirstListEntry(Queue.Head);
  if Entry = nil then
    Exit(nil);
  Result := PDatagramEntry(ContainingRecord(Entry, FieldOffset(PDatagramEntry(nil)^.Link)));
end;

function DatagramData(Entry: PDatagramEntry): PByte;
begin
  Result := PByte(Entry) + SizeOf(TDatagramEntry);
end;

procedure RemoveFirstDatagram(var Queue: TDatagramQueue);
var
  Entry: PDatagramEntry;
begin
  Entry := FirstDatagram(Queue);
  if Entry = nil then
    Exit;
  RemoveListEntry(@Entry^.Link);
  Dec(Queue.Count);
  Queue.Bytes := Queue.Bytes - Entry^.Length;
  FreeKernelMemory(Entry);
end;

procedure DiscardDatagrams(var Queue: TDatagramQueue);
begin
  while Queue.Count > 0 do
    RemoveFirstDatagram(Queue);
end;

end.
