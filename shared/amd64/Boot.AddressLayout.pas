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
