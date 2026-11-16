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
  records only at their edges. An endpoint is an address and a port
  with the family it belongs to, so that sockets do not assume IPv4.
}
unit Network.Addresses;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

type
  TIpv4Address = LongWord;

  PNetworkEndpoint = ^TNetworkEndpoint;
  TNetworkEndpoint = record
    Family: Word;
    Port: Word;
    Address: TIpv4Address;
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
{ A system call's address as an endpoint: ErrorAddressFamilyNotSupported
  for a family other than IPv4. }
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
  Result.Family := AddressFamilyIPv4;
  Result.Port := Port;
  Result.Address := Address;
end;

function EndpointFromAbi(constref Source: TAbiSocketAddress; out Endpoint: TNetworkEndpoint): LongInt;
begin
  Endpoint := MakeEndpoint(AnyAddress, 0);
  if Source.Family <> AddressFamilyIPv4 then
    Exit(ErrorAddressFamilyNotSupported);
  Endpoint.Port := Source.Port;
  Endpoint.Address := ReadIpv4Address(@Source.Address[0]);
  Result := ErrorNone;
end;

procedure EndpointToAbi(constref Endpoint: TNetworkEndpoint; out Destination: TAbiSocketAddress);
begin
  FillMemory(@Destination, SizeOf(Destination), 0);
  Destination.Family := AddressFamilyIPv4;
  Destination.Port := Endpoint.Port;
  WriteIpv4Address(@Destination.Address[0], Endpoint.Address);
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
