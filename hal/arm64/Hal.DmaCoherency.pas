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
  Cache maintenance for DMA on AArch64.

  A device that does not snoop the processors' caches (the Raspberry Pi
  4's EMMC2, GENET, xHCI behind the BCM2711 PCIe bridge: ACPI _CCA = 0)
  reads memory as it is in RAM and writes RAM behind the caches' back.
  So memory a device is about to read is cleaned (dirty lines written
  back) first; memory it is about to write is cleaned and invalidated
  (no dirty line may be evicted over its data later); and memory it
  wrote is invalidated again before the processor reads it (lines may
  have been fetched speculatively meanwhile). The routines work on whole
  cache lines to the point of coherency (CacheMaintenance.s); lines only
  partly in a range are never thrown away without being written back.

  ACPI on AArch64 wants _CCA on every device that does DMA and calls a
  device without it not coherent, so that is the default here.
}
unit Hal.DmaCoherency;

{$mode objfpc}

interface

const
  { Whether a device's DMA is coherent when the firmware does not say. }
  DmaIsCoherentByDefault = False;

{ The device will read [Address, Address + SizeInBytes). }
procedure CleanDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
{ The device will write the range. }
procedure CleanAndInvalidateDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
{ The device wrote the range; the processor reads it next. }
procedure InvalidateDataCacheAfterDevice(Address: Pointer; SizeInBytes: QWord);

implementation

procedure ArchCleanDataCacheRange(Address: Pointer; SizeInBytes: QWord);
  external name 'ArchCleanDataCacheRange';
procedure ArchCleanAndInvalidateDataCacheRange(Address: Pointer; SizeInBytes: QWord);
  external name 'ArchCleanAndInvalidateDataCacheRange';
procedure ArchInvalidateDataCacheRange(Address: Pointer; SizeInBytes: QWord);
  external name 'ArchInvalidateDataCacheRange';

procedure CleanDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
begin
  ArchCleanDataCacheRange(Address, SizeInBytes);
end;

procedure CleanAndInvalidateDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
begin
  ArchCleanAndInvalidateDataCacheRange(Address, SizeInBytes);
end;

procedure InvalidateDataCacheAfterDevice(Address: Pointer; SizeInBytes: QWord);
begin
  ArchInvalidateDataCacheRange(Address, SizeInBytes);
end;

end.
