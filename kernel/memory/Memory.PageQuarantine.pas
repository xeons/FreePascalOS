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
  Heap checking for the physical page allocator (Memory.PhysicalPages),
  on with the kernel heap's quarantine ("heapchecks", Memory.HeapChecks).

  A page freed while something still uses it - a driver whose device
  still writes into a buffer it gave back, a stale translation, a page
  table freed too early - goes unnoticed if the page is handed out again
  at once: the damage lands in someone else's memory, far from the
  cause. With the checks on, a freed page is

    * filled with PageFreeFill (eight of them are a non-canonical
      address, so a pointer read from the page faults when followed),
    * kept out of the free list for a while, in a ring of the last
      PageQuarantineCapacity freed pages (its use is
      PageUsageQuarantined, so freeing it again is caught as a double
      free), and
    * checked when it leaves the ring, just before it can be reused: a
      byte that is no longer the fill is reported with the page and the
      offset, and the system stops.

  Held back pages count as free memory, and when the free list runs dry
  the oldest of them is let go early: the checks never make the system
  run out of memory.

  The ring itself is a plain data structure; the page allocator keeps it
  under its database lock.
}
unit Memory.PageQuarantine;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

const
  PageFreeFill = Byte($F7);
  PageFreeFillWord = QWord($F7F7F7F7F7F7F7F7);
  { 1 MiB of pages held back. }
  PageQuarantineCapacity = 256;
  NoDamage = -1;

type
  TPageQuarantine = record
    Frames: array[0..PageQuarantineCapacity - 1] of QWord;
    { The oldest entry, and how many there are. }
    First: LongWord;
    Count: LongWord;
  end;

{ Fills a freed page (by its address in the window). }
procedure FillFreedPage(Page: Pointer);
{ The offset of the first byte of a freed page that is not the fill, or
  NoDamage. }
function FindFreedPageDamage(Page: Pointer): Int64;

procedure ClearPageQuarantine(out Quarantine: TPageQuarantine);
{ Adds a frame. When the ring was full, its oldest frame leaves it:
  returns True with that frame in Released. }
function QuarantineFrame(var Quarantine: TPageQuarantine; Frame: QWord; out Released: QWord): Boolean;
{ Takes the oldest frame out; False if the ring is empty. }
function ReleaseOldestFrame(var Quarantine: TPageQuarantine; out Released: QWord): Boolean;

{ Stops the system: Page (physical) was written after it was freed. }
procedure ReportFreedPageDamage(PhysicalAddress: TPhysicalAddress; Offset: Int64); noreturn;

implementation

uses
  Kernel.Panic,
  Debug.Output;

procedure FillFreedPage(Page: Pointer);
var
  Words: PQWord;
  Index: QWord;
begin
  Words := PQWord(Page);
  Index := 0;
  while Index < PageSize div SizeOf(QWord) do
  begin
    Words[Index] := PageFreeFillWord;
    Inc(Index);
  end;
end;

function FindFreedPageDamage(Page: Pointer): Int64;
var
  Words: PQWord;
  Bytes: PByte;
  Index: QWord;
  ByteIndex: QWord;
begin
  Words := PQWord(Page);
  Index := 0;
  while Index < PageSize div SizeOf(QWord) do
  begin
    if Words[Index] <> PageFreeFillWord then
    begin
      Bytes := PByte(Page) + Index * SizeOf(QWord);
      ByteIndex := 0;
      while (ByteIndex < SizeOf(QWord)) and (Bytes[ByteIndex] = PageFreeFill) do
        Inc(ByteIndex);
      Exit(Int64(Index * SizeOf(QWord) + ByteIndex));
    end;
    Inc(Index);
  end;
  Result := NoDamage;
end;

procedure ClearPageQuarantine(out Quarantine: TPageQuarantine);
begin
  Quarantine.First := 0;
  Quarantine.Count := 0;
end;

function QuarantineFrame(var Quarantine: TPageQuarantine; Frame: QWord; out Released: QWord): Boolean;
var
  Slot: LongWord;
begin
  Released := 0;
  Result := Quarantine.Count = PageQuarantineCapacity;
  if Result then
  begin
    { The oldest leaves; the new one takes its slot, now the newest. }
    Released := Quarantine.Frames[Quarantine.First];
    Quarantine.Frames[Quarantine.First] := Frame;
    Quarantine.First := (Quarantine.First + 1) mod PageQuarantineCapacity;
    Exit;
  end;
  Slot := (Quarantine.First + Quarantine.Count) mod PageQuarantineCapacity;
  Quarantine.Frames[Slot] := Frame;
  Inc(Quarantine.Count);
end;

function ReleaseOldestFrame(var Quarantine: TPageQuarantine; out Released: QWord): Boolean;
begin
  Released := 0;
  Result := Quarantine.Count > 0;
  if not Result then
    Exit;
  Released := Quarantine.Frames[Quarantine.First];
  Quarantine.First := (Quarantine.First + 1) mod PageQuarantineCapacity;
  Dec(Quarantine.Count);
end;

procedure ReportFreedPageDamage(PhysicalAddress: TPhysicalAddress; Offset: Int64);
var
  Found: Byte;
begin
  Found := PByte(PhysicalToVirtual(PhysicalAddress))[Offset];
  BeginKernelPanic(PanicHeapCorruption, 'physical page written after it was freed');
  DebugWrite('  Page:       ');
  DebugWriteAddress(PhysicalAddress);
  DebugWriteLine(' (physical)');
  DebugWrite('  Offset:     ');
  DebugWriteDecimal(QWord(Offset));
  DebugWrite(' holds 0x');
  DebugWriteHex(Found, 2);
  DebugWrite(' instead of 0x');
  DebugWriteHex(PageFreeFill, 2);
  DebugWriteLine('');
  FinishKernelPanic;
end;

end.
