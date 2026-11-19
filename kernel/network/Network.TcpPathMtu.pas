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
  Path MTU discovery for TCP (RFC 8201 5.2): when the path MTU to a
  destination becomes smaller, the connections to it send segments that
  fit, from the next one on (what was lost is sent again by the
  retransmission timer, and in the new size). Under the network lock.
}
unit Network.TcpPathMtu;

{$mode objfpc}

interface

uses
  Network.Ipv6Addresses;

{ The path MTU to Destination became smaller: its connections' maximum
  segment size follows. }
procedure TcpPathMtuDecreased(constref Destination: TIpv6Address);

implementation

uses
  Abi.SystemCalls,
  Network.TcpTypes,
  Network.TcpConnections,
  Network.TcpSegments;

procedure TcpPathMtuDecreased(constref Destination: TIpv6Address);
var
  Connection: PTcpConnection;
  Limit: LongWord;
begin
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    if (Connection^.Remote.Family = AddressFamilyIPv6) and
       Ipv6AddressesEqual(Connection^.Remote.Address6, Destination) then
    begin
      Limit := OwnMaximumSegment(Connection^.Remote, Connection^.BoundInterface);
      if Limit < Connection^.MaximumSegment then
        Connection^.MaximumSegment := Limit;
    end;
    Connection := NextTcpConnection(Connection);
  end;
end;

end.
