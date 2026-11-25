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
  The entries of a mapped file's page table (Processes.MappedFiles).

  An entry is 0 while the page is not in memory, else the physical
  address of the page (page aligned) with flags in its low bits:

    Dirty      written through a shared writable mapping and not
               written back to the file yet;
    Preserved  a page of a snapshot (a mapped file whose file changed
               while copy on write mappings used it) whose file
               contents changed since: it cannot be read again, so it
               is never evicted.

  Kept free of kernel units so the host test (tools/MappedFileTest)
  checks it.
}
unit Processes.MappedPageEntries;

{$mode objfpc}

interface

const
  MappedPageDirty = QWord(1);
  MappedPagePreserved = QWord(2);
  MappedPageFlagMask = QWord($FFF);

function MakeMappedPageEntry(Physical, Flags: QWord): QWord;
function MappedPagePhysical(Entry: QWord): QWord;
function MappedPageIsDirty(Entry: QWord): Boolean;
function MappedPageIsPreserved(Entry: QWord): Boolean;
{ True for a page in memory with no flag: it may be dropped (and read
  again from the file when needed) if nobody else holds it. }
function MappedPageIsEvictable(Entry: QWord): Boolean;

implementation

function MakeMappedPageEntry(Physical, Flags: QWord): QWord;
begin
  Result := (Physical and not MappedPageFlagMask) or (Flags and MappedPageFlagMask);
end;

function MappedPagePhysical(Entry: QWord): QWord;
begin
  Result := Entry and not MappedPageFlagMask;
end;

function MappedPageIsDirty(Entry: QWord): Boolean;
begin
  Result := (Entry and MappedPageDirty) <> 0;
end;

function MappedPageIsPreserved(Entry: QWord): Boolean;
begin
  Result := (Entry and MappedPagePreserved) <> 0;
end;

function MappedPageIsEvictable(Entry: QWord): Boolean;
begin
  Result := (MappedPagePhysical(Entry) <> 0) and ((Entry and MappedPageFlagMask) = 0);
end;

end.
