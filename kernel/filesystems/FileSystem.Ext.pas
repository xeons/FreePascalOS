{
  ext2, ext3 and ext4 file system driver.

  The three are one family. ext3 adds a journal to ext2; ext4 adds
  extents, 64-bit block numbers, flexible block groups, metadata
  checksums and more. This driver reads all of them and writes them as
  long as the volume uses no feature it cannot keep consistent; such
  volumes (and volumes whose journal needs recovery, which is not
  replayed) are mounted read-only.

  Name lookups are exact (case sensitive).

  The work is split over several units:
    FileSystem.Ext.Structures    on-disk records and feature flags
    FileSystem.Ext.Volume        checksums, group descriptors, inodes,
                                 block and inode allocation
    FileSystem.Ext.Blocks        block pointers and extent trees
    FileSystem.Ext.Directories   directory records
    FileSystem.Ext.Write         creating, writing, removing, renaming
    FileSystem.Ext.Attributes    permissions, owners, times, hard links
    FileSystem.Ext               (this unit) probing, mounting, reading
}
unit FileSystem.Ext;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExtFileSystemDriver: PFileSystemDriver;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Checksums,
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume,
  FileSystem.Ext.Blocks,
  FileSystem.Ext.Directories,
  FileSystem.Ext.Write,
  FileSystem.Ext.Attributes,
  Debug.Output;

const
  { Incompatible features that can be read. }
  ReadableIncompatibleFeatures = IncompatibleFileType or IncompatibleNeedsRecovery or
    IncompatibleMetaBlockGroups or IncompatibleExtents or Incompatible64Bit or
    IncompatibleMultipleMountProtection or IncompatibleFlexibleBlockGroups or
    IncompatibleExtendedAttributeInodes or IncompatibleChecksumSeed or
    IncompatibleLargeDirectories or IncompatibleInlineData or IncompatibleEncryption or
    IncompatibleCaseFolding;

  { Incompatible features that prevent writing. }
  WriteBlockingIncompatibleFeatures = IncompatibleNeedsRecovery or
    IncompatibleMultipleMountProtection or IncompatibleEncryption or IncompatibleCaseFolding;

  { Read-only compatible features this driver keeps consistent. }
  WritableReadOnlyCompatibleFeatures = ReadOnlyCompatibleSparseSuper or ReadOnlyCompatibleLargeFile or
    $0004 { btree_dir, unused } or ReadOnlyCompatibleHugeFile or
    ReadOnlyCompatibleGroupDescriptorChecksum or ReadOnlyCompatibleDirectoryLinkCount or
    ReadOnlyCompatibleExtraInodeSize or ReadOnlyCompatibleMetadataChecksum;

  { Features that only exist from ext4 on. }
  Ext4OnlyIncompatibleFeatures = IncompatibleExtents or Incompatible64Bit or
    IncompatibleFlexibleBlockGroups or IncompatibleInlineData or IncompatibleLargeDirectories;
  Ext4OnlyReadOnlyCompatibleFeatures = ReadOnlyCompatibleHugeFile or
    ReadOnlyCompatibleGroupDescriptorChecksum or ReadOnlyCompatibleDirectoryLinkCount or
    ReadOnlyCompatibleExtraInodeSize or ReadOnlyCompatibleMetadataChecksum;

  StateHasErrors = $0002;
  ChecksumTypeCrc32c = 1;
  ChecksumTypeOffset = $175;

var
  Driver: TFileSystemDriver;

{ --- Nodes ----------------------------------------------------------- }

function LoadNode(Volume: PVolume; InodeNumber: LongWord; out Node: PExtNode): TFileSystemStatus;
begin
  Node := PExtNode(AllocateZeroedKernelMemory(SizeOf(TExtNode)));
  if Node = nil then
    Exit(StatusOutOfMemory);

  Result := ReadInodeBytes(Volume, InodeNumber, @Node^.InodeBytes[0]);
  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Node);
    Node := nil;
    Exit;
  end;

  Node^.Common.Volume := Volume;
  Node^.InodeNumber := InodeNumber;
  RefreshNodeInformation(Node);
end;

function KindFromFileType(FileType: Byte): TNodeKind;
begin
  case FileType of
    FileTypeRegular: Result := NodeKindFile;
    FileTypeDirectory: Result := NodeKindDirectory;
    FileTypeSymbolicLink: Result := NodeKindSymbolicLink;
  else
    Result := NodeKindOther;
  end;
end;

{ --- Reading --------------------------------------------------------- }

function ExtLookup(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  Entry: TExtDirectoryEntry;
  Node: PExtNode;
begin
  Found := nil;
  if TextIsEqual(Name, '.') or TextIsEqual(Name, '..') then
    Exit(StatusNotFound);
  Result := FindDirectoryEntry(PExtNode(Directory), Name, Entry);
  if Result <> StatusSuccess then
    Exit;
  Result := LoadNode(Directory^.Volume, Entry.InodeNumber, Node);
  if Result = StatusSuccess then
    Found := @Node^.Common;
end;

function ExtReadDirectory(Directory: PNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
var
  ExtEntry: TExtDirectoryEntry;
begin
  Result := NextDirectoryEntry(PExtNode(Directory), Cursor, False, ExtEntry);
  if Result <> StatusSuccess then
    Exit;
  CopyText(@Entry.Name[0], @ExtEntry.Name[0], MaximumNameBytes);
  Entry.Kind := KindFromFileType(ExtEntry.FileType);
  Entry.NodeNumber := ExtEntry.InodeNumber;
end;

function ExtReadFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
var
  FileSize: QWord;
begin
  BytesRead := 0;
  FileSize := Node^.Information.SizeInBytes;
  if Offset >= FileSize then
    Exit(StatusSuccess);
  if ByteCount > FileSize - Offset then
    ByteCount := FileSize - Offset;

  Result := ReadNodeData(PExtNode(Node), Offset, ByteCount, PByte(Buffer));
  if Result = StatusSuccess then
    BytesRead := ByteCount;
end;

function ExtReadSymbolicLink(Node: PNode; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;
var
  ExtNode: PExtNode;
  LinkLength: QWord;
begin
  ExtNode := PExtNode(Node);
  LinkLength := InodeSize(InodeRecord(ExtNode)^);
  if LinkLength + 1 > Capacity then
    Exit(StatusNameTooLong);

  if IsFastSymbolicLink(Node) then
  begin
    CopyMemory(Target, @InodeRecord(ExtNode)^.Block[0], LinkLength);
    Result := StatusSuccess;
  end
  else
    Result := ReadNodeData(ExtNode, 0, LinkLength, PByte(Target));

  if Result = StatusSuccess then
    Target[LinkLength] := #0;
end;

procedure ExtReleaseNode(Node: PNode);
begin
  FreeKernelMemory(Node);
end;

{ --- Mounting -------------------------------------------------------- }

function ReadSuperblock(Device: PBlockDevice; out Superblock: TSuperblock): Boolean;
begin
  Result := CachedRead(Device, SuperblockOffset, SizeOf(TSuperblock), @Superblock) and
    (Superblock.Magic = ExtMagic);
end;

function ExtProbe(Device: PBlockDevice): Boolean;
var
  Superblock: TSuperblock;
begin
  Result := ReadSuperblock(Device, Superblock) and (Superblock.LogBlockSize <= 6) and
    (Superblock.BlocksPerGroup > 0) and (Superblock.InodesPerGroup > 0);
end;

procedure DetermineVariantName(Volume: PVolume; const Superblock: TSuperblock);
begin
  if ((Superblock.FeatureIncompatible and Ext4OnlyIncompatibleFeatures) <> 0) or
     ((Superblock.FeatureReadOnlyCompatible and Ext4OnlyReadOnlyCompatibleFeatures) <> 0) then
    CopyText(@Volume^.TypeName[0], 'ext4', FileSystemTypeNameLength)
  else if (Superblock.FeatureCompatible and CompatibleHasJournal) <> 0 then
    CopyText(@Volume^.TypeName[0], 'ext3', FileSystemTypeNameLength)
  else
    CopyText(@Volume^.TypeName[0], 'ext2', FileSystemTypeNameLength);
end;

procedure CopyVolumeName(Volume: PVolume; const Superblock: TSuperblock);
var
  Index: Integer;
begin
  Index := 0;
  while (Index < 16) and (Superblock.VolumeName[Index] <> #0) do
  begin
    Volume^.VolumeLabel[Index] := Superblock.VolumeName[Index];
    Inc(Index);
  end;
  Volume^.VolumeLabel[Index] := #0;
end;

procedure ReportReadOnlyReason(Volume: PVolume; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('ext');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(': mounting read-only: ');
  DebugWriteLine(Reason);
  DebugEndMessage;
end;

{ Decides whether this driver can write the volume without breaking it. }
procedure CheckWritability(Volume: PVolume; Ext: PExtVolume; const Superblock: TSuperblock;
  SuperblockBytes: PByte);
begin
  if Volume^.IsReadOnly then
    Exit;

  if HasIncompatibleFeature(Ext, IncompatibleNeedsRecovery) then
    ReportReadOnlyReason(Volume, 'the journal needs recovery, which is not supported')
  else if (Superblock.FeatureIncompatible and WriteBlockingIncompatibleFeatures) <> 0 then
    ReportReadOnlyReason(Volume, 'it uses features that cannot be written yet')
  else if (Superblock.FeatureReadOnlyCompatible and not WritableReadOnlyCompatibleFeatures) <> 0 then
    ReportReadOnlyReason(Volume, 'it has read-only compatible features that are not supported')
  else if Superblock.LogClusterSize <> Superblock.LogBlockSize then
    ReportReadOnlyReason(Volume, 'clusters larger than blocks (bigalloc) are not supported')
  else if (Superblock.State and StateHasErrors) <> 0 then
    ReportReadOnlyReason(Volume, 'it is marked as having errors')
  else if Ext^.HasMetadataChecksums and (SuperblockBytes[ChecksumTypeOffset] <> ChecksumTypeCrc32c) then
    ReportReadOnlyReason(Volume, 'unknown metadata checksum type')
  else
    Exit;
  Volume^.IsReadOnly := True;
end;

{ The per-group free counters are authoritative; the superblock copies
  are only updated lazily by some implementations. }
function SumFreeCounters(Volume: PVolume): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  Group: LongWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Ext^.FreeBlockCount := 0;
  Ext^.FreeInodeCount := 0;
  Group := 0;
  while Group < Ext^.GroupCount do
  begin
    Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
    if Result <> StatusSuccess then
      Exit;
    Ext^.FreeBlockCount := Ext^.FreeBlockCount + DescriptorValue(Ext, @Descriptor[0],
      DescriptorOffsetFreeBlocksLow, DescriptorOffsetFreeBlocksHigh, False);
    Ext^.FreeInodeCount := Ext^.FreeInodeCount + LongWord(DescriptorValue(Ext, @Descriptor[0],
      DescriptorOffsetFreeInodesLow, DescriptorOffsetFreeInodesHigh, False));
    Inc(Group);
  end;
  Result := StatusSuccess;
end;

function ExtMount(Volume: PVolume): TFileSystemStatus;
var
  Superblock: TSuperblock;
  SuperblockBytes: array[0..SuperblockSize - 1] of Byte;
  Ext: PExtVolume;
  Root: PExtNode;
  UnsupportedFeatures: LongWord;
begin
  if not CachedRead(Volume^.Device, SuperblockOffset, SuperblockSize, @SuperblockBytes[0]) then
    Exit(StatusIoError);
  Superblock := PSuperblock(@SuperblockBytes[0])^;
  if Superblock.Magic <> ExtMagic then
    Exit(StatusCorrupted);

  if Superblock.RevisionLevel = GoodOldRevision then
  begin
    Superblock.InodeSize := GoodOldInodeSize;
    Superblock.FirstInode := 11;
    Superblock.FeatureIncompatible := 0;
    Superblock.FeatureReadOnlyCompatible := 0;
    Superblock.FeatureCompatible := 0;
  end;

  UnsupportedFeatures := Superblock.FeatureIncompatible and not ReadableIncompatibleFeatures;
  if UnsupportedFeatures <> 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('ext');
    DebugWrite(@Volume^.Name[0]);
    DebugWrite(': unsupported incompatible features 0x');
    DebugWriteHex(UnsupportedFeatures, 1);
    DebugWriteLine('');
    DebugEndMessage;
    Exit(StatusUnsupported);
  end;

  Ext := PExtVolume(AllocateZeroedKernelMemory(SizeOf(TExtVolume)));
  if Ext = nil then
    Exit(StatusOutOfMemory);

  Ext^.BlockSize := QWord(1024) shl Superblock.LogBlockSize;
  Ext^.InodeSize := Superblock.InodeSize;
  Ext^.InodesPerGroup := Superblock.InodesPerGroup;
  Ext^.BlocksPerGroup := Superblock.BlocksPerGroup;
  Ext^.FirstDataBlock := Superblock.FirstDataBlock;
  Ext^.FeatureCompatible := Superblock.FeatureCompatible;
  Ext^.FeatureIncompatible := Superblock.FeatureIncompatible;
  Ext^.FeatureReadOnlyCompatible := Superblock.FeatureReadOnlyCompatible;
  Ext^.FirstMetaBlockGroup := Superblock.FirstMetaBlockGroup;
  Ext^.FirstNonReservedInode := Superblock.FirstInode;
  Ext^.WantExtraInodeSize := Superblock.WantExtraInodeSize;
  CopyMemory(@Ext^.Uuid[0], @Superblock.Uuid[0], 16);
  Ext^.HasMetadataChecksums :=
    (Superblock.FeatureReadOnlyCompatible and ReadOnlyCompatibleMetadataChecksum) <> 0;
  Ext^.HasGroupDescriptorChecksums :=
    (Superblock.FeatureReadOnlyCompatible and ReadOnlyCompatibleGroupDescriptorChecksum) <> 0;
  if HasIncompatibleFeature(Ext, IncompatibleChecksumSeed) then
    Ext^.ChecksumSeed := PLongWord(@SuperblockBytes[SuperblockChecksumSeedOffset])^
  else
    Ext^.ChecksumSeed := Crc32cUpdate(Crc32InitialValue, @Superblock.Uuid[0], 16);

  Ext^.BlockCount := Superblock.BlocksCountLow;
  if HasIncompatibleFeature(Ext, Incompatible64Bit) then
    Ext^.BlockCount := Ext^.BlockCount or (QWord(Superblock.BlocksCountHigh) shl 32);

  if HasIncompatibleFeature(Ext, Incompatible64Bit) and (Superblock.DescriptorSize >= 64) then
    Ext^.DescriptorSize := Superblock.DescriptorSize
  else
    Ext^.DescriptorSize := 32;
  if Ext^.DescriptorSize > MaximumDescriptorSize then
    Ext^.DescriptorSize := MaximumDescriptorSize;
  Ext^.DescriptorsPerBlock := LongWord(Ext^.BlockSize div Ext^.DescriptorSize);

  if (Ext^.InodeSize < GoodOldInodeSize) or (Ext^.InodeSize > MaximumInodeSize) or
     (Ext^.InodeSize > Ext^.BlockSize) or (Ext^.BlockCount <= Ext^.FirstDataBlock) or
     (Ext^.BlockCount * Ext^.BlockSize > BlockDeviceSizeInBytes(Volume^.Device)) then
  begin
    FreeKernelMemory(Ext);
    Exit(StatusCorrupted);
  end;
  Ext^.GroupCount := LongWord((Ext^.BlockCount - Ext^.FirstDataBlock + Ext^.BlocksPerGroup - 1) div
    Ext^.BlocksPerGroup);

  Volume^.DriverData := Ext;
  Volume^.TotalBytes := Ext^.BlockCount * Ext^.BlockSize;
  DetermineVariantName(Volume, Superblock);
  CopyVolumeName(Volume, Superblock);
  CheckWritability(Volume, Ext, Superblock, @SuperblockBytes[0]);

  { Allocation needs the free counters, and so does reporting free space;
    only writing depends on them being readable. }
  Result := SumFreeCounters(Volume);
  if Volume^.IsReadOnly then
    Result := StatusSuccess;
  if Result = StatusSuccess then
    Result := LoadNode(Volume, RootInodeNumber, Root);
  if (Result = StatusSuccess) and (Root^.Common.Information.Kind <> NodeKindDirectory) then
  begin
    FreeKernelMemory(Root);
    Result := StatusCorrupted;
  end;
  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Ext);
    Volume^.DriverData := nil;
    Exit;
  end;

  Volume^.RootNode := @Root^.Common;
end;

procedure ExtUnmount(Volume: PVolume);
begin
  FreeKernelMemory(Volume^.RootNode);
  FreeKernelMemory(Volume^.DriverData);
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
end;

function ExtFileSystemDriver: PFileSystemDriver;
begin
  Driver.Name := 'ext2/3/4';
  Driver.Probe := @ExtProbe;
  Driver.Mount := @ExtMount;
  Driver.Unmount := @ExtUnmount;
  Driver.Lookup := @ExtLookup;
  Driver.ReadDirectory := @ExtReadDirectory;
  Driver.ReadFile := @ExtReadFile;
  Driver.ReadSymbolicLink := @ExtReadSymbolicLink;
  Driver.ReleaseNode := @ExtReleaseNode;
  Driver.CreateNode := @ExtCreateNode;
  Driver.WriteFile := @ExtWriteFile;
  Driver.SetFileSize := @ExtSetFileSize;
  Driver.RemoveNode := @ExtRemoveNode;
  Driver.RenameNode := @ExtRenameNode;
  Driver.Sync := @ExtSync;
  Driver.SetAttributes := @ExtSetAttributes;
  Driver.CreateHardLink := @ExtCreateHardLink;
  Driver.GetFreeSpace := @ExtGetFreeSpace;
  Result := @Driver;
end;

end.
