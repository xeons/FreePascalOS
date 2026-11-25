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
  Mounting volumes at directories, and unmounting volumes.

  Every volume is in the list of volumes (FileSystem.Volumes, the
  namespace root /volumes); one may also be mounted on a directory of
  another volume, such as a memory volume on the system volume's /tmp
  or a USB disk on /mnt/usb. The table (FileSystem.MountTable) records
  each such mount; the mount point's node stays referenced while the
  mount lasts, so the volume holding it is busy and the directory
  cannot be removed or renamed (FileSystem.Files).

  Locking: MountListLock serializes mounting and unmounting. A record
  is entered and taken out with the lock of the volume holding the
  mount point held too, so path resolution, which holds that volume's
  lock while it looks for mount points (MountedVolumeAt), never sees a
  record half made. A mounted volume's own record pointer is changed
  with its lock held, for TopVolumeOfVolume and CopyVolumeMountPath.

  Unmounting needs the volume idle - no node besides its root in use,
  its root not open, nothing mounted on it - unless forced. It writes
  the volume back, takes it off the list and marks it gone, as an
  unplugged disk's volumes are (FileSystem.Files.MarkVolumeGone): open
  files of a forced unmount fail from then on and its driver data goes
  once the last of them is closed. The system volume is never
  unmounted.
}
unit FileSystem.Mounts;

{$mode objfpc}

interface

uses
  FileSystem.Types,
  FileSystem.MountTable;

procedure InitializeMounts;

{ Mounts Child (a volume on the list, mounted on no directory yet) on
  the directory at the kernel path Path. StatusInUse if Child is
  mounted somewhere already, something is mounted on the directory, or
  it is a volume's root; StatusInvalidPath if the directory is on Child
  or a volume mounted below it; StatusNoSpace if the table is full. }
function MountAtDirectory(Child: PVolume; Path: PChar): TFileSystemStatus;

{ Unmounts Volume (see above): StatusInUse while busy and not Force. }
function UnmountVolume(Volume: PVolume; Force: Boolean): TFileSystemStatus;

{ Volume went away (its disk was unplugged): its mount is forgotten,
  and so are the mounts on it (those volumes stay on the list). }
procedure ForgetMountsOfVolume(Volume: PVolume);

{ For path resolution, with Parent's lock held: the volume mounted on
  node NodeNumber of Parent, or nil. }
function MountedVolumeAt(Parent: PVolume; NodeNumber: QWord): PVolume;
{ With Parent's lock held: the path, from Parent's root, of the Index-th
  mount point on Parent (from 0); False after the last. }
function MountPointPathOnVolume(Parent: PVolume; Index: Integer; Path: PChar; Capacity: PtrUInt): Boolean;
{ With Volume's lock held: the volume at the top of its chain of mounts
  (itself when it is mounted nowhere), and its root's path from there
  ("" when mounted nowhere). }
function TopVolumeOfVolume(Volume: PVolume): PVolume;
procedure CopyVolumeMountPath(Volume: PVolume; Path: PChar; Capacity: PtrUInt);

{ Describes the Index-th mount (from 0): the volume mounted, the volume
  at the top of the chain and the mount point's path from its root.
  False after the last. }
function DescribeMount(Index: Integer; out Child, Top: PVolume; Path: PChar; Capacity: PtrUInt): Boolean;
{ Where Volume is mounted: the volume at the top of its chain and the
  mount point's path from its root; False if it is mounted nowhere. }
function FindVolumeMountPoint(Volume: PVolume; out Top: PVolume; Path: PChar; Capacity: PtrUInt): Boolean;

implementation

uses
  Runtime.Text,
  Kernel.Mutex,
  FileSystem.Files,
  FileSystem.Volumes,
  FileSystem.Watches,
  Debug.Output;

var
  Table: TMountTable;
  MountListLock: TMutex;

procedure InitializeMounts;
begin
  InitializeMountTable(Table);
  InitializeMutex(MountListLock);
end;

function MountedVolumeAt(Parent: PVolume; NodeNumber: QWord): PVolume;
var
  MountRecord: PMountRecord;
begin
  MountRecord := FindMountAt(Table, Parent, NodeNumber);
  if MountRecord = nil then
    Exit(nil);
  Result := PVolume(MountRecord^.Child);
end;

function MountPointPathOnVolume(Parent: PVolume; Index: Integer; Path: PChar; Capacity: PtrUInt): Boolean;
var
  RecordIndex: Integer;
  MountRecord: PMountRecord;
  RootPathLength: PtrUInt;
  RootPath: array[0..MaximumMountPathBytes - 1] of Char;
begin
  { Records on Parent are entered and taken out with its lock held. }
  CopyVolumeMountPath(Parent, @RootPath[0], MaximumMountPathBytes);
  RootPathLength := TextLength(@RootPath[0]);
  for RecordIndex := 0 to MaximumMounts - 1 do
  begin
    MountRecord := @Table.Records[RecordIndex];
    if not MountRecord^.InUse or (MountRecord^.Parent <> Pointer(Parent)) then
      Continue;
    if Index > 0 then
    begin
      Dec(Index);
      Continue;
    end;
    { The record's path runs from the top volume: Parent's own mount
      path comes first. }
    if TextLength(@MountRecord^.Path[0]) >= RootPathLength then
      CopyText(Path, @MountRecord^.Path[RootPathLength], Capacity)
    else
      CopyText(Path, '', Capacity);
    Exit(True);
  end;
  Result := False;
end;

function TopVolumeOfVolume(Volume: PVolume): PVolume;
var
  MountRecord: PMountRecord;
begin
  MountRecord := PMountRecord(Volume^.MountRecord);
  if MountRecord = nil then
    Exit(Volume);
  Result := PVolume(MountRecord^.Top);
end;

procedure CopyVolumeMountPath(Volume: PVolume; Path: PChar; Capacity: PtrUInt);
var
  MountRecord: PMountRecord;
begin
  MountRecord := PMountRecord(Volume^.MountRecord);
  if MountRecord = nil then
    CopyText(Path, '', Capacity)
  else
    CopyText(Path, @MountRecord^.Path[0], Capacity);
end;

procedure ReportMount(Child: PVolume; MountRecord: PMountRecord);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Child^.Name[0]);
  DebugWrite(': mounted at /');
  DebugWrite(@PVolume(MountRecord^.Top)^.Name[0]);
  DebugWriteLine(@MountRecord^.Path[0]);
  DebugEndMessage;
end;

procedure ReportUnmount(Volume: PVolume; Forced: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Volume^.Name[0]);
  if Forced then
    DebugWriteLine(': unmounted (forced)')
  else
    DebugWriteLine(': unmounted');
  DebugEndMessage;
end;

{ Enters the mount; MountListLock held. Takes over the reference to
  MountPointNode on success. }
function EnterMount(Child, Parent: PVolume; MountPointNode: PNode; RelativePath: PChar): TFileSystemStatus;
var
  ParentRootPath: array[0..MaximumMountPathBytes - 1] of Char;
  FullPath: array[0..MaximumMountPathBytes - 1] of Char;
  MountRecord: PMountRecord;
  Top: PVolume;
begin
  if Child^.IsGone or (FindMountOf(Table, Child) <> nil) then
    Exit(StatusInUse);
  if IsMountedBelow(Table, Parent, Child) then
    Exit(StatusInvalidPath);
  if FindMountAt(Table, Parent, MountPointNode^.Information.NodeNumber) <> nil then
    Exit(StatusInUse);

  Top := PVolume(TopVolumeOf(Table, Parent));
  CopyVolumeRootPath(Table, Parent, @ParentRootPath[0], MaximumMountPathBytes);
  if not JoinMountPath(@ParentRootPath[0], RelativePath, @FullPath[0], MaximumMountPathBytes) then
    Exit(StatusNameTooLong);

  AcquireMutex(Parent^.Lock);
  if Parent^.IsGone then
  begin
    ReleaseMutex(Parent^.Lock);
    Exit(StatusVolumeGone);
  end;
  MountRecord := AddMount(Table, Parent, MountPointNode, MountPointNode^.Information.NodeNumber,
    Child, Top, @FullPath[0]);
  if MountRecord <> nil then
    Inc(Parent^.MountsOnVolume);
  ReleaseMutex(Parent^.Lock);
  if MountRecord = nil then
    Exit(StatusNoSpace);

  AcquireMutex(Child^.Lock);
  Child^.MountRecord := MountRecord;
  ReleaseMutex(Child^.Lock);
  ReportMount(Child, MountRecord);
  Result := StatusSuccess;
end;

function MountAtDirectory(Child: PVolume; Path: PChar): TFileSystemStatus;
var
  Parent: PVolume;
  MountPointNode: PNode;
  RelativePath: array[0..MaximumMountPathBytes - 1] of Char;
  Found: PVolume;
begin
  { Mounted there already: nothing to do (mount -o on a mount point
    only changes the options, which the caller did). }
  if (Child^.MountRecord <> nil) and
     (LocatePath(Path, True, Found, @RelativePath[0], MaximumMountPathBytes) = StatusSuccess) and
     (Found = Child) and (RelativePath[0] = #0) then
    Exit(StatusSuccess);
  Result := ResolveDirectoryForMount(Path, Parent, MountPointNode, @RelativePath[0], MaximumMountPathBytes);
  if Result <> StatusSuccess then
    Exit;
  AcquireMutex(MountListLock);
  Result := EnterMount(Child, Parent, MountPointNode, @RelativePath[0]);
  ReleaseMutex(MountListLock);
  if Result <> StatusSuccess then
    ReleaseNodeOfVolume(Parent, MountPointNode);
end;

{ Takes a record out of the table and gives its mount point back.
  MountListLock held. }
procedure DetachMount(MountRecord: PMountRecord);
var
  Parent: PVolume;
  Child: PVolume;
  MountPointNode: PNode;
begin
  Parent := PVolume(MountRecord^.Parent);
  Child := PVolume(MountRecord^.Child);
  MountPointNode := PNode(MountRecord^.MountPointNode);

  AcquireMutex(Child^.Lock);
  Child^.MountRecord := nil;
  ReleaseMutex(Child^.Lock);

  AcquireMutex(Parent^.Lock);
  RemoveMount(MountRecord);
  Dec(Parent^.MountsOnVolume);
  ReleaseMutex(Parent^.Lock);
  ReleaseNodeOfVolume(Parent, MountPointNode);
end;

function UnmountVolume(Volume: PVolume; Force: Boolean): TFileSystemStatus;
var
  MountRecord: PMountRecord;
  Busy: Boolean;
begin
  if Volume = SystemVolume then
    Exit(StatusInUse);
  AcquireMutex(MountListLock);
  { Mounts on the volume are made and undone under MountListLock, so
    none appears meanwhile. }
  if CountMountsOn(Table, Volume) > 0 then
  begin
    ReleaseMutex(MountListLock);
    Exit(StatusInUse);
  end;
  { The idle check and marking the volume gone happen in one hold of its
    lock: nothing opened in between slips through. }
  Result := RetireVolume(Volume, Force, Busy);
  if Result <> StatusSuccess then
  begin
    ReleaseMutex(MountListLock);
    { Gone already (its disk was unplugged): nothing left to do. }
    if Result = StatusVolumeGone then
      Result := StatusSuccess;
    Exit;
  end;
  MountRecord := FindMountOf(Table, Volume);
  if MountRecord <> nil then
    DetachMount(MountRecord);
  ReleaseMutex(MountListLock);

  if RemoveVolumeFromList(Volume) then
  begin
    RememberLingeringVolume(Volume);
    ReportUnmount(Volume, Busy);
    ReportVolumeDeparture(Volume);
  end;
end;

procedure ForgetMountsOfVolume(Volume: PVolume);
var
  Index: Integer;
  MountRecord: PMountRecord;
begin
  AcquireMutex(MountListLock);
  MountRecord := FindMountOf(Table, Volume);
  if MountRecord <> nil then
    DetachMount(MountRecord);
  for Index := 0 to MaximumMounts - 1 do
  begin
    MountRecord := @Table.Records[Index];
    if MountRecord^.InUse and (MountRecord^.Parent = Pointer(Volume)) then
      DetachMount(MountRecord);
  end;
  ReleaseMutex(MountListLock);
end;

function DescribeMount(Index: Integer; out Child, Top: PVolume; Path: PChar; Capacity: PtrUInt): Boolean;
var
  MountRecord: PMountRecord;
begin
  AcquireMutex(MountListLock);
  MountRecord := MountAt(Table, Index);
  Result := MountRecord <> nil;
  if Result then
  begin
    Child := PVolume(MountRecord^.Child);
    Top := PVolume(MountRecord^.Top);
    CopyText(Path, @MountRecord^.Path[0], Capacity);
  end
  else
  begin
    Child := nil;
    Top := nil;
    Path[0] := #0;
  end;
  ReleaseMutex(MountListLock);
end;

function FindVolumeMountPoint(Volume: PVolume; out Top: PVolume; Path: PChar; Capacity: PtrUInt): Boolean;
var
  MountRecord: PMountRecord;
begin
  AcquireMutex(MountListLock);
  MountRecord := FindMountOf(Table, Volume);
  Result := MountRecord <> nil;
  if Result then
  begin
    Top := PVolume(MountRecord^.Top);
    CopyText(Path, @MountRecord^.Path[0], Capacity);
  end
  else
  begin
    Top := nil;
    Path[0] := #0;
  end;
  ReleaseMutex(MountListLock);
end;

end.
