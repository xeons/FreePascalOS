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
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL (UEFI specification, section 12.4).
}
unit Uefi.TextOutput;

{$mode objfpc}

interface

uses
  Uefi.Base;

type
  PEfiSimpleTextOutputProtocol = ^TEfiSimpleTextOutputProtocol;

  TEfiTextReset = function(This: PEfiSimpleTextOutputProtocol;
    ExtendedVerification: Boolean): TEfiStatus;
  TEfiTextOutputString = function(This: PEfiSimpleTextOutputProtocol;
    Text: PWideChar): TEfiStatus;
  TEfiTextSetAttribute = function(This: PEfiSimpleTextOutputProtocol;
    Attribute: QWord): TEfiStatus;
  TEfiTextClearScreen = function(This: PEfiSimpleTextOutputProtocol): TEfiStatus;

  TEfiSimpleTextOutputProtocol = record
    Reset: TEfiTextReset;
    OutputString: TEfiTextOutputString;
    TestString: Pointer;
    QueryMode: Pointer;
    SetMode: Pointer;
    SetAttribute: TEfiTextSetAttribute;
    ClearScreen: TEfiTextClearScreen;
    SetCursorPosition: Pointer;
    EnableCursor: Pointer;
    Mode: Pointer;
  end;

const
  EfiTextColorLightGray = $07;
  EfiTextColorWhite = $0F;
  EfiTextColorLightRed = $0C;
  EfiTextColorLightCyan = $0B;

implementation

end.
