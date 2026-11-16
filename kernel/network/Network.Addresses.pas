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
  Network addresses inside the kernel.

  An IPv4 address is a LongWord in the machine's byte order (10.0.2.15
  is $0A00020F), which makes masks and comparisons plain arithmetic; it
  is turned into the four bytes of the wire and of the system call
  records only at their edges. IPv6 addresses (Network.Ipv6Addresses)
  are their sixteen bytes.

  An endpoint is an address and a port with the family it belongs to:
  Address holds an IPv4 address, Address6 an IPv6 one (with ScopeId,
  the interface a link-local address belongs to). Sockets and TCP
  connections keep endpoints and compare them with the functions here,
  so that they work for both families alike.
}
unit Network.Addresses;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Network.Ipv6Addresses;

type
  TIpv4Address = LongWord;

  PNetworkEndpoint = ^TNetworkEndpoint;
  TNetworkEndpoint = record
    Family: Word;
    Port: Word;
    { IPv6: the index of the interface of a link-local address; 0
      otherwise. }
    ScopeId: LongWord;
    Address: TIpv4Address;
    Address6: TIpv6Address;
  end;

const
  AnyAddress = TIpv4Address(0);
  LimitedBroadcastAddress = TIpv4Address($FFFFFFFF);
  LoopbackAddress = TIpv4Address($7F000001);
  LoopbackPrefixLength = 8;

function PrefixMask(PrefixLength: LongWord): TIpv4Address;
{ True if Address and Other share their first PrefixLength bits. }
function SameNetwork(Address, Other: TIpv4Address; PrefixLength: LongWord): Boolean;
{ The broadcast address of Address's network. }
function SubnetBroadcast(Address: TIpv4Address; PrefixLength: LongWord): TIpv4Address;
function IsLoopbackAddress(Address: TIpv4Address): Boolean;
function IsMulticastAddress(Address: TIpv4Address): Boolean;

{ The four bytes of the wire (or of a record) and back. }
function ReadIpv4Address(Source: PByte): TIpv4Address;
procedure WriteIpv4Address(Destination: PByte; Address: TIpv4Address);

function MakeEndpoint(Address: TIpv4Address; Port: Word): TNetworkEndpoint;
function MakeIpv6Endpoint(constref Address: TIpv6Address; Port: Word; ScopeId: LongWord): TNetworkEndpoint;
{ 0.0.0.0 or :: (port 0) of Family. }
function UnspecifiedEndpoint(Family: Word): TNetworkEndpoint;
{ 127.0.0.1 or ::1 of Family, with Port. }
function LoopbackEndpoint(Family: Word; Port: Word): TNetworkEndpoint;
{ The address is 0.0.0.0 or ::. }
function EndpointIsUnspecified(constref Endpoint: TNetworkEndpoint): Boolean;
{ The same family and address (the port and scope are not looked at). }
function EndpointAddressesEqual(constref First, Second: TNetworkEndpoint): Boolean;
{ The same family, address and port. }
function EndpointsEqual(constref First, Second: TNetworkEndpoint): Boolean;
{ A system call's address as an endpoint: ErrorAddressFamilyNotSupported
  for a family other than IPv4 and IPv6. }
function EndpointFromAbi(constref Source: TAbiSocketAddress; out Endpoint: TNetworkEndpoint): LongInt;
procedure EndpointToAbi(constref Endpoint: TNetworkEndpoint; out Destination: TAbiSocketAddress);

{ Writes an address as a dotted quad into Text (16 characters with the
  terminator), for the kernel log. }
procedure FormatIpv4Address(Address: TIpv4Address; Text: PChar);

implementation

uses
  Runtime.Memory,
  Runtime.Text;

function PrefixMask(PrefixLength: LongWord): TIpv4Address;
begin
  if PrefixLength = 0 then
    Exit(0);
  if PrefixLength >= 32 then
    Exit($FFFFFFFF);
  Result := TIpv4Address($FFFFFFFF shl (32 - PrefixLength));
end;

function SameNetwork(Address, Other: TIpv4Address; PrefixLength: LongWord): Boolean;
var
  Mask: TIpv4Address;
begin
  Mask := PrefixMask(PrefixLength);
  Result := (Address and Mask) = (Other and Mask);
end;

function SubnetBroadcast(Address: TIpv4Address; PrefixLength: LongWord): TIpv4Address;
begin
  Result := Address or not PrefixMask(PrefixLength);
end;

function IsLoopbackAddress(Address: TIpv4Address): Boolean;
begin
  Result := (Address shr 24) = 127;
end;

function IsMulticastAddress(Address: TIpv4Address): Boolean;
begin
  Result := (Address shr 28) = $E;
end;

function ReadIpv4Address(Source: PByte): TIpv4Address;
begin
  Result := (TIpv4Address(Source[0]) shl 24) or (TIpv4Address(Source[1]) shl 16) or
    (TIpv4Address(Source[2]) shl 8) or TIpv4Address(Source[3]);
end;

procedure WriteIpv4Address(Destination: PByte; Address: TIpv4Address);
begin
  Destination[0] := Byte(Address shr 24);
  Destination[1] := Byte(Address shr 16);
  Destination[2] := Byte(Address shr 8);
  Destination[3] := Byte(Address);
end;

function MakeEndpoint(Address: TIpv4Address; Port: Word): TNetworkEndpoint;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Family := AddressFamilyIPv4;
  Result.Port := Port;
  Result.Address := Address;
end;

function MakeIpv6Endpoint(constref Address: TIpv6Address; Port: Word; ScopeId: LongWord): TNetworkEndpoint;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Family := AddressFamilyIPv6;
  Result.Port := Port;
  Result.Address6 := Address;
  if IsLinkLocalIpv6Address(Address) or IsMulticastIpv6Address(Address) then
    Result.ScopeId := ScopeId;
end;

function UnspecifiedEndpoint(Family: Word): TNetworkEndpoint;
begin
  if Family = AddressFamilyIPv6 then
    Result := MakeIpv6Endpoint(UnspecifiedIpv6Address, 0, 0)
  else
    Result := MakeEndpoint(AnyAddress, 0);
end;

function LoopbackEndpoint(Family: Word; Port: Word): TNetworkEndpoint;
begin
  if Family = AddressFamilyIPv6 then
    Result := MakeIpv6Endpoint(LoopbackIpv6Address, Port, 0)
  else
    Result := MakeEndpoint(LoopbackAddress, Port);
end;

function EndpointIsUnspecified(constref Endpoint: TNetworkEndpoint): Boolean;
begin
  if Endpoint.Family = AddressFamilyIPv6 then
    Result := IsUnspecifiedIpv6Address(Endpoint.Address6)
  else
    Result := Endpoint.Address = AnyAddress;
end;

function EndpointAddressesEqual(constref First, Second: TNetworkEndpoint): Boolean;
begin
  if First.Family <> Second.Family then
    Exit(False);
  if First.Family = AddressFamilyIPv6 then
    Result := Ipv6AddressesEqual(First.Address6, Second.Address6)
  else
    Result := First.Address = Second.Address;
end;

function EndpointsEqual(constref First, Second: TNetworkEndpoint): Boolean;
begin
  Result := (First.Port = Second.Port) and EndpointAddressesEqual(First, Second);
end;

function EndpointFromAbi(constref Source: TAbiSocketAddress; out Endpoint: TNetworkEndpoint): LongInt;
var
  Address6: TIpv6Address;
begin
  Endpoint := MakeEndpoint(AnyAddress, 0);
  case Source.Family of
    AddressFamilyIPv4:
      begin
        Endpoint.Port := Source.Port;
        Endpoint.Address := ReadIpv4Address(@Source.Address[0]);
      end;
    AddressFamilyIPv6:
      begin
        CopyMemory(@Address6[0], @Source.Address[0], Ipv6AddressLength);
        Endpoint := MakeIpv6Endpoint(Address6, Source.Port, Source.ScopeId);
      end;
  else
    Exit(ErrorAddressFamilyNotSupported);
  end;
  Result := ErrorNone;
end;

procedure EndpointToAbi(constref Endpoint: TNetworkEndpoint; out Destination: TAbiSocketAddress);
begin
  FillMemory(@Destination, SizeOf(Destination), 0);
  Destination.Port := Endpoint.Port;
  if Endpoint.Family = AddressFamilyIPv6 then
  begin
    Destination.Family := AddressFamilyIPv6;
    Destination.ScopeId := Endpoint.ScopeId;
    CopyMemory(@Destination.Address[0], @Endpoint.Address6[0], Ipv6AddressLength);
  end
  else
  begin
    Destination.Family := AddressFamilyIPv4;
    WriteIpv4Address(@Destination.Address[0], Endpoint.Address);
  end;
end;

procedure FormatIpv4Address(Address: TIpv4Address; Text: PChar);
var
  Number: TNumberText;
  Part: Integer;
  Length: PtrUInt;
begin
  Text[0] := #0;
  for Part := 3 downto 0 do
  begin
    Length := TextLength(Text);
    CopyText(Text + Length, FormatDecimal((Address shr (Part * 8)) and $FF, Number), 16 - Length);
    if Part > 0 then
    begin
      Length := TextLength(Text);
      Text[Length] := '.';
      Text[Length + 1] := #0;
    end;
  end;
end;

end.
