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
