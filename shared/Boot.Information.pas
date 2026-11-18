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
  BootInformationVersion = 6;

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
  { The RAM disk image (RamDiskPhysicalBase): RAM the kernel must keep. }
  MemoryRegionRamDisk = 10;

  PixelFormatRedGreenBlue = 1;
  PixelFormatBlueGreenRed = 2;
  { 16 bits per pixel: red in bits 15-11, green 10-5, blue 4-0 (a
    Raspberry Pi firmware's simple-framebuffer, r5g6b5). The others are
    32 bits per pixel. }
  PixelFormatRedGreenBlue565 = 3;

  PageSize = 4096;

  { The display's EDID (its base block): what the firmware read. }
  EdidBlockSize = 128;
  { Room for the kernel command line, including the terminating zero
    (a Raspberry Pi's firmware puts a few hundred characters of its own
    before the options of cmdline.txt). }
  CommandLineCapacity = 1024;

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
    { The display's EDID base block, if the firmware offered it
      (HasEdid): its physical size gives the display's DPI. }
    HasEdid: LongWord;
    Padding: LongWord;
    Edid: array[0..EdidBlockSize - 1] of Byte;
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
      \FreePascalOS\options.txt (a native boot: the device tree's
      /chosen bootargs). Words are separated by spaces. }
    CommandLine: array[0..CommandLineCapacity - 1] of Char;

    { The time of day the firmware told the loader (its GetTime runtime
      service), in seconds since 1970-01-01 UTC; zero if it did not. For
      machines whose clock the kernel cannot read (AArch64). }
    FirmwareTime: Int64;

    { A disk image the loader read into memory - the system volume of a
      network boot - which the kernel offers as a writable RAM disk
      (Drivers.RamDisk); both zero if there is none. Its pages are a
      MemoryRegionRamDisk region of the memory map. }
    RamDiskPhysicalBase: QWord;
    RamDiskSizeInBytes: QWord;

    { The flattened device tree a native boot (boot/native) was given,
      copied into boot data pages (they stay the kernel's); both zero on
      a UEFI boot, which describes the machine with ACPI
      (AcpiRootPointer) instead. }
    DeviceTreePhysicalBase: QWord;
    DeviceTreeSizeInBytes: QWord;

    MemoryRegionCount: QWord;
    MemoryRegions: array[0..MaximumMemoryRegions - 1] of TMemoryRegion;
  end;
  PBootInformation = ^TBootInformation;

implementation

end.
