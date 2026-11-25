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
  Copying an address space for fork (Processes.Fork).

  The copy has the same layout and the same regions; no page is copied.
  Every page of a private region (heap, stacks, thread data, images,
  private file mappings) is mapped copy on write in both spaces, each
  holding a reference, whatever its protection now: a page read-only or
  inaccessible today may be made writable later (mprotect), and that
  must not write the other side's memory. The first write of either side
  gives that side its own copy (BreakCopyOnWriteLocked). The pages of
  sections and shared file mappings are mapped as they are, with a
  reference more. Pages not touched yet stay so in both. Device memory
  is not copied: the child has none of it.
}
unit Processes.AddressSpaceCopy;

{$mode objfpc}

interface

uses
  Processes.AddressSpace;

function DuplicateAddressSpace(Source: PAddressSpace; out Copy: PAddressSpace): LongInt;

implementation

uses
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Processes.UserRegions,
  Processes.RegionTree,
  Processes.MappedFiles;

type
  TCopyContext = record
    Source: PAddressSpace;
    Target: PAddressSpace;
    Error: LongInt;
  end;
  PCopyContext = ^TCopyContext;

{ Pages that both sides keep writing to the same memory. }
function SharesWrites(Region: PUserRegion): Boolean;
begin
  Result := (Region^.Kind = RegionKindSection) or
    ((Region^.Kind = RegionKindFileMapping) and not Region^.BackingIsPrivate);
end;

{ Remaps the source's page at Address copy on write (it was writable). }
procedure MarkSourcePageCopyOnWrite(Source: PAddressSpace; Address: QWord; Physical: TPhysicalAddress;
  Mapping: LongWord);
begin
  UnmapPageInAddressSpace(Source^.Root, Address);
  MapPageInAddressSpace(Source^.Root, Address, Physical, Mapping);
end;

function CopyRegionPages(Context: PCopyContext; Region: PUserRegion): LongInt;
var
  Offset: QWord;
  Address: QWord;
  Physical: TPhysicalAddress;
  IsCopyOnWrite: Boolean;
  Mapping: LongWord;
  PageMapping: LongWord;
  Private_: Boolean;
begin
  Result := ErrorNone;
  Mapping := RegionMapping(Region);
  Private_ := not SharesWrites(Region);
  Offset := 0;
  while Offset < Region^.Length do
  begin
    Address := Region^.Start + Offset;
    Offset := Offset + PageSize;
    if not QueryPageInAddressSpace(Context^.Source^.Root, Address, Physical, IsCopyOnWrite) then
      Continue;
    Physical := RoundDownToPage(Physical);
    if not Private_ then
    begin
      PageMapping := Mapping;
      if (Region^.Kind = RegionKindFileMapping) then
        PageMapping := PageMapping and not MappingWritable;
    end
    else
    begin
      PageMapping := (Mapping and not MappingWritable) or MappingCopyOnWrite;
      if not IsCopyOnWrite then
        MarkSourcePageCopyOnWrite(Context^.Source, Address, Physical, PageMapping);
    end;
    ReferencePhysicalPage(Physical);
    if not MapPageInAddressSpace(Context^.Target^.Root, Address, Physical, PageMapping) then
    begin
      FreePhysicalPage(Physical);
      Exit(ErrorOutOfMemory);
    end;
    Inc(Context^.Target^.CommittedPages);
    if PageUsageOf(Physical) <> PageUsageUserMemory then
      Inc(Context^.Target^.SharedPages);
  end;
  if Context^.Target^.CommittedPages > Context^.Target^.PeakCommittedPages then
    Context^.Target^.PeakCommittedPages := Context^.Target^.CommittedPages;
end;

procedure CopyRegion(Region: PUserRegion; Context: Pointer);
var
  CopyContext: PCopyContext;
  Template: TUserRegion;
  Error: LongInt;
begin
  CopyContext := PCopyContext(Context);
  if (CopyContext^.Error <> ErrorNone) or (Region^.Kind = RegionKindDevice) then
    Exit;
  Template := Region^;
  if Template.Backing <> nil then
    ReferenceMappedFile(PMappedFile(Template.Backing), Template.BackingIsPrivate);
  Error := AddRegionRecordLocked(CopyContext^.Target, Template);
  if Error <> ErrorNone then
  begin
    if Template.Backing <> nil then
      ReleaseMappedFile(PMappedFile(Template.Backing), Template.BackingIsPrivate);
    CopyContext^.Error := Error;
    Exit;
  end;
  { The stack reserve's state is the source's (AddRegionRecordLocked
    sized it afresh). }
  FindRegionLocked(CopyContext^.Target, Template.Start)^.ReserveBytes := Region^.ReserveBytes;
  FindRegionLocked(CopyContext^.Target, Template.Start)^.ReserveInUse := Region^.ReserveInUse;
  CopyContext^.Error := CopyRegionPages(CopyContext, Region);
end;

function DuplicateAddressSpace(Source: PAddressSpace; out Copy: PAddressSpace): LongInt;
var
  Context: TCopyContext;
  PreviousLevel: TPriorityLevel;
begin
  Result := CreateAddressSpace(Copy);
  if Result <> ErrorNone then
    Exit;
  Copy^.Layout := Source^.Layout;
  Copy^.NextLibraryAddress := Source^.NextLibraryAddress;
  Copy^.RegionLimit := Source^.RegionLimit;
  Copy^.CommitLimitPages := Source^.CommitLimitPages;
  Copy^.AllowsDynamicCode := Source^.AllowsDynamicCode;
  Context.Source := Source;
  Context.Target := Copy;
  Context.Error := ErrorNone;
  PreviousLevel := AcquireSpinLock(Source^.Lock);
  VisitRegions(Source^.Regions, @CopyRegion, @Context);
  ReleaseSpinLock(Source^.Lock, PreviousLevel);
  Result := Context.Error;
  if Result <> ErrorNone then
  begin
    DestroyAddressSpace(Copy);
    Copy := nil;
  end;
end;

end.
