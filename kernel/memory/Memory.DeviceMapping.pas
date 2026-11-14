{
  Mapping of device registers (memory mapped I/O) into kernel space.

  Device memory must not be cached, so it is mapped separately into the
  kernel dynamic region with caching disabled rather than being used
  through the (write-back cached) physical memory window.
}
unit Memory.DeviceMapping;

{$mode objfpc}

interface

uses
  Memory.Layout;

{ Maps SizeInBytes of device memory starting at PhysicalAddress, which
  need not be page aligned. Returns nil if address space ran out. }
function MapDeviceMemory(PhysicalAddress: TPhysicalAddress; SizeInBytes: QWord): Pointer;

{ Undoes MapDeviceMemory. Pass the same size that was mapped. }
procedure UnmapDeviceMemory(Address: Pointer; SizeInBytes: QWord);

implementation

uses
  Memory.VirtualRanges,
  Memory.Arch.PageTables;

{ The physical pages belong to the device, so they are only unmapped,
  never freed. }
procedure UnmapPages(VirtualStart: QWord; PageCount: QWord);
var
  PageIndex: QWord;
  RunLength: LongWord;
  PhysicalPages: TPhysicalPageRun;
begin
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    RunLength := MaximumPagesPerRun;
    if PageCount - PageIndex < RunLength then
      RunLength := LongWord(PageCount - PageIndex);
    UnmapKernelPageRun(VirtualStart + PageIndex * PageSize, RunLength, PhysicalPages);
    PageIndex := PageIndex + RunLength;
  end;
end;

function MapDeviceMemory(PhysicalAddress: TPhysicalAddress; SizeInBytes: QWord): Pointer;
var
  FirstPage: TPhysicalAddress;
  OffsetInPage: QWord;
  PageCount: QWord;
  VirtualStart: QWord;
  PageIndex: QWord;
begin
  if SizeInBytes = 0 then
    Exit(nil);

  FirstPage := RoundDownToPage(PhysicalAddress);
  OffsetInPage := PhysicalAddress - FirstPage;
  PageCount := PagesForBytes(OffsetInPage + SizeInBytes);

  VirtualStart := AllocateVirtualRange(PageCount);
  if VirtualStart = 0 then
    Exit(nil);

  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    if not MapKernelPage(VirtualStart + PageIndex * PageSize, FirstPage + PageIndex * PageSize,
      MappingWritable or MappingUncached) then
    begin
      UnmapPages(VirtualStart, PageIndex);
      FreeVirtualRange(VirtualStart, PageCount);
      Exit(nil);
    end;
    Inc(PageIndex);
  end;

  Result := Pointer(VirtualStart + OffsetInPage);
end;

procedure UnmapDeviceMemory(Address: Pointer; SizeInBytes: QWord);
var
  VirtualStart: QWord;
  OffsetInPage: QWord;
  PageCount: QWord;
begin
  if (Address = nil) or (SizeInBytes = 0) then
    Exit;

  VirtualStart := RoundDownToPage(QWord(Address));
  OffsetInPage := QWord(Address) - VirtualStart;
  PageCount := PagesForBytes(OffsetInPage + SizeInBytes);

  UnmapPages(VirtualStart, PageCount);
  FreeVirtualRange(VirtualStart, PageCount);
end;

end.
