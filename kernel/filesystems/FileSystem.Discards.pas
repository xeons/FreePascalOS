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
  Discarding what file systems free.

  When the ext, FAT or exFAT driver frees blocks or clusters, it queues
  their byte range here (QueueVolumeDiscard). Ranges are batched per
  volume, adjacent ones merged (FileSystem.DiscardRanges), and sent to
  the disk later: by the block cache's background writer each round
  (about twice a second), when the volume is synced, and when a batch
  fills up.

  Order matters: a block must not be discarded while the disk could
  still name it in use after a crash. So a batch goes out only after the
  cache has been flushed to the disk (the metadata that freed the blocks
  is durable then), and on a journaled ext volume a range waits in a
  held batch until the transaction that freed it has committed
  (ReleaseCommittedDiscards; a transaction that failed drops it).

  And a block freed and then allocated again before its discard went
  out must not be discarded at all: the drivers cancel the range of
  every block they allocate (CancelVolumeDiscard) before writing to it.
  A volume's discard lock is held while a batch goes out, so an
  allocation waits until it is done; the drivers take it with their
  volume lock held, and sending a batch never takes a volume lock.

  Before the disk gets the ranges, the cache forgets the lines lying
  wholly inside them, dirty or not.

  Volumes discard if their disk can (Io.BlockDevice) and the kernel
  option discard=off is not given. fstrim (CallTrimVolume,
  Processes.TrimCalls) discards all of a volume's free space: each
  driver walks its own free space and calls TrimFreeRange.
}
unit FileSystem.Discards;

{$mode objfpc}

interface

uses
  FileSystem.Types;

type
  TVolumeDiscardStatistics = record
    BytesQueued: QWord;
    BytesDiscarded: QWord;
    BatchesSent: QWord;
    Failures: QWord;
  end;

procedure InitializeVolumeDiscards;

{ Sets up discarding for a volume just mounted read-write (nothing if
  its disk cannot discard or discard=off). }
procedure AttachVolumeDiscards(Volume: PVolume);
function VolumeDiscards(Volume: PVolume): Boolean;

{ ByteCount bytes at ByteOffset of the volume were freed. AfterCommit:
  only once the running journal transaction commits. }
procedure QueueVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord; AfterCommit: Boolean);
{ The range was allocated again: it must not be discarded. }
procedure CancelVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord);
{ The journal transaction committed: its freed ranges may go out. }
procedure ReleaseCommittedDiscards(Volume: PVolume);
{ The journal transaction failed: what it freed did not happen. }
procedure DropUncommittedDiscards(Volume: PVolume);

{ Sends the volume's batch (after flushing the cache). }
procedure SendVolumeDiscards(Volume: PVolume);
procedure SendAllVolumeDiscards;

{ fstrim: discards ByteCount free bytes at ByteOffset now (the caller
  holds the volume lock and flushed the cache first). Adds what the disk
  took to Discarded; False if it refused. }
function TrimFreeRange(Volume: PVolume; ByteOffset, ByteCount: QWord; var Discarded: QWord): Boolean;

procedure GetVolumeDiscardStatistics(out Statistics: TVolumeDiscardStatistics);

implementation

uses
  Runtime.LinkedList,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Options,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.DiscardRanges,
  Debug.Output;

type
  PVolumeDiscards = ^TVolumeDiscards;
  TVolumeDiscards = record
    Volume: PVolume;
    Lock: TMutex;
    { Ready to go out, and waiting for the journal to commit. }
    Pending: TDiscardRangeList;
    Held: TDiscardRangeList;
    Link: TListEntry;
  end;

var
  RegistryLock: TMutex;
  Registry: TListEntry;
  Counters: TVolumeDiscardStatistics;
  IsInitialized: Boolean;

procedure SendAllVolumeDiscardsTask;
begin
  SendAllVolumeDiscards;
end;

procedure InitializeVolumeDiscards;
begin
  InitializeMutex(RegistryLock);
  InitializeListHead(Registry);
  IsInitialized := True;
  RegisterCacheWriterTask(@SendAllVolumeDiscardsTask);
end;

function DiscardsOf(Volume: PVolume): PVolumeDiscards;
begin
  Result := PVolumeDiscards(Volume^.Discards);
end;

function DiscardIsTurnedOff: Boolean;
var
  Value: array[0..7] of Char;
begin
  Result := GetKernelOptionValue('discard', @Value[0], SizeOf(Value)) and (Value[0] = 'o') and
    (Value[1] = 'f') and (Value[2] = 'f');
end;

procedure AttachVolumeDiscards(Volume: PVolume);
var
  Discards: PVolumeDiscards;
begin
  if not IsInitialized or Volume^.IsReadOnly or not BlockDeviceSupportsDiscard(Volume^.Device) or
     DiscardIsTurnedOff then
    Exit;
  Discards := PVolumeDiscards(AllocateZeroedKernelMemory(SizeOf(TVolumeDiscards)));
  if Discards = nil then
    Exit;
  Discards^.Volume := Volume;
  InitializeMutex(Discards^.Lock);
  ClearDiscardRanges(Discards^.Pending);
  ClearDiscardRanges(Discards^.Held);
  AcquireMutex(RegistryLock);
  InsertAtTail(Registry, @Discards^.Link);
  ReleaseMutex(RegistryLock);
  Volume^.Discards := Discards;
end;

function VolumeDiscards(Volume: PVolume): Boolean;
begin
  Result := Volume^.Discards <> nil;
end;

{ Sends the pending batch (discard lock held). }
procedure SendPendingLocked(Discards: PVolumeDiscards);
var
  Volume: PVolume;
  Index: Integer;
  Batch: ^TDiscardRangeList;
begin
  Batch := @Discards^.Pending;
  if Batch^.Count = 0 then
    Exit;
  Volume := Discards^.Volume;
  if Volume^.IsGone or BlockDeviceIsRemoved(Volume^.Device) then
  begin
    ClearDiscardRanges(Batch^);
    Exit;
  end;
  { Freed blocks need not be written: forget them first, then make the
    metadata that freed them durable, then discard. }
  for Index := 0 to Batch^.Count - 1 do
    DiscardCachedRange(Volume^.Device, Batch^.Ranges[Index].Start, Batch^.Ranges[Index].Count);
  if not FlushCachedDevice(Volume^.Device) then
  begin
    { Not durable: the ranges wait for the next round. }
    Inc(Counters.Failures);
    Exit;
  end;
  for Index := 0 to Batch^.Count - 1 do
    if DiscardDeviceRange(Volume^.Device, Batch^.Ranges[Index].Start, Batch^.Ranges[Index].Count) then
      Counters.BytesDiscarded := Counters.BytesDiscarded + Batch^.Ranges[Index].Count
    else
      Inc(Counters.Failures);
  Inc(Counters.BatchesSent);
  ClearDiscardRanges(Batch^);
end;

procedure QueueVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord; AfterCommit: Boolean);
var
  Discards: PVolumeDiscards;
  Target: ^TDiscardRangeList;
begin
  Discards := DiscardsOf(Volume);
  if (Discards = nil) or (ByteCount = 0) then
    Exit;
  AcquireMutex(Discards^.Lock);
  if AfterCommit then
    Target := @Discards^.Held
  else
    Target := @Discards^.Pending;
  if not AddDiscardRange(Target^, ByteOffset, ByteCount) and not AfterCommit then
  begin
    { Full: the batch goes out now, and the range starts the next. }
    SendPendingLocked(Discards);
    AddDiscardRange(Target^, ByteOffset, ByteCount);
  end;
  Counters.BytesQueued := Counters.BytesQueued + ByteCount;
  ReleaseMutex(Discards^.Lock);
end;

procedure CancelVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord);
var
  Discards: PVolumeDiscards;
begin
  Discards := DiscardsOf(Volume);
  if Discards = nil then
    Exit;
  AcquireMutex(Discards^.Lock);
  CancelDiscardRange(Discards^.Pending, ByteOffset, ByteCount);
  CancelDiscardRange(Discards^.Held, ByteOffset, ByteCount);
  ReleaseMutex(Discards^.Lock);
end;

procedure ReleaseCommittedDiscards(Volume: PVolume);
var
  Discards: PVolumeDiscards;
begin
  Discards := DiscardsOf(Volume);
  if (Discards = nil) or (Discards^.Held.Count = 0) then
    Exit;
  AcquireMutex(Discards^.Lock);
  if not MergeDiscardRanges(Discards^.Pending, Discards^.Held) then
  begin
    { Full: send what is pending and try once more; what still finds no
      room is left for fstrim. }
    SendPendingLocked(Discards);
    MergeDiscardRanges(Discards^.Pending, Discards^.Held);
  end;
  ClearDiscardRanges(Discards^.Held);
  ReleaseMutex(Discards^.Lock);
end;

procedure DropUncommittedDiscards(Volume: PVolume);
var
  Discards: PVolumeDiscards;
begin
  Discards := DiscardsOf(Volume);
  if (Discards = nil) or (Discards^.Held.Count = 0) then
    Exit;
  AcquireMutex(Discards^.Lock);
  ClearDiscardRanges(Discards^.Held);
  ReleaseMutex(Discards^.Lock);
end;

procedure SendVolumeDiscards(Volume: PVolume);
var
  Discards: PVolumeDiscards;
begin
  Discards := DiscardsOf(Volume);
  if (Discards = nil) or (Discards^.Pending.Count = 0) then
    Exit;
  AcquireMutex(Discards^.Lock);
  SendPendingLocked(Discards);
  ReleaseMutex(Discards^.Lock);
end;

procedure SendAllVolumeDiscards;
var
  Entry: PListEntry;
  Discards: PVolumeDiscards;
begin
  if not IsInitialized then
    Exit;
  AcquireMutex(RegistryLock);
  Entry := Registry.Next;
  while Entry <> @Registry do
  begin
    Discards := PVolumeDiscards(ContainingRecord(Entry, FieldOffset(PVolumeDiscards(nil)^.Link)));
    if Discards^.Pending.Count > 0 then
    begin
      AcquireMutex(Discards^.Lock);
      SendPendingLocked(Discards);
      ReleaseMutex(Discards^.Lock);
    end;
    Entry := Entry^.Next;
  end;
  ReleaseMutex(RegistryLock);
end;

function TrimFreeRange(Volume: PVolume; ByteOffset, ByteCount: QWord; var Discarded: QWord): Boolean;
begin
  if ByteCount = 0 then
    Exit(True);
  Result := DiscardDeviceRange(Volume^.Device, ByteOffset, ByteCount);
  if Result then
  begin
    Discarded := Discarded + ByteCount;
    Counters.BytesDiscarded := Counters.BytesDiscarded + ByteCount;
  end
  else
    Inc(Counters.Failures);
end;

procedure GetVolumeDiscardStatistics(out Statistics: TVolumeDiscardStatistics);
begin
  Statistics := Counters;
end;

end.
