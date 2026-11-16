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
  address and port it shows goes through FormatEndpoint, so names come
  in one place: without -n a host is shown by its name and a port by
  its service's. There is no reverse lookup and no services list yet,
  so only the loopback address has a name ("localhost"); the rest stay
  numbers until those come.
}
unit Netstat.Names;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  { "localhost:65535", or an address with its port. }
  EndpointTextCapacity = 48;

{ Address and port as netstat shows them; port 0 is "*". }
function FormatEndpoint(constref Address: TAbiSocketAddress; Numeric: Boolean; Buffer: PChar;
  Capacity: PtrUInt): PChar;

implementation

uses
  Runtime.Text,
  Sys.Text,
  Sys.InternetAddresses;

{ The host's name, or its address as a number. }
procedure AppendHost(var Builder: TTextBuilder; constref Address: TAbiSocketAddress; Numeric: Boolean);
var
  Host: TInternetAddress;
  Text: array[0..Ipv4AddressTextCapacity - 1] of Char;
begin
  Host := SocketAddressHost(Address);
  if not Numeric and AddressesAreEqual(Host, LoopbackIpv4Address) then
  begin
    AppendText(Builder, 'localhost');
    Exit;
  end;
  AppendText(Builder, FormatInternetAddress(Host, @Text[0], SizeOf(Text)));
end;

{ The port's service name would go here; numbers for now. }
procedure AppendPort(var Builder: TTextBuilder; Port: Word);
begin
  if Port = 0 then
    AppendCharacter(Builder, '*')
  else
    AppendDecimal(Builder, Port);
end;

function FormatEndpoint(constref Address: TAbiSocketAddress; Numeric: Boolean; Buffer: PChar;
  Capacity: PtrUInt): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  AppendHost(Builder, Address, Numeric);
  AppendCharacter(Builder, ':');
  AppendPort(Builder, Address.Port);
  CopyText(Buffer, Builder.Text, Capacity);
  DiscardText(Builder);
  Result := Buffer;
end;

end.
