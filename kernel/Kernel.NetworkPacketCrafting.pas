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
  Crafted datagrams for the network self tests: IPv4 and IPv6 headers,
  TCP segments, UDP datagrams and ICMP messages built byte by byte with
  their checksums, and handed to the stack as if an interface had
  received them (Ipv4Input, Ipv6Input under the network lock). The
  interface may be lo or a test interface that is not in the table: an
  Ethernet interface with an address of TEST-NET-1 (192.0.2.1/24),
  which nothing ever transmits through.
}
unit Kernel.NetworkPacketCrafting;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Interfaces;

const
  CraftedCapacity = 256;
  TestInterfaceAddress = TIpv4Address($C0000201);
  TestInterfacePrefix = 24;

type
  TCraftedDatagram = record
    Bytes: array[0..CraftedCapacity - 1] of Byte;
    Length: LongWord;
  end;

  TCraftedTcp = record
    SourcePort: Word;
    DestinationPort: Word;
    Sequence: LongWord;
    Acknowledgment: LongWord;
    Flags: Byte;
    Window: Word;
    Data: PByte;
    DataLength: LongWord;
  end;

{ The test interface (not registered), with an IPv4 address or without. }
function TestEthernetInterface(WithAddress: Boolean): PNetworkInterface;
{ An IPv4 datagram of Protocol carrying Payload. }
procedure CraftIpv4(out Datagram: TCraftedDatagram; Source, Destination: TIpv4Address; Protocol: Byte;
  Payload: PByte; PayloadLength: LongWord);
{ An IPv6 datagram whose payload (NextHeader's) is Payload. }
procedure CraftIpv6(out Datagram: TCraftedDatagram; constref Source, Destination: TIpv6Address; NextHeader: Byte;
  Payload: PByte; PayloadLength: LongWord);
{ A TCP segment (20-byte header) into Target, its checksum for the
  endpoints' addresses; returns its length. }
function CraftTcp(Target: PByte; constref Source, Destination: TNetworkEndpoint; constref Segment: TCraftedTcp): LongWord;
{ A UDP datagram into Target; returns its length. }
function CraftUdp(Target: PByte; constref Source, Destination: TNetworkEndpoint; Data: PByte;
  DataLength: LongWord): LongWord;
{ The datagram, as if NetworkInterface had received it. }
procedure InjectIpv4(NetworkInterface: PNetworkInterface; var Datagram: TCraftedDatagram);
procedure InjectIpv6(NetworkInterface: PNetworkInterface; var Datagram: TCraftedDatagram);
{ A TCP segment from Source to Destination, as received on
  NetworkInterface (over IPv4 or IPv6, as the endpoints are). }
procedure InjectTcp(NetworkInterface: PNetworkInterface; constref Source, Destination: TNetworkEndpoint;
  constref Segment: TCraftedTcp);
procedure InjectUdp(NetworkInterface: PNetworkInterface; constref Source, Destination: TNetworkEndpoint;
  Data: PByte; DataLength: LongWord);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Network.ByteOrder,
  Network.Checksums,
  Network.Core,
  Network.Ipv4,
  Network.Ipv6;

const
  Ipv6FixedHeaderBytes = 40;

var
  TestInterface: TNetworkInterface;

function TestEthernetInterface(WithAddress: Boolean): PNetworkInterface;
begin
  FillMemory(@TestInterface, SizeOf(TestInterface), 0);
  TestInterface.Index := 200;
  CopyText(@TestInterface.Name[0], 'selftest0', NetworkInterfaceNameCapacity);
  TestInterface.IsUp := True;
  TestInterface.LinkIsUp := True;
  TestInterface.Mtu := DefaultMtu;
  TestInterface.HasAddress := WithAddress;
  if WithAddress then
  begin
    TestInterface.Address := TestInterfaceAddress;
    TestInterface.PrefixLength := TestInterfacePrefix;
  end;
  TestInterface.Ipv6.Mode := Ipv6ModeLinkLocal;
  Result := @TestInterface;
end;

procedure CraftIpv4(out Datagram: TCraftedDatagram; Source, Destination: TIpv4Address; Protocol: Byte;
  Payload: PByte; PayloadLength: LongWord);
var
  Header: PByte;
begin
  FillMemory(@Datagram, SizeOf(Datagram), 0);
  Header := @Datagram.Bytes[0];
  Datagram.Length := 20 + PayloadLength;
  Header[0] := $45;
  WriteBigEndian16(Header + 2, Word(Datagram.Length));
  WriteBigEndian16(Header + 4, $1234);
  Header[8] := 64;
  Header[9] := Protocol;
  WriteIpv4Address(Header + 12, Source);
  WriteIpv4Address(Header + 16, Destination);
  WriteBigEndian16(Header + 10, InternetChecksum(Header, 20));
  CopyMemory(Header + 20, Payload, PayloadLength);
end;

procedure CraftIpv6(out Datagram: TCraftedDatagram; constref Source, Destination: TIpv6Address; NextHeader: Byte;
  Payload: PByte; PayloadLength: LongWord);
var
  Header: PByte;
begin
  FillMemory(@Datagram, SizeOf(Datagram), 0);
  Header := @Datagram.Bytes[0];
  Datagram.Length := Ipv6FixedHeaderBytes + PayloadLength;
  Header[0] := $60;
  WriteBigEndian16(Header + 4, Word(PayloadLength));
  Header[6] := NextHeader;
  Header[7] := 64;
  CopyMemory(Header + 8, @Source[0], Ipv6AddressLength);
  CopyMemory(Header + 24, @Destination[0], Ipv6AddressLength);
  CopyMemory(Header + Ipv6FixedHeaderBytes, Payload, PayloadLength);
end;

function PseudoSum(constref Source, Destination: TNetworkEndpoint; Protocol: Byte; Length: LongWord): LongWord;
begin
  if Source.Family = AddressFamilyIPv6 then
    Result := Ipv6PseudoHeaderSum(@Source.Address6[0], @Destination.Address6[0], Protocol, Length)
  else
    Result := PseudoHeaderSum(Source.Address, Destination.Address, Protocol, Length);
end;

function CraftTcp(Target: PByte; constref Source, Destination: TNetworkEndpoint; constref Segment: TCraftedTcp): LongWord;
begin
  Result := 20 + Segment.DataLength;
  FillMemory(Target, 20, 0);
  WriteBigEndian16(Target, Segment.SourcePort);
  WriteBigEndian16(Target + 2, Segment.DestinationPort);
  WriteBigEndian32(Target + 4, Segment.Sequence);
  WriteBigEndian32(Target + 8, Segment.Acknowledgment);
  Target[12] := 5 shl 4;
  Target[13] := Segment.Flags;
  WriteBigEndian16(Target + 14, Segment.Window);
  if Segment.DataLength > 0 then
    CopyMemory(Target + 20, Segment.Data, Segment.DataLength);
  WriteBigEndian16(Target + 16, FinishChecksum(AddToChecksum(PseudoSum(Source, Destination, 6, Result), Target,
    Result)));
end;

function CraftUdp(Target: PByte; constref Source, Destination: TNetworkEndpoint; Data: PByte;
  DataLength: LongWord): LongWord;
var
  Sum: Word;
begin
  Result := 8 + DataLength;
  WriteBigEndian16(Target, Source.Port);
  WriteBigEndian16(Target + 2, Destination.Port);
  WriteBigEndian16(Target + 4, Word(Result));
  WriteBigEndian16(Target + 6, 0);
  if DataLength > 0 then
    CopyMemory(Target + 8, Data, DataLength);
  Sum := FinishChecksum(AddToChecksum(PseudoSum(Source, Destination, 17, Result), Target, Result));
  if Sum = 0 then
    Sum := $FFFF;
  WriteBigEndian16(Target + 6, Sum);
end;

procedure InjectIpv4(NetworkInterface: PNetworkInterface; var Datagram: TCraftedDatagram);
begin
  LockNetwork;
  Ipv4Input(NetworkInterface, @Datagram.Bytes[0], Datagram.Length);
  UnlockNetwork;
end;

procedure InjectIpv6(NetworkInterface: PNetworkInterface; var Datagram: TCraftedDatagram);
begin
  LockNetwork;
  Ipv6Input(NetworkInterface, @Datagram.Bytes[0], Datagram.Length);
  UnlockNetwork;
end;

procedure InjectTransport(NetworkInterface: PNetworkInterface; constref Source, Destination: TNetworkEndpoint;
  Protocol: Byte; Payload: PByte; Length: LongWord);
var
  Datagram: TCraftedDatagram;
begin
  if Source.Family = AddressFamilyIPv6 then
  begin
    CraftIpv6(Datagram, Source.Address6, Destination.Address6, Protocol, Payload, Length);
    InjectIpv6(NetworkInterface, Datagram);
  end
  else
  begin
    CraftIpv4(Datagram, Source.Address, Destination.Address, Protocol, Payload, Length);
    InjectIpv4(NetworkInterface, Datagram);
  end;
end;

procedure InjectTcp(NetworkInterface: PNetworkInterface; constref Source, Destination: TNetworkEndpoint;
  constref Segment: TCraftedTcp);
var
  Payload: array[0..127] of Byte;
  Length: LongWord;
begin
  Length := CraftTcp(@Payload[0], Source, Destination, Segment);
  InjectTransport(NetworkInterface, Source, Destination, 6, @Payload[0], Length);
end;

procedure InjectUdp(NetworkInterface: PNetworkInterface; constref Source, Destination: TNetworkEndpoint;
  Data: PByte; DataLength: LongWord);
var
  Payload: array[0..127] of Byte;
  Length: LongWord;
begin
  Length := CraftUdp(@Payload[0], Source, Destination, Data, DataLength);
  InjectTransport(NetworkInterface, Source, Destination, 17, @Payload[0], Length);
end;

end.
