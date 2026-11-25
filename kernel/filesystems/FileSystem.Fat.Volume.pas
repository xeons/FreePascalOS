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
  Mounted FAT volume state and the low level operations on it: the file
  allocation table, cluster chains, and directory records.

  On-disk layout:

    [reserved sectors, starting with the boot sector / BPB]
    [file allocation table] x NumberOfFats
    [root directory]                         FAT12 and FAT16 only
    [data area: clusters 2, 3, 4, ...]

  Nodes are identified by the volume offset of their short directory
  record, which is unique and stable until the file is renamed. The root
  directory, which has no record, uses node number zero.
}
unit FileSystem.Fat.Volume;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Fat.Structures;

const
  RootNodeNumber = 0;

type
  PFatVolume = ^TFatVolume;
  TFatVolume = record
    Variant: TFatVariant;
    BytesPerSector: LongWord;
    BytesPerCluster: LongWord;
    NumberOfFats: LongWord;
    FatSizeInBytes: QWord;
    FirstFatOffset: QWord;
    { Only the active FAT is used when FAT32 mirroring is disabled. }
    MirrorFats: Boolean;
    ActiveFat: LongWord;
    RootDirectoryOffset: QWord;  { FAT12/16 fixed root directory }
    RootEntryCount: LongWord;
    DataOffset: QWord;           { byte offset of cluster 2 }
    ClusterCount: LongWord;
    RootCluster: LongWord;       { FAT32 }
    EndOfChainMinimum: LongWord;
    EndOfChainMarker: LongWord;
    { Write support. }
    FreeClusterCount: LongWord;
    NextFreeHint: LongWord;
    FileSystemInformationOffset: QWord; { FAT32 FSInfo sector, 0 if none }
  end;

  PFatNode = ^TFatNode;
  TFatNode = record
    Common: TNode;
    FirstCluster: LongWord;
    IsFixedRoot: Boolean;
    IsRoot: Boolean;
    { Where the node's records are in its parent directory: the index of
      the first record of the set (a long name part, or the short record
      itself) and of the short record, and the short record's offset on
      the volume. }
    SetFirstIndex: QWord;
    ShortEntryIndex: QWord;
    EntryOffset: QWord;
    { Last cluster visited, to make sequential access linear: the ordinal
      in the upper 32 bits, the cluster number in the lower 32 bits. One
      64-bit field so that it never pairs an ordinal with the wrong
      cluster. }
    ChainHint: QWord;
    { Removed while open: its records are gone (and may belong to another
      file by now), so they are no longer written. }
    IsDetached: Boolean;
  end;

  { One directory entry set, decoded. }
  TFatEntry = record
    Name: TFileName;
    DirectoryRecord: TDirectoryRecord;
    SetFirstIndex: QWord;
    ShortEntryIndex: QWord;
    EntryOffset: QWord;
  end;

function FatVolumeOf(Node: PNode): PFatVolume;

function IsValidDataCluster(Fat: PFatVolume; Cluster: LongWord): Boolean;
function IsEndOfChain(Fat: PFatVolume; Value: LongWord): Boolean;
function ClusterOffset(Fat: PFatVolume; Cluster: LongWord): QWord;

function ReadFatEntry(Volume: PVolume; Cluster: LongWord; out NextCluster: LongWord): Boolean;
function WriteFatEntry(Volume: PVolume; Cluster: LongWord; Value: LongWord): Boolean;

{ Finds the Ordinal'th cluster (counting from zero) of Node's chain.
  Returns StatusEndOfDirectory if the chain is shorter. }
function FindClusterOfChain(Node: PFatNode; Ordinal: LongWord; out Cluster: LongWord): TFileSystemStatus;
{ Counts the clusters in Node's chain and returns the last one. }
function MeasureChain(Node: PFatNode; out ClusterCount: LongWord; out LastCluster: LongWord): TFileSystemStatus;

{ Counts free clusters by scanning the whole table (used at mount). }
function CountFreeClusters(Volume: PVolume): TFileSystemStatus;
{ Allocates one zero filled cluster, marked as the end of a chain, and
  links it after PreviousCluster unless that is zero. }
function AllocateCluster(Volume: PVolume; PreviousCluster: LongWord; out Cluster: LongWord): TFileSystemStatus;
{ Frees the chain starting at FirstCluster. }
function FreeClusterChain(Volume: PVolume; FirstCluster: LongWord): TFileSystemStatus;
{ fstrim: discards every run of free clusters. }
function TrimFreeClusters(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;

{ Directory record access by index within a directory. }
function DirectoryRecordOffset(Directory: PFatNode; Index: QWord; out Offset: QWord): TFileSystemStatus;
function ReadDirectoryRecord(Directory: PFatNode; Index: QWord;
  out DirectoryRecord: TDirectoryRecord): TFileSystemStatus;
function WriteDirectoryRecord(Directory: PFatNode; Index: QWord;
  const DirectoryRecord: TDirectoryRecord): TFileSystemStatus;

{ Returns the next real file or directory at or after Cursor.Position
  (skipping deleted records, volume labels, "." and ".."). }
function NextEntry(Directory: PFatNode; var Cursor: TDirectoryCursor;
  out Entry: TFatEntry): TFileSystemStatus;

function CreateNodeFromEntry(Volume: PVolume; const Entry: TFatEntry): PFatNode;
function CreateRootNode(Volume: PVolume): PFatNode;

{ Rewrites the short record of Node from its current state. }
function UpdateNodeRecord(Node: PFatNode; Modify: Boolean): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Time,
  Memory.KernelHeap,
  Kernel.Clock,
  FileSystem.Fat.Names,
  FileSystem.Discards;

const
  MaximumDirectoryRecords = 65536;

function FatVolumeOf(Node: PNode): PFatVolume;
begin
  Result := PFatVolume(Node^.Volume^.DriverData);
end;

{ --- Allocation table ------------------------------------------------ }

function IsValidDataCluster(Fat: PFatVolume; Cluster: LongWord): Boolean;
begin
  Result := (Cluster >= 2) and (Cluster < Fat^.ClusterCount + 2);
end;

function IsEndOfChain(Fat: PFatVolume; Value: LongWord): Boolean;
begin
  Result := Value >= Fat^.EndOfChainMinimum;
end;

function ClusterOffset(Fat: PFatVolume; Cluster: LongWord): QWord;
begin
  Result := Fat^.DataOffset + QWord(Cluster - 2) * Fat^.BytesPerCluster;
end;

function FatCopyOffset(Fat: PFatVolume; CopyIndex: LongWord): QWord;
begin
  Result := Fat^.FirstFatOffset + QWord(CopyIndex) * Fat^.FatSizeInBytes;
end;

function EntryOffsetInFat(Fat: PFatVolume; Cluster: LongWord): QWord;
begin
  case Fat^.Variant of
    FatVariant12: Result := Cluster + (Cluster div 2);
    FatVariant16: Result := QWord(Cluster) * 2;
  else
    Result := QWord(Cluster) * 4;
  end;
end;

function ReadFatEntry(Volume: PVolume; Cluster: LongWord; out NextCluster: LongWord): Boolean;
var
  Fat: PFatVolume;
  Offset: QWord;
  Value16: Word;
  Value32: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  NextCluster := 0;
  Offset := FatCopyOffset(Fat, Fat^.ActiveFat) + EntryOffsetInFat(Fat, Cluster);
  case Fat^.Variant of
    FatVariant12:
      begin
        Result := VolumeRead(Volume, Offset, 2, @Value16);
        if (Cluster and 1) <> 0 then
          NextCluster := Value16 shr 4
        else
          NextCluster := Value16 and $0FFF;
      end;
    FatVariant16:
      begin
        Result := VolumeRead(Volume, Offset, 2, @Value16);
        NextCluster := Value16;
      end;
  else
    begin
      Result := VolumeRead(Volume, Offset, 4, @Value32);
      NextCluster := Value32 and $0FFFFFFF;
    end;
  end;
end;

{ Writes one entry in one copy of the table. }
function WriteFatEntryInCopy(Volume: PVolume; CopyIndex: LongWord; Cluster: LongWord;
  Value: LongWord): Boolean;
var
  Fat: PFatVolume;
  Offset: QWord;
  Value16: Word;
  Value32: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Offset := FatCopyOffset(Fat, CopyIndex) + EntryOffsetInFat(Fat, Cluster);
  case Fat^.Variant of
    FatVariant12:
      begin
        { Two 12-bit entries share three bytes; keep the neighbour intact. }
        Result := VolumeRead(Volume, Offset, 2, @Value16);
        if not Result then
          Exit;
        if (Cluster and 1) <> 0 then
          Value16 := (Value16 and $000F) or Word((Value and $0FFF) shl 4)
        else
          Value16 := (Value16 and $F000) or Word(Value and $0FFF);
        Result := VolumeWrite(Volume, Offset, 2, @Value16);
      end;
    FatVariant16:
      begin
        Value16 := Word(Value);
        Result := VolumeWrite(Volume, Offset, 2, @Value16);
      end;
  else
    begin
      { The top four bits of a FAT32 entry are reserved and preserved. }
      Result := VolumeRead(Volume, Offset, 4, @Value32);
      if not Result then
        Exit;
      Value32 := (Value32 and $F0000000) or (Value and $0FFFFFFF);
      Result := VolumeWrite(Volume, Offset, 4, @Value32);
    end;
  end;
end;

function WriteFatEntry(Volume: PVolume; Cluster: LongWord; Value: LongWord): Boolean;
var
  Fat: PFatVolume;
  CopyIndex: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  if not Fat^.MirrorFats then
    Exit(WriteFatEntryInCopy(Volume, Fat^.ActiveFat, Cluster, Value));

  Result := True;
  CopyIndex := 0;
  while CopyIndex < Fat^.NumberOfFats do
  begin
    if not WriteFatEntryInCopy(Volume, CopyIndex, Cluster, Value) then
      Result := False;
    Inc(CopyIndex);
  end;
end;

function FindClusterOfChain(Node: PFatNode; Ordinal: LongWord; out Cluster: LongWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Hint: QWord;
  CurrentOrdinal: LongWord;
  CurrentCluster: LongWord;
  NextCluster: LongWord;
begin
  Fat := FatVolumeOf(@Node^.Common);
  Hint := Node^.ChainHint;
  CurrentOrdinal := LongWord(Hint shr 32);
  CurrentCluster := LongWord(Hint);
  { Start over from the first cluster unless the hint is ahead of us. }
  if (CurrentCluster = 0) or (CurrentOrdinal > Ordinal) then
  begin
    CurrentOrdinal := 0;
    CurrentCluster := Node^.FirstCluster;
  end;

  if CurrentCluster = 0 then
    Exit(StatusEndOfDirectory); { no clusters at all }

  while CurrentOrdinal < Ordinal do
  begin
    { No chain is longer than the volume: one that is comes back on
      itself. }
    if (CurrentOrdinal >= Fat^.ClusterCount) or not IsValidDataCluster(Fat, CurrentCluster) then
      Exit(StatusCorrupted);
    if not ReadFatEntry(Node^.Common.Volume, CurrentCluster, NextCluster) then
      Exit(StatusIoError);
    if IsEndOfChain(Fat, NextCluster) then
      Exit(StatusEndOfDirectory);
    CurrentCluster := NextCluster;
    Inc(CurrentOrdinal);
  end;

  if not IsValidDataCluster(Fat, CurrentCluster) then
    Exit(StatusCorrupted);

  Node^.ChainHint := (QWord(CurrentOrdinal) shl 32) or CurrentCluster;
  Cluster := CurrentCluster;
  Result := StatusSuccess;
end;

function MeasureChain(Node: PFatNode; out ClusterCount: LongWord; out LastCluster: LongWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Cluster: LongWord;
  NextCluster: LongWord;
begin
  Fat := FatVolumeOf(@Node^.Common);
  ClusterCount := 0;
  LastCluster := 0;
  Cluster := Node^.FirstCluster;
  if Cluster = 0 then
    Exit(StatusSuccess);

  repeat
    if (not IsValidDataCluster(Fat, Cluster)) or (ClusterCount > Fat^.ClusterCount) then
      Exit(StatusCorrupted);
    Inc(ClusterCount);
    LastCluster := Cluster;
    if not ReadFatEntry(Node^.Common.Volume, Cluster, NextCluster) then
      Exit(StatusIoError);
    Cluster := NextCluster;
  until IsEndOfChain(Fat, Cluster);
  Result := StatusSuccess;
end;

function CountFreeClusters(Volume: PVolume): TFileSystemStatus;
var
  Fat: PFatVolume;
  Cluster: LongWord;
  Value: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Fat^.FreeClusterCount := 0;
  Fat^.NextFreeHint := 0;
  for Cluster := 2 to Fat^.ClusterCount + 1 do
  begin
    if not ReadFatEntry(Volume, Cluster, Value) then
      Exit(StatusIoError);
    if Value = 0 then
    begin
      Inc(Fat^.FreeClusterCount);
      if Fat^.NextFreeHint = 0 then
        Fat^.NextFreeHint := Cluster;
    end;
  end;
  if Fat^.NextFreeHint = 0 then
    Fat^.NextFreeHint := 2;
  Result := StatusSuccess;
end;

function AllocateCluster(Volume: PVolume; PreviousCluster: LongWord; out Cluster: LongWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Candidate: LongWord;
  Checked: LongWord;
  Value: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Cluster := 0;
  if Fat^.FreeClusterCount = 0 then
    Exit(StatusNoSpace);

  Candidate := Fat^.NextFreeHint;
  Checked := 0;
  while Checked < Fat^.ClusterCount do
  begin
    if not IsValidDataCluster(Fat, Candidate) then
      Candidate := 2;
    if not ReadFatEntry(Volume, Candidate, Value) then
      Exit(StatusIoError);
    if Value = 0 then
    begin
      if not WriteFatEntry(Volume, Candidate, Fat^.EndOfChainMarker) then
        Exit(StatusIoError);
      { Its discard, if still waiting, must not reach what goes in now. }
      CancelVolumeDiscard(Volume, ClusterOffset(Fat, Candidate), Fat^.BytesPerCluster);
      if not VolumeWriteZeros(Volume, ClusterOffset(Fat, Candidate), Fat^.BytesPerCluster) then
        Exit(StatusIoError);
      if PreviousCluster <> 0 then
      begin
        if not WriteFatEntry(Volume, PreviousCluster, Candidate) then
          Exit(StatusIoError);
      end;
      Dec(Fat^.FreeClusterCount);
      Fat^.NextFreeHint := Candidate + 1;
      Cluster := Candidate;
      Exit(StatusSuccess);
    end;
    Inc(Candidate);
    Inc(Checked);
  end;
  Result := StatusNoSpace;
end;

function FreeClusterChain(Volume: PVolume; FirstCluster: LongWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Cluster: LongWord;
  NextCluster: LongWord;
  Freed: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Cluster := FirstCluster;
  Freed := 0;
  while IsValidDataCluster(Fat, Cluster) do
  begin
    if Freed > Fat^.ClusterCount then
      Exit(StatusCorrupted); { a loop in the chain }
    if not ReadFatEntry(Volume, Cluster, NextCluster) then
      Exit(StatusIoError);
    if not WriteFatEntry(Volume, Cluster, 0) then
      Exit(StatusIoError);
    QueueVolumeDiscard(Volume, ClusterOffset(Fat, Cluster), Fat^.BytesPerCluster, False);
    Inc(Fat^.FreeClusterCount);
    Inc(Freed);
    if Cluster < Fat^.NextFreeHint then
      Fat^.NextFreeHint := Cluster;
    if IsEndOfChain(Fat, NextCluster) then
      Break;
    Cluster := NextCluster;
  end;
  Result := StatusSuccess;
end;

function TrimFreeClusters(Volume: PVolume; var Discarded: QWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Cluster: LongWord;
  RunStart: LongWord;
  Value: LongWord;
  LastCluster: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Result := StatusSuccess;
  LastCluster := Fat^.ClusterCount + 1;
  Cluster := 2;
  while Cluster <= LastCluster do
  begin
    if not ReadFatEntry(Volume, Cluster, Value) then
      Exit(StatusIoError);
    if Value <> 0 then
    begin
      Inc(Cluster);
      Continue;
    end;
    RunStart := Cluster;
    repeat
      Inc(Cluster);
      if Cluster > LastCluster then
        Break;
      if not ReadFatEntry(Volume, Cluster, Value) then
        Exit(StatusIoError);
    until Value <> 0;
    if not TrimFreeRange(Volume, ClusterOffset(Fat, RunStart), QWord(Cluster - RunStart) * Fat^.BytesPerCluster,
      Discarded) then
      Result := StatusIoError;
  end;
end;

{ --- Directory records ----------------------------------------------- }

function DirectoryRecordOffset(Directory: PFatNode; Index: QWord; out Offset: QWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  EntriesPerCluster: QWord;
  Cluster: LongWord;
begin
  Fat := FatVolumeOf(@Directory^.Common);
  Offset := 0;
  if Directory^.IsFixedRoot then
  begin
    if Index >= Fat^.RootEntryCount then
      Exit(StatusEndOfDirectory);
    Offset := Fat^.RootDirectoryOffset + Index * DirectoryEntrySize;
    Exit(StatusSuccess);
  end;

  { A directory holds at most 65536 records (2 MiB); past that its chain
    is damaged, maybe looping without an end marker. }
  if Index >= MaximumDirectoryRecords then
    Exit(StatusCorrupted);
  EntriesPerCluster := Fat^.BytesPerCluster div DirectoryEntrySize;
  Result := FindClusterOfChain(Directory, LongWord(Index div EntriesPerCluster), Cluster);
  if Result = StatusSuccess then
    Offset := ClusterOffset(Fat, Cluster) + (Index mod EntriesPerCluster) * DirectoryEntrySize;
end;

function ReadDirectoryRecord(Directory: PFatNode; Index: QWord;
  out DirectoryRecord: TDirectoryRecord): TFileSystemStatus;
var
  Offset: QWord;
begin
  Result := DirectoryRecordOffset(Directory, Index, Offset);
  if Result <> StatusSuccess then
    Exit;
  if not VolumeRead(Directory^.Common.Volume, Offset, DirectoryEntrySize, @DirectoryRecord) then
    Result := StatusIoError;
end;

function WriteDirectoryRecord(Directory: PFatNode; Index: QWord;
  const DirectoryRecord: TDirectoryRecord): TFileSystemStatus;
var
  Offset: QWord;
begin
  Result := DirectoryRecordOffset(Directory, Index, Offset);
  if Result <> StatusSuccess then
    Exit;
  if not VolumeWrite(Directory^.Common.Volume, Offset, DirectoryEntrySize, @DirectoryRecord) then
    Result := StatusIoError;
end;

function IsDotEntry(const DirectoryRecord: TDirectoryRecord): Boolean;
begin
  Result := (DirectoryRecord.Name[0] = Ord('.')) and
    ((DirectoryRecord.Name[1] = Ord(' ')) or
     ((DirectoryRecord.Name[1] = Ord('.')) and (DirectoryRecord.Name[2] = Ord(' '))));
end;

function NextEntry(Directory: PFatNode; var Cursor: TDirectoryCursor;
  out Entry: TFatEntry): TFileSystemStatus;
var
  DirectoryRecord: TDirectoryRecord;
  LongName: TLongNameAssembly;
  Index: QWord;
  LongNameStart: QWord;
begin
  ResetLongName(LongName);
  LongNameStart := 0;
  repeat
    Index := Cursor.Position;
    Result := ReadDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result <> StatusSuccess then
      Exit;

    if DirectoryRecord.Name[0] = EntryEndOfDirectory then
      Exit(StatusEndOfDirectory);
    Inc(Cursor.Position);

    if DirectoryRecord.Name[0] = EntryDeleted then
    begin
      ResetLongName(LongName);
      Continue;
    end;

    if RecordIsLongNamePart(DirectoryRecord) then
    begin
      if (PLongNameRecord(@DirectoryRecord)^.Ordinal and LongNameLastEntryFlag) <> 0 then
        LongNameStart := Index;
      AddLongNamePart(LongName, DirectoryRecord);
      Continue;
    end;

    if ((DirectoryRecord.Attributes and AttributeVolumeId) <> 0) or IsDotEntry(DirectoryRecord) then
    begin
      ResetLongName(LongName);
      Continue;
    end;

    if LongNameIsComplete(LongName, DirectoryRecord.Name) then
    begin
      DecodeLongName(LongName, Entry.Name);
      Entry.SetFirstIndex := LongNameStart;
    end
    else
    begin
      FormatShortName(DirectoryRecord, Entry.Name);
      Entry.SetFirstIndex := Index;
    end;

    Entry.DirectoryRecord := DirectoryRecord;
    Entry.ShortEntryIndex := Index;
    Result := DirectoryRecordOffset(Directory, Index, Entry.EntryOffset);
    Exit;
  until False;
end;

{ --- Nodes ----------------------------------------------------------- }

function RoundUpToCluster(Fat: PFatVolume; Size: QWord): QWord;
begin
  Result := (Size + Fat^.BytesPerCluster - 1) div Fat^.BytesPerCluster * Fat^.BytesPerCluster;
end;

procedure DescribeNode(Node: PFatNode; const DirectoryRecord: TDirectoryRecord);
begin
  if (DirectoryRecord.Attributes and AttributeDirectory) <> 0 then
  begin
    Node^.Common.Information.Kind := NodeKindDirectory;
    Node^.Common.Information.SizeInBytes := 0;
  end
  else
  begin
    Node^.Common.Information.Kind := NodeKindFile;
    Node^.Common.Information.SizeInBytes := DirectoryRecord.FileSize;
  end;
  Node^.Common.Information.LinkCount := 1;
  { Whole clusters. }
  Node^.Common.Information.AllocatedBytes := RoundUpToCluster(FatVolumeOf(@Node^.Common),
    Node^.Common.Information.SizeInBytes);
  Node^.Common.Information.ModificationTime :=
    DosDateTimeToUnixTime(DirectoryRecord.WriteDate, DirectoryRecord.WriteTime);
  { FAT keeps only the date of the last access, and no change time. }
  Node^.Common.Information.AccessTime := DosDateTimeToUnixTime(DirectoryRecord.LastAccessDate, 0);
  Node^.Common.Information.ChangeTime := Node^.Common.Information.ModificationTime;
  { When it was made, to 10 ms (the tenths field counts 10 ms steps on
    top of the two second time). }
  Node^.Common.Information.BirthTime :=
    DosDateTimeToUnixTime(DirectoryRecord.CreationDate, DirectoryRecord.CreationTime);
  Node^.Common.Information.BirthNanoseconds := 0;
  if (Node^.Common.Information.BirthTime <> 0) and (DirectoryRecord.CreationTimeTenths <= 199) then
  begin
    Node^.Common.Information.BirthTime := Node^.Common.Information.BirthTime +
      DirectoryRecord.CreationTimeTenths div 100;
    Node^.Common.Information.BirthNanoseconds := LongWord(DirectoryRecord.CreationTimeTenths mod 100) * 10000000;
  end;
  if (DirectoryRecord.Attributes and AttributeReadOnly) <> 0 then
    Node^.Common.Information.Mode := $124  { r--r--r-- }
  else
    Node^.Common.Information.Mode := $1A4; { rw-r--r-- }
end;

function CreateNodeFromEntry(Volume: PVolume; const Entry: TFatEntry): PFatNode;
var
  Fat: PFatVolume;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Result := PFatNode(AllocateZeroedKernelMemory(SizeOf(TFatNode)));
  if Result = nil then
    Exit;

  Result^.Common.Volume := Volume;
  Result^.FirstCluster := RecordFirstCluster(Entry.DirectoryRecord);
  Result^.SetFirstIndex := Entry.SetFirstIndex;
  Result^.ShortEntryIndex := Entry.ShortEntryIndex;
  Result^.EntryOffset := Entry.EntryOffset;
  Result^.Common.Information.NodeNumber := Entry.EntryOffset;

  { A directory record pointing at cluster 0 means the root directory. }
  if ((Entry.DirectoryRecord.Attributes and AttributeDirectory) <> 0) and (Result^.FirstCluster = 0) then
  begin
    if Fat^.Variant = FatVariant32 then
      Result^.FirstCluster := Fat^.RootCluster
    else
      Result^.IsFixedRoot := True;
  end;
  DescribeNode(Result, Entry.DirectoryRecord);
end;

function CreateRootNode(Volume: PVolume): PFatNode;
var
  Fat: PFatVolume;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Result := PFatNode(AllocateZeroedKernelMemory(SizeOf(TFatNode)));
  if Result = nil then
    Exit;
  Result^.Common.Volume := Volume;
  Result^.IsRoot := True;
  Result^.Common.Information.Kind := NodeKindDirectory;
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.Mode := $1ED; { rwxr-xr-x }
  Result^.Common.Information.NodeNumber := RootNodeNumber;
  if Fat^.Variant = FatVariant32 then
    Result^.FirstCluster := Fat^.RootCluster
  else
    Result^.IsFixedRoot := True;
end;

function UpdateNodeRecord(Node: PFatNode; Modify: Boolean): TFileSystemStatus;
var
  DirectoryRecord: TDirectoryRecord;
  Volume: PVolume;
  DateWord: Word;
  TimeWord: Word;
begin
  if Node^.IsRoot or Node^.IsDetached then
    Exit(StatusSuccess);

  Volume := Node^.Common.Volume;
  if not VolumeRead(Volume, Node^.EntryOffset, DirectoryEntrySize, @DirectoryRecord) then
    Exit(StatusIoError);

  if Node^.Common.Information.Kind = NodeKindFile then
  begin
    DirectoryRecord.FileSize := LongWord(Node^.Common.Information.SizeInBytes);
    SetRecordFirstCluster(DirectoryRecord, Node^.FirstCluster);
    Node^.Common.Information.AllocatedBytes := RoundUpToCluster(FatVolumeOf(@Node^.Common),
      Node^.Common.Information.SizeInBytes);
  end;

  if Modify then
  begin
    Node^.Common.Information.ModificationTime := CurrentWallClockTime;
    UnixTimeToDosDateTime(Node^.Common.Information.ModificationTime, DateWord, TimeWord);
    DirectoryRecord.WriteDate := DateWord;
    DirectoryRecord.WriteTime := TimeWord;
    DirectoryRecord.LastAccessDate := DateWord;
    DirectoryRecord.Attributes := DirectoryRecord.Attributes or AttributeArchive;
  end;

  if not VolumeWrite(Volume, Node^.EntryOffset, DirectoryEntrySize, @DirectoryRecord) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

end.
