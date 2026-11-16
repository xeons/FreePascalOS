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
  Byte rings: the send and receive buffers of a TCP connection.

  A ring holds up to Capacity bytes in a heap block; bytes are added at
  the end and taken from the front, and any stretch can be copied out
  from an offset without taking it (the send buffer keeps what was sent
  until it is acknowledged, and retransmits from it).
}
unit Network.ByteRings;

{$mode objfpc}
{$pointermath on}

interface

type
  PByteRing = ^TByteRing;
  TByteRing = record
    Data: PByte;
    Capacity: LongWord;
    { Where the first byte is, and how many there are. }
    Start: LongWord;
    Count: LongWord;
  end;

function CreateByteRing(out Ring: TByteRing; Capacity: LongWord): Boolean;
procedure DestroyByteRing(var Ring: TByteRing);
function ByteRingFreeSpace(constref Ring: TByteRing): LongWord;
{ Adds up to Length bytes at the end; returns how many fitted. }
function AppendToByteRing(var Ring: TByteRing; Source: PByte; Length: LongWord): LongWord;
{ Copies Length bytes starting Offset bytes from the front (all of
  them must be there). }
procedure CopyFromByteRing(constref Ring: TByteRing; Offset: LongWord; Destination: PByte; Length: LongWord);
{ Drops Length bytes from the front. }
procedure DiscardFromByteRing(var Ring: TByteRing; Length: LongWord);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

function CreateByteRing(out Ring: TByteRing; Capacity: LongWord): Boolean;
begin
  Ring.Data := PByte(AllocateKernelMemory(Capacity));
  Ring.Capacity := Capacity;
  Ring.Start := 0;
  Ring.Count := 0;
  Result := Ring.Data <> nil;
  if not Result then
    Ring.Capacity := 0;
end;

procedure DestroyByteRing(var Ring: TByteRing);
begin
  if Ring.Data <> nil then
    FreeKernelMemory(Ring.Data);
  Ring.Data := nil;
  Ring.Capacity := 0;
  Ring.Start := 0;
  Ring.Count := 0;
end;

function ByteRingFreeSpace(constref Ring: TByteRing): LongWord;
begin
  Result := Ring.Capacity - Ring.Count;
end;

function AppendToByteRing(var Ring: TByteRing; Source: PByte; Length: LongWord): LongWord;
var
  WritePosition: LongWord;
  FirstPart: LongWord;
begin
  Result := Length;
  if Result > ByteRingFreeSpace(Ring) then
    Result := ByteRingFreeSpace(Ring);
  if Result = 0 then
    Exit;
  WritePosition := (Ring.Start + Ring.Count) mod Ring.Capacity;
  FirstPart := Ring.Capacity - WritePosition;
  if FirstPart > Result then
    FirstPart := Result;
  CopyMemory(Ring.Data + WritePosition, Source, FirstPart);
  if Result > FirstPart then
    CopyMemory(Ring.Data, Source + FirstPart, Result - FirstPart);
  Ring.Count := Ring.Count + Result;
end;

procedure CopyFromByteRing(constref Ring: TByteRing; Offset: LongWord; Destination: PByte; Length: LongWord);
var
  ReadPosition: LongWord;
  FirstPart: LongWord;
begin
  if Length = 0 then
    Exit;
  ReadPosition := (Ring.Start + Offset) mod Ring.Capacity;
  FirstPart := Ring.Capacity - ReadPosition;
  if FirstPart > Length then
    FirstPart := Length;
  CopyMemory(Destination, Ring.Data + ReadPosition, FirstPart);
  if Length > FirstPart then
    CopyMemory(Destination + FirstPart, Ring.Data, Length - FirstPart);
end;

procedure DiscardFromByteRing(var Ring: TByteRing; Length: LongWord);
begin
  if Length > Ring.Count then
    Length := Ring.Count;
  Ring.Start := (Ring.Start + Length) mod Ring.Capacity;
  Ring.Count := Ring.Count - Length;
  if Ring.Count = 0 then
    Ring.Start := 0;
end;

end.
