{
  Boot information contract between the OS loader and the kernel.

  The loader fills in one TBootInformation record and passes its address
  to the kernel entry point. The loader and kernel are compiled for
  different compiler targets (PE/Win64 and ELF/SysV), so every field uses an
  explicitly sized type and enumerations are expressed as constants to keep
  the record layout identical on both sides.

  Unless a field name says otherwise, addresses in this record are
  physical addresses.
}
unit Boot.Information;

{$mode objfpc}

interface

const
  { 'FPOSBOOT' in little endian ASCII. }
  BootInformationSignature = QWord($544F4F42534F5046);
  BootInformationVersion = 2;

  MaximumMemoryRegions = 512;

  { Kinds of physical memory reported to the kernel. }
  MemoryRegionUsable = 1;
  MemoryRegionReserved = 2;
  MemoryRegionAcpiReclaimable = 3;
  MemoryRegionAcpiNonVolatile = 4;
  MemoryRegionFirmwareRuntime = 5;
  MemoryRegionKernelImage = 6;
  MemoryRegionBootData = 7;
  MemoryRegionBootPageTables = 8;
  MemoryRegionUnusable = 9;

  PixelFormatRedGreenBlue = 1;
  PixelFormatBlueGreenRed = 2;

  PageSize = 4096;

  { Room for the kernel command line, including the terminating zero. }
  CommandLineCapacity = 256;

type
  TMemoryRegion = record
    PhysicalStart: QWord;
    PageCount: QWord;
    Kind: LongWord;
    Padding: LongWord;
  end;
  PMemoryRegion = ^TMemoryRegion;

  TFramebufferInformation = record
    PhysicalBase: QWord;
    SizeInBytes: QWord;
    Width: LongWord;
    Height: LongWord;
    PixelsPerScanLine: LongWord;
    PixelFormat: LongWord;
  end;

  TKernelImageInformation = record
    PhysicalBase: QWord;
    VirtualBase: QWord;
    SizeInBytes: QWord;
  end;

  TBootInformation = record
    Signature: QWord;
    Version: LongWord;
    Padding: LongWord;

    KernelImage: TKernelImageInformation;
    Framebuffer: TFramebufferInformation;

    { Virtual address at which the loader mapped all of physical memory. }
    PhysicalMemoryWindowBase: QWord;

    { Physical address of the top level page table the kernel starts on. }
    PageTableRoot: QWord;

    { Boot stack the kernel entry point runs on. }
    BootStackPhysicalBase: QWord;
    BootStackSizeInBytes: QWord;

    { Physical address of the ACPI RSDP structure, or zero if absent. }
    AcpiRootPointer: QWord;

    { Options for the kernel, read by the loader from the optional file
      \FreePascalOS\options.txt. Words are separated by spaces. }
    CommandLine: array[0..CommandLineCapacity - 1] of Char;

    MemoryRegionCount: QWord;
    MemoryRegions: array[0..MaximumMemoryRegions - 1] of TMemoryRegion;
  end;
  PBootInformation = ^TBootInformation;

implementation

end.
