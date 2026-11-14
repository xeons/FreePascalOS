{
  ext2, ext3 and ext4 file system driver (read-only).

  The three are one family. ext3 adds a journal to ext2; ext4 adds
  extents, 64-bit block numbers, flexible block groups and more. This
  driver reads all of them:

    * Block groups and their descriptors (32 or 64 bytes, optionally laid
      out with META_BG).
    * Inodes of any size.
    * File data mapped either through classic block pointers (direct,
      single, double and triple indirect) or through extent trees.
    * Linear directories, including directories with an htree index (the
      index blocks look like empty entries to a linear reader).
    * Fast symbolic links stored inside the inode, and slow ones stored in
      a data block.

  A volume that needs journal recovery is still mounted, with a warning:
  the journal is not replayed, so the most recent changes may be missing.

  Name lookups are exact (case sensitive).
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
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache,
  Debug.Output;

const
  SuperblockOffset = 1024;
  ExtMagic = $EF53;
  RootInodeNumber = 2;
  GoodOldInodeSize = 128;
  GoodOldRevision = 0;

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

  SupportedIncompatibleFeatures = IncompatibleFileType or IncompatibleNeedsRecovery or
    IncompatibleMetaBlockGroups or IncompatibleExtents or Incompatible64Bit or
    IncompatibleMultipleMountProtection or IncompatibleFlexibleBlockGroups or
    IncompatibleExtendedAttributeInodes or IncompatibleChecksumSeed or
    IncompatibleLargeDirectories or IncompatibleInlineData or IncompatibleEncryption or
    IncompatibleCaseFolding;

  ReadOnlyCompatibleSparseSuper = $0001;
  ReadOnlyCompatibleHugeFile = $0008;
  ReadOnlyCompatibleGroupDescriptorChecksum = $0010;
  ReadOnlyCompatibleDirectoryLinkCount = $0020;
  ReadOnlyCompatibleExtraInodeSize = $0040;
  ReadOnlyCompatibleMetadataChecksum = $0400;

  { Features that only exist from ext4 on. }
  Ext4OnlyIncompatibleFeatures = IncompatibleExtents or Incompatible64Bit or
    IncompatibleFlexibleBlockGroups or IncompatibleInlineData or IncompatibleLargeDirectories;
  Ext4OnlyReadOnlyCompatibleFeatures = ReadOnlyCompatibleHugeFile or
    ReadOnlyCompatibleGroupDescriptorChecksum or ReadOnlyCompatibleDirectoryLinkCount or
    ReadOnlyCompatibleExtraInodeSize or ReadOnlyCompatibleMetadataChecksum;

  ModeTypeMask = $F000;
  ModeTypeDirectory = $4000;
  ModeTypeRegular = $8000;
  ModeTypeSymbolicLink = $A000;
  ModePermissionMask = $0FFF;

  InodeFlagExtents = $00080000;
  InodeFlagInlineData = $10000000;
  InodeFlagHugeFile = $00040000;

  ExtentMagic = $F30A;
  ExtentUninitializedLength = 32768;
  MaximumExtentDepth = 5;

  DirectBlockCount = 12;
  SingleIndirectSlot = 12;
  DoubleIndirectSlot = 13;
  TripleIndirectSlot = 14;

  InlineDataCapacity = 60;
  DirectoryEntryHeaderSize = 8;

  FileTypeRegular = 1;
  FileTypeDirectory = 2;
  FileTypeSymbolicLink = 7;

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

  TGroupDescriptor = packed record
    BlockBitmapLow: LongWord;
    InodeBitmapLow: LongWord;
    InodeTableLow: LongWord;
    FreeBlocksCountLow: Word;
    FreeInodesCountLow: Word;
    UsedDirectoriesCountLow: Word;
    Flags: Word;
    ExcludeBitmapLow: LongWord;
    BlockBitmapChecksumLow: Word;
    InodeBitmapChecksumLow: Word;
    UnusedInodeCountLow: Word;
    Checksum: Word;
    { Present when the descriptor size is 64 bytes. }
    BlockBitmapHigh: LongWord;
    InodeBitmapHigh: LongWord;
    InodeTableHigh: LongWord;
  end;

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
    OsDependent2: array[0..11] of Byte;
  end;

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

  PExtVolume = ^TExtVolume;
  TExtVolume = record
    BlockSize: QWord;
    InodeSize: LongWord;
    InodesPerGroup: LongWord;
    BlocksPerGroup: LongWord;
    FirstDataBlock: LongWord;
    GroupCount: LongWord;
    DescriptorSize: LongWord;
    DescriptorsPerBlock: LongWord;
    FirstMetaBlockGroup: LongWord;
    FeatureIncompatible: LongWord;
    FeatureReadOnlyCompatible: LongWord;
    BlockCount: QWord;
  end;

  PExtNode = ^TExtNode;
  TExtNode = record
    Common: TNode;
    InodeNumber: LongWord;
    Inode: TInode;
  end;

var
  Driver: TFileSystemDriver;

function ExtVolumeOf(Node: PNode): PExtVolume;
begin
  Result := PExtVolume(Node^.Volume^.DriverData);
end;

function HasIncompatibleFeature(Ext: PExtVolume; Feature: LongWord): Boolean;
begin
  Result := (Ext^.FeatureIncompatible and Feature) <> 0;
end;

{ --- Block groups and inodes ----------------------------------------- }

function IsPowerOf(Value, Base: LongWord): Boolean;
begin
  while (Value > 1) and ((Value mod Base) = 0) do
    Value := Value div Base;
  Result := Value = 1;
end;

{ With the sparse superblock feature only groups 0, 1 and powers of 3, 5
  and 7 hold superblock (and descriptor) backups. }
function GroupHasSuperblockBackup(Ext: PExtVolume; Group: LongWord): Boolean;
begin
  if (Ext^.FeatureReadOnlyCompatible and ReadOnlyCompatibleSparseSuper) = 0 then
    Exit(True);
  Result := (Group <= 1) or IsPowerOf(Group, 3) or IsPowerOf(Group, 5) or IsPowerOf(Group, 7);
end;

function GroupDescriptorOffset(Ext: PExtVolume; Group: LongWord): QWord;
var
  MetaGroup: LongWord;
  FirstGroupOfMeta: LongWord;
  DescriptorBlock: QWord;
begin
  if (not HasIncompatibleFeature(Ext, IncompatibleMetaBlockGroups)) or
     (Group < Ext^.FirstMetaBlockGroup * Ext^.DescriptorsPerBlock) then
    Exit((QWord(Ext^.FirstDataBlock) + 1) * Ext^.BlockSize + QWord(Group) * Ext^.DescriptorSize);

  { With META_BG each run of DescriptorsPerBlock groups keeps its single
    descriptor block in the first group of the run. }
  MetaGroup := Group div Ext^.DescriptorsPerBlock;
  FirstGroupOfMeta := MetaGroup * Ext^.DescriptorsPerBlock;
  DescriptorBlock := QWord(Ext^.FirstDataBlock) + QWord(FirstGroupOfMeta) * Ext^.BlocksPerGroup;
  if GroupHasSuperblockBackup(Ext, FirstGroupOfMeta) then
    Inc(DescriptorBlock);
  Result := DescriptorBlock * Ext^.BlockSize + QWord(Group mod Ext^.DescriptorsPerBlock) * Ext^.DescriptorSize;
end;

function ReadInodeTableBlock(Volume: PVolume; Group: LongWord; out TableBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: TGroupDescriptor;
  BytesToRead: LongWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  ZeroMemory(@Descriptor, SizeOf(Descriptor));
  BytesToRead := Ext^.DescriptorSize;
  if BytesToRead > SizeOf(Descriptor) then
    BytesToRead := SizeOf(Descriptor);
  if not VolumeRead(Volume, GroupDescriptorOffset(Ext, Group), BytesToRead, @Descriptor) then
    Exit(StatusIoError);

  TableBlock := Descriptor.InodeTableLow;
  if Ext^.DescriptorSize >= 64 then
    TableBlock := TableBlock or (QWord(Descriptor.InodeTableHigh) shl 32);
  if (TableBlock = 0) or (TableBlock >= Ext^.BlockCount) then
    Exit(StatusCorrupted);
  Result := StatusSuccess;
end;

function ReadInode(Volume: PVolume; InodeNumber: LongWord; out Inode: TInode): TFileSystemStatus;
var
  Ext: PExtVolume;
  Group: LongWord;
  IndexInGroup: LongWord;
  TableBlock: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  ZeroMemory(@Inode, SizeOf(Inode));
  if (InodeNumber = 0) or (InodeNumber > Ext^.InodesPerGroup * Ext^.GroupCount) then
    Exit(StatusCorrupted);

  Group := (InodeNumber - 1) div Ext^.InodesPerGroup;
  IndexInGroup := (InodeNumber - 1) mod Ext^.InodesPerGroup;
  Result := ReadInodeTableBlock(Volume, Group, TableBlock);
  if Result <> StatusSuccess then
    Exit;

  if not VolumeRead(Volume, TableBlock * Ext^.BlockSize + QWord(IndexInGroup) * Ext^.InodeSize,
    SizeOf(TInode), @Inode) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

function InodeSize(const Inode: TInode): QWord;
begin
  Result := Inode.SizeLow or (QWord(Inode.SizeHigh) shl 32);
end;

{ --- Block mapping: extent trees ------------------------------------- }

function ReadExtentHeader(Volume: PVolume; Address: QWord; out Header: TExtentHeader): Boolean;
begin
  Result := VolumeRead(Volume, Address, SizeOf(Header), @Header) and (Header.Magic = ExtentMagic);
end;

{ Maps a logical block through an extent tree whose root header and
  entries are stored in the inode's block array. }
function MapThroughExtents(Node: PExtNode; LogicalBlock: LongWord; out PhysicalBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Header: TExtentHeader;
  Entry: TExtentEntry;
  NextEntry: TExtentEntry;
  RootEntries: PExtentEntry;
  FromInode: Boolean;
  NodeAddress: QWord;
  EntryIndex: Integer;
  ChosenIndex: Integer;
  Level: Integer;
  Length: LongWord;
  StartBlock: QWord;

  function GetEntry(Index: Integer; out Value: TExtentEntry): Boolean;
  begin
    if FromInode then
    begin
      Value := RootEntries[Index];
      Result := True;
    end
    else
      Result := VolumeRead(Node^.Common.Volume,
        NodeAddress + SizeOf(TExtentHeader) + QWord(Index) * SizeOf(TExtentEntry),
        SizeOf(TExtentEntry), @Value);
  end;

begin
  PhysicalBlock := 0;
  Ext := ExtVolumeOf(@Node^.Common);
  Header := PExtentHeader(@Node^.Inode.Block[0])^;
  if Header.Magic <> ExtentMagic then
    Exit(StatusCorrupted);
  RootEntries := PExtentEntry(PByte(@Node^.Inode.Block[0]) + SizeOf(TExtentHeader));
  FromInode := True;
  NodeAddress := 0;

  for Level := 0 to MaximumExtentDepth do
  begin
    if Header.Depth = 0 then
    begin
      { Leaf: find the extent that covers the block, if any. }
      for EntryIndex := 0 to Integer(Header.Entries) - 1 do
      begin
        if not GetEntry(EntryIndex, Entry) then
          Exit(StatusIoError);
        Length := Entry.Length;
        if Length > ExtentUninitializedLength then
        begin
          { Allocated but never written: reads as zeros, like a hole. }
          if (LogicalBlock >= Entry.LogicalBlock) and
             (LogicalBlock < Entry.LogicalBlock + (Length - ExtentUninitializedLength)) then
            Exit(StatusSuccess);
          Continue;
        end;
        if (LogicalBlock >= Entry.LogicalBlock) and (LogicalBlock < Entry.LogicalBlock + Length) then
        begin
          StartBlock := Entry.StartLow or (QWord(Entry.StartHigh) shl 32);
          PhysicalBlock := StartBlock + (LogicalBlock - Entry.LogicalBlock);
          if PhysicalBlock >= Ext^.BlockCount then
            Exit(StatusCorrupted);
          Exit(StatusSuccess);
        end;
      end;
      Exit(StatusSuccess); { a hole }
    end;

    { Index node: descend into the last child starting at or before the
      wanted block. }
    if Header.Entries = 0 then
      Exit(StatusSuccess);
    ChosenIndex := 0;
    for EntryIndex := 1 to Integer(Header.Entries) - 1 do
    begin
      if not GetEntry(EntryIndex, NextEntry) then
        Exit(StatusIoError);
      if NextEntry.LogicalBlock > LogicalBlock then
        Break;
      ChosenIndex := EntryIndex;
    end;
    if not GetEntry(ChosenIndex, Entry) then
      Exit(StatusIoError);

    StartBlock := Entry.ChildLow or (QWord(Entry.ChildHigh) shl 32);
    if StartBlock >= Ext^.BlockCount then
      Exit(StatusCorrupted);
    NodeAddress := StartBlock * Ext^.BlockSize;
    FromInode := False;
    if not ReadExtentHeader(Node^.Common.Volume, NodeAddress, Header) then
      Exit(StatusCorrupted);
  end;
  Result := StatusCorrupted; { deeper than any valid tree }
end;

{ --- Block mapping: classic block pointers --------------------------- }

function ReadBlockPointer(Volume: PVolume; TableBlock: QWord; Index: QWord;
  out Value: LongWord): Boolean;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := VolumeRead(Volume, TableBlock * Ext^.BlockSize + Index * 4, 4, @Value);
end;

{ Blocks 0-11 are listed in the inode. After those, block slot 12 points
  at a table of block numbers, slot 13 at a table of tables, and slot 14
  at a table of tables of tables. }
function MapThroughBlockPointers(Node: PExtNode; LogicalBlock: LongWord;
  out PhysicalBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  PointersPerBlock: QWord;
  Remaining: QWord;
  LevelCount: Integer;
  Level: Integer;
  BlocksPerEntry: QWord;
  Multiplication: Integer;
  TableBlock: LongWord;
  NextBlock: LongWord;
  IndexInTable: QWord;
begin
  PhysicalBlock := 0;
  Volume := Node^.Common.Volume;
  Ext := ExtVolumeOf(@Node^.Common);
  PointersPerBlock := Ext^.BlockSize div 4;
  Remaining := LogicalBlock;

  if Remaining < DirectBlockCount then
  begin
    PhysicalBlock := Node^.Inode.Block[Remaining];
    Exit(StatusSuccess);
  end;
  Remaining := Remaining - DirectBlockCount;

  if Remaining < PointersPerBlock then
  begin
    TableBlock := Node^.Inode.Block[SingleIndirectSlot];
    LevelCount := 1;
  end
  else
  begin
    Remaining := Remaining - PointersPerBlock;
    if Remaining < PointersPerBlock * PointersPerBlock then
    begin
      TableBlock := Node^.Inode.Block[DoubleIndirectSlot];
      LevelCount := 2;
    end
    else
    begin
      Remaining := Remaining - PointersPerBlock * PointersPerBlock;
      if Remaining >= PointersPerBlock * PointersPerBlock * PointersPerBlock then
        Exit(StatusCorrupted);
      TableBlock := Node^.Inode.Block[TripleIndirectSlot];
      LevelCount := 3;
    end;
  end;

  for Level := LevelCount downto 1 do
  begin
    if TableBlock = 0 then
      Exit(StatusSuccess); { a hole }
    if TableBlock >= Ext^.BlockCount then
      Exit(StatusCorrupted);

    { Each entry at this level covers PointersPerBlock^(Level - 1) blocks. }
    BlocksPerEntry := 1;
    for Multiplication := 2 to Level do
      BlocksPerEntry := BlocksPerEntry * PointersPerBlock;
    IndexInTable := Remaining div BlocksPerEntry;
    Remaining := Remaining mod BlocksPerEntry;

    if not ReadBlockPointer(Volume, TableBlock, IndexInTable, NextBlock) then
      Exit(StatusIoError);
    TableBlock := NextBlock;
  end;

  PhysicalBlock := TableBlock;
  Result := StatusSuccess;
end;

function MapLogicalBlock(Node: PExtNode; LogicalBlock: LongWord; out PhysicalBlock: QWord): TFileSystemStatus;
begin
  if (Node^.Inode.Flags and InodeFlagExtents) <> 0 then
    Result := MapThroughExtents(Node, LogicalBlock, PhysicalBlock)
  else
    Result := MapThroughBlockPointers(Node, LogicalBlock, PhysicalBlock);
end;

{ --- Data access ----------------------------------------------------- }

{ Reads data of the node, treating holes as zeros. The range must lie
  within the file. }
function ReadNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Buffer: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
  LogicalBlock: QWord;
  OffsetInBlock: QWord;
  ChunkBytes: QWord;
  PhysicalBlock: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);

  if (Node^.Inode.Flags and InodeFlagInlineData) <> 0 then
  begin
    { Small files may live entirely inside the inode's block array. Data
      beyond that spills into an extended attribute, not supported yet. }
    if Offset + ByteCount > InlineDataCapacity then
      Exit(StatusUnsupported);
    CopyMemory(Buffer, PByte(@Node^.Inode.Block[0]) + Offset, ByteCount);
    Exit(StatusSuccess);
  end;

  while ByteCount > 0 do
  begin
    LogicalBlock := Offset div Ext^.BlockSize;
    if LogicalBlock > High(LongWord) then
      Exit(StatusCorrupted);
    OffsetInBlock := Offset mod Ext^.BlockSize;
    ChunkBytes := Ext^.BlockSize - OffsetInBlock;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;

    Result := MapLogicalBlock(Node, LongWord(LogicalBlock), PhysicalBlock);
    if Result <> StatusSuccess then
      Exit;

    if PhysicalBlock = 0 then
      ZeroMemory(Buffer, ChunkBytes)
    else if not VolumeRead(Node^.Common.Volume, PhysicalBlock * Ext^.BlockSize + OffsetInBlock,
      ChunkBytes, Buffer) then
      Exit(StatusIoError);

    Buffer := Buffer + ChunkBytes;
    Offset := Offset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  Result := StatusSuccess;
end;

{ --- Nodes ----------------------------------------------------------- }

function KindFromMode(Mode: Word): TNodeKind;
begin
  case Mode and ModeTypeMask of
    ModeTypeDirectory: Result := NodeKindDirectory;
    ModeTypeRegular: Result := NodeKindFile;
    ModeTypeSymbolicLink: Result := NodeKindSymbolicLink;
  else
    Result := NodeKindOther;
  end;
end;

function KindFromDirectoryFileType(FileType: Byte): TNodeKind;
begin
  case FileType of
    FileTypeRegular: Result := NodeKindFile;
    FileTypeDirectory: Result := NodeKindDirectory;
    FileTypeSymbolicLink: Result := NodeKindSymbolicLink;
  else
    Result := NodeKindOther;
  end;
end;

function LoadNode(Volume: PVolume; InodeNumber: LongWord; out Node: PExtNode): TFileSystemStatus;
begin
  Node := PExtNode(AllocateZeroedKernelMemory(SizeOf(TExtNode)));
  if Node = nil then
    Exit(StatusOutOfMemory);

  Result := ReadInode(Volume, InodeNumber, Node^.Inode);
  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Node);
    Node := nil;
    Exit;
  end;

  Node^.Common.Volume := Volume;
  Node^.InodeNumber := InodeNumber;
  Node^.Common.Information.Kind := KindFromMode(Node^.Inode.Mode);
  Node^.Common.Information.SizeInBytes := InodeSize(Node^.Inode);
  Node^.Common.Information.NodeNumber := InodeNumber;
  Node^.Common.Information.LinkCount := Node^.Inode.LinksCount;
  Node^.Common.Information.Mode := Node^.Inode.Mode and ModePermissionMask;
  Node^.Common.Information.ModificationTime := Node^.Inode.ModificationTime;
end;

{ --- Directories ----------------------------------------------------- }

{ Reads the directory entry at Cursor.Position (a byte offset) and moves
  past it. Entries with inode number zero are unused space; they are
  skipped, as are "." and "..". }
function NextDirectoryEntry(Directory: PExtNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
var
  Ext: PExtVolume;
  DirectorySize: QWord;
  Header: TDirectoryEntryHeader;
  NameLength: LongWord;
  BlockRemainder: QWord;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  DirectorySize := InodeSize(Directory^.Inode);

  repeat
    if Cursor.Position + DirectoryEntryHeaderSize > DirectorySize then
      Exit(StatusEndOfDirectory);

    Result := ReadNodeData(Directory, Cursor.Position, DirectoryEntryHeaderSize, @Header);
    if Result <> StatusSuccess then
      Exit;

    BlockRemainder := Ext^.BlockSize - (Cursor.Position mod Ext^.BlockSize);
    if (Header.RecordLength < DirectoryEntryHeaderSize) or ((Header.RecordLength mod 4) <> 0) or
       (Header.RecordLength > BlockRemainder) then
      Exit(StatusCorrupted);

    if HasIncompatibleFeature(Ext, IncompatibleFileType) then
      NameLength := Header.NameLength
    else
      NameLength := Header.NameLength or (LongWord(Header.FileType) shl 8);

    if (Header.InodeNumber = 0) or (NameLength = 0) or
       (NameLength + DirectoryEntryHeaderSize > Header.RecordLength) then
    begin
      Cursor.Position := Cursor.Position + Header.RecordLength;
      Continue;
    end;

    Result := ReadNodeData(Directory, Cursor.Position + DirectoryEntryHeaderSize, NameLength,
      @Entry.Name[0]);
    if Result <> StatusSuccess then
      Exit;
    Entry.Name[NameLength] := #0;
    Cursor.Position := Cursor.Position + Header.RecordLength;

    if TextIsEqual(@Entry.Name[0], '.') or TextIsEqual(@Entry.Name[0], '..') then
      Continue;

    Entry.NodeNumber := Header.InodeNumber;
    if HasIncompatibleFeature(Ext, IncompatibleFileType) then
      Entry.Kind := KindFromDirectoryFileType(Header.FileType)
    else
      Entry.Kind := NodeKindOther;
    Exit(StatusSuccess);
  until False;
end;

{ --- Driver routines ------------------------------------------------- }

function DirectoryIsReadable(Directory: PExtNode): TFileSystemStatus;
begin
  if (Directory^.Inode.Flags and InodeFlagInlineData) <> 0 then
    Result := StatusUnsupported
  else
    Result := StatusSuccess;
end;

function ExtLookup(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
  Entry: TDirectoryEntry;
  Node: PExtNode;
begin
  Found := nil;
  Result := DirectoryIsReadable(PExtNode(Directory));
  if Result <> StatusSuccess then
    Exit;

  Cursor.Position := 0;
  Cursor.Extra := 0;
  repeat
    Result := NextDirectoryEntry(PExtNode(Directory), Cursor, Entry);
    if Result = StatusEndOfDirectory then
      Exit(StatusNotFound);
    if Result <> StatusSuccess then
      Exit;
  until TextIsEqual(@Entry.Name[0], Name);

  Result := LoadNode(Directory^.Volume, LongWord(Entry.NodeNumber), Node);
  if Result = StatusSuccess then
    Found := @Node^.Common;
end;

function ExtReadDirectory(Directory: PNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
begin
  Result := DirectoryIsReadable(PExtNode(Directory));
  if Result = StatusSuccess then
    Result := NextDirectoryEntry(PExtNode(Directory), Cursor, Entry);
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

{ A "fast" symbolic link keeps its target in the inode's block array
  instead of a data block. }
function IsFastSymbolicLink(Node: PExtNode): Boolean;
var
  Ext: PExtVolume;
  ExtendedAttributeBlocks: LongWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  if (Node^.Inode.Flags and (InodeFlagExtents or InodeFlagInlineData)) <> 0 then
    Exit(False);
  if InodeSize(Node^.Inode) >= InlineDataCapacity then
    Exit(False);
  ExtendedAttributeBlocks := 0;
  if Node^.Inode.FileAclLow <> 0 then
    ExtendedAttributeBlocks := LongWord(Ext^.BlockSize div 512);
  Result := Node^.Inode.BlocksLow = ExtendedAttributeBlocks;
end;

function ExtReadSymbolicLink(Node: PNode; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;
var
  ExtNode: PExtNode;
  LinkLength: QWord;
begin
  ExtNode := PExtNode(Node);
  LinkLength := InodeSize(ExtNode^.Inode);
  if LinkLength + 1 > Capacity then
    Exit(StatusNameTooLong);

  if IsFastSymbolicLink(ExtNode) then
  begin
    CopyMemory(Target, @ExtNode^.Inode.Block[0], LinkLength);
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

procedure WarnAboutUnreplayedJournal(Volume: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('ext');
  DebugWrite(@Volume^.Name[0]);
  DebugWriteLine(': journal needs recovery; mounting without replaying it');
  DebugEndMessage;
end;

function ExtMount(Volume: PVolume): TFileSystemStatus;
var
  Superblock: TSuperblock;
  Ext: PExtVolume;
  Root: PExtNode;
  UnsupportedFeatures: LongWord;
begin
  if not ReadSuperblock(Volume^.Device, Superblock) then
    Exit(StatusCorrupted);

  if Superblock.RevisionLevel = GoodOldRevision then
  begin
    Superblock.InodeSize := GoodOldInodeSize;
    Superblock.FeatureIncompatible := 0;
    Superblock.FeatureReadOnlyCompatible := 0;
    Superblock.FeatureCompatible := 0;
  end;

  UnsupportedFeatures := Superblock.FeatureIncompatible and not SupportedIncompatibleFeatures;
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
  Ext^.FeatureIncompatible := Superblock.FeatureIncompatible;
  Ext^.FeatureReadOnlyCompatible := Superblock.FeatureReadOnlyCompatible;
  Ext^.FirstMetaBlockGroup := Superblock.FirstMetaBlockGroup;

  Ext^.BlockCount := Superblock.BlocksCountLow;
  if HasIncompatibleFeature(Ext, Incompatible64Bit) then
    Ext^.BlockCount := Ext^.BlockCount or (QWord(Superblock.BlocksCountHigh) shl 32);

  if HasIncompatibleFeature(Ext, Incompatible64Bit) and (Superblock.DescriptorSize >= 64) then
    Ext^.DescriptorSize := Superblock.DescriptorSize
  else
    Ext^.DescriptorSize := 32;
  Ext^.DescriptorsPerBlock := LongWord(Ext^.BlockSize div Ext^.DescriptorSize);

  if (Ext^.InodeSize < GoodOldInodeSize) or (Ext^.InodeSize > Ext^.BlockSize) or
     (Ext^.BlockCount <= Ext^.FirstDataBlock) or
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

  if HasIncompatibleFeature(Ext, IncompatibleNeedsRecovery) then
    WarnAboutUnreplayedJournal(Volume);

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
  Result := @Driver;
end;

end.
