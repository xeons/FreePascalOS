{
  EFI_GRAPHICS_OUTPUT_PROTOCOL (UEFI specification, section 12.9).
}
unit Uefi.GraphicsOutput;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  EfiPixelRedGreenBlueReserved8BitPerColor = 0;
  EfiPixelBlueGreenRedReserved8BitPerColor = 1;
  EfiPixelBitMask = 2;
  EfiPixelBltOnly = 3;

type
  TEfiPixelBitmask = record
    RedMask: LongWord;
    GreenMask: LongWord;
    BlueMask: LongWord;
    ReservedMask: LongWord;
  end;

  TEfiGraphicsOutputModeInformation = record
    Version: LongWord;
    HorizontalResolution: LongWord;
    VerticalResolution: LongWord;
    PixelFormat: LongWord;
    PixelInformation: TEfiPixelBitmask;
    PixelsPerScanLine: LongWord;
  end;
  PEfiGraphicsOutputModeInformation = ^TEfiGraphicsOutputModeInformation;

  TEfiGraphicsOutputProtocolMode = record
    MaxMode: LongWord;
    Mode: LongWord;
    Information: PEfiGraphicsOutputModeInformation;
    SizeOfInformation: QWord;
    FramebufferBase: TEfiPhysicalAddress;
    FramebufferSize: QWord;
  end;
  PEfiGraphicsOutputProtocolMode = ^TEfiGraphicsOutputProtocolMode;

  TEfiGraphicsOutputProtocol = record
    QueryMode: Pointer;
    SetMode: Pointer;
    Blt: Pointer;
    Mode: PEfiGraphicsOutputProtocolMode;
  end;
  PEfiGraphicsOutputProtocol = ^TEfiGraphicsOutputProtocol;

const
  GraphicsOutputProtocolGuid: TEfiGuid = (
    Data1: $9042A9DE; Data2: $23DC; Data3: $4A38;
    Data4: ($96, $FB, $7A, $DE, $D0, $80, $51, $6A));

implementation

end.
