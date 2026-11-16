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
  Internet addresses as programs write them: dotted quads (10.0.2.15),
  with a prefix (10.0.2.15/24) or a netmask (255.255.255.0), and with a
  port (10.0.2.15:80), read and written; and turned into the socket
  addresses the system calls take.

  An address carries its family, so that IPv6 can be added: an IPv4
  address keeps its four bytes first, in the order they are written.
}
unit Sys.InternetAddresses;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

const
  { "255.255.255.255" and its terminator. }
  Ipv4AddressTextCapacity = 16;
  { With ":65535". }
  SocketAddressTextCapacity = 22;

type
  TInternetAddress = record
    Family: Word;
    Bytes: array[0..15] of Byte;
  end;

function Ipv4Address(First, Second, Third, Fourth: Byte): TInternetAddress;
function AnyIpv4Address: TInternetAddress;
function LoopbackIpv4Address: TInternetAddress;
function BroadcastIpv4Address: TInternetAddress;
{ The four bytes as one number, the first byte highest ($0A00020F). }
function Ipv4AddressValue(constref Address: TInternetAddress): LongWord;
function Ipv4AddressFromValue(Value: LongWord): TInternetAddress;
function AddressesAreEqual(constref First, Second: TInternetAddress): Boolean;
{ 0.0.0.0 (or no family at all). }
function AddressIsUnspecified(constref Address: TInternetAddress): Boolean;

{ A dotted quad, each part 0-255 in decimal; nothing else in Text. }
function ParseIpv4Address(Text: PChar; out Address: TInternetAddress): Boolean;
{ "A.B.C.D/N"; without "/N" the prefix is 32 and HasPrefix False. }
function ParseAddressWithPrefix(Text: PChar; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
{ A netmask (255.255.255.0) as a prefix length; False if its ones are
  not all in front. }
function ParseNetmask(Text: PChar; out PrefixLength: LongWord): Boolean;

{ Writes the address into Buffer and returns Buffer. }
function FormatInternetAddress(constref Address: TInternetAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
{ "255.255.255.0" for 24. }
function FormatNetmask(PrefixLength: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;

function MakeSocketAddress(constref Address: TInternetAddress; Port: Word): TAbiSocketAddress;
function SocketAddressHost(constref SocketAddress: TAbiSocketAddress): TInternetAddress;
{ "10.0.2.15:80". }
function FormatSocketAddress(constref SocketAddress: TAbiSocketAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
{ The address part of a TAbiInterfaceAddress (or of a route). }
function InterfaceAddressHost(constref Address: TAbiInterfaceAddress): TInternetAddress;

implementation

uses
  Runtime.Memory,
  Runtime.Text;

function Ipv4Address(First, Second, Third, Fourth: Byte): TInternetAddress;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Family := AddressFamilyIPv4;
  Result.Bytes[0] := First;
  Result.Bytes[1] := Second;
  Result.Bytes[2] := Third;
  Result.Bytes[3] := Fourth;
end;

function AnyIpv4Address: TInternetAddress;
begin
  Result := Ipv4Address(0, 0, 0, 0);
end;

function LoopbackIpv4Address: TInternetAddress;
begin
  Result := Ipv4Address(127, 0, 0, 1);
end;

function BroadcastIpv4Address: TInternetAddress;
begin
  Result := Ipv4Address(255, 255, 255, 255);
end;

function Ipv4AddressValue(constref Address: TInternetAddress): LongWord;
begin
  Result := (LongWord(Address.Bytes[0]) shl 24) or (LongWord(Address.Bytes[1]) shl 16) or
    (LongWord(Address.Bytes[2]) shl 8) or LongWord(Address.Bytes[3]);
end;

function Ipv4AddressFromValue(Value: LongWord): TInternetAddress;
begin
  Result := Ipv4Address(Byte(Value shr 24), Byte(Value shr 16), Byte(Value shr 8), Byte(Value));
end;

function AddressesAreEqual(constref First, Second: TInternetAddress): Boolean;
begin
  Result := (First.Family = Second.Family) and MemoryIsEqual(@First.Bytes[0], @Second.Bytes[0], 16);
end;

function AddressIsUnspecified(constref Address: TInternetAddress): Boolean;
begin
  Result := (Address.Family = AddressFamilyUnspecified) or
    ((Address.Family = AddressFamilyIPv4) and (Ipv4AddressValue(Address) = 0));
end;

{ A decimal number of 1 to 3 digits from Text[Position], at most Limit;
  Position moves past it. }
function ParseSmallNumber(Text: PChar; var Position: PtrUInt; Limit: LongWord; out Value: LongWord): Boolean;
var
  Digits: Integer;
begin
  Value := 0;
  Digits := 0;
  while (Text[Position] >= '0') and (Text[Position] <= '9') do
  begin
    if Digits = 3 then
      Exit(False);
    Value := Value * 10 + LongWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
    Inc(Digits);
  end;
  Result := (Digits > 0) and (Value <= Limit);
end;

function ParseQuadAt(Text: PChar; var Position: PtrUInt; out Address: TInternetAddress): Boolean;
var
  Part: Integer;
  Value: LongWord;
begin
  Address := AnyIpv4Address;
  for Part := 0 to 3 do
  begin
    if not ParseSmallNumber(Text, Position, 255, Value) then
      Exit(False);
    Address.Bytes[Part] := Byte(Value);
    if Part < 3 then
    begin
      if Text[Position] <> '.' then
        Exit(False);
      Inc(Position);
    end;
  end;
  Result := True;
end;

function ParseIpv4Address(Text: PChar; out Address: TInternetAddress): Boolean;
var
  Position: PtrUInt;
begin
  Position := 0;
  Result := (Text <> nil) and ParseQuadAt(Text, Position, Address) and (Text[Position] = #0);
end;

function ParseAddressWithPrefix(Text: PChar; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
var
  Position: PtrUInt;
begin
  PrefixLength := 32;
  HasPrefix := False;
  Position := 0;
  if (Text = nil) or not ParseQuadAt(Text, Position, Address) then
    Exit(False);
  if Text[Position] = '/' then
  begin
    Inc(Position);
    if not ParseSmallNumber(Text, Position, 32, PrefixLength) then
      Exit(False);
    HasPrefix := True;
  end;
  Result := Text[Position] = #0;
end;

function ParseNetmask(Text: PChar; out PrefixLength: LongWord): Boolean;
var
  Mask: TInternetAddress;
  Value: LongWord;
begin
  PrefixLength := 0;
  if not ParseIpv4Address(Text, Mask) then
    Exit(False);
  Value := Ipv4AddressValue(Mask);
  while (Value and $80000000) <> 0 do
  begin
    Inc(PrefixLength);
    Value := Value shl 1;
  end;
  Result := Value = 0;
end;

function FormatInternetAddress(constref Address: TInternetAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Text: array[0..Ipv4AddressTextCapacity - 1] of Char;
  Number: TNumberText;
  Part: Integer;
  Length: PtrUInt;
begin
  Result := Buffer;
  if Capacity = 0 then
    Exit;
  Text[0] := #0;
  if Address.Family = AddressFamilyIPv4 then
    for Part := 0 to 3 do
    begin
      Length := TextLength(@Text[0]);
      CopyText(@Text[Length], FormatDecimal(Address.Bytes[Part], Number), Ipv4AddressTextCapacity - Length);
      if Part < 3 then
      begin
        Length := TextLength(@Text[0]);
        Text[Length] := '.';
        Text[Length + 1] := #0;
      end;
    end
  else
    CopyText(@Text[0], '?', Ipv4AddressTextCapacity);
  CopyText(Buffer, @Text[0], Capacity);
end;

function FormatNetmask(PrefixLength: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Value: LongWord;
begin
  if PrefixLength = 0 then
    Value := 0
  else if PrefixLength >= 32 then
    Value := $FFFFFFFF
  else
    Value := LongWord($FFFFFFFF shl (32 - PrefixLength));
  Result := FormatInternetAddress(Ipv4AddressFromValue(Value), Buffer, Capacity);
end;

function MakeSocketAddress(constref Address: TInternetAddress; Port: Word): TAbiSocketAddress;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Family := Address.Family;
  Result.Port := Port;
  CopyMemory(@Result.Address[0], @Address.Bytes[0], 16);
end;

function SocketAddressHost(constref SocketAddress: TAbiSocketAddress): TInternetAddress;
begin
  Result.Family := SocketAddress.Family;
  CopyMemory(@Result.Bytes[0], @SocketAddress.Address[0], 16);
end;

function FormatSocketAddress(constref SocketAddress: TAbiSocketAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Text: array[0..SocketAddressTextCapacity - 1] of Char;
  Number: TNumberText;
  Length: PtrUInt;
begin
  FormatInternetAddress(SocketAddressHost(SocketAddress), @Text[0], SocketAddressTextCapacity);
  Length := TextLength(@Text[0]);
  Text[Length] := ':';
  CopyText(@Text[Length + 1], FormatDecimal(SocketAddress.Port, Number), SocketAddressTextCapacity - Length - 1);
  Result := Buffer;
  CopyText(Buffer, @Text[0], Capacity);
end;

function InterfaceAddressHost(constref Address: TAbiInterfaceAddress): TInternetAddress;
begin
  Result.Family := Address.Family;
  CopyMemory(@Result.Bytes[0], @Address.Address[0], 16);
end;

end.
