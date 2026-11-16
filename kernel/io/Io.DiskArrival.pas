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
  Disks arriving and leaving while the system runs (USB disks plugged in
  and unplugged).

  At startup Io.Startup brings every disk up in batches: partitions,
  /dev devices, then the file systems. A disk found later goes through
  the same steps on its own (AnnounceDiskArrival): its partitions are
  read, it and they appear in /dev, and their volumes are mounted under
  /volumes, which tells the watchers of the list of volumes. Until
  Io.Startup calls EnableDiskArrival, a new disk is left to the startup
  batches.

  When a disk goes (AnnounceDiskRemoval), its I/O fails from then on,
  its volumes are taken away (open files fail, watchers learn that the
  volume is gone), the block cache forgets it, and it and its
  partitions leave /dev and the list of block devices.

  Both run in a thread that may wait (the USB port watcher), never at
  dispatch level.
}
unit Io.DiskArrival;

{$mode objfpc}

interface

uses
  Io.BlockDevice;

procedure EnableDiskArrival;
{ True once EnableDiskArrival was called: a driver that found a disk
  announces it. }
function DiskArrivalIsEnabled: Boolean;

{ Disk is registered (RegisterBlockDevice) and ready. }
procedure AnnounceDiskArrival(Disk: PBlockDevice);
{ Disk is gone; its driver fails its requests already. }
procedure AnnounceDiskRemoval(Disk: PBlockDevice);

implementation

uses
  Io.Partitions,
  Io.BlockCache,
  Drivers.DiskDevices,
  FileSystem.Volumes,
  Debug.Output;

var
  ArrivalEnabled: Boolean = False;

procedure EnableDiskArrival;
begin
  ArrivalEnabled := True;
end;

function DiskArrivalIsEnabled: Boolean;
begin
  Result := ArrivalEnabled;
end;

procedure ReportDisk(Disk: PBlockDevice; What: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('block');
  DebugWrite(@Disk^.Name[0]);
  DebugWriteLine(What);
  DebugEndMessage;
end;

procedure AnnounceDiskArrival(Disk: PBlockDevice);
begin
  ReportDisk(Disk, ': plugged in');
  ScanPartitions(Disk);
  CreateDiskDevicesOf(Disk);
  MountVolumesOfDisk(Disk);
end;

{ Drops what the block cache holds of Disk and its partitions. }
procedure ForgetCachedDisk(Disk: PBlockDevice);
var
  Index: Integer;
  Device: PBlockDevice;
begin
  InvalidateCachedDevice(Disk);
  for Index := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(Index);
    if (Device <> nil) and (Device^.Parent = Disk) then
      InvalidateCachedDevice(Device);
  end;
end;

procedure AnnounceDiskRemoval(Disk: PBlockDevice);
begin
  ReportDisk(Disk, ': unplugged');
  MarkDiskRemoved(Disk);
  RemoveVolumesOfDisk(Disk);
  ForgetCachedDisk(Disk);
  UnlistDiskDevicesOf(Disk);
  UnlistBlockDevices(Disk);
end;

end.
