{
  Block devices.

  A block device is anything that stores fixed-size blocks addressed by
  number: a whole disk exposed by a storage driver, or a partition of one.
  Block devices are objects named "disk0", "disk0p1" and so on, and are
  also kept in a list so they can be enumerated.

  A storage driver creates a device with CreateBlockDevice, fills in its
  geometry and read/write routines, and calls RegisterBlockDevice. A
  partition device has no routines of its own: its requests are shifted
  by the partition start and passed to the parent device.

  ReadBlocks and WriteBlocks may block, so they must be called at
  PassiveLevel.
}
unit Io.BlockDevice;

{$mode objfpc}

interface

const
  BlockDeviceNameLength = 32;
  BlockDeviceModelLength = 41;
  MaximumBlockDevices = 64;

type
  PBlockDevice = ^TBlockDevice;

  TBlockTransfer = function(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
    Buffer: Pointer): Boolean;

  TBlockDevice = record
    Name: array[0..BlockDeviceNameLength - 1] of Char;
    Model: array[0..BlockDeviceModelLength - 1] of Char;
    BlockSize: LongWord;
    BlockCount: QWord;

    { Supplied by the driver for whole devices; nil for partitions. A nil
      WriteBlocks routine makes the device read-only. }
    ReadRoutine: TBlockTransfer;
    WriteRoutine: TBlockTransfer;
    DriverContext: Pointer;

    { Partitions only. }
    Parent: PBlockDevice;
    FirstBlockOnParent: QWord;
    PartitionNumber: LongWord;
  end;

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

function BlockDeviceIsPartition(Device: PBlockDevice): Boolean;
function BlockDeviceIsReadOnly(Device: PBlockDevice): Boolean;
function BlockDeviceSizeInBytes(Device: PBlockDevice): QWord;

function BlockDeviceCount: Integer;
function BlockDeviceAt(Index: Integer): PBlockDevice;

procedure WriteBlockDeviceDescription(Device: PBlockDevice);

implementation

uses
  Runtime.Text,
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

function ReadBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  if not RangeIsValid(Device, FirstBlock, BlockCount) then
    Exit(False);

  if Device^.Parent <> nil then
    Result := ReadBlocks(Device^.Parent, Device^.FirstBlockOnParent + FirstBlock, BlockCount, Buffer)
  else
    Result := Device^.ReadRoutine(Device, FirstBlock, BlockCount, Buffer);
end;

function WriteBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  if (not RangeIsValid(Device, FirstBlock, BlockCount)) or BlockDeviceIsReadOnly(Device) then
    Exit(False);

  if Device^.Parent <> nil then
    Result := WriteBlocks(Device^.Parent, Device^.FirstBlockOnParent + FirstBlock, BlockCount, Buffer)
  else
    Result := Device^.WriteRoutine(Device, FirstBlock, BlockCount, Buffer);
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
    Result := not Assigned(Device^.WriteRoutine);
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
