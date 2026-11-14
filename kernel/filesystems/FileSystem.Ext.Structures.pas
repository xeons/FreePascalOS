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
  On-disk structures of the ext2/ext3/ext4 family.

  All fields are little endian. Group descriptors are accessed through
  byte offsets (the DescriptorOffset* constants) rather than a record,
  because their size (32 or 64 bytes) depends on the volume.
}
unit FileSystem.Ext.Structures;

{$mode objfpc}

interface

const
  SuperblockOffset = 1024;
  SuperblockSize = 1024;
  ExtMagic = $EF53;
  RootInodeNumber = 2;
  GoodOldInodeSize = 128;
  GoodOldRevision = 0;
  MaximumInodeSize = 1024;

  { Superblock fields beyond the TSuperblock record. }
  SuperblockChecksumSeedOffset = $270;
  SuperblockChecksumOffset = $3FC;

  CompatibleHasJournal = $0004;

  IncompatibleCompression = $0001;
  IncompatibleFileType = $0002;
  IncompatibleNeedsRecovery = $0004;
  IncompatibleJournalDevice = $0008;
  IncompatibleMetaBlockGroups = $0010;
  IncompatibleExtents = $0040;
  Incompatible64Bit = $0080;
  IncompatibleMultipleMountProtection = $0100;
  IncompatibleFlexibleBlockGroups = $0200;
  IncompatibleExtendedAttributeInodes = $0400;
  IncompatibleDirectoryData = $1000;
  IncompatibleChecksumSeed = $2000;
  IncompatibleLargeDirectories = $4000;
  IncompatibleInlineData = $8000;
  IncompatibleEncryption = $10000;
  IncompatibleCaseFolding = $20000;

  ReadOnlyCompatibleSparseSuper = $0001;
  ReadOnlyCompatibleLargeFile = $0002;
  ReadOnlyCompatibleHugeFile = $0008;
  ReadOnlyCompatibleGroupDescriptorChecksum = $0010;
  ReadOnlyCompatibleDirectoryLinkCount = $0020;
  ReadOnlyCompatibleExtraInodeSize = $0040;
  ReadOnlyCompatibleMetadataChecksum = $0400;

  ModeTypeMask = $F000;
  ModeTypeDirectory = $4000;
  ModeTypeRegular = $8000;
  ModeTypeSymbolicLink = $A000;
  ModeTypeFifo = $1000;
  ModePermissionMask = $0FFF;

  InodeFlagIndexedDirectory = $00001000;
  InodeFlagHugeFile = $00040000;
  InodeFlagExtents = $00080000;
  InodeFlagInlineData = $10000000;

  { Byte offsets inside an inode. }
  InodeChecksumLowOffset = $7C;
  InodeExtraSizeOffset = $80;
  InodeChecksumHighOffset = $82;
  InodeCreationTimeOffset = $90;
  InodeExtraFieldsSize = 32;

  ExtentMagic = $F30A;
  ExtentHeaderSize = 12;
  ExtentEntrySize = 12;
  ExtentRootCapacity = 4;
  ExtentMaximumLength = 32768;
  ExtentTailSize = 4;
  MaximumExtentDepth = 5;

  DirectBlockCount = 12;
  SingleIndirectSlot = 12;
  DoubleIndirectSlot = 13;
  TripleIndirectSlot = 14;
  BlockPointerSlots = 15;

  InlineDataCapacity = 60;
  DirectoryEntryHeaderSize = 8;
  DirectoryTailSize = 12;
  DirectoryTailFileType = $DE;

  FileTypeUnknown = 0;
  FileTypeRegular = 1;
  FileTypeDirectory = 2;
  FileTypeFifo = 5;
  FileTypeSymbolicLink = 7;

  { Group descriptor layout. }
  DescriptorOffsetBlockBitmapLow = $00;
  DescriptorOffsetInodeBitmapLow = $04;
  DescriptorOffsetInodeTableLow = $08;
  DescriptorOffsetFreeBlocksLow = $0C;
  DescriptorOffsetFreeInodesLow = $0E;
  DescriptorOffsetUsedDirectoriesLow = $10;
  DescriptorOffsetFlags = $12;
  DescriptorOffsetBlockBitmapChecksumLow = $18;
  DescriptorOffsetInodeBitmapChecksumLow = $1A;
  DescriptorOffsetUnusedInodesLow = $1C;
  DescriptorOffsetChecksum = $1E;
  DescriptorOffsetBlockBitmapHigh = $20;
  DescriptorOffsetInodeBitmapHigh = $24;
  DescriptorOffsetInodeTableHigh = $28;
  DescriptorOffsetFreeBlocksHigh = $2C;
  DescriptorOffsetFreeInodesHigh = $2E;
  DescriptorOffsetUsedDirectoriesHigh = $30;
  DescriptorOffsetUnusedInodesHigh = $32;
  DescriptorOffsetBlockBitmapChecksumHigh = $38;
  DescriptorOffsetInodeBitmapChecksumHigh = $3A;
  MaximumDescriptorSize = 64;

  GroupFlagInodesUninitialized = $0001;
  GroupFlagBlocksUninitialized = $0002;
  GroupFlagInodeTableZeroed = $0004;

type
  TSuperblock = packed record
    InodesCount: LongWord;
    BlocksCountLow: LongWord;
    ReservedBlocksCountLow: LongWord;
    FreeBlocksCountLow: LongWord;
    FreeInodesCount: LongWord;
    FirstDataBlock: LongWord;
    LogBlockSize: LongWord;
    LogClusterSize: LongWord;
    BlocksPerGroup: LongWord;
    ClustersPerGroup: LongWord;
    InodesPerGroup: LongWord;
    MountTime: LongWord;
    WriteTime: LongWord;
    MountCount: Word;
    MaximumMountCount: Word;
    Magic: Word;
    State: Word;
    Errors: Word;
    MinorRevisionLevel: Word;
    LastCheck: LongWord;
    CheckInterval: LongWord;
    CreatorOs: LongWord;
    RevisionLevel: LongWord;
    DefaultReservedUid: Word;
    DefaultReservedGid: Word;
    FirstInode: LongWord;
    InodeSize: Word;
    BlockGroupNumber: Word;
    FeatureCompatible: LongWord;
    FeatureIncompatible: LongWord;
    FeatureReadOnlyCompatible: LongWord;
    Uuid: array[0..15] of Byte;
    VolumeName: array[0..15] of Char;
    LastMounted: array[0..63] of Char;
    AlgorithmUsageBitmap: LongWord;
    PreallocateBlocks: Byte;
    PreallocateDirectoryBlocks: Byte;
    ReservedGroupDescriptorBlocks: Word;
    JournalUuid: array[0..15] of Byte;
    JournalInode: LongWord;
    JournalDevice: LongWord;
    LastOrphan: LongWord;
    HashSeed: array[0..3] of LongWord;
    DefaultHashVersion: Byte;
    JournalBackupType: Byte;
    DescriptorSize: Word;
    DefaultMountOptions: LongWord;
    FirstMetaBlockGroup: LongWord;
    MakeFileSystemTime: LongWord;
    JournalBlocks: array[0..16] of LongWord;
    BlocksCountHigh: LongWord;
    ReservedBlocksCountHigh: LongWord;
    FreeBlocksCountHigh: LongWord;
    MinimumExtraInodeSize: Word;
    WantExtraInodeSize: Word;
  end;
  PSuperblock = ^TSuperblock;

  TInode = packed record
    Mode: Word;
    UserId: Word;
    SizeLow: LongWord;
    AccessTime: LongWord;
    ChangeTime: LongWord;
    ModificationTime: LongWord;
    DeletionTime: LongWord;
    GroupId: Word;
    LinksCount: Word;
    BlocksLow: LongWord;
    Flags: LongWord;
    OsDependent1: LongWord;
    Block: array[0..14] of LongWord;
    Generation: LongWord;
    FileAclLow: LongWord;
    SizeHigh: LongWord;
    ObsoleteFragmentAddress: LongWord;
    BlocksHigh: Word;
    FileAclHigh: Word;
    UserIdHigh: Word;
    GroupIdHigh: Word;
    ChecksumLow: Word;
    Reserved: Word;
  end;
  PInode = ^TInode;

  TExtentHeader = packed record
    Magic: Word;
    Entries: Word;
    Maximum: Word;
    Depth: Word;
    Generation: LongWord;
  end;
  PExtentHeader = ^TExtentHeader;

  { Leaf entries and index entries share the same 12-byte size. }
  TExtentEntry = packed record
    LogicalBlock: LongWord;
    case Boolean of
      False: (
        Length: Word;
        StartHigh: Word;
        StartLow: LongWord);
      True: (
        ChildLow: LongWord;
        ChildHigh: Word;
        Unused: Word);
  end;
  PExtentEntry = ^TExtentEntry;

  TDirectoryEntryHeader = packed record
    InodeNumber: LongWord;
    RecordLength: Word;
    NameLength: Byte;
    FileType: Byte;
  end;
  PDirectoryEntryHeader = ^TDirectoryEntryHeader;

function InodeSize(const Inode: TInode): QWord;
procedure SetInodeSize(var Inode: TInode; Size: QWord);
function DirectoryRecordLength(NameLength: LongWord): LongWord;

implementation

function InodeSize(const Inode: TInode): QWord;
begin
  Result := Inode.SizeLow or (QWord(Inode.SizeHigh) shl 32);
end;

procedure SetInodeSize(var Inode: TInode; Size: QWord);
begin
  Inode.SizeLow := LongWord(Size);
  Inode.SizeHigh := LongWord(Size shr 32);
end;

{ The smallest record that holds a name: header plus name, rounded up to
  a multiple of four. }
function DirectoryRecordLength(NameLength: LongWord): LongWord;
begin
  Result := (DirectoryEntryHeaderSize + NameLength + 3) and not LongWord(3);
end;

end.
