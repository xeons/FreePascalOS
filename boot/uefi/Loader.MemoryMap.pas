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

function FindHighestMemoryAddress: QWord;
var
  Map: TFirmwareMemoryMap;
  DescriptorIndex: QWord;
  Descriptor: PEfiMemoryDescriptor;
  RangeEnd: QWord;
begin
  Result := 0;
  if EfiIsError(AllocateMemoryMapBuffer(Map)) then
    Exit;

  if not EfiIsError(ReadMemoryMap(Map)) then
  begin
    DescriptorIndex := 0;
    while DescriptorIndex < DescriptorCount(Map) do
    begin
      Descriptor := GetDescriptor(Map, DescriptorIndex);
      Inc(DescriptorIndex);
      if not IsRealMemory(Descriptor^.MemoryType) then
        Continue;
      RangeEnd := Descriptor^.PhysicalStart + Descriptor^.NumberOfPages * LoaderPageSize;
      if RangeEnd > Result then
        Result := RangeEnd;
    end;
  end;

  FreeTemporaryBuffer(Map.Buffer);
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
