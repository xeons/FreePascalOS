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
  File system drivers and mounted volumes.

  Drivers register themselves here. At startup MountAllVolumes offers
  every block device to each driver in turn; the first one whose Probe
  accepts the device mounts it. A whole disk is only considered when it
  has no partitions (a "superfloppy" without a partition table).

  Each volume appears in the file namespace as a directory under the
  root, named after its block device: /disk1p2, /disk0p1 and so on.

  Disks plugged in later (USB disks) are mounted the same way by
  MountVolumesOfDisk (Io.DiskArrival), and their volumes taken away by
  RemoveVolumesOfDisk when they are unplugged: off the list, marked gone
  (FileSystem.Files: operations on them fail from then on), and
  watchers told (FileSystem.Watches). A gone volume's record is never
  freed: open files, named pipes and image sections may still name it,
  and none of them must ever mistake a later volume for it.

  A volume is mounted read-write when its driver implements the write
  routines, its device accepts writes, the driver did not ask for
  read-only (for example because of unknown on-disk features), and the
  kernel option "read-only-volumes" is not set.
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

{ Mounts the volumes of a disk that arrived after startup: every
  partition, or the whole disk if it has none. Returns how many. }
function MountVolumesOfDisk(Disk: PBlockDevice): Integer;
{ Takes away every volume on Disk and its partitions (the disk is
  gone). }
procedure RemoveVolumesOfDisk(Disk: PBlockDevice);

function VolumeCount: Integer;
function VolumeAt(Index: Integer): PVolume;
function FindVolumeByName(Name: PChar): PVolume;

implementation

uses
  Runtime.Text,
  Runtime.LinkedList,
  Runtime.Atomic,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.SharedLocks,
  Kernel.Options,
  FileSystem.Files,
  FileSystem.Watches,
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
  { Held shared to look volumes up (every path does), exclusively to
    change the list. }
  VolumeListLock: TSharedLock;
  { The last number given to a volume (TVolume.Number); volumes are
    mounted at boot and by the disk arrival thread, so it is counted
    atomically. }
  LastVolumeNumber: Int64;

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
  InitializeSharedLock(VolumeListLock);
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
  if Volume^.IsReadOnly then
    DebugWrite(', mounted read-only at /')
  else
    DebugWrite(', mounted read-write at /');
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
    Volume^.IsReadOnly := (not DriverSupportsWriting(Driver)) or BlockDeviceIsReadOnly(Device) or
      KernelOptionIsSet('read-only-volumes');
    InitializeMutex(Volume^.Lock);
    InitializeListHead(Volume^.NodeCache);
    Volume^.Number := LongWord(AtomicIncrement(LastVolumeNumber));
    CopyText(@Volume^.Name[0], @Device^.Name[0], VolumeNameLength);

    Status := Driver^.Mount(Volume);
    if Status <> StatusSuccess then
    begin
      ReportMountFailure(Device, Driver, Status);
      FreeKernelMemory(Volume);
      Continue;
    end;

    RegisterRootNode(Volume);

    AcquireSharedLockExclusive(VolumeListLock);
    if MountedVolumeCount < MaximumVolumes then
    begin
      Volumes[MountedVolumeCount] := Volume;
      Inc(MountedVolumeCount);
    end;
    ReleaseSharedLock(VolumeListLock);

    ReportMountedVolume(Volume);
    ReportVolumeArrival(Volume);
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

function MountVolumesOfDisk(Disk: PBlockDevice): Integer;
var
  DeviceIndex: Integer;
  Device: PBlockDevice;
begin
  Result := 0;
  if not DiskHasPartitions(Disk) then
  begin
    if MountVolume(Disk) <> nil then
      Inc(Result);
    Exit;
  end;
  for DeviceIndex := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(DeviceIndex);
    if (Device <> nil) and (Device^.Parent = Disk) and (MountVolume(Device) <> nil) then
      Inc(Result);
  end;
end;

procedure ReportRemovedVolume(Volume: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Volume^.Name[0]);
  DebugWriteLine(': gone (its disk was removed)');
  DebugEndMessage;
end;

{ Takes Volume off the list; False if it was not on it. }
function TakeOffList(Volume: PVolume): Boolean;
var
  Index: Integer;
  Found: Integer;
begin
  AcquireSharedLockExclusive(VolumeListLock);
  Found := -1;
  for Index := 0 to MountedVolumeCount - 1 do
    if Volumes[Index] = Volume then
      Found := Index;
  if Found >= 0 then
  begin
    for Index := Found to MountedVolumeCount - 2 do
      Volumes[Index] := Volumes[Index + 1];
    Dec(MountedVolumeCount);
    Volumes[MountedVolumeCount] := nil;
  end;
  ReleaseSharedLock(VolumeListLock);
  Result := Found >= 0;
end;

{ The volume on Disk or one of its partitions, or nil. }
function FindVolumeOnDisk(Disk: PBlockDevice): PVolume;
var
  Index: Integer;
  Volume: PVolume;
begin
  AcquireSharedLockShared(VolumeListLock);
  Result := nil;
  for Index := 0 to MountedVolumeCount - 1 do
  begin
    Volume := Volumes[Index];
    if (Volume^.Device = Disk) or (Volume^.Device^.Parent = Disk) then
    begin
      Result := Volume;
      Break;
    end;
  end;
  ReleaseSharedLock(VolumeListLock);
end;

procedure RemoveVolumesOfDisk(Disk: PBlockDevice);
var
  Volume: PVolume;
begin
  Volume := FindVolumeOnDisk(Disk);
  while Volume <> nil do
  begin
    if TakeOffList(Volume) then
    begin
      MarkVolumeGone(Volume);
      ReportRemovedVolume(Volume);
      ReportVolumeDeparture(Volume);
    end;
    Volume := FindVolumeOnDisk(Disk);
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
  { Under the lock: the list closes up when a volume goes away. }
  AcquireSharedLockShared(VolumeListLock);
  Result := nil;
  for Index := 0 to MountedVolumeCount - 1 do
  begin
    if TextIsEqual(@Volumes[Index]^.Name[0], Name) then
    begin
      Result := Volumes[Index];
      Break;
    end;
  end;
  ReleaseSharedLock(VolumeListLock);
end;


end.
