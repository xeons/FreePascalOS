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
  TCP for sockets: listen, accept, connect, send, receive, shut down
  and close, under the network lock.

  Sending copies into the connection's send buffer (waiting for room
  unless the socket does not wait) and lets TcpOutput send what the
  windows allow. Receiving takes from the receive buffer, and tells the
  peer when reading opened the window by two segments or more. Closing
  the socket hands the connection over: with unread data it is reset
  (RFC 2525), otherwise it sends its FIN and finishes on its own; a
  listener resets the connections still waiting to be accepted.
}
unit Network.TcpSockets;

{$mode objfpc}

interface

uses
  Network.Addresses,
  Network.Sockets;

procedure DescribeTcpReadiness(Socket: PSocket; out IsReadable, IsWritable: Boolean);
{ The socket is being deleted. }
procedure CloseTcpSocket(Socket: PSocket);
function ListenOnTcpSocket(Socket: PSocket; Backlog: LongWord): LongInt;
function AcceptOnTcpSocket(Socket: PSocket; out NewSocket: PSocket): LongInt;
function ConnectTcpSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
function SendOnTcpSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord): Int64;
function ReceiveOnTcpSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord): Int64;
function ShutdownTcpSocket(Socket: PSocket; How: LongWord): LongInt;
{ Bytes waiting to be read. }
function TcpReadableBytes(Socket: PSocket): LongWord;
{ The peer of a connected socket; False if it has none. }
function TcpPeer(Socket: PSocket; out Peer: TNetworkEndpoint): Boolean;
{ The error the connection ended with (reported once); ErrorNone if
  none. }
function TakeTcpError(Socket: PSocket): LongInt;
{ Passes changed options (no delay, time to live) to the connection. }
procedure ApplyTcpOptions(Socket: PSocket);

implementation

uses
  Abi.SystemCalls,
  Runtime.LinkedList,
  Network.Core,
  Network.ByteRings,
  Network.Interfaces,
  Network.Ipv4,
  Network.Ports,
  Network.TcpTypes,
  Network.TcpConnections,
  Network.TcpSegments,
  Network.TcpStates,
  Network.TcpOutput;

function ConnectionOf(Socket: PSocket): PTcpConnection;
begin
  Result := PTcpConnection(Socket^.Connection);
end;

function Minimum(First, Second: LongWord): LongWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

procedure DescribeTcpReadiness(Socket: PSocket; out IsReadable, IsWritable: Boolean);
var
  Connection: PTcpConnection;
  HasError: Boolean;
begin
  Connection := ConnectionOf(Socket);
  HasError := Socket^.PendingError <> ErrorNone;
  if Connection = nil then
  begin
    IsReadable := HasError or Socket^.ReceiveIsShut;
    IsWritable := HasError;
    Exit;
  end;
  if Connection^.State = TcpListen then
  begin
    IsReadable := (Connection^.AcceptQueueCount > 0) or HasError;
    IsWritable := False;
    Exit;
  end;
  HasError := HasError or (Connection^.Error <> ErrorNone);
  IsReadable := (Connection^.ReceiveBuffer.Count > 0) or Connection^.FinReceived or
    (Connection^.State = TcpClosed) or HasError or Socket^.ReceiveIsShut;
  IsWritable := (StateCanSend(Connection^.State) and not Socket^.SendIsShut and
    (ByteRingFreeSpace(Connection^.SendBuffer) > 0)) or (Connection^.State = TcpClosed) or HasError;
end;

{ The error the connection ended with, reported once. }
function TakeConnectionError(Socket: PSocket; Connection: PTcpConnection): LongInt;
begin
  Result := Connection^.Error;
  Connection^.Error := ErrorNone;
  if Result = ErrorNone then
    Result := Socket^.PendingError;
  Socket^.PendingError := ErrorNone;
  UpdateSocketReadiness(Socket);
end;

{ Where the data in the send buffer starts in sequence space. }
function DataStart(Connection: PTcpConnection): LongWord;
begin
  if Connection^.State in [TcpSynSent, TcpSynReceived] then
    Result := Connection^.InitialSendSequence + 1
  else
    Result := Connection^.SendUnacknowledged;
end;

procedure QueueFin(Connection: PTcpConnection);
begin
  if Connection^.FinQueued then
    Exit;
  Connection^.FinQueued := True;
  Connection^.FinSequence := DataStart(Connection) + Connection^.SendBuffer.Count;
end;

{ Resets every child of a listener that is going away. }
procedure ResetChildren(Listener: PTcpConnection);
var
  Connection: PTcpConnection;
  Next: PTcpConnection;
begin
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    Next := NextTcpConnection(Connection);
    if (Connection^.Listener = Listener) and (Connection^.Socket = nil) then
      CloseTcpConnection(Connection, ErrorNone, True);
    Connection := Next;
  end;
end;

procedure CloseTcpSocket(Socket: PSocket);
var
  Connection: PTcpConnection;
begin
  Connection := ConnectionOf(Socket);
  if Connection = nil then
    Exit;
  Connection^.Socket := nil;
  Socket^.Connection := nil;
  case Connection^.State of
    TcpListen:
      begin
        ResetChildren(Connection);
        FreeTcpConnection(Connection);
      end;
    TcpClosed, TcpSynSent:
      CloseTcpConnection(Connection, ErrorNone, False);
    TcpSynReceived, TcpEstablished, TcpCloseWait:
      if Connection^.ReceiveBuffer.Count > 0 then
        CloseTcpConnection(Connection, ErrorNone, True)
      else
      begin
        QueueFin(Connection);
        if Connection^.State = TcpCloseWait then
          EnterTcpState(Connection, TcpLastAck)
        else
          EnterTcpState(Connection, TcpFinWait1);
        TcpOutput(Connection);
      end;
    TcpFinWait2:
      begin
        Connection^.CloseDeadline := NetworkNow + OrphanFinWaitNanoseconds;
        RequestNetworkWakeAt(Connection^.CloseDeadline);
      end;
  end;
end;

{ A socket that listens or connects without having bound gets a port. }
function BindImplicitly(Socket: PSocket): LongInt;
var
  Port: Word;
begin
  if Socket^.IsBound then
    Exit(ErrorNone);
  Port := ChooseDynamicPort(Socket, Socket^.Local.Address);
  if Port = 0 then
    Exit(ErrorAddressInUse);
  Socket^.Local.Port := Port;
  Socket^.IsBound := True;
  Result := ErrorNone;
end;

function ListenOnTcpSocket(Socket: PSocket; Backlog: LongWord): LongInt;
var
  Connection: PTcpConnection;
begin
  if (Backlog = 0) or (Backlog > MaximumListenBacklog) then
    Backlog := MaximumListenBacklog;
  Connection := ConnectionOf(Socket);
  if Connection <> nil then
  begin
    if Connection^.State <> TcpListen then
      Exit(ErrorInvalidArgument);
    Connection^.Backlog := Backlog;
    Exit(ErrorNone);
  end;
  Result := BindImplicitly(Socket);
  if Result <> ErrorNone then
    Exit;
  Connection := CreateTcpConnection;
  if Connection = nil then
    Exit(ErrorOutOfMemory);
  Connection^.Local := Socket^.Local;
  Connection^.BoundInterface := Socket^.BoundInterface;
  Connection^.TimeToLive := Socket^.TimeToLive;
  Connection^.NoDelay := Socket^.NoDelay;
  Connection^.Backlog := Backlog;
  Connection^.State := TcpListen;
  Connection^.Socket := Socket;
  Socket^.Connection := Connection;
  UpdateSocketReadiness(Socket);
end;

{ Gives the first connection waiting on Listener a socket of its own. }
function TakeAcceptedConnection(Socket: PSocket; Listener: PTcpConnection; out NewSocket: PSocket): LongInt;
var
  Child: PTcpConnection;
begin
  Child := PTcpConnection(ContainingRecord(Listener^.AcceptQueue.Next, FieldOffset(PTcpConnection(nil)^.AcceptLink)));
  NewSocket := AllocateSocket(Socket^.Kind, SocketProtocolTcp, Socket^.OwnerUserId);
  if NewSocket = nil then
    Exit(ErrorOutOfMemory);
  RemoveListEntry(@Child^.AcceptLink);
  Dec(Listener^.AcceptQueueCount);
  Dec(Listener^.ChildCount);
  Child^.Listener := nil;
  NewSocket^.IsBound := True;
  NewSocket^.Local := Child^.Local;
  NewSocket^.IsConnected := True;
  NewSocket^.Peer := Child^.Remote;
  NewSocket^.TimeToLive := Socket^.TimeToLive;
  NewSocket^.NoDelay := Socket^.NoDelay;
  NewSocket^.BoundInterface := Socket^.BoundInterface;
  NewSocket^.Connection := Child;
  Child^.Socket := NewSocket;
  UpdateSocketReadiness(NewSocket);
  UpdateSocketReadiness(Socket);
  Result := ErrorNone;
end;

function AcceptOnTcpSocket(Socket: PSocket; out NewSocket: PSocket): LongInt;
var
  Listener: PTcpConnection;
  Deadline: QWord;
begin
  NewSocket := nil;
  Listener := ConnectionOf(Socket);
  if (Listener = nil) or (Listener^.State <> TcpListen) then
    Exit(ErrorInvalidArgument);
  Deadline := SocketWaitDeadline(Socket^.ReceiveTimeout);
  repeat
    { The socket may have been closed by another thread meanwhile. }
    if Socket^.Connection <> Listener then
      Exit(ErrorBadHandle);
    if Listener^.AcceptQueueCount > 0 then
      Exit(TakeAcceptedConnection(Socket, Listener, NewSocket));
    Result := TakePendingError(Socket);
    if Result <> ErrorNone then
      Exit;
    if Socket^.NonBlocking then
      Exit(ErrorWouldBlock);
    Result := WaitOnSocket(@Socket^.Readable, Deadline);
  until Result <> ErrorNone;
end;

function ConnectTcpSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
var
  Connection: PTcpConnection;
  Remote: TNetworkEndpoint;
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
  Source: TIpv4Address;
  Deadline: QWord;
begin
  Connection := ConnectionOf(Socket);
  if Connection <> nil then
  begin
    case Connection^.State of
      TcpSynSent, TcpSynReceived: Exit(ErrorAlreadyInProgress);
      TcpListen: Exit(ErrorInvalidArgument);
      TcpClosed:
        begin
          { An attempt that failed: a new one may be made. }
          Connection^.Socket := nil;
          Socket^.Connection := nil;
          FreeTcpConnection(Connection);
        end;
    else
      Exit(ErrorAlreadyConnected);
    end;
  end;
  Remote := Destination;
  if Remote.Address = AnyAddress then
    Remote.Address := LoopbackAddress;
  if Remote.Port = 0 then
    Exit(ErrorConnectionRefused);
  Result := RouteDatagram(Remote.Address, Socket^.BoundInterface, NetworkInterface, NextHop, Source);
  if Result <> ErrorNone then
    Exit;
  if Socket^.Local.Address = AnyAddress then
    Socket^.Local.Address := Source;
  Result := BindImplicitly(Socket);
  if Result <> ErrorNone then
    Exit;
  if FindTcpConnection(Socket^.Local.Address, Socket^.Local.Port, Remote.Address, Remote.Port) <> nil then
    Exit(ErrorAddressInUse);

  Connection := CreateTcpConnection;
  if Connection = nil then
    Exit(ErrorOutOfMemory);
  if not CreateConnectionBuffers(Connection) then
  begin
    FreeTcpConnection(Connection);
    Exit(ErrorOutOfMemory);
  end;
  Connection^.Local := Socket^.Local;
  Connection^.Remote := Remote;
  Connection^.BoundInterface := Socket^.BoundInterface;
  Connection^.TimeToLive := Socket^.TimeToLive;
  Connection^.NoDelay := Socket^.NoDelay;
  Connection^.MaximumSegment := OwnMaximumSegment(Remote.Address, Socket^.BoundInterface);
  Connection^.InitialSendSequence := GenerateInitialSequence;
  Connection^.SendUnacknowledged := Connection^.InitialSendSequence;
  Connection^.SendNext := Connection^.InitialSendSequence;
  Connection^.SendMaximum := Connection^.InitialSendSequence;
  Connection^.State := TcpSynSent;
  Connection^.Socket := Socket;
  Socket^.Connection := Connection;
  Socket^.Peer := Remote;
  TcpOutput(Connection);
  UpdateSocketReadiness(Socket);

  if Socket^.NonBlocking then
    Exit(ErrorInProgress);
  Deadline := SocketWaitDeadline(Socket^.SendTimeout);
  while Connection^.State in [TcpSynSent, TcpSynReceived] do
  begin
    Result := WaitOnSocket(@Socket^.Writable, Deadline);
    if Socket^.Connection <> Connection then
      Exit(ErrorBadHandle);
    if Result = ErrorWouldBlock then
      Exit(ErrorInProgress);
    if Result <> ErrorNone then
      Exit;
  end;
  if Connection^.State = TcpClosed then
  begin
    Result := TakeConnectionError(Socket, Connection);
    if Result = ErrorNone then
      Result := ErrorConnectionRefused;
    Exit;
  end;
  Socket^.IsConnected := True;
  Result := ErrorNone;
end;

{ Why a connection cannot take data now; ErrorNone if it can. }
function SendRefusal(Socket: PSocket; Connection: PTcpConnection): LongInt;
begin
  if Connection^.State = TcpClosed then
  begin
    Result := TakeConnectionError(Socket, Connection);
    if Result = ErrorNone then
      Result := ErrorBrokenPipe;
    Exit;
  end;
  if Socket^.SendIsShut or Connection^.FinQueued then
    Exit(ErrorBrokenPipe);
  Result := ErrorNone;
end;

function SendOnTcpSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord): Int64;
var
  Connection: PTcpConnection;
  Total: LongWord;
  Written: LongWord;
  Error: LongInt;
  Deadline: QWord;
  MayWait: Boolean;
begin
  Connection := ConnectionOf(Socket);
  if (Connection = nil) or (Connection^.State = TcpListen) then
    Exit(-ErrorNotConnected);
  MayWait := not Socket^.NonBlocking and ((Flags and SocketFlagDontWait) = 0);
  Deadline := SocketWaitDeadline(Socket^.SendTimeout);
  Total := 0;
  while Total < Length do
  begin
    if Socket^.Connection <> Connection then
      Break;
    Error := SendRefusal(Socket, Connection);
    if Error <> ErrorNone then
    begin
      if Total > 0 then
        Break;
      Exit(-Error);
    end;
    if StateCanSend(Connection^.State) and (ByteRingFreeSpace(Connection^.SendBuffer) > 0) then
    begin
      Written := AppendToByteRing(Connection^.SendBuffer, Data + Total, Length - Total);
      Total := Total + Written;
      TcpOutput(Connection);
      UpdateSocketReadiness(Socket);
      Continue;
    end;
    { No room yet, or still connecting. }
    if not MayWait then
    begin
      if Total > 0 then
        Break;
      Exit(-ErrorWouldBlock);
    end;
    Error := WaitOnSocket(@Socket^.Writable, Deadline);
    if Error <> ErrorNone then
    begin
      if Total > 0 then
        Break;
      Exit(-Error);
    end;
  end;
  Result := Total;
end;

{ After reading: tells the peer when its window opened noticeably. }
procedure UpdateWindowAfterRead(Connection: PTcpConnection);
var
  NewEdge: LongWord;
begin
  if not StateCanReceive(Connection^.State) then
    Exit;
  NewEdge := Connection^.ReceiveNext + ReceiveWindow(Connection);
  if SequenceAfterOrEqual(NewEdge, Connection^.AdvertisedEdge + 2 * Connection^.MaximumSegment) or
     ((Connection^.AdvertisedEdge = Connection^.ReceiveNext) and SequenceAfter(NewEdge, Connection^.AdvertisedEdge)) then
    SendAckNow(Connection);
end;

function ReceiveOnTcpSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord): Int64;
var
  Connection: PTcpConnection;
  Count: LongWord;
  Error: LongInt;
  Deadline: QWord;
begin
  Connection := ConnectionOf(Socket);
  if (Connection = nil) or (Connection^.State = TcpListen) then
    Exit(-ErrorNotConnected);
  Deadline := SocketWaitDeadline(Socket^.ReceiveTimeout);
  repeat
    if Socket^.Connection <> Connection then
      Exit(-ErrorBadHandle);
    if Connection^.ReceiveBuffer.Count > 0 then
    begin
      Count := Minimum(Length, Connection^.ReceiveBuffer.Count);
      CopyFromByteRing(Connection^.ReceiveBuffer, 0, Data, Count);
      if (Flags and SocketFlagPeek) = 0 then
      begin
        DiscardFromByteRing(Connection^.ReceiveBuffer, Count);
        UpdateWindowAfterRead(Connection);
      end;
      UpdateSocketReadiness(Socket);
      Exit(Count);
    end;
    if (Connection^.Error <> ErrorNone) or (Socket^.PendingError <> ErrorNone) then
      Exit(-TakeConnectionError(Socket, Connection));
    if Connection^.FinReceived or Socket^.ReceiveIsShut or (Connection^.State = TcpClosed) then
      Exit(0);
    if Socket^.NonBlocking or ((Flags and SocketFlagDontWait) <> 0) then
      Exit(-ErrorWouldBlock);
    Error := WaitOnSocket(@Socket^.Readable, Deadline);
  until Error <> ErrorNone;
  Result := -Error;
end;

function ShutdownTcpSocket(Socket: PSocket; How: LongWord): LongInt;
var
  Connection: PTcpConnection;
begin
  Connection := ConnectionOf(Socket);
  if (Connection = nil) or (Connection^.State in [TcpListen, TcpSynSent, TcpClosed]) then
    Exit(ErrorNotConnected);
  if (How and SocketShutdownReceive) <> 0 then
    Socket^.ReceiveIsShut := True;
  if ((How and SocketShutdownSend) <> 0) and not Socket^.SendIsShut then
  begin
    Socket^.SendIsShut := True;
    if StateCanSend(Connection^.State) or (Connection^.State = TcpSynReceived) then
    begin
      QueueFin(Connection);
      if Connection^.State = TcpCloseWait then
        EnterTcpState(Connection, TcpLastAck)
      else
        EnterTcpState(Connection, TcpFinWait1);
      TcpOutput(Connection);
    end;
  end;
  UpdateSocketReadiness(Socket);
  Result := ErrorNone;
end;

function TcpReadableBytes(Socket: PSocket): LongWord;
var
  Connection: PTcpConnection;
begin
  Connection := ConnectionOf(Socket);
  if (Connection = nil) or (Connection^.State = TcpListen) then
    Exit(0);
  Result := Connection^.ReceiveBuffer.Count;
end;

function TcpPeer(Socket: PSocket; out Peer: TNetworkEndpoint): Boolean;
var
  Connection: PTcpConnection;
begin
  Peer := MakeEndpoint(AnyAddress, 0);
  Connection := ConnectionOf(Socket);
  Result := (Connection <> nil) and Connection^.WasEstablished;
  if Result then
    Peer := Connection^.Remote;
end;

function TakeTcpError(Socket: PSocket): LongInt;
var
  Connection: PTcpConnection;
begin
  Connection := ConnectionOf(Socket);
  if (Connection = nil) or (Connection^.Error = ErrorNone) then
    Exit(ErrorNone);
  Result := TakeConnectionError(Socket, Connection);
end;

procedure ApplyTcpOptions(Socket: PSocket);
var
  Connection: PTcpConnection;
begin
  Connection := ConnectionOf(Socket);
  if Connection = nil then
    Exit;
  Connection^.NoDelay := Socket^.NoDelay;
  Connection^.TimeToLive := Socket^.TimeToLive;
  if Connection^.NoDelay then
    TcpOutput(Connection);
end;

end.
