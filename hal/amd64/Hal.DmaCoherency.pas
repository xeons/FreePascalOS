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
  Cache maintenance for DMA on x86-64: none. Devices on x86 snoop the
  processors' caches, so DMA is always coherent and these routines do
  nothing (see the AArch64 unit for what they are for).
}
unit Hal.DmaCoherency;

{$mode objfpc}

interface

const
  { Whether a device's DMA is coherent when the firmware does not say. }
  DmaIsCoherentByDefault = True;

{ The device will read [Address, Address + SizeInBytes). }
procedure CleanDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
{ The device will write the range. }
procedure CleanAndInvalidateDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
{ The device wrote the range; the processor reads it next. }
procedure InvalidateDataCacheAfterDevice(Address: Pointer; SizeInBytes: QWord);

implementation

procedure CleanDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
begin
end;

procedure CleanAndInvalidateDataCacheForDevice(Address: Pointer; SizeInBytes: QWord);
begin
end;

procedure InvalidateDataCacheAfterDevice(Address: Pointer; SizeInBytes: QWord);
begin
end;

end.
