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
  The translation tables the kernel starts on after a native boot: the
  same two roots the UEFI loader builds (Boot.TranslationTableBuilder),
  from the device tree's memory instead of the UEFI memory map:

  - the kernel's (TTBR1_EL1): the physical memory window over all RAM
    but the reserved parts (normal cached memory), the framebuffer
    (normal non-cacheable), the console UART (device memory; on a
    Raspberry Pi 5 at 10_7D00_1000, far above RAM, which the 48-bit
    window reaches), and the kernel image at its linked address;
  - an identity mapping of the same RAM (TTBR0_EL1) for the hand-off.
}
unit Native.PageTables;

{$mode objfpc}

interface

uses
  Boot.Information,
  Boot.KernelElf;

{ The kernel's root, or 0 if memory ran out. UartPhysical (0: none) is
  the console's registers. }
function BuildNativePageTables(const BootInformation: TBootInformation; const KernelImage: TLoadedKernelImage;
  UartPhysical: QWord): QWord;
function NativeIdentityRoot: QWord;

implementation

uses
  Boot.AddressLayout,
  Boot.TranslationTableFormat,
  Boot.TranslationTableBuilder,
  Native.MemoryMap;

var
  Builder: TTranslationTableBuilder;
  KernelRoot: QWord;
  IdentityRoot: QWord;

function NativeIdentityRoot: QWord;
begin
  Result := IdentityRoot;
end;

function AllocateTablePage: QWord;
begin
  Result := AllocatePages(1, MemoryRegionBootPageTables);
end;

procedure MapMemoryPiece(PhysicalStart, SizeInBytes: QWord);
begin
  MapTranslationRange(Builder, KernelRoot, PhysicalMemoryWindowBase + PhysicalStart, PhysicalStart,
    SizeInBytes, DataAttributes(MemoryTypeNormal));
  MapTranslationRange(Builder, IdentityRoot, PhysicalStart, PhysicalStart, SizeInBytes,
    ExecutableMemoryAttributes);
end;

procedure MapKernelImage(const KernelImage: TLoadedKernelImage);
var
  Index: LongWord;
  Segment: ^TKernelSegment;
begin
  Index := 0;
  while Index < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[Index];
    MapTranslationRange(Builder, KernelRoot, Segment^.VirtualStart, Segment^.PhysicalStart,
      Segment^.PageCount * KernelPageSize, KernelSegmentAttributes(Segment^.IsWritable, Segment^.IsExecutable));
    Inc(Index);
  end;
end;

function BuildNativePageTables(const BootInformation: TBootInformation; const KernelImage: TLoadedKernelImage;
  UartPhysical: QWord): QWord;
var
  Framebuffer: TFramebufferInformation;
begin
  Result := 0;
  InitializeTableBuilder(Builder, @AllocateTablePage);
  KernelRoot := CreateTableRoot(Builder);
  IdentityRoot := CreateTableRoot(Builder);
  if Builder.OutOfMemory then
    Exit;

  VisitMappedMemory(@MapMemoryPiece);
  Framebuffer := BootInformation.Framebuffer;
  if (Framebuffer.PhysicalBase <> 0) and (Framebuffer.SizeInBytes <> 0) then
    MapTranslationRange(Builder, KernelRoot, PhysicalMemoryWindowBase + Framebuffer.PhysicalBase,
      Framebuffer.PhysicalBase, Framebuffer.SizeInBytes, DataAttributes(MemoryTypeNonCacheable));
  if UartPhysical <> 0 then
    MapTranslationRange(Builder, KernelRoot, PhysicalMemoryWindowBase + UartPhysical, UartPhysical,
      NativePageSize, DataAttributes(MemoryTypeDevice));
  MapKernelImage(KernelImage);
  if Builder.OutOfMemory then
    Exit;
  Result := KernelRoot;
end;

end.
