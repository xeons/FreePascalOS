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
  Builds the initial AArch64 translation tables the kernel starts on.

  Two roots are built:

  - The kernel's (TTBR1_EL1, the upper half), the one the kernel keeps:
    the physical memory window over every range of real memory in the
    firmware's memory map (normal cached memory), the framebuffer
    (normal non-cacheable) and the firmware's debug UART (device
    memory), and the kernel image at its linked address with 4 KiB pages
    and per-segment permissions.
  - An identity mapping of real memory (TTBR0_EL1, the lower half), so
    the hand-off code keeps running for the instructions between turning
    the new tables on and jumping to the kernel; the kernel replaces it
    early during startup.

  Ranges are mapped with 2 MiB blocks where they cover a whole aligned
  block and with 4 KiB pages at their edges, so nothing beyond them is
  mapped as memory (a device's registers next to RAM must never be
  normal memory: the processor may read it speculatively).
}
unit Loader.Arch.PageTables;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information,
  Loader.KernelImage;

{ Returns the physical address of the kernel's top level table (for
  TTBR1_EL1), or zero if memory ran out. PhysicalCoverage is unused: the
  window follows the memory map. }
function BuildInitialPageTables(const BootInformation: TBootInformation;
  PhysicalCoverage: QWord; const KernelImage: TLoadedKernelImage): QWord;

{ The identity mapping's top level table (for TTBR0_EL1), built by
  BuildInitialPageTables. }
function IdentityPageTableRoot: QWord;

implementation

uses
  Uefi.Base,
  Boot.AddressLayout,
  Boot.TranslationTableFormat,
  Loader.Memory,
  Loader.MemoryMap,
  Loader.Arch.DebugPort;

const
  BlockSize = QWord(2) * 1024 * 1024;
  PageBytes = QWord(LoaderPageSize);

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

  TRootPair = record
    Kernel: PPageTable;
    Identity: PPageTable;
  end;
  PRootPair = ^TRootPair;

var
  OutOfMemory: Boolean;
  IdentityRoot: PPageTable;

function IdentityPageTableRoot: QWord;
begin
  Result := QWord(IdentityRoot);
end;

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
begin
  Result := Integer((VirtualAddress shr (12 + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

function IsTableEntry(Entry: QWord): Boolean;
begin
  Result := (Entry and (DescriptorValid or DescriptorTableOrPage)) = (DescriptorValid or DescriptorTableOrPage);
end;

{ A level 2 block becomes a table of 512 pages with the same attributes,
  so part of it can be mapped differently. }
function SplitBlock(Block: QWord): QWord;
var
  Table: PPageTable;
  Index: Integer;
  Attributes: QWord;
  Physical: QWord;
begin
  Table := AllocatePageTable;
  if Table = nil then
    Exit(0);
  Attributes := Block and not DescriptorAddressMask;
  Physical := Block and DescriptorAddressMask;
  for Index := 0 to EntriesPerTable - 1 do
    Table^[Index] := (Physical + QWord(Index) * PageBytes) or Attributes or DescriptorTableOrPage;
  Result := QWord(Table) or DescriptorValid or DescriptorTableOrPage;
end;

{ The table entry Index of Table points at, created (or split from a
  block) if needed. }
function GetOrCreateNextTable(Table: PPageTable; Index: Integer): PPageTable;
var
  NextTable: PPageTable;
begin
  if IsTableEntry(Table^[Index]) then
    Exit(PPageTable(Table^[Index] and DescriptorAddressMask));

  if (Table^[Index] and DescriptorValid) <> 0 then
  begin
    Table^[Index] := SplitBlock(Table^[Index]);
    if Table^[Index] = 0 then
      Exit(nil);
    Exit(PPageTable(Table^[Index] and DescriptorAddressMask));
  end;

  NextTable := AllocatePageTable;
  if NextTable = nil then
    Exit(nil);
  Table^[Index] := QWord(NextTable) or DescriptorValid or DescriptorTableOrPage;
  Result := NextTable;
end;

function DescendTo(Root: PPageTable; VirtualAddress: QWord; LastLevel: Integer): PPageTable;
var
  Level: Integer;
begin
  Result := Root;
  Level := 4;
  while (Level > LastLevel) and (Result <> nil) do
  begin
    Result := GetOrCreateNextTable(Result, TableIndexForLevel(VirtualAddress, Level));
    Dec(Level);
  end;
end;

procedure MapPage(Root: PPageTable; VirtualAddress, PhysicalAddress, Attributes: QWord);
var
  Table: PPageTable;
begin
  Table := DescendTo(Root, VirtualAddress, 1);
  if Table <> nil then
    Table^[TableIndexForLevel(VirtualAddress, 1)] := PhysicalAddress or Attributes or
      DescriptorValid or DescriptorTableOrPage;
end;

procedure MapBlock(Root: PPageTable; VirtualAddress, PhysicalAddress, Attributes: QWord);
var
  Table: PPageTable;
begin
  Table := DescendTo(Root, VirtualAddress, 2);
  if Table <> nil then
    Table^[TableIndexForLevel(VirtualAddress, 2)] := PhysicalAddress or Attributes or DescriptorValid;
end;

{ Maps [PhysicalStart, PhysicalStart + SizeInBytes) at VirtualStart,
  page aligned outwards. }
procedure MapRange(Root: PPageTable; VirtualStart, PhysicalStart, SizeInBytes, Attributes: QWord);
var
  Physical: QWord;
  PhysicalEnd: QWord;
  Offset: QWord;
begin
  Physical := PhysicalStart and not (PageBytes - 1);
  PhysicalEnd := (PhysicalStart + SizeInBytes + PageBytes - 1) and not (PageBytes - 1);
  Offset := VirtualStart - PhysicalStart;
  while (Physical < PhysicalEnd) and not OutOfMemory do
  begin
    if ((Physical and (BlockSize - 1)) = 0) and (PhysicalEnd - Physical >= BlockSize) and
       (((Physical + Offset) and (BlockSize - 1)) = 0) then
    begin
      MapBlock(Root, Physical + Offset, Physical, Attributes);
      Physical := Physical + BlockSize;
    end
    else
    begin
      MapPage(Root, Physical + Offset, Physical, Attributes);
      Physical := Physical + PageBytes;
    end;
  end;
end;

function NormalMemoryAttributes: QWord;
begin
  Result := MemoryTypeBits(MemoryTypeNormal) or DescriptorInnerShareable or DescriptorAccessed;
end;

function DataAttributes(MemoryType: Integer): QWord;
begin
  Result := MemoryTypeBits(MemoryType) or DescriptorAccessed or
    DescriptorPrivilegedExecuteNever or DescriptorUserExecuteNever;
  if MemoryType = MemoryTypeNormal then
    Result := Result or DescriptorInnerShareable;
end;

procedure MapMemoryRange(PhysicalStart, SizeInBytes: QWord; Context: Pointer);
var
  Roots: PRootPair;
begin
  Roots := PRootPair(Context);
  MapRange(Roots^.Kernel, PhysicalMemoryWindowBase + PhysicalStart, PhysicalStart, SizeInBytes,
    DataAttributes(MemoryTypeNormal));
  { The identity mapping is executable: the hand-off code runs there. }
  MapRange(Roots^.Identity, PhysicalStart, PhysicalStart, SizeInBytes, NormalMemoryAttributes);
end;

procedure MapFramebuffer(Root: PPageTable; const Framebuffer: TFramebufferInformation);
begin
  if (Framebuffer.PhysicalBase = 0) or (Framebuffer.SizeInBytes = 0) then
    Exit;
  MapRange(Root, PhysicalMemoryWindowBase + Framebuffer.PhysicalBase, Framebuffer.PhysicalBase,
    Framebuffer.SizeInBytes, DataAttributes(MemoryTypeNonCacheable));
end;

procedure MapDebugPort(Root: PPageTable; AcpiRootPointer: QWord);
var
  Registers: QWord;
begin
  Registers := FindDebugPortRegisters(AcpiRootPointer);
  if Registers = 0 then
    Exit;
  MapRange(Root, PhysicalMemoryWindowBase + Registers, Registers, PageBytes,
    DataAttributes(MemoryTypeDevice));
end;

procedure MapKernelImage(Root: PPageTable; const KernelImage: TLoadedKernelImage);
var
  SegmentIndex: LongWord;
  Segment: ^TKernelSegment;
  Attributes: QWord;
begin
  SegmentIndex := 0;
  while SegmentIndex < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[SegmentIndex];
    Attributes := NormalMemoryAttributes or DescriptorUserExecuteNever;
    if not Segment^.IsWritable then
      Attributes := Attributes or DescriptorReadOnly;
    if not Segment^.IsExecutable then
      Attributes := Attributes or DescriptorPrivilegedExecuteNever;
    MapRange(Root, Segment^.VirtualStart, Segment^.PhysicalStart, Segment^.PageCount * PageBytes,
      Attributes);
    Inc(SegmentIndex);
  end;
end;

function BuildInitialPageTables(const BootInformation: TBootInformation;
  PhysicalCoverage: QWord; const KernelImage: TLoadedKernelImage): QWord;
var
  Roots: TRootPair;
begin
  OutOfMemory := False;
  Roots.Kernel := AllocatePageTable;
  Roots.Identity := AllocatePageTable;
  if OutOfMemory then
    Exit(0);

  if not VisitRealMemoryRanges(@MapMemoryRange, @Roots) then
    Exit(0);
  MapFramebuffer(Roots.Kernel, BootInformation.Framebuffer);
  MapDebugPort(Roots.Kernel, BootInformation.AcpiRootPointer);
  MapKernelImage(Roots.Kernel, KernelImage);
  if OutOfMemory then
    Exit(0);

  IdentityRoot := Roots.Identity;
  Result := QWord(Roots.Kernel);
end;

end.
