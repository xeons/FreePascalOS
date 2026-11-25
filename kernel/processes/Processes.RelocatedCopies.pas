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
  Relocated copies of image pages: the pages of a program or library
  that its relocations write, as they came out for one load address and
  one set of symbol resolutions, kept with the image's section
  (Processes.ImageSections) so a later load at the same address with
  the same resolutions maps them (copy on write, like the section's
  built pages) instead of relocating again.

  A copy is keyed by the load bias and a key the loader makes
  (Processes.ImageLoader): every value its relocations depend on
  besides the file itself - where each symbol they name resolved to,
  the thread-local storage placements - so two loads with equal keys
  write exactly the same bytes. The pages are referenced by the copy;
  processes that map them take references of their own, so dropping a
  copy (its section dropped, the table full, memory short) never takes
  a page from under anyone.

  A copy is reference counted while a load maps its pages: the section
  table's lock is not held across that.
}
unit Processes.RelocatedCopies;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

type
  PRelocatedCopy = ^TRelocatedCopy;
  TRelocatedCopy = record
    Bias: QWord;
    { The loader's key (kernel memory). }
    Key: PByte;
    KeyLength: QWord;
    { PageCount pages: the index of each in the memory image and the
      page (referenced). }
    PageCount: QWord;
    PageIndices: PQWord;
    Pages: PQWord;
    { The table's reference plus one per load using it. }
    References: Int64;
    LastUse: QWord;
  end;

  TRelocatedCopyCounters = record
    Copies: Int64;
    Pages: Int64;
    Reused: Int64;
    Kept: Int64;
    NotKept: Int64;
    SharedPlacements: Int64;
    Dropped: Int64;
  end;

var
  { Updated with atomic operations or under the section table's lock. }
  RelocatedCopyCounters: TRelocatedCopyCounters;

{ A copy taking over Key (kernel memory, KeyLength bytes) and PageCount
  pages (PageIndices and Pages, kernel arrays, each page with one
  reference for the copy); nil if memory is short (nothing taken then). }
function CreateRelocatedCopy(Bias: QWord; Key: PByte; KeyLength: QWord; PageCount: QWord;
  PageIndices, Pages: PQWord): PRelocatedCopy;
function RelocatedCopyMatches(Copy: PRelocatedCopy; Bias: QWord; Key: PByte; KeyLength: QWord): Boolean;
procedure ReferenceRelocatedCopy(Copy: PRelocatedCopy);
{ Drops a reference; the last frees the copy and its references to the
  pages. Returns the pages that went back to the free list with it. }
function ReleaseRelocatedCopy(Copy: PRelocatedCopy): QWord;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.KernelHeap,
  Memory.PhysicalPages;

function CreateRelocatedCopy(Bias: QWord; Key: PByte; KeyLength: QWord; PageCount: QWord;
  PageIndices, Pages: PQWord): PRelocatedCopy;
begin
  Result := PRelocatedCopy(AllocateZeroedKernelMemory(SizeOf(TRelocatedCopy)));
  if Result = nil then
    Exit;
  Result^.Bias := Bias;
  Result^.Key := Key;
  Result^.KeyLength := KeyLength;
  Result^.PageCount := PageCount;
  Result^.PageIndices := PageIndices;
  Result^.Pages := Pages;
  Result^.References := 1;
  AtomicIncrement(RelocatedCopyCounters.Copies);
  AtomicFetchAndAdd(RelocatedCopyCounters.Pages, Int64(PageCount));
end;

function RelocatedCopyMatches(Copy: PRelocatedCopy; Bias: QWord; Key: PByte; KeyLength: QWord): Boolean;
begin
  Result := (Copy^.Bias = Bias) and (Copy^.KeyLength = KeyLength) and
    ((KeyLength = 0) or MemoryIsEqual(Copy^.Key, Key, KeyLength));
end;

procedure ReferenceRelocatedCopy(Copy: PRelocatedCopy);
begin
  AtomicIncrement(Copy^.References);
end;

function ReleaseRelocatedCopy(Copy: PRelocatedCopy): QWord;
var
  Index: QWord;
begin
  Result := 0;
  if (Copy = nil) or (AtomicDecrement(Copy^.References) <> 0) then
    Exit;
  Index := 0;
  while Index < Copy^.PageCount do
  begin
    if PhysicalPageHolderCount(Copy^.Pages[Index]) = 1 then
      Inc(Result);
    FreePhysicalPage(Copy^.Pages[Index]);
    Inc(Index);
  end;
  AtomicDecrement(RelocatedCopyCounters.Copies);
  AtomicFetchAndAdd(RelocatedCopyCounters.Pages, -Int64(Copy^.PageCount));
  FreeKernelMemory(Copy^.Key);
  FreeKernelMemory(Copy^.PageIndices);
  FreeKernelMemory(Copy^.Pages);
  FreeKernelMemory(Copy);
end;

end.
