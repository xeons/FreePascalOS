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
  The memory file system (tmpfs): a volume that lives in RAM only.

  It has files, folders, symbolic links, named pipes and hard links,
  Unix owners and permissions, and the four times to the nanosecond
  (made, modified, changed, accessed; reading does not move the access
  time, as with "noatime"). Contents are kept in pages from the
  physical page allocator (FileSystem.Memory.Storage), at most the
  size= mount option (bytes or a share of the RAM, half by default);
  the root folder gets the mode= option (rwxrwxrwt by default). Pages
  go back as soon as a file is shortened or removed (or, if it was open,
  closed for the last time), and everything goes back on unmounting.

  Memory volumes are not probed on devices: FileSystem.Volumes makes
  them (MountMemoryVolume), named tmpfs1, tmpfs2 and so on, and the
  boot's /etc/fstab mounts one on /tmp.
}
unit FileSystem.Memory;

{$mode objfpc}

interface

uses
  FileSystem.Types;

function MemoryFileSystemDriver: PFileSystemDriver;

implementation

uses
  Runtime.Text,
  Runtime.LinkedList,
  Memory.KernelHeap,
  Memory.Layout,
  Memory.PhysicalPages,
  Io.BlockDevice,
  FileSystem.MountOptions,
  FileSystem.Memory.Storage,
  FileSystem.Memory.Nodes;

const
  MemoryTypeName = 'tmpfs';
  { Never less than this, whatever size= says. }
  MinimumPageLimit = 16;

var
  Driver: TFileSystemDriver;

function MemoryProbe(Device: PBlockDevice): Boolean;
begin
  Result := False;
end;

function PageLimitFor(const Options: TMountOptions): QWord;
var
  Statistics: TPhysicalMemoryStatistics;
begin
  if Options.SizePercent <> 0 then
  begin
    GetPhysicalMemoryStatistics(Statistics);
    Result := Statistics.TotalUsablePages * Options.SizePercent div 100;
  end
  else
    Result := (Options.SizeLimitBytes + PageSize - 1) shr PageShift;
  if Result < MinimumPageLimit then
    Result := MinimumPageLimit;
end;

function MemoryMount(Volume: PVolume): TFileSystemStatus;
var
  Data: PMemoryVolume;
begin
  Data := PMemoryVolume(AllocateZeroedKernelMemory(SizeOf(TMemoryVolume)));
  if Data = nil then
    Exit(StatusOutOfMemory);
  InitializeListHead(Data^.Inodes);
  Data^.NextNodeNumber := 1;
  Data^.Budget.PageLimit := PageLimitFor(Volume^.Options);
  Data^.Root := CreateInode(Data, NodeKindDirectory);
  if Data^.Root = nil then
  begin
    FreeKernelMemory(Data);
    Exit(StatusOutOfMemory);
  end;
  Data^.Root^.Information.Mode := Volume^.Options.RootMode and $FFF;
  Volume^.DriverData := Data;
  Volume^.RootNode := CreateNodeFor(Volume, Data^.Root);
  if Volume^.RootNode = nil then
  begin
    DestroyInode(Data, Data^.Root);
    FreeKernelMemory(Data);
    Volume^.DriverData := nil;
    Exit(StatusOutOfMemory);
  end;
  CopyText(@Volume^.TypeName[0], MemoryTypeName, FileSystemTypeNameLength);
  Volume^.VolumeLabel[0] := #0;
  Volume^.TotalBytes := Data^.Budget.PageLimit * PageSize;
  Result := StatusSuccess;
end;

procedure MemoryUnmount(Volume: PVolume);
var
  Data: PMemoryVolume;
begin
  Data := MemoryVolumeOf(Volume);
  if Data <> nil then
  begin
    while Data^.Inodes.Next <> @Data^.Inodes do
      DestroyInode(Data, InodeFromVolumeLink(Data^.Inodes.Next));
    FreeKernelMemory(Data);
  end;
  FreeKernelMemory(Volume^.RootNode);
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
end;

function MemoryLookup(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  Entry: PMemoryEntry;
begin
  Found := nil;
  Entry := FindEntry(InodeOf(Directory), Name);
  if Entry = nil then
    Exit(StatusNotFound);
  Found := CreateNodeFor(Directory^.Volume, Entry^.Inode);
  if Found = nil then
    Exit(StatusOutOfMemory);
  Result := StatusSuccess;
end;

function MemoryReadDirectory(Directory: PNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
var
  Found: PMemoryEntry;
begin
  Found := EntryAfter(InodeOf(Directory), Cursor.Position);
  if Found = nil then
    Exit(StatusEndOfDirectory);
  Cursor.Position := Found^.Serial;
  CopyText(@Entry.Name[0], Found^.Name, MaximumNameBytes);
  Entry.Kind := Found^.Inode^.Information.Kind;
  Entry.NodeNumber := Found^.Inode^.Information.NodeNumber;
  Result := StatusSuccess;
end;

function MemoryReadFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  Result := ReadStorage(Inode^.Storage, Inode^.Information.SizeInBytes, Offset, Buffer, ByteCount, BytesRead);
end;

function MemoryReadSymbolicLink(Node: PNode; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  if Inode^.LinkTarget = nil then
    Exit(StatusInvalidPath);
  if TextLength(Inode^.LinkTarget) >= Capacity then
    Exit(StatusNameTooLong);
  CopyText(Target, Inode^.LinkTarget, Capacity);
  Result := StatusSuccess;
end;

procedure MemoryReleaseNode(Node: PNode);
var
  Inode: PMemoryInode;
  Data: PMemoryVolume;
begin
  Inode := InodeOf(Node);
  Data := MemoryVolumeOf(Node^.Volume);
  Dec(Inode^.NodeCount);
  if Data <> nil then
    FreeInodeIfUnused(Data, Inode);
  FreeKernelMemory(Node);
end;

function MemoryCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
var
  Data: PMemoryVolume;
  Parent: PMemoryInode;
  Inode: PMemoryInode;
  TargetLength: PtrUInt;
begin
  Created := nil;
  Data := MemoryVolumeOf(Directory^.Volume);
  Parent := InodeOf(Directory);
  Inode := CreateInode(Data, Kind);
  if Inode = nil then
    Exit(StatusOutOfMemory);
  if Kind = NodeKindSymbolicLink then
  begin
    TargetLength := TextLength(LinkTarget);
    Inode^.LinkTarget := PChar(AllocateKernelMemory(TargetLength + 1));
    if Inode^.LinkTarget = nil then
    begin
      DestroyInode(Data, Inode);
      Exit(StatusOutOfMemory);
    end;
    CopyText(Inode^.LinkTarget, LinkTarget, TargetLength + 1);
    Inode^.Information.SizeInBytes := TargetLength;
  end;
  if not AddEntry(Data, Parent, Name, Inode) then
  begin
    DestroyInode(Data, Inode);
    Exit(StatusOutOfMemory);
  end;
  Created := CreateNodeFor(Directory^.Volume, Inode);
  if Created = nil then
  begin
    RemoveEntry(Parent, Name);
    DestroyInode(Data, Inode);
    Exit(StatusOutOfMemory);
  end;
  if Kind = NodeKindDirectory then
    Inc(Parent^.Information.LinkCount); { its ".." }
  StampInode(Parent, True);
  RefreshNode(Directory);
  Result := StatusSuccess;
end;

function MemoryWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  Result := WriteStorage(Inode^.Storage, @MemoryVolumeOf(Node^.Volume)^.Budget, Offset, Buffer, ByteCount,
    BytesWritten);
  if (Result = StatusNoSpace) and (BytesWritten > 0) then
    Result := StatusSuccess; { a short write }
  if Offset + BytesWritten > Inode^.Information.SizeInBytes then
    Inode^.Information.SizeInBytes := Offset + BytesWritten;
  if BytesWritten > 0 then
    StampInode(Inode, True);
  RefreshNode(Node);
end;

function MemorySetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  if NewSize < Inode^.Information.SizeInBytes then
    TruncateStorage(Inode^.Storage, @MemoryVolumeOf(Node^.Volume)^.Budget, NewSize);
  Inode^.Information.SizeInBytes := NewSize;
  StampInode(Inode, True);
  RefreshNode(Node);
  Result := StatusSuccess;
end;

{ Takes the name Name of Node out of Directory. }
function Unlink(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  Parent: PMemoryInode;
  Inode: PMemoryInode;
begin
  Parent := InodeOf(Directory);
  Inode := InodeOf(Node);
  if (Inode^.Information.Kind = NodeKindDirectory) and (Inode^.EntryCount > 0) then
    Exit(StatusDirectoryNotEmpty);
  RemoveEntry(Parent, Name);
  if Inode^.Information.Kind = NodeKindDirectory then
  begin
    Inode^.Information.LinkCount := 0;
    Dec(Parent^.Information.LinkCount);
  end
  else
    Dec(Inode^.Information.LinkCount);
  StampInode(Inode, False);
  StampInode(Parent, True);
  RefreshNode(Directory);
  RefreshNode(Node);
  Result := StatusSuccess;
end;

function MemoryRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  Result := Unlink(Directory, Name, Node);
end;

function MemoryRemoveOpenNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  Result := Unlink(Directory, Name, Node);
  if (Result = StatusSuccess) and (InodeOf(Node)^.Information.LinkCount = 0) then
    Node^.RemovalPending := True;
end;

function MemoryFinishRemoval(Node: PNode): TFileSystemStatus;
begin
  { The pages go with the inode, when its last node is released. }
  Result := StatusSuccess;
end;

function MemoryRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
var
  Data: PMemoryVolume;
  Source: PMemoryInode;
  Target: PMemoryInode;
  Inode: PMemoryInode;
begin
  Data := MemoryVolumeOf(Node^.Volume);
  Source := InodeOf(SourceDirectory);
  Target := InodeOf(TargetDirectory);
  Inode := InodeOf(Node);
  if not AddEntry(Data, Target, TargetName, Inode) then
    Exit(StatusOutOfMemory);
  { Names are compared exactly, so the old name is another entry. }
  RemoveEntry(Source, SourceName);
  if (Inode^.Information.Kind = NodeKindDirectory) and (Source <> Target) then
  begin
    Dec(Source^.Information.LinkCount);
    Inc(Target^.Information.LinkCount);
  end;
  StampInode(Inode, False);
  StampInode(Source, True);
  StampInode(Target, True);
  RefreshNode(SourceDirectory);
  RefreshNode(TargetDirectory);
  RefreshNode(Node);
  Result := StatusSuccess;
end;

function MemorySync(Volume: PVolume): TFileSystemStatus;
begin
  Result := StatusSuccess;
end;

function MemorySetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  if (Changes.Fields and AttributeChangeMode) <> 0 then
    Inode^.Information.Mode := Changes.Mode and $FFF;
  if (Changes.Fields and AttributeChangeOwner) <> 0 then
    Inode^.Information.OwnerId := Changes.OwnerId;
  if (Changes.Fields and AttributeChangeGroup) <> 0 then
    Inode^.Information.GroupId := Changes.GroupId;
  if (Changes.Fields and AttributeChangeModificationTime) <> 0 then
  begin
    Inode^.Information.ModificationTime := Changes.ModificationTime;
    Inode^.Information.ModificationNanoseconds := 0;
    if (Changes.Fields and AttributeChangeNanoseconds) <> 0 then
      Inode^.Information.ModificationNanoseconds := Changes.ModificationNanoseconds;
  end;
  if (Changes.Fields and AttributeChangeAccessTime) <> 0 then
  begin
    Inode^.Information.AccessTime := Changes.AccessTime;
    Inode^.Information.AccessNanoseconds := 0;
    if (Changes.Fields and AttributeChangeNanoseconds) <> 0 then
      Inode^.Information.AccessNanoseconds := Changes.AccessNanoseconds;
  end;
  StampInode(Inode, False);
  RefreshNode(Node);
  Result := StatusSuccess;
end;

function MemoryCreateHardLink(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  if not AddEntry(MemoryVolumeOf(Node^.Volume), InodeOf(Directory), Name, Inode) then
    Exit(StatusOutOfMemory);
  Inc(Inode^.Information.LinkCount);
  StampInode(Inode, False);
  StampInode(InodeOf(Directory), True);
  RefreshNode(Directory);
  RefreshNode(Node);
  Result := StatusSuccess;
end;

function MemoryGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;
var
  Data: PMemoryVolume;
  Statistics: TPhysicalMemoryStatistics;
  FreePages: QWord;
begin
  Data := MemoryVolumeOf(Volume);
  FreePages := 0;
  if Data^.Budget.PageLimit > Data^.Budget.PagesUsed then
    FreePages := Data^.Budget.PageLimit - Data^.Budget.PagesUsed;
  GetPhysicalMemoryStatistics(Statistics);
  if FreePages > Statistics.FreePages then
    FreePages := Statistics.FreePages;
  FreeBytes := FreePages * PageSize;
  Result := StatusSuccess;
end;

function MemoryFileSystemDriver: PFileSystemDriver;
begin
  Driver.Name := 'tmpfs';
  Driver.Probe := @MemoryProbe;
  Driver.Mount := @MemoryMount;
  Driver.Unmount := @MemoryUnmount;
  Driver.Lookup := @MemoryLookup;
  Driver.ReadDirectory := @MemoryReadDirectory;
  Driver.ReadFile := @MemoryReadFile;
  Driver.ReadSymbolicLink := @MemoryReadSymbolicLink;
  Driver.ReleaseNode := @MemoryReleaseNode;
  Driver.CreateNode := @MemoryCreateNode;
  Driver.WriteFile := @MemoryWriteFile;
  Driver.SetFileSize := @MemorySetFileSize;
  Driver.RemoveNode := @MemoryRemoveNode;
  Driver.RenameNode := @MemoryRenameNode;
  Driver.Sync := @MemorySync;
  Driver.SetAttributes := @MemorySetAttributes;
  Driver.CreateHardLink := @MemoryCreateHardLink;
  Driver.GetFreeSpace := @MemoryGetFreeSpace;
  Driver.RemoveOpenNode := @MemoryRemoveOpenNode;
  Driver.FinishRemoval := @MemoryFinishRemoval;
  Driver.IsVirtual := True;
  Result := @Driver;
end;

end.
