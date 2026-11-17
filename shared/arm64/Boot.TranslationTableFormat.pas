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
  The AArch64 stage 1 translation table format the loader and the kernel
  share: 4 KiB granule, 48-bit virtual and physical addresses, four
  levels of 512 entries (the kernel numbers them 4 = top .. 1 = pages,
  as on x86-64; the architecture calls them level 0 .. 3).

  The memory attribute indirection register (MAIR_EL1) holds the memory
  types; a descriptor picks one by index:

    0  normal memory, write-back cached (RAM)
    1  device-nGnRE (device registers)
    2  normal memory, non-cacheable (the framebuffer: writes combine)
    3  device-nGnRnE (strictly ordered registers)
}
unit Boot.TranslationTableFormat;

{$mode objfpc}

interface

const
  DescriptorValid = QWord(1) shl 0;
  { Bit 1 set: a table (levels 4-2) or a page (level 1); clear: a block. }
  DescriptorTableOrPage = QWord(1) shl 1;
  DescriptorAttributeIndexShift = 2;
  { EL0 may access. }
  DescriptorUserAccess = QWord(1) shl 6;
  { Read-only (at every level of privilege that may access). }
  DescriptorReadOnly = QWord(1) shl 7;
  DescriptorInnerShareable = QWord(3) shl 8;
  DescriptorAccessed = QWord(1) shl 10;
  DescriptorNotGlobal = QWord(1) shl 11;
  DescriptorPrivilegedExecuteNever = QWord(1) shl 53;
  DescriptorUserExecuteNever = QWord(1) shl 54;
  { Available to software. }
  DescriptorSoftwareCopyOnWrite = QWord(1) shl 55;
  DescriptorSoftwareDevicePage = QWord(1) shl 56;

  DescriptorAddressMask = QWord($0000FFFFFFFFF000);

  MemoryTypeNormal = 0;
  MemoryTypeDevice = 1;
  MemoryTypeNonCacheable = 2;
  MemoryTypeStrictDevice = 3;

  { Attr0 FFh normal write-back read/write-allocate, Attr1 04h
    device-nGnRE, Attr2 44h normal non-cacheable, Attr3 00h device-nGnRnE. }
  MemoryAttributeIndirection = QWord($004404FF);

  { TCR_EL1: T0SZ = T1SZ = 16 (48-bit halves), 4 KiB granules for both,
    table walks inner shareable and write-back cached. The physical
    address size (IPS, bits 34-32) is the processor's own, copied from
    ID_AA64MMFR0_EL1 when the register is loaded. }
  TranslationControl =
    QWord(16) or                    { T0SZ }
    (QWord(1) shl 8) or             { IRGN0 write-back write-allocate }
    (QWord(1) shl 10) or            { ORGN0 }
    (QWord(3) shl 12) or            { SH0 inner shareable }
    (QWord(0) shl 14) or            { TG0 4 KiB }
    (QWord(16) shl 16) or           { T1SZ }
    (QWord(1) shl 24) or            { IRGN1 }
    (QWord(1) shl 26) or            { ORGN1 }
    (QWord(3) shl 28) or            { SH1 }
    (QWord(2) shl 30);              { TG1 4 KiB }
  TranslationControlPhysicalSizeShift = 32;

  EntriesPerTable = 512;
  { The first address translated through TTBR1_EL1. }
  UpperHalfBase = QWord($FFFF000000000000);

function MemoryTypeBits(MemoryType: Integer): QWord;

implementation

function MemoryTypeBits(MemoryType: Integer): QWord;
begin
  Result := QWord(MemoryType) shl DescriptorAttributeIndexShift;
end;

end.
