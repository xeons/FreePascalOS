{
  exFAT file system driver (read-only).

  On-disk layout:

    [main boot region: boot sector at sector 0, 12 sectors]
    [backup boot region]
    [file allocation table, at FatOffset]
    [cluster heap: clusters 2, 3, 4, ..., at ClusterHeapOffset]

  The root directory, the allocation bitmap and the up-case table all
  live in the cluster heap. A file is described by a directory entry set:

    File entry (0x85)          attributes, timestamps, number of entries
    Stream extension (0xC0)    first cluster, lengths, "no FAT chain" flag
    File name entries (0xC1)   15 UTF-16 characters each

  A file whose stream has the "no FAT chain" flag occupies consecutive
  clusters and the allocation table is not consulted for it.

  Lookups compare names through the volume's own up-case table, which is
  what exFAT prescribes for case-insensitive matching.
}
unit FileSystem.ExFat;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExFatFileSystemDriver: PFileSystemDriver;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Unicode,
  Runtime.Time,
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache;

const
  FileSystemNameText = 'EXFAT   ';
  BootSignatureOffset = 510;
  BootSignature = $AA55;

  EntryTypeEndOfDirectory = $00;
  EntryTypeInUse = $80;
  EntryTypeAllocationBitmap = $81;
  EntryTypeUpcaseTable = $82;
  EntryTypeVolumeLabel = $83;
  EntryTypeFile = $85;
  EntryTypeStreamExtension = $C0;
  EntryTypeFileName = $C1;

  AttributeDirectory = $10;
  AttributeReadOnly = $01;

  StreamFlagNoFatChain = $02;

  CharactersPerNameEntry = 15;
  MaximumNameCharacters = 255;
  MaximumSecondaryEntries = 18;

  DirectoryEntrySize = 32;
  EndOfChain = LongWord($FFFFFFF8);

  UpcaseTableCharacters = 65536;
  UpcaseIdentityRunMarker = $FFFF;

type
  TBootSector = packed record
    JumpInstruction: array[0..2] of Byte;
    FileSystemName: array[0..7] of Char;
    MustBeZero: array[0..52] of Byte;
    PartitionOffset: QWord;
    VolumeLength: QWord;
    FatOffset: LongWord;
    FatLength: LongWord;
    ClusterHeapOffset: LongWord;
    ClusterCount: LongWord;
    FirstClusterOfRootDirectory: LongWord;
    VolumeSerialNumber: LongWord;
    FileSystemRevision: Word;
    VolumeFlags: Word;
    BytesPerSectorShift: Byte;
    SectorsPerClusterShift: Byte;
    NumberOfFats: Byte;
    DriveSelect: Byte;
    PercentInUse: Byte;
  end;

  TRawEntry = array[0..DirectoryEntrySize - 1] of Byte;

  TFileEntry = packed record
    EntryType: Byte;
    SecondaryCount: Byte;
    SetChecksum: Word;
    FileAttributes: Word;
    Reserved1: Word;
    CreateTimestamp: LongWord;
    LastModifiedTimestamp: LongWord;
    LastAccessedTimestamp: LongWord;
    Create10ms: Byte;
    LastModified10ms: Byte;
    CreateUtcOffset: Byte;
    LastModifiedUtcOffset: Byte;
    LastAccessedUtcOffset: Byte;
    Reserved2: array[0..6] of Byte;
  end;
  PFileEntry = ^TFileEntry;

  TStreamEntry = packed record
    EntryType: Byte;
    GeneralSecondaryFlags: Byte;
    Reserved1: Byte;
    NameLength: Byte;
    NameHash: Word;
    Reserved2: Word;
    ValidDataLength: QWord;
    Reserved3: LongWord;
    FirstCluster: LongWord;
    DataLength: QWord;
  end;
  PStreamEntry = ^TStreamEntry;

  TFileNameEntry = packed record
    EntryType: Byte;
    GeneralSecondaryFlags: Byte;
    FileName: array[0..CharactersPerNameEntry - 1] of Word;
  end;
  PFileNameEntry = ^TFileNameEntry;

  TVolumeLabelEntry = packed record
    EntryType: Byte;
    CharacterCount: Byte;
    VolumeLabel: array[0..10] of Word;
    Reserved: QWord;
  end;
  PVolumeLabelEntry = ^TVolumeLabelEntry;

  TUpcaseTableEntry = packed record
    EntryType: Byte;
    Reserved1: array[0..2] of Byte;
    TableChecksum: LongWord;
    Reserved2: array[0..11] of Byte;
    FirstCluster: LongWord;
    DataLength: QWord;
  end;
  PUpcaseTableEntry = ^TUpcaseTableEntry;

  PExFatVolume = ^TExFatVolume;
  TExFatVolume = record
    BytesPerCluster: QWord;
    FatOffset: QWord;
    ClusterHeapOffset: QWord;
    ClusterCount: LongWord;
    RootCluster: LongWord;
    { Maps every UTF-16 unit to its upper case form. }
    UpcaseTable: PWord;
  end;

  PExFatNode = ^TExFatNode;
  TExFatNode = record
    Common: TNode;
    FirstCluster: LongWord;
    IsContiguous: Boolean;
    { For directories other than the root, the bytes they occupy. The
      root directory's extent is only known from its cluster chain. }
    DataLength: QWord;
    HasKnownLength: Boolean;
    ValidDataLength: QWord;
    { Ordinal in the upper 32 bits, cluster in the lower 32 bits. }
    ChainHint: QWord;
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
  end;

var
  Driver: TFileSystemDriver;

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

function FindClusterOfNode(Node: PExFatNode; Ordinal: LongWord; out Cluster: LongWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Hint: QWord;
  CurrentOrdinal: LongWord;
  CurrentCluster: LongWord;
  NextCluster: LongWord;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);

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
    if not VolumeRead(Node^.Common.Volume, ExFat^.FatOffset + QWord(CurrentCluster) * 4, 4,
      @NextCluster) then
      Exit(StatusIoError);
    if NextCluster >= EndOfChain then
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

{ Reads Length bytes at Offset within the node's data (which must lie in
  its allocated clusters). }
function ReadNodeBytes(Node: PExFatNode; Offset: QWord; Length: QWord; Buffer: PByte): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Cluster: LongWord;
  OffsetInCluster: QWord;
  ChunkBytes: QWord;
begin
  ExFat := ExFatVolumeOf(@Node^.Common);
  while Length > 0 do
  begin
    Result := FindClusterOfNode(Node, LongWord(Offset div ExFat^.BytesPerCluster), Cluster);
    if Result <> StatusSuccess then
      Exit;
    OffsetInCluster := Offset mod ExFat^.BytesPerCluster;
    ChunkBytes := ExFat^.BytesPerCluster - OffsetInCluster;
    if ChunkBytes > Length then
      ChunkBytes := Length;
    if not VolumeRead(Node^.Common.Volume, ClusterOffset(ExFat, Cluster) + OffsetInCluster,
      ChunkBytes, Buffer) then
      Exit(StatusIoError);
    Buffer := Buffer + ChunkBytes;
    Offset := Offset + ChunkBytes;
    Length := Length - ChunkBytes;
  end;
  Result := StatusSuccess;
end;

{ --- Directory entries ----------------------------------------------- }

function ReadRawEntry(Directory: PExFatNode; Index: QWord; out Entry: TRawEntry): TFileSystemStatus;
begin
  if Directory^.HasKnownLength and ((Index + 1) * DirectoryEntrySize > Directory^.DataLength) then
    Exit(StatusEndOfDirectory);
  Result := ReadNodeBytes(Directory, Index * DirectoryEntrySize, DirectoryEntrySize, @Entry[0]);
end;

function UpdateSetChecksum(Checksum: Word; const Entry: TRawEntry; IsPrimary: Boolean): Word;
var
  Index: Integer;
begin
  for Index := 0 to DirectoryEntrySize - 1 do
  begin
    { The checksum field itself is excluded. }
    if IsPrimary and ((Index = 2) or (Index = 3)) then
      Continue;
    if (Checksum and 1) <> 0 then
      Checksum := Word($8000 + (Checksum shr 1) + Entry[Index])
    else
      Checksum := Word((Checksum shr 1) + Entry[Index]);
  end;
  Result := Checksum;
end;

{ Reads the entry set whose primary entry is at Index. Returns False if
  the set is damaged or incomplete. }
function ReadEntrySet(Directory: PExFatNode; Index: QWord; const Primary: TRawEntry;
  out Entry: TExFatEntry; out Status: TFileSystemStatus): Boolean;
var
  FileEntry: PFileEntry;
  Secondary: TRawEntry;
  Stream: PStreamEntry;
  NameEntry: PFileNameEntry;
  Checksum: Word;
  SecondaryIndex: Integer;
  CharacterIndex: Integer;
  NameCharactersLeft: Integer;
begin
  Result := False;
  Status := StatusSuccess;
  FileEntry := PFileEntry(@Primary[0]);
  if (FileEntry^.SecondaryCount < 2) or (FileEntry^.SecondaryCount > MaximumSecondaryEntries) then
    Exit;

  Checksum := UpdateSetChecksum(0, Primary, True);
  Entry.NameLength := 0;
  NameCharactersLeft := 0;

  for SecondaryIndex := 1 to FileEntry^.SecondaryCount do
  begin
    Status := ReadRawEntry(Directory, Index + QWord(SecondaryIndex), Secondary);
    if Status <> StatusSuccess then
      Exit;
    Checksum := UpdateSetChecksum(Checksum, Secondary, False);

    if SecondaryIndex = 1 then
    begin
      if Secondary[0] <> EntryTypeStreamExtension then
        Exit;
      Stream := PStreamEntry(@Secondary[0]);
      Entry.FirstCluster := Stream^.FirstCluster;
      Entry.IsContiguous := (Stream^.GeneralSecondaryFlags and StreamFlagNoFatChain) <> 0;
      Entry.DataLength := Stream^.DataLength;
      Entry.ValidDataLength := Stream^.ValidDataLength;
      NameCharactersLeft := Stream^.NameLength;
    end
    else if Secondary[0] = EntryTypeFileName then
    begin
      NameEntry := PFileNameEntry(@Secondary[0]);
      CharacterIndex := 0;
      while (CharacterIndex < CharactersPerNameEntry) and (NameCharactersLeft > 0) do
      begin
        Entry.Name[Entry.NameLength] := NameEntry^.FileName[CharacterIndex];
        Inc(Entry.NameLength);
        Dec(NameCharactersLeft);
        Inc(CharacterIndex);
      end;
    end;
  end;

  if (Checksum <> FileEntry^.SetChecksum) or (Entry.NameLength = 0) then
    Exit;

  Entry.Name[Entry.NameLength] := 0;
  Entry.Attributes := FileEntry^.FileAttributes;
  Entry.LastModifiedTimestamp := FileEntry^.LastModifiedTimestamp;
  Entry.LastModifiedUtcOffset := FileEntry^.LastModifiedUtcOffset;
  Result := True;
end;

{ Returns the next valid file entry set at or after Cursor.Position. }
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

{ --- Names ----------------------------------------------------------- }

function UpcaseUnit(ExFat: PExFatVolume; UnitValue: Word): Word;
begin
  Result := ExFat^.UpcaseTable[UnitValue];
end;

function EntryNameMatches(ExFat: PExFatVolume; const Entry: TExFatEntry; Name: PWord;
  NameLength: Integer): Boolean;
var
  Index: Integer;
begin
  if Entry.NameLength <> NameLength then
    Exit(False);
  for Index := 0 to NameLength - 1 do
  begin
    if UpcaseUnit(ExFat, Entry.Name[Index]) <> UpcaseUnit(ExFat, Name[Index]) then
      Exit(False);
  end;
  Result := True;
end;

{ --- Nodes ----------------------------------------------------------- }

function TimestampToUnixTime(Timestamp: LongWord; UtcOffset: Byte): TUnixTime;
const
  UtcOffsetValid = $80;
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

function CreateNode(Volume: PVolume; const Entry: TExFatEntry): PExFatNode;
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

  if (Entry.Attributes and AttributeDirectory) <> 0 then
    Result^.Common.Information.Kind := NodeKindDirectory
  else
    Result^.Common.Information.Kind := NodeKindFile;
  Result^.Common.Information.SizeInBytes := Entry.DataLength;
  Result^.Common.Information.NodeNumber := Entry.FirstCluster;
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.ModificationTime :=
    TimestampToUnixTime(Entry.LastModifiedTimestamp, Entry.LastModifiedUtcOffset);
  if (Entry.Attributes and AttributeReadOnly) <> 0 then
    Result^.Common.Information.Mode := $124
  else
    Result^.Common.Information.Mode := $1A4;
end;

{ --- Driver routines ------------------------------------------------- }

function ExFatLookup(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  WantedName: array[0..MaximumNameCharacters] of Word;
  WantedLength: PtrInt;
  Cursor: TDirectoryCursor;
  Entry: TExFatEntry;
  ExFat: PExFatVolume;
  Node: PExFatNode;
begin
  Found := nil;
  ExFat := ExFatVolumeOf(Directory);
  WantedLength := Utf8ToUtf16(Name, @WantedName[0], MaximumNameCharacters);
  if WantedLength < 0 then
    Exit(StatusNameTooLong);

  Cursor.Position := 0;
  Cursor.Extra := 0;
  repeat
    Result := NextEntry(PExFatNode(Directory), Cursor, Entry);
    if Result = StatusEndOfDirectory then
      Exit(StatusNotFound);
    if Result <> StatusSuccess then
      Exit;
  until EntryNameMatches(ExFat, Entry, @WantedName[0], Integer(WantedLength));

  Node := CreateNode(Directory^.Volume, Entry);
  if Node = nil then
    Exit(StatusOutOfMemory);
  Found := @Node^.Common;
end;

function ExFatReadDirectory(Directory: PNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
var
  ExFatEntry: TExFatEntry;
  Builder: TUtf8Builder;
begin
  Result := NextEntry(PExFatNode(Directory), Cursor, ExFatEntry);
  if Result <> StatusSuccess then
    Exit;
  BeginUtf8(Builder, @Entry.Name[0], MaximumNameBytes);
  AppendUtf16(Builder, @ExFatEntry.Name[0], ExFatEntry.NameLength);
  if (ExFatEntry.Attributes and AttributeDirectory) <> 0 then
    Entry.Kind := NodeKindDirectory
  else
    Entry.Kind := NodeKindFile;
  Entry.NodeNumber := ExFatEntry.FirstCluster;
end;

function ExFatReadFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  FileSize: QWord;
  ValidBytes: QWord;
  Destination: PByte;
begin
  BytesRead := 0;
  ExFatNode := PExFatNode(Node);
  FileSize := ExFatNode^.DataLength;
  if Offset >= FileSize then
    Exit(StatusSuccess);
  if ByteCount > FileSize - Offset then
    ByteCount := FileSize - Offset;
  Destination := PByte(Buffer);

  { Bytes beyond the valid data length were never written: read as zero. }
  if Offset < ExFatNode^.ValidDataLength then
  begin
    ValidBytes := ExFatNode^.ValidDataLength - Offset;
    if ValidBytes > ByteCount then
      ValidBytes := ByteCount;
    Result := ReadNodeBytes(ExFatNode, Offset, ValidBytes, Destination);
    if Result = StatusEndOfDirectory then
      Exit(StatusCorrupted);
    if Result <> StatusSuccess then
      Exit;
  end
  else
    ValidBytes := 0;

  ZeroMemory(Destination + ValidBytes, ByteCount - ValidBytes);
  BytesRead := ByteCount;
  Result := StatusSuccess;
end;

procedure ExFatReleaseNode(Node: PNode);
begin
  FreeKernelMemory(Node);
end;

{ --- Mounting -------------------------------------------------------- }

function ReadBootSector(Device: PBlockDevice; out BootSector: TBootSector): Boolean;
var
  Signature: Word;
begin
  Result := CachedRead(Device, 0, SizeOf(TBootSector), @BootSector) and
    CachedRead(Device, BootSignatureOffset, 2, @Signature) and
    (Signature = BootSignature) and
    MemoryIsEqual(@BootSector.FileSystemName[0], PChar(FileSystemNameText), 8);
end;

function ExFatProbe(Device: PBlockDevice): Boolean;
var
  BootSector: TBootSector;
begin
  Result := ReadBootSector(Device, BootSector) and
    (BootSector.BytesPerSectorShift >= 9) and (BootSector.BytesPerSectorShift <= 12) and
    (BootSector.SectorsPerClusterShift <= 25 - BootSector.BytesPerSectorShift);
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
  Result^.Common.Information.NodeNumber := ExFat^.RootCluster;
  Result^.FirstCluster := ExFat^.RootCluster;
  Result^.IsContiguous := False;
  Result^.HasKnownLength := False;
end;

{ Expands the compressed up-case table: a run of $FFFF followed by a count
  means that many characters map to themselves. }
function LoadUpcaseTable(Volume: PVolume; Root: PExFatNode; const TableEntry: TUpcaseTableEntry): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  TableNode: TExFatNode;
  Compressed: PWord;
  CompressedCount: QWord;
  SourceIndex: QWord;
  NextCharacter: LongWord;
  RunLength: LongWord;
  Character: LongWord;
begin
  ExFat := PExFatVolume(Volume^.DriverData);

  { Start with the identity mapping so a short table leaves the rest alone. }
  for Character := 0 to UpcaseTableCharacters - 1 do
    ExFat^.UpcaseTable[Character] := Word(Character);

  if (TableEntry.DataLength = 0) or (TableEntry.DataLength > 2 * UpcaseTableCharacters * 2) then
    Exit(StatusCorrupted);

  Compressed := PWord(AllocateKernelMemory(TableEntry.DataLength));
  if Compressed = nil then
    Exit(StatusOutOfMemory);

  ZeroMemory(@TableNode, SizeOf(TableNode));
  TableNode.Common.Volume := Volume;
  TableNode.FirstCluster := TableEntry.FirstCluster;
  TableNode.DataLength := TableEntry.DataLength;
  TableNode.HasKnownLength := True;
  Result := ReadNodeBytes(@TableNode, 0, TableEntry.DataLength, PByte(Compressed));
  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Compressed);
    Exit;
  end;

  CompressedCount := TableEntry.DataLength div 2;
  SourceIndex := 0;
  NextCharacter := 0;
  while (SourceIndex < CompressedCount) and (NextCharacter < UpcaseTableCharacters) do
  begin
    if (Compressed[SourceIndex] = UpcaseIdentityRunMarker) and (SourceIndex + 1 < CompressedCount) then
    begin
      RunLength := Compressed[SourceIndex + 1];
      NextCharacter := NextCharacter + RunLength;
      SourceIndex := SourceIndex + 2;
    end
    else
    begin
      ExFat^.UpcaseTable[NextCharacter] := Compressed[SourceIndex];
      Inc(NextCharacter);
      Inc(SourceIndex);
    end;
  end;

  FreeKernelMemory(Compressed);
  Result := StatusSuccess;
end;

{ Reads the volume label and up-case table entries from the root. }
function ReadRootMetadata(Volume: PVolume; Root: PExFatNode): TFileSystemStatus;
var
  Index: QWord;
  Entry: TRawEntry;
  LabelEntry: PVolumeLabelEntry;
  Builder: TUtf8Builder;
  FoundUpcaseTable: Boolean;
begin
  FoundUpcaseTable := False;
  Index := 0;
  repeat
    Result := ReadRawEntry(Root, Index, Entry);
    if Result = StatusEndOfDirectory then
      Break;
    if Result <> StatusSuccess then
      Exit;
    Inc(Index);

    case Entry[0] of
      EntryTypeEndOfDirectory:
        Break;
      EntryTypeVolumeLabel:
        begin
          LabelEntry := PVolumeLabelEntry(@Entry[0]);
          if LabelEntry^.CharacterCount <= 11 then
          begin
            BeginUtf8(Builder, @Volume^.VolumeLabel[0], VolumeLabelLength);
            AppendUtf16(Builder, @LabelEntry^.VolumeLabel[0], LabelEntry^.CharacterCount);
          end;
        end;
      EntryTypeUpcaseTable:
        begin
          Result := LoadUpcaseTable(Volume, Root, PUpcaseTableEntry(@Entry[0])^);
          if Result <> StatusSuccess then
            Exit;
          FoundUpcaseTable := True;
        end;
    end;
  until False;

  if FoundUpcaseTable then
    Result := StatusSuccess
  else
    Result := StatusCorrupted;
end;

function ExFatMount(Volume: PVolume): TFileSystemStatus;
var
  BootSector: TBootSector;
  ExFat: PExFatVolume;
  BytesPerSector: QWord;
  Root: PExFatNode;
begin
  if not ReadBootSector(Volume^.Device, BootSector) then
    Exit(StatusCorrupted);

  ExFat := PExFatVolume(AllocateZeroedKernelMemory(SizeOf(TExFatVolume)));
  if ExFat = nil then
    Exit(StatusOutOfMemory);
  ExFat^.UpcaseTable := PWord(AllocateKernelMemory(UpcaseTableCharacters * SizeOf(Word)));
  if ExFat^.UpcaseTable = nil then
  begin
    FreeKernelMemory(ExFat);
    Exit(StatusOutOfMemory);
  end;

  BytesPerSector := QWord(1) shl BootSector.BytesPerSectorShift;
  ExFat^.BytesPerCluster := BytesPerSector shl BootSector.SectorsPerClusterShift;
  ExFat^.FatOffset := QWord(BootSector.FatOffset) * BytesPerSector;
  ExFat^.ClusterHeapOffset := QWord(BootSector.ClusterHeapOffset) * BytesPerSector;
  ExFat^.ClusterCount := BootSector.ClusterCount;
  ExFat^.RootCluster := BootSector.FirstClusterOfRootDirectory;

  Volume^.DriverData := ExFat;
  Volume^.TotalBytes := BootSector.VolumeLength * BytesPerSector;
  CopyText(@Volume^.TypeName[0], 'exfat', FileSystemTypeNameLength);

  Root := CreateRootNode(Volume);
  if (Root = nil) or not IsValidCluster(ExFat, ExFat^.RootCluster) then
    Result := StatusCorrupted
  else
    Result := ReadRootMetadata(Volume, Root);

  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Root);
    FreeKernelMemory(ExFat^.UpcaseTable);
    FreeKernelMemory(ExFat);
    Volume^.DriverData := nil;
    Exit;
  end;

  Volume^.RootNode := @Root^.Common;
end;

procedure ExFatUnmount(Volume: PVolume);
begin
  FreeKernelMemory(Volume^.RootNode);
  FreeKernelMemory(PExFatVolume(Volume^.DriverData)^.UpcaseTable);
  FreeKernelMemory(Volume^.DriverData);
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
end;

function ExFatFileSystemDriver: PFileSystemDriver;
begin
  Driver.Name := 'exFAT';
  Driver.Probe := @ExFatProbe;
  Driver.Mount := @ExFatMount;
  Driver.Unmount := @ExFatUnmount;
  Driver.Lookup := @ExFatLookup;
  Driver.ReadDirectory := @ExFatReadDirectory;
  Driver.ReadFile := @ExFatReadFile;
  Driver.ReadSymbolicLink := nil;
  Driver.ReleaseNode := @ExFatReleaseNode;
  Result := @Driver;
end;

end.
