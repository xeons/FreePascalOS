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
  x86-64 four level page table management.

  The kernel keeps running on the top level table built by the loader.
  Page tables are reached through the physical memory window, so no
  recursive mapping tricks are needed. Intermediate tables are allocated
  on demand when a mapping needs them.

  Every user process has its own top level table. Its upper (kernel)
  half is a copy of the kernel's, which never changes because every
  kernel top level entry is created during startup; its lower half maps
  the process's own memory. Switching address spaces is therefore just
  loading a different top level table.
}
unit Memory.Arch.PageTables;

{$mode objfpc}
{$pointermath on}

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

{ Removes the identity mapping of low memory the loader left behind. }
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

function KernelPageTableRoot: TPhysicalAddress;

function NoExecuteIsSupported: Boolean;

{ --- User address spaces --- }

{ Creates a top level table sharing the kernel half. Returns its
  physical address, or zero if memory ran out. }
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

{ Makes Root the active address space of this processor. }
type
  { Invalidates Address in the other processors' translation caches:
    all of them for Root = 0 (kernel), else where Root is loaded. }
  TRemoteInvalidation = procedure(Root: QWord; StartAddress: QWord; PageCount: LongWord);

{ Installed once several processors run (Kernel.InterProcessor). }
procedure SetRemoteInvalidation(Routine: TRemoteInvalidation);

procedure ActivateAddressSpace(Root: TPhysicalAddress);
function ActiveAddressSpace: TPhysicalAddress;

implementation

uses
  Runtime.Memory,
  Memory.PhysicalPages,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Kernel.Processors;

const
  EntryPresent = QWord(1) shl 0;
  EntryWritable = QWord(1) shl 1;
  EntryUser = QWord(1) shl 2;
  EntryWriteThrough = QWord(1) shl 3;
  EntryCacheDisable = QWord(1) shl 4;
  EntryLargePage = QWord(1) shl 7;
  EntryGlobal = QWord(1) shl 8;
  { Available to software: the page is copied on the first write. }
  EntryCopyOnWrite = QWord(1) shl 9;
  EntryNoExecute = QWord(1) shl 63;

  EntryAddressMask = QWord($000FFFFFFFFFF000);

  EntriesPerTable = 512;
  FirstKernelTopLevelEntry = 256;

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

var
  KernelTopLevelTable: PPageTable;
  KernelTopLevelTablePhysical: TPhysicalAddress;
  NoExecuteEnabled: Boolean;
  PageTableLock: TSpinLock;

function KernelPageTableRoot: TPhysicalAddress;
begin
  Result := KernelTopLevelTablePhysical;
end;

function NoExecuteIsSupported: Boolean;
begin
  Result := NoExecuteEnabled;
end;

function TableIndex(VirtualAddress: QWord; Level: Integer): Integer;
begin
  { Level 4 is the top level table, level 1 holds the page entries. }
  Result := Integer((VirtualAddress shr (PageShift + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

function TableFromEntry(Entry: QWord): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Entry and EntryAddressMask));
end;

function TableFromRoot(Root: TPhysicalAddress): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Root));
end;

procedure EnableNoExecuteIfSupported;
var
  Features: TCpuidResult;
begin
  ExecuteCpuid(CpuidExtendedFeatures, 0, Features);
  NoExecuteEnabled := (Features.Edx and CpuidExtendedEdxNoExecute) <> 0;
  if NoExecuteEnabled then
    WriteModelSpecificRegister(MsrExtendedFeatureEnable,
      ReadModelSpecificRegister(MsrExtendedFeatureEnable) or EferNoExecuteEnable);
end;

{ Allocates the second level tables for every kernel half entry so that
  the kernel half of the top level table never changes again. }
procedure PopulateKernelTopLevelEntries;
var
  Index: Integer;
  TablePhysical: TPhysicalAddress;
begin
  for Index := FirstKernelTopLevelEntry to EntriesPerTable - 1 do
  begin
    if (KernelTopLevelTable^[Index] and EntryPresent) <> 0 then
      Continue;
    TablePhysical := AllocateZeroedPhysicalPage(PageUsagePageTable);
    if TablePhysical = 0 then
      KernelPanicWithCode(PanicOutOfPhysicalMemory,
        'no memory for kernel page tables', Index, 0, 0, 0);
    KernelTopLevelTable^[Index] := TablePhysical or EntryPresent or EntryWritable;
  end;
end;

procedure InitializeKernelPageTables;
begin
  InitializeSpinLock(PageTableLock);
  KernelTopLevelTablePhysical := ReadControlRegister3 and EntryAddressMask;
  KernelTopLevelTable := TableFromRoot(KernelTopLevelTablePhysical);
  CurrentProcessor^.ActiveAddressSpace := KernelTopLevelTablePhysical;

  { Make the kernel honour read-only pages too. }
  WriteControlRegister0(ReadControlRegister0 or Cr0WriteProtect);
  EnableNoExecuteIfSupported;

  PopulateKernelTopLevelEntries;
end;

procedure RemoveBootIdentityMapping;
var
  Index: Integer;
begin
  { The identity mapping shares its lower level tables with the physical
    memory window, so only the top level entries are cleared. }
  for Index := 0 to FirstKernelTopLevelEntry - 1 do
    KernelTopLevelTable^[Index] := 0;
  FlushEntireTlb;
end;

function EncodeEntry(PhysicalAddress: TPhysicalAddress; Attributes: LongWord): QWord;
begin
  Result := (PhysicalAddress and EntryAddressMask) or EntryPresent;
  if (Attributes and MappingCopyOnWrite) <> 0 then
    Result := Result or EntryCopyOnWrite
  else if (Attributes and MappingWritable) <> 0 then
    Result := Result or EntryWritable;
  if (Attributes and MappingUser) <> 0 then
    Result := Result or EntryUser;
  if (Attributes and MappingUncached) <> 0 then
    Result := Result or EntryCacheDisable or EntryWriteThrough;
  if ((Attributes and MappingExecutable) = 0) and NoExecuteEnabled then
    Result := Result or EntryNoExecute;
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

    if (Table^[Index] and EntryPresent) = 0 then
    begin
      if not CreateMissing then
        Exit(nil);
      NewTable := AllocateZeroedPhysicalPage(PageUsagePageTable);
      if NewTable = 0 then
        Exit(nil);
      { Intermediate entries are permissive; the final entry decides. }
      Table^[Index] := NewTable or EntryPresent or EntryWritable or EntryUser;
    end
    else if (Table^[Index] and EntryLargePage) <> 0 then
      KernelPanicWithCode(PanicPageTableFailure,
        'address is covered by a large page', VirtualAddress, Level, 0, 0);

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
  if (Table^[Index] and EntryPresent) <> 0 then
    KernelPanicWithCode(PanicPageTableFailure, 'virtual page is already mapped',
      VirtualAddress, Table^[Index], 0, 0);

  Table^[Index] := EncodeEntry(PhysicalAddress, Attributes);

  ReleaseSpinLock(PageTableLock, PreviousLevel);
  Result := True;
end;

var
  RemoteInvalidation: TRemoteInvalidation = nil;

procedure SetRemoteInvalidation(Routine: TRemoteInvalidation);
begin
  RemoteInvalidation := Routine;
end;

{ Unmaps PageCount pages from StartAddress (at most MaximumPagesPerRun)
  and, with FlushTlb, invalidates them on this processor. Returns True if
  any page was mapped. Remote invalidation is the caller's, after the
  page table lock is released (see Kernel.InterProcessor). }
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
    if (Table^[Index] and EntryPresent) = 0 then
      Continue;
    PhysicalPages[PageIndex - 1] := Table^[Index] and EntryAddressMask;
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
    if (Entry and EntryPresent) = 0 then
      Exit(0);
    if (Level = 1) or ((Entry and EntryLargePage) <> 0) then
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
  Table: PPageTable;
  Level: Integer;
  Entry: QWord;
  OffsetMask: QWord;
begin
  PhysicalAddress := 0;
  Table := TopLevel;

  for Level := 4 downto 1 do
  begin
    Entry := Table^[TableIndex(VirtualAddress, Level)];
    if (Entry and EntryPresent) = 0 then
      Exit(False);

    if (Level = 1) or ((Entry and EntryLargePage) <> 0) then
    begin
      OffsetMask := (QWord(1) shl (PageShift + 9 * (Level - 1))) - 1;
      PhysicalAddress := (Entry and EntryAddressMask and not OffsetMask) or
        (VirtualAddress and OffsetMask);
      Exit(True);
    end;

    Table := TableFromEntry(Entry);
  end;
  Result := False;
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
  Result := TranslateInTable(KernelTopLevelTable, VirtualAddress, PhysicalAddress);
end;

{ --- User address spaces --------------------------------------------- }

function CreateAddressSpaceRoot: TPhysicalAddress;
var
  Table: PPageTable;
  Index: Integer;
begin
  Result := AllocateZeroedPhysicalPage(PageUsagePageTable);
  if Result = 0 then
    Exit;
  Table := TableFromRoot(Result);
  for Index := FirstKernelTopLevelEntry to EntriesPerTable - 1 do
    Table^[Index] := KernelTopLevelTable^[Index];
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
    if (Table^[Index] and EntryPresent) = 0 then
      Continue;
    if Level = 1 then
      FreePhysicalPage(Table^[Index] and EntryAddressMask)
    else
      FreeTableTree(Table^[Index] and EntryAddressMask, Level - 1);
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
  if (Root = 0) or (Root = KernelTopLevelTablePhysical) then
    Exit;
  if AddressSpaceIsLoadedAnywhere(Root) then
    KernelPanicWithCode(PanicPageTableFailure, 'destroying the active address space', Root, 0, 0, 0);

  Table := TableFromRoot(Root);
  for Index := 0 to FirstKernelTopLevelEntry - 1 do
  begin
    if (Table^[Index] and EntryPresent) <> 0 then
      FreeTableTree(Table^[Index] and EntryAddressMask, 3);
  end;
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
  { Here only the active address space can have stale TLB entries;
    elsewhere, where the processors have Root loaded. }
  if UnmapRunInTable(TableFromRoot(Root), StartAddress, PageCount, ActiveAddressSpace = Root,
     PhysicalPages) and Assigned(RemoteInvalidation) then
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
  Entry := FindEntry(TableFromRoot(Root), VirtualAddress, Level);
  { User pages are always 4 KiB pages. }
  if (Entry = 0) or (Level <> 1) then
    Exit(False);
  PhysicalAddress := (Entry and EntryAddressMask) or (VirtualAddress and PageOffsetMask);
  IsCopyOnWrite := (Entry and EntryCopyOnWrite) <> 0;
  Result := True;
end;

function TranslateInAddressSpace(Root: TPhysicalAddress; VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
begin
  Result := TranslateInTable(TableFromRoot(Root), VirtualAddress, PhysicalAddress);
end;

procedure ActivateAddressSpace(Root: TPhysicalAddress);
begin
  if Root = 0 then
    Root := KernelTopLevelTablePhysical;
  if (ReadControlRegister3 and EntryAddressMask) <> Root then
  begin
    { Published before the switch (which serializes), so a processor
      removing a mapping of Root either sees it here or we see the
      removal (Kernel.InterProcessor). }
    CurrentProcessor^.ActiveAddressSpace := Root;
    WriteControlRegister3(Root);
  end;
end;

function ActiveAddressSpace: TPhysicalAddress;
begin
  Result := ReadControlRegister3 and EntryAddressMask;
end;

end.
