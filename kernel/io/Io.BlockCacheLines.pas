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
  The block cache's lines and their bookkeeping (Io.BlockCache uses it).

  A line is a record (TCacheLine) and, while it is live, a page of
  memory holding 4 KiB of one device. Records come in chunks of
  LinesPerChunk, allocated as the cache grows; a record whose page was
  given back is spare, kept for the next line, and a chunk whose records
  are all spare is freed. A chunk's place in the chunk table never
  changes, so a record can be reached by its slot number (chunk and
  index) while it exists.

  Live lines are found through a hash table, kept on the recency list
  (most recently used first) and, while dirty, on the dirty list in the
  order they became dirty, so the writer finds the oldest dirty lines
  without looking at clean ones.

  Everything here except allocating a chunk runs with the cache lock
  held (the routines ending in Locked). The cache lock is a mutex; no
  kernel heap memory is allocated while it is held, so that a heap that
  must reclaim memory never finds it taken by the thread that asks.
}
unit Io.BlockCacheLines;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Memory.Layout,
  Kernel.Mutex,
  Io.BlockDevice;

const
  CacheLineSize = 4096;
  LinesPerChunk = 256;

type
  PLineChunk = ^TLineChunk;

  PCacheLine = ^TCacheLine;
  TCacheLine = record
    { Protected by the cache lock. }
    Device: PBlockDevice;
    LineNumber: QWord;
    InHash: Boolean;
    { Has a page and is on the recency list (else it is spare). }
    IsLive: Boolean;
    InDirtyList: Boolean;
    PinCount: LongInt;
    NextInBucket: PCacheLine;
    { The recency list while live, the spare list while not. }
    RecencyLink: TListEntry;
    DirtyLink: TListEntry;
    { Set as the line joins the dirty list (its lock held too). }
    DirtySequence: QWord;
    DirtySince: QWord;
    Chunk: PLineChunk;
    { Protected by the line's own lock; the page changes only while the
      line is unpinned, under the cache lock. }
    Lock: TMutex;
    Data: PByte;
    DataPhysical: TPhysicalAddress;
    IsLoaded: Boolean;
    IsDirty: Boolean;
  end;

  TLineChunk = record
    Lines: array[0..LinesPerChunk - 1] of TCacheLine;
    LiveCount: LongWord;
    TableIndex: LongWord;
  end;

{ Sets up the tables for at most MaximumLines lines; False if there is
  no memory for them. }
function InitializeCacheLines(MaximumLines: QWord): Boolean;

procedure LockCache;
procedure UnlockCache;

{ Live lines, and the records allocated for lines. }
function LiveLineCount: QWord;
function LineRecordCount: QWord;
function DirtyLineCount: QWord;

{ --- Cache lock held ---------------------------------------------------- }

function FindLineLocked(Device: PBlockDevice; LineNumber: QWord): PCacheLine;
{ Gives Line (live, unpinned or pinned by the caller only) to another
  part of a device: out of its hash chain, into the new one. }
procedure ReassignLineLocked(Line: PCacheLine; Device: PBlockDevice; LineNumber: QWord);
{ Takes Line out of the hash table: nobody finds it any more. }
procedure ForgetLineLocked(Line: PCacheLine);
procedure MarkMostRecentlyUsedLocked(Line: PCacheLine);

{ The least recently used live line nobody has pinned, clean ones only
  if SkipDirty, searching at most Limit lines from the end; nil if none. }
function ReusableLineLocked(SkipDirty: Boolean; Limit: QWord): PCacheLine;

{ The line became dirty / clean (its lock held too). }
procedure NoteLineDirtiedLocked(Line: PCacheLine; Now: QWord);
procedure NoteLineCleanedLocked(Line: PCacheLine);
{ The dirty list, oldest first: the first line, and the one after Line;
  nil at the end. }
function FirstDirtyLineLocked: PCacheLine;
function NextDirtyLineLocked(Line: PCacheLine): PCacheLine;
{ The sequence the next line to become dirty gets. }
function NextDirtySequenceLocked: QWord;

{ A spare record, or nil (then allocate a chunk and AddChunkLocked). }
function TakeSpareLineLocked: PCacheLine;
{ Puts back a spare record that was not started after all. }
procedure ReturnSpareLineLocked(Line: PCacheLine);
{ Makes the spare record Line live with the page at Physical, owning
  line LineNumber of Device, pinned once, most recently used. }
procedure StartLineLocked(Line: PCacheLine; Physical: TPhysicalAddress; Device: PBlockDevice;
  LineNumber: QWord);
{ Gives Line (live, unpinned) a different page; returns the old one. }
function ReplacePageLocked(Line: PCacheLine; Physical: TPhysicalAddress): TPhysicalAddress;
{ Line (live, unpinned) stops: out of every list, spare from now on;
  returns its page, for the caller to free once the lock is released.
  A chunk left with no live line is freed. }
function RetireLineLocked(Line: PCacheLine): TPhysicalAddress;

{ Slots: every record of every chunk, numbered; LineAtSlotLocked is nil
  for a slot without a live line. }
function SlotCountLocked: QWord;
function LineAtSlotLocked(Slot: QWord): PCacheLine;

{ --- No lock held ------------------------------------------------------- }

{ A new chunk of spare records (nil if memory is short), for
  AddChunkLocked; FreeUnusedChunk if it turned out not to be needed. }
function AllocateLineChunk: PLineChunk;
{ Adds Chunk's records to the spare list; False (Chunk not taken) if the
  chunk table is full. }
function AddChunkLocked(Chunk: PLineChunk): Boolean;
procedure FreeUnusedChunk(Chunk: PLineChunk);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

const
  SmallestBucketCount = 1024;
  LargestBucketCount = QWord(1) shl 20;

var
  CacheLock: TMutex;
  Buckets: ^PCacheLine;
  BucketMask: QWord;
  Chunks: ^PLineChunk;
  ChunkTableSize: QWord;
  RecencyList: TListEntry;
  SpareList: TListEntry;
  DirtyList: TListEntry;
  LiveLines: QWord;
  LineRecords: QWord;
  DirtyLines: QWord;
  DirtySequence: QWord;

function LineFromRecencyLink(Entry: PListEntry): PCacheLine;
begin
  Result := PCacheLine(ContainingRecord(Entry, FieldOffset(PCacheLine(nil)^.RecencyLink)));
end;

function LineFromDirtyLink(Entry: PListEntry): PCacheLine;
begin
  Result := PCacheLine(ContainingRecord(Entry, FieldOffset(PCacheLine(nil)^.DirtyLink)));
end;

function InitializeCacheLines(MaximumLines: QWord): Boolean;
var
  BucketCount: QWord;
begin
  InitializeMutex(CacheLock);
  InitializeListHead(RecencyList);
  InitializeListHead(SpareList);
  InitializeListHead(DirtyList);
  { About two lines per hash chain when the cache is at its largest. }
  BucketCount := SmallestBucketCount;
  while (BucketCount < MaximumLines div 2) and (BucketCount < LargestBucketCount) do
    BucketCount := BucketCount * 2;
  BucketMask := BucketCount - 1;
  Buckets := AllocateZeroedKernelMemory(BucketCount * SizeOf(PCacheLine));
  ChunkTableSize := MaximumLines div LinesPerChunk + 2;
  Chunks := AllocateZeroedKernelMemory(ChunkTableSize * SizeOf(PLineChunk));
  Result := (Buckets <> nil) and (Chunks <> nil);
end;

procedure LockCache;
begin
  AcquireMutex(CacheLock);
end;

procedure UnlockCache;
begin
  ReleaseMutex(CacheLock);
end;

function LiveLineCount: QWord;
begin
  Result := LiveLines;
end;

function LineRecordCount: QWord;
begin
  Result := LineRecords;
end;

function DirtyLineCount: QWord;
begin
  Result := DirtyLines;
end;

{ --- The hash table ------------------------------------------------------ }

function BucketIndex(Device: PBlockDevice; LineNumber: QWord): QWord;
var
  Mixed: QWord;
begin
  Mixed := (QWord(Device) shr 4) xor (LineNumber * QWord($9E3779B97F4A7C15));
  Result := (Mixed shr 24) and BucketMask;
end;

function FindLineLocked(Device: PBlockDevice; LineNumber: QWord): PCacheLine;
begin
  Result := Buckets[BucketIndex(Device, LineNumber)];
  while (Result <> nil) and ((Result^.Device <> Device) or (Result^.LineNumber <> LineNumber)) do
    Result := Result^.NextInBucket;
end;

procedure ForgetLineLocked(Line: PCacheLine);
var
  Bucket: QWord;
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
  if Current <> nil then
  begin
    if Previous = nil then
      Buckets[Bucket] := Line^.NextInBucket
    else
      Previous^.NextInBucket := Line^.NextInBucket;
  end;
  Line^.NextInBucket := nil;
  Line^.InHash := False;
end;

procedure InsertIntoHashLocked(Line: PCacheLine; Device: PBlockDevice; LineNumber: QWord);
var
  Bucket: QWord;
begin
  Line^.Device := Device;
  Line^.LineNumber := LineNumber;
  Bucket := BucketIndex(Device, LineNumber);
  Line^.NextInBucket := Buckets[Bucket];
  Buckets[Bucket] := Line;
  Line^.InHash := True;
end;

procedure ReassignLineLocked(Line: PCacheLine; Device: PBlockDevice; LineNumber: QWord);
begin
  ForgetLineLocked(Line);
  InsertIntoHashLocked(Line, Device, LineNumber);
end;

{ --- Recency ------------------------------------------------------------- }

procedure MarkMostRecentlyUsedLocked(Line: PCacheLine);
begin
  RemoveListEntry(@Line^.RecencyLink);
  InsertAtHead(RecencyList, @Line^.RecencyLink);
end;

function ReusableLineLocked(SkipDirty: Boolean; Limit: QWord): PCacheLine;
var
  Entry: PListEntry;
  Line: PCacheLine;
  Looked: QWord;
begin
  Entry := RecencyList.Previous;
  Looked := 0;
  while (Entry <> @RecencyList) and (Looked < Limit) do
  begin
    Line := LineFromRecencyLink(Entry);
    { Unpinned, so nobody holds its lock: IsDirty can be read. }
    if (Line^.PinCount = 0) and not (SkipDirty and Line^.IsDirty) then
      Exit(Line);
    Entry := Entry^.Previous;
    Inc(Looked);
  end;
  Result := nil;
end;

{ --- The dirty list ------------------------------------------------------ }

procedure NoteLineDirtiedLocked(Line: PCacheLine; Now: QWord);
begin
  if Line^.InDirtyList then
    Exit;
  Line^.DirtySequence := DirtySequence;
  Inc(DirtySequence);
  Line^.DirtySince := Now;
  InsertAtTail(DirtyList, @Line^.DirtyLink);
  Line^.InDirtyList := True;
  Inc(DirtyLines);
end;

procedure NoteLineCleanedLocked(Line: PCacheLine);
begin
  if not Line^.InDirtyList then
    Exit;
  RemoveListEntry(@Line^.DirtyLink);
  Line^.InDirtyList := False;
  Dec(DirtyLines);
end;

function FirstDirtyLineLocked: PCacheLine;
begin
  if ListIsEmpty(DirtyList) then
    Exit(nil);
  Result := LineFromDirtyLink(DirtyList.Next);
end;

function NextDirtyLineLocked(Line: PCacheLine): PCacheLine;
begin
  if Line^.DirtyLink.Next = @DirtyList then
    Exit(nil);
  Result := LineFromDirtyLink(Line^.DirtyLink.Next);
end;

function NextDirtySequenceLocked: QWord;
begin
  Result := DirtySequence;
end;

{ --- Records and chunks -------------------------------------------------- }

function TakeSpareLineLocked: PCacheLine;
var
  Entry: PListEntry;
begin
  Entry := RemoveHeadEntry(SpareList);
  if Entry = nil then
    Exit(nil);
  Result := LineFromRecencyLink(Entry);
end;

procedure ReturnSpareLineLocked(Line: PCacheLine);
begin
  InsertAtHead(SpareList, @Line^.RecencyLink);
end;

procedure StartLineLocked(Line: PCacheLine; Physical: TPhysicalAddress; Device: PBlockDevice;
  LineNumber: QWord);
begin
  Line^.DataPhysical := Physical;
  Line^.Data := PByte(PhysicalToVirtual(Physical));
  Line^.IsLoaded := False;
  Line^.IsDirty := False;
  Line^.PinCount := 1;
  Line^.IsLive := True;
  InsertIntoHashLocked(Line, Device, LineNumber);
  InsertAtHead(RecencyList, @Line^.RecencyLink);
  Inc(Line^.Chunk^.LiveCount);
  Inc(LiveLines);
end;

function ReplacePageLocked(Line: PCacheLine; Physical: TPhysicalAddress): TPhysicalAddress;
begin
  Result := Line^.DataPhysical;
  Line^.DataPhysical := Physical;
  Line^.Data := PByte(PhysicalToVirtual(Physical));
  Line^.IsLoaded := False;
end;

procedure FreeChunkLocked(Chunk: PLineChunk);
var
  Index: Integer;
begin
  for Index := 0 to LinesPerChunk - 1 do
    RemoveListEntry(@Chunk^.Lines[Index].RecencyLink);
  Chunks[Chunk^.TableIndex] := nil;
  LineRecords := LineRecords - LinesPerChunk;
  { Freeing never allocates, so it may run under the cache lock. }
  FreeKernelMemory(Chunk);
end;

function RetireLineLocked(Line: PCacheLine): TPhysicalAddress;
var
  Chunk: PLineChunk;
begin
  ForgetLineLocked(Line);
  NoteLineCleanedLocked(Line);
  RemoveListEntry(@Line^.RecencyLink);
  Result := Line^.DataPhysical;
  Line^.Data := nil;
  Line^.DataPhysical := 0;
  Line^.IsLoaded := False;
  Line^.IsDirty := False;
  Line^.IsLive := False;
  Line^.Device := nil;
  Dec(LiveLines);
  Chunk := Line^.Chunk;
  Dec(Chunk^.LiveCount);
  InsertAtTail(SpareList, @Line^.RecencyLink);
  if Chunk^.LiveCount = 0 then
    FreeChunkLocked(Chunk);
end;

function SlotCountLocked: QWord;
begin
  Result := ChunkTableSize * LinesPerChunk;
end;

function LineAtSlotLocked(Slot: QWord): PCacheLine;
var
  Chunk: PLineChunk;
begin
  Result := nil;
  if Slot >= ChunkTableSize * LinesPerChunk then
    Exit;
  Chunk := Chunks[Slot div LinesPerChunk];
  if Chunk = nil then
    Exit;
  Result := @Chunk^.Lines[Slot mod LinesPerChunk];
  if not Result^.IsLive then
    Result := nil;
end;

function AllocateLineChunk: PLineChunk;
var
  Index: Integer;
begin
  Result := PLineChunk(AllocateZeroedKernelMemory(SizeOf(TLineChunk)));
  if Result = nil then
    Exit;
  for Index := 0 to LinesPerChunk - 1 do
  begin
    InitializeMutex(Result^.Lines[Index].Lock);
    Result^.Lines[Index].Chunk := Result;
    InitializeListHead(Result^.Lines[Index].RecencyLink);
    InitializeListHead(Result^.Lines[Index].DirtyLink);
  end;
end;

function AddChunkLocked(Chunk: PLineChunk): Boolean;
var
  TableIndex: QWord;
  Index: Integer;
begin
  TableIndex := 0;
  while (TableIndex < ChunkTableSize) and (Chunks[TableIndex] <> nil) do
    Inc(TableIndex);
  if TableIndex >= ChunkTableSize then
    Exit(False);
  Chunks[TableIndex] := Chunk;
  Chunk^.TableIndex := LongWord(TableIndex);
  for Index := 0 to LinesPerChunk - 1 do
    InsertAtTail(SpareList, @Chunk^.Lines[Index].RecencyLink);
  LineRecords := LineRecords + LinesPerChunk;
  Result := True;
end;

procedure FreeUnusedChunk(Chunk: PLineChunk);
begin
  FreeKernelMemory(Chunk);
end;

end.
