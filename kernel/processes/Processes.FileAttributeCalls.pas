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
  System calls about attributes of open files and volumes:
  CallSetHandleAttributes (times, mode, owner of an open file, by handle)
  and CallGetVolumeInformation (the volume a path is on). Also the
  conversion they share with the path based calls (Processes.FileCalls);
  who may change what is checked by the VFS through
  Processes.Security.CurrentMayChangeAttributes.
}
unit Processes.FileAttributeCalls;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  FileSystem.Types,
  FileSystem.Volumes;

{ Root and kernel threads may change anything. }
function CallerMaySetAnyAttributes: Boolean;
{ The kernel form of Abi attribute changes ("now" times filled in). }
procedure ConvertAttributeChanges(const UserChanges: TAbiAttributeChanges; out Changes: TAttributeChanges);
procedure FillVolumeInformation(Volume: PVolume; out Information: TAbiVolumeInformation);

function PerformSetHandleAttributes(Handle: Int64; ChangesAddress: QWord): Int64;
function PerformGetVolumeInformation(PathAddress: QWord; InformationAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Clock,
  Kernel.Mutex,
  FileSystem.Files,
  FileSystem.Security,
  Io.BlockDevice,
  Processes.Process,
  Processes.Handles,
  Processes.Paths,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Security,
  Processes.ObjectCalls,
  Objects.Manager,
  Processes.FileCalls;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerMaySetAnyAttributes: Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Result := not Process^.IsUserProcess or (Process^.Credentials.EffectiveUserId = RootUserId);
end;

procedure ConvertAttributeChanges(const UserChanges: TAbiAttributeChanges; out Changes: TAttributeChanges);
begin
  { The Abi field flags have the same values as the VFS ones. }
  Changes.Fields := UserChanges.Fields;
  Changes.Mode := UserChanges.Mode;
  Changes.OwnerId := UserChanges.OwnerId;
  Changes.GroupId := UserChanges.GroupId;
  Changes.ModificationTime := UserChanges.ModificationTime;
  Changes.AccessTime := UserChanges.AccessTime;
  Changes.TimesAreNow := (UserChanges.Fields and ChangeFieldTimesAreNow) <> 0;
  if Changes.TimesAreNow then
  begin
    Changes.Fields := Changes.Fields and not ChangeFieldTimesAreNow;
    Changes.ModificationTime := CurrentWallClockTime;
    Changes.AccessTime := Changes.ModificationTime;
  end;
end;

procedure FillVolumeInformation(Volume: PVolume; out Information: TAbiVolumeInformation);
begin
  FillMemory(@Information, SizeOf(Information), 0);
  CopyText(@Information.Name[0], @Volume^.Name[0], AbiTextCapacity);
  CopyText(@Information.FileSystemType[0], @Volume^.TypeName[0], AbiTextCapacity);
  CopyText(@Information.VolumeLabel[0], @Volume^.VolumeLabel[0], AbiTextCapacity);
  Information.TotalBytes := Volume^.TotalBytes;
  Information.HasFreeSpace := Ord(GetVolumeFreeSpace(Volume, Information.FreeBytes));
  Information.IsReadOnly := Ord(Volume^.IsReadOnly);
  Information.IsSystemVolume := Ord(TextIsEqual(@Volume^.Name[0], SystemVolumeName));
  Information.IsRemovable := Ord((Volume^.Device <> nil) and BlockDeviceIsRemovable(Volume^.Device));
end;

function PerformSetHandleAttributes(Handle: Int64; ChangesAddress: QWord): Int64;
var
  UserChanges: TAbiAttributeChanges;
  Changes: TAttributeChanges;
  OpenedFile: POpenFile;
  Kind: THandleKind;
  Error: LongInt;
begin
  Error := CopyFromUser(@UserChanges, ChangesAddress, SizeOf(UserChanges));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { A reference, so that another thread closing the handle meanwhile
    cannot free the open file under us. }
  OpenedFile := POpenFile(ReferenceHandle(Handle, Kind));
  if OpenedFile = nil then
    Exit(Failure(ErrorBadHandle));
  if Kind <> HandleKindFile then
  begin
    DereferenceObject(OpenedFile);
    Exit(Failure(ErrorUnsupported));
  end;
  ConvertAttributeChanges(UserChanges, Changes);
  { Who may change what is checked by the VFS, under the volume's lock. }
  Result := -Int64(ErrorFromStatus(SetFileAttributes(OpenedFile, Changes)));
  DereferenceObject(OpenedFile);
end;

{ The volume a kernel path leads to, through mount points ("/" names
  no volume). }
function VolumeOfKernelPath(Path: PChar): PVolume;
var
  RelativePath: TPathBuffer;
begin
  if LocatePath(Path, True, Result, @RelativePath[0], SizeOf(RelativePath)) <> StatusSuccess then
    Result := nil;
end;

function PerformGetVolumeInformation(PathAddress: QWord; InformationAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Information: TAbiVolumeInformation;
  Volume: PVolume;
  Error: LongInt;
begin
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Volume := VolumeOfKernelPath(@KernelPath^[0]);
  FreeKernelMemory(KernelPath);
  if Volume = nil then
    Exit(Failure(ErrorNotFound));
  FillVolumeInformation(Volume, Information);
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

end.
