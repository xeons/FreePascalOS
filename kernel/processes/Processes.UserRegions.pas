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
  The regions of a user address space (Processes.AddressSpace): ranges
  of user addresses with fixed attributes, kept in a region tree
  (Processes.RegionTree).
}
unit Processes.UserRegions;

{$mode objfpc}

interface

type
  TRegionKind = (RegionKindImage, RegionKindStack, RegionKindAllocation,
    { A thread's thread control block and static thread-local storage. }
    RegionKindThreadData,
    { Address space below a stack that is never mapped. }
    RegionKindStackGuard,
    { Device memory, mapped when the region was made. }
    RegionKindDevice,
    { A section's pages, mapped when the region was made. }
    RegionKindSection,
    { A file mapped with CallMapHandle: its pages come from the file
      (Backing) when first touched. }
    RegionKindFileMapping);

  TUserRegion = record
    Start: QWord;
    Length: QWord;
    Attributes: LongWord;
    Kind: TRegionKind;
    CommitsOnDemand: Boolean;
    { Stacks: the bottom ReserveBytes are only provided once a stack
      overflow opened them (ReserveInUse). }
    ReserveInUse: Boolean;
    ReserveBytes: QWord;
    { A run time allocation made for one thread (its threadvar block):
      the id of that thread, which gives the region back if it ends
      without having freed it. 0 for every other region. }
    OwnerThreadId: QWord;
    { Run time allocations, reservations and file mappings, which may be
      split into several regions (pages committed, decommitted or
      protected apart from the rest): the start of the allocation the
      region is part of (the address the program frees). 0 for regions
      that are never split. }
    AllocationBase: QWord;
    { A one-shot guard: the first touch raises ExceptionGuardPage and
      takes the guard off the page touched. }
    IsGuard: Boolean;
    { Pages from a file (a TMappedFile, Processes.MappedFiles) instead
      of zero filled ones: the region's first page is the file's page at
      BackingOffset. The region holds a reference to it. }
    Backing: Pointer;
    BackingOffset: QWord;
    { Writes go to a copy of the page (copy on write), never to the
      file. }
    BackingIsPrivate: Boolean;
    { A shared file mapping made from a handle open for writing: it may
      be (made) writable, and what is written reaches the file (the
      mapped file's pages are marked dirty and written back). }
    BackingIsWritable: Boolean;
    { Program images: the load that mapped the region (a number of
      Processes.ImageLoader's), so a load that fails takes back its own
      regions and nothing else. 0 for every other region. }
    LoadTag: QWord;
  end;
  PUserRegion = ^TUserRegion;

implementation

end.
