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

  The table building itself is shared with the native boot stub
  (Boot.TranslationTableBuilder).
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
  Boot.TranslationTableBuilder,
  Loader.Memory,
  Loader.MemoryMap,
  Loader.Arch.DebugPort;

const
  PageBytes = QWord(LoaderPageSize);

type
  TRootPair = record
    Kernel: QWord;
    Identity: QWord;
  end;
  PRootPair = ^TRootPair;

var
  Builder: TTranslationTableBuilder;
  IdentityRoot: QWord;

function IdentityPageTableRoot: QWord;
begin
  Result := IdentityRoot;
end;

function AllocateTablePage: QWord;
begin
  Result := AllocateLoaderPages(1, LoaderMemoryTypePageTables);
end;

procedure MapMemoryRange(PhysicalStart, SizeInBytes: QWord; Context: Pointer);
var
  Roots: PRootPair;
begin
  Roots := PRootPair(Context);
  MapTranslationRange(Builder, Roots^.Kernel, PhysicalMemoryWindowBase + PhysicalStart, PhysicalStart,
    SizeInBytes, DataAttributes(MemoryTypeNormal));
  { The identity mapping is executable: the hand-off code runs there. }
  MapTranslationRange(Builder, Roots^.Identity, PhysicalStart, PhysicalStart, SizeInBytes,
    ExecutableMemoryAttributes);
end;

procedure MapFramebuffer(Root: QWord; const Framebuffer: TFramebufferInformation);
begin
  if (Framebuffer.PhysicalBase = 0) or (Framebuffer.SizeInBytes = 0) then
    Exit;
  MapTranslationRange(Builder, Root, PhysicalMemoryWindowBase + Framebuffer.PhysicalBase,
    Framebuffer.PhysicalBase, Framebuffer.SizeInBytes, DataAttributes(MemoryTypeNonCacheable));
end;

procedure MapDebugPort(Root: QWord; AcpiRootPointer: QWord);
var
  Registers: QWord;
begin
  Registers := FindDebugPortRegisters(AcpiRootPointer);
  if Registers = 0 then
    Exit;
  MapTranslationRange(Builder, Root, PhysicalMemoryWindowBase + Registers, Registers, PageBytes,
    DataAttributes(MemoryTypeDevice));
end;

procedure MapKernelImage(Root: QWord; const KernelImage: TLoadedKernelImage);
var
  SegmentIndex: LongWord;
  Segment: ^TKernelSegment;
begin
  SegmentIndex := 0;
  while SegmentIndex < KernelImage.SegmentCount do
  begin
    Segment := @KernelImage.Segments[SegmentIndex];
    MapTranslationRange(Builder, Root, Segment^.VirtualStart, Segment^.PhysicalStart,
      Segment^.PageCount * PageBytes, KernelSegmentAttributes(Segment^.IsWritable, Segment^.IsExecutable));
    Inc(SegmentIndex);
  end;
end;

function BuildInitialPageTables(const BootInformation: TBootInformation;
  PhysicalCoverage: QWord; const KernelImage: TLoadedKernelImage): QWord;
var
  Roots: TRootPair;
begin
  InitializeTableBuilder(Builder, @AllocateTablePage);
  Roots.Kernel := CreateTableRoot(Builder);
  Roots.Identity := CreateTableRoot(Builder);
  if Builder.OutOfMemory then
    Exit(0);

  if not VisitRealMemoryRanges(@MapMemoryRange, @Roots) then
    Exit(0);
  MapFramebuffer(Roots.Kernel, BootInformation.Framebuffer);
  MapDebugPort(Roots.Kernel, BootInformation.AcpiRootPointer);
  MapKernelImage(Roots.Kernel, KernelImage);
  if Builder.OutOfMemory then
    Exit(0);

  IdentityRoot := Roots.Identity;
  Result := Roots.Kernel;
end;

end.
