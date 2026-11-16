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

  An address carries its family: an IPv4 address keeps its four bytes
  first, in the order they are written; an IPv6 address all sixteen. A
  socket address of IPv6 is written with brackets ([fec0::2]:80).
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
  { An IPv6 address in brackets with ":65535". }
  SocketAddressTextCapacity = 54;
  { Any address, IPv6 ones included
    ("ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255" and its terminator). }
  InternetAddressTextCapacity = 46;

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
{ 0.0.0.0 or :: (or no family at all). }
function AddressIsUnspecified(constref Address: TInternetAddress): Boolean;

{ "::" and "::1". }
function AnyIpv6Address: TInternetAddress;
function LoopbackIpv6Address: TInternetAddress;
{ 127.0.0.0/8 or ::1. }
function AddressIsLoopback(constref Address: TInternetAddress): Boolean;
{ IPv6 fe80::/10 (IPv4 169.254.0.0/16). }
function AddressIsLinkLocal(constref Address: TInternetAddress): Boolean;
{ IPv4 224.0.0.0/4, IPv6 ff00::/8. }
function AddressIsMulticast(constref Address: TInternetAddress): Boolean;
{ True if the first PrefixLength bits of the two (of one family) are
  the same. }
function AddressesSharePrefix(constref First, Second: TInternetAddress; PrefixLength: LongWord): Boolean;

{ A dotted quad, each part 0-255 in decimal; nothing else in Text. }
function ParseIpv4Address(Text: PChar; out Address: TInternetAddress): Boolean;
{ An IPv6 address as RFC 4291 writes it: eight groups of up to four
  hexadecimal digits, "::" for a run of zero groups, and an IPv4 address
  for the last 32 bits if wanted ("::ffff:10.0.2.15"). }
function ParseIpv6Address(Text: PChar; out Address: TInternetAddress): Boolean;
{ Either. }
function ParseInternetAddress(Text: PChar; out Address: TInternetAddress): Boolean;
{ "A.B.C.D/N" or an IPv6 address with "/N"; without "/N" the prefix is
  32 (IPv6: 128) and HasPrefix False. }
function ParseAddressWithPrefix(Text: PChar; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
{ A netmask (255.255.255.0) as a prefix length; False if its ones are
  not all in front. }
function ParseNetmask(Text: PChar; out PrefixLength: LongWord): Boolean;

{ Writes the address into Buffer and returns Buffer: IPv6 addresses as
  RFC 5952 recommends (lower case, the longest run of zero groups as
  "::"). }
function FormatInternetAddress(constref Address: TInternetAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
{ "255.255.255.0" for 24. }
function FormatNetmask(PrefixLength: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;

function MakeSocketAddress(constref Address: TInternetAddress; Port: Word): TAbiSocketAddress;
function SocketAddressHost(constref SocketAddress: TAbiSocketAddress): TInternetAddress;
{ "10.0.2.15:80", "[fec0::2]:80". }
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
var
  Index: Integer;
begin
  case Address.Family of
    AddressFamilyIPv4: Result := Ipv4AddressValue(Address) = 0;
    AddressFamilyIPv6:
      begin
        for Index := 0 to 15 do
          if Address.Bytes[Index] <> 0 then
            Exit(False);
        Result := True;
      end;
  else
    Result := True;
  end;
end;

function AnyIpv6Address: TInternetAddress;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Family := AddressFamilyIPv6;
end;

function LoopbackIpv6Address: TInternetAddress;
begin
  Result := AnyIpv6Address;
  Result.Bytes[15] := 1;
end;

function AddressIsLoopback(constref Address: TInternetAddress): Boolean;
begin
  case Address.Family of
    AddressFamilyIPv4: Result := Address.Bytes[0] = 127;
    AddressFamilyIPv6: Result := AddressesAreEqual(Address, LoopbackIpv6Address);
  else
    Result := False;
  end;
end;

function AddressIsLinkLocal(constref Address: TInternetAddress): Boolean;
begin
  case Address.Family of
    AddressFamilyIPv4: Result := (Address.Bytes[0] = 169) and (Address.Bytes[1] = 254);
    AddressFamilyIPv6: Result := (Address.Bytes[0] = $FE) and ((Address.Bytes[1] and $C0) = $80);
  else
    Result := False;
  end;
end;

function AddressIsMulticast(constref Address: TInternetAddress): Boolean;
begin
  case Address.Family of
    AddressFamilyIPv4: Result := (Address.Bytes[0] and $F0) = $E0;
    AddressFamilyIPv6: Result := Address.Bytes[0] = $FF;
  else
    Result := False;
  end;
end;

function AddressesSharePrefix(constref First, Second: TInternetAddress; PrefixLength: LongWord): Boolean;
var
  WholeBytes: LongWord;
  RemainingBits: LongWord;
  Mask: Byte;
begin
  if First.Family <> Second.Family then
    Exit(False);
  if PrefixLength > 128 then
    PrefixLength := 128;
  WholeBytes := PrefixLength div 8;
  RemainingBits := PrefixLength mod 8;
  if not MemoryIsEqual(@First.Bytes[0], @Second.Bytes[0], WholeBytes) then
    Exit(False);
  if RemainingBits = 0 then
    Exit(True);
  Mask := Byte($FF shl (8 - RemainingBits));
  Result := (First.Bytes[WholeBytes] and Mask) = (Second.Bytes[WholeBytes] and Mask);
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

function HexadecimalDigitValue(Character: Char; out Value: LongWord): Boolean;
begin
  Result := True;
  if (Character >= '0') and (Character <= '9') then
    Value := Ord(Character) - Ord('0')
  else if (Character >= 'a') and (Character <= 'f') then
    Value := Ord(Character) - Ord('a') + 10
  else if (Character >= 'A') and (Character <= 'F') then
    Value := Ord(Character) - Ord('A') + 10
  else
    Result := False;
end;

{ The groups of one side of "::" (or of a whole address), each up to
  four hexadecimal digits, separated by single colons; the last may be a
  dotted quad (two groups). Stops before "::" or at the end; Count says
  how many groups were read. }
function ParseIpv6Groups(Text: PChar; var Position: PtrUInt; out Groups: array of Word;
  out Count: Integer): Boolean;
var
  Digits: Integer;
  Value: LongWord;
  DigitValue: LongWord;
  QuadPosition: PtrUInt;
  Quad: TInternetAddress;
begin
  Count := 0;
  repeat
    if Count > High(Groups) then
      Exit(False);
    QuadPosition := Position;
    if (Count < High(Groups)) and ParseQuadAt(Text, QuadPosition, Quad) and (Text[QuadPosition] = #0) then
    begin
      Groups[Count] := (Word(Quad.Bytes[0]) shl 8) or Quad.Bytes[1];
      Groups[Count + 1] := (Word(Quad.Bytes[2]) shl 8) or Quad.Bytes[3];
      Inc(Count, 2);
      Position := QuadPosition;
      Exit(True);
    end;
    Digits := 0;
    Value := 0;
    while HexadecimalDigitValue(Text[Position], DigitValue) do
    begin
      if Digits = 4 then
        Exit(False);
      Value := Value * 16 + DigitValue;
      Inc(Digits);
      Inc(Position);
    end;
    if Digits = 0 then
      Exit(False);
    Groups[Count] := Word(Value);
    Inc(Count);
    if (Text[Position] <> ':') or (Text[Position + 1] = ':') then
      Exit(True);
    Inc(Position);
  until False;
end;

function ParseIpv6Address(Text: PChar; out Address: TInternetAddress): Boolean;
var
  Position: PtrUInt;
  Front: array[0..7] of Word;
  Back: array[0..7] of Word;
  FrontCount: Integer;
  BackCount: Integer;
  HasGap: Boolean;
  Index: Integer;
  Groups: array[0..7] of Word;
begin
  FillMemory(@Address, SizeOf(Address), 0);
  Address.Family := AddressFamilyIPv6;
  Result := False;
  if Text = nil then
    Exit;
  Position := 0;
  FrontCount := 0;
  BackCount := 0;
  HasGap := False;
  if not ((Text[0] = ':') and (Text[1] = ':')) then
    if not ParseIpv6Groups(Text, Position, Front, FrontCount) then
      Exit;
  if (Text[Position] = ':') and (Text[Position + 1] = ':') then
  begin
    HasGap := True;
    Inc(Position, 2);
    if Text[Position] <> #0 then
      if not ParseIpv6Groups(Text, Position, Back, BackCount) then
        Exit;
  end;
  if Text[Position] <> #0 then
    Exit;
  if HasGap then
  begin
    if FrontCount + BackCount > 7 then
      Exit;
  end
  else if FrontCount <> 8 then
    Exit;
  for Index := 0 to 7 do
    Groups[Index] := 0;
  for Index := 0 to FrontCount - 1 do
    Groups[Index] := Front[Index];
  for Index := 0 to BackCount - 1 do
    Groups[8 - BackCount + Index] := Back[Index];
  for Index := 0 to 7 do
  begin
    Address.Bytes[Index * 2] := Byte(Groups[Index] shr 8);
    Address.Bytes[Index * 2 + 1] := Byte(Groups[Index]);
  end;
  Result := True;
end;

function ParseInternetAddress(Text: PChar; out Address: TInternetAddress): Boolean;
begin
  Result := ParseIpv4Address(Text, Address);
  if not Result then
    Result := ParseIpv6Address(Text, Address);
end;

{ An IPv6 address with an optional "/N" (N up to 128). }
function ParseIpv6AddressWithPrefix(Text: PChar; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
var
  AddressText: array[0..InternetAddressTextCapacity - 1] of Char;
  Length: PtrUInt;
  Position: PtrUInt;
begin
  PrefixLength := 128;
  HasPrefix := False;
  Length := 0;
  while (Text[Length] <> #0) and (Text[Length] <> '/') do
    Inc(Length);
  if Length >= InternetAddressTextCapacity then
    Exit(False);
  CopyMemory(@AddressText[0], Text, Length);
  AddressText[Length] := #0;
  if not ParseIpv6Address(@AddressText[0], Address) then
    Exit(False);
  Position := Length;
  if Text[Position] = '/' then
  begin
    Inc(Position);
    if not ParseSmallNumber(Text, Position, 128, PrefixLength) then
      Exit(False);
    HasPrefix := True;
  end;
  Result := Text[Position] = #0;
end;

function ParseAddressWithPrefix(Text: PChar; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
var
  Position: PtrUInt;
begin
  PrefixLength := 32;
  HasPrefix := False;
  Position := 0;
  if Text = nil then
    Exit(False);
  if not ParseQuadAt(Text, Position, Address) then
    Exit(ParseIpv6AddressWithPrefix(Text, Address, PrefixLength, HasPrefix));
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

procedure AppendTextTo(Text: PChar; Capacity: PtrUInt; Addition: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Text);
  if Length + 1 < Capacity then
    CopyText(@Text[Length], Addition, Capacity - Length);
end;

procedure FormatIpv4Text(constref Address: TInternetAddress; Text: PChar; Capacity: PtrUInt);
var
  Number: TNumberText;
  Part: Integer;
begin
  Text[0] := #0;
  for Part := 0 to 3 do
  begin
    AppendTextTo(Text, Capacity, FormatDecimal(Address.Bytes[Part], Number));
    if Part < 3 then
      AppendTextTo(Text, Capacity, '.');
  end;
end;

{ The longest run of two or more zero groups (RFC 5952: the first of
  equal ones); First is -1 if there is none. }
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

procedure FormatIpv6Text(constref Address: TInternetAddress; Text: PChar; Capacity: PtrUInt);
const
  LowerDigits: PChar = '0123456789abcdef';
var
  Groups: array[0..7] of Word;
  Index: Integer;
  RunFirst: Integer;
  RunCount: Integer;
  Group: array[0..4] of Char;
  Digit: Integer;
  Started: Boolean;
  GroupLength: Integer;
begin
  for Index := 0 to 7 do
    Groups[Index] := (Word(Address.Bytes[Index * 2]) shl 8) or Address.Bytes[Index * 2 + 1];
  FindLongestZeroRun(Groups, RunFirst, RunCount);
  Text[0] := #0;
  Index := 0;
  while Index < 8 do
  begin
    if Index = RunFirst then
    begin
      AppendTextTo(Text, Capacity, '::');
      Index := Index + RunCount;
      Continue;
    end;
    if (Index > 0) and (Index <> RunFirst + RunCount) then
      AppendTextTo(Text, Capacity, ':');
    GroupLength := 0;
    Started := False;
    for Digit := 3 downto 0 do
      if Started or (((Groups[Index] shr (Digit * 4)) and $F) <> 0) or (Digit = 0) then
      begin
        Started := True;
        Group[GroupLength] := LowerDigits[(Groups[Index] shr (Digit * 4)) and $F];
        Inc(GroupLength);
      end;
    Group[GroupLength] := #0;
    AppendTextTo(Text, Capacity, @Group[0]);
    Inc(Index);
  end;
end;

function FormatInternetAddress(constref Address: TInternetAddress; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
begin
  Result := Buffer;
  if Capacity = 0 then
    Exit;
  case Address.Family of
    AddressFamilyIPv4: FormatIpv4Text(Address, @Text[0], InternetAddressTextCapacity);
    AddressFamilyIPv6: FormatIpv6Text(Address, @Text[0], InternetAddressTextCapacity);
  else
    CopyText(@Text[0], '?', InternetAddressTextCapacity);
  end;
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
  if SocketAddress.Family = AddressFamilyIPv6 then
  begin
    Text[0] := '[';
    FormatInternetAddress(SocketAddressHost(SocketAddress), @Text[1], SocketAddressTextCapacity - 1);
    Length := TextLength(@Text[0]);
    Text[Length] := ']';
    Inc(Length);
  end
  else
  begin
    FormatInternetAddress(SocketAddressHost(SocketAddress), @Text[0], SocketAddressTextCapacity);
    Length := TextLength(@Text[0]);
  end;
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
