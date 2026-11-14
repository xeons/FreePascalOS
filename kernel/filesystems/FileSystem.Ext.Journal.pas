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
  Finding and checking the journal of an ext3/ext4 volume when it is
  mounted (see FileSystem.Ext.Transactions for how it is written and
  FileSystem.Ext.JournalRecovery for how it is replayed).

  The journal is the file of inode 8 (the superblock names it). Where its
  blocks are on the disk is worked out once, as runs of consecutive
  blocks, so that the log can be written without going through the
  inode's block map again. Journals on a separate device are not
  supported (the volume stays read-only).

  Writing a journal also needs its format to be one this driver writes:
  a version 2 superblock, and no checksums or v3 checksums. The revoke
  feature is switched on (recovery then honours the revoke records this
  driver writes), and so are 64-bit block numbers on 64-bit volumes, as
  Linux does.
}
unit FileSystem.Ext.Journal;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.Volume,
  FileSystem.Ext.Transactions;

{ Loads the journal of Volume: its blocks, superblock and format. Reason
  explains a failure (a journal that cannot even be replayed). }
function LoadExtJournal(Volume: PVolume; JournalInode: LongWord; out Journal: PExtJournal;
  out Reason: PChar): TFileSystemStatus;
{ True if this driver can write transactions to Journal; Reason explains
  why not. }
function JournalIsWritable(Journal: PExtJournal; out Reason: PChar): Boolean;
{ Makes a loaded journal ready for transactions. }
function PrepareJournalForWriting(Journal: PExtJournal; Ext: PExtVolume): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Checksums,
  Memory.KernelHeap,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Blocks,
  FileSystem.Ext.JournalFormat;

{ Works out the runs of the journal file's first BlockCount blocks. }
function MapJournalFile(Journal: PExtJournal; Node: PExtNode; BlockCount: QWord): TFileSystemStatus;
var
  Logical: QWord;
  Physical: QWord;
  Capacity: LongWord;
  Grown: PJournalRun;
  Last: PJournalRun;
begin
  Capacity := 0;
  Logical := 0;
  while Logical < BlockCount do
  begin
    Result := MapLogicalBlock(Node, LongWord(Logical), Physical);
    if Result <> StatusSuccess then
      Exit;
    if Physical = 0 then
      Exit(StatusCorrupted);
    Last := nil;
    if Journal^.RunCount > 0 then
      Last := @Journal^.Runs[Journal^.RunCount - 1];
    if (Last <> nil) and (Last^.PhysicalStart + Last^.Count = Physical) then
      Inc(Last^.Count)
    else
    begin
      if Journal^.RunCount = Capacity then
      begin
        Grown := PJournalRun(AllocateKernelMemory((Capacity * 2 + 8) * SizeOf(TJournalRun)));
        if Grown = nil then
          Exit(StatusOutOfMemory);
        if Journal^.RunCount > 0 then
          CopyMemory(Grown, Journal^.Runs, Journal^.RunCount * SizeOf(TJournalRun));
        FreeKernelMemory(Journal^.Runs);
        Journal^.Runs := Grown;
        Capacity := Capacity * 2 + 8;
      end;
      Journal^.Runs[Journal^.RunCount].LogicalStart := Logical;
      Journal^.Runs[Journal^.RunCount].PhysicalStart := Physical;
      Journal^.Runs[Journal^.RunCount].Count := 1;
      Inc(Journal^.RunCount);
    end;
    Inc(Logical);
  end;
  Result := StatusSuccess;
end;

function ReadJournalFormat(Journal: PExtJournal; Ext: PExtVolume; FileBlocks: QWord;
  out Reason: PChar): TFileSystemStatus;
var
  Superblock: PByte;
  BlockType: LongWord;
begin
  Superblock := @Journal^.Superblock[0];
  Result := StatusCorrupted;
  BlockType := ReadBigEndian32(Superblock + JournalHeaderBlockType);
  if (ReadBigEndian32(Superblock + JournalHeaderMagic) <> JournalMagic) or
     ((BlockType <> JournalBlockSuperblockVersion1) and (BlockType <> JournalBlockSuperblockVersion2)) then
  begin
    Reason := 'the journal superblock is damaged';
    Exit;
  end;
  Journal^.Format.BlockSize := ReadBigEndian32(Superblock + JournalSuperblockBlockSize);
  Journal^.TotalBlocks := ReadBigEndian32(Superblock + JournalSuperblockMaximumLength);
  Journal^.FirstLogBlock := ReadBigEndian32(Superblock + JournalSuperblockFirst);
  if (Journal^.Format.BlockSize <> Ext^.BlockSize) or (Journal^.TotalBlocks > FileBlocks) or
     (Journal^.FirstLogBlock = 0) or (Journal^.FirstLogBlock >= Journal^.TotalBlocks) then
  begin
    Reason := 'the journal superblock does not fit the journal';
    Exit;
  end;
  if BlockType = JournalBlockSuperblockVersion2 then
  begin
    Journal^.Format.Compatible := ReadBigEndian32(Superblock + JournalSuperblockCompatible);
    Journal^.Format.Incompatible := ReadBigEndian32(Superblock + JournalSuperblockIncompatible);
  end;
  if (Journal^.Format.Incompatible and not JournalReadableIncompatible) <> 0 then
  begin
    Reason := 'the journal uses features that cannot be replayed';
    Exit(StatusUnsupported);
  end;
  CopyMemory(@Journal^.Format.Uuid[0], Superblock + JournalSuperblockUuid, JournalUuidSize);
  Journal^.Format.ChecksumSeed := Crc32cUpdate(Crc32InitialValue, @Journal^.Format.Uuid[0], JournalUuidSize);
  if HasChecksumV3(Journal^.Format) and
     ((Superblock[JournalSuperblockChecksumType] <> JournalChecksumTypeCrc32c) or
      (ReadBigEndian32(Superblock + JournalSuperblockChecksum) <> JournalSuperblockChecksumOf(Superblock))) then
  begin
    Reason := 'the journal superblock checksum is wrong';
    Exit;
  end;
  Journal^.Sequence := ReadBigEndian32(Superblock + JournalSuperblockSequence);
  Result := StatusSuccess;
end;

function LoadExtJournal(Volume: PVolume; JournalInode: LongWord; out Journal: PExtJournal;
  out Reason: PChar): TFileSystemStatus;
var
  Ext: PExtVolume;
  Node: PExtNode;
  FileBlocks: QWord;
  SuperblockAddress: QWord;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Journal := nil;
  Reason := 'the journal cannot be read';
  if JournalInode = 0 then
  begin
    Reason := 'journals on another device are not supported';
    Exit(StatusUnsupported);
  end;

  Node := PExtNode(AllocateZeroedKernelMemory(SizeOf(TExtNode)));
  Journal := PExtJournal(AllocateZeroedKernelMemory(SizeOf(TExtJournal)));
  if (Node = nil) or (Journal = nil) then
  begin
    FreeKernelMemory(Node);
    FreeKernelMemory(Journal);
    Journal := nil;
    Exit(StatusOutOfMemory);
  end;
  Journal^.Volume := Volume;
  Journal^.VolumeHasMetadataChecksums := Ext^.HasMetadataChecksums;
  Node^.Common.Volume := Volume;
  Node^.InodeNumber := JournalInode;

  Result := ReadInodeBytes(Volume, JournalInode, @Node^.InodeBytes[0]);
  if Result = StatusSuccess then
  begin
    FileBlocks := InodeSize(InodeRecord(Node)^) div Ext^.BlockSize;
    { The superblock first, to learn how much of the file is the journal. }
    Result := MapJournalFile(Journal, Node, 1);
  end;
  if Result = StatusSuccess then
  begin
    SuperblockAddress := Journal^.Runs[0].PhysicalStart * Ext^.BlockSize;
    if not VolumeRead(Volume, SuperblockAddress, JournalSuperblockSize, @Journal^.Superblock[0]) then
      Result := StatusIoError;
  end;
  if Result = StatusSuccess then
    Result := ReadJournalFormat(Journal, Ext, FileBlocks, Reason);
  if Result = StatusSuccess then
  begin
    Journal^.RunCount := 0;
    Result := MapJournalFile(Journal, Node, Journal^.TotalBlocks);
  end;
  FreeKernelMemory(Node);
  if Result <> StatusSuccess then
  begin
    FreeJournal(Journal);
    Journal := nil;
  end;
end;

function JournalIsWritable(Journal: PExtJournal; out Reason: PChar): Boolean;
begin
  Result := False;
  if ReadBigEndian32(@Journal^.Superblock[JournalHeaderBlockType]) <> JournalBlockSuperblockVersion2 then
    Reason := 'version 1 journals are not written'
  else if (Journal^.Format.Incompatible and not JournalWritableIncompatible) <> 0 then
    Reason := 'the journal uses features that cannot be written'
  else if (Journal^.Format.Compatible and JournalCompatibleChecksum) <> 0 then
    Reason := 'journals with version 1 checksums are not written'
  else
    Result := True;
end;

function PrepareJournalForWriting(Journal: PExtJournal; Ext: PExtVolume): Boolean;
begin
  Journal^.Format.Incompatible := Journal^.Format.Incompatible or JournalIncompatibleRevoke;
  if HasIncompatibleFeature(Ext, Incompatible64Bit) then
    Journal^.Format.Incompatible := Journal^.Format.Incompatible or JournalIncompatible64Bit;
  { Written to the disk with the first transaction. }
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockIncompatible], Journal^.Format.Incompatible);
  Result := StartJournal(Journal);
end;

end.
