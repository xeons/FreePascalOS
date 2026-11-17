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
  Final transfer of control from the loader to the kernel on AArch64.

  The hand-off (LoaderHandoff.s) turns the MMU off for a moment, so
  everything the kernel reads first - its image, the boot information,
  the boot stack and the translation tables, all in the loader's own
  memory types - and the hand-off code itself are written back to
  memory first. The kernel starts at EL1 with x0 = the boot information
  and SP = the boot stack, like the first argument of a call.
}
unit Loader.Arch.Handoff;

{$mode objfpc}

interface

uses
  Elf64;

const
  KernelElfMachine = ElfMachineAarch64;

{ Switches to the kernel translation tables and stack, then jumps to the
  kernel entry point with BootInformation (its virtual address) as its
  only argument. Never returns. }
procedure TransferControlToKernel(PageTableRoot: QWord; StackTop: QWord;
  BootInformation: QWord; EntryPoint: QWord);

implementation

uses
  Boot.Information,
  Boot.AddressLayout,
  Loader.Arch.PageTables;

procedure ArchCleanDataCacheRange(Start, Size: QWord); external name 'ArchCleanDataCacheRange';
procedure ArchEnterKernel(KernelRoot, IdentityRoot, StackTop, BootInformation, EntryPoint: QWord);
  external name 'ArchEnterKernel';
procedure ArchEnterKernelStart; external name 'ArchEnterKernel';
procedure ArchEnterKernelEnd; external name 'ArchEnterKernelEnd';

procedure CleanLoaderRegions(Information: PBootInformation);
var
  Index: QWord;
  Region: PMemoryRegion;
begin
  Index := 0;
  while Index < Information^.MemoryRegionCount do
  begin
    Region := @Information^.MemoryRegions[Index];
    if (Region^.Kind = MemoryRegionKernelImage) or (Region^.Kind = MemoryRegionBootData) or
       (Region^.Kind = MemoryRegionBootPageTables) then
      ArchCleanDataCacheRange(Region^.PhysicalStart, Region^.PageCount * PageSize);
    Inc(Index);
  end;
end;

procedure TransferControlToKernel(PageTableRoot: QWord; StackTop: QWord;
  BootInformation: QWord; EntryPoint: QWord);
var
  Information: PBootInformation;
begin
  { The loader still runs on the firmware's identity mapping. }
  Information := PBootInformation(BootInformation - PhysicalMemoryWindowBase);
  CleanLoaderRegions(Information);
  ArchCleanDataCacheRange(QWord(@ArchEnterKernelStart),
    QWord(@ArchEnterKernelEnd) - QWord(@ArchEnterKernelStart));
  ArchEnterKernel(PageTableRoot, IdentityPageTableRoot, StackTop, BootInformation, EntryPoint);
end;

end.
