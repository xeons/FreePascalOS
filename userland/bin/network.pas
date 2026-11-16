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
  network - the network service

  network

  Runs as root (/etc/services/network.service, in both boot modes) for
  as long as the system does: it gives the interfaces the configuration
  /etc/settings/Network.settings asks for - static addresses, or DHCP
  leases it obtains and renews itself - with the default routes, the
  DNS servers and the host name; it applies changes to that file as soon
  as they are written, follows links that come and go and adapters that
  appear, and writes each interface's state to
  /var/lib/network/NAME.state for other programs. Asked to end, it gives
  its leases back (DHCPRELEASE) and ends with status 0. Units in
  userland/network.
}
program network;

{$mode objfpc}
{$H+}

uses
  NetworkService.Supervisor;

begin
  RunNetworkService;
end.
