{
  x86-64 four level page table management for the kernel address space.

  The kernel keeps running on the top level table built by the loader.
  Page tables are reached through the physical memory window, so no
  recursive mapping tricks are needed. Intermediate tables are allocated
  on demand when a mapping needs them.

  Mappings in the kernel half are shared by all address spaces; once user
  address spaces exist they will copy the kernel half of the top level
  table, which is why every kernel top level entry is created up front.
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

{ Looks up the physical address behind a virtual address. }
function TranslateVirtualAddress(VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;

function KernelPageTableRoot: TPhysicalAddress;

function NoExecuteIsSupported: Boolean;

implementation

uses
  Memory.PhysicalPages,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic;

const
  EntryPresent = QWord(1) shl 0;
  EntryWritable = QWord(1) shl 1;
  EntryUser = QWord(1) shl 2;
  EntryWriteThrough = QWord(1) shl 3;
  EntryCacheDisable = QWord(1) shl 4;
  EntryLargePage = QWord(1) shl 7;
  EntryGlobal = QWord(1) shl 8;
  EntryNoExecute = QWord(1) shl 63;

  EntryAddressMask = QWord($000FFFFFFFFFF000);

  EntriesPerTable = 512;
  FirstKernelTopLevelEntry = 256;

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

var
  TopLevelTable: PPageTable;
  TopLevelTablePhysical: TPhysicalAddress;
  NoExecuteEnabled: Boolean;
  PageTableLock: TSpinLock;

function KernelPageTableRoot: TPhysicalAddress;
begin
  Result := TopLevelTablePhysical;
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
    if (TopLevelTable^[Index] and EntryPresent) <> 0 then
      Continue;
    TablePhysical := AllocateZeroedPhysicalPage(PageUsagePageTable);
    if TablePhysical = 0 then
      KernelPanicWithCode(PanicOutOfPhysicalMemory,
        'no memory for kernel page tables', Index, 0, 0, 0);
    TopLevelTable^[Index] := TablePhysical or EntryPresent or EntryWritable;
  end;
end;

procedure InitializeKernelPageTables;
begin
  InitializeSpinLock(PageTableLock);
  TopLevelTablePhysical := ReadControlRegister3 and EntryAddressMask;
  TopLevelTable := PPageTable(PhysicalToVirtual(TopLevelTablePhysical));

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
    TopLevelTable^[Index] := 0;
  FlushEntireTlb;
end;

function EncodeEntry(PhysicalAddress: TPhysicalAddress; Attributes: LongWord): QWord;
begin
  Result := PhysicalAddress or EntryPresent;
  if (Attributes and MappingWritable) <> 0 then
    Result := Result or EntryWritable;
  if (Attributes and MappingUser) <> 0 then
    Result := Result or EntryUser;
  if (Attributes and MappingUncached) <> 0 then
    Result := Result or EntryCacheDisable or EntryWriteThrough;
  if ((Attributes and MappingExecutable) = 0) and NoExecuteEnabled then
    Result := Result or EntryNoExecute;
end;

{ Walks down to the level 1 table covering VirtualAddress. When
  CreateMissing is set, absent intermediate tables are allocated.
  Returns nil if a table is missing (or could not be allocated). }
function FindPageTable(VirtualAddress: QWord; CreateMissing: Boolean): PPageTable;
var
  Table: PPageTable;
  Level: Integer;
  Index: Integer;
  NewTable: TPhysicalAddress;
begin
  Table := TopLevelTable;
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

function MapKernelPage(VirtualAddress: QWord; PhysicalAddress: TPhysicalAddress;
  Attributes: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Table: PPageTable;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(PageTableLock);

  Table := FindPageTable(VirtualAddress, True);
  if Table = nil then
  begin
    ReleaseSpinLock(PageTableLock, PreviousLevel);
    Exit(False);
  end;

  Index := TableIndex(VirtualAddress, 1);
  if (Table^[Index] and EntryPresent) <> 0 then
    KernelPanicWithCode(PanicPageTableFailure, 'virtual page is already mapped',
      VirtualAddress, Table^[Index], 0, 0);

  Table^[Index] := EncodeEntry(PhysicalAddress and EntryAddressMask, Attributes);

  ReleaseSpinLock(PageTableLock, PreviousLevel);
  Result := True;
end;

function UnmapKernelPage(VirtualAddress: QWord): TPhysicalAddress;
var
  PreviousLevel: TPriorityLevel;
  Table: PPageTable;
  Index: Integer;
begin
  Result := 0;
  PreviousLevel := AcquireSpinLock(PageTableLock);

  Table := FindPageTable(VirtualAddress, False);
  if Table <> nil then
  begin
    Index := TableIndex(VirtualAddress, 1);
    if (Table^[Index] and EntryPresent) <> 0 then
    begin
      Result := Table^[Index] and EntryAddressMask;
      Table^[Index] := 0;
      InvalidateTlbEntry(VirtualAddress);
    end;
  end;

  ReleaseSpinLock(PageTableLock, PreviousLevel);
end;

function TranslateVirtualAddress(VirtualAddress: QWord;
  out PhysicalAddress: TPhysicalAddress): Boolean;
var
  Table: PPageTable;
  Level: Integer;
  Entry: QWord;
  OffsetMask: QWord;
begin
  PhysicalAddress := 0;
  Table := TopLevelTable;

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

end.
