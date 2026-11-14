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
