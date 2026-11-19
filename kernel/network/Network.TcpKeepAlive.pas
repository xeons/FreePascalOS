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
  TCP keep-alives (RFC 1122 4.2.3.6), for sockets that ask for them
  (SocketOptionKeepAlive).

  A connection established (or in CLOSE_WAIT) that has heard nothing
  from its peer for the idle time (SocketOptionKeepIdle, two hours at
  first) sends a probe: an ACK with the sequence number before the next
  one, which the peer must answer with an ACK. Unanswered, a probe goes
  again after each interval (SocketOptionKeepInterval, 75 s), and after
  the count of them (SocketOptionKeepCount, 9) the connection is reset
  and its socket gets ErrorTimedOut. Anything that arrives from the peer
  counts as an answer (Network.TcpInput keeps LastReceived). While data
  waits to be sent or acknowledged the retransmission timer watches the
  peer instead.

  The timer is lazy: each connection keeps one deadline, and when it
  passes the connection looks at when it last heard from the peer
  before deciding to probe.
}
unit Network.TcpKeepAlive;

{$mode objfpc}

interface

uses
  Network.TcpTypes;

{ Sets the keep-alive deadline from now (or clears it if keep-alives
  are off or the state has none). }
procedure ArmKeepAlive(Connection: PTcpConnection);
{ The keep-alive deadline passed. True if the connection gave up and
  was freed (it had no socket). }
function KeepAliveTimerExpired(Connection: PTcpConnection; Now: QWord): Boolean;

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.TcpSegments,
  Network.TcpStates;

function KeepAliveApplies(Connection: PTcpConnection): Boolean;
begin
  Result := Connection^.KeepAlive and (Connection^.State in [TcpEstablished, TcpCloseWait]);
end;

function SecondsFrom(Start: QWord; Seconds: LongWord): QWord;
begin
  Result := Start + QWord(Seconds) * NanosecondsPerSecond;
end;

procedure SetDeadline(Connection: PTcpConnection; Deadline: QWord);
begin
  Connection^.KeepAliveDeadline := Deadline;
  RequestNetworkWakeAt(Deadline);
end;

procedure ArmKeepAlive(Connection: PTcpConnection);
begin
  Connection^.KeepAliveProbes := 0;
  if not KeepAliveApplies(Connection) then
  begin
    Connection^.KeepAliveDeadline := 0;
    Exit;
  end;
  if Connection^.LastReceived = 0 then
    Connection^.LastReceived := NetworkNow;
  SetDeadline(Connection, SecondsFrom(Connection^.LastReceived, Connection^.KeepAliveIdleSeconds));
end;

function KeepAliveTimerExpired(Connection: PTcpConnection; Now: QWord): Boolean;
var
  IdleEnd: QWord;
begin
  Result := False;
  Connection^.KeepAliveDeadline := 0;
  if not KeepAliveApplies(Connection) then
    Exit;
  { Data waiting: the retransmission or zero window timer is in charge. }
  if (Connection^.SendNext <> Connection^.SendUnacknowledged) or (Connection^.SendBuffer.Count > 0) then
  begin
    Connection^.KeepAliveProbes := 0;
    SetDeadline(Connection, SecondsFrom(Now, Connection^.KeepAliveIdleSeconds));
    Exit;
  end;
  if Connection^.KeepAliveProbes = 0 then
  begin
    IdleEnd := SecondsFrom(Connection^.LastReceived, Connection^.KeepAliveIdleSeconds);
    if Now < IdleEnd then
    begin
      SetDeadline(Connection, IdleEnd);
      Exit;
    end;
  end;
  if Connection^.KeepAliveProbes >= Connection^.KeepAliveCount then
  begin
    Result := Connection^.Socket = nil;
    CloseTcpConnection(Connection, ErrorTimedOut, True);
    Exit;
  end;
  { The byte before the next: the peer answers with an ACK. }
  SendConnectionSegment(Connection, Connection^.SendNext - 1, 0, 0, 0);
  Inc(Connection^.KeepAliveProbes);
  SetDeadline(Connection, SecondsFrom(Now, Connection^.KeepAliveIntervalSeconds));
end;

end.
