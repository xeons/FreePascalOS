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
  Builds the initial x86-64 page tables the kernel starts running on.

  Three things are mapped:

  1. The physical memory window: all of physical memory at
     PhysicalMemoryWindowBase, using 2 MiB pages, never executable.
  2. An identity mapping of the same range, so the loader keeps running
     for the few instructions between loading CR3 and jumping to the
     kernel. It reuses the window's page directory tables, and the kernel
     removes it early during startup. It is executable: the no-execute
     bit of the window is set in its top level entries, which the two do
     not share.
  3. The kernel image at its linked virtual address, using 4 KiB pages so
     each segment gets its own permissions: code read-only, read-only
     data read-only and no-execute, data writable and no-execute.

  The window's view of the kernel's code and read-only data is made
  read-only too (those 2 MiB pages are split into 4 KiB ones), so the
  kernel's code cannot be changed through its other address either.
  The no-execute bit is used only when the processor has it
  (Loader.Arch.NoExecute turns it on).
}
unit Loader.Arch.PageTables;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information,
  Loader.KernelImage;

{ Returns the physical address of the new top level table (PML4), or zero
  if memory ran out. PhysicalCoverage is how many bytes of physical
  address space the window and identity mapping should cover. The boot
  information (framebuffer, ACPI tables) is not needed on x86-64. }
function BuildInitialPageTables(const BootInformation: TBootInformation;
  PhysicalCoverage: QWord; const KernelImage: TLoadedKernelImage): QWord;

implementation

uses
  Uefi.Base,
  Boot.AddressLayout,
  Loader.Memory,
  Loader.Arch.NoExecute;

const
  PageFlagPresent = QWord(1) shl 0;
  PageFlagWritable = QWord(1) shl 1;
  PageFlagLargePage = QWord(1) shl 7;
  PageFlagNoExecute = QWord(1) shl 63;

  PageTableAddressMask = QWord($000FFFFFFFFFF000);

  EntriesPerTable = 512;
  LargePageSize = QWord(2) * 1024 * 1024;
  BytesPerPageDirectory = QWord(EntriesPerTable) * LargePageSize; { 1 GiB }
  BytesPerTopLevelEntry = QWord(EntriesPerTable) * BytesPerPageDirectory; { 512 GiB }

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

var
  OutOfMemory: Boolean;
  { PageFlagNoExecute, or 0 on a processor without it. }
  NoExecuteFlag: QWord;

function AllocatePageTable: PPageTable;
var
  PhysicalAddress: QWord;
begin
  PhysicalAddress := AllocateLoaderPages(1, LoaderMemoryTypePageTables);
  if PhysicalAddress = 0 then
    OutOfMemory := True;
  Result := PPageTable(PhysicalAddress);
end;

function TableIndexForLevel(VirtualAddress: QWord; Level: Integer): Integer;
var
  Shift: Integer;
begin
  { Level 4 is the PML4, level 1 is the final page table. }
  Shift := 12 + 9 * (Level - 1);
  Result := Integer((VirtualAddress shr Shift) and (EntriesPerTable - 1));
end;

{ Returns the table that entry Index of Table points at, creating it if
  it does not exist yet. }
function GetOrCreateNextTable(Table: PPageTable; Index: Integer): PPageTable;
var
  NextTable: PPageTable;
begin
  if (Table^[Index] and PageFlagPresent) <> 0 then
    Exit(PPageTable(Table^[Index] and PageTableAddressMask));

  NextTable := AllocatePageTable;
  if NextTable = nil then
    Exit(nil);

  Table^[Index] := QWord(NextTable) or PageFlagPresent or PageFlagWritable;
  Result := NextTable;
end;

procedure MapSmallPage(TopLevelTable: PPageTable; VirtualAddress, PhysicalAddress: QWord;
  Flags: QWord);
var
  Table: PPageTable;
  Level: Integer;
begin
  Table := TopLevelTable;
  for Level := 4 downto 2 do
  begin
    Table := GetOrCreateNextTable(Table, TableIndexForLevel(VirtualAddress, Level));
    if Table = nil then
      Exit;
  end;
  Table^[TableIndexForLevel(VirtualAddress, 1)] := PhysicalAddress or Flags or PageFlagPresent;
end;

{ Maps [0, PhysicalCoverage) both at the physical memory window and at
  the identity address, sharing the lower level tables. }
procedure MapPhysicalMemoryWindow(TopLevelTable: PPageTable; PhysicalCoverage: QWord);
var
  TopLevelEntryCount: QWord;
  WindowFirstEntry: Integer;
  TopLevelIndex: QWord;
  IdentityEntry: QWord;
  DirectoryPointerTable: PPageTable;
  DirectoryPointerIndex: Integer;
  Directory: PPageTable;
  DirectoryIndex: Integer;
  PhysicalAddress: QWord;
begin
  TopLevelEntryCount := (PhysicalCoverage + BytesPerTopLevelEntry - 1) div BytesPerTopLevelEntry;
  WindowFirstEntry := TableIndexForLevel(PhysicalMemoryWindowBase, 4);
  PhysicalAddress := 0;

  for TopLevelIndex := 1 to TopLevelEntryCount do
  begin
    DirectoryPointerTable := AllocatePageTable;
    if DirectoryPointerTable = nil then
      Exit;

    IdentityEntry := TopLevelIndex - 1;
    TopLevelTable^[IdentityEntry] := QWord(DirectoryPointerTable) or PageFlagPresent or PageFlagWritable;
    { The no-execute bit of a top level entry covers everything below it. }
    TopLevelTable^[WindowFirstEntry + Integer(IdentityEntry)] := TopLevelTable^[IdentityEntry] or NoExecuteFlag;

    for DirectoryPointerIndex := 0 to EntriesPerTable - 1 do
    begin
      if PhysicalAddress >= PhysicalCoverage then
        Exit;

      Directory := AllocatePageTable;
      if Directory = nil then
        Exit;
      DirectoryPointerTable^[DirectoryPointerIndex] := QWord(Directory) or PageFlagPresent or PageFlagWritable;

      for DirectoryIndex := 0 to EntriesPerTable - 1 do
      begin
        Directory^[DirectoryIndex] := PhysicalAddress or PageFlagPresent or PageFlagWritable or PageFlagLargePage;
        PhysicalAddress := PhysicalAddress + LargePageSize;
      end;
    end;
  end;
end;

procedure MapKernelImage(TopLevelTable: PPageTable; const KernelImage: TLoadedKernelImage);
var
  SegmentIndex: LongWord;
  Segment: ^TKernelSegment;
  PageIndex: QWord;
  Flags: QWord;
  Offset: QWord;
begin
  SegmentIndex := 0;
  while SegmentIndex < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[SegmentIndex];
    Flags := 0;
    if Segment^.IsWritable then
      Flags := Flags or PageFlagWritable;
    if not Segment^.IsExecutable then
      Flags := Flags or NoExecuteFlag;

    PageIndex := 0;
    while PageIndex < Segment^.PageCount do
    begin
      Offset := PageIndex * LoaderPageSize;
      MapSmallPage(TopLevelTable, Segment^.VirtualStart + Offset,
        Segment^.PhysicalStart + Offset, Flags);
      if OutOfMemory then
        Exit;
      Inc(PageIndex);
    end;

    Inc(SegmentIndex);
  end;
end;

{ The page directory entry of the window covering PhysicalAddress. }
function WindowDirectoryEntry(TopLevelTable: PPageTable; PhysicalAddress: QWord): PQWord;
var
  WindowAddress: QWord;
  DirectoryPointerTable: PPageTable;
  Directory: PPageTable;
begin
  WindowAddress := PhysicalMemoryWindowBase + PhysicalAddress;
  DirectoryPointerTable := PPageTable(TopLevelTable^[TableIndexForLevel(WindowAddress, 4)] and
    PageTableAddressMask);
  Directory := PPageTable(DirectoryPointerTable^[TableIndexForLevel(WindowAddress, 3)] and
    PageTableAddressMask);
  Result := @Directory^[TableIndexForLevel(WindowAddress, 2)];
end;

{ Replaces a 2 MiB page by a table of 512 small pages with the same
  permissions. Returns the table, or nil if memory ran out. }
function SplitLargePage(DirectoryEntry: PQWord): PPageTable;
var
  Table: PPageTable;
  Index: Integer;
  LargePageBase: QWord;
  Flags: QWord;
begin
  if (DirectoryEntry^ and PageFlagLargePage) = 0 then
    Exit(PPageTable(DirectoryEntry^ and PageTableAddressMask));
  Table := AllocatePageTable;
  if Table = nil then
    Exit(nil);
  LargePageBase := DirectoryEntry^ and PageTableAddressMask and not (LargePageSize - 1);
  Flags := DirectoryEntry^ and (PageFlagPresent or PageFlagWritable);
  for Index := 0 to EntriesPerTable - 1 do
    Table^[Index] := (LargePageBase + QWord(Index) * LoaderPageSize) or Flags;
  DirectoryEntry^ := QWord(Table) or PageFlagPresent or PageFlagWritable;
  Result := Table;
end;

{ Makes the window's view of the kernel's read-only segments read-only. }
procedure ProtectKernelImageInWindow(TopLevelTable: PPageTable; const KernelImage: TLoadedKernelImage);
var
  SegmentIndex: LongWord;
  Segment: ^TKernelSegment;
  PageIndex: QWord;
  PhysicalAddress: QWord;
  Table: PPageTable;
begin
  SegmentIndex := 0;
  while SegmentIndex < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[SegmentIndex];
    PageIndex := 0;
    while (PageIndex < Segment^.PageCount) and not Segment^.IsWritable do
    begin
      PhysicalAddress := Segment^.PhysicalStart + PageIndex * LoaderPageSize;
      Table := SplitLargePage(WindowDirectoryEntry(TopLevelTable, PhysicalAddress));
      if Table = nil then
        Exit;
      Table^[TableIndexForLevel(PhysicalAddress, 1)] :=
        Table^[TableIndexForLevel(PhysicalAddress, 1)] and not PageFlagWritable;
      Inc(PageIndex);
    end;
    Inc(SegmentIndex);
  end;
end;

function BuildInitialPageTables(const BootInformation: TBootInformation;
  PhysicalCoverage: QWord; const KernelImage: TLoadedKernelImage): QWord;
var
  TopLevelTable: PPageTable;
begin
  OutOfMemory := False;
  NoExecuteFlag := 0;
  if EnableNoExecute then
    NoExecuteFlag := PageFlagNoExecute;

  TopLevelTable := AllocatePageTable;
  if TopLevelTable = nil then
    Exit(0);

  MapPhysicalMemoryWindow(TopLevelTable, PhysicalCoverage);
  if OutOfMemory then
    Exit(0);

  MapKernelImage(TopLevelTable, KernelImage);
  if OutOfMemory then
    Exit(0);

  ProtectKernelImageInWindow(TopLevelTable, KernelImage);
  if OutOfMemory then
    Exit(0);

  Result := QWord(TopLevelTable);
end;

end.
