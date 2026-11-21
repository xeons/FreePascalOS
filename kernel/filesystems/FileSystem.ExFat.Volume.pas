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
  Mounted exFAT volume state and the low level operations on it.

  On-disk layout:

    [main boot region: boot sector at sector 0, 12 sectors]
    [backup boot region]
    [file allocation table, at FatOffset]
    [cluster heap: clusters 2, 3, 4, ..., at ClusterHeapOffset]

  Which clusters are in use is recorded in the allocation bitmap (one bit
  per cluster), not in the FAT. The FAT only links the clusters of files
  that are not stored contiguously; a contiguous file has the "no FAT
  chain" flag in its stream extension.

  Nodes are identified by the volume offset of their file entry. Each node
  also remembers the volume offsets of every entry of its entry set, so
  the set can be rewritten (new size, new timestamps) without going back
  through the parent directory.
}
unit FileSystem.ExFat.Volume;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.ExFat.Structures;

const
  RootNodeNumber = 0;

type
  PExFatNode = ^TExFatNode;

  PExFatVolume = ^TExFatVolume;
  TExFatVolume = record
    BytesPerCluster: QWord;
    FatOffset: QWord;
    ClusterHeapOffset: QWord;
    ClusterCount: LongWord;
    RootCluster: LongWord;
    { Maps every UTF-16 unit to its upper case form. }
    UpcaseTable: PWord;
    { The allocation bitmap is itself stored like a file. }
    Bitmap: PExFatNode;
    FreeClusterCount: LongWord;
    NextFreeHint: LongWord;
    IsMarkedDirty: Boolean;
  end;

  TExFatNode = record
    Common: TNode;
    FirstCluster: LongWord;
    IsContiguous: Boolean;
    IsRoot: Boolean;
    { Bytes allocated to the node. For the root directory this is unknown
      and its cluster chain decides the extent. }
    DataLength: QWord;
    HasKnownLength: Boolean;
    ValidDataLength: QWord;
    { Ordinal in the upper 32 bits, cluster in the lower 32 bits. }
    ChainHint: QWord;
    { Where the node's entry set is: its index in the parent directory and
      the volume offset of each of its entries. }
    SetIndex: QWord;
    SetEntryCount: Integer;
    SetEntryOffsets: array[0..MaximumEntrySetSize - 1] of QWord;
    { Removed while open: its entry set is gone, so it is no longer
      written. }
    IsDetached: Boolean;
  end;

  TExFatEntry = record
    Name: array[0..MaximumNameCharacters] of Word;
    NameLength: Integer;
    Attributes: Word;
    FirstCluster: LongWord;
    IsContiguous: Boolean;
    DataLength: QWord;
    ValidDataLength: QWord;
    LastModifiedTimestamp: LongWord;
    LastModifiedUtcOffset: Byte;
    SetIndex: QWord;
    SetEntryCount: Integer;
    SetEntryOffsets: array[0..MaximumEntrySetSize - 1] of QWord;
  end;

function ExFatVolumeOf(Node: PNode): PExFatVolume;

function IsValidCluster(ExFat: PExFatVolume; Cluster: LongWord): Boolean;
function ClusterOffset(ExFat: PExFatVolume; Cluster: LongWord): QWord;
function ReadFatEntry(Volume: PVolume; Cluster: LongWord; out Value: LongWord): Boolean;
function WriteFatEntry(Volume: PVolume; Cluster: LongWord; Value: LongWord): Boolean;

{ Node data access. Ordinal is the cluster index within the node. }
function FindClusterOfNode(Node: PExFatNode; Ordinal: LongWord; out Cluster: LongWord): TFileSystemStatus;
function ReadNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Buffer: PByte): TFileSystemStatus;
{ Source = nil writes zeros. The range must lie in allocated clusters. }
function WriteNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Source: PByte): TFileSystemStatus;
{ Number of clusters allocated to the node, and the last one. }
function CountNodeClusters(Node: PExFatNode; out ClusterCount: LongWord;
  out LastCluster: LongWord): TFileSystemStatus;

{ Allocation bitmap. }
function CountFreeClusters(Volume: PVolume): TFileSystemStatus;
function ClusterIsFree(Volume: PVolume; Cluster: LongWord; out IsFree: Boolean): TFileSystemStatus;
function MarkCluster(Volume: PVolume; Cluster: LongWord; Allocated: Boolean): TFileSystemStatus;
{ fstrim: discards every run of free clusters. }
function TrimFreeClusters(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;
function FindFreeCluster(Volume: PVolume; out Cluster: LongWord): TFileSystemStatus;

{ Directory entries by index within a directory. }
function EntryVolumeOffset(Directory: PExFatNode; Index: QWord; out Offset: QWord): TFileSystemStatus;
function ReadRawEntry(Directory: PExFatNode; Index: QWord; out Entry: TRawEntry): TFileSystemStatus;
function WriteRawEntry(Directory: PExFatNode; Index: QWord; const Entry: TRawEntry): TFileSystemStatus;

function ComputeSetChecksum(const EntrySet: TEntrySet; EntryCount: Integer): Word;
function ComputeNameHash(ExFat: PExFatVolume; Name: PWord; NameLength: Integer): Word;
function UpcaseUnit(ExFat: PExFatVolume; UnitValue: Word): Word;

{ Returns the next valid file entry set at or after Cursor.Position. }
function NextEntry(Directory: PExFatNode; var Cursor: TDirectoryCursor;
  out Entry: TExFatEntry): TFileSystemStatus;

function CreateNodeFromEntry(Volume: PVolume; const Entry: TExFatEntry): PExFatNode;
function CreateRootNode(Volume: PVolume): PExFatNode;

{ Rewrites the node's stream extension from its current state and, when
  Modify is set, its modification time; then fixes the set checksum. }
function UpdateNodeEntrySet(Node: PExFatNode; Modify: Boolean): TFileSystemStatus;

function CurrentTimestamp: LongWord;

implementation

uses
  Runtime.Memory,
  Runtime.Time,
  Memory.KernelHeap,
  Kernel.Clock,
  FileSystem.Discards;

function ExFatVolumeOf(Node: PNode): PExFatVolume;
begin
  Result := PExFatVolume(Node^.Volume^.DriverData);
end;

{ --- Clusters -------------------------------------------------------- }

function IsValidCluster(ExFat: PExFatVolume; Cluster: LongWord): Boolean;
begin
  Result := (Cluster >= 2) and (Cluster < ExFat^.ClusterCount + 2);
end;

function ClusterOffset(ExFat: PExFatVolume; Cluster: LongWord): QWord;
begin
  Result := ExFat^.ClusterHeapOffset + QWord(Cluster - 2) * ExFat^.BytesPerCluster;
end;

function ReadFatEntry(Volume: PVolume; Cluster: LongWord; out Value: LongWord): Boolean;
var
  ExFat: PExFatVolume;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := VolumeRead(Volume, ExFat^.FatOffset + QWord(Cluster) * 4, 4, @Value);
end;

function WriteFatEntry(Volume: PVolume; Cluster: LongWord; Value: LongWord): Boolean;
var
  ExFat: PExFatVolume;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := VolumeWrite(Volume, ExFat^.FatOffset + QWord(Cluster) * 4, 4, @Value);
end;

function FindClusterOfNode(Node: PExFatNode; Ordinal: LongWord; out Cluster: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Hint: QWord;
  CurrentOrdinal: LongWord;
  CurrentCluster: LongWord;
  NextCluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);
  Cluster := 0;
  if Node^.FirstCluster = 0 then
    Exit(StatusEndOfDirectory);

  if Node^.IsContiguous then
  begin
    if Node^.HasKnownLength and (QWord(Ordinal) * ExFat^.BytesPerCluster >= Node^.DataLength) then
      Exit(StatusEndOfDirectory);
    Cluster := Node^.FirstCluster + Ordinal;
    if not IsValidCluster(ExFat, Cluster) then
      Exit(StatusCorrupted);
    Exit(StatusSuccess);
  end;

  Hint := Node^.ChainHint;
  CurrentOrdinal := LongWord(Hint shr 32);
  CurrentCluster := LongWord(Hint);
  if (CurrentCluster = 0) or (CurrentOrdinal > Ordinal) then
  begin
    CurrentOrdinal := 0;
    CurrentCluster := Node^.FirstCluster;
  end;

  while CurrentOrdinal < Ordinal do
  begin
    if not IsValidCluster(ExFat, CurrentCluster) then
      Exit(StatusCorrupted);
    if not ReadFatEntry(Node^.Common.Volume, CurrentCluster, NextCluster) then
      Exit(StatusIoError);
    if NextCluster >= EndOfChainMinimum then
      Exit(StatusEndOfDirectory);
    CurrentCluster := NextCluster;
    Inc(CurrentOrdinal);
  end;

  if not IsValidCluster(ExFat, CurrentCluster) then
    Exit(StatusCorrupted);
  Node^.ChainHint := (QWord(CurrentOrdinal) shl 32) or CurrentCluster;
  Cluster := CurrentCluster;
  Result := StatusSuccess;
end;

{ Shared by ReadNodeBytes and WriteNodeBytes. }
function TransferNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Buffer: PByte;
  IsWrite: Boolean): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Volume: PVolume;
  Cluster: LongWord;
  OffsetInCluster: QWord;
  ChunkBytes: QWord;
  Succeeded: Boolean;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  while Length > 0 do
  begin
    Result := FindClusterOfNode(Node, LongWord(Offset div ExFat^.BytesPerCluster), Cluster);
    if Result <> StatusSuccess then
      Exit;
    OffsetInCluster := Offset mod ExFat^.BytesPerCluster;
    ChunkBytes := ExFat^.BytesPerCluster - OffsetInCluster;
    if ChunkBytes > Length then
      ChunkBytes := Length;

    if not IsWrite then
      Succeeded := VolumeRead(Volume, ClusterOffset(ExFat, Cluster) + OffsetInCluster, ChunkBytes, Buffer)
    else if Buffer <> nil then
      Succeeded := VolumeWrite(Volume, ClusterOffset(ExFat, Cluster) + OffsetInCluster, ChunkBytes, Buffer)
    else
      Succeeded := VolumeWriteZeros(Volume, ClusterOffset(ExFat, Cluster) + OffsetInCluster, ChunkBytes);
    if not Succeeded then
      Exit(StatusIoError);

    if Buffer <> nil then
      Buffer := Buffer + ChunkBytes;
    Offset := Offset + ChunkBytes;
    Length := Length - ChunkBytes;
  end;
  Result := StatusSuccess;
end;

function ReadNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Buffer: PByte): TFileSystemStatus;
begin
  Result := TransferNodeBytes(Node, Offset, Length, Buffer, False);
end;

function WriteNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Source: PByte): TFileSystemStatus;
begin
  Result := TransferNodeBytes(Node, Offset, Length, Source, True);
end;

function CountNodeClusters(Node: PExFatNode; out ClusterCount: LongWord;
  out LastCluster: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Cluster: LongWord;
  NextCluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);
  ClusterCount := 0;
  LastCluster := 0;
  if Node^.FirstCluster = 0 then
    Exit(StatusSuccess);

  if Node^.IsContiguous then
  begin
    ClusterCount := LongWord((Node^.DataLength + ExFat^.BytesPerCluster - 1) div ExFat^.BytesPerCluster);
    if ClusterCount > 0 then
      LastCluster := Node^.FirstCluster + ClusterCount - 1;
    Exit(StatusSuccess);
  end;

  Cluster := Node^.FirstCluster;
  repeat
    if (not IsValidCluster(ExFat, Cluster)) or (ClusterCount > ExFat^.ClusterCount) then
      Exit(StatusCorrupted);
    Inc(ClusterCount);
    LastCluster := Cluster;
    if not ReadFatEntry(Node^.Common.Volume, Cluster, NextCluster) then
      Exit(StatusIoError);
    Cluster := NextCluster;
  until Cluster >= EndOfChainMinimum;
  Result := StatusSuccess;
end;

{ --- Allocation bitmap ----------------------------------------------- }

function BitmapByteOf(Cluster: LongWord): QWord;
begin
  Result := (Cluster - 2) div 8;
end;

function BitmapMaskOf(Cluster: LongWord): Byte;
begin
  Result := Byte(1 shl ((Cluster - 2) mod 8));
end;

function CountFreeClusters(Volume: PVolume): TFileSystemStatus;
const
  ChunkBytes = 512;
var
  ExFat: PExFatVolume;
  Chunk: array[0..ChunkBytes - 1] of Byte;
  BitmapBytes: QWord;
  Offset: QWord;
  BytesInChunk: QWord;
  ByteIndex: QWord;
  Bit: Integer;
  Cluster: LongWord;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  ExFat^.FreeClusterCount := 0;
  ExFat^.NextFreeHint := 0;
  BitmapBytes := (QWord(ExFat^.ClusterCount) + 7) div 8;

  Offset := 0;
  while Offset < BitmapBytes do
  begin
    BytesInChunk := BitmapBytes - Offset;
    if BytesInChunk > ChunkBytes then
      BytesInChunk := ChunkBytes;
    Result := ReadNodeBytes(ExFat^.Bitmap, Offset, BytesInChunk, @Chunk[0]);
    if Result <> StatusSuccess then
      Exit;

    ByteIndex := 0;
    while ByteIndex < BytesInChunk do
    begin
      for Bit := 0 to 7 do
      begin
        Cluster := LongWord((Offset + ByteIndex) * 8) + LongWord(Bit) + 2;
        if Cluster >= ExFat^.ClusterCount + 2 then
          Break;
        if (Chunk[ByteIndex] and (1 shl Bit)) = 0 then
        begin
          Inc(ExFat^.FreeClusterCount);
          if ExFat^.NextFreeHint = 0 then
            ExFat^.NextFreeHint := Cluster;
        end;
      end;
      Inc(ByteIndex);
    end;
    Offset := Offset + BytesInChunk;
  end;

  if ExFat^.NextFreeHint = 0 then
    ExFat^.NextFreeHint := 2;
  Result := StatusSuccess;
end;

function ClusterIsFree(Volume: PVolume; Cluster: LongWord; out IsFree: Boolean): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Value: Byte;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  IsFree := False;
  if not IsValidCluster(ExFat, Cluster) then
    Exit(StatusSuccess);
  Result := ReadNodeBytes(ExFat^.Bitmap, BitmapByteOf(Cluster), 1, @Value);
  if Result = StatusSuccess then
    IsFree := (Value and BitmapMaskOf(Cluster)) = 0;
end;

function MarkCluster(Volume: PVolume; Cluster: LongWord; Allocated: Boolean): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Value: Byte;
  WasAllocated: Boolean;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := ReadNodeBytes(ExFat^.Bitmap, BitmapByteOf(Cluster), 1, @Value);
  if Result <> StatusSuccess then
    Exit;
  WasAllocated := (Value and BitmapMaskOf(Cluster)) <> 0;
  if WasAllocated = Allocated then
    Exit(StatusSuccess);

  if Allocated then
  begin
    Value := Value or BitmapMaskOf(Cluster);
    Dec(ExFat^.FreeClusterCount);
    { Its discard, if still waiting, must not reach what goes in now. }
    CancelVolumeDiscard(Volume, ClusterOffset(ExFat, Cluster), ExFat^.BytesPerCluster);
  end
  else
  begin
    Value := Value and not BitmapMaskOf(Cluster);
    Inc(ExFat^.FreeClusterCount);
    if Cluster < ExFat^.NextFreeHint then
      ExFat^.NextFreeHint := Cluster;
  end;
  Result := WriteNodeBytes(ExFat^.Bitmap, BitmapByteOf(Cluster), 1, @Value);
  if (Result = StatusSuccess) and not Allocated then
    QueueVolumeDiscard(Volume, ClusterOffset(ExFat, Cluster), ExFat^.BytesPerCluster, False);
end;

function TrimFreeClusters(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;
const
  ChunkBytes = 4096;
var
  ExFat: PExFatVolume;
  Chunk: array[0..ChunkBytes - 1] of Byte;
  ChunkStart: QWord;
  Index: LongWord;
  RunStart: LongWord;
  InRun: Boolean;
  IsFree: Boolean;
  Cluster: LongWord;
  ByteIndex: QWord;
  BitmapBytes: QWord;
  Length: QWord;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := StatusSuccess;
  BitmapBytes := (QWord(ExFat^.ClusterCount) + 7) div 8;
  ChunkStart := High(QWord);
  InRun := False;
  RunStart := 2;
  Index := 0;
  while Index <= ExFat^.ClusterCount do
  begin
    { One past the last cluster ends the last run. }
    IsFree := False;
    if Index < ExFat^.ClusterCount then
    begin
      ByteIndex := Index div 8;
      if (ChunkStart = High(QWord)) or (ByteIndex < ChunkStart) or (ByteIndex >= ChunkStart + ChunkBytes) then
      begin
        ChunkStart := ByteIndex - ByteIndex mod ChunkBytes;
        Length := BitmapBytes - ChunkStart;
        if Length > ChunkBytes then
          Length := ChunkBytes;
        Result := ReadNodeBytes(ExFat^.Bitmap, ChunkStart, Length, @Chunk[0]);
        if Result <> StatusSuccess then
          Exit;
      end;
      IsFree := (Chunk[ByteIndex - ChunkStart] and (1 shl (Index mod 8))) = 0;
    end;
    Cluster := Index + 2;
    if IsFree and not InRun then
    begin
      InRun := True;
      RunStart := Cluster;
    end
    else if not IsFree and InRun then
    begin
      InRun := False;
      if not TrimFreeRange(Volume, ClusterOffset(ExFat, RunStart), QWord(Cluster - RunStart) * ExFat^.BytesPerCluster,
        Discarded) then
        Result := StatusIoError;
    end;
    Inc(Index);
  end;
end;

function FindFreeCluster(Volume: PVolume; out Cluster: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Candidate: LongWord;
  Checked: LongWord;
  IsFree: Boolean;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Cluster := 0;
  if ExFat^.FreeClusterCount = 0 then
    Exit(StatusNoSpace);

  Candidate := ExFat^.NextFreeHint;
  Checked := 0;
  while Checked < ExFat^.ClusterCount do
  begin
    if not IsValidCluster(ExFat, Candidate) then
      Candidate := 2;
    Result := ClusterIsFree(Volume, Candidate, IsFree);
    if Result <> StatusSuccess then
      Exit;
    if IsFree then
    begin
      Cluster := Candidate;
      ExFat^.NextFreeHint := Candidate + 1;
      Exit(StatusSuccess);
    end;
    Inc(Candidate);
    Inc(Checked);
  end;
  Result := StatusNoSpace;
end;

{ --- Directory entries ----------------------------------------------- }

function EntryVolumeOffset(Directory: PExFatNode; Index: QWord; out Offset: QWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  ByteOffset: QWord;
  Cluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Directory^.Common);
  Offset := 0;
  ByteOffset := Index * DirectoryEntrySize;
  if Directory^.HasKnownLength and (ByteOffset + DirectoryEntrySize > Directory^.DataLength) then
    Exit(StatusEndOfDirectory);
  Result := FindClusterOfNode(Directory, LongWord(ByteOffset div ExFat^.BytesPerCluster), Cluster);
  if Result = StatusSuccess then
    Offset := ClusterOffset(ExFat, Cluster) + ByteOffset mod ExFat^.BytesPerCluster;
end;

function ReadRawEntry(Directory: PExFatNode; Index: QWord; out Entry: TRawEntry): TFileSystemStatus;
var
  Offset: QWord;
begin
  Result := EntryVolumeOffset(Directory, Index, Offset);
  if Result <> StatusSuccess then
    Exit;
  if not VolumeRead(Directory^.Common.Volume, Offset, DirectoryEntrySize, @Entry[0]) then
    Result := StatusIoError;
end;

function WriteRawEntry(Directory: PExFatNode; Index: QWord; const Entry: TRawEntry): TFileSystemStatus;
var
  Offset: QWord;
begin
  Result := EntryVolumeOffset(Directory, Index, Offset);
  if Result <> StatusSuccess then
    Exit;
  if not VolumeWrite(Directory^.Common.Volume, Offset, DirectoryEntrySize, @Entry[0]) then
    Result := StatusIoError;
end;

function ComputeSetChecksum(const EntrySet: TEntrySet; EntryCount: Integer): Word;
var
  EntryIndex: Integer;
  ByteIndex: Integer;
  Checksum: Word;
begin
  Checksum := 0;
  for EntryIndex := 0 to EntryCount - 1 do
  begin
    for ByteIndex := 0 to DirectoryEntrySize - 1 do
    begin
      { The checksum field of the file entry is excluded. }
      if (EntryIndex = 0) and ((ByteIndex = 2) or (ByteIndex = 3)) then
        Continue;
      if (Checksum and 1) <> 0 then
        Checksum := Word($8000 + (Checksum shr 1) + EntrySet[EntryIndex][ByteIndex])
      else
        Checksum := Word((Checksum shr 1) + EntrySet[EntryIndex][ByteIndex]);
    end;
  end;
  Result := Checksum;
end;

function UpcaseUnit(ExFat: PExFatVolume; UnitValue: Word): Word;
begin
  Result := ExFat^.UpcaseTable[UnitValue];
end;

function HashStep(Hash: Word; Value: Byte): Word;
begin
  if (Hash and 1) <> 0 then
    Result := Word($8000 + (Hash shr 1) + Value)
  else
    Result := Word((Hash shr 1) + Value);
end;

function ComputeNameHash(ExFat: PExFatVolume; Name: PWord; NameLength: Integer): Word;
var
  Index: Integer;
  Upcased: Word;
begin
  Result := 0;
  for Index := 0 to NameLength - 1 do
  begin
    Upcased := UpcaseUnit(ExFat, Name[Index]);
    Result := HashStep(Result, Byte(Upcased and $FF));
    Result := HashStep(Result, Byte(Upcased shr 8));
  end;
end;

{ Reads the entry set whose primary entry is at Index. Returns False if
  the set is damaged or incomplete. }
function ReadEntrySet(Directory: PExFatNode; Index: QWord; const Primary: TRawEntry;
  out Entry: TExFatEntry; out Status: TFileSystemStatus): Boolean;
var
  EntrySet: TEntrySet;
  FileEntry: PFileEntry;
  Stream: PStreamEntry;
  NameEntry: PFileNameEntry;
  SecondaryIndex: Integer;
  CharacterIndex: Integer;
  NameCharactersLeft: Integer;
begin
  Result := False;
  Status := StatusSuccess;
  FileEntry := PFileEntry(@Primary[0]);
  if (FileEntry^.SecondaryCount < 2) or (FileEntry^.SecondaryCount > MaximumSecondaryEntries) then
    Exit;

  EntrySet[0] := Primary;
  Entry.SetEntryCount := FileEntry^.SecondaryCount + 1;
  for SecondaryIndex := 0 to Entry.SetEntryCount - 1 do
  begin
    Status := EntryVolumeOffset(Directory, Index + QWord(SecondaryIndex),
      Entry.SetEntryOffsets[SecondaryIndex]);
    if Status <> StatusSuccess then
      Exit;
    if SecondaryIndex > 0 then
    begin
      if not VolumeRead(Directory^.Common.Volume, Entry.SetEntryOffsets[SecondaryIndex],
        DirectoryEntrySize, @EntrySet[SecondaryIndex][0]) then
      begin
        Status := StatusIoError;
        Exit;
      end;
    end;
  end;

  if (EntrySet[1][0] <> EntryTypeStreamExtension) or
     (ComputeSetChecksum(EntrySet, Entry.SetEntryCount) <> FileEntry^.SetChecksum) then
    Exit;

  Stream := PStreamEntry(@EntrySet[1][0]);
  Entry.FirstCluster := Stream^.FirstCluster;
  Entry.IsContiguous := (Stream^.GeneralSecondaryFlags and StreamFlagNoFatChain) <> 0;
  Entry.DataLength := Stream^.DataLength;
  Entry.ValidDataLength := Stream^.ValidDataLength;
  NameCharactersLeft := Stream^.NameLength;
  Entry.NameLength := 0;

  for SecondaryIndex := 2 to Entry.SetEntryCount - 1 do
  begin
    if EntrySet[SecondaryIndex][0] <> EntryTypeFileName then
      Continue;
    NameEntry := PFileNameEntry(@EntrySet[SecondaryIndex][0]);
    CharacterIndex := 0;
    while (CharacterIndex < CharactersPerNameEntry) and (NameCharactersLeft > 0) do
    begin
      Entry.Name[Entry.NameLength] := NameEntry^.FileName[CharacterIndex];
      Inc(Entry.NameLength);
      Dec(NameCharactersLeft);
      Inc(CharacterIndex);
    end;
  end;
  if Entry.NameLength = 0 then
    Exit;

  Entry.Name[Entry.NameLength] := 0;
  Entry.Attributes := FileEntry^.FileAttributes;
  Entry.LastModifiedTimestamp := FileEntry^.LastModifiedTimestamp;
  Entry.LastModifiedUtcOffset := FileEntry^.LastModifiedUtcOffset;
  Entry.SetIndex := Index;
  Result := True;
end;

function NextEntry(Directory: PExFatNode; var Cursor: TDirectoryCursor;
  out Entry: TExFatEntry): TFileSystemStatus;
var
  Primary: TRawEntry;
  Index: QWord;
begin
  repeat
    Index := Cursor.Position;
    Result := ReadRawEntry(Directory, Index, Primary);
    if Result <> StatusSuccess then
      Exit;

    if Primary[0] = EntryTypeEndOfDirectory then
      Exit(StatusEndOfDirectory);

    if Primary[0] <> EntryTypeFile then
    begin
      Inc(Cursor.Position);
      Continue;
    end;

    { Skip the whole set, valid or not. }
    Cursor.Position := Index + 1 + PFileEntry(@Primary[0])^.SecondaryCount;
    if ReadEntrySet(Directory, Index, Primary, Entry, Result) then
      Exit(StatusSuccess);
    if (Result <> StatusSuccess) and (Result <> StatusEndOfDirectory) then
      Exit;
  until False;
end;

{ --- Nodes ----------------------------------------------------------- }

function TimestampToUnixTime(Timestamp: LongWord; UtcOffset: Byte): TUnixTime;
var
  OffsetQuarterHours: LongInt;
begin
  Result := DosDateTimeToUnixTime(Word(Timestamp shr 16), Word(Timestamp and $FFFF));
  if (Result <> 0) and ((UtcOffset and UtcOffsetValid) <> 0) then
  begin
    { A signed 7-bit count of 15 minute steps east of UTC. }
    OffsetQuarterHours := UtcOffset and $7F;
    if OffsetQuarterHours >= 64 then
      OffsetQuarterHours := OffsetQuarterHours - 128;
    Result := Result - Int64(OffsetQuarterHours) * 15 * 60;
  end;
end;

function CurrentTimestamp: LongWord;
var
  DateWord: Word;
  TimeWord: Word;
begin
  UnixTimeToDosDateTime(CurrentWallClockTime, DateWord, TimeWord);
  Result := (LongWord(DateWord) shl 16) or TimeWord;
end;

function CreateNodeFromEntry(Volume: PVolume; const Entry: TExFatEntry): PExFatNode;
var
  EntryIndex: Integer;
begin
  Result := PExFatNode(AllocateZeroedKernelMemory(SizeOf(TExFatNode)));
  if Result = nil then
    Exit;
  Result^.Common.Volume := Volume;
  Result^.FirstCluster := Entry.FirstCluster;
  Result^.IsContiguous := Entry.IsContiguous;
  Result^.DataLength := Entry.DataLength;
  Result^.HasKnownLength := True;
  Result^.ValidDataLength := Entry.ValidDataLength;
  Result^.SetIndex := Entry.SetIndex;
  Result^.SetEntryCount := Entry.SetEntryCount;
  for EntryIndex := 0 to Entry.SetEntryCount - 1 do
    Result^.SetEntryOffsets[EntryIndex] := Entry.SetEntryOffsets[EntryIndex];

  if (Entry.Attributes and AttributeDirectory) <> 0 then
    Result^.Common.Information.Kind := NodeKindDirectory
  else
    Result^.Common.Information.Kind := NodeKindFile;
  Result^.Common.Information.SizeInBytes := Entry.DataLength;
  Result^.Common.Information.AllocatedBytes := (Entry.DataLength + PExFatVolume(Volume^.DriverData)^.BytesPerCluster - 1)
    div PExFatVolume(Volume^.DriverData)^.BytesPerCluster * PExFatVolume(Volume^.DriverData)^.BytesPerCluster;
  Result^.Common.Information.NodeNumber := Entry.SetEntryOffsets[0];
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.ModificationTime :=
    TimestampToUnixTime(Entry.LastModifiedTimestamp, Entry.LastModifiedUtcOffset);
  Result^.Common.Information.AccessTime := Result^.Common.Information.ModificationTime;
  Result^.Common.Information.ChangeTime := Result^.Common.Information.ModificationTime;
  if (Entry.Attributes and AttributeReadOnly) <> 0 then
    Result^.Common.Information.Mode := $124
  else
    Result^.Common.Information.Mode := $1A4;
end;

function CreateRootNode(Volume: PVolume): PExFatNode;
var
  ExFat: PExFatVolume;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := PExFatNode(AllocateZeroedKernelMemory(SizeOf(TExFatNode)));
  if Result = nil then
    Exit;
  Result^.Common.Volume := Volume;
  Result^.Common.Information.Kind := NodeKindDirectory;
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.Mode := $1ED;
  Result^.Common.Information.NodeNumber := RootNodeNumber;
  Result^.FirstCluster := ExFat^.RootCluster;
  Result^.IsContiguous := False;
  Result^.HasKnownLength := False;
  Result^.IsRoot := True;
end;

function UpdateNodeEntrySet(Node: PExFatNode; Modify: Boolean): TFileSystemStatus;
var
  Volume: PVolume;
  EntrySet: TEntrySet;
  EntryIndex: Integer;
  FileEntry: PFileEntry;
  Stream: PStreamEntry;
  Timestamp: LongWord;
begin
  if Node^.IsRoot or Node^.IsDetached then
    Exit(StatusSuccess);
  Volume := Node^.Common.Volume;

  for EntryIndex := 0 to Node^.SetEntryCount - 1 do
  begin
    if not VolumeRead(Volume, Node^.SetEntryOffsets[EntryIndex], DirectoryEntrySize,
      @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;

  FileEntry := PFileEntry(@EntrySet[0][0]);
  Stream := PStreamEntry(@EntrySet[1][0]);
  if (FileEntry^.EntryType <> EntryTypeFile) or (Stream^.EntryType <> EntryTypeStreamExtension) then
    Exit(StatusCorrupted);

  Stream^.FirstCluster := Node^.FirstCluster;
  Stream^.DataLength := Node^.DataLength;
  Node^.Common.Information.AllocatedBytes := Node^.DataLength;
  Stream^.ValidDataLength := Node^.ValidDataLength;
  Stream^.GeneralSecondaryFlags := StreamFlagAllocationPossible;
  if Node^.IsContiguous and (Node^.FirstCluster <> 0) then
    Stream^.GeneralSecondaryFlags := Stream^.GeneralSecondaryFlags or StreamFlagNoFatChain;

  if Modify then
  begin
    Timestamp := CurrentTimestamp;
    FileEntry^.LastModifiedTimestamp := Timestamp;
    FileEntry^.LastAccessedTimestamp := Timestamp;
    FileEntry^.LastModified10ms := 0;
    FileEntry^.LastModifiedUtcOffset := UtcOffsetValid;
    FileEntry^.LastAccessedUtcOffset := UtcOffsetValid;
    if Node^.Common.Information.Kind = NodeKindFile then
      FileEntry^.FileAttributes := FileEntry^.FileAttributes or AttributeArchive;
    Node^.Common.Information.ModificationTime := CurrentWallClockTime;
  end;

  FileEntry^.SetChecksum := ComputeSetChecksum(EntrySet, Node^.SetEntryCount);

  for EntryIndex := 0 to Node^.SetEntryCount - 1 do
  begin
    if not VolumeWrite(Volume, Node^.SetEntryOffsets[EntryIndex], DirectoryEntrySize,
      @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;
  Result := StatusSuccess;
end;

end.
