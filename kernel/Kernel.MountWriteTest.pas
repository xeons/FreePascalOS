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
  Mount point checks of the file system write test (kernel option
  fstest, Kernel.FileSystemWriteTest): a memory volume mounted on a
  directory of a writable test volume, resolved into and back out of
  (through "..", symbolic links with ".." and absolute targets),
  renames and hard links across refused (StatusCrossesVolumes), the
  mount point kept from being removed or renamed, and the volume
  unmounted only once nothing of it is open. A failure panics, as in
  the rest of the write test.
}
unit Kernel.MountWriteTest;

{$mode objfpc}

interface

uses
  FileSystem.Types;

procedure RunMountWriteTests(TestVolume: PVolume);
{ Removes everything below RelativePath ("" for the root) on Volume. }
function RemoveTreeForTest(Volume: PVolume; RelativePath: PChar): TFileSystemStatus;

implementation

uses
  Runtime.Text,
  Kernel.Panic,
  FileSystem.MountOptions,
  FileSystem.Files,
  FileSystem.Volumes,
  FileSystem.Mounts,
  Debug.Output,
  Debug.FramebufferConsole;

const
  PathCapacity = 512;

type
  TPath = array[0..PathCapacity - 1] of Char;

procedure Fail(Description: PChar; Status: TFileSystemStatus);
begin
  BeginKernelPanic(PanicAssertionFailed, 'mount write test failed');
  DebugWrite('  ');
  DebugWrite(Description);
  DebugWrite(': ');
  DebugWriteLine(FileSystemStatusText(Status));
  FinishKernelPanic;
end;

procedure Expect(Status, Expected: TFileSystemStatus; Description: PChar);
begin
  if Status <> Expected then
    Fail(Description, Status);
end;

procedure Check(Condition: Boolean; Description: PChar);
begin
  if not Condition then
    Fail(Description, StatusSuccess);
end;

{ Path := "/" + Volume's name + "/" + Relative. }
procedure VolumePath(Volume: PVolume; Relative: PChar; out Path: TPath);
var
  Length: PtrUInt;
begin
  Path[0] := '/';
  CopyText(@Path[1], @Volume^.Name[0], PathCapacity - 1);
  if Relative^ = #0 then
    Exit;
  Length := TextLength(@Path[0]);
  Path[Length] := '/';
  CopyText(@Path[Length + 1], Relative, PathCapacity - Length - 1);
end;

function WriteText(Path, Text: PChar): TFileSystemStatus;
var
  OpenedFile: POpenFile;
  Written: QWord;
begin
  Result := OpenFile(Path, OpenForWriting or OpenCreate or OpenTruncate, OpenedFile);
  if Result <> StatusSuccess then
    Exit;
  Result := WriteToFile(OpenedFile, Text, TextLength(Text), Written);
  CloseFile(OpenedFile);
end;

function ReadsAs(Path, Expected: PChar): Boolean;
var
  OpenedFile: POpenFile;
  Buffer: array[0..63] of Char;
  BytesRead: QWord;
begin
  Result := False;
  if OpenPath(Path, OpenedFile) <> StatusSuccess then
    Exit;
  if ReadFromFile(OpenedFile, @Buffer[0], SizeOf(Buffer) - 1, BytesRead) = StatusSuccess then
  begin
    Buffer[BytesRead] := #0;
    Result := TextIsEqual(@Buffer[0], Expected);
  end;
  CloseFile(OpenedFile);
end;

function VolumeNumberOf(Path: PChar): LongWord;
var
  Information: TNodeInformation;
begin
  Result := 0;
  if GetPathInformation(Path, Information) = StatusSuccess then
    Result := Information.VolumeNumber;
end;

function RemoveTreeForTest(Volume: PVolume; RelativePath: PChar): TFileSystemStatus;
var
  Directory: TPath;
  Child: TPath;
  ChildRelative: TPath;
  OpenedFile: POpenFile;
  Entry: TDirectoryEntry;
  Length: PtrUInt;
begin
  VolumePath(Volume, RelativePath, Directory);
  repeat
    Result := OpenPath(@Directory[0], OpenedFile);
    if Result <> StatusSuccess then
      Exit;
    Result := ReadDirectoryEntry(OpenedFile, Entry);
    CloseFile(OpenedFile);
    if Result = StatusEndOfDirectory then
      Exit(StatusSuccess);
    if Result <> StatusSuccess then
      Exit;
    CopyText(@ChildRelative[0], RelativePath, PathCapacity);
    Length := TextLength(@ChildRelative[0]);
    if Length > 0 then
    begin
      ChildRelative[Length] := '/';
      Inc(Length);
    end;
    CopyText(@ChildRelative[Length], @Entry.Name[0], PathCapacity - Length);
    if Entry.Kind = NodeKindDirectory then
    begin
      Result := RemoveTreeForTest(Volume, @ChildRelative[0]);
      if Result <> StatusSuccess then
        Exit;
    end;
    VolumePath(Volume, @ChildRelative[0], Child);
    Result := RemovePath(@Child[0]);
  until Result <> StatusSuccess;
end;

procedure ReportPassed(TestVolume, Memory: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite('mounts: ');
  DebugWrite(@Memory^.Name[0]);
  DebugWrite(' at a folder of ');
  DebugWrite(@TestVolume^.Name[0]);
  DebugWrite(': ');
  DebugSetColor(ColorGreen);
  DebugWrite('passed');
  DebugResetColor;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure RunMountWriteTests(TestVolume: PVolume);
var
  Options: TMountOptions;
  Memory: PVolume;
  MountPoint: TPath;
  Inside: TPath;
  InsideDirect: TPath;
  Outside: TPath;
  Other: TPath;
  OpenedFile: POpenFile;
  Found: PVolume;
  Relative: TPath;
  Information: TNodeInformation;
begin
  SetDefaultMountOptions(Options);
  Options.SizeLimitBytes := 1024 * 1024;
  Options.SizePercent := 0;
  Memory := MountMemoryVolume(Options);
  Check(Memory <> nil, 'making a memory volume');

  VolumePath(TestVolume, 'mount-point', MountPoint);
  Expect(CreateDirectory(@MountPoint[0]), StatusSuccess, 'making the mount point');
  Expect(MountAtDirectory(Memory, @MountPoint[0]), StatusSuccess, 'mounting at a folder');
  Expect(MountAtDirectory(Memory, @MountPoint[0]), StatusSuccess, 'mounting at the same folder again');
  VolumePath(TestVolume, 'fstype.txt', Other);
  Expect(MountAtDirectory(Memory, @Other[0]), StatusNotADirectory, 'mounting on a file');

  { Into the mounted volume and back out. }
  VolumePath(TestVolume, 'mount-point/inside.txt', Inside);
  Expect(WriteText(@Inside[0], 'inside'), StatusSuccess, 'writing through the mount point');
  VolumePath(Memory, 'inside.txt', InsideDirect);
  Check(ReadsAs(@InsideDirect[0], 'inside'), 'the file is on the mounted volume');
  Check(VolumeNumberOf(@Inside[0]) = Memory^.Number, 'paths below the mount point are on it');
  Check(VolumeNumberOf(@MountPoint[0]) = Memory^.Number, 'the mount point is the mounted root');
  Expect(LocatePath(@Inside[0], True, Found, @Relative[0], PathCapacity), StatusSuccess, 'locating');
  Check((Found = Memory) and TextIsEqual(@Relative[0], '/inside.txt'), 'located on the mounted volume');
  VolumePath(TestVolume, 'mount-point/../fstype.txt', Other);
  Check(VolumeNumberOf(@Other[0]) = TestVolume^.Number, '".." leads back out');

  VolumePath(Memory, 'up', Other);
  Expect(CreateSymbolicLink(@Other[0], '../fstype.txt'), StatusSuccess, 'a link with ".."');
  VolumePath(TestVolume, 'mount-point/up', Other);
  Check(VolumeNumberOf(@Other[0]) = TestVolume^.Number, 'a link with ".." leads out of the mount');
  VolumePath(Memory, 'absolute', Other);
  Expect(CreateSymbolicLink(@Other[0], '/fstype.txt'), StatusSuccess, 'an absolute link');
  VolumePath(TestVolume, 'mount-point/absolute', Other);
  Check(VolumeNumberOf(@Other[0]) = TestVolume^.Number, 'an absolute link starts at the top volume');

  { Two volumes are never joined. }
  VolumePath(TestVolume, 'moved.txt', Outside);
  Expect(RenamePath(@Inside[0], @Outside[0]), StatusCrossesVolumes, 'renaming out of the mount');
  Expect(CreateHardLink(@Inside[0], @Outside[0]), StatusCrossesVolumes, 'a hard link across');
  VolumePath(TestVolume, 'renamed-point', Other);
  Expect(RenamePath(@MountPoint[0], @Other[0]), StatusInUse, 'renaming the mount point');
  Expect(RemovePath(@MountPoint[0]), StatusInUse, 'removing the mount point');
  Expect(UnmountVolume(TestVolume, False), StatusInUse, 'unmounting a volume something is mounted on');

  { Unmounting. }
  Expect(OpenPath(@Inside[0], OpenedFile), StatusSuccess, 'opening a file on the mount');
  Expect(UnmountVolume(Memory, False), StatusInUse, 'unmounting while a file is open');
  CloseFile(OpenedFile);
  Expect(UnmountVolume(Memory, False), StatusSuccess, 'unmounting when idle');
  Check(Memory^.IsUnmounted, 'the memory volume is given back');
  Expect(GetPathInformation(@Inside[0], Information), StatusNotFound, 'the folder below shows again');
  Expect(RemovePath(@MountPoint[0]), StatusSuccess, 'removing the former mount point');
  ReportPassed(TestVolume, Memory);
end;

end.
