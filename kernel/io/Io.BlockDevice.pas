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
  Block devices.

  A block device is anything that stores fixed-size blocks addressed by
  number: a whole disk exposed by a storage driver, or a partition of one.
  Block devices are objects named "disk0", "disk0p1" and so on, and are
  also kept in a list so they can be enumerated.

  A storage driver creates a device object (Io.Manager) for each disk -
  one without a name, since programs reach disks through the disk
  devices (Drivers.DiskDevices) - then a block device with
  CreateBlockDevice, fills in its geometry and that device object, and
  calls RegisterBlockDevice. Reading and writing blocks sends read and
  write requests to the device object, with Offset and Length in bytes
  (always whole blocks), and waits for them to complete. A partition
  device has no device object of its own: its requests are shifted by
  the partition start and passed to the parent device.

  ReadBlocks and WriteBlocks wait, so they must be called at
  PassiveLevel.
}
unit Io.BlockDevice;

{$mode objfpc}

interface

uses
  Kernel.Events,
  Io.Manager;

const
  BlockDeviceNameLength = 32;
  BlockDeviceModelLength = 41;
  MaximumBlockDevices = 64;

type
  PBlockDevice = ^TBlockDevice;

  TBlockDevice = record
    Name: array[0..BlockDeviceNameLength - 1] of Char;
    Model: array[0..BlockDeviceModelLength - 1] of Char;
    BlockSize: LongWord;
    BlockCount: QWord;

    { Supplied by the driver for whole devices; nil for partitions. }
    StorageDevice: PDeviceObject;
    WriteProtected: Boolean;

    { Partitions only. }
    Parent: PBlockDevice;
    FirstBlockOnParent: QWord;
    PartitionNumber: LongWord;
  end;

  { One run of blocks for WriteBlocksTogether; Request and Completed
    belong to it while it runs. }
  TBlockWrite = record
    FirstBlock: QWord;
    BlockCount: LongWord;
    Buffer: Pointer;
    Request: TIoRequest;
    Completed: TEvent;
  end;
  PBlockWrite = ^TBlockWrite;

procedure InitializeBlockDevices;

{ Creates an unregistered block device object; nil if out of memory or
  the name is taken. }
function CreateBlockDevice(Name: PChar): PBlockDevice;

procedure RegisterBlockDevice(Device: PBlockDevice);

{ Creates and registers a partition of Disk. }
function CreatePartitionDevice(Disk: PBlockDevice; PartitionNumber: LongWord;
  FirstBlock, BlockCount: QWord): PBlockDevice;

{ Builds the next free whole-disk name, for example "disk2". }
procedure GenerateDiskName(Name: PChar);

function ReadBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
function WriteBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;

{ Writes Count runs of blocks of Device at once: all requests are sent
  before any is waited for, so a disk that queues commands works on them
  together. True if every one of them worked. }
function WriteBlocksTogether(Device: PBlockDevice; Writes: PBlockWrite; Count: Integer): Boolean;

{ Makes everything written so far durable: the disk writes its volatile
  cache to the medium. True also for disks that have no such cache. }
function FlushBlockDevice(Device: PBlockDevice): Boolean;

function BlockDeviceIsPartition(Device: PBlockDevice): Boolean;
function BlockDeviceIsReadOnly(Device: PBlockDevice): Boolean;
function BlockDeviceSizeInBytes(Device: PBlockDevice): QWord;

function BlockDeviceCount: Integer;
function BlockDeviceAt(Index: Integer): PBlockDevice;

procedure WriteBlockDeviceDescription(Device: PBlockDevice);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Mutex,
  Kernel.Panic,
  Objects.Manager,
  Debug.Output;

var
  BlockDeviceObjectType: TObjectType;
  DeviceListLock: TMutex;
  Devices: array[0..MaximumBlockDevices - 1] of PBlockDevice;
  DeviceCount: Integer;
  NextDiskNumber: LongWord;

procedure InitializeBlockDevices;
begin
  RegisterObjectType(BlockDeviceObjectType, 'BlockDevice', SizeOf(TBlockDevice), nil);
  InitializeMutex(DeviceListLock);
  DeviceCount := 0;
  NextDiskNumber := 0;
end;

function CreateBlockDevice(Name: PChar): PBlockDevice;
begin
  Result := PBlockDevice(CreateObject(BlockDeviceObjectType, Name));
  if Result <> nil then
    CopyText(@Result^.Name[0], Name, BlockDeviceNameLength);
end;

procedure RegisterBlockDevice(Device: PBlockDevice);
begin
  AcquireMutex(DeviceListLock);
  if DeviceCount < MaximumBlockDevices then
  begin
    Devices[DeviceCount] := Device;
    Inc(DeviceCount);
  end;
  ReleaseMutex(DeviceListLock);
end;

procedure AppendText(Destination: PChar; Capacity: PtrUInt; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  CopyText(Destination + Length, Text, Capacity - Length);
end;

procedure GenerateDiskName(Name: PChar);
var
  NumberText: TNumberText;
begin
  AcquireMutex(DeviceListLock);
  CopyText(Name, 'disk', BlockDeviceNameLength);
  AppendText(Name, BlockDeviceNameLength, FormatDecimal(NextDiskNumber, NumberText));
  Inc(NextDiskNumber);
  ReleaseMutex(DeviceListLock);
end;

function CreatePartitionDevice(Disk: PBlockDevice; PartitionNumber: LongWord;
  FirstBlock, BlockCount: QWord): PBlockDevice;
var
  Name: array[0..BlockDeviceNameLength - 1] of Char;
  NumberText: TNumberText;
begin
  CopyText(@Name[0], @Disk^.Name[0], BlockDeviceNameLength);
  AppendText(@Name[0], BlockDeviceNameLength, 'p');
  AppendText(@Name[0], BlockDeviceNameLength, FormatDecimal(PartitionNumber, NumberText));

  Result := CreateBlockDevice(@Name[0]);
  if Result = nil then
    Exit;

  ReferenceObject(Disk);
  Result^.Parent := Disk;
  Result^.FirstBlockOnParent := FirstBlock;
  Result^.BlockCount := BlockCount;
  Result^.BlockSize := Disk^.BlockSize;
  Result^.PartitionNumber := PartitionNumber;
  CopyText(@Result^.Model[0], @Disk^.Model[0], BlockDeviceModelLength);
  RegisterBlockDevice(Result);
end;

function RangeIsValid(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord): Boolean;
begin
  Result := (BlockCount > 0) and (FirstBlock < Device^.BlockCount) and
    (BlockCount <= Device^.BlockCount - FirstBlock);
end;

{ Sends one read or write request for whole blocks to the storage
  device and waits for it. }
function TransferBlocks(Device: PBlockDevice; Operation: TIoFunction; FirstBlock: QWord;
  BlockCount: LongWord; Buffer: Pointer): Boolean;
var
  Request: TIoRequest;
begin
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := Operation;
  Request.Buffer := Buffer;
  Request.Length := QWord(BlockCount) * Device^.BlockSize;
  Request.Offset := FirstBlock * Device^.BlockSize;
  Result := (CallDriverAndWait(Device^.StorageDevice, Request, False) = ErrorNone) and
    (QWord(Request.Information) = Request.Length);
end;

function ReadBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  if not RangeIsValid(Device, FirstBlock, BlockCount) then
    Exit(False);

  if Device^.Parent <> nil then
    Result := ReadBlocks(Device^.Parent, Device^.FirstBlockOnParent + FirstBlock, BlockCount, Buffer)
  else
    Result := TransferBlocks(Device, IoFunctionRead, FirstBlock, BlockCount, Buffer);
end;

function WriteBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  if (not RangeIsValid(Device, FirstBlock, BlockCount)) or BlockDeviceIsReadOnly(Device) then
    Exit(False);

  if Device^.Parent <> nil then
    Result := WriteBlocks(Device^.Parent, Device^.FirstBlockOnParent + FirstBlock, BlockCount, Buffer)
  else
    Result := TransferBlocks(Device, IoFunctionWrite, FirstBlock, BlockCount, Buffer);
end;

function WriteBlocksTogether(Device: PBlockDevice; Writes: PBlockWrite; Count: Integer): Boolean;
var
  Disk: PBlockDevice;
  Shift: QWord;
  Index: Integer;
  Write: PBlockWrite;
begin
  for Index := 0 to Count - 1 do
    if not RangeIsValid(Device, Writes[Index].FirstBlock, Writes[Index].BlockCount) then
      Exit(False);
  if BlockDeviceIsReadOnly(Device) then
    Exit(False);
  { Partitions forward to their disk, shifted. }
  Disk := Device;
  Shift := 0;
  while Disk^.Parent <> nil do
  begin
    Shift := Shift + Disk^.FirstBlockOnParent;
    Disk := Disk^.Parent;
  end;
  for Index := 0 to Count - 1 do
  begin
    Write := @Writes[Index];
    FillMemory(@Write^.Request, SizeOf(Write^.Request), 0);
    InitializeEvent(Write^.Completed, EventKindNotification, False);
    Write^.Request.Operation := IoFunctionWrite;
    Write^.Request.Buffer := Write^.Buffer;
    Write^.Request.Length := QWord(Write^.BlockCount) * Disk^.BlockSize;
    Write^.Request.Offset := (Shift + Write^.FirstBlock) * Disk^.BlockSize;
    Write^.Request.CompletionEvent := @Write^.Completed;
    CallDriver(Disk^.StorageDevice, Write^.Request);
  end;
  Result := True;
  for Index := 0 to Count - 1 do
  begin
    Write := @Writes[Index];
    WaitForEvent(Write^.Completed);
    if (Write^.Request.Status <> ErrorNone) or (QWord(Write^.Request.Information) <> Write^.Request.Length) then
      Result := False;
  end;
end;

function FlushBlockDevice(Device: PBlockDevice): Boolean;
var
  Request: TIoRequest;
  Status: LongInt;
begin
  if Device^.Parent <> nil then
    Exit(FlushBlockDevice(Device^.Parent));
  if Device^.StorageDevice = nil then
    Exit(True);
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionFlush;
  Status := CallDriverAndWait(Device^.StorageDevice, Request, False);
  Result := (Status = ErrorNone) or (Status = ErrorUnsupported);
end;

function BlockDeviceIsPartition(Device: PBlockDevice): Boolean;
begin
  Result := Device^.Parent <> nil;
end;

function BlockDeviceIsReadOnly(Device: PBlockDevice): Boolean;
begin
  if Device^.Parent <> nil then
    Result := BlockDeviceIsReadOnly(Device^.Parent)
  else
    Result := Device^.WriteProtected;
end;

function BlockDeviceSizeInBytes(Device: PBlockDevice): QWord;
begin
  Result := Device^.BlockCount * Device^.BlockSize;
end;

function BlockDeviceCount: Integer;
begin
  Result := DeviceCount;
end;

function BlockDeviceAt(Index: Integer): PBlockDevice;
begin
  if (Index < 0) or (Index >= DeviceCount) then
    Exit(nil);
  Result := Devices[Index];
end;

procedure WriteBlockDeviceDescription(Device: PBlockDevice);
begin
  DebugBeginMessage;
  DebugWriteTag('block');
  DebugWrite(@Device^.Name[0]);
  DebugWrite(': ');
  DebugWriteSize(BlockDeviceSizeInBytes(Device));
  DebugWrite(' (');
  DebugWriteDecimal(Device^.BlockCount);
  DebugWrite(' blocks of ');
  DebugWriteDecimal(Device^.BlockSize);
  DebugWrite(' bytes)');
  if Device^.Parent = nil then
  begin
    DebugWrite(' ');
    DebugWrite(@Device^.Model[0]);
  end
  else
  begin
    DebugWrite(' at block ');
    DebugWriteDecimal(Device^.FirstBlockOnParent);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
