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
  AArch64 translation tables (4 KiB granule, 48-bit addresses, four
  levels; the format is in Boot.TranslationTableFormat).

  The two halves of the address space have separate roots: the kernel's
  (TTBR1_EL1), built by the loader and kept, and one per user address
  space (TTBR0_EL1), which holds only the user half - unlike x86-64,
  where every top level table also carries the kernel half. The
  "kernel address space" (root 0, or the kernel root) loads an empty
  table into TTBR0_EL1, so no user mapping stays reachable.

  Kernel mappings are global; user mappings are not global and are
  tagged with the address space's ASID (Memory.Arch.AddressSpaceIds), so
  switching TTBR0_EL1 invalidates nothing. The ASID's context is kept in
  the user root table's last entry, which translation never uses (user
  space ends at 2^47), with its valid bit clear. Removing a mapping
  invalidates it on every processor at once, for every ASID (TLBI
  ...IS); the architecture independent shootdown requests still go out
  (Kernel.InterProcessor) and only repeat that.

  Device memory is device-nGnRE, write-combining memory (framebuffers)
  normal non-cacheable, everything else normal write-back memory.

  The instruction caches do not see what the kernel writes through the
  data side (reading a program's code from its file, for one), so a page
  mapped executable for user mode has its code synchronized first: its
  data cache lines cleaned to the point of unification and its
  instruction cache lines invalidated, on every processor.
}
unit Memory.Arch.PageTables;

{$mode objfpc}

interface

uses
  Memory.Layout;

const
  { Architecture independent mapping attributes. }
  MappingWritable = LongWord(1) shl 0;
  MappingExecutable = LongWord(1) shl 1;
  MappingUser = LongWord(1) shl 2;
  MappingUncached = LongWord(1) shl 3;
  { A shared page that is copied on the first write: mapped read-only and
    marked, so the page fault resolver knows to copy it
    (Processes.AddressSpace). Combined with MappingWritable it means
    "writable once copied". }
  MappingCopyOnWrite = LongWord(1) shl 4;
  { Writes may be combined and delayed (framebuffers). }
  MappingWriteCombining = LongWord(1) shl 5;
  { Device memory, not a page of the page allocator: never freed with
    the mapping, and not returned by unmapping. }
  MappingDevice = LongWord(1) shl 6;
  { A user page the program may not touch at all (no access, or a guard,
    Processes.VirtualMemory): mapped for the kernel only, so the page
    stays where it is and a touch from user mode is a protection fault. }
  MappingNoAccess = LongWord(1) shl 7;

  { First address above user space. }
  UserSpaceLimit = QWord($0000800000000000);

  { Pages unmapped together, so the other processors are interrupted
    once for all of them. }
  MaximumPagesPerRun = 32;

type
  { The physical pages a run of unmapped pages pointed to (zero where
    nothing was mapped). The caller frees them, if they are its to free,
    only after the run was unmapped: until then another processor may
    still reach them through a stale translation. }
  TPhysicalPageRun = array[0..MaximumPagesPerRun - 1] of TPhysicalAddress;

procedure InitializeKernelPageTables;

{ Replaces the identity mapping the loader left in TTBR0_EL1 with an
  empty user half. }
procedure RemoveBootIdentityMapping;

{ Maps one 4 KiB page. Returns False if a page table could not be
  allocated. Mapping over an existing page is a fatal error. }
function MapKernelPage(VirtualAddress: QWord; PhysicalAddress: TPhysicalAddress;
  Attributes: LongWord): Boolean;

{ Removes the mapping of one 4 KiB page and returns the physical address
  it pointed to (zero if nothing was mapped). }
function UnmapKernelPage(VirtualAddress: QWord): TPhysicalAddress;

{ Unmaps PageCount (at most MaximumPagesPerRun) pages from StartAddress,
  invalidating their translations on every processor once. }
procedure UnmapKernelPageRun(StartAddress: QWord; PageCount: LongWord;
  out PhysicalPages: TPhysicalPageRun);

{ Looks up the physical address behind a virtual address in the kernel
  address space. }
function TranslateVirtualAddress(VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;

{ The kernel's root (TTBR1_EL1). }
function KernelPageTableRoot: TPhysicalAddress;

function NoExecuteIsSupported: Boolean;

{ --- User address spaces --- }

{ Creates an empty user half. Returns its physical address, or zero if
  memory ran out. }
function CreateAddressSpaceRoot: TPhysicalAddress;

{ Frees every user page and page table of an address space, and the top
  level table itself. It must not be the active address space. }
procedure DestroyAddressSpaceRoot(Root: TPhysicalAddress);

{ The same operations as above for a user address space. }
function MapPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  PhysicalAddress: TPhysicalAddress; Attributes: LongWord): Boolean;
function UnmapPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord): TPhysicalAddress;
procedure UnmapPageRunInAddressSpace(Root: TPhysicalAddress; StartAddress: QWord;
  PageCount: LongWord; out PhysicalPages: TPhysicalPageRun);
function TranslateInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
{ Like TranslateInAddressSpace, also telling whether the page is a copy
  on write one. }
function QueryPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress; out IsCopyOnWrite: Boolean): Boolean;

type
  { Invalidates Address in the other processors' translation caches:
    all of them for Root = 0 (kernel), else where Root is loaded. }
  TRemoteInvalidation = procedure(Root: QWord; StartAddress: QWord; PageCount: LongWord);

{ Installed once several processors run (Kernel.InterProcessor). }
procedure SetRemoteInvalidation(Routine: TRemoteInvalidation);

{ Makes Root the active address space of this processor (0 or the
  kernel root: no user half). }
procedure ActivateAddressSpace(Root: TPhysicalAddress);
function ActiveAddressSpace: TPhysicalAddress;

implementation

uses
  Runtime.Memory,
  Boot.TranslationTableFormat,
  Memory.PhysicalPages,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Kernel.Processors,
  Memory.Arch.AddressSpaceIds;

const
  { The root table entry holding the address space's ASID context. }
  AddressSpaceIdEntry = EntriesPerTable - 1;
  AsidPosition = 48;

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

var
  KernelTopLevelTable: PPageTable;
  KernelTopLevelTablePhysical: TPhysicalAddress;
  { The user half of the kernel address space: nothing. }
  EmptyUserTablePhysical: TPhysicalAddress;
  PageTableLock: TSpinLock;
  RemoteInvalidation: TRemoteInvalidation = nil;

function ArchReadKernelTableRoot: QWord; external name 'ArchReadKernelTableRoot';
function ArchReadUserTableRoot: QWord; external name 'ArchReadUserTableRoot';
procedure ArchWriteUserTableRoot(Root: QWord); external name 'ArchWriteUserTableRoot';
procedure ArchPublishTableEntry; external name 'ArchPublishTableEntry';
procedure ArchLoadUserTableRoot(Root: QWord); external name 'ArchLoadUserTableRoot';
procedure ArchInvalidateLocalPages; external name 'ArchInvalidateLocalPages';

function KernelPageTableRoot: TPhysicalAddress;
begin
  Result := KernelTopLevelTablePhysical;
end;

function NoExecuteIsSupported: Boolean;
begin
  Result := True;
end;

function TableIndex(VirtualAddress: QWord; Level: Integer): Integer;
begin
  Result := Integer((VirtualAddress shr (PageShift + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

function EntryIsValid(Entry: QWord): Boolean;
begin
  Result := (Entry and DescriptorValid) <> 0;
end;

{ A block (levels 3 and 2) rather than a table. }
function EntryIsBlock(Entry: QWord; Level: Integer): Boolean;
begin
  Result := (Level > 1) and EntryIsValid(Entry) and ((Entry and DescriptorTableOrPage) = 0);
end;

function TableFromEntry(Entry: QWord): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Entry and DescriptorAddressMask));
end;

function TableFromRoot(Root: TPhysicalAddress): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Root));
end;

procedure InitializeKernelPageTables;
begin
  InitializeSpinLock(PageTableLock);
  KernelTopLevelTablePhysical := ArchReadKernelTableRoot and DescriptorAddressMask;
  KernelTopLevelTable := TableFromRoot(KernelTopLevelTablePhysical);
  CurrentProcessor^.ActiveAddressSpace := KernelTopLevelTablePhysical;
end;

procedure RemoveBootIdentityMapping;
begin
  EmptyUserTablePhysical := AllocateZeroedPhysicalPage(PageUsagePageTable);
  if EmptyUserTablePhysical = 0 then
    KernelPanicWithCode(PanicOutOfPhysicalMemory, 'no memory for the empty user table', 0, 0, 0, 0);
  ArchWriteUserTableRoot(EmptyUserTablePhysical);
  FlushEntireTlb;
end;

function EncodeEntry(VirtualAddress: QWord; PhysicalAddress: TPhysicalAddress; Attributes: LongWord): QWord;
begin
  Result := (PhysicalAddress and DescriptorAddressMask) or DescriptorValid or DescriptorTableOrPage or
    DescriptorAccessed;

  if (Attributes and MappingDevice) <> 0 then
    Result := Result or DescriptorSoftwareDevicePage;
  if (Attributes and MappingUncached) <> 0 then
    Result := Result or MemoryTypeBits(MemoryTypeDevice)
  else if (Attributes and MappingWriteCombining) <> 0 then
    Result := Result or MemoryTypeBits(MemoryTypeNonCacheable) or DescriptorInnerShareable
  else
    Result := Result or MemoryTypeBits(MemoryTypeNormal) or DescriptorInnerShareable;

  if (Attributes and MappingCopyOnWrite) <> 0 then
    Result := Result or DescriptorSoftwareCopyOnWrite or DescriptorReadOnly
  else if ((Attributes and MappingWritable) = 0) or ((Attributes and MappingNoAccess) <> 0) then
    Result := Result or DescriptorReadOnly;

  if ((Attributes and MappingUser) <> 0) and ((Attributes and MappingNoAccess) <> 0) then
    { In the user half, so tagged with the space's ASID like every user
      page, but neither reachable nor executable from user mode. }
    Result := Result or DescriptorNotGlobal or DescriptorPrivilegedExecuteNever or
      DescriptorUserExecuteNever
  else if (Attributes and MappingUser) <> 0 then
  begin
    Result := Result or DescriptorUserAccess or DescriptorNotGlobal or DescriptorPrivilegedExecuteNever;
    if (Attributes and MappingExecutable) = 0 then
      Result := Result or DescriptorUserExecuteNever;
  end
  else
  begin
    Result := Result or DescriptorUserExecuteNever;
    if (Attributes and MappingExecutable) = 0 then
      Result := Result or DescriptorPrivilegedExecuteNever;
  end;
end;

{ Walks down from TopLevel to the level 1 table covering VirtualAddress.
  When CreateMissing is set, absent intermediate tables are allocated.
  Returns nil if a table is missing (or could not be allocated). }
function FindPageTable(TopLevel: PPageTable; VirtualAddress: QWord; CreateMissing: Boolean): PPageTable;
var
  Table: PPageTable;
  Level: Integer;
  Index: Integer;
  NewTable: TPhysicalAddress;
begin
  Table := TopLevel;
  for Level := 4 downto 2 do
  begin
    Index := TableIndex(VirtualAddress, Level);
    if not EntryIsValid(Table^[Index]) then
    begin
      if not CreateMissing then
        Exit(nil);
      NewTable := AllocateZeroedPhysicalPage(PageUsagePageTable);
      if NewTable = 0 then
        Exit(nil);
      { The zeroed table must be visible to the walker before the entry
        pointing at it. }
      ArchPublishTableEntry;
      Table^[Index] := NewTable or DescriptorValid or DescriptorTableOrPage;
    end
    else if EntryIsBlock(Table^[Index], Level) then
      KernelPanicWithCode(PanicPageTableFailure,
        'address is covered by a block mapping', VirtualAddress, Level, 0, 0);
    Table := TableFromEntry(Table^[Index]);
  end;
  Result := Table;
end;

function MapPageInTable(TopLevel: PPageTable; VirtualAddress: QWord;
  PhysicalAddress: TPhysicalAddress; Attributes: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Table: PPageTable;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(PageTableLock);
  Table := FindPageTable(TopLevel, VirtualAddress, True);
  if Table = nil then
  begin
    ReleaseSpinLock(PageTableLock, PreviousLevel);
    Exit(False);
  end;
  Index := TableIndex(VirtualAddress, 1);
  if EntryIsValid(Table^[Index]) then
    KernelPanicWithCode(PanicPageTableFailure, 'virtual page is already mapped',
      VirtualAddress, Table^[Index], 0, 0);
  if (Attributes and (MappingUser or MappingExecutable or MappingDevice)) = (MappingUser or MappingExecutable) then
    SynchronizeInstructionCache(PhysicalToVirtual(PhysicalAddress), PageSize);
  Table^[Index] := EncodeEntry(VirtualAddress, PhysicalAddress, Attributes);
  ArchPublishTableEntry;
  ReleaseSpinLock(PageTableLock, PreviousLevel);
  Result := True;
end;

procedure SetRemoteInvalidation(Routine: TRemoteInvalidation);
begin
  RemoteInvalidation := Routine;
end;

{ Unmaps PageCount pages from StartAddress (at most MaximumPagesPerRun)
  and, with FlushTlb, invalidates them. Returns True if any page was
  mapped. }
function UnmapRunInTable(TopLevel: PPageTable; StartAddress: QWord; PageCount: LongWord;
  FlushTlb: Boolean; out PhysicalPages: TPhysicalPageRun): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Table: PPageTable;
  Index: Integer;
  PageIndex: LongWord;
  VirtualAddress: QWord;
begin
  if PageCount > MaximumPagesPerRun then
    KernelPanicWithCode(PanicPageTableFailure, 'too many pages in one unmap run', PageCount, 0, 0, 0);
  ZeroMemory(@PhysicalPages, SizeOf(PhysicalPages));
  Result := False;
  PreviousLevel := AcquireSpinLock(PageTableLock);
  for PageIndex := 1 to PageCount do
  begin
    VirtualAddress := StartAddress + QWord(PageIndex - 1) * PageSize;
    Table := FindPageTable(TopLevel, VirtualAddress, False);
    if Table = nil then
      Continue;
    Index := TableIndex(VirtualAddress, 1);
    if not EntryIsValid(Table^[Index]) then
      Continue;
    if (Table^[Index] and DescriptorSoftwareDevicePage) = 0 then
      PhysicalPages[PageIndex - 1] := Table^[Index] and DescriptorAddressMask;
    Table^[Index] := 0;
    if FlushTlb then
      InvalidateTlbEntry(VirtualAddress);
    Result := True;
  end;
  ReleaseSpinLock(PageTableLock, PreviousLevel);
end;

{ The entry mapping VirtualAddress (any level), or 0 if none. }
function FindEntry(TopLevel: PPageTable; VirtualAddress: QWord; out EntryLevel: Integer): QWord;
var
  Table: PPageTable;
  Level: Integer;
  Entry: QWord;
begin
  Table := TopLevel;
  EntryLevel := 0;
  for Level := 4 downto 1 do
  begin
    Entry := Table^[TableIndex(VirtualAddress, Level)];
    if not EntryIsValid(Entry) then
      Exit(0);
    if (Level = 1) or EntryIsBlock(Entry, Level) then
    begin
      EntryLevel := Level;
      Exit(Entry);
    end;
    Table := TableFromEntry(Entry);
  end;
  Result := 0;
end;

function TranslateInTable(TopLevel: PPageTable; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
var
  Entry: QWord;
  Level: Integer;
  OffsetMask: QWord;
begin
  PhysicalAddress := 0;
  Entry := FindEntry(TopLevel, VirtualAddress, Level);
  if Entry = 0 then
    Exit(False);
  OffsetMask := (QWord(1) shl (PageShift + 9 * (Level - 1))) - 1;
  PhysicalAddress := (Entry and DescriptorAddressMask and not OffsetMask) or (VirtualAddress and OffsetMask);
  Result := True;
end;

{ --- Kernel address space -------------------------------------------- }

function MapKernelPage(VirtualAddress: QWord; PhysicalAddress: TPhysicalAddress;
  Attributes: LongWord): Boolean;
begin
  Result := MapPageInTable(KernelTopLevelTable, VirtualAddress, PhysicalAddress, Attributes);
end;

procedure UnmapKernelPageRun(StartAddress: QWord; PageCount: LongWord;
  out PhysicalPages: TPhysicalPageRun);
begin
  if UnmapRunInTable(KernelTopLevelTable, StartAddress, PageCount, True, PhysicalPages) and
     Assigned(RemoteInvalidation) then
    RemoteInvalidation(0, StartAddress, PageCount);
end;

function UnmapKernelPage(VirtualAddress: QWord): TPhysicalAddress;
var
  PhysicalPages: TPhysicalPageRun;
begin
  UnmapKernelPageRun(VirtualAddress, 1, PhysicalPages);
  Result := PhysicalPages[0];
end;

function TranslateVirtualAddress(VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
begin
  if VirtualAddress < UpperHalfBase then
  begin
    PhysicalAddress := 0;
    Exit(False);
  end;
  Result := TranslateInTable(KernelTopLevelTable, VirtualAddress, PhysicalAddress);
end;

{ --- User address spaces --------------------------------------------- }

function CreateAddressSpaceRoot: TPhysicalAddress;
begin
  Result := AllocateZeroedPhysicalPage(PageUsagePageTable);
end;

{ Frees a lower level table and everything below it. Level 1 tables point
  at the user's pages, which belong to the address space and are freed
  too. }
procedure FreeTableTree(TablePhysical: TPhysicalAddress; Level: Integer);
var
  Table: PPageTable;
  Index: Integer;
begin
  Table := TableFromRoot(TablePhysical);
  for Index := 0 to EntriesPerTable - 1 do
  begin
    if not EntryIsValid(Table^[Index]) then
      Continue;
    if Level = 1 then
    begin
      if (Table^[Index] and DescriptorSoftwareDevicePage) = 0 then
        FreePhysicalPage(Table^[Index] and DescriptorAddressMask);
    end
    else
      FreeTableTree(Table^[Index] and DescriptorAddressMask, Level - 1);
  end;
  FreePhysicalPage(TablePhysical);
end;

function AddressSpaceIsLoadedAnywhere(Root: TPhysicalAddress): Boolean;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if Processor^.IsOnline and (Processor^.ActiveAddressSpace = Root) then
      Exit(True);
  end;
  Result := ActiveAddressSpace = Root;
end;

procedure DestroyAddressSpaceRoot(Root: TPhysicalAddress);
var
  Table: PPageTable;
  Index: Integer;
begin
  if (Root = 0) or (Root = KernelTopLevelTablePhysical) or (Root = EmptyUserTablePhysical) then
    Exit;
  if AddressSpaceIsLoadedAnywhere(Root) then
    KernelPanicWithCode(PanicPageTableFailure, 'destroying the active address space', Root, 0, 0, 0);
  Table := TableFromRoot(Root);
  for Index := 0 to EntriesPerTable - 1 do
    if EntryIsValid(Table^[Index]) then
      FreeTableTree(Table^[Index] and DescriptorAddressMask, 3);
  FreePhysicalPage(Root);
end;

function MapPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  PhysicalAddress: TPhysicalAddress; Attributes: LongWord): Boolean;
begin
  if VirtualAddress >= UserSpaceLimit then
    Exit(False);
  Result := MapPageInTable(TableFromRoot(Root), VirtualAddress, PhysicalAddress,
    Attributes or MappingUser);
end;

procedure UnmapPageRunInAddressSpace(Root: TPhysicalAddress; StartAddress: QWord;
  PageCount: LongWord; out PhysicalPages: TPhysicalPageRun);
begin
  if StartAddress + QWord(PageCount) * PageSize > UserSpaceLimit then
  begin
    ZeroMemory(@PhysicalPages, SizeOf(PhysicalPages));
    Exit;
  end;
  { The invalidation is broadcast, so it is done wherever Root may be
    loaded. }
  if UnmapRunInTable(TableFromRoot(Root), StartAddress, PageCount, True, PhysicalPages) and
     Assigned(RemoteInvalidation) then
    RemoteInvalidation(Root, StartAddress, PageCount);
end;

function UnmapPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord): TPhysicalAddress;
var
  PhysicalPages: TPhysicalPageRun;
begin
  UnmapPageRunInAddressSpace(Root, VirtualAddress, 1, PhysicalPages);
  Result := PhysicalPages[0];
end;

function QueryPageInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress; out IsCopyOnWrite: Boolean): Boolean;
var
  Entry: QWord;
  Level: Integer;
begin
  PhysicalAddress := 0;
  IsCopyOnWrite := False;
  if VirtualAddress >= UserSpaceLimit then
    Exit(False);
  Entry := FindEntry(TableFromRoot(Root), VirtualAddress, Level);
  { User pages are always 4 KiB pages. }
  if (Entry = 0) or (Level <> 1) then
    Exit(False);
  PhysicalAddress := (Entry and DescriptorAddressMask) or (VirtualAddress and PageOffsetMask);
  IsCopyOnWrite := (Entry and DescriptorSoftwareCopyOnWrite) <> 0;
  Result := True;
end;

function TranslateInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
begin
  if VirtualAddress >= UpperHalfBase then
    Exit(TranslateVirtualAddress(VirtualAddress, PhysicalAddress));
  if (Root = 0) or (Root = KernelTopLevelTablePhysical) then
  begin
    PhysicalAddress := 0;
    Exit(False);
  end;
  Result := TranslateInTable(TableFromRoot(Root), VirtualAddress, PhysicalAddress);
end;

procedure ActivateAddressSpace(Root: TPhysicalAddress);
var
  TableRoot: QWord;
  Asid: LongWord;
  MustFlushTlb: Boolean;
begin
  if Root = 0 then
    Root := KernelTopLevelTablePhysical;
  MustFlushTlb := False;
  if Root = KernelTopLevelTablePhysical then
    TableRoot := EmptyUserTablePhysical or (QWord(KernelAsid) shl AsidPosition)
  else
  begin
    Asid := AddressSpaceIdFor(PtrUInt(TableFromRoot(Root)^[AddressSpaceIdEntry]), MustFlushTlb);
    TableRoot := Root or (QWord(Asid) shl AsidPosition);
  end;
  if (ArchReadUserTableRoot <> TableRoot) or MustFlushTlb then
  begin
    { Published before the switch, so a processor removing a mapping of
      Root either sees it here or we see the removal
      (Kernel.InterProcessor). }
    CurrentProcessor^.ActiveAddressSpace := Root;
    ArchLoadUserTableRoot(TableRoot);
    { A new generation of ASIDs began since this processor last loaded
      one: entries cached under the old numbers must go. }
    if MustFlushTlb then
      ArchInvalidateLocalPages;
  end;
end;

function ActiveAddressSpace: TPhysicalAddress;
begin
  Result := CurrentProcessor^.ActiveAddressSpace;
end;

end.
