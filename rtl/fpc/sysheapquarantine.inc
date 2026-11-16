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
  Heap checking (sysheapcheck.inc): the quarantine, a first in, first
  out queue of freed blocks that are not given back to the heap yet.

  While a block waits here nothing else can get its memory, so a stale
  pointer still finds the free fill (and faults when it follows a
  pointer read from it), and a write through it is found when the block
  leaves. The queue is bounded by entries and by bytes; before a block
  is added the oldest ones are taken out until it fits, and the caller
  checks them and gives them back to the heap. Blocks larger than
  QuarantineLargestBlock are not kept (they would push out everything
  else); they are filled and freed at once.

  The threads of a program share the queue, under its own lock. The
  lock is never held while the heap's own lock is taken: blocks are
  checked and freed after it is released.
}

const
  QuarantineCapacity = 1024;
  QuarantineByteLimit = 512 * 1024;
  QuarantineLargestBlock = 64 * 1024;

type
  TQuarantineEntry = record
    Block: Pointer;
    ByteCount: PtrUInt;
    FreedBy: THeapCheckFreedBy;
  end;

var
  QuarantineEntries: array[0..QuarantineCapacity - 1] of TQuarantineEntry;
  QuarantineOldest: SizeInt;
  QuarantineCount: SizeInt;
  QuarantineBytes: PtrUInt;
  QuarantineLock: LongInt = LockFree;

function QuarantineIsFullFor(ByteCount: PtrUInt): Boolean;
begin
  QuarantineIsFullFor := (QuarantineCount > 0) and
    ((QuarantineCount >= QuarantineCapacity) or (QuarantineBytes + ByteCount > QuarantineByteLimit));
end;

{ Takes the oldest entry out if a block of ByteCount bytes does not fit
  yet; the caller checks it and frees it, then asks again. }
function TakeOldestToMakeRoom(ByteCount: PtrUInt; out Entry: TQuarantineEntry): Boolean;
begin
  AcquireWordLock(QuarantineLock);
  TakeOldestToMakeRoom := QuarantineIsFullFor(ByteCount);
  if TakeOldestToMakeRoom then
  begin
    Entry := QuarantineEntries[QuarantineOldest];
    QuarantineOldest := (QuarantineOldest + 1) mod QuarantineCapacity;
    Dec(QuarantineCount);
    QuarantineBytes := QuarantineBytes - Entry.ByteCount;
  end;
  ReleaseWordLock(QuarantineLock);
end;

{ Adds Entry. Another thread may have filled the room made for it in
  the meantime: then the oldest entry leaves first, into Leaving (and
  the result is True), for the caller to check and free. }
function AddToQuarantine(const Entry: TQuarantineEntry; out Leaving: TQuarantineEntry): Boolean;
var
  Slot: SizeInt;
begin
  AcquireWordLock(QuarantineLock);
  AddToQuarantine := QuarantineCount >= QuarantineCapacity;
  if AddToQuarantine then
  begin
    Leaving := QuarantineEntries[QuarantineOldest];
    QuarantineOldest := (QuarantineOldest + 1) mod QuarantineCapacity;
    Dec(QuarantineCount);
    QuarantineBytes := QuarantineBytes - Leaving.ByteCount;
  end;
  Slot := (QuarantineOldest + QuarantineCount) mod QuarantineCapacity;
  QuarantineEntries[Slot] := Entry;
  Inc(QuarantineCount);
  QuarantineBytes := QuarantineBytes + Entry.ByteCount;
  ReleaseWordLock(QuarantineLock);
end;

{ The entry of Block, for the report of a double free; False if the
  block is not (or no longer) in the quarantine. }
function FindInQuarantine(Block: Pointer; out Entry: TQuarantineEntry): Boolean;
var
  Index: SizeInt;
  Slot: SizeInt;
begin
  FindInQuarantine := False;
  FillChar(Entry, SizeOf(Entry), 0);
  AcquireWordLock(QuarantineLock);
  for Index := 0 to QuarantineCount - 1 do
  begin
    Slot := (QuarantineOldest + Index) mod QuarantineCapacity;
    if QuarantineEntries[Slot].Block = Block then
    begin
      Entry := QuarantineEntries[Slot];
      FindInQuarantine := True;
      Break;
    end;
  end;
  ReleaseWordLock(QuarantineLock);
end;
