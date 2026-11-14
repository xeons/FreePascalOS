{
  Physical memory allocation for the loader, built on firmware services.

  While boot services are active the firmware identity maps memory, so a
  physical address returned here can be used directly as a pointer.
}
unit Loader.Memory;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  LoaderPageSize = 4096;

{ Allocates zeroed, page aligned physical memory tagged with MemoryType.
  Returns zero when the firmware cannot satisfy the request. }
function AllocateLoaderPages(PageCount: QWord; MemoryType: LongWord): TEfiPhysicalAddress;

{ Allocates temporary memory that the kernel may reuse after boot. }
function AllocateTemporaryBuffer(ByteCount: QWord): Pointer;
procedure FreeTemporaryBuffer(Buffer: Pointer);

function PagesNeededFor(ByteCount: QWord): QWord;

implementation

uses
  Runtime.Memory,
  Loader.Firmware;

function PagesNeededFor(ByteCount: QWord): QWord;
begin
  Result := (ByteCount + LoaderPageSize - 1) div LoaderPageSize;
end;

function AllocateLoaderPages(PageCount: QWord; MemoryType: LongWord): TEfiPhysicalAddress;
var
  Status: TEfiStatus;
  PhysicalAddress: TEfiPhysicalAddress;
begin
  PhysicalAddress := 0;
  Status := FirmwareBootServices^.AllocatePages(EfiAllocateAnyPages, MemoryType,
    PageCount, @PhysicalAddress);
  if EfiIsError(Status) then
    Exit(0);

  ZeroMemory(Pointer(PhysicalAddress), PageCount * LoaderPageSize);
  Result := PhysicalAddress;
end;

function AllocateTemporaryBuffer(ByteCount: QWord): Pointer;
var
  Status: TEfiStatus;
  Buffer: Pointer;
begin
  Buffer := nil;
  Status := FirmwareBootServices^.AllocatePool(EfiLoaderData, ByteCount, @Buffer);
  if EfiIsError(Status) then
    Exit(nil);
  Result := Buffer;
end;

procedure FreeTemporaryBuffer(Buffer: Pointer);
begin
  if Buffer <> nil then
    FirmwareBootServices^.FreePool(Buffer);
end;

end.
