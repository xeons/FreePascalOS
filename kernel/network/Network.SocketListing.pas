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
  The list of sockets and connections a netstat shows: every socket,
  then every TCP connection that has no socket (closing after its
  socket went, or connected and waiting to be accepted). Under the
  network lock.
}
unit Network.SocketListing;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

{ Fills up to Capacity records; returns how many entries there are. }
function ListSockets(Records: PAbiSocketInformation; Capacity: LongWord): LongWord;

implementation

uses
  Runtime.Memory,
  Network.Addresses,
  Network.Sockets,
  Network.TcpTypes,
  Network.TcpConnections;

procedure DescribeConnection(Connection: PTcpConnection; out Description: TAbiSocketInformation);
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Description.Family := AddressFamilyIPv4;
  Description.Kind := SocketKindStream;
  Description.Protocol := ProtocolTcp;
  Description.State := AbiTcpState(Connection^.State);
  EndpointToAbi(Connection^.Local, Description.LocalAddress);
  EndpointToAbi(Connection^.Remote, Description.PeerAddress);
  Description.ReceiveQueued := Connection^.ReceiveBuffer.Count;
  Description.SendQueued := Connection^.SendBuffer.Count;
end;

procedure DescribeSocket(Socket: PSocket; out Description: TAbiSocketInformation);
var
  Connection: PTcpConnection;
begin
  Connection := PTcpConnection(Socket^.Connection);
  if (Socket^.Protocol = SocketProtocolTcp) and (Connection <> nil) then
  begin
    DescribeConnection(Connection, Description);
    if Connection^.State = TcpListen then
      Description.PeerAddress.Family := AddressFamilyIPv4;
  end
  else
  begin
    FillMemory(@Description, SizeOf(Description), 0);
    Description.Family := AddressFamilyIPv4;
    Description.Kind := Socket^.Kind;
    case Socket^.Protocol of
      SocketProtocolTcp:
        begin
          Description.Protocol := ProtocolTcp;
          Description.State := TcpStateClosed;
        end;
      SocketProtocolUdp: Description.Protocol := ProtocolUdp;
    else
      Description.Protocol := ProtocolIcmp;
    end;
    EndpointToAbi(Socket^.Local, Description.LocalAddress);
    EndpointToAbi(Socket^.Peer, Description.PeerAddress);
    Description.ReceiveQueued := Socket^.Datagrams.Bytes;
  end;
  Description.OwnerUserId := Socket^.Owner.UserId;
  Description.OwnerProcessId := Socket^.Owner.ProcessId;
end;

function ListSockets(Records: PAbiSocketInformation; Capacity: LongWord): LongWord;
var
  Socket: PSocket;
  Connection: PTcpConnection;
begin
  Result := 0;
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if Result < Capacity then
      DescribeSocket(Socket, Records[Result]);
    Inc(Result);
    Socket := NextSocket(Socket);
  end;
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    if Connection^.Socket = nil then
    begin
      if Result < Capacity then
        DescribeConnection(Connection, Records[Result]);
      Inc(Result);
    end;
    Connection := NextTcpConnection(Connection);
  end;
end;

end.
