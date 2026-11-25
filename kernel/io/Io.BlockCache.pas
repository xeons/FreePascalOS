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

  Size. The cache starts at its minimum and takes a new line for a miss,
  rather than reusing the least recently used one, while it is below its
  maximum and memory is plentiful (twice the low watermark free); both
  bounds come from the memory free at start and the kernel options
  (Io.BlockCacheSizing). Under memory pressure its shrinker
  (Memory.Pressure) gives clean lines back, least recently used first,
  down to the minimum - and, asked hard, writes dirty lines back first.
  The lines' records and bookkeeping are in Io.BlockCacheLines.

  Writing back. A write only changes the cached line and marks it dirty.
  Dirty lines reach the device when FlushCachedDevice is called (which
  then also flushes the device's own cache - file systems call it
  whenever something must be durable or ordered, as the ext journal does
  around its commit blocks), when the background writer finds them dirty
  for more than DirtyLifetimeMilliseconds, before their line is used for
  another part of a device, or when the shrinker needs their memory.
  Dirty lines are kept on a list in the order they became dirty, so a
  flush writes only those dirty before it began, and never waits for
  lines dirtied while it runs. Lines are written in batches of one
  device, in ascending order (which is also the order their locks are
  taken in).

  Locking. One mutex (the cache lock) protects the hash table, the lists
  and which part of which device each line holds; it is never held across
  device I/O. Each line has a mutex of its own for its data and its I/O,
  so different devices - and different lines of one device - are read
  and written in parallel. A thread takes a line's mutex only while it
  has the line pinned, so an unpinned line's mutex is always free:
  choosing a line to reuse never waits.

  Reading ahead. When reads miss on consecutive lines of a device, the
  next ReadAheadLines lines not yet cached are read along with the one
  asked for, in one device request.

  Pages for mappings. PinCachedPage hands out a line's page itself (for
  file mappings that page in through the cache): whoever maps it takes a
  reference to the physical page, and the cache never reuses a page
  someone else holds - it gives such a line a fresh page instead and
  drops its own reference.

  Discarding. DiscardCachedRange forgets the lines a discarded range
  covers whole, dirty or not (freed blocks need not be written).
}
unit Io.BlockCache;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout,
  Io.BlockDevice;

const
  CacheLineSize = 4096;
  { Dirty line tags (CachedWriteTagged): no change in particular, and
    several changes (written back by every FlushCachedTag). }
  CacheTagNone = 0;
  CacheTagShared = High(QWord);

type
  TBlockCacheStatistics = record
    { Live lines now, the bounds, the dirty ones, and the records
      allocated for lines (live and spare). }
    LineCount: QWord;
    MinimumLines: QWord;
    MaximumLines: QWord;
    DirtyLines: QWord;
    LineRecords: QWord;
    Hits: QWord;
    Misses: QWord;
    ReadAhead: QWord;
    WrittenBack: QWord;
    { Lines added as the cache grew, given back under pressure, and
      forgotten because their blocks were discarded. }
    LinesGrown: QWord;
    LinesShrunk: QWord;
    LinesDiscarded: QWord;
  end;

  { A pinned line handed out with its page (PinCachedPage). }
  TCachedPage = record
    Line: Pointer;
    Physical: TPhysicalAddress;
    Data: PByte;
  end;

  { Runs on the background writer after each of its rounds. }
  TCacheWriterTask = procedure;

procedure InitializeBlockCache;

{ Copies ByteCount bytes starting at ByteOffset on Device into Buffer.
  Returns False on a device error or when the range is past the end. }
function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;

{ Writes ByteCount bytes from Buffer at ByteOffset on Device into the
  cache (written back later). Returns False on a device error. }
function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
{ CachedWrite (zeros if Buffer is nil) for the change Tag stands for
  (a file's, CacheTagNone, CacheTagShared): the lines it dirties carry
  the tag - or CacheTagShared once a second one dirties them - so that
  FlushCachedTag writes back only that file's. }
function CachedWriteTagged(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer; Tag: QWord): Boolean;
{ Writes back the dirty lines of Device tagged Tag, and those shared by
  several changes, then flushes the device. True when all of it is
  durable. }
function FlushCachedTag(Device: PBlockDevice; Tag: QWord): Boolean;
{ Dirty lines of Device tagged Tag (shared ones not counted), for
  tests. }
function CountDirtyLinesTagged(Device: PBlockDevice; Tag: QWord): QWord;

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

{ Forgets, without writing them back, the lines that lie wholly inside
  ByteCount bytes at ByteOffset of Device: the range is being discarded.
  Lines in use at the moment are left alone. }
procedure DiscardCachedRange(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord);

{ Discards the device blocks lying wholly inside ByteCount bytes at
  ByteOffset of Device, after forgetting what the cache holds of them
  (DiscardCachedRange). True if the disk took it (False also for disks
  that cannot discard). }
function DiscardDeviceRange(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;

{ The page holding the 4 KiB at ByteOffset (a multiple of CacheLineSize)
  of Device, pinned and locked: loaded if Load, else about to be
  overwritten whole. Hold it briefly; to keep the page (mapped in a
  process), take a reference to Page.Physical before releasing it.
  False on a device error, a range past the end, or a device the cache
  does not take. }
function PinCachedPage(Device: PBlockDevice; ByteOffset: QWord; Load: Boolean;
  out Page: TCachedPage): Boolean;
{ Lets the page go; Dirtied marks it for writing back. }
procedure ReleaseCachedPage(var Page: TCachedPage; Dirtied: Boolean);

{ Adds a routine for the background writer to run each round (pending
  discards, for one). }
procedure RegisterCacheWriterTask(Task: TCacheWriterTask);

{ The background writer: a system thread runs this; it never returns. }
procedure RunBlockCacheWriter(Context: Pointer);

procedure GetBlockCacheStatistics(out Statistics: TBlockCacheStatistics);
procedure WriteBlockCacheSummary;

implementation

uses
  Runtime.Memory,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.Pressure,
  Kernel.Mutex,
  Kernel.Clock,
  Kernel.Options,
  Kernel.Scheduler,
  Kernel.Panic,
  Io.BlockCacheLines,
  Io.BlockCacheSizing,
  Debug.Output;

const
  ReadAheadLines = 16;
  WriterIntervalMilliseconds = 500;
  DirtyLifetimeMilliseconds = 1000;
  MaximumTrackedDevices = 64;
  WriteBatchSize = 32;
  ShrinkBatchSize = 64;
  { How far up from the least recently used end the shrinker looks for
    a clean line. }
  ShrinkScanLimit = 4096;
  MaximumWriterTasks = 4;

type
  { Per device: where the last read miss was, to notice sequential reads. }
  TDeviceHistory = record
    Device: PBlockDevice;
    LastMissLine: QWord;
  end;

var
  CacheSize: TBlockCacheSize;
  Histories: array[0..MaximumTrackedDevices - 1] of TDeviceHistory;
  HitCount: QWord;
  MissCount: QWord;
  ReadAheadCount: QWord;
  WriteBackCount: QWord;
  GrownCount: QWord;
  ShrunkCount: QWord;
  DiscardedCount: QWord;
  WriterTasks: array[0..MaximumWriterTasks - 1] of TCacheWriterTask;
  WriterTaskCount: Integer;

function ShrinkBlockCache(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord; forward;

{ --- Starting ------------------------------------------------------------ }

procedure ReadSizingOptions(out Options: TBlockCacheSizingOptions);
begin
  if not GetKernelOptionNumber('blockcache', Options.MaximumMegabytes) then
    Options.MaximumMegabytes := 0;
  if not GetKernelOptionNumber('blockcachemin', Options.MinimumMegabytes) then
    Options.MinimumMegabytes := 0;
  if not GetKernelOptionNumber('blockcacheshare', Options.SharePercent) then
    Options.SharePercent := 0;
end;

{ Fills the cache to its minimum with lines owning nothing yet. }
procedure AddFirstLines;
var
  Spare: PLineChunk;
  Line: PCacheLine;
  Physical: TPhysicalAddress;
begin
  Spare := nil;
  while LiveLineCount < CacheSize.MinimumLines do
  begin
    LockCache;
    Line := TakeSpareLineLocked;
    if (Line = nil) and (Spare <> nil) and AddChunkLocked(Spare) then
    begin
      Spare := nil;
      Line := TakeSpareLineLocked;
    end;
    if Line = nil then
    begin
      UnlockCache;
      Spare := AllocateLineChunk;
      if Spare = nil then
        Break;
      Continue;
    end;
    Physical := AllocatePhysicalPage(PageUsageBlockCache);
    if Physical = 0 then
    begin
      ReturnSpareLineLocked(Line);
      UnlockCache;
      Break;
    end;
    { Started unowned: in no hash chain, unpinned, the first to reuse. }
    StartLineLocked(Line, Physical, nil, 0);
    ForgetLineLocked(Line);
    Line^.PinCount := 0;
    UnlockCache;
  end;
  if Spare <> nil then
    FreeUnusedChunk(Spare);
end;

procedure InitializeBlockCache;
var
  Options: TBlockCacheSizingOptions;
  Physical: TPhysicalMemoryStatistics;
begin
  ReadSizingOptions(Options);
  GetPhysicalMemoryStatistics(Physical);
  CacheSize := ChooseBlockCacheSize(Physical.FreePages, Options);
  if not InitializeCacheLines(CacheSize.MaximumLines) then
    KernelPanic('no memory for the block cache');
  AddFirstLines;
  if LiveLineCount = 0 then
    KernelPanic('no memory for block cache pages');
  RegisterShrinker('block cache', @ShrinkBlockCache);
end;

procedure RegisterCacheWriterTask(Task: TCacheWriterTask);
begin
  if WriterTaskCount < MaximumWriterTasks then
  begin
    WriterTasks[WriterTaskCount] := Task;
    Inc(WriterTaskCount);
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

{ --- Pinning ------------------------------------------------------------- }

procedure UnpinLine(Line: PCacheLine);
begin
  LockCache;
  Dec(Line^.PinCount);
  UnlockCache;
end;

{ The line's data became dirty or clean (its lock held). }
{ Line's lock held. A line dirtied again for another change is shared
  by both. }
procedure MarkLineDirty(Line: PCacheLine; Tag: QWord);
begin
  if Line^.IsDirty then
  begin
    if Line^.DirtyTag = Tag then
      Exit;
    LockCache;
    Line^.DirtyTag := CacheTagShared;
    UnlockCache;
    Exit;
  end;
  Line^.IsDirty := True;
  LockCache;
  Line^.DirtyTag := Tag;
  NoteLineDirtiedLocked(Line, ClockTickCount);
  UnlockCache;
end;

procedure MarkLineClean(Line: PCacheLine);
begin
  Line^.IsDirty := False;
  LockCache;
  NoteLineCleanedLocked(Line);
  UnlockCache;
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
  { Changes for a disk that was unplugged are lost; keeping them dirty
    would only have them tried again and again. }
  if BlockDeviceIsRemoved(Line^.Device) then
  begin
    MarkLineClean(Line);
    Exit(False);
  end;
  Result := WriteBlocks(Line^.Device, Line^.LineNumber * BlocksPerLine(Line^.Device),
    LongWord(BlocksInLine(Line^.Device, Line^.LineNumber)), Line^.Data);
  if Result then
  begin
    MarkLineClean(Line);
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

{ --- Growing ------------------------------------------------------------- }

{ True while the cache may take another line: below its maximum, with
  twice the low watermark of memory free. }
function CacheMayGrow: Boolean;
var
  Physical: TPhysicalMemoryStatistics;
  Low: QWord;
  Critical: QWord;
begin
  if LiveLineCount >= CacheSize.MaximumLines then
    Exit(False);
  GetPhysicalMemoryStatistics(Physical);
  GetMemoryWatermarks(Low, Critical);
  Result := Physical.FreePages > 2 * Low;
end;

{ A new line for LineNumber of Device, pinned (cache lock held); nil if
  there is no spare record (NeedsChunk: allocate one and try again) or
  no page. Spare, if not nil, is a chunk to add when records run out. }
function GrowLineLocked(Device: PBlockDevice; LineNumber: QWord; var Spare: PLineChunk;
  out NeedsChunk: Boolean): PCacheLine;
var
  Physical: TPhysicalAddress;
begin
  NeedsChunk := False;
  Result := TakeSpareLineLocked;
  if (Result = nil) and (Spare <> nil) and AddChunkLocked(Spare) then
  begin
    Spare := nil;
    Result := TakeSpareLineLocked;
  end;
  if Result = nil then
  begin
    NeedsChunk := Spare = nil;
    Exit;
  end;
  Physical := AllocatePhysicalPage(PageUsageBlockCache);
  if Physical = 0 then
  begin
    ReturnSpareLineLocked(Result);
    Exit(nil);
  end;
  StartLineLocked(Result, Physical, Device, LineNumber);
  Inc(GrownCount);
end;

{ --- Finding lines ------------------------------------------------------- }

{ Victim (unpinned, clean) gets a page nobody else holds: False if it
  was retired instead (no memory for a fresh one); OldPage is a page to
  free once the cache lock is released (0 for none). }
function TakeOwnPageLocked(Victim: PCacheLine; out OldPage: TPhysicalAddress): Boolean;
var
  Physical: TPhysicalAddress;
begin
  OldPage := 0;
  Result := True;
  if not PhysicalPageIsShared(Victim^.DataPhysical) then
    Exit;
  Physical := AllocatePhysicalPage(PageUsageBlockCache);
  if Physical = 0 then
  begin
    OldPage := RetireLineLocked(Victim);
    Exit(False);
  end;
  OldPage := ReplacePageLocked(Victim, Physical);
end;

{ The line for LineNumber of Device, pinned (not locked, perhaps not
  loaded yet). Fresh tells whether it was not cached; with OnlyIfAbsent
  a cached line is not returned (nil). nil also if no line is free. }
function PinLine(Device: PBlockDevice; LineNumber: QWord; OnlyIfAbsent: Boolean;
  out Fresh: Boolean): PCacheLine;
var
  Victim: PCacheLine;
  Spare: PLineChunk;
  ChunkTried: Boolean;
  NeedsChunk: Boolean;
  OldPage: TPhysicalAddress;
  Usable: Boolean;
begin
  Fresh := False;
  Spare := nil;
  ChunkTried := False;
  Result := nil;
  repeat
    LockCache;
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
      UnlockCache;
      Break;
    end;

    if CacheMayGrow then
    begin
      Result := GrowLineLocked(Device, LineNumber, Spare, NeedsChunk);
      if Result <> nil then
      begin
        UnlockCache;
        Fresh := True;
        Break;
      end;
      if NeedsChunk and not ChunkTried then
      begin
        { Chunks are allocated without the cache lock held. }
        UnlockCache;
        ChunkTried := True;
        Spare := AllocateLineChunk;
        Continue;
      end;
    end;

    Victim := ReusableLineLocked(False, High(QWord));
    if Victim = nil then
    begin
      UnlockCache;
      Break;
    end;
    if Victim^.IsDirty then
    begin
      { Written back where it is (so readers of it still find it), then
        chosen again. }
      Inc(Victim^.PinCount);
      UnlockCache;
      if not CleanPinnedLine(Victim) then
        Break;
      Continue;
    end;
    Usable := TakeOwnPageLocked(Victim, OldPage);
    if Usable then
    begin
      Inc(Victim^.PinCount);
      ReassignLineLocked(Victim, Device, LineNumber);
      Victim^.IsLoaded := False;
      MarkMostRecentlyUsedLocked(Victim);
    end;
    UnlockCache;
    if OldPage <> 0 then
      FreePhysicalPage(OldPage);
    if Usable then
    begin
      Fresh := True;
      Result := Victim;
      Break;
    end;
  until False;
  if Spare <> nil then
    FreeUnusedChunk(Spare);
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
  LockCache;
  Index := DeviceHistoryIndex(Device);
  Result := (Index >= 0) and (Histories[Index].LastMissLine + 1 = LineNumber);
  if Index >= 0 then
    Histories[Index].LastMissLine := LineNumber;
  UnlockCache;
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
  Source: PByte; Tag: QWord): Boolean;
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
    MarkLineDirty(Line, Tag);
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
  Result := WriteIntoCache(Device, ByteOffset, ByteCount, PByte(Buffer), CacheTagNone);
end;

function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
begin
  Result := WriteIntoCache(Device, ByteOffset, ByteCount, nil, CacheTagNone);
end;

function CachedWriteTagged(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer; Tag: QWord): Boolean;
begin
  Result := WriteIntoCache(Device, ByteOffset, ByteCount, PByte(Buffer), Tag);
end;

function PinCachedPage(Device: PBlockDevice; ByteOffset: QWord; Load: Boolean;
  out Page: TCachedPage): Boolean;
var
  Line: PCacheLine;
begin
  Page.Line := nil;
  Page.Physical := 0;
  Page.Data := nil;
  if ((ByteOffset mod CacheLineSize) <> 0) or not RangeIsValid(Device, ByteOffset, 1) then
    Exit(False);
  Line := AcquireLine(Device, ByteOffset div CacheLineSize, Load);
  if Line = nil then
    Exit(False);
  if not Load and not Line^.IsLoaded then
  begin
    ZeroMemory(Line^.Data, CacheLineSize);
    Line^.IsLoaded := True;
  end;
  Page.Line := Line;
  Page.Physical := Line^.DataPhysical;
  Page.Data := Line^.Data;
  Result := True;
end;

procedure ReleaseCachedPage(var Page: TCachedPage; Dirtied: Boolean);
var
  Line: PCacheLine;
begin
  Line := PCacheLine(Page.Line);
  if Line = nil then
    Exit;
  if Dirtied then
    MarkLineDirty(Line, CacheTagShared);
  ReleaseLine(Line);
  Page.Line := nil;
end;

{ --- Writing back -------------------------------------------------------- }

type
  { Dirty lines of one device, pinned and locked, written back together. }
  TWriteBatch = record
    Device: PBlockDevice;
    Lines: array[0..WriteBatchSize - 1] of PCacheLine;
    Count: Integer;
  end;

{ Writes the batch's lines back in one go (through Writes, room for
  WriteBatchSize runs, or one at a time if that is nil) and lets them go. }
function WriteBatch(var Batch: TWriteBatch; Writes: PBlockWrite): Boolean;
var
  Index: Integer;
  Line: PCacheLine;
begin
  Result := True;
  if Batch.Count = 0 then
    Exit;
  if (Writes = nil) or BlockDeviceIsRemoved(Batch.Device) then
  begin
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
    begin
      LockCache;
      for Index := 0 to Batch.Count - 1 do
      begin
        Batch.Lines[Index]^.IsDirty := False;
        NoteLineCleanedLocked(Batch.Lines[Index]);
      end;
      UnlockCache;
      Inc(WriteBackCount, Batch.Count);
    end;
  end;
  for Index := 0 to Batch.Count - 1 do
    ReleaseLine(Batch.Lines[Index]);
  Batch.Count := 0;
end;

{ Sorts the batch by line number: the order line locks are taken in. }
procedure SortBatch(var Batch: TWriteBatch);
var
  Index: Integer;
  Place: Integer;
  Moving: PCacheLine;
begin
  for Index := 1 to Batch.Count - 1 do
  begin
    Moving := Batch.Lines[Index];
    Place := Index;
    while (Place > 0) and (Batch.Lines[Place - 1]^.LineNumber > Moving^.LineNumber) do
    begin
      Batch.Lines[Place] := Batch.Lines[Place - 1];
      Dec(Place);
    end;
    Batch.Lines[Place] := Moving;
  end;
end;

{ Pins up to WriteBatchSize dirty lines of one device (of Device, if not
  nil) that became dirty before sequence StopSequence and at or before
  tick DirtyBefore; with ByTag only those tagged Tag or shared. }
procedure GatherBatch(Device: PBlockDevice; StopSequence, DirtyBefore: QWord; ByTag: Boolean; Tag: QWord;
  out Batch: TWriteBatch);
var
  Line: PCacheLine;
begin
  Batch.Count := 0;
  Batch.Device := nil;
  LockCache;
  Line := FirstDirtyLineLocked;
  while (Line <> nil) and (Batch.Count < WriteBatchSize) do
  begin
    { The list is in the order lines became dirty. }
    if (Line^.DirtySequence >= StopSequence) or (Line^.DirtySince > DirtyBefore) then
      Break;
    if ((Device = nil) or (Line^.Device = Device)) and
       ((Batch.Device = nil) or (Line^.Device = Batch.Device)) and
       (not ByTag or (Line^.DirtyTag = Tag) or (Line^.DirtyTag = CacheTagShared)) then
    begin
      Inc(Line^.PinCount);
      Batch.Device := Line^.Device;
      Batch.Lines[Batch.Count] := Line;
      Inc(Batch.Count);
    end;
    Line := NextDirtyLineLocked(Line);
  end;
  UnlockCache;
end;

{ Locks the batch's lines; those another thread wrote back meanwhile are
  let go. }
procedure LockBatch(var Batch: TWriteBatch);
var
  Index: Integer;
  Kept: Integer;
  Line: PCacheLine;
begin
  SortBatch(Batch);
  Kept := 0;
  for Index := 0 to Batch.Count - 1 do
  begin
    Line := Batch.Lines[Index];
    AcquireMutex(Line^.Lock);
    if Line^.IsDirty then
    begin
      Batch.Lines[Kept] := Line;
      Inc(Kept);
    end
    else
      ReleaseLine(Line);
  end;
  Batch.Count := Kept;
end;

{ Writes back the dirty lines of Device (all devices if nil) that have
  been dirty since at least DirtyBefore ticks and were dirty when this
  began, WriteBatchSize of a device at once. }
function WriteBackChosenLines(Device: PBlockDevice; DirtyBefore: QWord; ByTag: Boolean; Tag: QWord): Boolean;
var
  Batch: TWriteBatch;
  Writes: PBlockWrite;
  StopSequence: QWord;
begin
  Result := True;
  { Allocated before any line is locked: an allocation that has to
    reclaim memory may ask this cache to write lines back. }
  Writes := PBlockWrite(AllocateKernelMemory(WriteBatchSize * SizeOf(TBlockWrite)));
  LockCache;
  StopSequence := NextDirtySequenceLocked;
  UnlockCache;
  repeat
    GatherBatch(Device, StopSequence, DirtyBefore, ByTag, Tag, Batch);
    if Batch.Count = 0 then
      Break;
    LockBatch(Batch);
    if not WriteBatch(Batch, Writes) then
    begin
      Result := False;
      Break;
    end;
  until False;
  FreeKernelMemory(Writes);
end;

function WriteBackLines(Device: PBlockDevice; DirtyBefore: QWord): Boolean;
begin
  Result := WriteBackChosenLines(Device, DirtyBefore, False, CacheTagNone);
end;

function FlushCachedDevice(Device: PBlockDevice): Boolean;
begin
  Result := WriteBackLines(Device, High(QWord));
  Result := FlushBlockDevice(Device) and Result;
end;

function FlushCachedTag(Device: PBlockDevice; Tag: QWord): Boolean;
begin
  Result := WriteBackChosenLines(Device, High(QWord), True, Tag);
  Result := FlushBlockDevice(Device) and Result;
end;

function CountDirtyLinesTagged(Device: PBlockDevice; Tag: QWord): QWord;
var
  Line: PCacheLine;
begin
  Result := 0;
  LockCache;
  Line := FirstDirtyLineLocked;
  while Line <> nil do
  begin
    if (Line^.Device = Device) and (Line^.DirtyTag = Tag) then
      Inc(Result);
    Line := NextDirtyLineLocked(Line);
  end;
  UnlockCache;
end;

function FlushAllCachedDevices: Boolean;
var
  Index: Integer;
  Device: PBlockDevice;
begin
  Result := WriteBackLines(nil, High(QWord));
  for Index := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(Index);
    { The list closes up when a disk is unplugged meanwhile. }
    if (Device <> nil) and not BlockDeviceIsPartition(Device) then
      Result := FlushBlockDevice(Device) and Result;
  end;
end;

{ Line (live, unpinned) holds nothing any more: reused first (cache
  lock held). }
procedure DropLineLocked(Line: PCacheLine);
begin
  ForgetLineLocked(Line);
  NoteLineCleanedLocked(Line);
  Line^.IsLoaded := False;
  Line^.IsDirty := False;
end;

procedure InvalidateCachedDevice(Device: PBlockDevice);
var
  Slot: QWord;
  Line: PCacheLine;
begin
  WriteBackLines(Device, High(QWord));
  LockCache;
  Slot := 0;
  while Slot < SlotCountLocked do
  begin
    Line := LineAtSlotLocked(Slot);
    if (Line <> nil) and Line^.InHash and (Line^.Device = Device) and (Line^.PinCount = 0) then
      DropLineLocked(Line);
    Inc(Slot);
  end;
  UnlockCache;
end;

procedure DiscardCachedRange(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord);
var
  FirstLine: QWord;
  EndLine: QWord;
  LineNumber: QWord;
  Slot: QWord;
  Line: PCacheLine;
begin
  if (ByteCount = 0) or not DeviceIsCacheable(Device) then
    Exit;
  FirstLine := (ByteOffset + CacheLineSize - 1) div CacheLineSize;
  EndLine := (ByteOffset + ByteCount) div CacheLineSize;
  if EndLine <= FirstLine then
    Exit;
  LockCache;
  if EndLine - FirstLine <= LiveLineCount then
  begin
    LineNumber := FirstLine;
    while LineNumber < EndLine do
    begin
      Line := FindLineLocked(Device, LineNumber);
      if (Line <> nil) and (Line^.PinCount = 0) then
      begin
        DropLineLocked(Line);
        Inc(DiscardedCount);
      end;
      Inc(LineNumber);
    end;
  end
  else
  begin
    Slot := 0;
    while Slot < SlotCountLocked do
    begin
      Line := LineAtSlotLocked(Slot);
      if (Line <> nil) and Line^.InHash and (Line^.Device = Device) and (Line^.PinCount = 0) and
         (Line^.LineNumber >= FirstLine) and (Line^.LineNumber < EndLine) then
      begin
        DropLineLocked(Line);
        Inc(DiscardedCount);
      end;
      Inc(Slot);
    end;
  end;
  UnlockCache;
end;

function DiscardDeviceRange(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
var
  FirstBlock: QWord;
  EndBlock: QWord;
begin
  if not BlockDeviceSupportsDiscard(Device) then
    Exit(False);
  FirstBlock := (ByteOffset + Device^.BlockSize - 1) div Device^.BlockSize;
  EndBlock := (ByteOffset + ByteCount) div Device^.BlockSize;
  if EndBlock <= FirstBlock then
    Exit(True);
  DiscardCachedRange(Device, ByteOffset, ByteCount);
  Result := DiscardBlocks(Device, FirstBlock, EndBlock - FirstBlock);
end;

{ --- Shrinking ------------------------------------------------------------ }

{ Gives back up to Wanted clean lines, least recently used first, never
  below the minimum; returns how many. }
function RetireCleanLines(Wanted: QWord): QWord;
var
  Pages: array[0..ShrinkBatchSize - 1] of TPhysicalAddress;
  Count: Integer;
  Index: Integer;
  Line: PCacheLine;
begin
  Result := 0;
  while Result < Wanted do
  begin
    Count := 0;
    LockCache;
    while (Count < ShrinkBatchSize) and (Result + QWord(Count) < Wanted) and
          (LiveLineCount > CacheSize.MinimumLines) do
    begin
      Line := ReusableLineLocked(True, ShrinkScanLimit);
      if Line = nil then
        Break;
      Pages[Count] := RetireLineLocked(Line);
      Inc(Count);
    end;
    UnlockCache;
    for Index := 0 to Count - 1 do
      FreePhysicalPage(Pages[Index]);
    Result := Result + QWord(Count);
    if Count = 0 then
      Break;
  end;
  Inc(ShrunkCount, Result);
end;

function ShrinkBlockCache(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
begin
  Result := RetireCleanLines(PagesWanted);
  if (Result < PagesWanted) and (Urgency = ShrinkHard) and (DirtyLineCount > 0) then
  begin
    WriteBackLines(nil, High(QWord));
    Result := Result + RetireCleanLines(PagesWanted - Result);
  end;
end;

{ --- The writer and reports ---------------------------------------------- }

procedure RunBlockCacheWriter(Context: Pointer);
var
  Now: QWord;
  Lifetime: QWord;
  Index: Integer;
begin
  Lifetime := MillisecondsToTicks(DirtyLifetimeMilliseconds);
  while True do
  begin
    SleepMilliseconds(WriterIntervalMilliseconds);
    Now := ClockTickCount;
    if Now > Lifetime then
      WriteBackLines(nil, Now - Lifetime);
    for Index := 0 to WriterTaskCount - 1 do
      WriterTasks[Index]();
  end;
end;

procedure GetBlockCacheStatistics(out Statistics: TBlockCacheStatistics);
begin
  Statistics.LineCount := LiveLineCount;
  Statistics.MinimumLines := CacheSize.MinimumLines;
  Statistics.MaximumLines := CacheSize.MaximumLines;
  Statistics.DirtyLines := DirtyLineCount;
  Statistics.LineRecords := LineRecordCount;
  Statistics.Hits := HitCount;
  Statistics.Misses := MissCount;
  Statistics.ReadAhead := ReadAheadCount;
  Statistics.WrittenBack := WriteBackCount;
  Statistics.LinesGrown := GrownCount;
  Statistics.LinesShrunk := ShrunkCount;
  Statistics.LinesDiscarded := DiscardedCount;
end;

procedure WriteBlockCacheSummary;
var
  Lookups: QWord;
begin
  Lookups := HitCount + MissCount;
  DebugBeginMessage;
  DebugWriteTag('cache');
  DebugWriteDecimal(LiveLineCount);
  DebugWrite(' lines of ');
  DebugWriteDecimal(CacheLineSize);
  DebugWrite(' bytes (');
  DebugWriteSize(LiveLineCount * CacheLineSize);
  DebugWrite(', ');
  DebugWriteSize(CacheSize.MinimumLines * CacheLineSize);
  DebugWrite(' to ');
  DebugWriteSize(CacheSize.MaximumLines * CacheLineSize);
  DebugWrite('), ');
  DebugWriteDecimal(DirtyLineCount);
  DebugWriteLine(' dirty');
  DebugWriteTag('cache');
  DebugWriteDecimal(HitCount);
  DebugWrite(' hits, ');
  DebugWriteDecimal(MissCount);
  DebugWrite(' misses');
  if Lookups > 0 then
  begin
    DebugWrite(' (');
    DebugWriteDecimal(HitCount * 100 div Lookups);
    DebugWrite('% hits)');
  end;
  DebugWrite(', ');
  DebugWriteDecimal(ReadAheadCount);
  DebugWrite(' read ahead, ');
  DebugWriteDecimal(WriteBackCount);
  DebugWrite(' written back, ');
  DebugWriteDecimal(GrownCount);
  DebugWrite(' grown, ');
  DebugWriteDecimal(ShrunkCount);
  DebugWrite(' shrunk, ');
  DebugWriteDecimal(DiscardedCount);
  DebugWriteLine(' discarded');
  DebugEndMessage;
end;

end.
