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
  A quarantine for freed memory: a first in, first out queue that holds
  freed blocks for a while before they can be reused (Memory.HeapChecks).

  As long as a block waits here nothing else gets its memory, so a stale
  pointer still finds the free fill pattern (and faults), and a write
  through it is found when the block leaves. The queue is bounded both
  by the number of entries and by the bytes they hold; the owner takes
  the oldest entries out until a new one fits.

  It keeps no memory of its own beyond a fixed table, and does no
  locking: the owner (the kernel heap) holds its lock around every call.
}
unit Memory.HeapQuarantine;

{$mode objfpc}

interface

const
  QuarantineCapacity = 1024;

type
  TQuarantineEntry = record
    Block: Pointer;
    ByteCount: QWord;
    { The code address that freed the block, for the report if it was
      written to while it waited. }
    FreedBy: QWord;
  end;

  TQuarantine = record
    Entries: array[0..QuarantineCapacity - 1] of TQuarantineEntry;
    Oldest: LongWord;
    Count: LongWord;
    Bytes: QWord;
    MaximumCount: LongWord;
    MaximumBytes: QWord;
  end;

{ MaximumCount is at most QuarantineCapacity. }
procedure InitializeQuarantine(var Quarantine: TQuarantine; MaximumCount: LongWord; MaximumBytes: QWord);

{ True while the oldest entries must leave before one of ByteCount
  bytes can be added. }
function QuarantineIsFullFor(const Quarantine: TQuarantine; ByteCount: QWord): Boolean;

{ Adds an entry; the caller made room first (QuarantineIsFullFor). }
procedure AddToQuarantine(var Quarantine: TQuarantine; const Entry: TQuarantineEntry);

{ Takes the oldest entry out; False if the quarantine is empty. }
function TakeOldestFromQuarantine(var Quarantine: TQuarantine; out Entry: TQuarantineEntry): Boolean;

{ Finds the entry for Block (for the report of a double free). }
function FindInQuarantine(const Quarantine: TQuarantine; Block: Pointer; out Entry: TQuarantineEntry): Boolean;

implementation

procedure InitializeQuarantine(var Quarantine: TQuarantine; MaximumCount: LongWord; MaximumBytes: QWord);
begin
  Quarantine.Oldest := 0;
  Quarantine.Count := 0;
  Quarantine.Bytes := 0;
  if MaximumCount > QuarantineCapacity then
    MaximumCount := QuarantineCapacity;
  Quarantine.MaximumCount := MaximumCount;
  Quarantine.MaximumBytes := MaximumBytes;
end;

function QuarantineIsFullFor(const Quarantine: TQuarantine; ByteCount: QWord): Boolean;
begin
  if Quarantine.Count = 0 then
    Exit(False);
  Result := (Quarantine.Count >= Quarantine.MaximumCount) or
    (Quarantine.Bytes + ByteCount > Quarantine.MaximumBytes);
end;

procedure AddToQuarantine(var Quarantine: TQuarantine; const Entry: TQuarantineEntry);
var
  Slot: LongWord;
begin
  Slot := (Quarantine.Oldest + Quarantine.Count) mod QuarantineCapacity;
  Quarantine.Entries[Slot] := Entry;
  Inc(Quarantine.Count);
  Quarantine.Bytes := Quarantine.Bytes + Entry.ByteCount;
end;

function TakeOldestFromQuarantine(var Quarantine: TQuarantine; out Entry: TQuarantineEntry): Boolean;
begin
  Entry.Block := nil;
  Entry.ByteCount := 0;
  Entry.FreedBy := 0;
  if Quarantine.Count = 0 then
    Exit(False);
  Entry := Quarantine.Entries[Quarantine.Oldest];
  Quarantine.Oldest := (Quarantine.Oldest + 1) mod QuarantineCapacity;
  Dec(Quarantine.Count);
  Quarantine.Bytes := Quarantine.Bytes - Entry.ByteCount;
  Result := True;
end;

function FindInQuarantine(const Quarantine: TQuarantine; Block: Pointer; out Entry: TQuarantineEntry): Boolean;
var
  Index: LongWord;
  Slot: LongWord;
begin
  Index := 0;
  while Index < Quarantine.Count do
  begin
    Slot := (Quarantine.Oldest + Index) mod QuarantineCapacity;
    if Quarantine.Entries[Slot].Block = Block then
    begin
      Entry := Quarantine.Entries[Slot];
      Exit(True);
    end;
    Inc(Index);
  end;
  Entry.Block := nil;
  Entry.ByteCount := 0;
  Entry.FreedBy := 0;
  Result := False;
end;

end.
