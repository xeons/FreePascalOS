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
  Putting fragmented IPv6 datagrams together (RFC 8200 4.5), as
  Network.Fragments does for IPv4: one buffer per datagram (source,
  destination and identification), a bitmap of the 8-byte blocks that
  came (Network.ReassemblyBlocks), at most 16 datagrams at once for 60 s
  each. Senders of one /64 hold at most 4 of them: a fifth pushes out
  their own oldest, so one flooding source cannot push out the others';
  past that, the oldest of all gives way.

  RFC 5722: a fragment that overlaps one that came (or disagrees about
  where the datagram ends) gives up the whole datagram, silently; an
  exact copy of one that came is dropped alone. RFC 8200 4.5: the first
  fragment must hold the whole header chain up to the upper-layer
  header (Network.Ipv6 checks it before handing the fragment here).

  The whole datagram is a fixed header (from the fragments, its next
  header the first fragment's, its payload length the new one) followed
  by the fragmentable part; the extension headers that came before the
  fragment header were looked at already and are left out.
}
unit Network.Ipv6Fragments;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.IpDatagrams,
  Network.Ipv6Headers;

const
  MaximumIpv6Reassemblies = 16;
  { Reassemblies the senders of one /64 may hold. }
  MaximumReassembliesPerPrefix = 4;
  ReassemblyPrefixLength = 64;
  Ipv6ReassemblySeconds = 60;
  MaximumIpv6Payload = 65535;

{ A fragment of Datagram (Walk found its fragment header). True once the
  datagram is whole: Whole is then a new kernel heap block holding it,
  the fixed header first, WholeLength bytes long, for the caller to
  free. }
function AddIpv6Fragment(constref Datagram: TIpDatagram; constref Walk: TIpv6HeaderWalk; out Whole: PByte;
  out WholeLength: LongWord): Boolean;
{ On the network thread: drops what took too long. }
procedure RunIpv6ReassemblyTimers(Now: QWord);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Network.ByteOrder,
  Network.Ipv6Addresses,
  Network.Core,
  Network.ReassemblyBlocks,
  Network.Statistics;

const
  FixedHeaderBytes = 40;
  FragmentHeaderBytes = 8;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;

type
  PReassembly = ^TReassembly;
  TReassembly = record
    InUse: Boolean;
    Source: TIpv6Address;
    Destination: TIpv6Address;
    Identification: LongWord;
    FixedHeader: array[0..FixedHeaderBytes - 1] of Byte;
    { The first fragment came: NextHeader is known. }
    HasFirst: Boolean;
    NextHeader: Byte;
    Payload: PByte;
    { 0 until the last fragment came. }
    PayloadLength: LongWord;
    Received: TReassemblyBlocks;
    Deadline: QWord;
  end;

var
  Reassemblies: array[0..MaximumIpv6Reassemblies - 1] of TReassembly;

procedure ReleaseReassembly(Reassembly: PReassembly);
begin
  FreeKernelMemory(Reassembly^.Payload);
  Reassembly^.Payload := nil;
  Reassembly^.InUse := False;
end;

function Matches(Reassembly: PReassembly; constref Datagram: TIpDatagram; Identification: LongWord): Boolean;
begin
  Result := Reassembly^.InUse and (Reassembly^.Identification = Identification) and
    Ipv6AddressesEqual(Reassembly^.Source, Datagram.Source6) and
    Ipv6AddressesEqual(Reassembly^.Destination, Datagram.Destination6);
end;

{ The oldest reassembly in use, of all or (Prefix not nil) of senders
  in the /64 of Prefix^; and how many such there are. }
function OldestReassembly(Prefix: PIpv6Address; out Count: Integer): PReassembly;
var
  Index: Integer;
  Candidate: PReassembly;
begin
  Result := nil;
  Count := 0;
  for Index := 0 to MaximumIpv6Reassemblies - 1 do
  begin
    Candidate := @Reassemblies[Index];
    if not Candidate^.InUse or
       ((Prefix <> nil) and not SameIpv6Prefix(Candidate^.Source, Prefix^, ReassemblyPrefixLength)) then
      Continue;
    Inc(Count);
    if (Result = nil) or (Candidate^.Deadline < Result^.Deadline) then
      Result := Candidate;
  end;
end;

function FreeReassembly: PReassembly;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6Reassemblies - 1 do
    if not Reassemblies[Index].InUse then
      Exit(@Reassemblies[Index]);
  Result := nil;
end;

function FindReassembly(constref Datagram: TIpDatagram; Identification: LongWord): PReassembly;
var
  Index: Integer;
  Free: PReassembly;
  Sender: TIpv6Address;
  Count: Integer;
  Oldest: PReassembly;
begin
  for Index := 0 to MaximumIpv6Reassemblies - 1 do
  begin
    Result := @Reassemblies[Index];
    if Matches(Result, Datagram, Identification) then
      Exit;
  end;
  Sender := Datagram.Source6;
  Oldest := OldestReassembly(@Sender, Count);
  if Count >= MaximumReassembliesPerPrefix then
    Free := Oldest
  else
  begin
    Free := FreeReassembly;
    if Free = nil then
      Free := OldestReassembly(nil, Count);
  end;
  if Free^.InUse then
  begin
    Inc(NetworkStatistics.Ipv6.ReassemblyFailures);
    ReleaseReassembly(Free);
  end;
  Result := Free;
  FillMemory(Result, SizeOf(TReassembly), 0);
  Result^.Payload := PByte(AllocateKernelMemory(MaximumIpv6Payload));
  if Result^.Payload = nil then
    Exit(nil);
  Result^.InUse := True;
  Result^.Source := Datagram.Source6;
  Result^.Destination := Datagram.Destination6;
  Result^.Identification := Identification;
  CopyMemory(@Result^.FixedHeader[0], Datagram.Header, FixedHeaderBytes);
  Result^.Deadline := NetworkNow + Ipv6ReassemblySeconds * NanosecondsPerSecond;
  RequestNetworkWakeAt(Result^.Deadline);
end;

function IsComplete(Reassembly: PReassembly): Boolean;
begin
  Result := Reassembly^.HasFirst and ReassemblyBlocksComplete(Reassembly^.Received, Reassembly^.PayloadLength);
end;

function BuildWhole(Reassembly: PReassembly; out WholeLength: LongWord): PByte;
begin
  WholeLength := FixedHeaderBytes + Reassembly^.PayloadLength;
  Result := PByte(AllocateKernelMemory(WholeLength));
  if Result = nil then
    Exit;
  CopyMemory(Result, @Reassembly^.FixedHeader[0], FixedHeaderBytes);
  WriteBigEndian16(Result + 4, Word(Reassembly^.PayloadLength));
  Result[6] := Reassembly^.NextHeader;
  CopyMemory(Result + FixedHeaderBytes, Reassembly^.Payload, Reassembly^.PayloadLength);
end;

function AddIpv6Fragment(constref Datagram: TIpDatagram; constref Walk: TIpv6HeaderWalk; out Whole: PByte;
  out WholeLength: LongWord): Boolean;
var
  Reassembly: PReassembly;
  DataStart: LongWord;
  Length: LongWord;
begin
  Whole := nil;
  WholeLength := 0;
  Result := False;
  DataStart := Walk.Offset + FragmentHeaderBytes;
  if DataStart > Datagram.TotalLength then
    Exit;
  Length := Datagram.TotalLength - DataStart;
  if (Walk.FragmentOffset + Length > MaximumIpv6Payload) or
     (Walk.MoreFragments and (((Length mod ReassemblyBlockBytes) <> 0) or (Length = 0))) then
    Exit;
  Reassembly := FindReassembly(Datagram, Walk.Identification);
  if Reassembly = nil then
    Exit;
  case ClassifyFragment(Reassembly^.Received, Walk.FragmentOffset, Length, Walk.MoreFragments,
    Reassembly^.PayloadLength) of
    FragmentDuplicate:
      begin
        { An exact copy is dropped alone; different bytes over the same
          blocks are an overlap. }
        if not MemoryIsEqual(Reassembly^.Payload + Walk.FragmentOffset, Datagram.Header + DataStart, Length) then
        begin
          Inc(NetworkStatistics.Ipv6.ReassemblyFailures);
          ReleaseReassembly(Reassembly);
        end;
        Exit;
      end;
    FragmentOverlaps:
      begin
        Inc(NetworkStatistics.Ipv6.ReassemblyFailures);
        ReleaseReassembly(Reassembly);
        Exit;
      end;
  end;
  CopyMemory(Reassembly^.Payload + Walk.FragmentOffset, Datagram.Header + DataStart, Length);
  MarkReassemblyBlocks(Reassembly^.Received, Walk.FragmentOffset, Length);
  if Walk.FragmentOffset = 0 then
  begin
    Reassembly^.HasFirst := True;
    Reassembly^.NextHeader := Walk.NextHeader;
  end;
  if not Walk.MoreFragments then
    Reassembly^.PayloadLength := Walk.FragmentOffset + Length;
  if not IsComplete(Reassembly) then
    Exit;
  Whole := BuildWhole(Reassembly, WholeLength);
  ReleaseReassembly(Reassembly);
  Result := Whole <> nil;
end;

procedure RunIpv6ReassemblyTimers(Now: QWord);
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6Reassemblies - 1 do
  begin
    if not Reassemblies[Index].InUse then
      Continue;
    if Reassemblies[Index].Deadline <= Now then
    begin
      Inc(NetworkStatistics.Ipv6.ReassemblyFailures);
      ReleaseReassembly(@Reassemblies[Index]);
    end
    else
      RequestNetworkWakeAt(Reassemblies[Index].Deadline);
  end;
end;

end.
