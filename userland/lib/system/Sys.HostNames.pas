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
  Turning a host as the user writes it into an address: the one place
  programs (ping, ...) ask, so that the DNS resolver, when it comes,
  makes every program take names at once. For now a host must be a
  numeric address, or "localhost".
}
unit Sys.HostNames;

{$mode objfpc}

interface

uses
  Sys.InternetAddresses;

{ ErrorNone with the address of Host, or ErrorNotFound (the name is not
  known). }
function LookUpHost(Host: PChar; out Address: TInternetAddress): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Text;

function LookUpHost(Host: PChar; out Address: TInternetAddress): LongInt;
begin
  if ParseIpv4Address(Host, Address) then
    Exit(ErrorNone);
  if (Host <> nil) and (CompareTextIgnoringCase(Host, 'localhost') = 0) then
  begin
    Address := LoopbackIpv4Address;
    Exit(ErrorNone);
  end;
  { The DNS resolver (Network.Dns keeps its servers) goes here. }
  Address := AnyIpv4Address;
  Result := ErrorNotFound;
end;

end.
