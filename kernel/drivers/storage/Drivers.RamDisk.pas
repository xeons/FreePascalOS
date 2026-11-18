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
  The RAM disk: a disk image the loader read into memory, offered as a
  writable block device named "ramdisk0".

  A network boot brings the system volume this way (the loader fetches
  the image from the server, Loader.NetworkBoot), so a rebuilt userland
  takes effect at the next reset. Writes change only the memory: they
  are gone at the next boot. The image's pages are a MemoryRegionRamDisk
  region of the boot memory map, never given to anyone else, and the
  physical memory window already maps them.

  Its partitions (the system image has one) are scanned like any disk's,
  and the system volume is preferably the RAM disk's (Processes.Paths).
}
unit Drivers.RamDisk;

{$mode objfpc}

interface

uses
  Boot.Information,
  Io.BlockDevice;

const
  RamDiskName = 'ramdisk0';

{ Notes where the loader put the image (in phase 0). }
procedure RecordBootRamDisk(const BootInformation: TBootInformation);

{ Registers the block device if there is an image; True if so. }
function InitializeRamDisk: Boolean;

{ True for the RAM disk and its partitions. }
function IsRamDiskDevice(Device: PBlockDevice): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Io.Manager,
  Debug.Output;

const
  SectorSize = 512;

var
  ImagePhysicalBase: QWord;
  ImageSizeInBytes: QWord;
  ImageContents: PByte;
  RamDiskDevice: PBlockDevice;

procedure RecordBootRamDisk(const BootInformation: TBootInformation);
begin
  ImagePhysicalBase := BootInformation.RamDiskPhysicalBase;
  ImageSizeInBytes := BootInformation.RamDiskSizeInBytes;
end;

function RequestIsValid(var Request: TIoRequest): Boolean;
var
  SectorCount: QWord;
begin
  if Request.Operation = IoFunctionFlush then
    Exit(Request.Length = 0);
  SectorCount := ImageSizeInBytes div SectorSize;
  Result := (Request.Length > 0) and (Request.Length mod SectorSize = 0) and
    (Request.Offset mod SectorSize = 0) and (Request.Offset div SectorSize < SectorCount) and
    (Request.Length div SectorSize <= SectorCount - Request.Offset div SectorSize);
end;

function TransferRamDisk(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  if not RequestIsValid(Request) then
    Exit(ErrorInvalidArgument);
  case Request.Operation of
    IoFunctionRead:
      CopyMemory(Request.Buffer, ImageContents + Request.Offset, Request.Length);
    IoFunctionWrite:
      CopyMemory(ImageContents + Request.Offset, Request.Buffer, Request.Length);
  end;
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

function CreateRamDiskDevice: PDeviceObject;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferRamDisk;
  Dispatch[IoFunctionWrite] := @TransferRamDisk;
  Dispatch[IoFunctionFlush] := @TransferRamDisk;
  Driver := CreateDriver('ramdisk', Dispatch);
  if Driver = nil then
    Exit(nil);
  Result := CreateDevice(Driver, nil, DeviceKindBlock, 0, 0);
end;

function InitializeRamDisk: Boolean;
var
  Device: PDeviceObject;
begin
  Result := False;
  if (ImagePhysicalBase = 0) or (ImageSizeInBytes < SectorSize) then
    Exit;
  ImageContents := PByte(PhysicalToVirtual(ImagePhysicalBase));
  Device := CreateRamDiskDevice;
  if Device = nil then
    Exit;
  Device^.SizeInBytes := ImageSizeInBytes - ImageSizeInBytes mod SectorSize;

  RamDiskDevice := CreateBlockDevice(RamDiskName);
  if RamDiskDevice = nil then
    Exit;
  CopyText(@RamDiskDevice^.Model[0], 'RAM disk (loaded at boot)', BlockDeviceModelLength);
  RamDiskDevice^.BlockSize := SectorSize;
  RamDiskDevice^.BlockCount := ImageSizeInBytes div SectorSize;
  RamDiskDevice^.StorageDevice := Device;
  RegisterBlockDevice(RamDiskDevice);
  WriteBlockDeviceDescription(RamDiskDevice);

  DebugBeginMessage;
  DebugWriteTag('ramdisk');
  DebugWrite(RamDiskName);
  DebugWrite(': ');
  DebugWriteDecimal(ImageSizeInBytes div 1024);
  DebugWrite(' KiB image from the loader at physical ');
  DebugWriteAddress(ImagePhysicalBase);
  DebugWriteLine(', writable, lost at reset');
  DebugEndMessage;
  Result := True;
end;

function IsRamDiskDevice(Device: PBlockDevice): Boolean;
begin
  Result := (RamDiskDevice <> nil) and (Device <> nil) and
    ((Device = RamDiskDevice) or (Device^.Parent = RamDiskDevice));
end;

end.
