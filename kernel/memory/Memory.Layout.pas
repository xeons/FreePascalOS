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
  Kernel virtual address space layout and physical memory window helpers.

  All of physical memory is mapped at a fixed offset (the physical memory
  window, set up by the loader), so translating between a physical address
  and a usable pointer is a single addition.
}
unit Memory.Layout;

{$mode objfpc}

interface

uses
  Boot.AddressLayout;

const
  PageShift = 12;
  PageSize = QWord(1) shl PageShift;
  PageOffsetMask = PageSize - 1;

  WindowBase = PhysicalMemoryWindowBase;
  DynamicRegionBase = KernelDynamicRegionBase;
  DynamicRegionSize = KernelDynamicRegionSize;

type
  TPhysicalAddress = QWord;
  PPhysicalAddress = ^TPhysicalAddress;

function PhysicalToVirtual(PhysicalAddress: TPhysicalAddress): Pointer;
function WindowVirtualToPhysical(VirtualAddress: Pointer): TPhysicalAddress;
function IsInPhysicalWindow(VirtualAddress: Pointer): Boolean;

function RoundDownToPage(Value: QWord): QWord;
function RoundUpToPage(Value: QWord): QWord;
function PagesForBytes(ByteCount: QWord): QWord;

implementation

function PhysicalToVirtual(PhysicalAddress: TPhysicalAddress): Pointer;
begin
  Result := Pointer(PhysicalMemoryWindowBase + PhysicalAddress);
end;

function WindowVirtualToPhysical(VirtualAddress: Pointer): TPhysicalAddress;
begin
  Result := QWord(VirtualAddress) - PhysicalMemoryWindowBase;
end;

function IsInPhysicalWindow(VirtualAddress: Pointer): Boolean;
begin
  Result := (QWord(VirtualAddress) >= PhysicalMemoryWindowBase) and
    (QWord(VirtualAddress) - PhysicalMemoryWindowBase < PhysicalMemoryWindowSize);
end;

function RoundDownToPage(Value: QWord): QWord;
begin
  Result := Value and not PageOffsetMask;
end;

function RoundUpToPage(Value: QWord): QWord;
begin
  Result := (Value + PageOffsetMask) and not PageOffsetMask;
end;

function PagesForBytes(ByteCount: QWord): QWord;
begin
  Result := RoundUpToPage(ByteCount) shr PageShift;
end;

end.
