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
  Block cache.

  File systems read metadata (superblocks, allocation tables, directories,
  inodes) in small pieces at arbitrary byte offsets, and the same pieces
  are read again and again. The cache keeps recently used 4 KiB "lines" of
  each block device in memory and lets callers read any byte range,
  hiding the device's block size.

  Lines are found through a hash table and evicted least recently used
  first. One mutex protects the whole cache, so device reads issued for a
  cache miss are serialized; that keeps this first version simple.

  Writes are write-through: the cached line is updated and the affected
  device blocks are written immediately, so the disk never lags behind
  the cache and nothing needs to be flushed.
}
unit Io.BlockCache;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.BlockDevice;

const
  CacheLineSize = 4096;

procedure InitializeBlockCache;

{ Copies ByteCount bytes starting at ByteOffset on Device into Buffer.
  Returns False on a device error or when the range is past the end. }
function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;

{ Writes ByteCount bytes from Buffer at ByteOffset on Device, through the
  cache. Returns False on a device error. }
function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;

{ Writes ByteCount zero bytes at ByteOffset. }
function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;

{ Drops every cached line of Device (used when a volume is unmounted). }
procedure InvalidateCachedDevice(Device: PBlockDevice);

procedure WriteBlockCacheSummary;

implementation

uses
  Runtime.Memory,
  Runtime.LinkedList,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Panic,
  Debug.Output;

const
  LineCount = 1024;
  BucketCount = 1024;

type
  PCacheLine = ^TCacheLine;
  TCacheLine = record
    Device: PBlockDevice;
    LineNumber: QWord;
    Data: PByte;
    IsValid: Boolean;
    NextInBucket: PCacheLine;
    RecencyLink: TListEntry;
  end;

var
  Lines: PCacheLine;
  Buckets: array[0..BucketCount - 1] of PCacheLine;
  { Most recently used at the head, eviction candidates at the tail. }
  RecencyList: TListEntry;
  CacheLock: TMutex;
  HitCount: QWord;
  MissCount: QWord;

function LineFromRecencyLink(Entry: PListEntry): PCacheLine;
begin
  Result := PCacheLine(ContainingRecord(Entry, FieldOffset(PCacheLine(nil)^.RecencyLink)));
end;

function BucketIndex(Device: PBlockDevice; LineNumber: QWord): Integer;
var
  Mixed: QWord;
begin
  Mixed := (QWord(Device) shr 4) xor (LineNumber * QWord($9E3779B97F4A7C15));
  Result := Integer((Mixed shr 32) mod BucketCount);
end;

procedure InitializeBlockCache;
var
  LineIndex: Integer;
  PagePhysical: QWord;
begin
  InitializeMutex(CacheLock);
  InitializeListHead(RecencyList);
  HitCount := 0;
  MissCount := 0;

  Lines := PCacheLine(AllocateZeroedKernelMemory(LineCount * SizeOf(TCacheLine)));
  if Lines = nil then
    KernelPanic('no memory for the block cache');

  for LineIndex := 0 to LineCount - 1 do
  begin
    PagePhysical := AllocatePhysicalPage(PageUsageGeneral);
    if PagePhysical = 0 then
      KernelPanic('no memory for block cache pages');
    Lines[LineIndex].Data := PByte(PhysicalToVirtual(PagePhysical));
    Lines[LineIndex].IsValid := False;
    InsertAtTail(RecencyList, @Lines[LineIndex].RecencyLink);
  end;

  for LineIndex := 0 to BucketCount - 1 do
    Buckets[LineIndex] := nil;
end;

function FindLine(Device: PBlockDevice; LineNumber: QWord): PCacheLine;
var
  Line: PCacheLine;
begin
  Line := Buckets[BucketIndex(Device, LineNumber)];
  while Line <> nil do
  begin
    if (Line^.Device = Device) and (Line^.LineNumber = LineNumber) then
      Exit(Line);
    Line := Line^.NextInBucket;
  end;
  Result := nil;
end;

procedure RemoveFromBucket(Line: PCacheLine);
var
  Bucket: Integer;
  Previous: PCacheLine;
  Current: PCacheLine;
begin
  Bucket := BucketIndex(Line^.Device, Line^.LineNumber);
  Previous := nil;
  Current := Buckets[Bucket];
  while Current <> nil do
  begin
    if Current = Line then
    begin
      if Previous = nil then
        Buckets[Bucket] := Current^.NextInBucket
      else
        Previous^.NextInBucket := Current^.NextInBucket;
      Exit;
    end;
    Previous := Current;
    Current := Current^.NextInBucket;
  end;
end;

procedure MarkMostRecentlyUsed(Line: PCacheLine);
begin
  RemoveListEntry(@Line^.RecencyLink);
  InsertAtHead(RecencyList, @Line^.RecencyLink);
end;

{ Reads one line from the device. The last line of a device may be only
  partly backed by blocks; the rest is zero filled. }
function FillLine(Line: PCacheLine; Device: PBlockDevice; LineNumber: QWord): Boolean;
var
  BlocksPerLine: QWord;
  FirstBlock: QWord;
  BlocksToRead: QWord;
begin
  BlocksPerLine := CacheLineSize div Device^.BlockSize;
  FirstBlock := LineNumber * BlocksPerLine;
  if FirstBlock >= Device^.BlockCount then
    Exit(False);

  BlocksToRead := BlocksPerLine;
  if BlocksToRead > Device^.BlockCount - FirstBlock then
  begin
    BlocksToRead := Device^.BlockCount - FirstBlock;
    ZeroMemory(Line^.Data, CacheLineSize);
  end;

  Result := ReadBlocks(Device, FirstBlock, LongWord(BlocksToRead), Line^.Data);
end;

{ Returns the line holding LineNumber, reading it if needed. Called with
  the cache lock held. }
function GetLine(Device: PBlockDevice; LineNumber: QWord): PCacheLine;
var
  Line: PCacheLine;
begin
  Line := FindLine(Device, LineNumber);
  if Line <> nil then
  begin
    Inc(HitCount);
    MarkMostRecentlyUsed(Line);
    Exit(Line);
  end;

  Inc(MissCount);
  Line := LineFromRecencyLink(RecencyList.Previous);
  if Line^.IsValid then
    RemoveFromBucket(Line);
  Line^.IsValid := False;

  if not FillLine(Line, Device, LineNumber) then
    Exit(nil);

  Line^.Device := Device;
  Line^.LineNumber := LineNumber;
  Line^.IsValid := True;
  Line^.NextInBucket := Buckets[BucketIndex(Device, LineNumber)];
  Buckets[BucketIndex(Device, LineNumber)] := Line;
  MarkMostRecentlyUsed(Line);
  Result := Line;
end;

{ Devices whose blocks do not evenly divide a cache line bypass the cache. }
function DeviceIsCacheable(Device: PBlockDevice): Boolean;
begin
  Result := (Device^.BlockSize >= 512) and (Device^.BlockSize <= CacheLineSize) and
    ((CacheLineSize mod Device^.BlockSize) = 0);
end;

function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
var
  Destination: PByte;
  LineNumber: QWord;
  OffsetInLine: QWord;
  ChunkBytes: QWord;
  Line: PCacheLine;
begin
  if ByteCount = 0 then
    Exit(True);
  if (ByteOffset >= BlockDeviceSizeInBytes(Device)) or
     (ByteCount > BlockDeviceSizeInBytes(Device) - ByteOffset) then
    Exit(False);
  if not DeviceIsCacheable(Device) then
    Exit(False);

  Destination := PByte(Buffer);
  Result := True;
  AcquireMutex(CacheLock);
  while ByteCount > 0 do
  begin
    LineNumber := ByteOffset div CacheLineSize;
    OffsetInLine := ByteOffset mod CacheLineSize;
    ChunkBytes := CacheLineSize - OffsetInLine;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;

    Line := GetLine(Device, LineNumber);
    if Line = nil then
    begin
      Result := False;
      Break;
    end;
    CopyMemory(Destination, Line^.Data + OffsetInLine, ChunkBytes);

    Destination := Destination + ChunkBytes;
    ByteOffset := ByteOffset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  ReleaseMutex(CacheLock);
end;

{ Writes the device blocks of Line that overlap [OffsetInLine,
  OffsetInLine + ByteCount). }
function WriteLineRange(Line: PCacheLine; Device: PBlockDevice; OffsetInLine: QWord;
  ByteCount: QWord): Boolean;
var
  BlocksPerLine: QWord;
  FirstBlockInLine: QWord;
  LastBlockInLine: QWord;
begin
  BlocksPerLine := CacheLineSize div Device^.BlockSize;
  FirstBlockInLine := OffsetInLine div Device^.BlockSize;
  LastBlockInLine := (OffsetInLine + ByteCount - 1) div Device^.BlockSize;
  Result := WriteBlocks(Device, Line^.LineNumber * BlocksPerLine + FirstBlockInLine,
    LongWord(LastBlockInLine - FirstBlockInLine + 1),
    Line^.Data + FirstBlockInLine * Device^.BlockSize);
end;

{ Shared by CachedWrite and CachedWriteZeros: Source = nil writes zeros. }
function WriteThroughCache(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Source: PByte): Boolean;
var
  LineNumber: QWord;
  OffsetInLine: QWord;
  ChunkBytes: QWord;
  Line: PCacheLine;
begin
  if ByteCount = 0 then
    Exit(True);
  if (ByteOffset >= BlockDeviceSizeInBytes(Device)) or
     (ByteCount > BlockDeviceSizeInBytes(Device) - ByteOffset) then
    Exit(False);
  if not DeviceIsCacheable(Device) then
    Exit(False);

  Result := True;
  AcquireMutex(CacheLock);
  while ByteCount > 0 do
  begin
    LineNumber := ByteOffset div CacheLineSize;
    OffsetInLine := ByteOffset mod CacheLineSize;
    ChunkBytes := CacheLineSize - OffsetInLine;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;

    { The line is read first so that partially written device blocks keep
      their other bytes. }
    Line := GetLine(Device, LineNumber);
    if Line = nil then
    begin
      Result := False;
      Break;
    end;

    if Source <> nil then
    begin
      CopyMemory(Line^.Data + OffsetInLine, Source, ChunkBytes);
      Source := Source + ChunkBytes;
    end
    else
      ZeroMemory(Line^.Data + OffsetInLine, ChunkBytes);

    if not WriteLineRange(Line, Device, OffsetInLine, ChunkBytes) then
    begin
      { The cached copy no longer matches the disk. }
      RemoveFromBucket(Line);
      Line^.IsValid := False;
      Result := False;
      Break;
    end;

    ByteOffset := ByteOffset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  ReleaseMutex(CacheLock);
end;

function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
begin
  if (Buffer = nil) and (ByteCount > 0) then
    Exit(False);
  Result := WriteThroughCache(Device, ByteOffset, ByteCount, PByte(Buffer));
end;

function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
begin
  Result := WriteThroughCache(Device, ByteOffset, ByteCount, nil);
end;

procedure InvalidateCachedDevice(Device: PBlockDevice);
var
  LineIndex: Integer;
begin
  AcquireMutex(CacheLock);
  for LineIndex := 0 to LineCount - 1 do
  begin
    if Lines[LineIndex].IsValid and (Lines[LineIndex].Device = Device) then
    begin
      RemoveFromBucket(@Lines[LineIndex]);
      Lines[LineIndex].IsValid := False;
    end;
  end;
  ReleaseMutex(CacheLock);
end;

procedure WriteBlockCacheSummary;
begin
  DebugBeginMessage;
  DebugWriteTag('cache');
  DebugWriteDecimal(LineCount);
  DebugWrite(' lines of ');
  DebugWriteDecimal(CacheLineSize);
  DebugWrite(' bytes, ');
  DebugWriteDecimal(HitCount);
  DebugWrite(' hits, ');
  DebugWriteDecimal(MissCount);
  DebugWriteLine(' misses');
  DebugEndMessage;
end;

end.
