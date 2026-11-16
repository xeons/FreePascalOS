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
  TCP: changes of state that concern more than the connection itself -
  its socket (whose readiness follows the connection), its listener (a
  child that becomes established goes on the accept queue), and the end
  of a connection (freed at once if nobody holds it, else kept closed
  for its socket to find, with the reason it failed).
}
unit Network.TcpStates;

{$mode objfpc}

interface

uses
  Network.TcpTypes;

{ The socket of the connection (and, for a child, its listener's) looks
  at its state again. }
procedure NotifyConnectionSocket(Connection: PTcpConnection);
procedure EnterTcpState(Connection: PTcpConnection; State: TTcpState);
{ A child completed the handshake: it waits on its listener's accept
  queue. }
procedure QueueForAccept(Connection: PTcpConnection);
{ Ends the connection: closed, its timers off, Error (ErrorNone for a
  normal end) left for its socket; freed if it has no socket. Sends a
  reset first if SendReset. The connection may be gone afterwards. }
procedure CloseTcpConnection(Connection: PTcpConnection; Error: LongInt; SendReset: Boolean);
{ TIME_WAIT: closed after twice the maximum segment lifetime. }
procedure EnterTimeWait(Connection: PTcpConnection);

implementation

uses
  Runtime.LinkedList,
  Abi.SystemCalls,
  Network.Core,
  Network.Sockets,
  Network.TcpConnections,
  Network.TcpSegments;

procedure NotifyConnectionSocket(Connection: PTcpConnection);
begin
  if Connection^.Socket <> nil then
    UpdateSocketReadiness(PSocket(Connection^.Socket));
  if (Connection^.Listener <> nil) and (Connection^.Listener^.Socket <> nil) then
    UpdateSocketReadiness(PSocket(Connection^.Listener^.Socket));
end;

procedure EnterTcpState(Connection: PTcpConnection; State: TTcpState);
begin
  Connection^.State := State;
  if State = TcpEstablished then
    Connection^.WasEstablished := True;
  NotifyConnectionSocket(Connection);
end;

procedure QueueForAccept(Connection: PTcpConnection);
var
  Listener: PTcpConnection;
begin
  Listener := Connection^.Listener;
  if (Listener = nil) or not ListIsEmpty(Connection^.AcceptLink) then
    Exit;
  InsertAtTail(Listener^.AcceptQueue, @Connection^.AcceptLink);
  Inc(Listener^.AcceptQueueCount);
  NotifyConnectionSocket(Connection);
end;

procedure CloseTcpConnection(Connection: PTcpConnection; Error: LongInt; SendReset: Boolean);
var
  Listener: PTcpConnection;
begin
  if SendReset and not (Connection^.State in [TcpClosed, TcpListen, TcpSynSent, TcpTimeWait]) then
    SendConnectionSegment(Connection, Connection^.SendNext, TcpFlagReset, 0, 0);
  Connection^.State := TcpClosed;
  Connection^.RetransmitDeadline := 0;
  Connection^.AckDeadline := 0;
  Connection^.AckPending := False;
  Connection^.CloseDeadline := 0;
  if Error <> ErrorNone then
  begin
    Connection^.Error := Error;
    if Connection^.Socket <> nil then
      PSocket(Connection^.Socket)^.PendingError := Error;
  end;
  if Connection^.Socket = nil then
  begin
    { No socket: nobody will look at it again (a child not yet
      accepted, or one whose socket closed). }
    Listener := Connection^.Listener;
    FreeTcpConnection(Connection);
    if (Listener <> nil) and (Listener^.Socket <> nil) then
      UpdateSocketReadiness(PSocket(Listener^.Socket));
    Exit;
  end;
  NotifyConnectionSocket(Connection);
end;

procedure EnterTimeWait(Connection: PTcpConnection);
begin
  Connection^.State := TcpTimeWait;
  Connection^.RetransmitDeadline := 0;
  Connection^.CloseDeadline := NetworkNow + TimeWaitNanoseconds;
  RequestNetworkWakeAt(Connection^.CloseDeadline);
  NotifyConnectionSocket(Connection);
end;

end.
