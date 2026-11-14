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
  Virtual address space layout for x86-64.

  Both the loader (which builds the first page tables) and the kernel
  (which keeps using them) need to agree on these addresses.

    0000_0000_0000_0000 .. 0000_7FFF_FFFF_FFFF   User space (future)
    FFFF_8000_0000_0000 .. FFFF_BFFF_FFFF_FFFF   Physical memory window
    FFFF_C000_0000_0000 .. FFFF_C0FF_FFFF_FFFF   Kernel dynamic region
    FFFF_FFFF_8000_0000 .. FFFF_FFFF_FFFF_FFFF   Kernel image

  The physical memory window maps every physical address at a fixed offset,
  so the kernel can reach page tables and page frames without mapping them.
}
unit Boot.AddressLayout;

{$mode objfpc}

interface

const
  PhysicalMemoryWindowBase = QWord($FFFF800000000000);
  PhysicalMemoryWindowSize = QWord($0000400000000000);

  KernelDynamicRegionBase = QWord($FFFFC00000000000);
  KernelDynamicRegionSize = QWord($0000010000000000);

  KernelImageBase = QWord($FFFFFFFF80000000);

  { The loader always maps at least this much of the physical address
    space so that memory mapped devices below 4 GiB are reachable. }
  MinimumPhysicalWindowCoverage = QWord($100000000);

implementation

end.
