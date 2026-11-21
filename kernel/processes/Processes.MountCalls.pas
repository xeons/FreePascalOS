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
  System calls for mounting (172-175): CallMountVolume,
  CallUnmountVolume, CallListMounts and CallGetFileTimes.

  Mounting and unmounting are root's. A volume is named by its device
  (/dev/disk1p2), its place in /volumes, or made afresh (tmpfs). Before
  an unmount that is not forced, a program working in the volume (its
  current directory there) makes it busy, besides the open files and
  folders the VFS counts (FileSystem.Mounts).
}
unit Processes.MountCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformMountVolume(RequestAddress: QWord): Int64;
function PerformUnmountVolume(PathAddress: QWord; Flags: QWord): Int64;
function PerformListMounts(Index: QWord; InformationAddress: QWord): Int64;
function PerformGetFileTimes(PathAddress: QWord; Handle: Int64; Flags: QWord; TimesAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Io.BlockDevice,
  FileSystem.Types,
  FileSystem.MountOptions,
  FileSystem.Files,
  FileSystem.Volumes,
  FileSystem.Mounts,
  Processes.Process,
  Processes.Thread,
  Processes.Handles,
  Processes.Paths,
  Processes.UserAccess,
  Processes.FileCalls,
  Processes.FileAttributeCalls;

const
  DevicePrefix = '/dev/';
  VolumesPrefix = '/volumes/';
  MemoryTypeName = 'tmpfs';

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function StartsWith(Text, Prefix: PChar): Boolean;
begin
  while Prefix^ <> #0 do
  begin
    if Text^ <> Prefix^ then
      Exit(False);
    Inc(Text);
    Inc(Prefix);
  end;
  Result := True;
end;

function FindBlockDeviceByName(Name: PChar): PBlockDevice;
var
  Index: Integer;
  Device: PBlockDevice;
begin
  for Index := 0 to BlockDeviceCount - 1 do
  begin
    Device := BlockDeviceAt(Index);
    if (Device <> nil) and TextIsEqual(@Device^.Name[0], Name) then
      Exit(Device);
  end;
  Result := nil;
end;

{ "vfat", "msdos" and "fat" stand for every FAT; "auto" or nothing for
  anything. }
function TypeMatches(Wanted, Actual: PChar): Boolean;
begin
  if (Wanted^ = #0) or TextIsEqual(Wanted, 'auto') then
    Exit(True);
  if TextIsEqual(Wanted, 'vfat') or TextIsEqual(Wanted, 'msdos') or TextIsEqual(Wanted, 'fat') then
    Exit(StartsWith(Actual, 'fat'));
  Result := TextIsEqual(Wanted, Actual);
end;

{ The volume a mount request names, made if need be (Created). }
function VolumeForRequest(const Request: TAbiMountRequest; var Options: TMountOptions;
  out Volume: PVolume; out Created: Boolean): LongInt;
var
  Source: PChar;
  Device: PBlockDevice;
begin
  Volume := nil;
  Created := False;
  Source := @Request.Source[0];
  if TextIsEqual(@Request.FileSystemType[0], MemoryTypeName) then
  begin
    Volume := MountMemoryVolume(Options);
    if Volume = nil then
      Exit(ErrorOutOfMemory);
    Created := True;
    Exit(ErrorNone);
  end;

  if StartsWith(Source, VolumesPrefix) then
  begin
    Volume := FindVolumeByName(Source + Length(VolumesPrefix));
    if Volume = nil then
      Exit(ErrorNotFound);
  end
  else
  begin
    if StartsWith(Source, DevicePrefix) then
      Source := Source + Length(DevicePrefix);
    Device := FindBlockDeviceByName(Source);
    if Device = nil then
      Exit(ErrorNotFound);
    Volume := FindVolumeByDevice(Device);
    if Volume = nil then
    begin
      if DeviceHasLingeringVolume(Device) then
        Exit(ErrorBusy);
      Volume := MountVolumeWithOptions(Device, Options);
      if Volume = nil then
        Exit(ErrorUnsupported);
      Created := True;
    end;
  end;
  if not TypeMatches(@Request.FileSystemType[0], @Volume^.TypeName[0]) then
  begin
    if Created then
      UnmountVolume(Volume, True);
    Volume := nil;
    Exit(ErrorInvalidArgument);
  end;
  if not Created then
    ChangeVolumeOptions(Volume, Options);
  Result := ErrorNone;
end;

function PerformMountVolume(RequestAddress: QWord): Int64;
var
  Request: PAbiMountRequest;
  Options: TMountOptions;
  ErrorPosition: Integer;
  Volume: PVolume;
  Created: Boolean;
  KernelPath: TPathBuffer;
  Error: LongInt;
  Status: TFileSystemStatus;
begin
  if not CallerMaySetAnyAttributes then
    Exit(Failure(ErrorNotPermitted));
  Request := PAbiMountRequest(AllocateKernelMemory(SizeOf(TAbiMountRequest)));
  if Request = nil then
    Exit(Failure(ErrorOutOfMemory));
  Error := CopyFromUser(Request, RequestAddress, SizeOf(TAbiMountRequest));
  if Error = ErrorNone then
  begin
    Request^.Source[AbiMountTextCapacity - 1] := #0;
    Request^.Target[AbiMountTextCapacity - 1] := #0;
    Request^.FileSystemType[AbiTextCapacity - 1] := #0;
    Request^.Options[AbiMountTextCapacity - 1] := #0;
    SetDefaultMountOptions(Options);
    if not ParseMountOptions(@Request^.Options[0], Options, ErrorPosition) then
      Error := ErrorInvalidArgument;
  end;
  if (Error = ErrorNone) and (Request^.Target[0] <> #0) then
    Error := TranslateUserPath(CurrentProcess, @Request^.Target[0], @KernelPath[0], ProcessPathCapacity);
  if Error = ErrorNone then
    Error := VolumeForRequest(Request^, Options, Volume, Created);
  if (Error = ErrorNone) and (Request^.Target[0] <> #0) then
  begin
    Status := MountAtDirectory(Volume, @KernelPath[0]);
    if Status <> StatusSuccess then
    begin
      Error := ErrorFromStatus(Status);
      if Status = StatusNoSpace then
        Error := ErrorBusy; { the mount table is full }
      if Created then
        UnmountVolume(Volume, True);
    end;
  end;
  FreeKernelMemory(Request);
  Result := Failure(Error);
end;

{ --- Unmounting ------------------------------------------------------ }

type
  TWorkingInside = record
    Paths: array[0..1] of TPathBuffer;
    PathCount: Integer;
    Found: Boolean;
  end;
  PWorkingInside = ^TWorkingInside;

function PathIsWithin(Inner, Outer: PChar): Boolean;
var
  OuterLength: PtrUInt;
begin
  OuterLength := TextLength(Outer);
  if TextIsEqual(Outer, '/') then
    Exit(True);
  Result := MemoryIsEqual(Inner, Outer, OuterLength) and
    ((Inner[OuterLength] = #0) or (Inner[OuterLength] = '/'));
end;

{ Registry lock held: is Process's current directory inside one of the
  paths? (Read without the process's lock: a heuristic, as a directory
  changing meanwhile changes the answer anyway.) }
procedure VisitWorkingDirectory(Process: PProcess; Context: Pointer);
var
  Inside: PWorkingInside;
  Directory: TPathBuffer;
  Index: Integer;
begin
  Inside := PWorkingInside(Context);
  if not Process^.IsUserProcess or Inside^.Found then
    Exit;
  if TextIsEqual(@Process^.RootDirectory[0], '/') then
    CopyText(@Directory[0], @Process^.CurrentDirectory[0], ProcessPathCapacity)
  else
  begin
    CopyText(@Directory[0], @Process^.RootDirectory[0], ProcessPathCapacity);
    if not TextIsEqual(@Process^.CurrentDirectory[0], '/') then
      CopyText(@Directory[TextLength(@Directory[0])], @Process^.CurrentDirectory[0],
        ProcessPathCapacity - TextLength(@Directory[0]));
  end;
  for Index := 0 to Inside^.PathCount - 1 do
    if PathIsWithin(@Directory[0], @Inside^.Paths[Index][0]) then
      Inside^.Found := True;
end;

{ True if a program works in the volume: below its mount point or its
  place in /volumes (paths as programs see them). }
function SomeoneWorksIn(Volume: PVolume; MountPoint: PChar): Boolean;
var
  Inside: PWorkingInside;
begin
  Inside := PWorkingInside(AllocateZeroedKernelMemory(SizeOf(TWorkingInside)));
  if Inside = nil then
    Exit(False);
  CopyText(@Inside^.Paths[0][0], VolumesPrefix, ProcessPathCapacity);
  CopyText(@Inside^.Paths[0][Length(VolumesPrefix)], @Volume^.Name[0], ProcessPathCapacity - Length(VolumesPrefix));
  Inside^.PathCount := 1;
  if (MountPoint <> nil) and (MountPoint^ <> #0) then
  begin
    CopyText(@Inside^.Paths[1][0], MountPoint, ProcessPathCapacity);
    Inside^.PathCount := 2;
  end;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@VisitWorkingDirectory, Inside);
  UnlockProcessRegistry;
  Result := Inside^.Found;
  FreeKernelMemory(Inside);
end;

function PerformUnmountVolume(PathAddress: QWord; Flags: QWord): Int64;
var
  UserPath: TPathBuffer;
  Unrooted: TPathBuffer;
  KernelPath: TPathBuffer;
  RelativePath: TPathBuffer;
  Volume: PVolume;
  Error: LongInt;
  Status: TFileSystemStatus;
  Force: Boolean;
begin
  if not CallerMaySetAnyAttributes then
    Exit(Failure(ErrorNotPermitted));
  Force := (Flags and UnmountForce) <> 0;
  Error := CopyStringFromUser(PathAddress, @UserPath[0], ProcessPathCapacity);
  if Error = ErrorNone then
    Error := UnrootedUserPath(CurrentProcess, @UserPath[0], @Unrooted[0], ProcessPathCapacity);
  if Error = ErrorNone then
    Error := TranslateUserPath(CurrentProcess, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := LocatePath(@KernelPath[0], True, Volume, @RelativePath[0], ProcessPathCapacity);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  { Only a volume's root names the volume. }
  if RelativePath[0] <> #0 then
    Exit(Failure(ErrorInvalidArgument));
  if not Force and SomeoneWorksIn(Volume, @Unrooted[0]) then
    Exit(Failure(ErrorBusy));
  Result := Failure(ErrorFromStatus(UnmountVolume(Volume, Force)));
end;

{ --- Listing --------------------------------------------------------- }

procedure AppendText(Destination: PChar; Capacity: PtrUInt; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  CopyText(Destination + Length, Text, Capacity - Length);
end;

{ Where programs see Volume. }
procedure DescribeMountPoint(Volume: PVolume; var Information: TAbiMountInformation);
var
  Top: PVolume;
  Path: TPathBuffer;
begin
  Information.MountPoint[0] := #0;
  if FindVolumeMountPoint(Volume, Top, @Path[0], ProcessPathCapacity) then
  begin
    Information.IsAtDirectory := 1;
    if Top <> SystemVolume then
    begin
      AppendText(@Information.MountPoint[0], AbiMountTextCapacity, VolumesPrefix);
      AppendText(@Information.MountPoint[0], AbiMountTextCapacity, @Top^.Name[0]);
    end;
    AppendText(@Information.MountPoint[0], AbiMountTextCapacity, @Path[0]);
  end
  else if Volume = SystemVolume then
    CopyText(@Information.MountPoint[0], '/', AbiMountTextCapacity)
  else
  begin
    AppendText(@Information.MountPoint[0], AbiMountTextCapacity, VolumesPrefix);
    AppendText(@Information.MountPoint[0], AbiMountTextCapacity, @Volume^.Name[0]);
  end;
end;

function PerformListMounts(Index: QWord; InformationAddress: QWord): Int64;
var
  Volume: PVolume;
  Information: TAbiMountInformation;
begin
  if Index >= QWord(VolumeCount) then
    Exit(0);
  Volume := VolumeAt(Integer(Index));
  if Volume = nil then
    Exit(0);
  FillMemory(@Information, SizeOf(Information), 0);
  CopyText(@Information.Name[0], @Volume^.Name[0], AbiTextCapacity);
  if Volume^.Device <> nil then
  begin
    CopyText(@Information.Source[0], DevicePrefix, AbiTextCapacity);
    AppendText(@Information.Source[0], AbiTextCapacity, @Volume^.Device^.Name[0]);
  end
  else
    CopyText(@Information.Source[0], @Volume^.TypeName[0], AbiTextCapacity);
  CopyText(@Information.FileSystemType[0], @Volume^.TypeName[0], AbiTextCapacity);
  DescribeMountPoint(Volume, Information);
  FormatMountOptions(Volume^.Options, Volume^.Driver^.HasNoOwners, Volume^.Driver^.IsVirtual,
    @Information.Options[0], AbiMountTextCapacity);
  Information.VolumeNumber := Volume^.Number;
  Result := Failure(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
  if Result = 0 then
    Result := 1;
end;

{ --- File times ------------------------------------------------------- }

procedure SetPreciseTime(out Time: TAbiPreciseTime; Seconds: Int64; Nanoseconds: LongWord);
begin
  Time.Seconds := Seconds;
  Time.Nanoseconds := Nanoseconds;
  Time.Reserved := 0;
end;

function PerformGetFileTimes(PathAddress: QWord; Handle: Int64; Flags: QWord; TimesAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Information: TNodeInformation;
  Times: TAbiFileTimes;
  Status: TFileSystemStatus;
  Error: LongInt;
  Process: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
  Found: Boolean;
begin
  if PathAddress <> 0 then
  begin
    Error := FetchKernelPath(PathAddress, KernelPath);
    if Error <> ErrorNone then
      Exit(Failure(Error));
    Status := DescribePath(@KernelPath^[0], (Flags and FileTimesFollowLinks) <> 0, Information);
    FreeKernelMemory(KernelPath);
  end
  else
  begin
    Process := CurrentProcess;
    AcquireMutex(Process^.Lock);
    Found := LookupHandle(Process^.Handles, Handle, Kind, ObjectBody);
    ReleaseMutex(Process^.Lock);
    if not Found then
      Exit(Failure(ErrorBadHandle));
    if Kind <> HandleKindFile then
      Exit(Failure(ErrorUnsupported));
    Status := GetFileInformation(POpenFile(ObjectBody), Information);
  end;
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  FillMemory(@Times, SizeOf(Times), 0);
  SetPreciseTime(Times.Access, Information.AccessTime, Information.AccessNanoseconds);
  SetPreciseTime(Times.Modification, Information.ModificationTime, Information.ModificationNanoseconds);
  SetPreciseTime(Times.Change, Information.ChangeTime, Information.ChangeNanoseconds);
  SetPreciseTime(Times.Birth, Information.BirthTime, Information.BirthNanoseconds);
  if Information.BirthTime <> 0 then
    Times.Flags := FileTimesHasBirthTime;
  Result := Failure(CopyToUser(TimesAddress, @Times, SizeOf(Times)));
end;

end.
