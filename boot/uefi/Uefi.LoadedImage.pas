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
  EFI_LOADED_IMAGE_PROTOCOL (UEFI specification, section 9.1).

  The loader uses it to find the device it was started from, which is
  where the kernel image lives as well.
}
unit Uefi.LoadedImage;

{$mode objfpc}

interface

uses
  Uefi.Base;

type
  TEfiLoadedImageProtocol = record
    Revision: LongWord;
    ParentHandle: TEfiHandle;
    SystemTable: Pointer;
    DeviceHandle: TEfiHandle;
    FilePath: Pointer;
    Reserved: Pointer;
    LoadOptionsSize: LongWord;
    LoadOptions: Pointer;
    ImageBase: Pointer;
    ImageSize: QWord;
    ImageCodeType: LongWord;
    ImageDataType: LongWord;
    Unload: Pointer;
  end;
  PEfiLoadedImageProtocol = ^TEfiLoadedImageProtocol;

const
  LoadedImageProtocolGuid: TEfiGuid = (
    Data1: $5B1B31A1; Data2: $9562; Data3: $11D2;
    Data4: ($8E, $3F, $00, $A0, $C9, $69, $72, $3B));

implementation

end.
