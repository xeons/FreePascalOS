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
  The table of TCP connections: making them, finding the one a segment
  belongs to, and freeing them.

  A segment belongs to the connection with its four endpoints, else to
  a listener on its destination port (one bound to the destination
  address before one bound to every address). Closed connections are
  never found: one still held by its socket only waits for the socket
  to close. Initial sequence numbers come from the clock (4 per
  microsecond, as RFC 793 suggests) plus a random offset taken once.
  Used under the network lock.
}
unit Network.TcpConnections;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.TcpTypes;

procedure InitializeTcpConnections;
{ A new connection in the table, closed, without buffers; nil if memory
  is short. }
function CreateTcpConnection: PTcpConnection;
{ The send and receive buffers of a connection that will carry data:
  the sizes its socket asked for, else 64 KiB each to grow from. }
function CreateConnectionBuffers(Connection: PTcpConnection): Boolean;
{ Takes a connection out of the table (and off its listener's queue)
  and frees it with everything it holds. }
procedure FreeTcpConnection(Connection: PTcpConnection);
function FirstTcpConnection: PTcpConnection;
function NextTcpConnection(Connection: PTcpConnection): PTcpConnection;
function FindTcpConnection(constref Local, Remote: TNetworkEndpoint): PTcpConnection;
function FindTcpListener(constref Local: TNetworkEndpoint): PTcpConnection;
function GenerateInitialSequence: LongWord;
{ Frees the out-of-order segments a connection keeps. }
procedure DiscardOutOfOrder(Connection: PTcpConnection);

implementation

uses
  Runtime.LinkedList,
  Memory.KernelHeap,
  Kernel.Arch.Cpu,
  Network.ByteRings,
  Network.TcpWindows,
  Network.TcpReceivedBlocks,
  Network.Core;

var
  Connections: TListEntry;
  SequenceOffset: LongWord;

procedure InitializeTcpConnections;
var
  Random: QWord;
begin
  InitializeListHead(Connections);
  if not ReadHardwareRandom(Random) then
    Random := ReadTimeStampCounter * 2654435761;
  SequenceOffset := LongWord(Random);
end;

function CreateTcpConnection: PTcpConnection;
begin
  Result := PTcpConnection(AllocateZeroedKernelMemory(SizeOf(TTcpConnection)));
  if Result = nil then
    Exit;
  Result^.State := TcpClosed;
  Result^.TimeToLive := 64;
  Result^.RetransmissionTimeout := InitialRetransmissionTimeout;
  Result^.MaximumSegment := DefaultPeerMss;
  Result^.KeepAliveIdleSeconds := DefaultKeepAliveIdleSeconds;
  Result^.KeepAliveIntervalSeconds := DefaultKeepAliveIntervalSeconds;
  Result^.KeepAliveCount := DefaultKeepAliveCount;
  InitializeListHead(Result^.AcceptQueue);
  InitializeListHead(Result^.AcceptLink);
  InitializeListHead(Result^.OutOfOrder);
  InsertAtTail(Connections, @Result^.Link);
end;

function BufferSize(Requested, Initial: LongWord): LongWord;
begin
  if Requested <> 0 then
    Result := Requested
  else
    Result := Initial;
end;

function CreateConnectionBuffers(Connection: PTcpConnection): Boolean;
begin
  Result := CreateByteRing(Connection^.SendBuffer,
      BufferSize(Connection^.RequestedSendBuffer, InitialSendBufferBytes)) and
    CreateByteRing(Connection^.ReceiveBuffer,
      BufferSize(Connection^.RequestedReceiveBuffer, InitialReceiveBufferBytes));
end;

procedure DiscardOutOfOrder(Connection: PTcpConnection);
var
  Entry: PListEntry;
begin
  Entry := RemoveHeadEntry(Connection^.OutOfOrder);
  while Entry <> nil do
  begin
    FreeKernelMemory(ContainingRecord(Entry, FieldOffset(POutOfOrderSegment(nil)^.Link)));
    Entry := RemoveHeadEntry(Connection^.OutOfOrder);
  end;
  Connection^.OutOfOrderCount := 0;
  Connection^.OutOfOrderBytes := 0;
  ClearReceivedBlocks(Connection^.ReceivedBlocks);
end;

procedure FreeTcpConnection(Connection: PTcpConnection);
begin
  RemoveListEntry(@Connection^.Link);
  if Connection^.Listener <> nil then
  begin
    { A child not yet accepted. }
    if not ListIsEmpty(Connection^.AcceptLink) then
    begin
      RemoveListEntry(@Connection^.AcceptLink);
      Dec(Connection^.Listener^.AcceptQueueCount);
    end;
    Dec(Connection^.Listener^.ChildCount);
    Connection^.Listener := nil;
  end;
  DiscardOutOfOrder(Connection);
  DestroyByteRing(Connection^.SendBuffer);
  DestroyByteRing(Connection^.ReceiveBuffer);
  FreeKernelMemory(Connection);
end;

function FirstTcpConnection: PTcpConnection;
begin
  if ListIsEmpty(Connections) then
    Exit(nil);
  Result := PTcpConnection(ContainingRecord(Connections.Next, FieldOffset(PTcpConnection(nil)^.Link)));
end;

function NextTcpConnection(Connection: PTcpConnection): PTcpConnection;
begin
  if Connection^.Link.Next = @Connections then
    Exit(nil);
  Result := PTcpConnection(ContainingRecord(Connection^.Link.Next, FieldOffset(PTcpConnection(nil)^.Link)));
end;

function FindTcpConnection(constref Local, Remote: TNetworkEndpoint): PTcpConnection;
begin
  Result := FirstTcpConnection;
  while Result <> nil do
  begin
    if not (Result^.State in [TcpClosed, TcpListen]) and EndpointsEqual(Result^.Local, Local) and
       EndpointsEqual(Result^.Remote, Remote) then
      Exit;
    Result := NextTcpConnection(Result);
  end;
end;

function FindTcpListener(constref Local: TNetworkEndpoint): PTcpConnection;
var
  Candidate: PTcpConnection;
begin
  Result := nil;
  Candidate := FirstTcpConnection;
  while Candidate <> nil do
  begin
    if (Candidate^.State = TcpListen) and (Candidate^.Local.Family = Local.Family) and
       (Candidate^.Local.Port = Local.Port) then
    begin
      if EndpointAddressesEqual(Candidate^.Local, Local) then
        Exit(Candidate);
      if EndpointIsUnspecified(Candidate^.Local) then
        Result := Candidate;
    end;
    Candidate := NextTcpConnection(Candidate);
  end;
end;

function GenerateInitialSequence: LongWord;
begin
  Result := LongWord(NetworkNow div 250) + SequenceOffset;
  { Not the same twice within one tick of the clock. }
  SequenceOffset := SequenceOffset + 64000;
end;

end.
