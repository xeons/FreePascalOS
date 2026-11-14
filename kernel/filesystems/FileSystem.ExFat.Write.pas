{
  Write support for exFAT.

  Allocation: a node grows one cluster at a time. While the cluster after
  its last one is free it stays contiguous (the "no FAT chain" flag);
  otherwise it is converted to a FAT chain on the spot by writing chain
  links for its existing clusters. New clusters are zero filled, and the
  valid data length is kept equal to the data length, so gaps always read
  back as zeros.

  While a volume is being modified its "volume dirty" flag is set in the
  boot sector; Sync clears it again and updates the percentage in use.
  Both fields are excluded from the boot region checksum, so changing
  them needs no checksum update.
}
unit FileSystem.ExFat.Write;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExFatCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
function ExFatWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
function ExFatSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
function ExFatRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
function ExFatRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
function ExFatSync(Volume: PVolume): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Unicode,
  Memory.KernelHeap,
  Kernel.Clock,
  FileSystem.ExFat.Structures,
  FileSystem.ExFat.Volume;

const
  VolumeFlagsOffset = 106;
  PercentInUseOffset = 112;
  IllegalNameCharacters = '"*/:<>?\|';

{ --- Volume state ---------------------------------------------------- }

function ReadVolumeFlags(Volume: PVolume; out Flags: Word): Boolean;
begin
  Result := VolumeRead(Volume, VolumeFlagsOffset, 2, @Flags);
end;

function WriteVolumeFlags(Volume: PVolume; Flags: Word): Boolean;
begin
  Result := VolumeWrite(Volume, VolumeFlagsOffset, 2, @Flags);
end;

{ Sets the dirty flag before the first change, so a checker knows the
  volume may be inconsistent if the system stops before Sync. }
function BeginModification(Volume: PVolume): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Flags: Word;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  if ExFat^.IsMarkedDirty then
    Exit(StatusSuccess);
  if not ReadVolumeFlags(Volume, Flags) then
    Exit(StatusIoError);
  if not WriteVolumeFlags(Volume, Flags or VolumeFlagDirty) then
    Exit(StatusIoError);
  ExFat^.IsMarkedDirty := True;
  Result := StatusSuccess;
end;

{ --- Cluster allocation ---------------------------------------------- }

{ Writes FAT links for a contiguous run so the node can become a chain. }
function ConvertToChain(Node: PExFatNode; ClusterCount: LongWord): TFileSystemStatus;
var
  Volume: PVolume;
  Index: LongWord;
  Cluster: LongWord;
begin
  Volume := Node^.Common.Volume;
  Index := 0;
  while Index < ClusterCount do
  begin
    Cluster := Node^.FirstCluster + Index;
    if Index + 1 < ClusterCount then
    begin
      if not WriteFatEntry(Volume, Cluster, Cluster + 1) then
        Exit(StatusIoError);
    end
    else if not WriteFatEntry(Volume, Cluster, EndOfChain) then
      Exit(StatusIoError);
    Inc(Index);
  end;
  Node^.IsContiguous := False;
  Node^.ChainHint := 0;
  Result := StatusSuccess;
end;

{ Adds one zero filled cluster to the end of Node. ClusterCount and
  LastCluster describe the node before the call and are updated. }
function AppendCluster(Node: PExFatNode; var ClusterCount: LongWord;
  var LastCluster: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Volume: PVolume;
  NewCluster: LongWord;
  NextIsFree: Boolean;
begin
  Volume := Node^.Common.Volume;
  ExFat := PExFatVolume(Volume^.DriverData);

  NextIsFree := False;
  if ClusterCount > 0 then
  begin
    Result := ClusterIsFree(Volume, LastCluster + 1, NextIsFree);
    if Result <> StatusSuccess then
      Exit;
  end;

  if NextIsFree then
    NewCluster := LastCluster + 1
  else
  begin
    Result := FindFreeCluster(Volume, NewCluster);
    if Result <> StatusSuccess then
      Exit;
  end;

  Result := MarkCluster(Volume, NewCluster, True);
  if Result <> StatusSuccess then
    Exit;
  if not VolumeWriteZeros(Volume, ClusterOffset(ExFat, NewCluster), ExFat^.BytesPerCluster) then
    Exit(StatusIoError);

  if ClusterCount = 0 then
  begin
    Node^.FirstCluster := NewCluster;
    Node^.IsContiguous := not Node^.IsRoot;
  end
  else if not (Node^.IsContiguous and (NewCluster = LastCluster + 1)) then
  begin
    { The new cluster does not continue a contiguous run: link it. }
    if Node^.IsContiguous then
    begin
      Result := ConvertToChain(Node, ClusterCount);
      if Result <> StatusSuccess then
        Exit;
    end;
    if not WriteFatEntry(Volume, LastCluster, NewCluster) then
      Exit(StatusIoError);
  end;

  if not Node^.IsContiguous then
  begin
    if not WriteFatEntry(Volume, NewCluster, EndOfChain) then
      Exit(StatusIoError);
  end;

  Inc(ClusterCount);
  LastCluster := NewCluster;
  Result := StatusSuccess;
end;

{ Grows a node to NeededClusters clusters, keeping DataLength (which
  defines a contiguous node's extent) in step. }
function GrowNode(Node: PExFatNode; NeededClusters: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  ClusterCount: LongWord;
  LastCluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);
  Result := CountNodeClusters(Node, ClusterCount, LastCluster);
  if Result <> StatusSuccess then
    Exit;

  while ClusterCount < NeededClusters do
  begin
    Result := AppendCluster(Node, ClusterCount, LastCluster);
    if Result <> StatusSuccess then
      Exit;
    if Node^.DataLength < QWord(ClusterCount) * ExFat^.BytesPerCluster then
    begin
      { Only the allocation grows here; callers set the final lengths. }
      if Node^.IsContiguous then
        Node^.DataLength := QWord(ClusterCount) * ExFat^.BytesPerCluster;
    end;
  end;
  Result := StatusSuccess;
end;

{ Releases all but the first KeepClusters clusters of Node. }
function ShrinkNode(Node: PExFatNode; KeepClusters: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Volume: PVolume;
  ClusterCount: LongWord;
  LastCluster: LongWord;
  Cluster: LongWord;
  NextCluster: LongWord;
  Index: LongWord;
begin
  Volume := Node^.Common.Volume;
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := CountNodeClusters(Node, ClusterCount, LastCluster);
  if (Result <> StatusSuccess) or (ClusterCount <= KeepClusters) then
    Exit;

  if Node^.IsContiguous then
  begin
    Index := KeepClusters;
    while Index < ClusterCount do
    begin
      Result := MarkCluster(Volume, Node^.FirstCluster + Index, False);
      if Result <> StatusSuccess then
        Exit;
      Inc(Index);
    end;
  end
  else
  begin
    if KeepClusters = 0 then
      Cluster := Node^.FirstCluster
    else
    begin
      Result := FindClusterOfNode(Node, KeepClusters - 1, Cluster);
      if Result <> StatusSuccess then
        Exit;
      if not ReadFatEntry(Volume, Cluster, NextCluster) then
        Exit(StatusIoError);
      if not WriteFatEntry(Volume, Cluster, EndOfChain) then
        Exit(StatusIoError);
      Cluster := NextCluster;
    end;

    Index := 0;
    while IsValidCluster(ExFat, Cluster) and (Index <= ExFat^.ClusterCount) do
    begin
      if not ReadFatEntry(Volume, Cluster, NextCluster) then
        Exit(StatusIoError);
      if not WriteFatEntry(Volume, Cluster, 0) then
        Exit(StatusIoError);
      Result := MarkCluster(Volume, Cluster, False);
      if Result <> StatusSuccess then
        Exit;
      Cluster := NextCluster;
      Inc(Index);
    end;
  end;

  Node^.ChainHint := 0;
  if KeepClusters = 0 then
  begin
    Node^.FirstCluster := 0;
    Node^.IsContiguous := False;
  end;
  Result := StatusSuccess;
end;

function ClustersFor(ExFat: PExFatVolume; ByteCount: QWord): LongWord;
begin
  Result := LongWord((ByteCount + ExFat^.BytesPerCluster - 1) div ExFat^.BytesPerCluster);
end;

{ --- Entry sets ------------------------------------------------------ }

function ValidateName(Name: PChar; Units: PWord; out UnitCount: Integer): TFileSystemStatus;
var
  Converted: PtrInt;
  Index: Integer;
  Characters: PChar;
begin
  UnitCount := 0;
  Converted := Utf8ToUtf16(Name, Units, MaximumNameCharacters);
  if Converted <= 0 then
    Exit(StatusNameTooLong);
  UnitCount := Integer(Converted);
  for Index := 0 to UnitCount - 1 do
  begin
    if Units[Index] < $20 then
      Exit(StatusInvalidName);
    Characters := IllegalNameCharacters;
    while Characters^ <> #0 do
    begin
      if Units[Index] = Ord(Characters^) then
        Exit(StatusInvalidName);
      Inc(Characters);
    end;
  end;
  Result := StatusSuccess;
end;

{ Replaces the name entries of EntrySet with Name and returns the new
  number of entries. The file and stream entries are kept. }
function ApplyNameToSet(ExFat: PExFatVolume; var EntrySet: TEntrySet; Units: PWord;
  UnitCount: Integer): Integer;
var
  NameEntryCount: Integer;
  NameEntryIndex: Integer;
  CharacterIndex: Integer;
  Position: Integer;
  NameEntry: PFileNameEntry;
  Stream: PStreamEntry;
begin
  NameEntryCount := (UnitCount + CharactersPerNameEntry - 1) div CharactersPerNameEntry;
  for NameEntryIndex := 0 to NameEntryCount - 1 do
  begin
    FillMemory(@EntrySet[2 + NameEntryIndex][0], DirectoryEntrySize, 0);
    NameEntry := PFileNameEntry(@EntrySet[2 + NameEntryIndex][0]);
    NameEntry^.EntryType := EntryTypeFileName;
    for CharacterIndex := 0 to CharactersPerNameEntry - 1 do
    begin
      Position := NameEntryIndex * CharactersPerNameEntry + CharacterIndex;
      if Position < UnitCount then
        NameEntry^.FileName[CharacterIndex] := Units[Position];
    end;
  end;

  Stream := PStreamEntry(@EntrySet[1][0]);
  Stream^.NameLength := Byte(UnitCount);
  Stream^.NameHash := ComputeNameHash(ExFat, Units, UnitCount);

  Result := 2 + NameEntryCount;
  PFileEntry(@EntrySet[0][0])^.SecondaryCount := Byte(Result - 1);
  PFileEntry(@EntrySet[0][0])^.SetChecksum := ComputeSetChecksum(EntrySet, Result);
end;

{ Finds Count consecutive unused entries in Directory, growing it by a
  cluster at a time if needed. }
function FindFreeEntries(Directory: PExFatNode; Count: Integer; out FirstIndex: QWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Index: QWord;
  RunStart: QWord;
  RunLength: Integer;
  Entry: TRawEntry;
  ClusterCount: LongWord;
  LastCluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Directory^.Common);
  FirstIndex := 0;
  Index := 0;
  RunStart := 0;
  RunLength := 0;

  repeat
    Result := ReadRawEntry(Directory, Index, Entry);
    if Result = StatusEndOfDirectory then
    begin
      Result := CountNodeClusters(Directory, ClusterCount, LastCluster);
      if Result <> StatusSuccess then
        Exit;
      Result := AppendCluster(Directory, ClusterCount, LastCluster);
      if Result <> StatusSuccess then
        Exit;
      if not Directory^.IsRoot then
      begin
        Directory^.DataLength := QWord(ClusterCount) * ExFat^.BytesPerCluster;
        Directory^.ValidDataLength := Directory^.DataLength;
        Directory^.Common.Information.SizeInBytes := Directory^.DataLength;
        Result := UpdateNodeEntrySet(Directory, True);
        if Result <> StatusSuccess then
          Exit;
      end;
      Continue;
    end;
    if Result <> StatusSuccess then
      Exit;

    if (Entry[0] and EntryTypeInUse) = 0 then
    begin
      if RunLength = 0 then
        RunStart := Index;
      Inc(RunLength);
      if RunLength = Count then
      begin
        FirstIndex := RunStart;
        Exit(StatusSuccess);
      end;
    end
    else
      RunLength := 0;
    Inc(Index);
  until False;
end;

{ Writes EntrySet at FirstIndex of Directory and records where each entry
  went in Node. }
function PlaceEntrySet(Directory: PExFatNode; const EntrySet: TEntrySet; EntryCount: Integer;
  Node: PExFatNode): TFileSystemStatus;
var
  FirstIndex: QWord;
  EntryIndex: Integer;
begin
  Result := FindFreeEntries(Directory, EntryCount, FirstIndex);
  if Result <> StatusSuccess then
    Exit;

  for EntryIndex := 0 to EntryCount - 1 do
  begin
    Result := EntryVolumeOffset(Directory, FirstIndex + QWord(EntryIndex), Node^.SetEntryOffsets[EntryIndex]);
    if Result <> StatusSuccess then
      Exit;
    if not VolumeWrite(Directory^.Common.Volume, Node^.SetEntryOffsets[EntryIndex],
      DirectoryEntrySize, @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;

  Node^.SetIndex := FirstIndex;
  Node^.SetEntryCount := EntryCount;
  Node^.Common.Information.NodeNumber := Node^.SetEntryOffsets[0];
  Result := StatusSuccess;
end;

{ Clears the in-use bit of every entry of Node's set. }
function MarkSetUnused(Node: PExFatNode): TFileSystemStatus;
var
  EntryIndex: Integer;
  EntryType: Byte;
  Volume: PVolume;
begin
  Volume := Node^.Common.Volume;
  for EntryIndex := 0 to Node^.SetEntryCount - 1 do
  begin
    if not VolumeRead(Volume, Node^.SetEntryOffsets[EntryIndex], 1, @EntryType) then
      Exit(StatusIoError);
    EntryType := EntryType and not EntryTypeInUse;
    if not VolumeWrite(Volume, Node^.SetEntryOffsets[EntryIndex], 1, @EntryType) then
      Exit(StatusIoError);
  end;
  Result := StatusSuccess;
end;

function ReadNodeSet(Node: PExFatNode; out EntrySet: TEntrySet): TFileSystemStatus;
var
  EntryIndex: Integer;
begin
  for EntryIndex := 0 to Node^.SetEntryCount - 1 do
  begin
    if not VolumeRead(Node^.Common.Volume, Node^.SetEntryOffsets[EntryIndex], DirectoryEntrySize,
      @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;
  Result := StatusSuccess;
end;

{ --- Driver routines ------------------------------------------------- }

function ExFatCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
var
  Volume: PVolume;
  ExFat: PExFatVolume;
  Units: array[0..MaximumNameCharacters] of Word;
  UnitCount: Integer;
  EntrySet: TEntrySet;
  EntryCount: Integer;
  FileEntry: PFileEntry;
  Stream: PStreamEntry;
  Node: PExFatNode;
  Timestamp: LongWord;
  ClusterCount: LongWord;
  LastCluster: LongWord;
begin
  Created := nil;
  if (Kind <> NodeKindFile) and (Kind <> NodeKindDirectory) then
    Exit(StatusUnsupported); { exFAT has no symbolic links }

  Volume := Directory^.Volume;
  ExFat := PExFatVolume(Volume^.DriverData);
  Result := ValidateName(Name, @Units[0], UnitCount);
  if Result <> StatusSuccess then
    Exit;
  Result := BeginModification(Volume);
  if Result <> StatusSuccess then
    Exit;

  Node := PExFatNode(AllocateZeroedKernelMemory(SizeOf(TExFatNode)));
  if Node = nil then
    Exit(StatusOutOfMemory);
  Node^.Common.Volume := Volume;
  Node^.HasKnownLength := True;
  Node^.Common.Information.LinkCount := 1;
  Node^.Common.Information.Mode := $1A4;

  { A new directory gets one empty cluster straight away. }
  if Kind = NodeKindDirectory then
  begin
    Node^.Common.Information.Kind := NodeKindDirectory;
    ClusterCount := 0;
    LastCluster := 0;
    Result := AppendCluster(Node, ClusterCount, LastCluster);
    if Result <> StatusSuccess then
    begin
      FreeKernelMemory(Node);
      Exit;
    end;
    Node^.DataLength := ExFat^.BytesPerCluster;
    Node^.ValidDataLength := Node^.DataLength;
    Node^.Common.Information.SizeInBytes := Node^.DataLength;
  end
  else
    Node^.Common.Information.Kind := NodeKindFile;

  FillMemory(@EntrySet, SizeOf(EntrySet), 0);
  Timestamp := CurrentTimestamp;
  FileEntry := PFileEntry(@EntrySet[0][0]);
  FileEntry^.EntryType := EntryTypeFile;
  if Kind = NodeKindDirectory then
    FileEntry^.FileAttributes := AttributeDirectory
  else
    FileEntry^.FileAttributes := AttributeArchive;
  FileEntry^.CreateTimestamp := Timestamp;
  FileEntry^.LastModifiedTimestamp := Timestamp;
  FileEntry^.LastAccessedTimestamp := Timestamp;
  FileEntry^.CreateUtcOffset := UtcOffsetValid;
  FileEntry^.LastModifiedUtcOffset := UtcOffsetValid;
  FileEntry^.LastAccessedUtcOffset := UtcOffsetValid;

  Stream := PStreamEntry(@EntrySet[1][0]);
  Stream^.EntryType := EntryTypeStreamExtension;
  Stream^.GeneralSecondaryFlags := StreamFlagAllocationPossible;
  if Node^.IsContiguous and (Node^.FirstCluster <> 0) then
    Stream^.GeneralSecondaryFlags := Stream^.GeneralSecondaryFlags or StreamFlagNoFatChain;
  Stream^.FirstCluster := Node^.FirstCluster;
  Stream^.DataLength := Node^.DataLength;
  Stream^.ValidDataLength := Node^.ValidDataLength;

  EntryCount := ApplyNameToSet(ExFat, EntrySet, @Units[0], UnitCount);
  Result := PlaceEntrySet(PExFatNode(Directory), EntrySet, EntryCount, Node);
  if Result <> StatusSuccess then
  begin
    ShrinkNode(Node, 0);
    FreeKernelMemory(Node);
    Exit;
  end;

  Node^.Common.Information.ModificationTime := CurrentWallClockTime;
  Created := @Node^.Common;
end;

function ExFatWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  ExFat: PExFatVolume;
  NewEnd: QWord;
  UpdateStatus: TFileSystemStatus;
begin
  BytesWritten := 0;
  ExFatNode := PExFatNode(Node);
  ExFat := ExFatVolumeOf(Node);
  NewEnd := Offset + ByteCount;
  if NewEnd < Offset then
    Exit(StatusNoSpace);

  Result := BeginModification(Node^.Volume);
  if Result <> StatusSuccess then
    Exit;

  if NewEnd > ExFatNode^.DataLength then
    Result := GrowNode(ExFatNode, ClustersFor(ExFat, NewEnd));

  { Bytes between the valid data length and the write must become zeros
    before the valid data length can move past them. }
  if (Result = StatusSuccess) and (Offset > ExFatNode^.ValidDataLength) then
    Result := WriteNodeBytes(ExFatNode, ExFatNode^.ValidDataLength,
      Offset - ExFatNode^.ValidDataLength, nil);

  if Result = StatusSuccess then
  begin
    Result := WriteNodeBytes(ExFatNode, Offset, ByteCount, PByte(Buffer));
    if Result = StatusSuccess then
      BytesWritten := ByteCount;
  end;

  if Offset + BytesWritten > ExFatNode^.ValidDataLength then
    ExFatNode^.ValidDataLength := Offset + BytesWritten;
  if NewEnd > Node^.Information.SizeInBytes then
  begin
    if Result = StatusSuccess then
      Node^.Information.SizeInBytes := NewEnd
    else if ExFatNode^.ValidDataLength > Node^.Information.SizeInBytes then
      Node^.Information.SizeInBytes := ExFatNode^.ValidDataLength;
  end;
  ExFatNode^.DataLength := Node^.Information.SizeInBytes;
  if ExFatNode^.ValidDataLength > ExFatNode^.DataLength then
    ExFatNode^.ValidDataLength := ExFatNode^.DataLength;

  UpdateStatus := UpdateNodeEntrySet(ExFatNode, True);
  if Result = StatusSuccess then
    Result := UpdateStatus;
end;

function ExFatSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  ExFat: PExFatVolume;
begin
  ExFatNode := PExFatNode(Node);
  ExFat := ExFatVolumeOf(Node);
  Result := BeginModification(Node^.Volume);
  if Result <> StatusSuccess then
    Exit;

  if NewSize > ExFatNode^.DataLength then
  begin
    Result := GrowNode(ExFatNode, ClustersFor(ExFat, NewSize));
    if Result = StatusSuccess then
      Result := WriteNodeBytes(ExFatNode, ExFatNode^.ValidDataLength,
        NewSize - ExFatNode^.ValidDataLength, nil);
    if Result <> StatusSuccess then
      Exit;
    ExFatNode^.ValidDataLength := NewSize;
  end
  else
  begin
    Result := ShrinkNode(ExFatNode, ClustersFor(ExFat, NewSize));
    if Result <> StatusSuccess then
      Exit;
    if ExFatNode^.ValidDataLength > NewSize then
      ExFatNode^.ValidDataLength := NewSize;
  end;

  ExFatNode^.DataLength := NewSize;
  Node^.Information.SizeInBytes := NewSize;
  Result := UpdateNodeEntrySet(ExFatNode, True);
end;

function DirectoryIsEmpty(Directory: PExFatNode; out IsEmpty: Boolean): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
  Entry: TExFatEntry;
begin
  Cursor.Position := 0;
  Cursor.Extra := 0;
  Result := NextEntry(Directory, Cursor, Entry);
  IsEmpty := Result = StatusEndOfDirectory;
  if (Result = StatusEndOfDirectory) or (Result = StatusSuccess) then
    Result := StatusSuccess;
end;

function ExFatRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  IsEmpty: Boolean;
begin
  ExFatNode := PExFatNode(Node);
  if ExFatNode^.IsRoot then
    Exit(StatusInvalidPath);

  if Node^.Information.Kind = NodeKindDirectory then
  begin
    Result := DirectoryIsEmpty(ExFatNode, IsEmpty);
    if Result <> StatusSuccess then
      Exit;
    if not IsEmpty then
      Exit(StatusDirectoryNotEmpty);
  end;

  Result := BeginModification(Node^.Volume);
  if Result = StatusSuccess then
    Result := MarkSetUnused(ExFatNode);
  if Result = StatusSuccess then
    Result := ShrinkNode(ExFatNode, 0);
end;

function ExFatRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  ExFat: PExFatVolume;
  Units: array[0..MaximumNameCharacters] of Word;
  UnitCount: Integer;
  OldSet: TEntrySet;
  NewSet: TEntrySet;
  OldCount: Integer;
  OldOffsets: array[0..MaximumEntrySetSize - 1] of QWord;
  OldIndex: QWord;
  NewCount: Integer;
  EntryIndex: Integer;
begin
  ExFatNode := PExFatNode(Node);
  ExFat := ExFatVolumeOf(Node);
  Result := ValidateName(TargetName, @Units[0], UnitCount);
  if Result <> StatusSuccess then
    Exit;
  Result := BeginModification(Node^.Volume);
  if Result <> StatusSuccess then
    Exit;

  Result := ReadNodeSet(ExFatNode, OldSet);
  if Result <> StatusSuccess then
    Exit;
  OldCount := ExFatNode^.SetEntryCount;
  OldIndex := ExFatNode^.SetIndex;
  for EntryIndex := 0 to OldCount - 1 do
    OldOffsets[EntryIndex] := ExFatNode^.SetEntryOffsets[EntryIndex];

  { The old entries are released first, so a rename that only changes
    letter case can reuse them. }
  Result := MarkSetUnused(ExFatNode);
  if Result <> StatusSuccess then
    Exit;

  NewSet := OldSet;
  NewCount := ApplyNameToSet(ExFat, NewSet, @Units[0], UnitCount);
  Result := PlaceEntrySet(PExFatNode(TargetDirectory), NewSet, NewCount, ExFatNode);
  if Result <> StatusSuccess then
  begin
    { Put the old entries back. }
    for EntryIndex := 0 to OldCount - 1 do
    begin
      VolumeWrite(Node^.Volume, OldOffsets[EntryIndex], DirectoryEntrySize, @OldSet[EntryIndex][0]);
      ExFatNode^.SetEntryOffsets[EntryIndex] := OldOffsets[EntryIndex];
    end;
    ExFatNode^.SetEntryCount := OldCount;
    ExFatNode^.SetIndex := OldIndex;
    Node^.Information.NodeNumber := OldOffsets[0];
  end;
end;

function ExFatSync(Volume: PVolume): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Flags: Word;
  PercentInUse: Byte;
  UsedClusters: QWord;
begin
  ExFat := PExFatVolume(Volume^.DriverData);

  UsedClusters := ExFat^.ClusterCount - ExFat^.FreeClusterCount;
  PercentInUse := Byte((UsedClusters * 100) div ExFat^.ClusterCount);
  if not VolumeWrite(Volume, PercentInUseOffset, 1, @PercentInUse) then
    Exit(StatusIoError);

  if ExFat^.IsMarkedDirty then
  begin
    if not ReadVolumeFlags(Volume, Flags) then
      Exit(StatusIoError);
    if not WriteVolumeFlags(Volume, Flags and not VolumeFlagDirty) then
      Exit(StatusIoError);
    ExFat^.IsMarkedDirty := False;
  end;
  Result := StatusSuccess;
end;

end.
