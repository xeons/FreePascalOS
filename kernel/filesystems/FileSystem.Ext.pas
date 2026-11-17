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
  ext2, ext3 and ext4 file system driver.

  The three are one family. ext3 adds a journal to ext2; ext4 adds
  extents, 64-bit block numbers, flexible block groups, metadata
  checksums and more. This driver reads all of them and writes them as
  long as the volume uses no feature it cannot keep consistent; such
  volumes are mounted read-only.

  ext3 and ext4 volumes are written through their journal: every driver
  call that changes the volume is one transaction, committed to the
  journal before anything is written in place. A volume whose journal
  needs recovery (it was not unmounted cleanly) has its journal replayed
  when it is mounted, unless it is to be mounted read-only.

  Name lookups are exact (case sensitive).

  The work is split over several units:
    FileSystem.Ext.Structures    on-disk records and feature flags
    FileSystem.Ext.Volume        checksums, group descriptors, inodes,
                                 block and inode allocation
    FileSystem.Ext.Blocks        block pointers and extent trees
    FileSystem.Ext.Directories   directory records
    FileSystem.Ext.Write         creating, writing, removing, renaming
    FileSystem.Ext.Attributes    permissions, owners, times, hard links
    FileSystem.Ext.JournalFormat the journal's on-disk format
    FileSystem.Ext.Transactions  transactions: logging and checkpointing
    FileSystem.Ext.JournalRecovery  replaying the journal
    FileSystem.Ext.Journal       finding and checking the journal
    FileSystem.Ext.Orphans       files removed while open, the orphan list
    FileSystem.Ext               (this unit) probing, mounting, reading
}
unit FileSystem.Ext;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExtFileSystemDriver: PFileSystemDriver;

{ For tests: the next transaction committed on Volume stops before it is
  written in place, as if the machine crashed right after the commit;
  nothing more is written to the volume, which becomes read-only. False
  if Volume has no journal being written. }
function SimulateCrashAfterNextCommit(Volume: PVolume): Boolean;

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
  FileSystem.Ext.Transactions,
  FileSystem.Ext.JournalRecovery,
  FileSystem.Ext.Journal,
  FileSystem.Ext.Orphans,
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
    FileTypeFifo: Result := NodeKindFifo;
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
  ForgetOrphan(Node);
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
    ReportReadOnlyReason(Volume, 'the journal needs recovery')
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

procedure ReportJournal(Volume: PVolume; Text: PChar; Count: QWord; Tail: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('ext');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(': ');
  DebugWrite(Text);
  DebugWriteDecimal(Count);
  DebugWriteLine(Tail);
  DebugEndMessage;
end;

{ Replays the journal of a volume that needs recovery, then clears the
  mark; Replayed tells whether that happened (the volume must then be
  mounted afresh, as its metadata may have changed). Leaves the volume
  marked if it is to be mounted read-only or the journal cannot be
  replayed. }
function RecoverIfNeeded(Volume: PVolume; Ext: PExtVolume; const Superblock: TSuperblock;
  out Replayed: Boolean): TFileSystemStatus;
var
  Journal: PExtJournal;
  Reason: PChar;
  ReplayedBlocks: QWord;
begin
  Replayed := False;
  Result := StatusSuccess;
  if not HasIncompatibleFeature(Ext, IncompatibleNeedsRecovery) or
     ((Superblock.FeatureCompatible and CompatibleHasJournal) = 0) or Volume^.IsReadOnly then
    Exit;
  if LoadExtJournal(Volume, Superblock.JournalInode, Journal, Reason) <> StatusSuccess then
  begin
    ReportReadOnlyReason(Volume, Reason);
    Exit;
  end;
  Result := RecoverJournal(Journal, ReplayedBlocks);
  FreeJournal(Journal);
  if Result <> StatusSuccess then
    Exit;
  if not SetNeedsRecovery(Volume, False, Ext^.HasMetadataChecksums) or
     not FlushCachedDevice(Volume^.Device) then
    Exit(StatusIoError);
  ReportJournal(Volume, 'journal recovered, ', ReplayedBlocks, ' blocks replayed');
  Replayed := True;
end;

{ Opens the journal of a writable ext3/ext4 volume for transactions, or
  makes the volume read-only if it cannot be written. }
procedure OpenJournalForWriting(Volume: PVolume; Ext: PExtVolume; const Superblock: TSuperblock);
var
  Journal: PExtJournal;
  Reason: PChar;
begin
  if Volume^.IsReadOnly or ((Superblock.FeatureCompatible and CompatibleHasJournal) = 0) then
    Exit;
  if LoadExtJournal(Volume, Superblock.JournalInode, Journal, Reason) <> StatusSuccess then
  begin
    ReportReadOnlyReason(Volume, Reason);
    Volume^.IsReadOnly := True;
    Exit;
  end;
  if not JournalIsWritable(Journal, Reason) then
  begin
    ReportReadOnlyReason(Volume, Reason);
    Volume^.IsReadOnly := True;
    FreeJournal(Journal);
    Exit;
  end;
  if not PrepareJournalForWriting(Journal, Ext) then
  begin
    ReportReadOnlyReason(Volume, 'out of memory for the journal');
    Volume^.IsReadOnly := True;
    FreeJournal(Journal);
    Exit;
  end;
  Ext^.Journal := Journal;
end;

function JournalOfVolume(Volume: PVolume): PExtJournal; forward;
function FinishTransaction(Volume: PVolume; Status: TFileSystemStatus): TFileSystemStatus; forward;

{ Frees what files removed while open left behind when the volume was
  last used (it was not unmounted cleanly). }
procedure SettleOrphans(Volume: PVolume);
var
  Count: LongWord;
  Status: TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Volume));
  Status := FinishTransaction(Volume, ProcessOrphans(Volume, Count));
  if (Count > 0) or (Status <> StatusSuccess) then
  begin
    DebugBeginMessage;
    DebugWriteTag('ext');
    DebugWrite(@Volume^.Name[0]);
    DebugWrite(': ');
    DebugWriteDecimal(Count);
    DebugWrite(' orphaned inodes freed');
    if Status <> StatusSuccess then
    begin
      DebugWrite(', then ');
      DebugWrite(FileSystemStatusText(Status));
    end;
    DebugWriteLine('');
    DebugEndMessage;
  end;
end;

function LatestOf(First, Second: LongWord): LongWord;
begin
  if First > Second then
    Result := First
  else
    Result := Second;
end;

function ExtMount(Volume: PVolume): TFileSystemStatus;
var
  Superblock: TSuperblock;
  SuperblockBytes: array[0..SuperblockSize - 1] of Byte;
  Ext: PExtVolume;
  Root: PExtNode;
  UnsupportedFeatures: LongWord;
  Replayed: Boolean;
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
  Ext^.EarliestDeletionTime := LatestOf(Superblock.InodesCount,
    LatestOf(Superblock.WriteTime, Superblock.MakeFileSystemTime));
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

  Result := RecoverIfNeeded(Volume, Ext, Superblock, Replayed);
  if (Result <> StatusSuccess) or Replayed then
  begin
    FreeKernelMemory(Ext);
    Volume^.DriverData := nil;
    if Result <> StatusSuccess then
      Exit;
    { Everything may have changed, the superblock included. }
    Exit(ExtMount(Volume));
  end;

  DetermineVariantName(Volume, Superblock);
  CopyVolumeName(Volume, Superblock);
  CheckWritability(Volume, Ext, Superblock, @SuperblockBytes[0]);
  OpenJournalForWriting(Volume, Ext, Superblock);

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
    FreeJournal(Ext^.Journal);
    FreeKernelMemory(Ext);
    Volume^.DriverData := nil;
    Exit;
  end;

  Volume^.RootNode := @Root^.Common;
  if not Volume^.IsReadOnly then
    SettleOrphans(Volume);
end;

procedure ExtUnmount(Volume: PVolume);
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  if Ext <> nil then
  begin
    MarkJournalClean(Ext^.Journal);
    FreeJournal(Ext^.Journal);
  end;
  FreeKernelMemory(Volume^.RootNode);
  FreeKernelMemory(Volume^.DriverData);
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
end;

{ --- Transactions -------------------------------------------------------- }

{ Every call that changes the volume is one transaction. }

function JournalOfVolume(Volume: PVolume): PExtJournal;
begin
  Result := PExtVolume(Volume^.DriverData)^.Journal;
end;

{ Commits the transaction of a call that ended with Status. What the
  call changed is committed even if it failed part way, as it was
  written in place before there was a journal. }
function FinishTransaction(Volume: PVolume; Status: TFileSystemStatus): TFileSystemStatus;
var
  CommitStatus: TFileSystemStatus;
begin
  { The superblock's free counters go with the transaction that changed
    them, so that the committed state is consistent as a whole (without
    a journal they are written when the volume is synced). }
  if JournalOfVolume(Volume) <> nil then
    SyncSuperblock(Volume);
  CommitStatus := EndTransaction(JournalOfVolume(Volume));
  if (JournalOfVolume(Volume) <> nil) and JournalOfVolume(Volume)^.Halted then
    Volume^.IsReadOnly := True;
  if (Status = StatusSuccess) and (CommitStatus <> StatusSuccess) then
    Result := CommitStatus
  else
    Result := Status;
end;

function JournaledCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Directory^.Volume));
  Result := FinishTransaction(Directory^.Volume, ExtCreateNode(Directory, Name, Kind, LinkTarget, Created));
end;

function JournaledWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Node^.Volume));
  Result := FinishTransaction(Node^.Volume, ExtWriteFile(Node, Offset, Buffer, ByteCount, BytesWritten));
end;

function JournaledSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Node^.Volume));
  Result := FinishTransaction(Node^.Volume, ExtSetFileSize(Node, NewSize));
end;

function JournaledRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Directory^.Volume));
  Result := FinishTransaction(Directory^.Volume, ExtRemoveNode(Directory, Name, Node));
end;

function JournaledRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(SourceDirectory^.Volume));
  Result := FinishTransaction(SourceDirectory^.Volume,
    ExtRenameNode(SourceDirectory, SourceName, Node, TargetDirectory, TargetName));
end;

function JournaledSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Node^.Volume));
  Result := FinishTransaction(Node^.Volume, ExtSetAttributes(Node, Changes));
end;

function JournaledCreateHardLink(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Directory^.Volume));
  Result := FinishTransaction(Directory^.Volume, ExtCreateHardLink(Directory, Name, Node));
end;

{ Syncing also empties the journal: afterwards the volume needs no
  recovery until it is changed again. }
function JournaledSync(Volume: PVolume): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Volume));
  Result := FinishTransaction(Volume, ExtSync(Volume));
  if Result = StatusSuccess then
    Result := MarkJournalClean(JournalOfVolume(Volume));
end;

function JournaledRemoveOpenNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Directory^.Volume));
  Result := FinishTransaction(Directory^.Volume, ExtRemoveOpenNode(Directory, Name, Node));
end;

function JournaledFinishRemoval(Node: PNode): TFileSystemStatus;
begin
  BeginTransaction(JournalOfVolume(Node^.Volume));
  Result := FinishTransaction(Node^.Volume, ExtFinishRemoval(Node));
end;

procedure BeginExtAtomicChange(Volume: PVolume);
begin
  BeginTransaction(JournalOfVolume(Volume));
end;

function EndExtAtomicChange(Volume: PVolume): TFileSystemStatus;
begin
  Result := FinishTransaction(Volume, StatusSuccess);
end;

function SimulateCrashAfterNextCommit(Volume: PVolume): Boolean;
var
  Journal: PExtJournal;
begin
  Result := False;
  if (Volume^.Driver <> @Driver) or (Volume^.DriverData = nil) then
    Exit;
  Journal := JournalOfVolume(Volume);
  if Journal = nil then
    Exit;
  Journal^.StopBeforeCheckpoint := True;
  Result := True;
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
  Driver.CreateNode := @JournaledCreateNode;
  Driver.WriteFile := @JournaledWriteFile;
  Driver.SetFileSize := @JournaledSetFileSize;
  Driver.RemoveNode := @JournaledRemoveNode;
  Driver.RenameNode := @JournaledRenameNode;
  Driver.Sync := @JournaledSync;
  Driver.SetAttributes := @JournaledSetAttributes;
  Driver.CreateHardLink := @JournaledCreateHardLink;
  Driver.GetFreeSpace := @ExtGetFreeSpace;
  Driver.RemoveOpenNode := @JournaledRemoveOpenNode;
  Driver.FinishRemoval := @JournaledFinishRemoval;
  Driver.BeginAtomicChange := @BeginExtAtomicChange;
  Driver.EndAtomicChange := @EndExtAtomicChange;
  Result := @Driver;
end;

end.
