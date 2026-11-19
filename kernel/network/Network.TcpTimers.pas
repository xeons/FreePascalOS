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
  TCP's timers, run by the network thread: retransmission (and zero
  window probes), delayed acknowledgments, keep-alives, and the end of
  TIME_WAIT (and of FIN_WAIT_2 for a connection whose socket is gone). Each
  connection keeps its deadlines; this looks at every connection, acts
  on those due and asks to be woken for the next.
}
unit Network.TcpTimers;

{$mode objfpc}

interface

procedure RunTcpTimers(Now: QWord);

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.TcpTypes,
  Network.TcpConnections,
  Network.TcpStates,
  Network.TcpKeepAlive,
  Network.TcpOutput;

procedure RequestEarliest(Connection: PTcpConnection);
begin
  if Connection^.RetransmitDeadline <> 0 then
    RequestNetworkWakeAt(Connection^.RetransmitDeadline);
  if Connection^.AckDeadline <> 0 then
    RequestNetworkWakeAt(Connection^.AckDeadline);
  if Connection^.CloseDeadline <> 0 then
    RequestNetworkWakeAt(Connection^.CloseDeadline);
  if Connection^.KeepAliveDeadline <> 0 then
    RequestNetworkWakeAt(Connection^.KeepAliveDeadline);
end;

{ True if the connection was freed. }
function RunConnectionTimers(Connection: PTcpConnection; Now: QWord): Boolean;
begin
  Result := False;
  if (Connection^.CloseDeadline <> 0) and (Connection^.CloseDeadline <= Now) then
  begin
    Connection^.CloseDeadline := 0;
    if Connection^.State in [TcpTimeWait, TcpFinWait2] then
    begin
      Result := Connection^.Socket = nil;
      CloseTcpConnection(Connection, ErrorNone, False);
      Exit;
    end;
  end;
  if (Connection^.AckDeadline <> 0) and (Connection^.AckDeadline <= Now) then
  begin
    Connection^.AckDeadline := 0;
    if Connection^.AckPending and not (Connection^.State in [TcpClosed, TcpListen, TcpSynSent]) then
      SendAckNow(Connection);
  end;
  if (Connection^.RetransmitDeadline <> 0) and (Connection^.RetransmitDeadline <= Now) then
    if RetransmissionTimerExpired(Connection) then
      Exit(True);
  if (Connection^.KeepAliveDeadline <> 0) and (Connection^.KeepAliveDeadline <= Now) then
    if KeepAliveTimerExpired(Connection, Now) then
      Exit(True);
  if Connection^.State <> TcpClosed then
    RequestEarliest(Connection);
end;

procedure RunTcpTimers(Now: QWord);
var
  Connection: PTcpConnection;
  Next: PTcpConnection;
begin
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    Next := NextTcpConnection(Connection);
    RunConnectionTimers(Connection, Now);
    Connection := Next;
  end;
end;

end.
