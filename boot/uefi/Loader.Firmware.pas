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
