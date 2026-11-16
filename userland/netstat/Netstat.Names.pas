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
  How netstat writes an endpoint: "10.0.2.15:22", "0.0.0.0:*". Every
  address and port it shows goes through EndpointText, so names come
  in one place: without -n a host is shown by its name and a port by
  its service's. There is no reverse lookup and no services list yet,
  so only the loopback address has a name ("localhost"); the rest stay
  numbers until those come.
}
unit Netstat.Names;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls;

{ Address and port as netstat shows them; port 0 is "*". }
function EndpointText(constref Address: TAbiSocketAddress; Numeric: Boolean): string;

implementation

uses
  SysUtils,
  Sys.InternetAddresses,
  Sys.AddressText;

{ The host's name, or its address as a number. }
function HostText(constref Address: TAbiSocketAddress; Numeric: Boolean): string;
var
  Host: TInternetAddress;
begin
  Host := SocketAddressHost(Address);
  if not Numeric and AddressIsLoopback(Host) then
    Result := 'localhost'
  else
    Result := AddressToText(Host);
end;

{ The port's service name would go here; numbers for now. }
function PortText(Port: Word): string;
begin
  if Port = 0 then
    Result := '*'
  else
    Result := IntToStr(Port);
end;

function EndpointText(constref Address: TAbiSocketAddress; Numeric: Boolean): string;
begin
  Result := HostText(Address, Numeric) + ':' + PortText(Address.Port);
end;

end.
