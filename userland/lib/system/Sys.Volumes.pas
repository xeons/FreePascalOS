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
  The volumes (mounted file systems) and their comings and goings.

  Every volume is a folder under /volumes, named after the disk or
  partition it is on (/volumes/disk2p1); the system volume is also "/".
  Disks plugged in while the system runs (USB disks) are mounted there
  at once, and leave when they are unplugged.

  GetVolumeDescription lists them by index (0, 1, ... until it returns
  False); the list may change between two calls. WatchVolumes gives a
  watch (Sys.FileWatches) whose changes are FileChangeCreated when a
  volume arrives and FileChangeRemoved when one goes, the name being the
  volume's.
}
unit Sys.Volumes;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  VolumesFolder = '/volumes';
  MountPointCapacity = AbiTextCapacity + 16;

type
  TVolumeDescription = record
    Name: array[0..AbiTextCapacity - 1] of Char;
    VolumeLabel: array[0..AbiTextCapacity - 1] of Char;
    { "fat32", "exfat", "ext4", ... }
    FileSystemType: array[0..AbiTextCapacity - 1] of Char;
    { Where it is: /volumes/<name>. }
    MountPoint: array[0..MountPointCapacity - 1] of Char;
    TotalBytes: QWord;
    { Valid when HasFreeSpace. }
    FreeBytes: QWord;
    HasFreeSpace: Boolean;
    IsReadOnly: Boolean;
    IsSystemVolume: Boolean;
    { On a disk that can be unplugged. }
    IsRemovable: Boolean;
  end;

{ The volume at Index; False past the last one. }
function GetVolumeDescription(Index: Integer; out Description: TVolumeDescription): Boolean;
{ The volume named Name; False if there is none. }
function FindVolumeDescription(Name: PChar; out Description: TVolumeDescription): Boolean;
{ A watch on the list of volumes, or minus an error code. }
function WatchVolumes: Int64;

implementation

uses
  Runtime.Text,
  Sys.Kernel,
  Sys.FileWatches;

procedure DescribeVolume(const Information: TAbiVolumeInformation; out Description: TVolumeDescription);
var
  Length: PtrUInt;
begin
  CopyText(@Description.Name[0], @Information.Name[0], AbiTextCapacity);
  CopyText(@Description.VolumeLabel[0], @Information.VolumeLabel[0], AbiTextCapacity);
  CopyText(@Description.FileSystemType[0], @Information.FileSystemType[0], AbiTextCapacity);
  CopyText(@Description.MountPoint[0], VolumesFolder + '/', MountPointCapacity);
  Length := TextLength(@Description.MountPoint[0]);
  CopyText(@Description.MountPoint[Length], @Information.Name[0], MountPointCapacity - Length);
  Description.TotalBytes := Information.TotalBytes;
  Description.FreeBytes := Information.FreeBytes;
  Description.HasFreeSpace := Information.HasFreeSpace <> 0;
  Description.IsReadOnly := Information.IsReadOnly <> 0;
  Description.IsSystemVolume := Information.IsSystemVolume <> 0;
  Description.IsRemovable := Information.IsRemovable <> 0;
end;

function GetVolumeDescription(Index: Integer; out Description: TVolumeDescription): Boolean;
var
  Information: TAbiVolumeInformation;
begin
  Result := KernelListVolumes(QWord(Index), Information) > 0;
  if Result then
    DescribeVolume(Information, Description);
end;

function FindVolumeDescription(Name: PChar; out Description: TVolumeDescription): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    if TextIsEqual(@Description.Name[0], Name) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function WatchVolumes: Int64;
begin
  Result := WatchPath(VolumesFolder, WatchNames);
end;

end.
