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
  Fundamental UEFI types and constants (UEFI specification, section 2.3).

  The loader is compiled for the Win64 target, whose native calling
  convention is the Microsoft x64 convention required by UEFI, so firmware
  function pointers can be declared as ordinary procedural types.
}
unit Uefi.Base;

{$mode objfpc}

interface

type
  TEfiStatus = QWord;
  TEfiHandle = Pointer;
  PEfiHandle = ^TEfiHandle;
  TEfiEvent = Pointer;
  TEfiPhysicalAddress = QWord;
  PEfiPhysicalAddress = ^TEfiPhysicalAddress;
  TEfiVirtualAddress = QWord;

  TEfiGuid = record
    Data1: LongWord;
    Data2: Word;
    Data3: Word;
    Data4: array[0..7] of Byte;
  end;
  PEfiGuid = ^TEfiGuid;

  TEfiTableHeader = record
    Signature: QWord;
    Revision: LongWord;
    HeaderSize: LongWord;
    Crc32: LongWord;
    Reserved: LongWord;
  end;

  TEfiMemoryDescriptor = record
    MemoryType: LongWord;
    Padding: LongWord;
    PhysicalStart: TEfiPhysicalAddress;
    VirtualStart: TEfiVirtualAddress;
    NumberOfPages: QWord;
    Attribute: QWord;
  end;
  PEfiMemoryDescriptor = ^TEfiMemoryDescriptor;

const
  EfiErrorBit = QWord($8000000000000000);

  EfiSuccess = TEfiStatus(0);
  EfiLoadError = EfiErrorBit or 1;
  EfiInvalidParameter = EfiErrorBit or 2;
  EfiUnsupported = EfiErrorBit or 3;
  EfiBufferTooSmall = EfiErrorBit or 5;
  EfiOutOfResources = EfiErrorBit or 9;
  EfiNotReady = EfiErrorBit or 6;
  EfiDeviceError = EfiErrorBit or 7;
  EfiNotFound = EfiErrorBit or 14;
  EfiAccessDenied = EfiErrorBit or 15;
  EfiNoResponse = EfiErrorBit or 16;
  EfiNoMapping = EfiErrorBit or 17;
  EfiTimeout = EfiErrorBit or 18;
  EfiNotStarted = EfiErrorBit or 19;
  EfiAlreadyStarted = EfiErrorBit or 20;
  EfiAborted = EfiErrorBit or 21;
  EfiIcmpError = EfiErrorBit or 22;
  EfiTftpError = EfiErrorBit or 23;
  EfiHttpError = EfiErrorBit or 35;

  { EFI_ALLOCATE_TYPE }
  EfiAllocateAnyPages = 0;
  EfiAllocateMaxAddress = 1;
  EfiAllocateAddress = 2;

  { EFI_MEMORY_TYPE }
  EfiReservedMemoryType = 0;
  EfiLoaderCode = 1;
  EfiLoaderData = 2;
  EfiBootServicesCode = 3;
  EfiBootServicesData = 4;
  EfiRuntimeServicesCode = 5;
  EfiRuntimeServicesData = 6;
  EfiConventionalMemory = 7;
  EfiUnusableMemory = 8;
  EfiAcpiReclaimMemory = 9;
  EfiAcpiMemoryNvs = 10;
  EfiMemoryMappedIo = 11;
  EfiMemoryMappedIoPortSpace = 12;
  EfiPalCode = 13;
  EfiPersistentMemory = 14;

  { Memory types 0x80000000 and above are reserved for operating system
    loaders. The loader tags its own allocations with these so the memory
    map handed to the kernel says exactly what each region holds. }
  LoaderMemoryTypeKernelImage = LongWord($80000001);
  LoaderMemoryTypeBootData = LongWord($80000002);
  LoaderMemoryTypePageTables = LongWord($80000003);
  { The RAM disk image the loader read (a netbooted system volume). }
  LoaderMemoryTypeRamDisk = LongWord($80000004);

function EfiIsError(Status: TEfiStatus): Boolean;
function EfiGuidsAreEqual(const First, Second: TEfiGuid): Boolean;

implementation

function EfiIsError(Status: TEfiStatus): Boolean;
begin
  Result := (Status and EfiErrorBit) <> 0;
end;

function EfiGuidsAreEqual(const First, Second: TEfiGuid): Boolean;
var
  ByteIndex: Integer;
begin
  Result := False;
  if First.Data1 <> Second.Data1 then
    Exit;
  if First.Data2 <> Second.Data2 then
    Exit;
  if First.Data3 <> Second.Data3 then
    Exit;
  for ByteIndex := 0 to 7 do
  begin
    if First.Data4[ByteIndex] <> Second.Data4[ByteIndex] then
      Exit;
  end;
  Result := True;
end;

end.
