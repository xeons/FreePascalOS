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
  Retrieves the firmware memory map, translates it into the kernel's
  memory region format, and leaves boot services.

  The final memory map must be captured immediately before calling
  ExitBootServices, with no allocations in between, so translation into
  the boot information record happens in that window.
}
unit Loader.MemoryMap;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base,
  Boot.Information;

{ Returns the end of the highest range of real memory (RAM, ACPI tables
  and firmware runtime areas) in the current memory map, or zero on error. }
function FindHighestMemoryAddress: QWord;

type
  TMemoryRangeVisitor = procedure(PhysicalStart, SizeInBytes: QWord; Context: Pointer);

{ Calls Visitor for every range of real memory (as FindHighestMemoryAddress
  counts it) in the current memory map. False if the map could not be
  read. }
function VisitRealMemoryRanges(Visitor: TMemoryRangeVisitor; Context: Pointer): Boolean;

{ Captures the final memory map into BootInformation and exits boot
  services. On success the firmware console is no longer usable. }
function ExitBootServicesAndRecordMemoryMap(var BootInformation: TBootInformation): TEfiStatus;

implementation

uses
  Loader.Firmware,
  Loader.Memory,
  Loader.Console;

const
  ExtraDescriptorSlack = 16;
  MaximumExitAttempts = 4;

type
  TFirmwareMemoryMap = record
    Buffer: PByte;
    BufferCapacity: QWord;
    MapSize: QWord;
    MapKey: QWord;
    DescriptorSize: QWord;
    DescriptorVersion: LongWord;
  end;

function GetDescriptor(const Map: TFirmwareMemoryMap; Index: QWord): PEfiMemoryDescriptor;
begin
  Result := PEfiMemoryDescriptor(Map.Buffer + Index * Map.DescriptorSize);
end;

function DescriptorCount(const Map: TFirmwareMemoryMap): QWord;
begin
  Result := Map.MapSize div Map.DescriptorSize;
end;

{ Allocates a buffer big enough for the current memory map plus some room
  for growth, since the allocation itself can add descriptors. }
function AllocateMemoryMapBuffer(out Map: TFirmwareMemoryMap): TEfiStatus;
var
  RequiredSize: QWord;
begin
  Map.Buffer := nil;
  Map.BufferCapacity := 0;
  RequiredSize := 0;

  Result := FirmwareBootServices^.GetMemoryMap(@RequiredSize, nil, @Map.MapKey,
    @Map.DescriptorSize, @Map.DescriptorVersion);
  if Result <> EfiBufferTooSmall then
    Exit(EfiLoadError);

  Map.BufferCapacity := RequiredSize + ExtraDescriptorSlack * Map.DescriptorSize;
  Map.Buffer := AllocateTemporaryBuffer(Map.BufferCapacity);
  if Map.Buffer = nil then
    Exit(EfiOutOfResources);

  Result := EfiSuccess;
end;

function ReadMemoryMap(var Map: TFirmwareMemoryMap): TEfiStatus;
begin
  Map.MapSize := Map.BufferCapacity;
  Result := FirmwareBootServices^.GetMemoryMap(@Map.MapSize,
    PEfiMemoryDescriptor(Map.Buffer), @Map.MapKey, @Map.DescriptorSize,
    @Map.DescriptorVersion);
end;

function IsRealMemory(FirmwareType: LongWord): Boolean;
begin
  case FirmwareType of
    EfiLoaderCode, EfiLoaderData,
    EfiBootServicesCode, EfiBootServicesData,
    EfiRuntimeServicesCode, EfiRuntimeServicesData,
    EfiConventionalMemory,
    EfiAcpiReclaimMemory, EfiAcpiMemoryNvs,
    LoaderMemoryTypeKernelImage, LoaderMemoryTypeBootData, LoaderMemoryTypePageTables:
      Result := True;
  else
    Result := False;
  end;
end;

function VisitRealMemoryRanges(Visitor: TMemoryRangeVisitor; Context: Pointer): Boolean;
var
  Map: TFirmwareMemoryMap;
  DescriptorIndex: QWord;
  Descriptor: PEfiMemoryDescriptor;
begin
  Result := False;
  if EfiIsError(AllocateMemoryMapBuffer(Map)) then
    Exit;

  if not EfiIsError(ReadMemoryMap(Map)) then
  begin
    DescriptorIndex := 0;
    while DescriptorIndex < DescriptorCount(Map) do
    begin
      Descriptor := GetDescriptor(Map, DescriptorIndex);
      Inc(DescriptorIndex);
      if IsRealMemory(Descriptor^.MemoryType) then
        Visitor(Descriptor^.PhysicalStart, Descriptor^.NumberOfPages * LoaderPageSize, Context);
    end;
    Result := True;
  end;

  FreeTemporaryBuffer(Map.Buffer);
end;

procedure NoteRangeEnd(PhysicalStart, SizeInBytes: QWord; Context: Pointer);
var
  HighestEnd: PQWord;
begin
  HighestEnd := PQWord(Context);
  if PhysicalStart + SizeInBytes > HighestEnd^ then
    HighestEnd^ := PhysicalStart + SizeInBytes;
end;

function FindHighestMemoryAddress: QWord;
begin
  Result := 0;
  if not VisitRealMemoryRanges(@NoteRangeEnd, @Result) then
    Result := 0;
end;

function TranslateMemoryType(FirmwareType: LongWord): LongWord;
begin
  case FirmwareType of
    EfiLoaderCode,
    EfiLoaderData,
    EfiBootServicesCode,
    EfiBootServicesData,
    EfiConventionalMemory:
      Result := MemoryRegionUsable;

    EfiRuntimeServicesCode,
    EfiRuntimeServicesData:
      Result := MemoryRegionFirmwareRuntime;

    EfiAcpiReclaimMemory:
      Result := MemoryRegionAcpiReclaimable;

    EfiAcpiMemoryNvs:
      Result := MemoryRegionAcpiNonVolatile;

    EfiUnusableMemory:
      Result := MemoryRegionUnusable;

    LoaderMemoryTypeKernelImage:
      Result := MemoryRegionKernelImage;

    LoaderMemoryTypeBootData:
      Result := MemoryRegionBootData;

    LoaderMemoryTypePageTables:
      Result := MemoryRegionBootPageTables;
  else
    Result := MemoryRegionReserved;
  end;
end;

procedure SortRegionsByAddress(var BootInformation: TBootInformation);
var
  OuterIndex: QWord;
  InnerIndex: QWord;
  RegionToInsert: TMemoryRegion;
begin
  if BootInformation.MemoryRegionCount < 2 then
    Exit;

  for OuterIndex := 1 to BootInformation.MemoryRegionCount - 1 do
  begin
    RegionToInsert := BootInformation.MemoryRegions[OuterIndex];
    InnerIndex := OuterIndex;
    while (InnerIndex > 0) and
      (BootInformation.MemoryRegions[InnerIndex - 1].PhysicalStart > RegionToInsert.PhysicalStart) do
    begin
      BootInformation.MemoryRegions[InnerIndex] := BootInformation.MemoryRegions[InnerIndex - 1];
      Dec(InnerIndex);
    end;
    BootInformation.MemoryRegions[InnerIndex] := RegionToInsert;
  end;
end;

{ Joins neighbouring regions of the same kind into one. }
procedure MergeAdjacentRegions(var BootInformation: TBootInformation);
var
  ReadIndex: QWord;
  WriteIndex: QWord;
  Previous: PMemoryRegion;
  Current: PMemoryRegion;
  PreviousEnd: QWord;
begin
  if BootInformation.MemoryRegionCount < 2 then
    Exit;

  WriteIndex := 0;
  for ReadIndex := 1 to BootInformation.MemoryRegionCount - 1 do
  begin
    Previous := @BootInformation.MemoryRegions[WriteIndex];
    Current := @BootInformation.MemoryRegions[ReadIndex];
    PreviousEnd := Previous^.PhysicalStart + Previous^.PageCount * PageSize;

    if (Current^.Kind = Previous^.Kind) and (Current^.PhysicalStart = PreviousEnd) then
      Previous^.PageCount := Previous^.PageCount + Current^.PageCount
    else
    begin
      Inc(WriteIndex);
      BootInformation.MemoryRegions[WriteIndex] := Current^;
    end;
  end;

  BootInformation.MemoryRegionCount := WriteIndex + 1;
end;

procedure TranslateMemoryMap(const Map: TFirmwareMemoryMap;
  var BootInformation: TBootInformation);
var
  DescriptorIndex: QWord;
  Descriptor: PEfiMemoryDescriptor;
  Region: PMemoryRegion;
begin
  BootInformation.MemoryRegionCount := 0;

  DescriptorIndex := 0;
  while DescriptorIndex < DescriptorCount(Map) do
  begin
    if BootInformation.MemoryRegionCount >= MaximumMemoryRegions then
      Break;

    Descriptor := GetDescriptor(Map, DescriptorIndex);
    Inc(DescriptorIndex);
    Region := @BootInformation.MemoryRegions[BootInformation.MemoryRegionCount];
    Region^.PhysicalStart := Descriptor^.PhysicalStart;
    Region^.PageCount := Descriptor^.NumberOfPages;
    Region^.Kind := TranslateMemoryType(Descriptor^.MemoryType);
    Region^.Padding := 0;
    Inc(BootInformation.MemoryRegionCount);
  end;

  SortRegionsByAddress(BootInformation);
  MergeAdjacentRegions(BootInformation);
end;

function ExitBootServicesAndRecordMemoryMap(var BootInformation: TBootInformation): TEfiStatus;
var
  Map: TFirmwareMemoryMap;
  Attempt: Integer;
begin
  Result := AllocateMemoryMapBuffer(Map);
  if EfiIsError(Result) then
    Exit;

  for Attempt := 1 to MaximumExitAttempts do
  begin
    Result := ReadMemoryMap(Map);
    if EfiIsError(Result) then
      Exit;

    { Nothing between here and ExitBootServices may allocate memory,
      otherwise the map key becomes stale. }
    TranslateMemoryMap(Map, BootInformation);

    Result := FirmwareBootServices^.ExitBootServices(LoaderImageHandle, Map.MapKey);
    if not EfiIsError(Result) then
    begin
      BootServicesHaveExited := True;
      Exit;
    end;

    { The memory map changed underneath us (firmware events can allocate),
      so read it again and retry. }
  end;
end;

end.
