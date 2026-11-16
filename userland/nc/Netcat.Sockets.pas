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
  What nc's client and listener share: looking up the host, making a
  socket of the kind -u says, and writing addresses.
}
unit Netcat.Sockets;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Sys.InternetAddresses;

{ The address of Host (numeric only with -n); ends nc if there is none. }
function ResolveHost(Host: PChar): TInternetAddress;
{ A TCP or UDP socket (-u), bound to -p's port if one was given (with
  Address as the local address); ends nc on failure. }
function OpenSocket(constref LocalAddress: TInternetAddress; LocalPort: Word): Int64;
{ "tcp" or "udp". }
function TransportName: PChar;
{ The address part of Address as text, into Buffer
  (Ipv4AddressTextCapacity). }
function HostText(constref Address: TAbiSocketAddress; Buffer: PChar): PChar;

implementation

uses
  Sys.Errors,
  Sys.Format,
  Sys.HostNames,
  Sys.Sockets,
  Util.Messages,
  Netcat.Settings;

function ResolveHost(Host: PChar): TInternetAddress;
var
  Error: LongInt;
begin
  if Settings.NumericOnly then
  begin
    if not ParseIpv4Address(Host, Result) then
      Fail(1, '%s: not a numeric address (-n)', [ArgumentText(Host)]);
    Exit;
  end;
  Error := LookUpHost(Host, Result);
  if Error = ErrorNotFound then
    Fail(1, '%s: Name or service not known', [ArgumentText(Host)]);
  if Error <> ErrorNone then
    FailWithError(1, Error, '%s', [ArgumentText(Host)]);
end;

function OpenSocket(constref LocalAddress: TInternetAddress; LocalPort: Word): Int64;
var
  Kind: LongWord;
  Error: LongInt;
begin
  if Settings.Datagrams then
    Kind := SocketKindDatagram
  else
    Kind := SocketKindStream;
  Result := CreateSocket(AddressFamilyIPv4, Kind, ProtocolDefault);
  if Result < 0 then
    FailWithError(1, ErrorCodeOf(Result), 'cannot make a socket', []);
  if (LocalPort = 0) and AddressIsUnspecified(LocalAddress) then
    Exit;
  SetSocketOption(Result, SocketOptionReuseAddress, 1);
  Error := BindSocket(Result, MakeSocketAddress(LocalAddress, LocalPort));
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot bind to port %u', [ArgumentUnsigned(LocalPort)]);
end;

function TransportName: PChar;
begin
  if Settings.Datagrams then
    Result := 'udp'
  else
    Result := 'tcp';
end;

function HostText(constref Address: TAbiSocketAddress; Buffer: PChar): PChar;
begin
  Result := FormatInternetAddress(SocketAddressHost(Address), Buffer, Ipv4AddressTextCapacity);
end;

end.
