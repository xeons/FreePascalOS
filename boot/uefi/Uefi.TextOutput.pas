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
