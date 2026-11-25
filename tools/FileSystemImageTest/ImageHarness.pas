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
  Runs the kernel's file system drivers (ext2/3/4, FAT, exFAT) on a disk
  image in memory, for FileSystemImageTest: probe and mount it, walk every
  directory (looking each name up, reading files and symbolic links),
  then, on a writable volume, create, write, shorten, rename and remove a
  few files (and shorten and remove a file named "victim"), sync,
  unmount, and mount and walk once more.

  What comes back is a summary of how it went. The heap stand-in catches
  writes outside allocated blocks, the block cache stand-in catches
  endless loops (EOperationLimit), and the host runtime catches wild
  pointers (SysUtils turns them into exceptions).
}
unit ImageHarness;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  FileSystem.Types;

type
  TImageOutcome = record
    { A driver took the image and mounted it. }
    Mounted: Boolean;
    MountStatus: TFileSystemStatus;
    DriverName: string;
    IsReadOnly: Boolean;
    { The first failing status seen while walking or writing (success if
      none); Corrupted is set when StatusCorrupted was among them. }
    FirstError: TFileSystemStatus;
    SawCorrupted: Boolean;
    NodesVisited: Integer;
    { Damage to the harness itself: a hang, a crash, heap corruption or
      leaked blocks. Empty when there was none. }
    Fault: string;
  end;

{ Image is copied: the drivers write to the copy. }
function RunImage(const Image: TBytes; DoWrites: Boolean; out Outcome: TImageOutcome): Boolean;

implementation

uses
  Runtime.LinkedList,
  Io.BlockDevice,
  Io.BlockCache,
  Memory.KernelHeap,
  FileSystem.Fat,
  FileSystem.ExFat,
  FileSystem.Ext;

const
  SectorSize = 512;
  { A loop on a damaged disk shows up as this many block accesses. }
  OperationsPerImage = 3000000;
  MaximumEntriesPerDirectory = 2000;
  MaximumDepth = 12;
  MaximumNodes = 5000;
  MaximumBytesPerFile = 256 * 1024;

type
  TWalker = record
    Volume: PVolume;
    Outcome: ^TImageOutcome;
    Buffer: array[0..65535] of Byte;
  end;
  PWalker = ^TWalker;

procedure NoteStatus(Walker: PWalker; Status: TFileSystemStatus);
begin
  if (Status = StatusSuccess) or (Status = StatusEndOfDirectory) then
    Exit;
  if Walker^.Outcome^.FirstError = StatusSuccess then
    Walker^.Outcome^.FirstError := Status;
  if Status = StatusCorrupted then
    Walker^.Outcome^.SawCorrupted := True;
end;

procedure ReadWholeFile(Walker: PWalker; Node: PNode);
var
  Offset: QWord;
  BytesRead: QWord;
  Status: TFileSystemStatus;
begin
  Offset := 0;
  while Offset < MaximumBytesPerFile do
  begin
    Status := Walker^.Volume^.Driver^.ReadFile(Node, Offset, @Walker^.Buffer[0], SizeOf(Walker^.Buffer),
      BytesRead);
    NoteStatus(Walker, Status);
    if (Status <> StatusSuccess) or (BytesRead = 0) then
      Exit;
    Offset := Offset + BytesRead;
  end;
end;

procedure ReadLink(Walker: PWalker; Node: PNode);
var
  Target: array[0..1023] of Char;
begin
  if Assigned(Walker^.Volume^.Driver^.ReadSymbolicLink) then
    NoteStatus(Walker, Walker^.Volume^.Driver^.ReadSymbolicLink(Node, @Target[0], SizeOf(Target)));
end;

procedure WalkDirectory(Walker: PWalker; Directory: PNode; Depth: Integer);
var
  Cursor: TDirectoryCursor;
  Entry: TDirectoryEntry;
  Status: TFileSystemStatus;
  Found: PNode;
  Count: Integer;
begin
  Cursor.Position := 0;
  Cursor.Extra := 0;
  Count := 0;
  repeat
    Status := Walker^.Volume^.Driver^.ReadDirectory(Directory, Cursor, Entry);
    NoteStatus(Walker, Status);
    if Status <> StatusSuccess then
      Exit;
    Inc(Count);
    if Walker^.Outcome^.NodesVisited >= MaximumNodes then
      Exit;
    Inc(Walker^.Outcome^.NodesVisited);
    Status := Walker^.Volume^.Driver^.Lookup(Directory, @Entry.Name[0], Found);
    NoteStatus(Walker, Status);
    if Status = StatusSuccess then
    begin
      case Found^.Information.Kind of
        NodeKindFile: ReadWholeFile(Walker, Found);
        NodeKindSymbolicLink: ReadLink(Walker, Found);
        NodeKindDirectory:
          if Depth < MaximumDepth then
            WalkDirectory(Walker, Found, Depth + 1);
      end;
      Walker^.Volume^.Driver^.ReleaseNode(Found);
    end;
  until Count >= MaximumEntriesPerDirectory;
end;

procedure Exercise(Walker: PWalker; Status: TFileSystemStatus);
begin
  NoteStatus(Walker, Status);
end;

{ Creates, writes, shortens, renames and removes a few names. }
procedure ExerciseWriting(Walker: PWalker);
var
  Driver: PFileSystemDriver;
  Root: PNode;
  FileNode: PNode;
  Folder: PNode;
  Inner: PNode;
  Written: QWord;
  Status: TFileSystemStatus;
begin
  Driver := Walker^.Volume^.Driver;
  Root := Walker^.Volume^.RootNode;
  FillChar(Walker^.Buffer, SizeOf(Walker^.Buffer), $5C);

  Status := Driver^.CreateNode(Root, 'probe.dat', NodeKindFile, nil, FileNode);
  Exercise(Walker, Status);
  if Status = StatusSuccess then
  begin
    Exercise(Walker, Driver^.WriteFile(FileNode, 0, @Walker^.Buffer[0], 20000, Written));
    Exercise(Walker, Driver^.WriteFile(FileNode, 70000, @Walker^.Buffer[0], 3000, Written));
    Exercise(Walker, Driver^.SetFileSize(FileNode, 5000));
    Exercise(Walker, Driver^.SetFileSize(FileNode, 9000));
    ReadWholeFile(Walker, FileNode);
    Exercise(Walker, Driver^.RemoveNode(Root, 'probe.dat', FileNode));
    Driver^.ReleaseNode(FileNode);
  end;

  Status := Driver^.CreateNode(Root, 'probe.dir', NodeKindDirectory, nil, Folder);
  Exercise(Walker, Status);
  if Status = StatusSuccess then
  begin
    Status := Driver^.CreateNode(Folder, 'inner', NodeKindFile, nil, Inner);
    Exercise(Walker, Status);
    if Status = StatusSuccess then
    begin
      Status := Driver^.RenameNode(Folder, 'inner', Inner, Root, 'moved');
      Exercise(Walker, Status);
      if Status = StatusSuccess then
        Exercise(Walker, Driver^.RemoveNode(Root, 'moved', Inner))
      else
        Exercise(Walker, Driver^.RemoveNode(Folder, 'inner', Inner));
      Driver^.ReleaseNode(Inner);
    end;
    Exercise(Walker, Driver^.RemoveNode(Root, 'probe.dir', Folder));
    Driver^.ReleaseNode(Folder);
  end;
  { An existing file named "victim" (damaged on purpose by some images)
    is shortened and removed: the paths that load its whole block map. }
  if Driver^.Lookup(Root, 'victim', FileNode) = StatusSuccess then
  begin
    if FileNode^.Information.Kind = NodeKindFile then
    begin
      Exercise(Walker, Driver^.SetFileSize(FileNode, 1000));
      Exercise(Walker, Driver^.RemoveNode(Root, 'victim', FileNode));
    end;
    Driver^.ReleaseNode(FileNode);
  end;
  Exercise(Walker, Driver^.Sync(Walker^.Volume));
end;

function MountWithFirstDriver(Volume: PVolume; var Outcome: TImageOutcome): Boolean;
var
  Drivers: array[0..2] of PFileSystemDriver;
  Index: Integer;
begin
  Drivers[0] := FatFileSystemDriver;
  Drivers[1] := ExFatFileSystemDriver;
  Drivers[2] := ExtFileSystemDriver;
  for Index := 0 to High(Drivers) do
    if Drivers[Index]^.Probe(Volume^.Device) then
    begin
      Volume^.Driver := Drivers[Index];
      Outcome.DriverName := Drivers[Index]^.Name;
      Outcome.MountStatus := Drivers[Index]^.Mount(Volume);
      Exit(Outcome.MountStatus = StatusSuccess);
    end;
  Outcome.MountStatus := StatusUnsupported;
  Result := False;
end;

procedure MountAndWalk(Volume: PVolume; DoWrites: Boolean; var Outcome: TImageOutcome);
var
  Walker: PWalker;
begin
  Outcome.Mounted := MountWithFirstDriver(Volume, Outcome);
  if not Outcome.Mounted then
    Exit;
  Outcome.IsReadOnly := Volume^.IsReadOnly;
  New(Walker);
  try
    Walker^.Volume := Volume;
    Walker^.Outcome := @Outcome;
    WalkDirectory(Walker, Volume^.RootNode, 0);
    if DoWrites and not Volume^.IsReadOnly and DriverSupportsWriting(Volume^.Driver) then
    begin
      ExerciseWriting(Walker);
      WalkDirectory(Walker, Volume^.RootNode, 0);
    end;
  finally
    Dispose(Walker);
  end;
  Volume^.Driver^.Unmount(Volume);
end;

{ Where the exception being handled came from (with line numbers when
  built with -gl). }
function DescribeWhere: string;
var
  Frames: PCodePointer;
  Index: Integer;
begin
  Result := ' at' + BackTraceStrFunc(ExceptAddr);
  Frames := ExceptFrames;
  for Index := 0 to ExceptFrameCount - 1 do
  begin
    if Index >= 4 then
      Break;
    Result := Result + ' <' + BackTraceStrFunc(Frames[Index]);
  end;
end;

procedure MountAgain(Volume: PVolume; var Outcome: TImageOutcome);
var
  Again: TImageOutcome;
begin
  Again := Default(TImageOutcome);
  Again.FirstError := StatusSuccess;
  Volume^.IsReadOnly := False;
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
  MountAndWalk(Volume, False, Again);
  if not Again.Mounted then
  begin
    Outcome.Mounted := False;
    Outcome.MountStatus := Again.MountStatus;
  end;
  Outcome.IsReadOnly := Outcome.IsReadOnly or Again.IsReadOnly;
  if Outcome.FirstError = StatusSuccess then
    Outcome.FirstError := Again.FirstError;
  Outcome.SawCorrupted := Outcome.SawCorrupted or Again.SawCorrupted;
end;

function RunImage(const Image: TBytes; DoWrites: Boolean; out Outcome: TImageOutcome): Boolean;
var
  Device: TBlockDevice;
  Volume: TVolume;
  Leaked: Integer;
begin
  Outcome := Default(TImageOutcome);
  Outcome.FirstError := StatusSuccess;
  FillChar(Device, SizeOf(Device), 0);
  Device.BlockSize := SectorSize;
  Device.BlockCount := Length(Image) div SectorSize;
  GetMem(Device.Image, Length(Image) + 1);
  if Length(Image) > 0 then
    Move(Image[0], Device.Image^, Length(Image));
  FillChar(Volume, SizeOf(Volume), 0);
  Volume.Device := @Device;
  Volume.Name := 'image';
  Volume.CanWrite := True;
  InitializeListHead(Volume.NodeCache);

  OperationCount := 0;
  OperationLimit := OperationsPerImage;
  try
    MountAndWalk(@Volume, DoWrites, Outcome);
    { What the first mount wrote must leave a volume that mounts again
      the same way (an orphan list that freed the journal would not). }
    if Outcome.Mounted and not Outcome.IsReadOnly then
      MountAgain(@Volume, Outcome);
  except
    on EOperationLimit do
      Outcome.Fault := 'hang (more than ' + IntToStr(OperationsPerImage) + ' block accesses)';
    on Failure: Exception do
      Outcome.Fault := 'crash: ' + Failure.ClassName + ': ' + Failure.Message + DescribeWhere;
  end;
  OperationLimit := 0;

  if CheckKernelHeap('after the image') > 0 then
    Outcome.Fault := Outcome.Fault + ' heap corruption';
  Leaked := ForgetKernelHeap;
  if (Outcome.Fault = '') and (Leaked > 0) then
    Outcome.Fault := IntToStr(Leaked) + ' kernel heap blocks leaked';
  FreeMem(Device.Image);
  Result := Outcome.Fault = '';
end;

end.
