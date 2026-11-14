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
  each block device in memory and lets callers read and write any byte
  range, hiding the device's block size.

  Writing back. A write only changes the cached line and marks it dirty.
  Dirty lines reach the device when FlushCachedDevice is called (which
  then also flushes the device's own cache - file systems call it
  whenever something must be durable or ordered, as the ext journal does
  around its commit blocks), when the background writer finds them dirty
  for more than DirtyLifetimeMilliseconds, or before their line is used
  for another part of a device.

  Locking. One mutex (the cache lock) protects the hash table, the
  recency list and which part of which device each line holds; it is
  never held across device I/O. Each line has a mutex of its own for its
  data and its I/O, so different devices - and different lines of one
  device - are read and written in parallel. A thread takes a line's
  mutex only while it has the line pinned, so an unpinned line's mutex
  is always free: choosing a line to reuse never waits.

  Reading ahead. When reads miss on consecutive lines of a device, the
  next ReadAheadLines lines not yet cached are read along with the one
  asked for, in one device request.

  Lines are found through a hash table and reused least recently used
  first; a dirty line is written back before it is reused.
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

{ Writes ByteCount bytes from Buffer at ByteOffset on Device into the
  cache (written back later). Returns False on a device error. }
function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;

{ Writes ByteCount zero bytes at ByteOffset. }
function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;

{ Writes every dirty line of Device back and flushes the device: when it
  returns True, everything written to Device so far is durable. }
function FlushCachedDevice(Device: PBlockDevice): Boolean;
{ The same for every device. }
function FlushAllCachedDevices: Boolean;

{ Writes back and drops every cached line of Device (used when a volume
  is unmounted, and after the device was written around the cache). }
procedure InvalidateCachedDevice(Device: PBlockDevice);

{ The background writer: a system thread runs this; it never returns. }
procedure RunBlockCacheWriter(Context: Pointer);

procedure WriteBlockCacheSummary;

implementation

uses
  Runtime.Memory,
  Runtime.LinkedList,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Panic,
  Debug.Output;

const
  LineCount = 1024;
  BucketCount = 1024;
  ReadAheadLines = 16;
  WriterIntervalMilliseconds = 500;
  DirtyLifetimeMilliseconds = 1000;
  MaximumTrackedDevices = 64;
  WriteBatchSize = 32;

type
  PCacheLine = ^TCacheLine;
  TCacheLine = record
    { Protected by the cache lock. }
    Device: PBlockDevice;
    LineNumber: QWord;
    InHash: Boolean;
    PinCount: LongInt;
    NextInBucket: PCacheLine;
    RecencyLink: TListEntry;
    { Protected by the line's own lock. }
    Lock: TMutex;
    Data: PByte;
    IsLoaded: Boolean;
    IsDirty: Boolean;
    DirtySince: QWord;
  end;

  { Per device: where the last read miss was, to notice sequential reads. }
  TDeviceHistory = record
    Device: PBlockDevice;
    LastMissLine: QWord;
  end;

var
  Lines: PCacheLine;
  Buckets: array[0..BucketCount - 1] of PCacheLine;
  { Most recently used at the head, reuse candidates at the tail. }
  RecencyList: TListEntry;
  CacheLock: TMutex;
  Histories: array[0..MaximumTrackedDevices - 1] of TDeviceHistory;
  HitCount: QWord;
  MissCount: QWord;
  ReadAheadCount: QWord;
  WriteBackCount: QWord;

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
  Lines := PCacheLine(AllocateZeroedKernelMemory(LineCount * SizeOf(TCacheLine)));
  if Lines = nil then
    KernelPanic('no memory for the block cache');
  for LineIndex := 0 to LineCount - 1 do
  begin
    PagePhysical := AllocatePhysicalPage(PageUsageGeneral);
    if PagePhysical = 0 then
      KernelPanic('no memory for block cache pages');
    Lines[LineIndex].Data := PByte(PhysicalToVirtual(PagePhysical));
    InitializeMutex(Lines[LineIndex].Lock);
    InsertAtTail(RecencyList, @Lines[LineIndex].RecencyLink);
  end;
end;

{ --- Device geometry ----------------------------------------------------- }

{ Devices whose blocks do not evenly divide a cache line bypass the cache. }
function DeviceIsCacheable(Device: PBlockDevice): Boolean;
begin
  Result := (Device^.BlockSize >= 512) and (Device^.BlockSize <= CacheLineSize) and
    ((CacheLineSize mod Device^.BlockSize) = 0);
end;

function BlocksPerLine(Device: PBlockDevice): QWord;
begin
  Result := CacheLineSize div Device^.BlockSize;
end;

function LineCountOf(Device: PBlockDevice): QWord;
begin
  Result := (Device^.BlockCount + BlocksPerLine(Device) - 1) div BlocksPerLine(Device);
end;

{ Device blocks backing line LineNumber: the last line of a device may be
  only partly backed. }
function BlocksInLine(Device: PBlockDevice; LineNumber: QWord): QWord;
var
  FirstBlock: QWord;
begin
  FirstBlock := LineNumber * BlocksPerLine(Device);
  Result := BlocksPerLine(Device);
  if Result > Device^.BlockCount - FirstBlock then
    Result := Device^.BlockCount - FirstBlock;
end;

{ --- The hash table and the recency list (cache lock held) -------------- }

function FindLineLocked(Device: PBlockDevice; LineNumber: QWord): PCacheLine;
begin
  Result := Buckets[BucketIndex(Device, LineNumber)];
  while (Result <> nil) and ((Result^.Device <> Device) or (Result^.LineNumber <> LineNumber)) do
    Result := Result^.NextInBucket;
end;

procedure RemoveFromBucketLocked(Line: PCacheLine);
var
  Bucket: Integer;
  Previous: PCacheLine;
  Current: PCacheLine;
begin
  if not Line^.InHash then
    Exit;
  Bucket := BucketIndex(Line^.Device, Line^.LineNumber);
  Previous := nil;
  Current := Buckets[Bucket];
  while (Current <> nil) and (Current <> Line) do
  begin
    Previous := Current;
    Current := Current^.NextInBucket;
  end;
  if Current = nil then
    Exit;
  if Previous = nil then
    Buckets[Bucket] := Line^.NextInBucket
  else
    Previous^.NextInBucket := Line^.NextInBucket;
  Line^.InHash := False;
end;

procedure InsertIntoBucketLocked(Line: PCacheLine; Device: PBlockDevice; LineNumber: QWord);
var
  Bucket: Integer;
begin
  Line^.Device := Device;
  Line^.LineNumber := LineNumber;
  Bucket := BucketIndex(Device, LineNumber);
  Line^.NextInBucket := Buckets[Bucket];
  Buckets[Bucket] := Line;
  Line^.InHash := True;
end;

procedure MarkMostRecentlyUsedLocked(Line: PCacheLine);
begin
  RemoveListEntry(@Line^.RecencyLink);
  InsertAtHead(RecencyList, @Line^.RecencyLink);
end;

{ The least recently used line nobody has pinned; Dirty tells whether it
  must be written back first. nil if every line is pinned. }
function ReusableLineLocked(out Dirty: Boolean): PCacheLine;
var
  Entry: PListEntry;
  Line: PCacheLine;
begin
  Entry := RecencyList.Previous;
  while Entry <> @RecencyList do
  begin
    Line := LineFromRecencyLink(Entry);
    if Line^.PinCount = 0 then
    begin
      { Unpinned, so nobody holds its lock: IsDirty can be read. }
      Dirty := Line^.IsDirty;
      Exit(Line);
    end;
    Entry := Entry^.Previous;
  end;
  Result := nil;
end;

procedure UnpinLine(Line: PCacheLine);
begin
  AcquireMutex(CacheLock);
  Dec(Line^.PinCount);
  ReleaseMutex(CacheLock);
end;

{ --- Device I/O for one line (line lock held) --------------------------- }

function LoadLine(Line: PCacheLine): Boolean;
var
  Count: QWord;
begin
  Count := BlocksInLine(Line^.Device, Line^.LineNumber);
  if Count < BlocksPerLine(Line^.Device) then
    ZeroMemory(Line^.Data, CacheLineSize);
  Result := ReadBlocks(Line^.Device, Line^.LineNumber * BlocksPerLine(Line^.Device), LongWord(Count),
    Line^.Data);
  Line^.IsLoaded := Result;
end;

function WriteBackLine(Line: PCacheLine): Boolean;
begin
  Result := True;
  if not Line^.IsDirty then
    Exit;
  Result := WriteBlocks(Line^.Device, Line^.LineNumber * BlocksPerLine(Line^.Device),
    LongWord(BlocksInLine(Line^.Device, Line^.LineNumber)), Line^.Data);
  if Result then
  begin
    Line^.IsDirty := False;
    Inc(WriteBackCount);
  end;
end;

{ Writes back a dirty line nobody had pinned (pinned by the caller now). }
function CleanPinnedLine(Line: PCacheLine): Boolean;
begin
  AcquireMutex(Line^.Lock);
  Result := WriteBackLine(Line);
  ReleaseMutex(Line^.Lock);
  UnpinLine(Line);
end;

{ --- Finding lines ------------------------------------------------------- }

{ The line for LineNumber of Device, pinned (not locked, perhaps not
  loaded yet). Fresh tells whether it was not cached; with OnlyIfAbsent
  a cached line is not returned (nil). nil also if no line is free. }
function PinLine(Device: PBlockDevice; LineNumber: QWord; OnlyIfAbsent: Boolean;
  out Fresh: Boolean): PCacheLine;
var
  Dirty: Boolean;
  Victim: PCacheLine;
begin
  Fresh := False;
  repeat
    AcquireMutex(CacheLock);
    Result := FindLineLocked(Device, LineNumber);
    if Result <> nil then
    begin
      if OnlyIfAbsent then
        Result := nil
      else
      begin
        Inc(Result^.PinCount);
        MarkMostRecentlyUsedLocked(Result);
      end;
      ReleaseMutex(CacheLock);
      Exit;
    end;
    Victim := ReusableLineLocked(Dirty);
    if Victim = nil then
    begin
      ReleaseMutex(CacheLock);
      Exit(nil);
    end;
    Inc(Victim^.PinCount);
    if not Dirty then
    begin
      RemoveFromBucketLocked(Victim);
      InsertIntoBucketLocked(Victim, Device, LineNumber);
      Victim^.IsLoaded := False;
      MarkMostRecentlyUsedLocked(Victim);
      ReleaseMutex(CacheLock);
      Fresh := True;
      Exit(Victim);
    end;
    { Written back where it is (so readers of it still find it), then
      chosen again. }
    ReleaseMutex(CacheLock);
    if not CleanPinnedLine(Victim) then
      Exit(nil);
  until False;
end;

function DeviceHistoryIndex(Device: PBlockDevice): Integer;
var
  Index: Integer;
begin
  for Index := 0 to MaximumTrackedDevices - 1 do
    if Histories[Index].Device = Device then
      Exit(Index);
  for Index := 0 to MaximumTrackedDevices - 1 do
    if Histories[Index].Device = nil then
    begin
      Histories[Index].Device := Device;
      Histories[Index].LastMissLine := High(QWord) - 1;
      Exit(Index);
    end;
  Result := -1;
end;

{ True if a miss on LineNumber follows a miss on the line before it. }
function MissIsSequential(Device: PBlockDevice; LineNumber: QWord): Boolean;
var
  Index: Integer;
begin
  AcquireMutex(CacheLock);
  Index := DeviceHistoryIndex(Device);
  Result := (Index >= 0) and (Histories[Index].LastMissLine + 1 = LineNumber);
  if Index >= 0 then
    Histories[Index].LastMissLine := LineNumber;
  ReleaseMutex(CacheLock);
end;

{ Loads Line (locked, not loaded) together with the lines after it that
  are not cached, in one request. }
function LoadWithReadAhead(Line: PCacheLine): Boolean;
var
  Device: PBlockDevice;
  Extra: array[0..ReadAheadLines - 1] of PCacheLine;
  ExtraCount: Integer;
  Fresh: Boolean;
  Candidate: PCacheLine;
  Buffer: PByte;
  BlockCount: QWord;
  Index: Integer;
begin
  Device := Line^.Device;
  ExtraCount := 0;
  while (ExtraCount < ReadAheadLines) and (Line^.LineNumber + QWord(ExtraCount) + 1 < LineCountOf(Device)) do
  begin
    Candidate := PinLine(Device, Line^.LineNumber + QWord(ExtraCount) + 1, True, Fresh);
    if Candidate = nil then
      Break;
    { Fresh lines are found by others only after this; locking them in
      ascending order cannot deadlock. }
    AcquireMutex(Candidate^.Lock);
    if Candidate^.IsLoaded then
    begin
      ReleaseMutex(Candidate^.Lock);
      UnpinLine(Candidate);
      Break;
    end;
    Extra[ExtraCount] := Candidate;
    Inc(ExtraCount);
  end;

  Buffer := nil;
  if ExtraCount > 0 then
    Buffer := PByte(AllocateKernelMemory((ExtraCount + 1) * CacheLineSize));
  if Buffer = nil then
    Result := LoadLine(Line)
  else
  begin
    BlockCount := QWord(ExtraCount) * BlocksPerLine(Device) +
      BlocksInLine(Device, Line^.LineNumber + QWord(ExtraCount));
    ZeroMemory(Buffer + ExtraCount * CacheLineSize, CacheLineSize);
    Result := ReadBlocks(Device, Line^.LineNumber * BlocksPerLine(Device), LongWord(BlockCount), Buffer);
    if Result then
    begin
      CopyMemory(Line^.Data, Buffer, CacheLineSize);
      Line^.IsLoaded := True;
      for Index := 0 to ExtraCount - 1 do
      begin
        CopyMemory(Extra[Index]^.Data, Buffer + (Index + 1) * CacheLineSize, CacheLineSize);
        Extra[Index]^.IsLoaded := True;
      end;
      Inc(ReadAheadCount, ExtraCount);
    end;
    FreeKernelMemory(Buffer);
  end;
  for Index := 0 to ExtraCount - 1 do
  begin
    ReleaseMutex(Extra[Index]^.Lock);
    UnpinLine(Extra[Index]);
  end;
end;

{ The line for LineNumber, pinned and locked. With Load it is loaded
  (reading ahead after sequential misses); without, the caller is about
  to overwrite all of it. nil on a device error. }
function AcquireLine(Device: PBlockDevice; LineNumber: QWord; Load: Boolean): PCacheLine;
var
  Fresh: Boolean;
  Loaded: Boolean;
begin
  Result := PinLine(Device, LineNumber, False, Fresh);
  if Result = nil then
    Exit;
  if Fresh then
    Inc(MissCount)
  else
    Inc(HitCount);
  AcquireMutex(Result^.Lock);
  if Result^.IsLoaded or not Load then
    Exit;
  if MissIsSequential(Device, LineNumber) then
    Loaded := LoadWithReadAhead(Result)
  else
    Loaded := LoadLine(Result);
  if not Loaded then
  begin
    ReleaseMutex(Result^.Lock);
    UnpinLine(Result);
    Result := nil;
  end;
end;

procedure ReleaseLine(Line: PCacheLine);
begin
  ReleaseMutex(Line^.Lock);
  UnpinLine(Line);
end;

{ --- Reading and writing ------------------------------------------------- }

function RangeIsValid(Device: PBlockDevice; ByteOffset, ByteCount: QWord): Boolean;
begin
  Result := (ByteOffset < BlockDeviceSizeInBytes(Device)) and
    (ByteCount <= BlockDeviceSizeInBytes(Device) - ByteOffset) and DeviceIsCacheable(Device);
end;

function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
var
  Destination: PByte;
  OffsetInLine: QWord;
  ChunkBytes: QWord;
  Line: PCacheLine;
begin
  if ByteCount = 0 then
    Exit(True);
  if not RangeIsValid(Device, ByteOffset, ByteCount) then
    Exit(False);
  Destination := PByte(Buffer);
  while ByteCount > 0 do
  begin
    OffsetInLine := ByteOffset mod CacheLineSize;
    ChunkBytes := CacheLineSize - OffsetInLine;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;
    Line := AcquireLine(Device, ByteOffset div CacheLineSize, True);
    if Line = nil then
      Exit(False);
    CopyMemory(Destination, Line^.Data + OffsetInLine, ChunkBytes);
    ReleaseLine(Line);
    Destination := Destination + ChunkBytes;
    ByteOffset := ByteOffset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  Result := True;
end;

{ Shared by CachedWrite and CachedWriteZeros: Source = nil writes zeros. }
function WriteIntoCache(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Source: PByte): Boolean;
var
  OffsetInLine: QWord;
  ChunkBytes: QWord;
  Line: PCacheLine;
begin
  if ByteCount = 0 then
    Exit(True);
  if not RangeIsValid(Device, ByteOffset, ByteCount) then
    Exit(False);
  while ByteCount > 0 do
  begin
    OffsetInLine := ByteOffset mod CacheLineSize;
    ChunkBytes := CacheLineSize - OffsetInLine;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;
    { A line written only in part is read first, keeping its other bytes. }
    Line := AcquireLine(Device, ByteOffset div CacheLineSize, ChunkBytes < CacheLineSize);
    if Line = nil then
      Exit(False);
    if Source <> nil then
    begin
      CopyMemory(Line^.Data + OffsetInLine, Source, ChunkBytes);
      Source := Source + ChunkBytes;
    end
    else
      ZeroMemory(Line^.Data + OffsetInLine, ChunkBytes);
    Line^.IsLoaded := True;
    if not Line^.IsDirty then
      Line^.DirtySince := ClockTickCount;
    Line^.IsDirty := True;
    ReleaseLine(Line);
    ByteOffset := ByteOffset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  Result := True;
end;

function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
begin
  if (Buffer = nil) and (ByteCount > 0) then
    Exit(False);
  Result := WriteIntoCache(Device, ByteOffset, ByteCount, PByte(Buffer));
end;

function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
begin
  Result := WriteIntoCache(Device, ByteOffset, ByteCount, nil);
end;

{ --- Writing back -------------------------------------------------------- }

type
  { Dirty lines of one device, pinned and locked, written back together. }
  TWriteBatch = record
    Device: PBlockDevice;
    Lines: array[0..WriteBatchSize - 1] of PCacheLine;
    Count: Integer;
  end;

{ Writes the batch's lines back in one go and lets them go. }
function WriteBatch(var Batch: TWriteBatch): Boolean;
var
  Writes: PBlockWrite;
  Index: Integer;
  Line: PCacheLine;
begin
  Result := True;
  if Batch.Count = 0 then
    Exit;
  Writes := PBlockWrite(AllocateKernelMemory(Batch.Count * SizeOf(TBlockWrite)));
  if Writes = nil then
  begin
    { One at a time instead. }
    for Index := 0 to Batch.Count - 1 do
      if not WriteBackLine(Batch.Lines[Index]) then
        Result := False;
  end
  else
  begin
    for Index := 0 to Batch.Count - 1 do
    begin
      Line := Batch.Lines[Index];
      Writes[Index].FirstBlock := Line^.LineNumber * BlocksPerLine(Line^.Device);
      Writes[Index].BlockCount := LongWord(BlocksInLine(Line^.Device, Line^.LineNumber));
      Writes[Index].Buffer := Line^.Data;
    end;
    Result := WriteBlocksTogether(Batch.Device, Writes, Batch.Count);
    if Result then
      for Index := 0 to Batch.Count - 1 do
      begin
        Batch.Lines[Index]^.IsDirty := False;
        Inc(WriteBackCount);
      end;
    FreeKernelMemory(Writes);
  end;
  for Index := 0 to Batch.Count - 1 do
    ReleaseLine(Batch.Lines[Index]);
  Batch.Count := 0;
end;

{ Writes back the dirty lines of Device (all devices if nil) that have
  been dirty since at least DirtyBefore ticks, up to WriteBatchSize of a
  device at once. }
function WriteBackLines(Device: PBlockDevice; DirtyBefore: QWord): Boolean;
var
  LineIndex: Integer;
  Line: PCacheLine;
  Wanted: Boolean;
  Batch: TWriteBatch;
begin
  Result := True;
  Batch.Count := 0;
  Batch.Device := nil;
  for LineIndex := 0 to LineCount - 1 do
  begin
    Line := @Lines[LineIndex];
    AcquireMutex(CacheLock);
    { IsDirty is only a hint here; it is checked again under the line's
      lock. Lines in the batch are pinned, so never reused meanwhile. }
    Wanted := Line^.InHash and Line^.IsDirty and ((Device = nil) or (Line^.Device = Device));
    if Wanted then
      Inc(Line^.PinCount);
    ReleaseMutex(CacheLock);
    if not Wanted then
      Continue;
    AcquireMutex(Line^.Lock);
    if not Line^.IsDirty or (Line^.DirtySince > DirtyBefore) then
    begin
      ReleaseLine(Line);
      Continue;
    end;
    if (Batch.Count > 0) and ((Batch.Device <> Line^.Device) or (Batch.Count = WriteBatchSize)) then
      if not WriteBatch(Batch) then
        Result := False;
    Batch.Device := Line^.Device;
    Batch.Lines[Batch.Count] := Line;
    Inc(Batch.Count);
  end;
  if not WriteBatch(Batch) then
    Result := False;
end;

function FlushCachedDevice(Device: PBlockDevice): Boolean;
begin
  Result := WriteBackLines(Device, High(QWord));
  Result := FlushBlockDevice(Device) and Result;
end;

function FlushAllCachedDevices: Boolean;
var
  Index: Integer;
begin
  Result := WriteBackLines(nil, High(QWord));
  for Index := 0 to BlockDeviceCount - 1 do
    if not BlockDeviceIsPartition(BlockDeviceAt(Index)) then
      Result := FlushBlockDevice(BlockDeviceAt(Index)) and Result;
end;

procedure InvalidateCachedDevice(Device: PBlockDevice);
var
  LineIndex: Integer;
begin
  WriteBackLines(Device, High(QWord));
  AcquireMutex(CacheLock);
  for LineIndex := 0 to LineCount - 1 do
    if Lines[LineIndex].InHash and (Lines[LineIndex].Device = Device) and
       (Lines[LineIndex].PinCount = 0) then
    begin
      RemoveFromBucketLocked(@Lines[LineIndex]);
      Lines[LineIndex].IsLoaded := False;
      Lines[LineIndex].IsDirty := False;
    end;
  ReleaseMutex(CacheLock);
end;

procedure RunBlockCacheWriter(Context: Pointer);
var
  Now: QWord;
  Lifetime: QWord;
begin
  Lifetime := MillisecondsToTicks(DirtyLifetimeMilliseconds);
  while True do
  begin
    SleepMilliseconds(WriterIntervalMilliseconds);
    Now := ClockTickCount;
    if Now > Lifetime then
      WriteBackLines(nil, Now - Lifetime);
  end;
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
  DebugWrite(' misses, ');
  DebugWriteDecimal(ReadAheadCount);
  DebugWrite(' read ahead, ');
  DebugWriteDecimal(WriteBackCount);
  DebugWriteLine(' written back');
  DebugEndMessage;
end;

end.
