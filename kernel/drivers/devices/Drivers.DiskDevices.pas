{
  Disks and partitions as devices: /dev/disk0, /dev/disk0p1, ...

  Every block device (Io.BlockDevice) gets a block device object of the
  same name, readable and writable by root only. Reads and writes may
  start anywhere and have any length; they go through a buffer of one
  block, so they need not be aligned. Writing to a device that holds a
  mounted volume, or to a disk with a mounted partition, is refused: the
  file system would not know about the change.

  Blocks are read from the device itself, past the block cache. That is
  safe because the cache writes through.
}
unit Drivers.DiskDevices;

{$mode objfpc}
{$pointermath on}

interface

{ Creates a device for every block device there is (after partitions
  were scanned). }
procedure InitializeDiskDevices;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Io.Manager,
  Io.BlockDevice,
  FileSystem.Types,
  FileSystem.Volumes;

function BlockDeviceOf(Device: PDeviceObject): PBlockDevice;
begin
  Result := PBlockDevice(Device^.Extension);
end;

{ The part of [Offset, Offset + Length) inside the device. }
function ClampLength(Device: PDeviceObject; Offset, Length: QWord): QWord;
begin
  if Offset >= Device^.SizeInBytes then
    Exit(0);
  Result := Length;
  if Result > Device^.SizeInBytes - Offset then
    Result := Device^.SizeInBytes - Offset;
end;

function ReadDiskDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Disk: PBlockDevice;
  Block: PByte;
  Total: QWord;
  Remaining: QWord;
  Position: QWord;
  WithinBlock: QWord;
  Piece: QWord;
begin
  Disk := BlockDeviceOf(Device);
  Remaining := ClampLength(Device, Request.Offset, Request.Length);
  Block := PByte(AllocateKernelMemory(Disk^.BlockSize));
  if Block = nil then
    Exit(ErrorOutOfMemory);
  Result := ErrorNone;
  Total := 0;
  Position := Request.Offset;
  while Remaining > 0 do
  begin
    if not ReadBlocks(Disk, Position div Disk^.BlockSize, 1, Block) then
    begin
      if Total = 0 then
        Result := ErrorIo;
      Break;
    end;
    WithinBlock := Position mod Disk^.BlockSize;
    Piece := Disk^.BlockSize - WithinBlock;
    if Piece > Remaining then
      Piece := Remaining;
    CopyMemory(PByte(Request.Buffer) + Total, Block + WithinBlock, Piece);
    Total := Total + Piece;
    Position := Position + Piece;
    Remaining := Remaining - Piece;
  end;
  FreeKernelMemory(Block);
  Request.Information := Int64(Total);
end;

{ True if a mounted volume lives on Disk, or on a partition of it. }
function DeviceIsInUse(Disk: PBlockDevice): Boolean;
var
  Index: Integer;
  Volume: PVolume;
begin
  for Index := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(Index);
    if (Volume^.Device = Disk) or (Volume^.Device^.Parent = Disk) then
      Exit(True);
  end;
  Result := False;
end;

function WriteDiskDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Disk: PBlockDevice;
  Block: PByte;
  Total: QWord;
  Remaining: QWord;
  Position: QWord;
  BlockNumber: QWord;
  WithinBlock: QWord;
  Piece: QWord;
begin
  Disk := BlockDeviceOf(Device);
  if BlockDeviceIsReadOnly(Disk) then
    Exit(ErrorReadOnly);
  if DeviceIsInUse(Disk) then
    Exit(ErrorBusy);
  Remaining := ClampLength(Device, Request.Offset, Request.Length);
  if (Remaining = 0) and (Request.Length > 0) then
    Exit(ErrorNoSpace);
  Block := PByte(AllocateKernelMemory(Disk^.BlockSize));
  if Block = nil then
    Exit(ErrorOutOfMemory);
  Result := ErrorNone;
  Total := 0;
  Position := Request.Offset;
  while Remaining > 0 do
  begin
    BlockNumber := Position div Disk^.BlockSize;
    WithinBlock := Position mod Disk^.BlockSize;
    Piece := Disk^.BlockSize - WithinBlock;
    if Piece > Remaining then
      Piece := Remaining;
    { A partial block keeps the rest of its old contents. }
    if (Piece < Disk^.BlockSize) and not ReadBlocks(Disk, BlockNumber, 1, Block) then
      Break;
    CopyMemory(Block + WithinBlock, PByte(Request.Buffer) + Total, Piece);
    if not WriteBlocks(Disk, BlockNumber, 1, Block) then
      Break;
    Total := Total + Piece;
    Position := Position + Piece;
    Remaining := Remaining - Piece;
  end;
  FreeKernelMemory(Block);
  if (Total = 0) and (Remaining > 0) then
    Result := ErrorIo;
  Request.Information := Int64(Total);
end;

procedure InitializeDiskDevices;
const
  OwnerReadWrite = $180; { rw------- }
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
  Index: Integer;
  Disk: PBlockDevice;
  Device: PDeviceObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadDiskDevice;
  Dispatch[IoFunctionWrite] := @WriteDiskDevice;
  Driver := CreateDriver('disk', Dispatch);
  for Index := 0 to BlockDeviceCount - 1 do
  begin
    Disk := BlockDeviceAt(Index);
    Device := CreateDevice(Driver, @Disk^.Name[0], DeviceKindBlock, OwnerReadWrite, 0);
    if Device = nil then
      Continue;
    Device^.Extension := Disk;
    Device^.SizeInBytes := BlockDeviceSizeInBytes(Disk);
  end;
end;

end.
