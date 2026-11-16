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
  came, at most 8 datagrams at once for 60 s each (the oldest pushed out
  by a ninth).

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
  MaximumIpv6Reassemblies = 8;
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
  Network.Statistics;

const
  FixedHeaderBytes = 40;
  FragmentHeaderBytes = 8;
  BlockBytes = 8;
  BlockCount = (MaximumIpv6Payload + BlockBytes - 1) div BlockBytes;
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
    Received: array[0..(BlockCount + 7) div 8 - 1] of Byte;
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

function FindReassembly(constref Datagram: TIpDatagram; Identification: LongWord): PReassembly;
var
  Index: Integer;
  Free: PReassembly;
  Oldest: PReassembly;
begin
  Free := nil;
  Oldest := nil;
  for Index := 0 to MaximumIpv6Reassemblies - 1 do
  begin
    Result := @Reassemblies[Index];
    if not Result^.InUse then
    begin
      if Free = nil then
        Free := Result;
      Continue;
    end;
    if Matches(Result, Datagram, Identification) then
      Exit;
    if (Oldest = nil) or (Result^.Deadline < Oldest^.Deadline) then
      Oldest := Result;
  end;
  if Free = nil then
  begin
    Inc(NetworkStatistics.Ipv6.ReassemblyFailures);
    ReleaseReassembly(Oldest);
    Free := Oldest;
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

procedure MarkBlocks(Reassembly: PReassembly; Offset, Length: LongWord);
var
  Block: LongWord;
  LastBlock: LongWord;
begin
  if Length = 0 then
    Exit;
  Block := Offset div BlockBytes;
  LastBlock := (Offset + Length - 1) div BlockBytes;
  while Block <= LastBlock do
  begin
    Reassembly^.Received[Block div 8] := Reassembly^.Received[Block div 8] or (1 shl (Block mod 8));
    Inc(Block);
  end;
end;

function IsComplete(Reassembly: PReassembly): Boolean;
var
  Block: LongWord;
  Blocks: LongWord;
begin
  if (Reassembly^.PayloadLength = 0) or not Reassembly^.HasFirst then
    Exit(False);
  Blocks := (Reassembly^.PayloadLength + BlockBytes - 1) div BlockBytes;
  Block := 0;
  while Block < Blocks do
  begin
    if (Reassembly^.Received[Block div 8] and (1 shl (Block mod 8))) = 0 then
      Exit(False);
    Inc(Block);
  end;
  Result := True;
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
     (Walk.MoreFragments and (((Length mod BlockBytes) <> 0) or (Length = 0))) then
    Exit;
  Reassembly := FindReassembly(Datagram, Walk.Identification);
  if Reassembly = nil then
    Exit;
  CopyMemory(Reassembly^.Payload + Walk.FragmentOffset, Datagram.Header + DataStart, Length);
  MarkBlocks(Reassembly, Walk.FragmentOffset, Length);
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
