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
  UEFI system table and boot services table (UEFI specification, chapter 4).

  Boot services the loader does not call are declared as plain pointers so
  that the record layout stays correct without describing every signature.
}
unit Uefi.SystemTable;

{$mode objfpc}

interface

uses
  Uefi.Base,
  Uefi.TextOutput;

type
  TEfiAllocatePages = function(AllocationType: LongWord; MemoryType: LongWord;
    PageCount: QWord; Memory: PEfiPhysicalAddress): TEfiStatus;
  TEfiFreePages = function(Memory: TEfiPhysicalAddress; PageCount: QWord): TEfiStatus;
  TEfiGetMemoryMap = function(MemoryMapSize: PQWord; MemoryMap: PEfiMemoryDescriptor;
    MapKey: PQWord; DescriptorSize: PQWord; DescriptorVersion: PLongWord): TEfiStatus;
  TEfiAllocatePool = function(PoolType: LongWord; Size: QWord; Buffer: Pointer): TEfiStatus;
  TEfiFreePool = function(Buffer: Pointer): TEfiStatus;
  TEfiHandleProtocol = function(Handle: TEfiHandle; Protocol: PEfiGuid;
    ProtocolInterface: Pointer): TEfiStatus;
  TEfiExitBootServices = function(ImageHandle: TEfiHandle; MapKey: QWord): TEfiStatus;
  TEfiStall = function(Microseconds: QWord): TEfiStatus;
  TEfiSetWatchdogTimer = function(Timeout: QWord; WatchdogCode: QWord;
    DataSize: QWord; WatchdogData: PWideChar): TEfiStatus;
  TEfiLocateProtocol = function(Protocol: PEfiGuid; Registration: Pointer;
    ProtocolInterface: Pointer): TEfiStatus;
  TEfiLocateHandleBuffer = function(SearchType: LongWord; Protocol: PEfiGuid;
    SearchKey: Pointer; HandleCount: PQWord; Buffer: Pointer): TEfiStatus;
  TEfiConnectController = function(ControllerHandle: TEfiHandle; DriverImageHandle: PEfiHandle;
    RemainingDevicePath: Pointer; Recursive: Byte): TEfiStatus;
  TEfiCreateEvent = function(EventType: LongWord; NotifyPriority: QWord; NotifyFunction: Pointer;
    NotifyContext: Pointer; Event: Pointer): TEfiStatus;
  TEfiEventFunction = function(Event: TEfiEvent): TEfiStatus;

  TEfiBootServices = record
    Header: TEfiTableHeader;

    { Task priority services }
    RaiseTpl: Pointer;
    RestoreTpl: Pointer;

    { Memory services }
    AllocatePages: TEfiAllocatePages;
    FreePages: TEfiFreePages;
    GetMemoryMap: TEfiGetMemoryMap;
    AllocatePool: TEfiAllocatePool;
    FreePool: TEfiFreePool;

    { Event and timer services }
    CreateEvent: TEfiCreateEvent;
    SetTimer: Pointer;
    WaitForEvent: Pointer;
    SignalEvent: Pointer;
    CloseEvent: TEfiEventFunction;
    CheckEvent: TEfiEventFunction;

    { Protocol handler services }
    InstallProtocolInterface: Pointer;
    ReinstallProtocolInterface: Pointer;
    UninstallProtocolInterface: Pointer;
    HandleProtocol: TEfiHandleProtocol;
    Reserved: Pointer;
    RegisterProtocolNotify: Pointer;
    LocateHandle: Pointer;
    LocateDevicePath: Pointer;
    InstallConfigurationTable: Pointer;

    { Image services }
    LoadImage: Pointer;
    StartImage: Pointer;
    ExitImage: Pointer;
    UnloadImage: Pointer;
    ExitBootServices: TEfiExitBootServices;

    { Miscellaneous services }
    GetNextMonotonicCount: Pointer;
    Stall: TEfiStall;
    SetWatchdogTimer: TEfiSetWatchdogTimer;

    { Driver support services }
    ConnectController: TEfiConnectController;
    DisconnectController: Pointer;

    { Open and close protocol services }
    OpenProtocol: Pointer;
    CloseProtocol: Pointer;
    OpenProtocolInformation: Pointer;

    { Library services }
    ProtocolsPerHandle: Pointer;
    LocateHandleBuffer: TEfiLocateHandleBuffer;
    LocateProtocol: TEfiLocateProtocol;
    InstallMultipleProtocolInterfaces: Pointer;
    UninstallMultipleProtocolInterfaces: Pointer;

    { CRC services }
    CalculateCrc32: Pointer;

    { Miscellaneous services }
    CopyMem: Pointer;
    SetMem: Pointer;
    CreateEventEx: Pointer;
  end;
  PEfiBootServices = ^TEfiBootServices;

  TEfiConfigurationTable = record
    VendorGuid: TEfiGuid;
    VendorTable: Pointer;
  end;
  PEfiConfigurationTable = ^TEfiConfigurationTable;

  TEfiSystemTable = record
    Header: TEfiTableHeader;
    FirmwareVendor: PWideChar;
    FirmwareRevision: LongWord;
    ConsoleInHandle: TEfiHandle;
    ConsoleIn: Pointer;
    ConsoleOutHandle: TEfiHandle;
    ConsoleOut: PEfiSimpleTextOutputProtocol;
    StandardErrorHandle: TEfiHandle;
    StandardError: PEfiSimpleTextOutputProtocol;
    RuntimeServices: Pointer;
    BootServices: PEfiBootServices;
    NumberOfTableEntries: QWord;
    ConfigurationTable: PEfiConfigurationTable;
  end;
  PEfiSystemTable = ^TEfiSystemTable;

const
  { EFI_LOCATE_SEARCH_TYPE }
  EfiLocateAllHandles = 0;
  EfiLocateByProtocol = 2;

  Acpi20TableGuid: TEfiGuid = (
    Data1: $8868E871; Data2: $E4F1; Data3: $11D3;
    Data4: ($BC, $22, $00, $80, $C7, $3C, $88, $81));

  Acpi10TableGuid: TEfiGuid = (
    Data1: $EB9D2D30; Data2: $2D88; Data3: $11D3;
    Data4: ($9A, $16, $00, $90, $27, $3F, $C1, $4D));

implementation

end.
