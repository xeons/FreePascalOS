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
  Virtual address space layout for AArch64 (4 KiB granule, 48-bit
  virtual addresses, four translation levels).

  The same addresses as on x86-64. The lower half is translated through
  TTBR0_EL1 (one table per user address space), the upper half through
  TTBR1_EL1 (the kernel's, shared by all):

    0000_0000_0000_0000 .. 0000_7FFF_FFFF_FFFF   User space        (TTBR0)
    FFFF_8000_0000_0000 .. FFFF_BFFF_FFFF_FFFF   Physical memory window
    FFFF_C000_0000_0000 .. FFFF_C0FF_FFFF_FFFF   Kernel dynamic region
    FFFF_FFFF_8000_0000 .. FFFF_FFFF_FFFF_FFFF   Kernel image      (TTBR1)

  Unlike x86-64 the window maps only memory (RAM, as normal cached
  memory), the framebuffer (normal non-cacheable) and the firmware's
  debug UART (device memory): device registers mapped as normal memory
  could be fetched speculatively or cached, so every other device is
  mapped on demand with device attributes (Memory.DeviceMapping).
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

  { Devices are not reached through the window here (see above). }
  MinimumPhysicalWindowCoverage = QWord(0);

implementation

end.
