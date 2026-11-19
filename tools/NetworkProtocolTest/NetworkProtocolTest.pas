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
  NetworkProtocolTest - checks the network's message code on the host
  (make network-protocol-test): the resolver's EDNS(0) and cache of
  answers, the DHCP client's option overload and choice of offers.
}
program NetworkProtocolTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  NetworkProtocolTest.Dns,
  NetworkProtocolTest.Dhcp;

begin
  RunDnsChecks;
  RunDhcpChecks;
  FinishChecks('network protocol test');
end.
