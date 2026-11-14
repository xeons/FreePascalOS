{
  File system drivers and mounted volumes.

  Drivers register themselves here. At startup MountAllVolumes offers
  every block device to each driver in turn; the first one whose Probe
  accepts the device mounts it. A whole disk is only considered when it
  has no partitions (a "superfloppy" without a partition table).

  Each volume appears in the file namespace as a directory under the
  root, named after its block device: /disk1p2, /disk0p1 and so on.
}
unit FileSystem.Volumes;

{$mode objfpc}

interface

uses
  Io.BlockDevice,
  FileSystem.Types;

const
  MaximumFileSystemDrivers = 8;
  MaximumVolumes = 32;

procedure InitializeFileSystems;
procedure RegisterFileSystemDriver(Driver: PFileSystemDriver);

procedure MountAllVolumes;

{ Tries every driver on Device. Returns the new volume or nil. }
function MountVolume(Device: PBlockDevice): PVolume;

function VolumeCount: Integer;
function VolumeAt(Index: Integer): PVolume;
function FindVolumeByName(Name: PChar): PVolume;

implementation

uses
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Mutex,
  Io.BlockCache,
  FileSystem.Fat,
  FileSystem.ExFat,
  FileSystem.Ext,
  Debug.Output;

var
  Drivers: array[0..MaximumFileSystemDrivers - 1] of PFileSystemDriver;
  DriverCount: Integer;
  Volumes: array[0..MaximumVolumes - 1] of PVolume;
  MountedVolumeCount: Integer;
  VolumeListLock: TMutex;

procedure RegisterFileSystemDriver(Driver: PFileSystemDriver);
begin
  if DriverCount < MaximumFileSystemDrivers then
  begin
    Drivers[DriverCount] := Driver;
    Inc(DriverCount);
  end;
end;

procedure InitializeFileSystems;
begin
  DriverCount := 0;
  MountedVolumeCount := 0;
  InitializeMutex(VolumeListLock);
  InitializeBlockCache;

  RegisterFileSystemDriver(FatFileSystemDriver);
  RegisterFileSystemDriver(ExFatFileSystemDriver);
  RegisterFileSystemDriver(ExtFileSystemDriver);
end;

procedure ReportMountedVolume(Volume: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(': ');
  DebugWrite(@Volume^.TypeName[0]);
  if Volume^.VolumeLabel[0] <> #0 then
  begin
    DebugWrite(' "');
    DebugWrite(@Volume^.VolumeLabel[0]);
    DebugWrite('"');
  end;
  DebugWrite(', ');
  DebugWriteSize(Volume^.TotalBytes);
  DebugWrite(', mounted read-only at /');
  DebugWriteLine(@Volume^.Name[0]);
  DebugEndMessage;
end;

procedure ReportMountFailure(Device: PBlockDevice; Driver: PFileSystemDriver;
  Status: TFileSystemStatus);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Device^.Name[0]);
  DebugWrite(': looks like ');
  DebugWrite(Driver^.Name);
  DebugWrite(' but could not be mounted (');
  DebugWrite(FileSystemStatusText(Status));
  DebugWriteLine(')');
  DebugEndMessage;
end;

function MountVolume(Device: PBlockDevice): PVolume;
var
  DriverIndex: Integer;
  Driver: PFileSystemDriver;
  Volume: PVolume;
  Status: TFileSystemStatus;
begin
  Result := nil;
  for DriverIndex := 0 to DriverCount - 1 do
  begin
    Driver := Drivers[DriverIndex];
    if not Driver^.Probe(Device) then
      Continue;

    Volume := PVolume(AllocateZeroedKernelMemory(SizeOf(TVolume)));
    if Volume = nil then
      Exit;
    Volume^.Device := Device;
    Volume^.Driver := Driver;
    Volume^.IsReadOnly := True;
    CopyText(@Volume^.Name[0], @Device^.Name[0], VolumeNameLength);

    Status := Driver^.Mount(Volume);
    if Status <> StatusSuccess then
    begin
      ReportMountFailure(Device, Driver, Status);
      FreeKernelMemory(Volume);
      Continue;
    end;

    AcquireMutex(VolumeListLock);
    if MountedVolumeCount < MaximumVolumes then
    begin
      Volumes[MountedVolumeCount] := Volume;
      Inc(MountedVolumeCount);
    end;
    ReleaseMutex(VolumeListLock);

    ReportMountedVolume(Volume);
    Exit(Volume);
  end;
end;

function DiskHasPartitions(Disk: PBlockDevice): Boolean;
var
  DeviceIndex: Integer;
  Device: PBlockDevice;
begin
  for DeviceIndex := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(DeviceIndex);
    if Device^.Parent = Disk then
      Exit(True);
  end;
  Result := False;
end;

procedure MountAllVolumes;
var
  DeviceIndex: Integer;
  Device: PBlockDevice;
begin
  for DeviceIndex := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(DeviceIndex);
    if (not BlockDeviceIsPartition(Device)) and DiskHasPartitions(Device) then
      Continue;
    MountVolume(Device);
  end;
end;

function VolumeCount: Integer;
begin
  Result := MountedVolumeCount;
end;

function VolumeAt(Index: Integer): PVolume;
begin
  if (Index < 0) or (Index >= MountedVolumeCount) then
    Exit(nil);
  Result := Volumes[Index];
end;

function FindVolumeByName(Name: PChar): PVolume;
var
  Index: Integer;
begin
  for Index := 0 to MountedVolumeCount - 1 do
  begin
    if TextIsEqual(@Volumes[Index]^.Name[0], Name) then
      Exit(Volumes[Index]);
  end;
  Result := nil;
end;

end.
