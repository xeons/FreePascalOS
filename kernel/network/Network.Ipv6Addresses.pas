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
  IPv6 addresses inside the kernel (RFC 4291).

  An IPv6 address is kept as its sixteen bytes in the order of the wire
  (fe80::1 is FE 80 0 ... 0 1), so it is copied to and from packets and
  system call records as it is. The well-known addresses, the kinds of
  address (unspecified, loopback, link-local, multicast), prefixes, the
  solicited-node multicast group of an address, the Ethernet address a
  multicast group maps to, and interface identifiers made from an
  Ethernet address (modified EUI-64) are here.
}
unit Network.Ipv6Addresses;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.NetworkAdapters;

const
  Ipv6AddressLength = 16;
  { The text of the longest address and its terminator. }
  Ipv6AddressTextCapacity = 40;

type
  TIpv6Address = array[0..Ipv6AddressLength - 1] of Byte;
  PIpv6Address = ^TIpv6Address;

const
  UnspecifiedIpv6Address: TIpv6Address = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  LoopbackIpv6Address: TIpv6Address = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
  { ff02::1 and ff02::2. }
  AllNodesIpv6Address: TIpv6Address = ($FF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
  AllRoutersIpv6Address: TIpv6Address = ($FF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2);
  { ff02::16: where MLDv2 reports go. }
  AllMldRoutersIpv6Address: TIpv6Address = ($FF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $16);
  LinkLocalPrefixLength = 64;
  LoopbackIpv6PrefixLength = 128;

function Ipv6AddressesEqual(constref First, Second: TIpv6Address): Boolean;
function IsUnspecifiedIpv6Address(constref Address: TIpv6Address): Boolean;
function IsLoopbackIpv6Address(constref Address: TIpv6Address): Boolean;
{ fe80::/10. }
function IsLinkLocalIpv6Address(constref Address: TIpv6Address): Boolean;
{ ff00::/8. }
function IsMulticastIpv6Address(constref Address: TIpv6Address): Boolean;
{ ::ffff:0:0/96 (an IPv4 address seen through IPv6; never used here). }
function IsIpv4MappedIpv6Address(constref Address: TIpv6Address): Boolean;
{ True if the first PrefixLength bits are the same. }
function SameIpv6Prefix(constref First, Second: TIpv6Address; PrefixLength: LongWord): Boolean;
{ Address with every bit after the first PrefixLength cleared. }
function Ipv6PrefixOf(constref Address: TIpv6Address; PrefixLength: LongWord): TIpv6Address;
{ How many leading bits the two have in common (0-128). }
function CommonIpv6PrefixLength(constref First, Second: TIpv6Address): LongWord;
{ ff02::1:ffXX:XXXX, the group whose last 24 bits are Address's. }
function SolicitedNodeAddress(constref Address: TIpv6Address): TIpv6Address;
{ 33:33 and the multicast group's last four bytes. }
function MulticastEthernetAddress(constref Group: TIpv6Address): TEthernetAddress;
{ The prefix's first 64 bits with the modified EUI-64 interface
  identifier of an Ethernet address (RFC 4291 appendix A). }
function AddressFromInterfaceIdentifier(constref Prefix: TIpv6Address; constref Hardware: TEthernetAddress): TIpv6Address;
{ fe80::/64 with the Ethernet address's interface identifier. }
function LinkLocalAddressFor(constref Hardware: TEthernetAddress): TIpv6Address;
{ Writes the address as RFC 5952 recommends (lower case, the longest
  run of zero groups as "::") into Text (Ipv6AddressTextCapacity), for
  the kernel log. }
procedure FormatIpv6Address(constref Address: TIpv6Address; Text: PChar);

implementation

uses
  Runtime.Memory;

function Ipv6AddressesEqual(constref First, Second: TIpv6Address): Boolean;
begin
  Result := MemoryIsEqual(@First[0], @Second[0], Ipv6AddressLength);
end;

function IsUnspecifiedIpv6Address(constref Address: TIpv6Address): Boolean;
begin
  Result := Ipv6AddressesEqual(Address, UnspecifiedIpv6Address);
end;

function IsLoopbackIpv6Address(constref Address: TIpv6Address): Boolean;
begin
  Result := Ipv6AddressesEqual(Address, LoopbackIpv6Address);
end;

function IsLinkLocalIpv6Address(constref Address: TIpv6Address): Boolean;
begin
  Result := (Address[0] = $FE) and ((Address[1] and $C0) = $80);
end;

function IsMulticastIpv6Address(constref Address: TIpv6Address): Boolean;
begin
  Result := Address[0] = $FF;
end;

function IsIpv4MappedIpv6Address(constref Address: TIpv6Address): Boolean;
const
  MappedPrefix: array[0..11] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $FF, $FF);
begin
  Result := MemoryIsEqual(@Address[0], @MappedPrefix[0], SizeOf(MappedPrefix));
end;

function SameIpv6Prefix(constref First, Second: TIpv6Address; PrefixLength: LongWord): Boolean;
begin
  if PrefixLength > 128 then
    PrefixLength := 128;
  Result := CommonIpv6PrefixLength(First, Second) >= PrefixLength;
end;

function Ipv6PrefixOf(constref Address: TIpv6Address; PrefixLength: LongWord): TIpv6Address;
var
  Index: LongWord;
  BitsLeft: LongWord;
begin
  Result := Address;
  for Index := 0 to Ipv6AddressLength - 1 do
  begin
    if PrefixLength >= (Index + 1) * 8 then
      Continue;
    if PrefixLength <= Index * 8 then
      Result[Index] := 0
    else
    begin
      BitsLeft := PrefixLength - Index * 8;
      Result[Index] := Result[Index] and Byte($FF shl (8 - BitsLeft));
    end;
  end;
end;

function CommonIpv6PrefixLength(constref First, Second: TIpv6Address): LongWord;
var
  Index: LongWord;
  Difference: Byte;
begin
  Result := 0;
  for Index := 0 to Ipv6AddressLength - 1 do
  begin
    Difference := First[Index] xor Second[Index];
    if Difference = 0 then
    begin
      Result := Result + 8;
      Continue;
    end;
    while (Difference and $80) = 0 do
    begin
      Inc(Result);
      Difference := Byte(Difference shl 1);
    end;
    Exit;
  end;
end;

function SolicitedNodeAddress(constref Address: TIpv6Address): TIpv6Address;
begin
  FillMemory(@Result[0], Ipv6AddressLength, 0);
  Result[0] := $FF;
  Result[1] := $02;
  Result[11] := $01;
  Result[12] := $FF;
  Result[13] := Address[13];
  Result[14] := Address[14];
  Result[15] := Address[15];
end;

function MulticastEthernetAddress(constref Group: TIpv6Address): TEthernetAddress;
begin
  Result[0] := $33;
  Result[1] := $33;
  Result[2] := Group[12];
  Result[3] := Group[13];
  Result[4] := Group[14];
  Result[5] := Group[15];
end;

function AddressFromInterfaceIdentifier(constref Prefix: TIpv6Address; constref Hardware: TEthernetAddress): TIpv6Address;
begin
  Result := Ipv6PrefixOf(Prefix, 64);
  { The universal/local bit is inverted; FFFE goes in the middle. }
  Result[8] := Hardware[0] xor $02;
  Result[9] := Hardware[1];
  Result[10] := Hardware[2];
  Result[11] := $FF;
  Result[12] := $FE;
  Result[13] := Hardware[3];
  Result[14] := Hardware[4];
  Result[15] := Hardware[5];
end;

function LinkLocalAddressFor(constref Hardware: TEthernetAddress): TIpv6Address;
var
  Prefix: TIpv6Address;
begin
  Prefix := UnspecifiedIpv6Address;
  Prefix[0] := $FE;
  Prefix[1] := $80;
  Result := AddressFromInterfaceIdentifier(Prefix, Hardware);
end;

{ The longest run of two or more zero groups; First is -1 if none. }
procedure FindLongestZeroRun(const Groups: array of Word; out First, Count: Integer);
var
  Index: Integer;
  RunStart: Integer;
begin
  First := -1;
  Count := 0;
  Index := 0;
  while Index < 8 do
  begin
    if Groups[Index] <> 0 then
    begin
      Inc(Index);
      Continue;
    end;
    RunStart := Index;
    while (Index < 8) and (Groups[Index] = 0) do
      Inc(Index);
    if (Index - RunStart >= 2) and (Index - RunStart > Count) then
    begin
      First := RunStart;
      Count := Index - RunStart;
    end;
  end;
end;

procedure AppendGroup(Text: PChar; var Length: Integer; Group: Word);
const
  Digits: PChar = '0123456789abcdef';
var
  Shift: Integer;
  Started: Boolean;
  Digit: Word;
begin
  Started := False;
  Shift := 12;
  while Shift >= 0 do
  begin
    Digit := (Group shr Shift) and $F;
    if Started or (Digit <> 0) or (Shift = 0) then
    begin
      Started := True;
      Text[Length] := Digits[Digit];
      Inc(Length);
    end;
    Shift := Shift - 4;
  end;
end;

procedure FormatIpv6Address(constref Address: TIpv6Address; Text: PChar);
var
  Groups: array[0..7] of Word;
  Index: Integer;
  RunFirst: Integer;
  RunCount: Integer;
  Length: Integer;
begin
  for Index := 0 to 7 do
    Groups[Index] := (Word(Address[Index * 2]) shl 8) or Address[Index * 2 + 1];
  FindLongestZeroRun(Groups, RunFirst, RunCount);
  Length := 0;
  Index := 0;
  while Index < 8 do
  begin
    if Index = RunFirst then
    begin
      Text[Length] := ':';
      Text[Length + 1] := ':';
      Length := Length + 2;
      Index := Index + RunCount;
      Continue;
    end;
    if (Index > 0) and (Index <> RunFirst + RunCount) then
    begin
      Text[Length] := ':';
      Inc(Length);
    end;
    AppendGroup(Text, Length, Groups[Index]);
    Inc(Index);
  end;
  Text[Length] := #0;
end;

end.
