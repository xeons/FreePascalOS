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
  Building the AArch64 translation tables a kernel starts on, for both
  boot paths: the UEFI loader (boot/uefi/arm64/Loader.Arch.PageTables)
  and the native boot stub (boot/native/arm64/Native.PageTables).

  The tables are written through their physical addresses (the firmware's
  identity mapping, or no translation at all), in pages the caller's
  allocator hands out zeroed. Ranges are mapped with 2 MiB blocks where
  they cover a whole aligned block and with 4 KiB pages at their edges,
  so nothing beyond them is mapped as memory (a device's registers next
  to RAM must never be normal memory: the processor may read it
  speculatively). Mapping over part of a block splits it into pages.

  Nothing is both writable and executable: the physical memory window
  is execute-never, the kernel image's code read-only, and the window's
  view of the kernel's code and read-only data is made read-only too
  (ProtectKernelImageInWindow), so neither can be changed through
  another address.
}
unit Boot.TranslationTableBuilder;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.KernelElf;

type
  { A zeroed page for a table, by physical address; 0 when memory ran out. }
  TTablePageAllocator = function: QWord;

  TTranslationTableBuilder = record
    AllocatePage: TTablePageAllocator;
    OutOfMemory: Boolean;
  end;

procedure InitializeTableBuilder(out Builder: TTranslationTableBuilder; Allocator: TTablePageAllocator);
{ A new, empty top level table (0 if memory ran out). }
function CreateTableRoot(var Builder: TTranslationTableBuilder): QWord;
{ Maps [PhysicalStart, PhysicalStart + SizeInBytes), page aligned
  outwards, at VirtualStart with Attributes. }
procedure MapTranslationRange(var Builder: TTranslationTableBuilder; Root: QWord;
  VirtualStart, PhysicalStart, SizeInBytes, Attributes: QWord);

{ Normal cached memory, executable (the hand-off's identity mapping). }
function ExecutableMemoryAttributes: QWord;
{ Data of MemoryType (Boot.TranslationTableFormat): never executable. }
function DataAttributes(MemoryType: Integer): QWord;
{ A kernel image segment: text read-only and executable, the rest
  execute-never, nothing for user mode. }
function KernelSegmentAttributes(IsWritable, IsExecutable: Boolean): QWord;
{ Maps the window's view (at WindowBase + physical address) of every
  read-only segment of the kernel image read-only, after the window was
  mapped. }
procedure ProtectKernelImageInWindow(var Builder: TTranslationTableBuilder; Root: QWord; WindowBase: QWord;
  const KernelImage: TLoadedKernelImage);

implementation

uses
  Boot.TranslationTableFormat;

const
  BlockSize = QWord(2) * 1024 * 1024;
  PageBytes = QWord(4096);

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

procedure InitializeTableBuilder(out Builder: TTranslationTableBuilder; Allocator: TTablePageAllocator);
begin
  Builder.AllocatePage := Allocator;
  Builder.OutOfMemory := False;
end;

function AllocateTable(var Builder: TTranslationTableBuilder): PPageTable;
var
  PhysicalAddress: QWord;
begin
  PhysicalAddress := Builder.AllocatePage();
  if PhysicalAddress = 0 then
    Builder.OutOfMemory := True;
  Result := PPageTable(PhysicalAddress);
end;

function CreateTableRoot(var Builder: TTranslationTableBuilder): QWord;
begin
  Result := QWord(AllocateTable(Builder));
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
function SplitBlock(var Builder: TTranslationTableBuilder; Block: QWord): QWord;
var
  Table: PPageTable;
  Index: Integer;
  Attributes: QWord;
  Physical: QWord;
begin
  Table := AllocateTable(Builder);
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
function GetOrCreateNextTable(var Builder: TTranslationTableBuilder; Table: PPageTable; Index: Integer): PPageTable;
var
  NextTable: PPageTable;
begin
  if IsTableEntry(Table^[Index]) then
    Exit(PPageTable(Table^[Index] and DescriptorAddressMask));

  if (Table^[Index] and DescriptorValid) <> 0 then
  begin
    Table^[Index] := SplitBlock(Builder, Table^[Index]);
    if Table^[Index] = 0 then
      Exit(nil);
    Exit(PPageTable(Table^[Index] and DescriptorAddressMask));
  end;

  NextTable := AllocateTable(Builder);
  if NextTable = nil then
    Exit(nil);
  Table^[Index] := QWord(NextTable) or DescriptorValid or DescriptorTableOrPage;
  Result := NextTable;
end;

function DescendTo(var Builder: TTranslationTableBuilder; Root: PPageTable; VirtualAddress: QWord;
  LastLevel: Integer): PPageTable;
var
  Level: Integer;
begin
  Result := Root;
  Level := 4;
  while (Level > LastLevel) and (Result <> nil) do
  begin
    Result := GetOrCreateNextTable(Builder, Result, TableIndexForLevel(VirtualAddress, Level));
    Dec(Level);
  end;
end;

procedure MapPage(var Builder: TTranslationTableBuilder; Root: PPageTable;
  VirtualAddress, PhysicalAddress, Attributes: QWord);
var
  Table: PPageTable;
begin
  Table := DescendTo(Builder, Root, VirtualAddress, 1);
  if Table <> nil then
    Table^[TableIndexForLevel(VirtualAddress, 1)] := PhysicalAddress or Attributes or
      DescriptorValid or DescriptorTableOrPage;
end;

procedure MapBlock(var Builder: TTranslationTableBuilder; Root: PPageTable;
  VirtualAddress, PhysicalAddress, Attributes: QWord);
var
  Table: PPageTable;
begin
  Table := DescendTo(Builder, Root, VirtualAddress, 2);
  if Table <> nil then
    Table^[TableIndexForLevel(VirtualAddress, 2)] := PhysicalAddress or Attributes or DescriptorValid;
end;

procedure MapTranslationRange(var Builder: TTranslationTableBuilder; Root: QWord;
  VirtualStart, PhysicalStart, SizeInBytes, Attributes: QWord);
var
  Physical: QWord;
  PhysicalEnd: QWord;
  Offset: QWord;
begin
  if (Root = 0) or (SizeInBytes = 0) then
    Exit;
  Physical := PhysicalStart and not (PageBytes - 1);
  PhysicalEnd := (PhysicalStart + SizeInBytes + PageBytes - 1) and not (PageBytes - 1);
  Offset := VirtualStart - PhysicalStart;
  while (Physical < PhysicalEnd) and not Builder.OutOfMemory do
  begin
    if ((Physical and (BlockSize - 1)) = 0) and (PhysicalEnd - Physical >= BlockSize) and
       (((Physical + Offset) and (BlockSize - 1)) = 0) then
    begin
      MapBlock(Builder, PPageTable(Root), Physical + Offset, Physical, Attributes);
      Physical := Physical + BlockSize;
    end
    else
    begin
      MapPage(Builder, PPageTable(Root), Physical + Offset, Physical, Attributes);
      Physical := Physical + PageBytes;
    end;
  end;
end;

function ExecutableMemoryAttributes: QWord;
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

function KernelSegmentAttributes(IsWritable, IsExecutable: Boolean): QWord;
begin
  Result := ExecutableMemoryAttributes or DescriptorUserExecuteNever;
  if not IsWritable then
    Result := Result or DescriptorReadOnly;
  if not IsExecutable then
    Result := Result or DescriptorPrivilegedExecuteNever;
end;

procedure ProtectKernelImageInWindow(var Builder: TTranslationTableBuilder; Root: QWord; WindowBase: QWord;
  const KernelImage: TLoadedKernelImage);
var
  Index: LongWord;
  Segment: ^TKernelSegment;
begin
  Index := 0;
  while Index < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[Index];
    if not Segment^.IsWritable then
      MapTranslationRange(Builder, Root, WindowBase + Segment^.PhysicalStart, Segment^.PhysicalStart,
        Segment^.PageCount * PageBytes, DataAttributes(MemoryTypeNormal) or DescriptorReadOnly);
    Inc(Index);
  end;
end;

end.
