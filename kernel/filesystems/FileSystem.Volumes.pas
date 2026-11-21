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
  Memory volumes (tmpfs, FileSystem.Memory) have no device and are
  named tmpfs1, tmpfs2, ... (MountMemoryVolume). The system volume is
  also found by the name "system" (an alias that is not listed), so
  /system is a stable path for it whatever its disk is called. A volume
  may further be mounted on a directory of another (FileSystem.Mounts).

  Disks plugged in later (USB disks) are mounted the same way by
  MountVolumesOfDisk (Io.DiskArrival), and their volumes taken away by
  RemoveVolumesOfDisk when they are unplugged: off the list, marked gone
  (FileSystem.Files: operations on them fail from then on), and
  watchers told (FileSystem.Watches). A gone volume's record is never
  freed: open files, named pipes and image sections may still name it,
  and none of them must ever mistake a later volume for it.

  A volume is mounted read-write when its driver implements the write
  routines, its device accepts writes, the driver did not ask for
  read-only (for example because of unknown on-disk features), the
  kernel option "read-only-volumes" is not set and the mount options
  (FileSystem.MountOptions) do not say "ro".

  Unmounted volumes leave the list (FileSystem.Mounts.UnmountVolume);
  one whose files are still open lingers until they are closed, and
  its device cannot be mounted again meanwhile.
}
unit FileSystem.Volumes;

{$mode objfpc}

interface

uses
  Io.BlockDevice,
  FileSystem.MountOptions,
  FileSystem.Types;

const
  MaximumFileSystemDrivers = 8;
  MaximumVolumes = 32;
  { The name the system volume is also found by. }
  SystemVolumeAlias = 'system';

procedure InitializeFileSystems;
procedure RegisterFileSystemDriver(Driver: PFileSystemDriver);

procedure MountAllVolumes;

{ Tries every driver on Device. Returns the new volume or nil. }
function MountVolume(Device: PBlockDevice): PVolume;
{ The same with mount options (read-only, noexec, owners, ...). }
function MountVolumeWithOptions(Device: PBlockDevice; const Options: TMountOptions): PVolume;
{ A new memory volume (tmpfs) with Options (size=, mode=, ...); nil if
  memory ran out or the list is full. }
function MountMemoryVolume(const Options: TMountOptions): PVolume;
{ Applies new options to a mounted volume: noexec, nosuid, discard and
  the owners of formats without them at once; "ro" writes the volume
  back and makes it read-only. A read-only volume stays read-only
  (unmount and mount it again), which Options^.ReadOnly then says. }
procedure ChangeVolumeOptions(Volume: PVolume; var Options: TMountOptions);

{ Takes Volume off the list; False if it was not on it. }
function RemoveVolumeFromList(Volume: PVolume): Boolean;
{ Keeps an unmounted volume whose files are still open in mind, so its
  device is not mounted twice. }
procedure RememberLingeringVolume(Volume: PVolume);
{ The volume on the list that lives on Device, or nil. }
function FindVolumeByDevice(Device: PBlockDevice): PVolume;
{ True if an unmounted volume of Device still has files open. }
function DeviceHasLingeringVolume(Device: PBlockDevice): Boolean;

{ The system volume (Processes.Paths picks it), or nil. }
procedure SetSystemVolume(Volume: PVolume);
function SystemVolume: PVolume;

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
  Kernel.Options,
  FileSystem.Files,
  FileSystem.Mounts,
  FileSystem.Watches,
  Io.BlockCache,
  FileSystem.Fat,
  FileSystem.ExFat,
  FileSystem.Ext,
  FileSystem.Memory,
  Debug.Output;

var
  Drivers: array[0..MaximumFileSystemDrivers - 1] of PFileSystemDriver;
  DriverCount: Integer;
  Volumes: array[0..MaximumVolumes - 1] of PVolume;
  MountedVolumeCount: Integer;
  VolumeListLock: TMutex;
  { The last number given to a volume (TVolume.Number); volumes are
    mounted at boot and by the disk arrival thread, so it is counted
    atomically. }
  LastVolumeNumber: Int64;
  { The last number in a memory volume's name (tmpfs1, ...). }
  LastMemoryVolumeNumber: Int64;
  TheSystemVolume: PVolume;
  LingeringVolumes: array[0..MaximumVolumes - 1] of PVolume;

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
  InitializeMounts;

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
  if Volume^.TotalBytes <> 0 then
  begin
    DebugWrite(', ');
    DebugWriteSize(Volume^.TotalBytes);
  end;
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

{ A fresh volume record for Driver. }
function NewVolume(Driver: PFileSystemDriver; Device: PBlockDevice; const Options: TMountOptions): PVolume;
begin
  Result := PVolume(AllocateZeroedKernelMemory(SizeOf(TVolume)));
  if Result = nil then
    Exit;
  Result^.Device := Device;
  Result^.Driver := Driver;
  Result^.Options := Options;
  Result^.CanWrite := DriverSupportsWriting(Driver) and
    ((Device = nil) or not BlockDeviceIsReadOnly(Device)) and not KernelOptionIsSet('read-only-volumes');
  Result^.IsReadOnly := not Result^.CanWrite or Options.ReadOnly;
  InitializeMutex(Result^.Lock);
  InitializeListHead(Result^.NodeCache);
  Result^.Number := LongWord(AtomicIncrement(LastVolumeNumber));
end;

{ Puts a volume the driver mounted on the list and tells everyone. }
function ListVolume(Volume: PVolume): PVolume;
var
  Listed: Boolean;
begin
  { A driver that chose read-only cannot be made writable later. }
  if Volume^.IsReadOnly and not Volume^.Options.ReadOnly then
    Volume^.CanWrite := False;
  Volume^.Options.ReadOnly := Volume^.IsReadOnly;
  RegisterRootNode(Volume);

  AcquireMutex(VolumeListLock);
  Listed := MountedVolumeCount < MaximumVolumes;
  if Listed then
  begin
    Volumes[MountedVolumeCount] := Volume;
    Inc(MountedVolumeCount);
  end;
  ReleaseMutex(VolumeListLock);

  ReportMountedVolume(Volume);
  ReportVolumeArrival(Volume);
  Result := Volume;
end;

function MountVolumeWithOptions(Device: PBlockDevice; const Options: TMountOptions): PVolume;
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
    if Driver^.IsVirtual or not Driver^.Probe(Device) then
      Continue;

    Volume := NewVolume(Driver, Device, Options);
    if Volume = nil then
      Exit;
    CopyText(@Volume^.Name[0], @Device^.Name[0], VolumeNameLength);

    Status := Driver^.Mount(Volume);
    if Status <> StatusSuccess then
    begin
      ReportMountFailure(Device, Driver, Status);
      FreeKernelMemory(Volume);
      Continue;
    end;
    Exit(ListVolume(Volume));
  end;
end;

function MountVolume(Device: PBlockDevice): PVolume;
var
  Options: TMountOptions;
begin
  SetDefaultMountOptions(Options);
  Result := MountVolumeWithOptions(Device, Options);
end;

procedure AppendNumber(Text: PChar; Capacity: Integer; Value: QWord);
var
  Digits: array[0..23] of Char;
  Count: Integer;
  Length: Integer;
begin
  Count := 0;
  repeat
    Digits[Count] := Char(Ord('0') + Value mod 10);
    Value := Value div 10;
    Inc(Count);
  until Value = 0;
  Length := TextLength(Text);
  while (Count > 0) and (Length + 1 < Capacity) do
  begin
    Dec(Count);
    Text[Length] := Digits[Count];
    Inc(Length);
  end;
  Text[Length] := #0;
end;

function MountMemoryVolume(const Options: TMountOptions): PVolume;
var
  Volume: PVolume;
  Status: TFileSystemStatus;
begin
  Result := nil;
  Volume := NewVolume(MemoryFileSystemDriver, nil, Options);
  if Volume = nil then
    Exit;
  CopyText(@Volume^.Name[0], 'tmpfs', VolumeNameLength);
  AppendNumber(@Volume^.Name[0], VolumeNameLength, QWord(AtomicIncrement(LastMemoryVolumeNumber)));
  Status := Volume^.Driver^.Mount(Volume);
  if Status <> StatusSuccess then
  begin
    FreeKernelMemory(Volume);
    Exit;
  end;
  Result := ListVolume(Volume);
end;

procedure ChangeVolumeOptions(Volume: PVolume; var Options: TMountOptions);
begin
  if Options.ReadOnly and not Volume^.IsReadOnly then
    SyncVolume(Volume);
  AcquireMutex(Volume^.Lock);
  if Options.ReadOnly then
    Volume^.IsReadOnly := True;
  Options.ReadOnly := Volume^.IsReadOnly;
  { What a memory volume was made with stays. }
  Options.SizeLimitBytes := Volume^.Options.SizeLimitBytes;
  Options.SizePercent := Volume^.Options.SizePercent;
  Options.RootMode := Volume^.Options.RootMode;
  Volume^.Options := Options;
  if Volume^.Driver^.HasNoOwners then
    RemapOwnerlessNodes(Volume);
  ReleaseMutex(Volume^.Lock);
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

function RemoveVolumeFromList(Volume: PVolume): Boolean;
var
  Index: Integer;
  Found: Integer;
begin
  AcquireMutex(VolumeListLock);
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
  ReleaseMutex(VolumeListLock);
  Result := Found >= 0;
end;

{ The volume on Disk or one of its partitions, or nil. }
function FindVolumeOnDisk(Disk: PBlockDevice): PVolume;
var
  Index: Integer;
  Volume: PVolume;
begin
  AcquireMutex(VolumeListLock);
  Result := nil;
  for Index := 0 to MountedVolumeCount - 1 do
  begin
    Volume := Volumes[Index];
    if (Volume^.Device <> nil) and ((Volume^.Device = Disk) or (Volume^.Device^.Parent = Disk)) then
    begin
      Result := Volume;
      Break;
    end;
  end;
  ReleaseMutex(VolumeListLock);
end;

procedure RemoveVolumesOfDisk(Disk: PBlockDevice);
var
  Volume: PVolume;
begin
  Volume := FindVolumeOnDisk(Disk);
  while Volume <> nil do
  begin
    if RemoveVolumeFromList(Volume) then
    begin
      ForgetMountsOfVolume(Volume);
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

procedure SetSystemVolume(Volume: PVolume);
begin
  TheSystemVolume := Volume;
end;

function SystemVolume: PVolume;
begin
  Result := TheSystemVolume;
end;

function FindVolumeByDevice(Device: PBlockDevice): PVolume;
var
  Index: Integer;
begin
  AcquireMutex(VolumeListLock);
  Result := nil;
  for Index := 0 to MountedVolumeCount - 1 do
    if Volumes[Index]^.Device = Device then
    begin
      Result := Volumes[Index];
      Break;
    end;
  ReleaseMutex(VolumeListLock);
end;

procedure RememberLingeringVolume(Volume: PVolume);
var
  Index: Integer;
  Free: Integer;
begin
  if Volume^.Device = nil then
    Exit;
  AcquireMutex(VolumeListLock);
  Free := -1;
  for Index := 0 to MaximumVolumes - 1 do
    if (LingeringVolumes[Index] = nil) or LingeringVolumes[Index]^.IsUnmounted then
    begin
      LingeringVolumes[Index] := nil;
      if Free < 0 then
        Free := Index;
    end;
  if (Free >= 0) and not Volume^.IsUnmounted then
    LingeringVolumes[Free] := Volume;
  ReleaseMutex(VolumeListLock);
end;

function DeviceHasLingeringVolume(Device: PBlockDevice): Boolean;
var
  Index: Integer;
begin
  AcquireMutex(VolumeListLock);
  Result := False;
  for Index := 0 to MaximumVolumes - 1 do
    if (LingeringVolumes[Index] <> nil) and not LingeringVolumes[Index]^.IsUnmounted and
       (LingeringVolumes[Index]^.Device = Device) then
      Result := True;
  ReleaseMutex(VolumeListLock);
end;

function FindVolumeByName(Name: PChar): PVolume;
var
  Index: Integer;
begin
  if (TheSystemVolume <> nil) and TextIsEqual(Name, SystemVolumeAlias) and not TheSystemVolume^.IsGone then
    Exit(TheSystemVolume);
  { Under the lock: the list closes up when a volume goes away. }
  AcquireMutex(VolumeListLock);
  Result := nil;
  for Index := 0 to MountedVolumeCount - 1 do
  begin
    if TextIsEqual(@Volumes[Index]^.Name[0], Name) then
    begin
      Result := Volumes[Index];
      Break;
    end;
  end;
  ReleaseMutex(VolumeListLock);
end;


end.
