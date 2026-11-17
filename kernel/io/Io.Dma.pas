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
  DMA memory for drivers: what a device can reach, the addresses it uses
  for it, and keeping the processors' caches and the device in step.

  A device's DMA attributes (TDmaAttributes) say:
    - whether it snoops the caches (coherent: every x86 device, PCIe on
      QEMU's virt machine; ACPI _CCA = 1) or not (the Raspberry Pi 4's
      EMMC2, GENET and xHCI: _CCA = 0);
    - how its bus addresses map to physical memory (ACPI _DMA: windows
      of physical memory, each seen at a bus address of its own; none
      means it sees physical addresses one to one, all of them);
    - the highest bus address it can put out itself (32-bit DMA engines).
  The platform code fills them in (Io.PlatformDevices for ACPI devices
  and PCI devices).

  Two kinds of buffer:
    - shared ones (DmaShared: descriptor rings, contexts, anything both
      sides read and write while the device runs) are mapped uncached
      for a device that does not snoop, so neither side ever sees stale
      data and no maintenance is needed;
    - streaming ones (DmaStreaming: data buffers) stay cached; the driver
      brackets each transfer: PrepareDmaToDevice before the device reads
      the buffer, PrepareDmaFromDevice before it writes it and
      FinishDmaFromDevice after it wrote it (Hal.DmaCoherency). For a
      coherent device these do nothing.

  The kernel option "noncoherentdma" treats every device as not
  coherent, which exercises the uncached buffers and the cache
  maintenance on machines (QEMU) whose devices all snoop.
}
unit Io.Dma;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumDmaWindows = 4;
  OptionNonCoherentDma = 'noncoherentdma';

type
  TDmaWindow = record
    { Physical memory [PhysicalStart, PhysicalStart + Length) is seen by
      the device at BusStart. }
    PhysicalStart: QWord;
    BusStart: QWord;
    Length: QWord;
  end;

  TDmaAttributes = record
    Coherent: Boolean;
    { 0: the device sees physical addresses as they are. }
    WindowCount: Integer;
    Windows: array[0..MaximumDmaWindows - 1] of TDmaWindow;
    { The first bus address the device cannot put out (0: no limit). }
    BusAddressLimit: QWord;
  end;
  PDmaAttributes = ^TDmaAttributes;

  TDmaBufferKind = (DmaShared, DmaStreaming);

  TDmaBuffer = record
    Address: PByte;
    Physical: QWord;
    { What the device is given for Address. }
    DeviceAddress: QWord;
    SizeInBytes: QWord;
    { Mapped uncached in the dynamic region (a shared buffer of a device
      that does not snoop), not reached through the physical window. }
    IsUncachedMapping: Boolean;
  end;
  PDmaBuffer = ^TDmaBuffer;

{ Coherent unless the architecture says otherwise (Hal.DmaCoherency) or
  the noncoherentdma option is set; no windows, no limit. }
procedure SetDefaultDmaAttributes(out Attributes: TDmaAttributes);
{ Applies the noncoherentdma option to attributes the firmware gave. }
procedure ApplyDmaOptions(var Attributes: TDmaAttributes);
{ The device itself only puts out bus addresses below Limit. }
procedure LimitDmaBusAddresses(var Attributes: TDmaAttributes; Limit: QWord);
{ The first physical address past the memory the device can reach in
  one piece starting low (where allocations for it come from). }
function DmaPhysicalLimit(constref Attributes: TDmaAttributes): QWord;

{ The bus address the device uses for physical memory [Physical,
  Physical + SizeInBytes); False if it cannot reach all of it. }
function TranslateDmaAddress(constref Attributes: TDmaAttributes; Physical: QWord; SizeInBytes: QWord;
  out DeviceAddress: QWord): Boolean;

{ SizeInBytes (rounded up to pages) of zeroed, physically contiguous
  memory the device can reach. False if there is none. }
function AllocateDmaBuffer(constref Attributes: TDmaAttributes; SizeInBytes: QWord; Kind: TDmaBufferKind;
  out Buffer: TDmaBuffer): Boolean;
procedure FreeDmaBuffer(var Buffer: TDmaBuffer);

{ Cache maintenance around a transfer, for memory reached through the
  caches (streaming buffers, or any kernel memory); nothing for a
  coherent device. }
procedure PrepareDmaToDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);
procedure PrepareDmaFromDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);
procedure FinishDmaFromDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);

{ "coherent" or "not coherent", for the drivers' start-up lines. }
function DmaCoherenceText(constref Attributes: TDmaAttributes): PChar;

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.VirtualRanges,
  Memory.Arch.PageTables,
  Kernel.Options,
  Hal.DmaCoherency;

procedure SetDefaultDmaAttributes(out Attributes: TDmaAttributes);
begin
  ZeroMemory(@Attributes, SizeOf(Attributes));
  Attributes.Coherent := DmaIsCoherentByDefault;
  ApplyDmaOptions(Attributes);
end;

procedure ApplyDmaOptions(var Attributes: TDmaAttributes);
begin
  if KernelOptionIsSet(OptionNonCoherentDma) then
    Attributes.Coherent := False;
end;

procedure LimitDmaBusAddresses(var Attributes: TDmaAttributes; Limit: QWord);
begin
  if (Attributes.BusAddressLimit = 0) or (Limit < Attributes.BusAddressLimit) then
    Attributes.BusAddressLimit := Limit;
end;

{ The physical end of Window that its bus addresses stay below the
  device's own limit for (PhysicalStart if none). }
function UsableWindowEnd(constref Attributes: TDmaAttributes; constref Window: TDmaWindow): QWord;
var
  UsableLength: QWord;
begin
  UsableLength := Window.Length;
  if Attributes.BusAddressLimit <> 0 then
  begin
    if Window.BusStart >= Attributes.BusAddressLimit then
      UsableLength := 0
    else if Attributes.BusAddressLimit - Window.BusStart < UsableLength then
      UsableLength := Attributes.BusAddressLimit - Window.BusStart;
  end;
  Result := Window.PhysicalStart + UsableLength;
end;

function DmaPhysicalLimit(constref Attributes: TDmaAttributes): QWord;
var
  Index: Integer;
  Lowest: Integer;
begin
  if Attributes.WindowCount = 0 then
  begin
    if Attributes.BusAddressLimit = 0 then
      Exit(High(QWord));
    Exit(Attributes.BusAddressLimit);
  end;
  { The window that starts lowest: allocations search upwards from the
    bottom of memory. }
  Lowest := 0;
  for Index := 1 to Attributes.WindowCount - 1 do
    if Attributes.Windows[Index].PhysicalStart < Attributes.Windows[Lowest].PhysicalStart then
      Lowest := Index;
  Result := UsableWindowEnd(Attributes, Attributes.Windows[Lowest]);
end;

function TranslateDmaAddress(constref Attributes: TDmaAttributes; Physical: QWord; SizeInBytes: QWord;
  out DeviceAddress: QWord): Boolean;
var
  Index: Integer;
  Window: TDmaWindow;
begin
  Result := False;
  DeviceAddress := 0;
  if Attributes.WindowCount = 0 then
  begin
    DeviceAddress := Physical;
    Result := (Attributes.BusAddressLimit = 0) or
      ((Physical < Attributes.BusAddressLimit) and (SizeInBytes <= Attributes.BusAddressLimit - Physical));
    Exit;
  end;
  for Index := 0 to Attributes.WindowCount - 1 do
  begin
    Window := Attributes.Windows[Index];
    if (Physical >= Window.PhysicalStart) and (Physical - Window.PhysicalStart < Window.Length) and
       (SizeInBytes <= Window.Length - (Physical - Window.PhysicalStart)) and
       (Physical + SizeInBytes <= UsableWindowEnd(Attributes, Window)) then
    begin
      DeviceAddress := Window.BusStart + (Physical - Window.PhysicalStart);
      Exit(True);
    end;
  end;
end;

{ Maps PageCount pages from Physical uncached (normal memory, not
  cached) into the dynamic region; nil if address space ran out. }
function MapUncached(Physical: QWord; PageCount: QWord): PByte;
var
  VirtualStart: QWord;
  PageIndex: QWord;
  Removed: TPhysicalPageRun;
  Done: QWord;
  RunLength: LongWord;
begin
  Result := nil;
  VirtualStart := AllocateVirtualRange(PageCount);
  if VirtualStart = 0 then
    Exit;
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    if not MapKernelPage(VirtualStart + PageIndex * PageSize, Physical + PageIndex * PageSize,
      MappingWritable or MappingWriteCombining or MappingDevice) then
    begin
      Done := 0;
      while Done < PageIndex do
      begin
        RunLength := MaximumPagesPerRun;
        if PageIndex - Done < RunLength then
          RunLength := LongWord(PageIndex - Done);
        UnmapKernelPageRun(VirtualStart + Done * PageSize, RunLength, Removed);
        Done := Done + RunLength;
      end;
      FreeVirtualRange(VirtualStart, PageCount);
      Exit;
    end;
    Inc(PageIndex);
  end;
  Result := PByte(VirtualStart);
end;

procedure UnmapUncached(Address: PByte; PageCount: QWord);
var
  Done: QWord;
  RunLength: LongWord;
  Removed: TPhysicalPageRun;
begin
  Done := 0;
  while Done < PageCount do
  begin
    RunLength := MaximumPagesPerRun;
    if PageCount - Done < RunLength then
      RunLength := LongWord(PageCount - Done);
    UnmapKernelPageRun(QWord(Address) + Done * PageSize, RunLength, Removed);
    Done := Done + RunLength;
  end;
  FreeVirtualRange(QWord(Address), PageCount);
end;

procedure FreePages(Physical: QWord; PageCount: QWord);
var
  PageIndex: QWord;
begin
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    FreePhysicalPage(Physical + PageIndex * PageSize);
    Inc(PageIndex);
  end;
end;

function AllocateDmaBuffer(constref Attributes: TDmaAttributes; SizeInBytes: QWord; Kind: TDmaBufferKind;
  out Buffer: TDmaBuffer): Boolean;
var
  PageCount: QWord;
  Limit: QWord;
begin
  Result := False;
  ZeroMemory(@Buffer, SizeOf(Buffer));
  if SizeInBytes = 0 then
    Exit;
  PageCount := PagesForBytes(SizeInBytes);
  Limit := DmaPhysicalLimit(Attributes);
  if Limit < PageSize then
    Exit;
  if PageCount = 1 then
    Buffer.Physical := AllocateZeroedPhysicalPageBelow(Limit, PageUsageGeneral)
  else
    Buffer.Physical := AllocateZeroedContiguousPhysicalPages(PageCount, Limit, PageUsageGeneral);
  if Buffer.Physical = 0 then
    Exit;
  Buffer.SizeInBytes := PageCount * PageSize;
  if not TranslateDmaAddress(Attributes, Buffer.Physical, Buffer.SizeInBytes, Buffer.DeviceAddress) then
  begin
    FreePages(Buffer.Physical, PageCount);
    Exit;
  end;
  Buffer.Address := PByte(PhysicalToVirtual(Buffer.Physical));
  { The zeros are in the cache: written out (and dropped, for the
    uncached mapping) before the device looks. }
  CleanAndInvalidateDataCacheForDevice(Buffer.Address, Buffer.SizeInBytes);
  if not Attributes.Coherent and (Kind = DmaShared) then
  begin
    Buffer.Address := MapUncached(Buffer.Physical, PageCount);
    if Buffer.Address = nil then
    begin
      FreePages(Buffer.Physical, PageCount);
      Exit;
    end;
    Buffer.IsUncachedMapping := True;
  end;
  Result := True;
end;

procedure FreeDmaBuffer(var Buffer: TDmaBuffer);
var
  PageCount: QWord;
begin
  if Buffer.Physical = 0 then
    Exit;
  PageCount := Buffer.SizeInBytes div PageSize;
  if Buffer.IsUncachedMapping then
    UnmapUncached(Buffer.Address, PageCount);
  FreePages(Buffer.Physical, PageCount);
  ZeroMemory(@Buffer, SizeOf(Buffer));
end;

procedure PrepareDmaToDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);
begin
  if not Attributes.Coherent then
    CleanDataCacheForDevice(Address, SizeInBytes);
end;

procedure PrepareDmaFromDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);
begin
  if not Attributes.Coherent then
    CleanAndInvalidateDataCacheForDevice(Address, SizeInBytes);
end;

procedure FinishDmaFromDevice(constref Attributes: TDmaAttributes; Address: Pointer; SizeInBytes: QWord);
begin
  if not Attributes.Coherent then
    InvalidateDataCacheAfterDevice(Address, SizeInBytes);
end;

function DmaCoherenceText(constref Attributes: TDmaAttributes): PChar;
begin
  if Attributes.Coherent then
    Result := 'coherent DMA'
  else
    Result := 'non-coherent DMA';
end;

end.
