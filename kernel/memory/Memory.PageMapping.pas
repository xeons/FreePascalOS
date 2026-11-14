{
  Helpers for backing runs of kernel virtual pages with physical memory.
}
unit Memory.PageMapping;

{$mode objfpc}

interface

uses
  Memory.PhysicalPages;

{ Maps PageCount freshly allocated, zeroed physical pages starting at
  StartAddress. On failure every page mapped so far is released again and
  False is returned. }
function MapNewPages(StartAddress: QWord; PageCount: QWord; Usage: TPageUsage;
  Attributes: LongWord): Boolean;

{ Unmaps PageCount pages starting at StartAddress and frees the physical
  pages behind them. Pages that are not mapped are skipped. }
procedure UnmapAndFreePages(StartAddress: QWord; PageCount: QWord);

implementation

uses
  Memory.Layout,
  Memory.Arch.PageTables;

function MapNewPages(StartAddress: QWord; PageCount: QWord; Usage: TPageUsage;
  Attributes: LongWord): Boolean;
var
  PageIndex: QWord;
  PhysicalAddress: QWord;
begin
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    PhysicalAddress := AllocateZeroedPhysicalPage(Usage);
    if PhysicalAddress = 0 then
    begin
      UnmapAndFreePages(StartAddress, PageIndex);
      Exit(False);
    end;

    if not MapKernelPage(StartAddress + PageIndex * PageSize, PhysicalAddress, Attributes) then
    begin
      FreePhysicalPage(PhysicalAddress);
      UnmapAndFreePages(StartAddress, PageIndex);
      Exit(False);
    end;

    Inc(PageIndex);
  end;
  Result := True;
end;

procedure UnmapAndFreePages(StartAddress: QWord; PageCount: QWord);
var
  PageIndex: QWord;
  PhysicalAddress: QWord;
begin
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    PhysicalAddress := UnmapKernelPage(StartAddress + PageIndex * PageSize);
    if PhysicalAddress <> 0 then
      FreePhysicalPage(PhysicalAddress);
    Inc(PageIndex);
  end;
end;

end.
