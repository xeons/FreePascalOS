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
  Putting fragmented IPv4 datagrams together again (RFC 815).

  The fragments of a datagram (same source, destination, protocol and
  identification) are copied into one buffer as they come, in any
  order, and a bitmap of 8-byte blocks records what has arrived. The
  last fragment (no "more fragments") gives the total length; once
  every block up to it is there, the datagram is whole. At most
  MaximumReassemblies datagrams are put together at once, each for at
  most ReassemblySeconds; then what arrived of it is dropped. Used
  under the network lock.
}
unit Network.Fragments;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv4,
  Network.IpDatagrams;

const
  MaximumReassemblies = 8;
  ReassemblySeconds = 30;
  MaximumDatagramLength = 65535;

{ A fragment of Datagram (its header gives the addresses and protocol)
  at Offset bytes into the payload. True once the datagram is whole:
  Whole is then a new kernel heap block holding it, a 20-byte header
  first, WholeLength bytes long, for the caller to free. }
function AddFragment(constref Datagram: TIpDatagram; Identification: Word; Offset: LongWord;
  MoreFragments: Boolean; out Whole: PByte; out WholeLength: LongWord): Boolean;
{ On the network thread: drops what took too long. }
procedure RunReassemblyTimers(Now: QWord);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Network.ByteOrder,
  Network.Checksums,
  Network.Addresses,
  Network.Core,
  Network.Statistics;

const
  BlockBytes = 8;
  BlockCount = (MaximumDatagramLength + BlockBytes - 1) div BlockBytes;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;

type
  PReassembly = ^TReassembly;
  TReassembly = record
    InUse: Boolean;
    Source: TIpv4Address;
    Destination: TIpv4Address;
    Protocol: Byte;
    Identification: Word;
    { The payload as it arrives. }
    Payload: PByte;
    { 0 until the last fragment came. }
    PayloadLength: LongWord;
    Received: array[0..(BlockCount + 7) div 8 - 1] of Byte;
    Deadline: QWord;
  end;

var
  Reassemblies: array[0..MaximumReassemblies - 1] of TReassembly;

procedure ReleaseReassembly(Reassembly: PReassembly);
begin
  FreeKernelMemory(Reassembly^.Payload);
  Reassembly^.Payload := nil;
  Reassembly^.InUse := False;
end;

function FindReassembly(constref Datagram: TIpDatagram; Identification: Word): PReassembly;
var
  Index: Integer;
  Free: PReassembly;
  Oldest: PReassembly;
begin
  Free := nil;
  Oldest := nil;
  for Index := 0 to MaximumReassemblies - 1 do
  begin
    Result := @Reassemblies[Index];
    if not Result^.InUse then
    begin
      if Free = nil then
        Free := Result;
      Continue;
    end;
    if (Result^.Source = Datagram.Source) and (Result^.Destination = Datagram.Destination) and
       (Result^.Protocol = Datagram.Protocol) and (Result^.Identification = Identification) then
      Exit;
    if (Oldest = nil) or (Result^.Deadline < Oldest^.Deadline) then
      Oldest := Result;
  end;
  { A new one: a free slot, else the one that has waited longest. }
  if Free = nil then
  begin
    Inc(NetworkStatistics.Ip.ReassemblyFailures);
    ReleaseReassembly(Oldest);
    Free := Oldest;
  end;
  Result := Free;
  FillMemory(Result, SizeOf(TReassembly), 0);
  Result^.Payload := PByte(AllocateKernelMemory(MaximumDatagramLength));
  if Result^.Payload = nil then
    Exit(nil);
  Result^.InUse := True;
  Result^.Source := Datagram.Source;
  Result^.Destination := Datagram.Destination;
  Result^.Protocol := Datagram.Protocol;
  Result^.Identification := Identification;
  Result^.Deadline := NetworkNow + ReassemblySeconds * NanosecondsPerSecond;
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
  if Reassembly^.PayloadLength = 0 then
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

{ The whole datagram with a plain header in front. }
function BuildWhole(Reassembly: PReassembly; out WholeLength: LongWord): PByte;
begin
  WholeLength := Ipv4HeaderBytes + Reassembly^.PayloadLength;
  Result := PByte(AllocateKernelMemory(WholeLength));
  if Result = nil then
    Exit;
  FillMemory(Result, Ipv4HeaderBytes, 0);
  Result[0] := $45;
  WriteBigEndian16(Result + 2, Word(WholeLength));
  WriteBigEndian16(Result + 4, Reassembly^.Identification);
  Result[8] := 1;
  Result[9] := Reassembly^.Protocol;
  WriteIpv4Address(Result + 12, Reassembly^.Source);
  WriteIpv4Address(Result + 16, Reassembly^.Destination);
  WriteBigEndian16(Result + 10, InternetChecksum(Result, Ipv4HeaderBytes));
  CopyMemory(Result + Ipv4HeaderBytes, Reassembly^.Payload, Reassembly^.PayloadLength);
end;

function AddFragment(constref Datagram: TIpDatagram; Identification: Word; Offset: LongWord;
  MoreFragments: Boolean; out Whole: PByte; out WholeLength: LongWord): Boolean;
var
  Reassembly: PReassembly;
  Length: LongWord;
begin
  Whole := nil;
  WholeLength := 0;
  Result := False;
  Length := Datagram.TotalLength - Datagram.HeaderLength;
  { Every fragment but the last carries a multiple of 8 bytes. }
  if (Offset + Length > MaximumDatagramLength) or (MoreFragments and ((Length mod BlockBytes) <> 0)) or
     (MoreFragments and (Length = 0)) then
    Exit;
  Reassembly := FindReassembly(Datagram, Identification);
  if Reassembly = nil then
    Exit;
  CopyMemory(Reassembly^.Payload + Offset, Datagram.Header + Datagram.HeaderLength, Length);
  MarkBlocks(Reassembly, Offset, Length);
  if not MoreFragments then
    Reassembly^.PayloadLength := Offset + Length;
  if not IsComplete(Reassembly) then
    Exit;
  Whole := BuildWhole(Reassembly, WholeLength);
  ReleaseReassembly(Reassembly);
  Result := Whole <> nil;
end;

procedure RunReassemblyTimers(Now: QWord);
var
  Index: Integer;
begin
  for Index := 0 to MaximumReassemblies - 1 do
  begin
    if not Reassemblies[Index].InUse then
      Continue;
    if Reassemblies[Index].Deadline <= Now then
    begin
      Inc(NetworkStatistics.Ip.ReassemblyFailures);
      ReleaseReassembly(@Reassemblies[Index]);
    end
    else
      RequestNetworkWakeAt(Reassemblies[Index].Deadline);
  end;
end;

end.
