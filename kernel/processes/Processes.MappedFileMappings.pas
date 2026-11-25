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
  The mappings of a mapped file, in every address space: reaching the
  page table entries that map its pages.

  A mapped file lists the region nodes mapping it, each with its address
  space (Processes.MappedFiles, AttachMappedFileMapper). VisitMappings
  takes a reference to each address space on the list (one being
  destroyed is left alone: its pages go with it), then, one space at a
  time, holds the space's lock and the mapped file's lock and hands
  every region of that space on the list to the visitor. Regions do not
  go while the space's lock is held, so the nodes found under both
  locks are alive. Only one space lock is ever held, so this never
  deadlocks with fork (which holds the parent's and the child's).

  Two visitors use it:

    * ProtectMappedPages (the mapped files' page protector): before a
      dirty page is written back, every shared mapping of it loses
      write access to it, so the next write faults and marks it dirty
      again;
    * UnmapMappedPages (eviction, Processes.MappedFileEviction): the
      entries mapping one of a set of pages are removed (with the
      mapping's reference to the page), so the page can be dropped and
      read again on the next touch.
}
unit Processes.MappedFileMappings;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.AddressSpace,
  Processes.UserRegions,
  Processes.MappedFiles;

type
  { Called with the space's and the mapped file's locks held: changes
    page table entries only. }
  TMappingVisitor = procedure(Space: PAddressSpace; Region: PUserRegion; Context: Pointer);

procedure InitializeMappedFileMappings;
{ Visits every region mapping MappedFile. Passive level, no lock held. }
procedure VisitMappings(MappedFile: PMappedFile; Visit: TMappingVisitor; Context: Pointer);
{ Removes every mapping of the pages Pages[0..Count-1] (sorted by page
  index, each referenced by the caller). Passive level. }
procedure UnmapMappedPages(MappedFile: PMappedFile; Pages: PMappedPageReference; Count: Integer);

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Processes.RegionTree,
  Processes.MappedFileRanges;

type
  PPAddressSpace = ^PAddressSpace;

{ The distinct spaces on the list, each with a reference, in kernel
  memory. False if memory ran out. }
function CollectSpaces(MappedFile: PMappedFile; out Spaces: PPAddressSpace; out Count: Integer): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Capacity: Integer;
  Node: PRegionNode;
  Index: Integer;
  Known: Boolean;
  Fits: Boolean;
begin
  Count := 0;
  repeat
    Capacity := MappedFile^.MapperCount + 4;
    Spaces := PPAddressSpace(AllocateKernelMemory(QWord(Capacity) * SizeOf(PAddressSpace)));
    if Spaces = nil then
      Exit(False);
    Count := 0;
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Fits := MappedFile^.MapperCount <= Capacity;
    Node := MappedFile^.Mappers;
    while Fits and (Node <> nil) do
    begin
      Known := False;
      for Index := 0 to Count - 1 do
        if Spaces[Index] = PAddressSpace(Node^.MapperSpace) then
          Known := True;
      if not Known and TryReferenceAddressSpace(PAddressSpace(Node^.MapperSpace)) then
      begin
        Spaces[Count] := PAddressSpace(Node^.MapperSpace);
        Inc(Count);
      end;
      Node := Node^.MapperNext;
    end;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if not Fits then
    begin
      for Index := 0 to Count - 1 do
        ReleaseAddressSpaceReference(Spaces[Index]);
      FreeKernelMemory(Spaces);
      Count := 0;
    end;
  until Fits;
  Result := True;
end;

procedure VisitMappings(MappedFile: PMappedFile; Visit: TMappingVisitor; Context: Pointer);
var
  Spaces: PPAddressSpace;
  Count: Integer;
  Index: Integer;
  Space: PAddressSpace;
  SpaceLevel: TPriorityLevel;
  FileLevel: TPriorityLevel;
  Node: PRegionNode;
begin
  if MappedFile^.MapperCount = 0 then
    Exit;
  if not CollectSpaces(MappedFile, Spaces, Count) then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    Space := Spaces[Index];
    SpaceLevel := AcquireSpinLock(Space^.Lock);
    FileLevel := AcquireSpinLock(MappedFile^.Lock);
    Node := MappedFile^.Mappers;
    while Node <> nil do
    begin
      if Node^.MapperSpace = Pointer(Space) then
        Visit(Space, @Node^.Region, Context);
      Node := Node^.MapperNext;
    end;
    ReleaseSpinLock(MappedFile^.Lock, FileLevel);
    ReleaseSpinLock(Space^.Lock, SpaceLevel);
  end;
  for Index := 0 to Count - 1 do
    ReleaseAddressSpaceReference(Spaces[Index]);
  FreeKernelMemory(Spaces);
end;

{ The file page span the region maps. }
procedure RegionPageSpan(Region: PUserRegion; out FirstPage, PageCount: QWord);
begin
  FirstPage := Region^.BackingOffset div PageSize;
  PageCount := Region^.Length div PageSize;
end;

{ --- Taking write access ------------------------------------------------ }

type
  TPageSpan = record
    FirstPage: QWord;
    EndPage: QWord;
  end;
  PPageSpan = ^TPageSpan;

procedure ProtectVisitor(Space: PAddressSpace; Region: PUserRegion; Context: Pointer);
var
  Span: PPageSpan;
  RegionFirst: QWord;
  RegionPages: QWord;
  First: QWord;
  Finish: QWord;
  PageIndex: QWord;
  Address: QWord;
  Physical: TPhysicalAddress;
  IsCopyOnWrite: Boolean;
begin
  { Only shared writable mappings write the pages themselves. }
  if Region^.BackingIsPrivate or not Region^.BackingIsWritable then
    Exit;
  Span := PPageSpan(Context);
  RegionPageSpan(Region, RegionFirst, RegionPages);
  if not MappedOverlap(RegionFirst, RegionPages, Span^.FirstPage, Span^.EndPage, First, Finish) then
    Exit;
  PageIndex := First;
  while PageIndex < Finish do
  begin
    Address := Region^.Start + (PageIndex - RegionFirst) * PageSize;
    if QueryPageInAddressSpace(Space^.Root, Address, Physical, IsCopyOnWrite) then
    begin
      Physical := RoundDownToPage(Physical);
      UnmapPageInAddressSpace(Space^.Root, Address);
      if not MapPageInAddressSpace(Space^.Root, Address, Physical,
         RegionMapping(Region) and not MappingWritable) then
      begin
        FreePhysicalPage(Physical);
        Dec(Space^.CommittedPages);
        if Space^.SharedPages > 0 then
          Dec(Space^.SharedPages);
      end;
    end;
    Inc(PageIndex);
  end;
end;

procedure ProtectMappedPages(MappedFile: PMappedFile; FirstPage, EndPage: QWord);
var
  Span: TPageSpan;
begin
  Span.FirstPage := FirstPage;
  Span.EndPage := EndPage;
  VisitMappings(MappedFile, @ProtectVisitor, @Span);
end;

{ --- Removing mappings ---------------------------------------------------- }

type
  TPageSet = record
    Pages: PMappedPageReference;
    Count: Integer;
  end;
  PPageSet = ^TPageSet;

procedure UnmapVisitor(Space: PAddressSpace; Region: PUserRegion; Context: Pointer);
var
  PageSet: PPageSet;
  RegionFirst: QWord;
  RegionPages: QWord;
  Index: Integer;
  PageIndex: QWord;
  Address: QWord;
  Physical: TPhysicalAddress;
begin
  PageSet := PPageSet(Context);
  RegionPageSpan(Region, RegionFirst, RegionPages);
  for Index := 0 to PageSet^.Count - 1 do
  begin
    PageIndex := PageSet^.Pages[Index].PageIndex;
    if (PageIndex < RegionFirst) or (PageIndex >= RegionFirst + RegionPages) then
      Continue;
    Address := Region^.Start + (PageIndex - RegionFirst) * PageSize;
    { Only the file's page itself, not a private copy made of it. }
    if not TranslateInAddressSpace(Space^.Root, Address, Physical) or
       (RoundDownToPage(Physical) <> PageSet^.Pages[Index].Physical) then
      Continue;
    UnmapPageInAddressSpace(Space^.Root, Address);
    FreePhysicalPage(PageSet^.Pages[Index].Physical);
    Dec(Space^.CommittedPages);
    if Space^.SharedPages > 0 then
      Dec(Space^.SharedPages);
    Inc(MappedMappingsDropped);
  end;
end;

procedure UnmapMappedPages(MappedFile: PMappedFile; Pages: PMappedPageReference; Count: Integer);
var
  PageSet: TPageSet;
begin
  if Count = 0 then
    Exit;
  PageSet.Pages := Pages;
  PageSet.Count := Count;
  VisitMappings(MappedFile, @UnmapVisitor, @PageSet);
end;

procedure InitializeMappedFileMappings;
begin
  SetMappedPageProtector(@ProtectMappedPages);
end;

end.
