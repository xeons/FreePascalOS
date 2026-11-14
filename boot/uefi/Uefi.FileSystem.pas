{
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL and EFI_FILE_PROTOCOL
  (UEFI specification, sections 13.4 and 13.5).
}
unit Uefi.FileSystem;

{$mode objfpc}

interface

uses
  Uefi.Base;

type
  PEfiFileProtocol = ^TEfiFileProtocol;
  PPEfiFileProtocol = ^PEfiFileProtocol;

  TEfiFileOpen = function(This: PEfiFileProtocol; NewHandle: PPEfiFileProtocol;
    FileName: PWideChar; OpenMode: QWord; Attributes: QWord): TEfiStatus;
  TEfiFileClose = function(This: PEfiFileProtocol): TEfiStatus;
  TEfiFileRead = function(This: PEfiFileProtocol; BufferSize: PQWord;
    Buffer: Pointer): TEfiStatus;
  TEfiFileSetPosition = function(This: PEfiFileProtocol; Position: QWord): TEfiStatus;
  TEfiFileGetInfo = function(This: PEfiFileProtocol; InformationType: PEfiGuid;
    BufferSize: PQWord; Buffer: Pointer): TEfiStatus;

  TEfiFileProtocol = record
    Revision: QWord;
    Open: TEfiFileOpen;
    Close: TEfiFileClose;
    Delete: Pointer;
    Read: TEfiFileRead;
    Write: Pointer;
    GetPosition: Pointer;
    SetPosition: TEfiFileSetPosition;
    GetInfo: TEfiFileGetInfo;
    SetInfo: Pointer;
    Flush: Pointer;
  end;

  PEfiSimpleFileSystemProtocol = ^TEfiSimpleFileSystemProtocol;

  TEfiOpenVolume = function(This: PEfiSimpleFileSystemProtocol;
    Root: PPEfiFileProtocol): TEfiStatus;

  TEfiSimpleFileSystemProtocol = record
    Revision: QWord;
    OpenVolume: TEfiOpenVolume;
  end;

  TEfiTime = record
    Year: Word;
    Month: Byte;
    Day: Byte;
    Hour: Byte;
    Minute: Byte;
    Second: Byte;
    Pad1: Byte;
    Nanosecond: LongWord;
    TimeZone: SmallInt;
    Daylight: Byte;
    Pad2: Byte;
  end;

  { EFI_FILE_INFO is followed by a variable length file name. }
  TEfiFileInformation = record
    Size: QWord;
    FileSize: QWord;
    PhysicalSize: QWord;
    CreateTime: TEfiTime;
    LastAccessTime: TEfiTime;
    ModificationTime: TEfiTime;
    Attribute: QWord;
  end;
  PEfiFileInformation = ^TEfiFileInformation;

const
  EfiFileModeRead = QWord($0000000000000001);

  SimpleFileSystemProtocolGuid: TEfiGuid = (
    Data1: $964E5B22; Data2: $6459; Data3: $11D2;
    Data4: ($8E, $39, $00, $A0, $C9, $69, $72, $3B));

  FileInformationGuid: TEfiGuid = (
    Data1: $09576E92; Data2: $6D3F; Data3: $11D2;
    Data4: ($8E, $39, $00, $A0, $C9, $69, $72, $3B));

implementation

end.
