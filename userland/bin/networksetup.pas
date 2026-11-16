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
  networksetup - configure the network at start

  networksetup

  The network service (/etc/services/network.service) runs it once
  while the system starts: it gives the interfaces the addresses, the
  default route and the DNS servers that /etc/settings/Network.settings
  names (NetworkSetup.StaticConfiguration). Root only; running it again
  applies the settings again. Exit status 0 if everything applied, 1
  otherwise.
}
program networksetup;

{$mode objfpc}
{$H+}

uses
  NetworkSetup.StaticConfiguration;

begin
  if ApplyStaticConfiguration > 0 then
    Halt(1);
end.
