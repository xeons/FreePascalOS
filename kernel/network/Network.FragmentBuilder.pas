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
  Cutting an IPv6 datagram into fragments (RFC 8200 4.5), as the source
  does when the datagram is larger than the path MTU.

  The unfragmentable part is the IPv6 header and a hop-by-hop options
  header if one follows it (this machine sends no routing header); the
  rest is cut into pieces that keep each fragment within the MTU, a
  multiple of eight bytes but the last. Each fragment is the
  unfragmentable part (its last next header now 44, the payload length
  its own), the fragment header (the next header of the fragmentable
  part, the offset in eight-byte units, "more fragments", the
  identification) and its piece.

  Works on a whole datagram in a buffer and writes one fragment at a
  time into another, so the caller can put each in a packet of its own.
  Self-contained, so the host tests use it as it is.
}
unit Network.FragmentBuilder;

{$mode objfpc}
{$pointermath on}

interface

const
  FragmentIpv6HeaderBytes = 40;
  FragmentHeaderBytes = 8;
  NextHeaderHopByHopOptions = 0;
  NextHeaderFragmentHeader = 44;

type
  TFragmentPlan = record
    { The IPv6 header and what may not be fragmented after it. }
    UnfragmentableBytes: LongWord;
    { Where the next header that the fragment header takes over is
      (the IPv6 header's, or the hop-by-hop header's first byte). }
    NextHeaderPosition: LongWord;
    FragmentableBytes: LongWord;
    { The most of the fragmentable part one fragment carries. }
    PieceBytes: LongWord;
    FragmentCount: LongWord;
  end;

{ Plans the fragments of the datagram (Length bytes, header first) for
  Mtu. False if it cannot be cut (malformed, or an MTU too small for
  even eight bytes a fragment). }
function PlanIpv6Fragments(Datagram: PByte; Length, Mtu: LongWord; out Plan: TFragmentPlan): Boolean;
{ Writes fragment Index (from 0) of the plan into Output (room for the
  MTU); returns its length. }
function BuildIpv6Fragment(Datagram: PByte; constref Plan: TFragmentPlan; Index, Identification: LongWord;
  Output: PByte): LongWord;

implementation

procedure CopyBytes(Source, Destination: PByte; Count: LongWord);
var
  Position: LongWord;
begin
  Position := 0;
  while Position < Count do
  begin
    Destination[Position] := Source[Position];
    Inc(Position);
  end;
end;

function PlanIpv6Fragments(Datagram: PByte; Length, Mtu: LongWord; out Plan: TFragmentPlan): Boolean;
var
  HopByHopBytes: LongWord;
begin
  Plan.UnfragmentableBytes := FragmentIpv6HeaderBytes;
  Plan.NextHeaderPosition := 6;
  Plan.FragmentableBytes := 0;
  Plan.PieceBytes := 0;
  Plan.FragmentCount := 0;
  if Length < FragmentIpv6HeaderBytes then
    Exit(False);
  if Datagram[6] = NextHeaderHopByHopOptions then
  begin
    if Length < FragmentIpv6HeaderBytes + 2 then
      Exit(False);
    HopByHopBytes := (LongWord(Datagram[FragmentIpv6HeaderBytes + 1]) + 1) * 8;
    Plan.NextHeaderPosition := FragmentIpv6HeaderBytes;
    Plan.UnfragmentableBytes := FragmentIpv6HeaderBytes + HopByHopBytes;
    if Plan.UnfragmentableBytes > Length then
      Exit(False);
  end;
  Plan.FragmentableBytes := Length - Plan.UnfragmentableBytes;
  if Mtu < Plan.UnfragmentableBytes + FragmentHeaderBytes + 8 then
    Exit(False);
  Plan.PieceBytes := ((Mtu - Plan.UnfragmentableBytes - FragmentHeaderBytes) div 8) * 8;
  if Plan.FragmentableBytes = 0 then
    Plan.FragmentCount := 1
  else
    Plan.FragmentCount := (Plan.FragmentableBytes + Plan.PieceBytes - 1) div Plan.PieceBytes;
  Result := True;
end;

function BuildIpv6Fragment(Datagram: PByte; constref Plan: TFragmentPlan; Index, Identification: LongWord;
  Output: PByte): LongWord;
var
  Offset: LongWord;
  Piece: LongWord;
  FragmentHeader: PByte;
  PayloadLength: LongWord;
  OffsetField: LongWord;
begin
  Offset := Index * Plan.PieceBytes;
  Piece := Plan.PieceBytes;
  if Offset + Piece > Plan.FragmentableBytes then
    Piece := Plan.FragmentableBytes - Offset;
  CopyBytes(Datagram, Output, Plan.UnfragmentableBytes);
  FragmentHeader := Output + Plan.UnfragmentableBytes;
  FragmentHeader[0] := Datagram[Plan.NextHeaderPosition];
  FragmentHeader[1] := 0;
  OffsetField := (Offset div 8) shl 3;
  if Index + 1 < Plan.FragmentCount then
    OffsetField := OffsetField or 1;
  FragmentHeader[2] := Byte(OffsetField shr 8);
  FragmentHeader[3] := Byte(OffsetField);
  FragmentHeader[4] := Byte(Identification shr 24);
  FragmentHeader[5] := Byte(Identification shr 16);
  FragmentHeader[6] := Byte(Identification shr 8);
  FragmentHeader[7] := Byte(Identification);
  CopyBytes(Datagram + Plan.UnfragmentableBytes + Offset, FragmentHeader + FragmentHeaderBytes, Piece);
  Output[Plan.NextHeaderPosition] := NextHeaderFragmentHeader;
  Result := Plan.UnfragmentableBytes + FragmentHeaderBytes + Piece;
  PayloadLength := Result - FragmentIpv6HeaderBytes;
  Output[4] := Byte(PayloadLength shr 8);
  Output[5] := Byte(PayloadLength);
end;

end.
