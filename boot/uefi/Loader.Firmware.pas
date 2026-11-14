{
  Access to the firmware tables handed to the loader at startup.

  The image handle and system table are stored once by the entry point and
  then used by the other loader units.
}
unit Loader.Firmware;

{$mode objfpc}

interface

uses
  Uefi.Base,
  Uefi.SystemTable;

var
  LoaderImageHandle: TEfiHandle;
  FirmwareSystemTable: PEfiSystemTable;
  FirmwareBootServices: PEfiBootServices;

  { Becomes True once ExitBootServices succeeds. After that point no
    firmware service other than runtime services may be used. }
  BootServicesHaveExited: Boolean;

procedure InitializeFirmwareAccess(ImageHandle: TEfiHandle; SystemTable: PEfiSystemTable);

{ Returns the vendor table registered under Guid, or nil. }
function FindConfigurationTable(const Guid: TEfiGuid): Pointer;

implementation

{$pointermath on}

procedure InitializeFirmwareAccess(ImageHandle: TEfiHandle; SystemTable: PEfiSystemTable);
begin
  LoaderImageHandle := ImageHandle;
  FirmwareSystemTable := SystemTable;
  FirmwareBootServices := SystemTable^.BootServices;
  BootServicesHaveExited := False;
end;

function FindConfigurationTable(const Guid: TEfiGuid): Pointer;
var
  TableIndex: QWord;
  Entry: PEfiConfigurationTable;
begin
  Result := nil;
  TableIndex := 0;
  while TableIndex < FirmwareSystemTable^.NumberOfTableEntries do
  begin
    Entry := FirmwareSystemTable^.ConfigurationTable + TableIndex;
    if EfiGuidsAreEqual(Entry^.VendorGuid, Guid) then
      Exit(Entry^.VendorTable);
    Inc(TableIndex);
  end;
end;

end.
