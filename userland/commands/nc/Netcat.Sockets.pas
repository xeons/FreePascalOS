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
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.InternetAddresses;

{ The address of Host (numeric only with -n; an IPv6 address may be in
  brackets) of the families -4 and -6 allow, the one to try first; ends
  nc if there is none. }
function ResolveHost(const Host: string): TInternetAddress;
{ The unspecified address (0.0.0.0, or :: with -6) to listen on. }
function AnyListeningAddress: TInternetAddress;
{ A TCP or UDP socket (-u), bound to -p's port if one was given (with
  Address as the local address); ends nc on failure. }
function OpenSocket(constref LocalAddress: TInternetAddress; LocalPort: Word): Int64;
{ "tcp" or "udp". }
function TransportName: string;
{ The address part of Address as text. }
function HostText(constref Address: TAbiSocketAddress): string;

implementation

uses
  SysUtils,
  Sys.Errors,
  Sys.HostNames,
  Sys.HostLookup,
  Sys.AddressText,
  Sys.Sockets,
  Util.Messages,
  Netcat.Settings;

function FamilyIsAllowed(Family: Word): Boolean;
begin
  case Family of
    AddressFamilyIPv4: Result := (Settings.Families and HostFamilyIpv4) <> 0;
    AddressFamilyIPv6: Result := (Settings.Families and HostFamilyIpv6) <> 0;
  else
    Result := False;
  end;
end;

function ResolveHost(const Host: string): TInternetAddress;
var
  Error: LongInt;
  Name: string;
  Port: string;
  Addresses: TInternetAddressArray;
begin
  { "[::1]" as a URL writes it. }
  if not SplitHostAndPort(Host, Name, Port) or (Port <> '') then
    Name := Host;
  if TextToAddress(Name, Result) then
  begin
    if not FamilyIsAllowed(Result.Family) then
      Fail(1, Host + ': Address family for hostname not supported');
    Exit;
  end;
  if Settings.NumericOnly then
    Fail(1, Host + ': not a numeric address (-n)');
  Error := Sys.HostLookup.ResolveHost(Name, Settings.Families, Addresses);
  if (Error = ErrorNone) and (Length(Addresses) = 0) then
    Error := ErrorNotFound;
  if Error = ErrorNotFound then
    Fail(1, Host + ': Name or service not known');
  if Error <> ErrorNone then
    FailWithError(1, Error, Host);
  Result := Addresses[0];
end;

function AnyListeningAddress: TInternetAddress;
begin
  if Settings.Families = HostFamilyIpv6 then
    Result := AnyIpv6Address
  else
    Result := AnyIpv4Address;
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
  Result := CreateSocket(LocalAddress.Family, Kind, ProtocolDefault);
  if Result < 0 then
    FailWithError(1, ErrorCodeOf(Result), 'cannot make a socket');
  if (LocalPort = 0) and AddressIsUnspecified(LocalAddress) then
    Exit;
  SetSocketOption(Result, SocketOptionReuseAddress, 1);
  Error := BindSocket(Result, MakeSocketAddress(LocalAddress, LocalPort));
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot bind to port ' + IntToStr(LocalPort));
end;

function TransportName: string;
begin
  if Settings.Datagrams then
    Result := 'udp'
  else
    Result := 'tcp';
end;

function HostText(constref Address: TAbiSocketAddress): string;
begin
  Result := AddressToText(SocketAddressHost(Address));
end;

end.
