{
  Write support for ext2, ext3 and ext4.

  Changes are written in place without using the journal (the volume is
  only mounted for writing when its journal is clean, so it stays clean).
  Every change keeps the metadata consistent as e2fsck sees it: bitmaps,
  free counters in the group descriptors and superblock, link counts,
  block counts and, on ext4, all metadata checksums.

  Files are created with extents on volumes that have the extents
  feature, and with block pointers otherwise. Writing past the end of a
  file leaves a hole, which reads back as zeros.
}
unit FileSystem.Ext.Write;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExtCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
function ExtWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
function ExtSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
function ExtRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
function ExtRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
function ExtSync(Volume: PVolume): TFileSystemStatus;

{ True for symbolic links whose target is stored in the inode itself. }
function IsFastSymbolicLink(Node: PNode): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Clock,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume,
  FileSystem.Ext.Blocks,
  FileSystem.Ext.Directories;

const
  PermissionsFile = $1A4;          { rw-r--r-- }
  PermissionsDirectory = $1ED;     { rwxr-xr-x }
  PermissionsSymbolicLink = $1FF;  { rwxrwxrwx }

var
  NextGeneration: LongWord = 0;

function FileTypeOf(Kind: TNodeKind): Byte;
begin
  case Kind of
    NodeKindFile: Result := FileTypeRegular;
    NodeKindDirectory: Result := FileTypeDirectory;
    NodeKindSymbolicLink: Result := FileTypeSymbolicLink;
  else
    Result := FileTypeUnknown;
  end;
end;

function IsFastSymbolicLink(Node: PNode): Boolean;
var
  ExtNode: PExtNode;
  Ext: PExtVolume;
  Inode: PInode;
  ExtendedAttributeBlocks: LongWord;
begin
  ExtNode := PExtNode(Node);
  Ext := ExtVolumeOf(Node);
  Inode := InodeRecord(ExtNode);
  if (Inode^.Mode and ModeTypeMask) <> ModeTypeSymbolicLink then
    Exit(False);
  if (Inode^.Flags and (InodeFlagExtents or InodeFlagInlineData)) <> 0 then
    Exit(False);
  if InodeSize(Inode^) >= InlineDataCapacity then
    Exit(False);
  ExtendedAttributeBlocks := 0;
  if Inode^.FileAclLow <> 0 then
    ExtendedAttributeBlocks := LongWord(Ext^.BlockSize div 512);
  Result := Inode^.BlocksLow = ExtendedAttributeBlocks;
end;

procedure StampTimes(Node: PExtNode; Modified: Boolean);
var
  Now: LongWord;
begin
  Now := LongWord(CurrentWallClockTime);
  InodeRecord(Node)^.ChangeTime := Now;
  if Modified then
    InodeRecord(Node)^.ModificationTime := Now;
end;

{ Zeroes the bytes after the end of file in its last block, so growing
  the file later cannot expose old data. }
function ZeroTailOfLastBlock(Node: PExtNode; FileSize: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  BytesIntoBlock: QWord;
  PhysicalBlock: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  BytesIntoBlock := FileSize mod Ext^.BlockSize;
  if BytesIntoBlock = 0 then
    Exit(StatusSuccess);
  Result := MapLogicalBlock(Node, LongWord(FileSize div Ext^.BlockSize), PhysicalBlock);
  if (Result <> StatusSuccess) or (PhysicalBlock = 0) then
    Exit;
  if not VolumeWriteZeros(Node^.Common.Volume, PhysicalBlock * Ext^.BlockSize + BytesIntoBlock,
    Ext^.BlockSize - BytesIntoBlock) then
    Result := StatusIoError;
end;

{ --- Creating -------------------------------------------------------- }

procedure InitializeInode(Node: PExtNode; Kind: TNodeKind);
var
  Ext: PExtVolume;
  Inode: PInode;
  Now: LongWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Inode := InodeRecord(Node);
  FillMemory(@Node^.InodeBytes[0], Ext^.InodeSize, 0);
  Now := LongWord(CurrentWallClockTime);

  case Kind of
    NodeKindDirectory:
      begin
        Inode^.Mode := ModeTypeDirectory or PermissionsDirectory;
        Inode^.LinksCount := 2; { its name in the parent, and "." }
      end;
    NodeKindSymbolicLink:
      begin
        Inode^.Mode := ModeTypeSymbolicLink or PermissionsSymbolicLink;
        Inode^.LinksCount := 1;
      end;
  else
    begin
      Inode^.Mode := ModeTypeRegular or PermissionsFile;
      Inode^.LinksCount := 1;
    end;
  end;
  Inode^.AccessTime := Now;
  Inode^.ChangeTime := Now;
  Inode^.ModificationTime := Now;

  if NextGeneration = 0 then
    NextGeneration := Now;
  Inc(NextGeneration);
  Inode^.Generation := NextGeneration;

  if Ext^.InodeSize > GoodOldInodeSize then
  begin
    PWord(@Node^.InodeBytes[InodeExtraSizeOffset])^ := InodeExtraFieldsSize;
    PLongWord(@Node^.InodeBytes[InodeCreationTimeOffset])^ := Now;
  end;

  { Fast symbolic links keep their target where the block map would be. }
  if HasIncompatibleFeature(Ext, IncompatibleExtents) and (Kind <> NodeKindSymbolicLink) then
    InitializeEmptyExtentTree(Node);
end;

function WriteLinkTarget(Node: PExtNode; LinkTarget: PChar): TFileSystemStatus;
var
  Ext: PExtVolume;
  TargetLength: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  TargetLength := TextLength(LinkTarget);
  if TargetLength < InlineDataCapacity then
  begin
    CopyMemory(@InodeRecord(Node)^.Block[0], LinkTarget, TargetLength);
    SetInodeSize(InodeRecord(Node)^, TargetLength);
    Exit(StatusSuccess);
  end;

  if TargetLength > Ext^.BlockSize - 1 then
    Exit(StatusNameTooLong);
  if HasIncompatibleFeature(Ext, IncompatibleExtents) then
    InitializeEmptyExtentTree(Node);
  Result := AllocateBlockRange(Node, 0, 1);
  if Result = StatusSuccess then
    Result := WriteNodeData(Node, 0, TargetLength, PByte(LinkTarget));
  SetInodeSize(InodeRecord(Node)^, TargetLength);
end;

{ Gives back everything a half created or deleted inode owns. }
procedure DiscardInode(Node: PExtNode; IsDirectory: Boolean);
begin
  if not IsFastSymbolicLink(@Node^.Common) then
    ReleaseBlocksFrom(Node, 0);
  InodeRecord(Node)^.LinksCount := 0;
  InodeRecord(Node)^.DeletionTime := LongWord(CurrentWallClockTime);
  SetInodeSize(InodeRecord(Node)^, 0);
  WriteNodeInode(Node);
  FreeInode(Node^.Common.Volume, Node^.InodeNumber, IsDirectory);
end;

function ExtCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
var
  Ext: PExtVolume;
  Parent: PExtNode;
  Node: PExtNode;
  InodeNumber: LongWord;
  IsDirectory: Boolean;
begin
  Created := nil;
  Parent := PExtNode(Directory);
  Ext := ExtVolumeOf(Directory);
  if (Kind <> NodeKindFile) and (Kind <> NodeKindDirectory) and (Kind <> NodeKindSymbolicLink) then
    Exit(StatusUnsupported);
  if TextLength(Name) > 255 then
    Exit(StatusNameTooLong);
  Result := DirectoryIsModifiable(Parent);
  if Result <> StatusSuccess then
    Exit;

  IsDirectory := Kind = NodeKindDirectory;
  Result := AllocateInode(Directory^.Volume, GroupOfInode(Ext, Parent^.InodeNumber), IsDirectory,
    InodeNumber);
  if Result <> StatusSuccess then
    Exit;

  Node := PExtNode(AllocateZeroedKernelMemory(SizeOf(TExtNode)));
  if Node = nil then
  begin
    FreeInode(Directory^.Volume, InodeNumber, IsDirectory);
    Exit(StatusOutOfMemory);
  end;
  Node^.Common.Volume := Directory^.Volume;
  Node^.InodeNumber := InodeNumber;
  InitializeInode(Node, Kind);

  case Kind of
    NodeKindDirectory:
      begin
        Result := AllocateBlockRange(Node, 0, 1);
        if Result = StatusSuccess then
        begin
          SetInodeSize(InodeRecord(Node)^, Ext^.BlockSize);
          Result := WriteInitialDirectoryBlock(Node, Parent^.InodeNumber);
        end;
      end;
    NodeKindSymbolicLink:
      Result := WriteLinkTarget(Node, LinkTarget);
  else
    Result := StatusSuccess;
  end;

  if Result = StatusSuccess then
    Result := WriteNodeInode(Node);
  if Result = StatusSuccess then
    Result := AddDirectoryEntry(Parent, Name, InodeNumber, FileTypeOf(Kind));

  if Result <> StatusSuccess then
  begin
    DiscardInode(Node, IsDirectory);
    FreeKernelMemory(Node);
    Exit;
  end;

  { The new directory's ".." is a link to the parent. }
  if IsDirectory then
    Inc(InodeRecord(Parent)^.LinksCount);
  StampTimes(Parent, True);
  RefreshNodeInformation(Parent);
  Result := WriteNodeInode(Parent);

  RefreshNodeInformation(Node);
  Created := @Node^.Common;
end;

{ --- Data ------------------------------------------------------------ }

function ExtWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
var
  ExtNode: PExtNode;
  Ext: PExtVolume;
  OldSize: QWord;
  FirstBlock: QWord;
  LastBlock: QWord;
begin
  BytesWritten := 0;
  ExtNode := PExtNode(Node);
  Ext := ExtVolumeOf(Node);
  OldSize := InodeSize(InodeRecord(ExtNode)^);
  if ByteCount = 0 then
    Exit(StatusSuccess);

  FirstBlock := Offset div Ext^.BlockSize;
  LastBlock := (Offset + ByteCount - 1) div Ext^.BlockSize;
  if LastBlock > High(LongWord) then
    Exit(StatusNoSpace);

  Result := StatusSuccess;
  if Offset > OldSize then
    Result := ZeroTailOfLastBlock(ExtNode, OldSize);
  if Result = StatusSuccess then
    Result := AllocateBlockRange(ExtNode, LongWord(FirstBlock), LongWord(LastBlock - FirstBlock + 1));
  if Result = StatusSuccess then
    Result := WriteNodeData(ExtNode, Offset, ByteCount, PByte(Buffer));
  if Result = StatusSuccess then
  begin
    BytesWritten := ByteCount;
    if Offset + ByteCount > OldSize then
      SetInodeSize(InodeRecord(ExtNode)^, Offset + ByteCount);
  end;

  { Even after a failure the inode records the blocks taken so far. }
  StampTimes(ExtNode, True);
  RefreshNodeInformation(ExtNode);
  if Result = StatusSuccess then
    Result := WriteNodeInode(ExtNode)
  else
    WriteNodeInode(ExtNode);
end;

function ExtSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
var
  ExtNode: PExtNode;
  Ext: PExtVolume;
  OldSize: QWord;
  KeepBlocks: QWord;
begin
  ExtNode := PExtNode(Node);
  Ext := ExtVolumeOf(Node);
  OldSize := InodeSize(InodeRecord(ExtNode)^);

  if NewSize < OldSize then
  begin
    KeepBlocks := (NewSize + Ext^.BlockSize - 1) div Ext^.BlockSize;
    Result := ReleaseBlocksFrom(ExtNode, LongWord(KeepBlocks));
  end
  else
    { The new part is a hole; only the old last block needs clearing. }
    Result := ZeroTailOfLastBlock(ExtNode, OldSize);
  if Result <> StatusSuccess then
    Exit;

  SetInodeSize(InodeRecord(ExtNode)^, NewSize);
  StampTimes(ExtNode, True);
  RefreshNodeInformation(ExtNode);
  Result := WriteNodeInode(ExtNode);
end;

{ --- Removing and renaming ------------------------------------------- }

function ExtRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  Parent: PExtNode;
  ExtNode: PExtNode;
  IsDirectory: Boolean;
  IsEmpty: Boolean;
begin
  Parent := PExtNode(Directory);
  ExtNode := PExtNode(Node);
  IsDirectory := Node^.Information.Kind = NodeKindDirectory;
  if ExtNode^.InodeNumber = RootInodeNumber then
    Exit(StatusInvalidPath);

  if IsDirectory then
  begin
    Result := DirectoryIsEmpty(ExtNode, IsEmpty);
    if Result <> StatusSuccess then
      Exit;
    if not IsEmpty then
      Exit(StatusDirectoryNotEmpty);
  end;

  Result := RemoveDirectoryEntry(Parent, Name);
  if Result <> StatusSuccess then
    Exit;

  if IsDirectory then
  begin
    { Its ".." no longer links to the parent. }
    if InodeRecord(Parent)^.LinksCount > 2 then
      Dec(InodeRecord(Parent)^.LinksCount);
    DiscardInode(ExtNode, True);
  end
  else
  begin
    if InodeRecord(ExtNode)^.LinksCount > 0 then
      Dec(InodeRecord(ExtNode)^.LinksCount);
    if InodeRecord(ExtNode)^.LinksCount = 0 then
      DiscardInode(ExtNode, False)
    else
    begin
      StampTimes(ExtNode, False);
      WriteNodeInode(ExtNode);
    end;
  end;
  RefreshNodeInformation(ExtNode);

  StampTimes(Parent, True);
  RefreshNodeInformation(Parent);
  Result := WriteNodeInode(Parent);
end;

function ExtRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
var
  Source: PExtNode;
  Target: PExtNode;
  ExtNode: PExtNode;
  IsDirectory: Boolean;
begin
  Source := PExtNode(SourceDirectory);
  Target := PExtNode(TargetDirectory);
  ExtNode := PExtNode(Node);
  IsDirectory := Node^.Information.Kind = NodeKindDirectory;

  Result := DirectoryIsModifiable(Source);
  if Result = StatusSuccess then
    Result := DirectoryIsModifiable(Target);
  if Result <> StatusSuccess then
    Exit;

  { Add the new name first, so the file is never without a name. }
  Result := AddDirectoryEntry(Target, TargetName, ExtNode^.InodeNumber,
    FileTypeOf(Node^.Information.Kind));
  if Result <> StatusSuccess then
    Exit;
  Result := RemoveDirectoryEntry(Source, SourceName);
  if Result <> StatusSuccess then
  begin
    RemoveDirectoryEntry(Target, TargetName);
    Exit;
  end;

  if IsDirectory and (Source <> Target) then
  begin
    Result := SetParentEntry(ExtNode, Target^.InodeNumber);
    if Result <> StatusSuccess then
      Exit;
    if InodeRecord(Source)^.LinksCount > 2 then
      Dec(InodeRecord(Source)^.LinksCount);
    Inc(InodeRecord(Target)^.LinksCount);
  end;

  StampTimes(ExtNode, False);
  WriteNodeInode(ExtNode);
  StampTimes(Source, True);
  RefreshNodeInformation(Source);
  Result := WriteNodeInode(Source);
  if (Result = StatusSuccess) and (Target <> Source) then
  begin
    StampTimes(Target, True);
    RefreshNodeInformation(Target);
    Result := WriteNodeInode(Target);
  end;
end;

function ExtSync(Volume: PVolume): TFileSystemStatus;
begin
  Result := SyncSuperblock(Volume);
end;

end.
