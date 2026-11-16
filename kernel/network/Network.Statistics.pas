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
  The protocols' counters (netstat -s): what IP, ICMP, TCP and UDP
  received, sent and threw away since the start, in the manner of the
  MIB-II groups. The protocols count under the network lock, where all
  their work is done; TakeNetworkStatistics copies them out under it.
}
unit Network.Statistics;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

var
  { Written only under the network lock. }
  NetworkStatistics: TAbiNetworkStatistics;

{ An ICMP message of IcmpType came in, or went out. }
procedure CountIcmpReceived(IcmpType: Byte);
procedure CountIcmpSent(IcmpType: Byte);
{ A copy of the counters, with the connections established now counted
  (under the lock). }
procedure TakeNetworkStatistics(out Statistics: TAbiNetworkStatistics);

implementation

uses
  Network.TcpTypes,
  Network.TcpConnections;

procedure CountIcmpReceived(IcmpType: Byte);
begin
  Inc(NetworkStatistics.Icmp.Received);
  if IcmpType < IcmpTypesCounted then
    Inc(NetworkStatistics.Icmp.ReceivedByType[IcmpType]);
end;

procedure CountIcmpSent(IcmpType: Byte);
begin
  Inc(NetworkStatistics.Icmp.Sent);
  if IcmpType < IcmpTypesCounted then
    Inc(NetworkStatistics.Icmp.SentByType[IcmpType]);
end;

function CountEstablishedConnections: QWord;
var
  Connection: PTcpConnection;
begin
  Result := 0;
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    if Connection^.State in [TcpEstablished, TcpCloseWait] then
      Inc(Result);
    Connection := NextTcpConnection(Connection);
  end;
end;

procedure TakeNetworkStatistics(out Statistics: TAbiNetworkStatistics);
begin
  Statistics := NetworkStatistics;
  Statistics.Tcp.CurrentlyEstablished := CountEstablishedConnections;
end;

end.
