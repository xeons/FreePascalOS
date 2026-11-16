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
  The Internet checksum (RFC 1071): the ones' complement of the ones'
  complement sum of the data as 16-bit big-endian words, an odd last
  byte padded with zero. IPv4 headers, ICMP, ICMPv6, UDP and TCP use it;
  UDP, TCP and ICMPv6 also sum a pseudo-header (source and destination
  address, the protocol and the length) in front of their data.

  A sum is built in a 32-bit accumulator (AddToChecksum, which may be
  called for several pieces as long as every piece but the last has an
  even length) and finished by folding the carries back in and
  inverting (FinishChecksum). Data whose checksum field holds the right
  value sums to zero after finishing.
}
unit Network.Checksums;

{$mode objfpc}
{$pointermath on}

interface

const
  ChecksumStart = 0;

function AddToChecksum(Sum: LongWord; Data: PByte; Length: LongWord): LongWord;
function FinishChecksum(Sum: LongWord): Word;
{ The checksum of one piece of data. }
function InternetChecksum(Data: PByte; Length: LongWord): Word;
{ Starts a UDP or TCP checksum with the IPv4 pseudo-header (addresses in
  host order). }
function PseudoHeaderSum(Source, Destination: LongWord; Protocol: Byte; Length: LongWord): LongWord;
{ Starts a UDP, TCP or ICMPv6 checksum with the IPv6 pseudo-header
  (RFC 8200 8.1: the addresses as on the wire, the upper-layer length
  as 32 bits and the next header value). }
function Ipv6PseudoHeaderSum(Source, Destination: PByte; NextHeader: Byte; Length: LongWord): LongWord;

implementation

function AddToChecksum(Sum: LongWord; Data: PByte; Length: LongWord): LongWord;
var
  Index: LongWord;
  Total: QWord;
begin
  Total := Sum;
  Index := 0;
  while Index + 1 < Length do
  begin
    Total := Total + ((LongWord(Data[Index]) shl 8) or LongWord(Data[Index + 1]));
    Index := Index + 2;
  end;
  if Index < Length then
    Total := Total + (LongWord(Data[Index]) shl 8);
  { Keep it within 32 bits so that more pieces can follow. }
  while (Total shr 32) <> 0 do
    Total := (Total and $FFFFFFFF) + (Total shr 32);
  Result := LongWord(Total);
end;

function FinishChecksum(Sum: LongWord): Word;
begin
  while (Sum shr 16) <> 0 do
    Sum := (Sum and $FFFF) + (Sum shr 16);
  Result := Word(not Sum);
end;

function InternetChecksum(Data: PByte; Length: LongWord): Word;
begin
  Result := FinishChecksum(AddToChecksum(ChecksumStart, Data, Length));
end;

function PseudoHeaderSum(Source, Destination: LongWord; Protocol: Byte; Length: LongWord): LongWord;
var
  Total: QWord;
begin
  Total := (Source shr 16) + (Source and $FFFF) + (Destination shr 16) + (Destination and $FFFF) +
    Protocol + Length;
  Result := LongWord(Total);
end;

function Ipv6PseudoHeaderSum(Source, Destination: PByte; NextHeader: Byte; Length: LongWord): LongWord;
var
  Sum: LongWord;
  Total: QWord;
begin
  Sum := AddToChecksum(ChecksumStart, Source, 16);
  Sum := AddToChecksum(Sum, Destination, 16);
  Total := QWord(Sum) + (Length shr 16) + (Length and $FFFF) + NextHeader;
  while (Total shr 32) <> 0 do
    Total := (Total and $FFFFFFFF) + (Total shr 32);
  Result := LongWord(Total);
end;

end.
