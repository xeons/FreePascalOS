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
  Mounted ext2/3/4 volume state: geometry, metadata checksums, group
  descriptors, inodes, and block and inode allocation.

  Checksums (ext4 "metadata_csum"): every piece of metadata carries a
  CRC32C. They are all seeded from the volume's checksum seed (the
  CRC32C of the volume UUID, or a stored seed), and per-inode structures
  (the inode itself, directory blocks, extent blocks) are additionally
  seeded with the inode number and generation. Volumes with only the
  older "gdt_csum" feature protect group descriptors with a CRC16.

  Allocation only takes blocks and inodes from block groups whose bitmaps
  are initialized; groups still marked uninitialized by mke2fs are left
  alone (except that an uninitialized inode bitmap is initialized on
  first use, which is simple: all zeros).
}
unit FileSystem.Ext.Volume;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Transactions;

type
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
    FeatureCompatible: LongWord;
    FeatureIncompatible: LongWord;
    FeatureReadOnlyCompatible: LongWord;
    BlockCount: QWord;
    FirstNonReservedInode: LongWord;
    WantExtraInodeSize: Word;
    HasMetadataChecksums: Boolean;
    HasGroupDescriptorChecksums: Boolean;
    ChecksumSeed: LongWord;
    Uuid: array[0..15] of Byte;
    { Free counters, written to the superblock by SyncSuperblock. }
    FreeBlockCount: QWord;
    FreeInodeCount: LongWord;
    SuperblockNeedsWriting: Boolean;
    { The journal being written, nil for volumes written in place. }
    Journal: PExtJournal;
    { Files removed while open, newest first: the in-memory copy of the
      orphan list that starts at the superblock (FileSystem.Ext.Orphans). }
    FirstOrphan: Pointer;
    { The earliest deletion time written into a freed inode: the
      superblock's inode count at least, since e2fsck reads a smaller
      deletion time as a link of the orphan list (a damaged one, as the
      inode is not on it), and not before the volume was made or last
      written. The wall clock starts at zero on machines without a
      real-time clock, so the uptime alone is no deletion time. }
    EarliestDeletionTime: LongWord;
  end;

  PExtNode = ^TExtNode;
  TExtNode = record
    Common: TNode;
    InodeNumber: LongWord;
    { The complete on-disk inode (InodeSize bytes); its first part is
      reached through InodeRecord. }
    InodeBytes: array[0..MaximumInodeSize - 1] of Byte;
    { On the orphan list: removed while open; the next one on it. }
    IsOrphan: Boolean;
    NextOrphan: PExtNode;
  end;

function ExtVolumeOf(Node: PNode): PExtVolume;

{ All of the driver's disk accesses go through these. Reads see the
  running transaction; metadata writes go into it (on journaled
  volumes); file data is written in place. A nil Buffer writes zeros. }
function ExtRead(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
function ExtWriteMetadata(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
function ExtWriteData(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;

function InodeRecord(Node: PExtNode): PInode;
function HasIncompatibleFeature(Ext: PExtVolume; Feature: LongWord): Boolean;

{ --- Checksums --- }
function InodeChecksumSeed(Ext: PExtVolume; InodeNumber: LongWord; Generation: LongWord): LongWord;
procedure UpdateInodeChecksum(Ext: PExtVolume; InodeNumber: LongWord; InodeBytes: PByte);
{ Checksum of a block owned by Node (directory leaf or extent block):
  the CRC32C, seeded per inode, of the first ByteCount bytes. }
function NodeBlockChecksum(Node: PExtNode; Data: PByte; ByteCount: QWord): LongWord;

{ --- Group descriptors --- }
function GroupDescriptorOffset(Ext: PExtVolume; Group: LongWord): QWord;
function ReadGroupDescriptor(Volume: PVolume; Group: LongWord; Descriptor: PByte): TFileSystemStatus;
{ Recomputes the descriptor checksum and writes it. }
function WriteGroupDescriptor(Volume: PVolume; Group: LongWord; Descriptor: PByte): TFileSystemStatus;
function DescriptorValue(Ext: PExtVolume; Descriptor: PByte; LowOffset, HighOffset: Integer;
  IsWide: Boolean): QWord;
procedure SetDescriptorValue(Ext: PExtVolume; Descriptor: PByte; LowOffset, HighOffset: Integer;
  IsWide: Boolean; Value: QWord);

{ --- Inodes --- }
{ Copies the inode's type, size, links, mode and time into the node's
  generic information. }
procedure RefreshNodeInformation(Node: PExtNode);
function ReadInodeBytes(Volume: PVolume; InodeNumber: LongWord; Destination: PByte): TFileSystemStatus;
{ Writes Node's inode back, updating its checksum. }
function WriteNodeInode(Node: PExtNode): TFileSystemStatus;

{ --- Allocation --- }
{ Allocates one zero filled block, preferably close to Goal. }
function AllocateBlock(Volume: PVolume; Goal: QWord; out Block: QWord): TFileSystemStatus;
function FreeBlock(Volume: PVolume; Block: QWord): TFileSystemStatus;
{ Allocates an inode, preferably in PreferredGroup. }
function AllocateInode(Volume: PVolume; PreferredGroup: LongWord; IsDirectory: Boolean;
  out InodeNumber: LongWord): TFileSystemStatus;
function FreeInode(Volume: PVolume; InodeNumber: LongWord; IsDirectory: Boolean): TFileSystemStatus;
function GroupOfInode(Ext: PExtVolume; InodeNumber: LongWord): LongWord;
function GroupOfBlock(Ext: PExtVolume; Block: QWord): LongWord;

{ Brings the superblock's free counters and checksum up to date. }
function SyncSuperblock(Volume: PVolume): TFileSystemStatus;

{ fstrim: discards every run of free blocks (groups whose block bitmap
  is still uninitialized are left alone). }
function TrimFreeBlocks(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Checksums,
  Memory.KernelHeap,
  FileSystem.Discards;

function ExtVolumeOf(Node: PNode): PExtVolume;
begin
  Result := PExtVolume(Node^.Volume^.DriverData);
end;

function JournalOf(Volume: PVolume): PExtJournal;
begin
  Result := PExtVolume(Volume^.DriverData)^.Journal;
end;

function ExtRead(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  Result := JournalRead(JournalOf(Volume), Volume, Offset, ByteCount, Buffer);
end;

function ExtWriteMetadata(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  Result := JournalWriteMetadata(JournalOf(Volume), Volume, Offset, ByteCount, Buffer);
end;

function ExtWriteData(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  Result := JournalWriteData(JournalOf(Volume), Volume, Offset, ByteCount, Buffer);
end;

function InodeRecord(Node: PExtNode): PInode;
begin
  Result := PInode(@Node^.InodeBytes[0]);
end;

function HasIncompatibleFeature(Ext: PExtVolume; Feature: LongWord): Boolean;
begin
  Result := (Ext^.FeatureIncompatible and Feature) <> 0;
end;

{ --- Checksums ------------------------------------------------------- }

function Crc32cOfLongWord(Seed: LongWord; Value: LongWord): LongWord;
begin
  Result := Crc32cUpdate(Seed, @Value, 4);
end;

function InodeChecksumSeed(Ext: PExtVolume; InodeNumber: LongWord; Generation: LongWord): LongWord;
begin
  Result := Crc32cOfLongWord(Crc32cOfLongWord(Ext^.ChecksumSeed, InodeNumber), Generation);
end;

{ The inode checksum covers the whole inode with the checksum fields
  counted as zero. The high half only exists when the extra inode area
  is large enough to hold it. }
procedure UpdateInodeChecksum(Ext: PExtVolume; InodeNumber: LongWord; InodeBytes: PByte);
var
  Inode: PInode;
  ExtraSize: Word;
  HasHighHalf: Boolean;
  Checksum: LongWord;
begin
  if not Ext^.HasMetadataChecksums then
    Exit;
  Inode := PInode(InodeBytes);

  HasHighHalf := False;
  if Ext^.InodeSize > GoodOldInodeSize then
  begin
    ExtraSize := PWord(InodeBytes + InodeExtraSizeOffset)^;
    HasHighHalf := GoodOldInodeSize + ExtraSize >= InodeChecksumHighOffset + 2;
  end;

  Inode^.ChecksumLow := 0;
  if HasHighHalf then
    PWord(InodeBytes + InodeChecksumHighOffset)^ := 0;

  Checksum := Crc32cUpdate(InodeChecksumSeed(Ext, InodeNumber, Inode^.Generation),
    InodeBytes, Ext^.InodeSize);

  Inode^.ChecksumLow := Word(Checksum and $FFFF);
  if HasHighHalf then
    PWord(InodeBytes + InodeChecksumHighOffset)^ := Word(Checksum shr 16);
end;

function NodeBlockChecksum(Node: PExtNode; Data: PByte; ByteCount: QWord): LongWord;
var
  Ext: PExtVolume;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Result := Crc32cUpdate(InodeChecksumSeed(Ext, Node^.InodeNumber, InodeRecord(Node)^.Generation),
    Data, ByteCount);
end;

{ --- Group descriptors ----------------------------------------------- }

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

function ReadGroupDescriptor(Volume: PVolume; Group: LongWord; Descriptor: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  FillMemory(Descriptor, MaximumDescriptorSize, 0);
  if Group >= Ext^.GroupCount then
    Exit(StatusCorrupted);
  if not ExtRead(Volume, GroupDescriptorOffset(Ext, Group), Ext^.DescriptorSize, Descriptor) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

function GroupDescriptorChecksum(Ext: PExtVolume; Group: LongWord; Descriptor: PByte): Word;
var
  Crc32Value: LongWord;
  Crc16Value: Word;
  Zero: Word;
  AfterChecksum: LongWord;
begin
  Zero := 0;
  AfterChecksum := DescriptorOffsetChecksum + 2;
  if Ext^.HasMetadataChecksums then
  begin
    Crc32Value := Crc32cOfLongWord(Ext^.ChecksumSeed, Group);
    Crc32Value := Crc32cUpdate(Crc32Value, Descriptor, DescriptorOffsetChecksum);
    Crc32Value := Crc32cUpdate(Crc32Value, @Zero, 2);
    if AfterChecksum < Ext^.DescriptorSize then
      Crc32Value := Crc32cUpdate(Crc32Value, Descriptor + AfterChecksum, Ext^.DescriptorSize - AfterChecksum);
    Result := Word(Crc32Value and $FFFF);
  end
  else
  begin
    Crc16Value := Crc16Update($FFFF, @Ext^.Uuid[0], 16);
    Crc16Value := Crc16Update(Crc16Value, @Group, 4);
    Crc16Value := Crc16Update(Crc16Value, Descriptor, DescriptorOffsetChecksum);
    if HasIncompatibleFeature(Ext, Incompatible64Bit) and (AfterChecksum < Ext^.DescriptorSize) then
      Crc16Value := Crc16Update(Crc16Value, Descriptor + AfterChecksum, Ext^.DescriptorSize - AfterChecksum);
    Result := Crc16Value;
  end;
end;

function WriteGroupDescriptor(Volume: PVolume; Group: LongWord; Descriptor: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  if Ext^.HasMetadataChecksums or Ext^.HasGroupDescriptorChecksums then
    PWord(Descriptor + DescriptorOffsetChecksum)^ := GroupDescriptorChecksum(Ext, Group, Descriptor);
  if not ExtWriteMetadata(Volume, GroupDescriptorOffset(Ext, Group), Ext^.DescriptorSize, Descriptor) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

{ Descriptor fields are split into a low part and, in 64-byte
  descriptors, a high part. IsWide selects 32-bit (True) or 16-bit
  halves. }
function DescriptorValue(Ext: PExtVolume; Descriptor: PByte; LowOffset, HighOffset: Integer;
  IsWide: Boolean): QWord;
begin
  if IsWide then
  begin
    Result := PLongWord(Descriptor + LowOffset)^;
    if Ext^.DescriptorSize >= MaximumDescriptorSize then
      Result := Result or (QWord(PLongWord(Descriptor + HighOffset)^) shl 32);
  end
  else
  begin
    Result := PWord(Descriptor + LowOffset)^;
    if Ext^.DescriptorSize >= MaximumDescriptorSize then
      Result := Result or (QWord(PWord(Descriptor + HighOffset)^) shl 16);
  end;
end;

procedure SetDescriptorValue(Ext: PExtVolume; Descriptor: PByte; LowOffset, HighOffset: Integer;
  IsWide: Boolean; Value: QWord);
begin
  if IsWide then
  begin
    PLongWord(Descriptor + LowOffset)^ := LongWord(Value);
    if Ext^.DescriptorSize >= MaximumDescriptorSize then
      PLongWord(Descriptor + HighOffset)^ := LongWord(Value shr 32);
  end
  else
  begin
    PWord(Descriptor + LowOffset)^ := Word(Value);
    if Ext^.DescriptorSize >= MaximumDescriptorSize then
      PWord(Descriptor + HighOffset)^ := Word(Value shr 16);
  end;
end;

{ --- Inodes ---------------------------------------------------------- }

function GroupOfInode(Ext: PExtVolume; InodeNumber: LongWord): LongWord;
begin
  Result := (InodeNumber - 1) div Ext^.InodesPerGroup;
end;

function GroupOfBlock(Ext: PExtVolume; Block: QWord): LongWord;
begin
  Result := LongWord((Block - Ext^.FirstDataBlock) div Ext^.BlocksPerGroup);
end;

function InodeOffset(Volume: PVolume; InodeNumber: LongWord; out Offset: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  Group: LongWord;
  TableBlock: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Offset := 0;
  if (InodeNumber = 0) or (InodeNumber > Ext^.InodesPerGroup * Ext^.GroupCount) then
    Exit(StatusCorrupted);

  Group := GroupOfInode(Ext, InodeNumber);
  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  TableBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetInodeTableLow,
    DescriptorOffsetInodeTableHigh, True);
  if (TableBlock = 0) or (TableBlock >= Ext^.BlockCount) then
    Exit(StatusCorrupted);

  Offset := TableBlock * Ext^.BlockSize + QWord((InodeNumber - 1) mod Ext^.InodesPerGroup) * Ext^.InodeSize;
end;

{ i_blocks counts 512-byte sectors, or file system blocks for inodes
  with the huge file flag. }
function AllocatedBytesOf(Node: PExtNode): QWord;
var
  Inode: PInode;
  Blocks: QWord;
begin
  Inode := InodeRecord(Node);
  Blocks := Inode^.BlocksLow or (QWord(Inode^.BlocksHigh) shl 32);
  if (Inode^.Flags and InodeFlagHugeFile) <> 0 then
    Result := Blocks * ExtVolumeOf(@Node^.Common)^.BlockSize
  else
    Result := Blocks * 512;
end;

const
  { The extra time fields of a large inode: nanoseconds (bits 2-31)
    and two more bits of seconds (0-1) after each 32-bit time. }
  InodeChangeTimeExtra = $84;
  InodeModificationTimeExtra = $88;
  InodeAccessTimeExtra = $8C;
  InodeCreationTimeExtra = $94;

{ True if the inode is large enough to hold the 32-bit field at
  FieldOffset. }
function InodeHasField(Node: PExtNode; FieldOffset: LongWord): Boolean;
var
  ExtraSize: Word;
begin
  if ExtVolumeOf(@Node^.Common)^.InodeSize <= GoodOldInodeSize then
    Exit(False);
  ExtraSize := PWord(@Node^.InodeBytes[InodeExtraSizeOffset])^;
  Result := GoodOldInodeSize + ExtraSize >= FieldOffset + 4;
end;

{ Applies an extra time field to Seconds (from the base field) and
  gives its nanoseconds. }
procedure ApplyExtraTime(Node: PExtNode; ExtraOffset: LongWord; var Seconds: Int64;
  out Nanoseconds: LongWord);
var
  Extra: LongWord;
begin
  Nanoseconds := 0;
  if not InodeHasField(Node, ExtraOffset) then
    Exit;
  Extra := PLongWord(@Node^.InodeBytes[ExtraOffset])^;
  Nanoseconds := Extra shr 2;
  if Nanoseconds > 999999999 then
    Nanoseconds := 0;
  if (Extra and 3) <> 0 then
    Seconds := Int64(LongInt(LongWord(Seconds))) + (Int64(Extra and 3) shl 32);
end;

{ The nanoseconds and the time the inode was made (crtime), where the
  inode is large enough to have them. }
procedure RefreshExtraTimes(Node: PExtNode);
var
  Information: ^TNodeInformation;
  Birth: Int64;
begin
  Information := @Node^.Common.Information;
  ApplyExtraTime(Node, InodeChangeTimeExtra, Information^.ChangeTime, Information^.ChangeNanoseconds);
  ApplyExtraTime(Node, InodeModificationTimeExtra, Information^.ModificationTime,
    Information^.ModificationNanoseconds);
  ApplyExtraTime(Node, InodeAccessTimeExtra, Information^.AccessTime, Information^.AccessNanoseconds);
  Information^.BirthTime := 0;
  Information^.BirthNanoseconds := 0;
  if InodeHasField(Node, InodeCreationTimeOffset) then
  begin
    Birth := PLongWord(@Node^.InodeBytes[InodeCreationTimeOffset])^;
    ApplyExtraTime(Node, InodeCreationTimeExtra, Birth, Information^.BirthNanoseconds);
    Information^.BirthTime := Birth;
  end;
end;

procedure RefreshNodeInformation(Node: PExtNode);
var
  Inode: PInode;
begin
  Inode := InodeRecord(Node);
  case Inode^.Mode and ModeTypeMask of
    ModeTypeDirectory: Node^.Common.Information.Kind := NodeKindDirectory;
    ModeTypeRegular: Node^.Common.Information.Kind := NodeKindFile;
    ModeTypeSymbolicLink: Node^.Common.Information.Kind := NodeKindSymbolicLink;
    ModeTypeFifo: Node^.Common.Information.Kind := NodeKindFifo;
  else
    Node^.Common.Information.Kind := NodeKindOther;
  end;
  Node^.Common.Information.SizeInBytes := InodeSize(Inode^);
  Node^.Common.Information.NodeNumber := Node^.InodeNumber;
  Node^.Common.Information.LinkCount := Inode^.LinksCount;
  Node^.Common.Information.Mode := Inode^.Mode and ModePermissionMask;
  Node^.Common.Information.OwnerId := Inode^.UserId or (LongWord(Inode^.UserIdHigh) shl 16);
  Node^.Common.Information.GroupId := Inode^.GroupId or (LongWord(Inode^.GroupIdHigh) shl 16);
  Node^.Common.Information.ModificationTime := Inode^.ModificationTime;
  Node^.Common.Information.AccessTime := Inode^.AccessTime;
  Node^.Common.Information.ChangeTime := Inode^.ChangeTime;
  RefreshExtraTimes(Node);
  Node^.Common.Information.AllocatedBytes := AllocatedBytesOf(Node);
end;

function ReadInodeBytes(Volume: PVolume; InodeNumber: LongWord; Destination: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
  Offset: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := InodeOffset(Volume, InodeNumber, Offset);
  if Result <> StatusSuccess then
    Exit;
  if not ExtRead(Volume, Offset, Ext^.InodeSize, Destination) then
    Result := StatusIoError;
end;

function WriteNodeInode(Node: PExtNode): TFileSystemStatus;
var
  Ext: PExtVolume;
  Offset: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Result := InodeOffset(Node^.Common.Volume, Node^.InodeNumber, Offset);
  if Result <> StatusSuccess then
    Exit;
  UpdateInodeChecksum(Ext, Node^.InodeNumber, @Node^.InodeBytes[0]);
  if not ExtWriteMetadata(Node^.Common.Volume, Offset, Ext^.InodeSize, @Node^.InodeBytes[0]) then
    Result := StatusIoError;
end;

{ --- Bitmaps --------------------------------------------------------- }

{ Bitmap checksums cover clusters (or inodes) per group, in bytes. }
procedure UpdateBitmapChecksum(Ext: PExtVolume; Descriptor: PByte; Bitmap: PByte;
  ByteCount: LongWord; LowOffset, HighOffset: Integer);
var
  Checksum: LongWord;
begin
  if not Ext^.HasMetadataChecksums then
    Exit;
  Checksum := Crc32cUpdate(Ext^.ChecksumSeed, Bitmap, ByteCount);
  PWord(Descriptor + LowOffset)^ := Word(Checksum and $FFFF);
  if Ext^.DescriptorSize >= MaximumDescriptorSize then
    PWord(Descriptor + HighOffset)^ := Word(Checksum shr 16);
end;

{ Reads a whole bitmap block into a heap buffer. }
function LoadBitmap(Volume: PVolume; BitmapBlock: QWord; out Bitmap: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Bitmap := PByte(AllocateKernelMemory(Ext^.BlockSize));
  if Bitmap = nil then
    Exit(StatusOutOfMemory);
  if not ExtRead(Volume, BitmapBlock * Ext^.BlockSize, Ext^.BlockSize, Bitmap) then
  begin
    FreeKernelMemory(Bitmap);
    Bitmap := nil;
    Exit(StatusIoError);
  end;
  Result := StatusSuccess;
end;

function BitIsSet(Bitmap: PByte; Index: LongWord): Boolean;
begin
  Result := (Bitmap[Index div 8] and (1 shl (Index mod 8))) <> 0;
end;

procedure SetBit(Bitmap: PByte; Index: LongWord; Value: Boolean);
begin
  if Value then
    Bitmap[Index div 8] := Bitmap[Index div 8] or Byte(1 shl (Index mod 8))
  else
    Bitmap[Index div 8] := Bitmap[Index div 8] and not Byte(1 shl (Index mod 8));
end;

function BlocksInGroup(Ext: PExtVolume; Group: LongWord): LongWord;
var
  GroupStart: QWord;
begin
  GroupStart := QWord(Ext^.FirstDataBlock) + QWord(Group) * Ext^.BlocksPerGroup;
  if GroupStart + Ext^.BlocksPerGroup > Ext^.BlockCount then
    Result := LongWord(Ext^.BlockCount - GroupStart)
  else
    Result := Ext^.BlocksPerGroup;
end;

{ Searches one group for a free block at or after StartIndex and takes it. }
function TryAllocateInGroup(Volume: PVolume; Group: LongWord; StartIndex: LongWord;
  out Block: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  BitmapBlock: QWord;
  Bitmap: PByte;
  Index: LongWord;
  Limit: LongWord;
  Found: Boolean;
  FreeInGroup: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Block := 0;
  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  if (PWord(@Descriptor[DescriptorOffsetFlags])^ and GroupFlagBlocksUninitialized) <> 0 then
    Exit(StatusNoSpace);
  FreeInGroup := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeBlocksLow,
    DescriptorOffsetFreeBlocksHigh, False);
  if FreeInGroup = 0 then
    Exit(StatusNoSpace);

  BitmapBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetBlockBitmapLow,
    DescriptorOffsetBlockBitmapHigh, True);
  Result := LoadBitmap(Volume, BitmapBlock, Bitmap);
  if Result <> StatusSuccess then
    Exit;

  Limit := BlocksInGroup(Ext, Group);
  Found := False;
  Index := StartIndex;
  while Index < Limit do
  begin
    if not BitIsSet(Bitmap, Index) then
    begin
      Found := True;
      Break;
    end;
    Inc(Index);
  end;
  if not Found then
  begin
    Index := 0;
    while Index < StartIndex do
    begin
      if not BitIsSet(Bitmap, Index) then
      begin
        Found := True;
        Break;
      end;
      Inc(Index);
    end;
  end;

  if not Found then
  begin
    FreeKernelMemory(Bitmap);
    Exit(StatusNoSpace);
  end;

  SetBit(Bitmap, Index, True);
  Block := QWord(Ext^.FirstDataBlock) + QWord(Group) * Ext^.BlocksPerGroup + Index;
  if not ExtWriteMetadata(Volume, BitmapBlock * Ext^.BlockSize, Ext^.BlockSize, Bitmap) then
  begin
    FreeKernelMemory(Bitmap);
    Exit(StatusIoError);
  end;

  SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeBlocksLow,
    DescriptorOffsetFreeBlocksHigh, False, FreeInGroup - 1);
  UpdateBitmapChecksum(Ext, @Descriptor[0], Bitmap, Ext^.BlocksPerGroup div 8,
    DescriptorOffsetBlockBitmapChecksumLow, DescriptorOffsetBlockBitmapChecksumHigh);
  FreeKernelMemory(Bitmap);
  Result := WriteGroupDescriptor(Volume, Group, @Descriptor[0]);
end;

function AllocateBlock(Volume: PVolume; Goal: QWord; out Block: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  StartGroup: LongWord;
  StartIndex: LongWord;
  Attempt: LongWord;
  Group: LongWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Block := 0;
  if Ext^.FreeBlockCount = 0 then
    Exit(StatusNoSpace);

  if (Goal < Ext^.FirstDataBlock) or (Goal >= Ext^.BlockCount) then
    Goal := Ext^.FirstDataBlock;
  StartGroup := GroupOfBlock(Ext, Goal);
  StartIndex := LongWord((Goal - Ext^.FirstDataBlock) mod Ext^.BlocksPerGroup);

  for Attempt := 0 to Ext^.GroupCount - 1 do
  begin
    Group := (StartGroup + Attempt) mod Ext^.GroupCount;
    Result := TryAllocateInGroup(Volume, Group, StartIndex, Block);
    if Result = StatusSuccess then
    begin
      Dec(Ext^.FreeBlockCount);
      Ext^.SuperblockNeedsWriting := True;
      { Its discard, if still waiting, must not reach what goes in now. }
      CancelVolumeDiscard(Volume, Block * Ext^.BlockSize, Ext^.BlockSize);
      { A data write: the block may become file data, which is never
        journaled; metadata written to it later is. }
      if not ExtWriteData(Volume, Block * Ext^.BlockSize, Ext^.BlockSize, nil) then
        Exit(StatusIoError);
      Exit;
    end;
    if Result <> StatusNoSpace then
      Exit;
    StartIndex := 0;
  end;
  Result := StatusNoSpace;
end;

function FreeBlock(Volume: PVolume; Block: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  Group: LongWord;
  Index: LongWord;
  BitmapBlock: QWord;
  Bitmap: PByte;
  FreeInGroup: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  if (Block < Ext^.FirstDataBlock) or (Block >= Ext^.BlockCount) then
    Exit(StatusCorrupted);
  Group := GroupOfBlock(Ext, Block);
  Index := LongWord((Block - Ext^.FirstDataBlock) mod Ext^.BlocksPerGroup);

  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  BitmapBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetBlockBitmapLow,
    DescriptorOffsetBlockBitmapHigh, True);
  Result := LoadBitmap(Volume, BitmapBlock, Bitmap);
  if Result <> StatusSuccess then
    Exit;

  if BitIsSet(Bitmap, Index) then
  begin
    SetBit(Bitmap, Index, False);
    if not ExtWriteMetadata(Volume, BitmapBlock * Ext^.BlockSize, Ext^.BlockSize, Bitmap) then
    begin
      FreeKernelMemory(Bitmap);
      Exit(StatusIoError);
    end;
    FreeInGroup := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeBlocksLow,
      DescriptorOffsetFreeBlocksHigh, False);
    SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeBlocksLow,
      DescriptorOffsetFreeBlocksHigh, False, FreeInGroup + 1);
    JournalNoteFreedBlock(Ext^.Journal, Block);
    UpdateBitmapChecksum(Ext, @Descriptor[0], Bitmap, Ext^.BlocksPerGroup div 8,
      DescriptorOffsetBlockBitmapChecksumLow, DescriptorOffsetBlockBitmapChecksumHigh);
    Result := WriteGroupDescriptor(Volume, Group, @Descriptor[0]);
    Inc(Ext^.FreeBlockCount);
    Ext^.SuperblockNeedsWriting := True;
    { On a journaled volume only once the transaction has committed. }
    QueueVolumeDiscard(Volume, Block * Ext^.BlockSize, Ext^.BlockSize, Ext^.Journal <> nil);
  end;
  FreeKernelMemory(Bitmap);
end;

{ Discards the free runs of one group's block bitmap. }
function TrimGroup(Volume: PVolume; Group: LongWord; var Discarded: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  BitmapBlock: QWord;
  Bitmap: PByte;
  Limit: LongWord;
  Index: LongWord;
  RunStart: LongWord;
  GroupFirst: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  if (PWord(@Descriptor[DescriptorOffsetFlags])^ and GroupFlagBlocksUninitialized) <> 0 then
    Exit(StatusSuccess);
  BitmapBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetBlockBitmapLow,
    DescriptorOffsetBlockBitmapHigh, True);
  Result := LoadBitmap(Volume, BitmapBlock, Bitmap);
  if Result <> StatusSuccess then
    Exit;
  GroupFirst := QWord(Ext^.FirstDataBlock) + QWord(Group) * Ext^.BlocksPerGroup;
  Limit := BlocksInGroup(Ext, Group);
  Index := 0;
  while Index < Limit do
  begin
    if BitIsSet(Bitmap, Index) then
    begin
      Inc(Index);
      Continue;
    end;
    RunStart := Index;
    while (Index < Limit) and not BitIsSet(Bitmap, Index) do
      Inc(Index);
    if not TrimFreeRange(Volume, (GroupFirst + RunStart) * Ext^.BlockSize,
      QWord(Index - RunStart) * Ext^.BlockSize, Discarded) then
      Result := StatusIoError;
  end;
  FreeKernelMemory(Bitmap);
end;

function TrimFreeBlocks(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Group: LongWord;
  Status: TFileSystemStatus;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := StatusSuccess;
  Group := 0;
  while Group < Ext^.GroupCount do
  begin
    Status := TrimGroup(Volume, Group, Discarded);
    if Status <> StatusSuccess then
      Result := Status;
    Inc(Group);
  end;
end;

function TryAllocateInodeInGroup(Volume: PVolume; Group: LongWord; IsDirectory: Boolean;
  out InodeNumber: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  Flags: Word;
  BitmapBlock: QWord;
  Bitmap: PByte;
  Index: LongWord;
  FirstIndex: LongWord;
  FreeInGroup: QWord;
  UnusedInGroup: QWord;
  UsedDirectories: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  InodeNumber := 0;
  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  FreeInGroup := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeInodesLow,
    DescriptorOffsetFreeInodesHigh, False);
  if FreeInGroup = 0 then
    Exit(StatusNoSpace);

  Flags := PWord(@Descriptor[DescriptorOffsetFlags])^;
  BitmapBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetInodeBitmapLow,
    DescriptorOffsetInodeBitmapHigh, True);
  Result := LoadBitmap(Volume, BitmapBlock, Bitmap);
  if Result <> StatusSuccess then
    Exit;

  { An uninitialized inode bitmap means "nothing in use yet". The part of
    the block past the group's inodes is padded with ones. }
  if (Flags and GroupFlagInodesUninitialized) <> 0 then
  begin
    FillMemory(Bitmap, Ext^.BlockSize, $FF);
    FillMemory(Bitmap, Ext^.InodesPerGroup div 8, 0);
    Flags := Flags and not GroupFlagInodesUninitialized;
  end;

  { The reserved inodes at the start of group 0 are never handed out. }
  FirstIndex := 0;
  if Group = 0 then
    FirstIndex := Ext^.FirstNonReservedInode - 1;

  Index := FirstIndex;
  while (Index < Ext^.InodesPerGroup) and BitIsSet(Bitmap, Index) do
    Inc(Index);
  if Index >= Ext^.InodesPerGroup then
  begin
    FreeKernelMemory(Bitmap);
    Exit(StatusNoSpace);
  end;

  SetBit(Bitmap, Index, True);
  if not ExtWriteMetadata(Volume, BitmapBlock * Ext^.BlockSize, Ext^.BlockSize, Bitmap) then
  begin
    FreeKernelMemory(Bitmap);
    Exit(StatusIoError);
  end;

  SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeInodesLow,
    DescriptorOffsetFreeInodesHigh, False, FreeInGroup - 1);
  if IsDirectory then
  begin
    UsedDirectories := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUsedDirectoriesLow,
      DescriptorOffsetUsedDirectoriesHigh, False);
    SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUsedDirectoriesLow,
      DescriptorOffsetUsedDirectoriesHigh, False, UsedDirectories + 1);
  end;

  { Inodes past (InodesPerGroup - unused) count as never used; using one
    moves that boundary. }
  if Ext^.HasMetadataChecksums or Ext^.HasGroupDescriptorChecksums then
  begin
    UnusedInGroup := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUnusedInodesLow,
      DescriptorOffsetUnusedInodesHigh, False);
    if Index >= Ext^.InodesPerGroup - UnusedInGroup then
      SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUnusedInodesLow,
        DescriptorOffsetUnusedInodesHigh, False, Ext^.InodesPerGroup - Index - 1);
  end;

  PWord(@Descriptor[DescriptorOffsetFlags])^ := Flags;
  UpdateBitmapChecksum(Ext, @Descriptor[0], Bitmap, Ext^.InodesPerGroup div 8,
    DescriptorOffsetInodeBitmapChecksumLow, DescriptorOffsetInodeBitmapChecksumHigh);
  FreeKernelMemory(Bitmap);
  Result := WriteGroupDescriptor(Volume, Group, @Descriptor[0]);
  InodeNumber := Group * Ext^.InodesPerGroup + Index + 1;
end;

function AllocateInode(Volume: PVolume; PreferredGroup: LongWord; IsDirectory: Boolean;
  out InodeNumber: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Attempt: LongWord;
  Group: LongWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  InodeNumber := 0;
  if Ext^.FreeInodeCount = 0 then
    Exit(StatusNoSpace);

  for Attempt := 0 to Ext^.GroupCount - 1 do
  begin
    Group := (PreferredGroup + Attempt) mod Ext^.GroupCount;
    Result := TryAllocateInodeInGroup(Volume, Group, IsDirectory, InodeNumber);
    if Result = StatusSuccess then
    begin
      Dec(Ext^.FreeInodeCount);
      Ext^.SuperblockNeedsWriting := True;
      Exit;
    end;
    if Result <> StatusNoSpace then
      Exit;
  end;
  Result := StatusNoSpace;
end;

function FreeInode(Volume: PVolume; InodeNumber: LongWord; IsDirectory: Boolean): TFileSystemStatus;
var
  Ext: PExtVolume;
  Descriptor: array[0..MaximumDescriptorSize - 1] of Byte;
  Group: LongWord;
  Index: LongWord;
  BitmapBlock: QWord;
  Bitmap: PByte;
  FreeInGroup: QWord;
  UsedDirectories: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Group := GroupOfInode(Ext, InodeNumber);
  Index := (InodeNumber - 1) mod Ext^.InodesPerGroup;

  Result := ReadGroupDescriptor(Volume, Group, @Descriptor[0]);
  if Result <> StatusSuccess then
    Exit;
  BitmapBlock := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetInodeBitmapLow,
    DescriptorOffsetInodeBitmapHigh, True);
  Result := LoadBitmap(Volume, BitmapBlock, Bitmap);
  if Result <> StatusSuccess then
    Exit;

  if BitIsSet(Bitmap, Index) then
  begin
    SetBit(Bitmap, Index, False);
    if not ExtWriteMetadata(Volume, BitmapBlock * Ext^.BlockSize, Ext^.BlockSize, Bitmap) then
    begin
      FreeKernelMemory(Bitmap);
      Exit(StatusIoError);
    end;
    FreeInGroup := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeInodesLow,
      DescriptorOffsetFreeInodesHigh, False);
    SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetFreeInodesLow,
      DescriptorOffsetFreeInodesHigh, False, FreeInGroup + 1);
    if IsDirectory then
    begin
      UsedDirectories := DescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUsedDirectoriesLow,
        DescriptorOffsetUsedDirectoriesHigh, False);
      if UsedDirectories > 0 then
        SetDescriptorValue(Ext, @Descriptor[0], DescriptorOffsetUsedDirectoriesLow,
          DescriptorOffsetUsedDirectoriesHigh, False, UsedDirectories - 1);
    end;
    UpdateBitmapChecksum(Ext, @Descriptor[0], Bitmap, Ext^.InodesPerGroup div 8,
      DescriptorOffsetInodeBitmapChecksumLow, DescriptorOffsetInodeBitmapChecksumHigh);
    Result := WriteGroupDescriptor(Volume, Group, @Descriptor[0]);
    Inc(Ext^.FreeInodeCount);
    Ext^.SuperblockNeedsWriting := True;
  end;
  FreeKernelMemory(Bitmap);
end;

{ --- Superblock ------------------------------------------------------ }

function SyncSuperblock(Volume: PVolume): TFileSystemStatus;
var
  Ext: PExtVolume;
  Buffer: PByte;
  Superblock: PSuperblock;
  Checksum: LongWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  if not Ext^.SuperblockNeedsWriting then
    Exit(StatusSuccess);

  Buffer := PByte(AllocateKernelMemory(SuperblockSize));
  if Buffer = nil then
    Exit(StatusOutOfMemory);
  if not ExtRead(Volume, SuperblockOffset, SuperblockSize, Buffer) then
  begin
    FreeKernelMemory(Buffer);
    Exit(StatusIoError);
  end;

  Superblock := PSuperblock(Buffer);
  Superblock^.FreeBlocksCountLow := LongWord(Ext^.FreeBlockCount);
  if HasIncompatibleFeature(Ext, Incompatible64Bit) then
    Superblock^.FreeBlocksCountHigh := LongWord(Ext^.FreeBlockCount shr 32);
  Superblock^.FreeInodesCount := Ext^.FreeInodeCount;

  if Ext^.HasMetadataChecksums then
  begin
    Checksum := Crc32cUpdate(Crc32InitialValue, Buffer, SuperblockChecksumOffset);
    PLongWord(Buffer + SuperblockChecksumOffset)^ := Checksum;
  end;

  if ExtWriteMetadata(Volume, SuperblockOffset, SuperblockSize, Buffer) then
  begin
    Ext^.SuperblockNeedsWriting := False;
    Result := StatusSuccess;
  end
  else
    Result := StatusIoError;
  FreeKernelMemory(Buffer);
end;

end.
