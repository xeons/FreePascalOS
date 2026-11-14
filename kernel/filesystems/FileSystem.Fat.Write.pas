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
  Write support for FAT12, FAT16 and FAT32.

  Creating a name writes an entry set (long name records, if needed,
  followed by the short record) into the first run of free records in the
  directory, growing the directory by a cluster when there is no room.
  File data grows a cluster at a time; new clusters are zero filled so a
  gap written past the end of a file reads back as zeros.

  Every allocation table change is written to all copies of the table.
  On FAT32 the FSInfo sector's free cluster count is kept up to date by
  Sync.
}
unit FileSystem.Fat.Write;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function FatCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
function FatWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
function FatSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
function FatRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
function FatRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
function FatSync(Volume: PVolume): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Time,
  Kernel.Clock,
  FileSystem.Fat.Structures,
  FileSystem.Fat.Names,
  FileSystem.Fat.Volume;

const
  MaximumNumericTail = 999999;
  MaximumEntrySetSize = MaximumLongNameEntries + 1;

{ --- Short names ----------------------------------------------------- }

function ShortNameExists(Directory: PFatNode; const ShortName: TShortName;
  out Exists: Boolean): TFileSystemStatus;
var
  Index: QWord;
  DirectoryRecord: TDirectoryRecord;
begin
  Exists := False;
  Index := 0;
  repeat
    Result := ReadDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result = StatusEndOfDirectory then
      Exit(StatusSuccess);
    if Result <> StatusSuccess then
      Exit;
    if DirectoryRecord.Name[0] = EntryEndOfDirectory then
      Exit(StatusSuccess);
    if (DirectoryRecord.Name[0] <> EntryDeleted) and not RecordIsLongNamePart(DirectoryRecord) and
       MemoryIsEqual(@DirectoryRecord.Name[0], @ShortName[0], ShortNameLength) then
    begin
      Exists := True;
      Exit(StatusSuccess);
    end;
    Inc(Index);
  until False;
end;

{ Settles the short name of Plan so that it is unique in Directory. }
function ChooseShortName(Directory: PFatNode; var Plan: TNamePlan): TFileSystemStatus;
var
  BasisName: TShortName;
  Exists: Boolean;
  Number: LongWord;
begin
  if not Plan.NeedsNumericTail then
  begin
    Result := ShortNameExists(Directory, Plan.ShortName, Exists);
    if (Result <> StatusSuccess) or not Exists then
      Exit;
    { The plain form is taken: fall back to a numbered form, which only
      a long name can explain. }
    Plan.NeedsLongName := True;
    Plan.CaseFlags := 0;
  end;

  BasisName := Plan.ShortName;
  for Number := 1 to MaximumNumericTail do
  begin
    Plan.ShortName := BasisName;
    ApplyNumericTail(Plan, Number);
    Result := ShortNameExists(Directory, Plan.ShortName, Exists);
    if Result <> StatusSuccess then
      Exit;
    if not Exists then
      Exit(StatusSuccess);
  end;
  Result := StatusAlreadyExists;
end;

{ --- Directory space ------------------------------------------------- }

{ Finds Count consecutive free records in Directory, growing it if
  needed. Returns the index of the first. }
function FindFreeRecords(Directory: PFatNode; Count: Integer; out FirstIndex: QWord): TFileSystemStatus;
var
  Volume: PVolume;
  Index: QWord;
  RunStart: QWord;
  RunLength: Integer;
  DirectoryRecord: TDirectoryRecord;
  ClusterCount: LongWord;
  LastCluster: LongWord;
  NewCluster: LongWord;
begin
  Volume := Directory^.Common.Volume;
  FirstIndex := 0;
  Index := 0;
  RunStart := 0;
  RunLength := 0;

  repeat
    Result := ReadDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result = StatusEndOfDirectory then
    begin
      { Out of records: add a cluster, whose records are all free. }
      if Directory^.IsFixedRoot then
        Exit(StatusNoSpace);
      Result := MeasureChain(Directory, ClusterCount, LastCluster);
      if Result <> StatusSuccess then
        Exit;
      Result := AllocateCluster(Volume, LastCluster, NewCluster);
      if Result <> StatusSuccess then
        Exit;
      Continue;
    end;
    if Result <> StatusSuccess then
      Exit;

    if (DirectoryRecord.Name[0] = EntryEndOfDirectory) or (DirectoryRecord.Name[0] = EntryDeleted) then
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

{ Writes the long name records (if any) and the short record at
  FirstIndex. Returns the index of the short record. }
function WriteEntrySet(Directory: PFatNode; FirstIndex: QWord; const Plan: TNamePlan;
  const ShortRecord: TDirectoryRecord; out ShortIndex: QWord): TFileSystemStatus;
var
  LongNameRecords: Integer;
  Checksum: Byte;
  Part: Integer;
  DirectoryRecord: TDirectoryRecord;
  Index: QWord;
begin
  LongNameRecords := LongNameRecordCount(Plan);
  Checksum := ShortNameChecksum(ShortRecord.Name);
  Index := FirstIndex;

  { The record with the highest ordinal comes first. }
  for Part := LongNameRecords downto 1 do
  begin
    BuildLongNameRecord(Plan, Part, Checksum, DirectoryRecord);
    Result := WriteDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result <> StatusSuccess then
      Exit;
    Inc(Index);
  end;

  Result := WriteDirectoryRecord(Directory, Index, ShortRecord);
  ShortIndex := Index;
end;

function MarkRecordsDeleted(Directory: PFatNode; FirstIndex, LastIndex: QWord): TFileSystemStatus;
var
  Index: QWord;
  DirectoryRecord: TDirectoryRecord;
begin
  Index := FirstIndex;
  while Index <= LastIndex do
  begin
    Result := ReadDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result <> StatusSuccess then
      Exit;
    DirectoryRecord.Name[0] := EntryDeleted;
    Result := WriteDirectoryRecord(Directory, Index, DirectoryRecord);
    if Result <> StatusSuccess then
      Exit;
    Inc(Index);
  end;
  Result := StatusSuccess;
end;

{ Plans Name and places it in Directory with ShortRecord's contents. }
function PlaceName(Directory: PFatNode; Name: PChar; var ShortRecord: TDirectoryRecord;
  out SetFirstIndex: QWord; out ShortIndex: QWord): TFileSystemStatus;
var
  Plan: TNamePlan;
begin
  Result := PlanName(Name, Plan);
  if Result <> StatusSuccess then
    Exit;
  Result := ChooseShortName(Directory, Plan);
  if Result <> StatusSuccess then
    Exit;

  ShortRecord.Name := Plan.ShortName;
  ShortRecord.CaseFlags := Plan.CaseFlags;

  Result := FindFreeRecords(Directory, LongNameRecordCount(Plan) + 1, SetFirstIndex);
  if Result <> StatusSuccess then
    Exit;
  Result := WriteEntrySet(Directory, SetFirstIndex, Plan, ShortRecord, ShortIndex);
end;

{ --- Helpers --------------------------------------------------------- }

function DirectoryClusterForDotDot(Directory: PFatNode): LongWord;
begin
  { ".." of a directory in the root points at cluster 0, even on FAT32. }
  if Directory^.IsRoot then
    Result := 0
  else
    Result := Directory^.FirstCluster;
end;

procedure StampRecord(var DirectoryRecord: TDirectoryRecord; Time: TUnixTime);
var
  DateWord: Word;
  TimeWord: Word;
begin
  UnixTimeToDosDateTime(Time, DateWord, TimeWord);
  DirectoryRecord.CreationDate := DateWord;
  DirectoryRecord.CreationTime := TimeWord;
  DirectoryRecord.CreationTimeTenths := 0;
  DirectoryRecord.WriteDate := DateWord;
  DirectoryRecord.WriteTime := TimeWord;
  DirectoryRecord.LastAccessDate := DateWord;
end;

function WriteDotEntries(Volume: PVolume; DirectoryCluster: LongWord; ParentCluster: LongWord;
  const Template: TDirectoryRecord): TFileSystemStatus;
var
  Fat: PFatVolume;
  DotRecord: TDirectoryRecord;
begin
  Fat := PFatVolume(Volume^.DriverData);

  DotRecord := Template;
  FillMemory(@DotRecord.Name[0], ShortNameLength, Ord(' '));
  DotRecord.Name[0] := Ord('.');
  DotRecord.CaseFlags := 0;
  DotRecord.Attributes := AttributeDirectory;
  DotRecord.FileSize := 0;
  SetRecordFirstCluster(DotRecord, DirectoryCluster);
  if not VolumeWrite(Volume, ClusterOffset(Fat, DirectoryCluster), DirectoryEntrySize, @DotRecord) then
    Exit(StatusIoError);

  DotRecord.Name[1] := Ord('.');
  SetRecordFirstCluster(DotRecord, ParentCluster);
  if not VolumeWrite(Volume, ClusterOffset(Fat, DirectoryCluster) + DirectoryEntrySize,
    DirectoryEntrySize, @DotRecord) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

{ Makes sure Node owns enough clusters for NewSize bytes. }
function EnsureCapacity(Node: PFatNode; NewSize: QWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Volume: PVolume;
  NeededClusters: QWord;
  ClusterCount: LongWord;
  LastCluster: LongWord;
  NewCluster: LongWord;
begin
  Volume := Node^.Common.Volume;
  Fat := PFatVolume(Volume^.DriverData);
  NeededClusters := (NewSize + Fat^.BytesPerCluster - 1) div Fat^.BytesPerCluster;

  Result := MeasureChain(Node, ClusterCount, LastCluster);
  if Result <> StatusSuccess then
    Exit;

  while ClusterCount < NeededClusters do
  begin
    Result := AllocateCluster(Volume, LastCluster, NewCluster);
    if Result <> StatusSuccess then
      Exit;
    if Node^.FirstCluster = 0 then
      Node^.FirstCluster := NewCluster;
    LastCluster := NewCluster;
    Inc(ClusterCount);
  end;
  Result := StatusSuccess;
end;

{ Writes Count bytes from Source (or zeros when Source is nil) into the
  node's clusters at Offset. The clusters must exist. }
function WriteIntoClusters(Node: PFatNode; Offset: QWord; Source: PByte; Count: QWord;
  out Written: QWord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Volume: PVolume;
  Cluster: LongWord;
  OffsetInCluster: QWord;
  ChunkBytes: QWord;
  WriteSucceeded: Boolean;
begin
  Volume := Node^.Common.Volume;
  Fat := PFatVolume(Volume^.DriverData);
  Written := 0;

  while Count > 0 do
  begin
    Result := FindClusterOfChain(Node, LongWord(Offset div Fat^.BytesPerCluster), Cluster);
    if Result = StatusEndOfDirectory then
      Exit(StatusCorrupted);
    if Result <> StatusSuccess then
      Exit;

    OffsetInCluster := Offset mod Fat^.BytesPerCluster;
    ChunkBytes := Fat^.BytesPerCluster - OffsetInCluster;
    if ChunkBytes > Count then
      ChunkBytes := Count;

    if Source <> nil then
      WriteSucceeded := VolumeWrite(Volume, ClusterOffset(Fat, Cluster) + OffsetInCluster, ChunkBytes, Source)
    else
      WriteSucceeded := VolumeWriteZeros(Volume, ClusterOffset(Fat, Cluster) + OffsetInCluster, ChunkBytes);
    if not WriteSucceeded then
      Exit(StatusIoError);

    if Source <> nil then
      Source := Source + ChunkBytes;
    Offset := Offset + ChunkBytes;
    Count := Count - ChunkBytes;
    Written := Written + ChunkBytes;
  end;
  Result := StatusSuccess;
end;

function DirectoryIsEmpty(Directory: PFatNode; out IsEmpty: Boolean): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
  Entry: TFatEntry;
begin
  Cursor.Position := 0;
  Cursor.Extra := 0;
  Result := NextEntry(Directory, Cursor, Entry);
  IsEmpty := Result = StatusEndOfDirectory;
  if (Result = StatusEndOfDirectory) or (Result = StatusSuccess) then
    Result := StatusSuccess;
end;

{ --- Driver routines ------------------------------------------------- }

function FatCreateNode(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
  out Created: PNode): TFileSystemStatus;
var
  Parent: PFatNode;
  Volume: PVolume;
  ShortRecord: TDirectoryRecord;
  NewCluster: LongWord;
  Entry: TFatEntry;
  Node: PFatNode;
begin
  Created := nil;
  if (Kind <> NodeKindFile) and (Kind <> NodeKindDirectory) then
    Exit(StatusUnsupported); { FAT has no symbolic links }

  Parent := PFatNode(Directory);
  Volume := Directory^.Volume;

  FillMemory(@ShortRecord, SizeOf(ShortRecord), 0);
  StampRecord(ShortRecord, CurrentWallClockTime);
  NewCluster := 0;
  if Kind = NodeKindDirectory then
  begin
    ShortRecord.Attributes := AttributeDirectory;
    Result := AllocateCluster(Volume, 0, NewCluster);
    if Result <> StatusSuccess then
      Exit;
    SetRecordFirstCluster(ShortRecord, NewCluster);
    Result := WriteDotEntries(Volume, NewCluster, DirectoryClusterForDotDot(Parent), ShortRecord);
    if Result <> StatusSuccess then
    begin
      FreeClusterChain(Volume, NewCluster);
      Exit;
    end;
  end
  else
    ShortRecord.Attributes := AttributeArchive;

  Result := PlaceName(Parent, Name, ShortRecord, Entry.SetFirstIndex, Entry.ShortEntryIndex);
  if Result = StatusSuccess then
    Result := DirectoryRecordOffset(Parent, Entry.ShortEntryIndex, Entry.EntryOffset);
  if Result <> StatusSuccess then
  begin
    if NewCluster <> 0 then
      FreeClusterChain(Volume, NewCluster);
    Exit;
  end;

  Entry.DirectoryRecord := ShortRecord;
  Node := CreateNodeFromEntry(Volume, Entry);
  if Node = nil then
    Exit(StatusOutOfMemory);
  Created := @Node^.Common;
end;

function FatWriteFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
var
  FatNode: PFatNode;
  OldSize: QWord;
  NewEnd: QWord;
  GapWritten: QWord;
  UpdateStatus: TFileSystemStatus;
begin
  BytesWritten := 0;
  FatNode := PFatNode(Node);
  OldSize := Node^.Information.SizeInBytes;
  if (Offset > MaximumFatFileSize) or (ByteCount > MaximumFatFileSize - Offset) then
    Exit(StatusNoSpace);
  NewEnd := Offset + ByteCount;

  Result := EnsureCapacity(FatNode, NewEnd);
  if (Result = StatusSuccess) and (Offset > OldSize) then
    Result := WriteIntoClusters(FatNode, OldSize, nil, Offset - OldSize, GapWritten);
  if Result = StatusSuccess then
    Result := WriteIntoClusters(FatNode, Offset, PByte(Buffer), ByteCount, BytesWritten);

  if Offset + BytesWritten > OldSize then
    Node^.Information.SizeInBytes := Offset + BytesWritten;
  UpdateStatus := UpdateNodeRecord(FatNode, True);
  if Result = StatusSuccess then
    Result := UpdateStatus;
end;

function FatSetFileSize(Node: PNode; NewSize: QWord): TFileSystemStatus;
var
  FatNode: PFatNode;
  Volume: PVolume;
  Fat: PFatVolume;
  OldSize: QWord;
  KeepClusters: QWord;
  LastKept: LongWord;
  FirstFreed: LongWord;
  Written: QWord;
begin
  FatNode := PFatNode(Node);
  Volume := Node^.Volume;
  Fat := PFatVolume(Volume^.DriverData);
  OldSize := Node^.Information.SizeInBytes;
  if NewSize > MaximumFatFileSize then
    Exit(StatusNoSpace);

  if NewSize > OldSize then
  begin
    Result := EnsureCapacity(FatNode, NewSize);
    if Result = StatusSuccess then
      Result := WriteIntoClusters(FatNode, OldSize, nil, NewSize - OldSize, Written);
    if Result <> StatusSuccess then
      Exit;
  end
  else if NewSize < OldSize then
  begin
    KeepClusters := (NewSize + Fat^.BytesPerCluster - 1) div Fat^.BytesPerCluster;
    FatNode^.ChainHint := 0;
    if KeepClusters = 0 then
    begin
      if FatNode^.FirstCluster <> 0 then
        Result := FreeClusterChain(Volume, FatNode^.FirstCluster)
      else
        Result := StatusSuccess;
      FatNode^.FirstCluster := 0;
    end
    else
    begin
      Result := FindClusterOfChain(FatNode, LongWord(KeepClusters - 1), LastKept);
      if Result = StatusSuccess then
      begin
        if not ReadFatEntry(Volume, LastKept, FirstFreed) then
          Exit(StatusIoError);
        if not IsEndOfChain(Fat, FirstFreed) then
        begin
          if not WriteFatEntry(Volume, LastKept, Fat^.EndOfChainMarker) then
            Exit(StatusIoError);
          Result := FreeClusterChain(Volume, FirstFreed);
        end;
      end;
      FatNode^.ChainHint := 0;
    end;
    if Result <> StatusSuccess then
      Exit;
  end;

  Node^.Information.SizeInBytes := NewSize;
  Result := UpdateNodeRecord(FatNode, True);
end;

function FatRemoveNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  FatNode: PFatNode;
  IsEmpty: Boolean;
begin
  FatNode := PFatNode(Node);
  if FatNode^.IsRoot then
    Exit(StatusInvalidPath);

  if Node^.Information.Kind = NodeKindDirectory then
  begin
    Result := DirectoryIsEmpty(FatNode, IsEmpty);
    if Result <> StatusSuccess then
      Exit;
    if not IsEmpty then
      Exit(StatusDirectoryNotEmpty);
  end;

  Result := MarkRecordsDeleted(PFatNode(Directory), FatNode^.SetFirstIndex, FatNode^.ShortEntryIndex);
  if Result <> StatusSuccess then
    Exit;
  if FatNode^.FirstCluster <> 0 then
    Result := FreeClusterChain(Node^.Volume, FatNode^.FirstCluster);
  FatNode^.FirstCluster := 0;
end;

function FatRenameNode(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
  TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;
var
  FatNode: PFatNode;
  Source: PFatNode;
  Target: PFatNode;
  Volume: PVolume;
  Fat: PFatVolume;
  SavedRecords: array[0..MaximumEntrySetSize - 1] of TDirectoryRecord;
  SavedCount: QWord;
  Index: QWord;
  ShortRecord: TDirectoryRecord;
  DotDotRecord: TDirectoryRecord;
  NewSetFirst: QWord;
  NewShortIndex: QWord;
  NewOffset: QWord;
begin
  FatNode := PFatNode(Node);
  Source := PFatNode(SourceDirectory);
  Target := PFatNode(TargetDirectory);
  Volume := Node^.Volume;
  Fat := PFatVolume(Volume^.DriverData);

  { Keep the old records so they can be put back if the new name does
    not fit. }
  SavedCount := FatNode^.ShortEntryIndex - FatNode^.SetFirstIndex + 1;
  if SavedCount > MaximumEntrySetSize then
    Exit(StatusCorrupted);
  for Index := 0 to SavedCount - 1 do
  begin
    Result := ReadDirectoryRecord(Source, FatNode^.SetFirstIndex + Index, SavedRecords[Index]);
    if Result <> StatusSuccess then
      Exit;
  end;
  ShortRecord := SavedRecords[SavedCount - 1];

  Result := MarkRecordsDeleted(Source, FatNode^.SetFirstIndex, FatNode^.ShortEntryIndex);
  if Result <> StatusSuccess then
    Exit;

  Result := PlaceName(Target, TargetName, ShortRecord, NewSetFirst, NewShortIndex);
  if Result = StatusSuccess then
    Result := DirectoryRecordOffset(Target, NewShortIndex, NewOffset);
  if Result <> StatusSuccess then
  begin
    for Index := 0 to SavedCount - 1 do
      WriteDirectoryRecord(Source, FatNode^.SetFirstIndex + Index, SavedRecords[Index]);
    Exit;
  end;

  { A directory moved to a new parent must point its ".." there. }
  if (Node^.Information.Kind = NodeKindDirectory) and (Source <> Target) and
     (FatNode^.FirstCluster <> 0) then
  begin
    if not VolumeRead(Volume, ClusterOffset(Fat, FatNode^.FirstCluster) + DirectoryEntrySize,
      DirectoryEntrySize, @DotDotRecord) then
      Exit(StatusIoError);
    SetRecordFirstCluster(DotDotRecord, DirectoryClusterForDotDot(Target));
    if not VolumeWrite(Volume, ClusterOffset(Fat, FatNode^.FirstCluster) + DirectoryEntrySize,
      DirectoryEntrySize, @DotDotRecord) then
      Exit(StatusIoError);
  end;

  FatNode^.SetFirstIndex := NewSetFirst;
  FatNode^.ShortEntryIndex := NewShortIndex;
  FatNode^.EntryOffset := NewOffset;
  Node^.Information.NodeNumber := NewOffset;
  Result := StatusSuccess;
end;

function FatSync(Volume: PVolume): TFileSystemStatus;
var
  Fat: PFatVolume;
  Information: TFileSystemInformationSector;
begin
  Fat := PFatVolume(Volume^.DriverData);
  if Fat^.FileSystemInformationOffset = 0 then
    Exit(StatusSuccess);

  if not VolumeRead(Volume, Fat^.FileSystemInformationOffset, SizeOf(Information), @Information) then
    Exit(StatusIoError);
  if (Information.LeadSignature <> FileSystemInformationLeadSignature) or
     (Information.StructSignature <> FileSystemInformationStructSignature) or
     (Information.TrailSignature <> FileSystemInformationTrailSignature) then
    Exit(StatusSuccess); { not a valid FSInfo sector; leave it alone }

  Information.FreeCount := Fat^.FreeClusterCount;
  Information.NextFree := Fat^.NextFreeHint;
  if not VolumeWrite(Volume, Fat^.FileSystemInformationOffset, SizeOf(Information), @Information) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

end.
