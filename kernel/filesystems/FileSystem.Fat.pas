{
  FAT12, FAT16 and FAT32 file system driver (read-only).

  On-disk layout:

    [reserved sectors, starting with the boot sector / BPB]
    [file allocation table] x NumberOfFats
    [root directory]                         FAT12 and FAT16 only
    [data area: clusters 2, 3, 4, ...]

  The FAT variant is decided purely by the number of data clusters, as
  the specification requires. Files and directories are chains of
  clusters linked through the allocation table. Directory entries are 32
  bytes; long file names (VFAT) are stored in extra entries placed in
  front of the short 8.3 entry, 13 UTF-16 characters each.

  Lookups ignore letter case, like every FAT implementation.
}
unit FileSystem.Fat;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function FatFileSystemDriver: PFileSystemDriver;

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
  BootSignatureOffset = 510;
  BootSignature = $AA55;

  AttributeReadOnly = $01;
  AttributeHidden = $02;
  AttributeSystem = $04;
  AttributeVolumeId = $08;
  AttributeDirectory = $10;
  AttributeArchive = $20;
  AttributeLongName = $0F;
  AttributeLongNameMask = $3F;

  EntryEndOfDirectory = $00;
  EntryDeleted = $E5;
  EntryKanjiE5 = $05;

  LongNameLastEntryFlag = $40;
  LongNameOrdinalMask = $1F;
  CharactersPerLongNameEntry = 13;
  MaximumLongNameEntries = 20;

  CaseLowerBase = $08;
  CaseLowerExtension = $10;

  DirectoryEntrySize = 32;

type
  TFatVariant = (FatVariant12, FatVariant16, FatVariant32);

  TBootSector = packed record
    JumpInstruction: array[0..2] of Byte;
    OemName: array[0..7] of Char;
    BytesPerSector: Word;
    SectorsPerCluster: Byte;
    ReservedSectorCount: Word;
    NumberOfFats: Byte;
    RootEntryCount: Word;
    TotalSectors16: Word;
    MediaType: Byte;
    FatSize16: Word;
    SectorsPerTrack: Word;
    NumberOfHeads: Word;
    HiddenSectors: LongWord;
    TotalSectors32: LongWord;
    case Boolean of
      False: (
        { FAT12 and FAT16 }
        DriveNumber16: Byte;
        Reserved16: Byte;
        BootSignature16: Byte;
        VolumeId16: LongWord;
        VolumeLabel16: array[0..10] of Char;
        FileSystemType16: array[0..7] of Char);
      True: (
        { FAT32 }
        FatSize32: LongWord;
        ExtendedFlags: Word;
        FileSystemVersion: Word;
        RootCluster: LongWord;
        FileSystemInformationSector: Word;
        BackupBootSector: Word;
        Reserved32: array[0..11] of Byte;
        DriveNumber32: Byte;
        Reserved32b: Byte;
        BootSignature32: Byte;
        VolumeId32: LongWord;
        VolumeLabel32: array[0..10] of Char;
        FileSystemType32: array[0..7] of Char);
  end;
  PBootSector = ^TBootSector;

  TDirectoryRecord = packed record
    Name: array[0..10] of Byte;
    Attributes: Byte;
    CaseFlags: Byte;
    CreationTimeTenths: Byte;
    CreationTime: Word;
    CreationDate: Word;
    LastAccessDate: Word;
    FirstClusterHigh: Word;
    WriteTime: Word;
    WriteDate: Word;
    FirstClusterLow: Word;
    FileSize: LongWord;
  end;
  PDirectoryRecord = ^TDirectoryRecord;

  TLongNameRecord = packed record
    Ordinal: Byte;
    NamePart1: array[0..4] of Word;
    Attributes: Byte;
    EntryType: Byte;
    Checksum: Byte;
    NamePart2: array[0..5] of Word;
    FirstClusterLow: Word;
    NamePart3: array[0..1] of Word;
  end;
  PLongNameRecord = ^TLongNameRecord;

  PFatVolume = ^TFatVolume;
  TFatVolume = record
    Variant: TFatVariant;
    BytesPerSector: LongWord;
    SectorsPerCluster: LongWord;
    BytesPerCluster: LongWord;
    FatOffset: QWord;           { byte offset of the active FAT }
    RootDirectoryOffset: QWord; { FAT12/16 fixed root directory }
    RootEntryCount: LongWord;
    DataOffset: QWord;          { byte offset of cluster 2 }
    ClusterCount: LongWord;
    RootCluster: LongWord;      { FAT32 }
    EndOfChainMinimum: LongWord;
  end;

  PFatNode = ^TFatNode;
  TFatNode = record
    Common: TNode;
    FirstCluster: LongWord;
    IsFixedRoot: Boolean;
    { Last cluster visited, to make sequential access linear: the ordinal
      in the upper 32 bits, the cluster number in the lower 32 bits. One
      64-bit field so that threads sharing a node (the root) never see an
      ordinal paired with the wrong cluster. }
    ChainHint: QWord;
  end;

  { Collects the parts of a long name while its entries are read. }
  TLongNameAssembly = record
    Units: array[0..MaximumLongNameEntries * CharactersPerLongNameEntry] of Word;
    ExpectedOrdinal: Integer;
    Checksum: Byte;
    IsValid: Boolean;
  end;

  { One directory entry, decoded. }
  TFatEntry = record
    Name: TFileName;
    Attributes: Byte;
    FirstCluster: LongWord;
    FileSize: LongWord;
    WriteDate: Word;
    WriteTime: Word;
  end;

var
  Driver: TFileSystemDriver;

{ --- Allocation table ------------------------------------------------ }

function FatVolumeOf(Node: PNode): PFatVolume;
begin
  Result := PFatVolume(Node^.Volume^.DriverData);
end;

function ReadFatEntry(Volume: PVolume; Cluster: LongWord; out NextCluster: LongWord): Boolean;
var
  Fat: PFatVolume;
  Value16: Word;
  Value32: LongWord;
begin
  Fat := PFatVolume(Volume^.DriverData);
  NextCluster := 0;
  case Fat^.Variant of
    FatVariant12:
      begin
        Result := VolumeRead(Volume, Fat^.FatOffset + Cluster + (Cluster div 2), 2, @Value16);
        if (Cluster and 1) <> 0 then
          NextCluster := Value16 shr 4
        else
          NextCluster := Value16 and $0FFF;
      end;
    FatVariant16:
      begin
        Result := VolumeRead(Volume, Fat^.FatOffset + QWord(Cluster) * 2, 2, @Value16);
        NextCluster := Value16;
      end;
  else
    begin
      Result := VolumeRead(Volume, Fat^.FatOffset + QWord(Cluster) * 4, 4, @Value32);
      NextCluster := Value32 and $0FFFFFFF;
    end;
  end;
end;

function IsValidDataCluster(Fat: PFatVolume; Cluster: LongWord): Boolean;
begin
  Result := (Cluster >= 2) and (Cluster < Fat^.ClusterCount + 2);
end;

function ClusterOffset(Fat: PFatVolume; Cluster: LongWord): QWord;
begin
  Result := Fat^.DataOffset + QWord(Cluster - 2) * Fat^.BytesPerCluster;
end;

{ Finds the Ordinal'th cluster (counting from zero) of the chain that
  starts at Node's first cluster, using and updating the node's hint. }
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

  while CurrentOrdinal < Ordinal do
  begin
    if not IsValidDataCluster(Fat, CurrentCluster) then
      Exit(StatusCorrupted);
    if not ReadFatEntry(Node^.Common.Volume, CurrentCluster, NextCluster) then
      Exit(StatusIoError);
    if NextCluster >= Fat^.EndOfChainMinimum then
      Exit(StatusEndOfDirectory); { chain is shorter than requested }
    CurrentCluster := NextCluster;
    Inc(CurrentOrdinal);
  end;

  if not IsValidDataCluster(Fat, CurrentCluster) then
    Exit(StatusCorrupted);

  Node^.ChainHint := (QWord(CurrentOrdinal) shl 32) or CurrentCluster;
  Cluster := CurrentCluster;
  Result := StatusSuccess;
end;

{ --- Raw directory access -------------------------------------------- }

{ Reads directory record number Index. Returns StatusEndOfDirectory when
  Index is past the end of the directory's storage. }
function ReadDirectoryRecord(Directory: PFatNode; Index: QWord;
  out DirectoryRecord: TDirectoryRecord): TFileSystemStatus;
var
  Fat: PFatVolume;
  Volume: PVolume;
  ByteOffset: QWord;
  EntriesPerCluster: QWord;
  Cluster: LongWord;
begin
  Volume := Directory^.Common.Volume;
  Fat := PFatVolume(Volume^.DriverData);

  if Directory^.IsFixedRoot then
  begin
    if Index >= Fat^.RootEntryCount then
      Exit(StatusEndOfDirectory);
    ByteOffset := Fat^.RootDirectoryOffset + Index * DirectoryEntrySize;
  end
  else
  begin
    EntriesPerCluster := Fat^.BytesPerCluster div DirectoryEntrySize;
    Result := FindClusterOfChain(Directory, LongWord(Index div EntriesPerCluster), Cluster);
    if Result <> StatusSuccess then
      Exit;
    ByteOffset := ClusterOffset(Fat, Cluster) + (Index mod EntriesPerCluster) * DirectoryEntrySize;
  end;

  if not VolumeRead(Volume, ByteOffset, DirectoryEntrySize, @DirectoryRecord) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

{ --- Names ----------------------------------------------------------- }

function ShortNameChecksum(const Name: array of Byte): Byte;
var
  Index: Integer;
  Sum: Byte;
begin
  Sum := 0;
  for Index := 0 to 10 do
    Sum := Byte(((Sum and 1) shl 7) + (Sum shr 1) + Name[Index]);
  Result := Sum;
end;

procedure FormatShortName(const DirectoryRecord: TDirectoryRecord; var Name: TFileName);
var
  Builder: TUtf8Builder;
  Index: Integer;
  BaseLength: Integer;
  ExtensionLength: Integer;
  Character: Byte;
begin
  BeginUtf8(Builder, @Name[0], MaximumNameBytes);

  BaseLength := 8;
  while (BaseLength > 0) and (DirectoryRecord.Name[BaseLength - 1] = Ord(' ')) do
    Dec(BaseLength);
  ExtensionLength := 3;
  while (ExtensionLength > 0) and (DirectoryRecord.Name[8 + ExtensionLength - 1] = Ord(' ')) do
    Dec(ExtensionLength);

  for Index := 0 to BaseLength - 1 do
  begin
    Character := DirectoryRecord.Name[Index];
    if (Index = 0) and (Character = EntryKanjiE5) then
      Character := EntryDeleted;
    if ((DirectoryRecord.CaseFlags and CaseLowerBase) <> 0) and
       (Character >= Ord('A')) and (Character <= Ord('Z')) then
      Character := Character + 32;
    AppendCodePoint(Builder, Character);
  end;

  if ExtensionLength > 0 then
  begin
    AppendCodePoint(Builder, Ord('.'));
    for Index := 8 to 8 + ExtensionLength - 1 do
    begin
      Character := DirectoryRecord.Name[Index];
      if ((DirectoryRecord.CaseFlags and CaseLowerExtension) <> 0) and
         (Character >= Ord('A')) and (Character <= Ord('Z')) then
        Character := Character + 32;
      AppendCodePoint(Builder, Character);
    end;
  end;
end;

procedure ResetLongName(var Assembly: TLongNameAssembly);
begin
  Assembly.IsValid := False;
  Assembly.ExpectedOrdinal := 0;
end;

procedure AddLongNamePart(var Assembly: TLongNameAssembly; const DirectoryRecord: TDirectoryRecord);
var
  Part: PLongNameRecord;
  Ordinal: Integer;
  Position: Integer;
  Index: Integer;
begin
  Part := PLongNameRecord(@DirectoryRecord);
  Ordinal := Part^.Ordinal and LongNameOrdinalMask;

  if (Part^.Ordinal and LongNameLastEntryFlag) <> 0 then
  begin
    { The entry with the highest ordinal comes first and starts a name. }
    if (Ordinal < 1) or (Ordinal > MaximumLongNameEntries) then
    begin
      ResetLongName(Assembly);
      Exit;
    end;
    FillMemory(@Assembly.Units[0], SizeOf(Assembly.Units), 0);
    Assembly.Checksum := Part^.Checksum;
    Assembly.IsValid := True;
  end
  else if (not Assembly.IsValid) or (Ordinal <> Assembly.ExpectedOrdinal) or
          (Part^.Checksum <> Assembly.Checksum) then
  begin
    ResetLongName(Assembly);
    Exit;
  end;

  Position := (Ordinal - 1) * CharactersPerLongNameEntry;
  for Index := 0 to 4 do
    Assembly.Units[Position + Index] := Part^.NamePart1[Index];
  for Index := 0 to 5 do
    Assembly.Units[Position + 5 + Index] := Part^.NamePart2[Index];
  for Index := 0 to 1 do
    Assembly.Units[Position + 11 + Index] := Part^.NamePart3[Index];

  Assembly.ExpectedOrdinal := Ordinal - 1;
end;

{ --- Entry iteration ------------------------------------------------- }

{ Reads entries starting at Cursor.Position and returns the next real
  file or directory (skipping deleted entries, the volume label, "." and
  ".."), with its long name if it has one. }
function NextEntry(Directory: PFatNode; var Cursor: TDirectoryCursor;
  out Entry: TFatEntry): TFileSystemStatus;
var
  DirectoryRecord: TDirectoryRecord;
  LongName: TLongNameAssembly;
  Builder: TUtf8Builder;
begin
  ResetLongName(LongName);
  repeat
    Result := ReadDirectoryRecord(Directory, Cursor.Position, DirectoryRecord);
    if Result <> StatusSuccess then
      Exit;
    Inc(Cursor.Position);

    if DirectoryRecord.Name[0] = EntryEndOfDirectory then
    begin
      Dec(Cursor.Position);
      Exit(StatusEndOfDirectory);
    end;

    if DirectoryRecord.Name[0] = EntryDeleted then
    begin
      ResetLongName(LongName);
      Continue;
    end;

    if (DirectoryRecord.Attributes and AttributeLongNameMask) = AttributeLongName then
    begin
      AddLongNamePart(LongName, DirectoryRecord);
      Continue;
    end;

    if (DirectoryRecord.Attributes and AttributeVolumeId) <> 0 then
    begin
      ResetLongName(LongName);
      Continue;
    end;

    if (DirectoryRecord.Name[0] = Ord('.')) and
       ((DirectoryRecord.Name[1] = Ord(' ')) or
        ((DirectoryRecord.Name[1] = Ord('.')) and (DirectoryRecord.Name[2] = Ord(' ')))) then
    begin
      ResetLongName(LongName);
      Continue;
    end;

    if LongName.IsValid and (LongName.ExpectedOrdinal = 0) and
       (LongName.Checksum = ShortNameChecksum(DirectoryRecord.Name)) then
    begin
      BeginUtf8(Builder, @Entry.Name[0], MaximumNameBytes);
      AppendUtf16(Builder, @LongName.Units[0], Length(LongName.Units));
      { Unused name characters are padded with $FFFF after the zero. }
    end
    else
      FormatShortName(DirectoryRecord, Entry.Name);

    Entry.Attributes := DirectoryRecord.Attributes;
    Entry.FirstCluster := (LongWord(DirectoryRecord.FirstClusterHigh) shl 16) or
      DirectoryRecord.FirstClusterLow;
    Entry.FileSize := DirectoryRecord.FileSize;
    Entry.WriteDate := DirectoryRecord.WriteDate;
    Entry.WriteTime := DirectoryRecord.WriteTime;
    Exit(StatusSuccess);
  until False;
end;

{ --- Nodes ----------------------------------------------------------- }

function CreateNode(Volume: PVolume; const Entry: TFatEntry): PFatNode;
var
  Fat: PFatVolume;
begin
  Fat := PFatVolume(Volume^.DriverData);
  Result := PFatNode(AllocateZeroedKernelMemory(SizeOf(TFatNode)));
  if Result = nil then
    Exit;

  Result^.Common.Volume := Volume;
  Result^.FirstCluster := Entry.FirstCluster;
  { On FAT32 a directory entry pointing at cluster 0 means the root. }
  if ((Entry.Attributes and AttributeDirectory) <> 0) and (Entry.FirstCluster = 0) then
  begin
    if Fat^.Variant = FatVariant32 then
      Result^.FirstCluster := Fat^.RootCluster
    else
      Result^.IsFixedRoot := True;
  end;

  if (Entry.Attributes and AttributeDirectory) <> 0 then
  begin
    Result^.Common.Information.Kind := NodeKindDirectory;
    Result^.Common.Information.SizeInBytes := 0;
  end
  else
  begin
    Result^.Common.Information.Kind := NodeKindFile;
    Result^.Common.Information.SizeInBytes := Entry.FileSize;
  end;
  Result^.Common.Information.NodeNumber := Entry.FirstCluster;
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.ModificationTime := DosDateTimeToUnixTime(Entry.WriteDate, Entry.WriteTime);
  if (Entry.Attributes and AttributeReadOnly) <> 0 then
    Result^.Common.Information.Mode := $124  { r--r--r-- }
  else
    Result^.Common.Information.Mode := $1A4; { rw-r--r-- }
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
  Result^.Common.Information.Kind := NodeKindDirectory;
  Result^.Common.Information.LinkCount := 1;
  Result^.Common.Information.Mode := $1ED; { rwxr-xr-x }
  if Fat^.Variant = FatVariant32 then
    Result^.FirstCluster := Fat^.RootCluster
  else
    Result^.IsFixedRoot := True;
  Result^.Common.Information.NodeNumber := Result^.FirstCluster;
end;

{ --- Driver routines ------------------------------------------------- }

function FatLookup(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
  Entry: TFatEntry;
  Node: PFatNode;
begin
  Found := nil;
  Cursor.Position := 0;
  Cursor.Extra := 0;
  repeat
    Result := NextEntry(PFatNode(Directory), Cursor, Entry);
    if Result = StatusEndOfDirectory then
      Exit(StatusNotFound);
    if Result <> StatusSuccess then
      Exit;
  until NamesAreEqualIgnoringCase(@Entry.Name[0], Name);

  Node := CreateNode(Directory^.Volume, Entry);
  if Node = nil then
    Exit(StatusOutOfMemory);
  Found := @Node^.Common;
end;

function FatReadDirectory(Directory: PNode; var Cursor: TDirectoryCursor;
  out Entry: TDirectoryEntry): TFileSystemStatus;
var
  FatEntry: TFatEntry;
begin
  Result := NextEntry(PFatNode(Directory), Cursor, FatEntry);
  if Result <> StatusSuccess then
    Exit;
  CopyText(@Entry.Name[0], @FatEntry.Name[0], MaximumNameBytes);
  if (FatEntry.Attributes and AttributeDirectory) <> 0 then
    Entry.Kind := NodeKindDirectory
  else
    Entry.Kind := NodeKindFile;
  Entry.NodeNumber := FatEntry.FirstCluster;
end;

function FatReadFile(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
var
  FatNode: PFatNode;
  Fat: PFatVolume;
  FileSize: QWord;
  Destination: PByte;
  Cluster: LongWord;
  OffsetInCluster: QWord;
  ChunkBytes: QWord;
begin
  BytesRead := 0;
  FatNode := PFatNode(Node);
  Fat := FatVolumeOf(Node);
  FileSize := Node^.Information.SizeInBytes;
  if Offset >= FileSize then
    Exit(StatusSuccess);
  if ByteCount > FileSize - Offset then
    ByteCount := FileSize - Offset;

  Destination := PByte(Buffer);
  while ByteCount > 0 do
  begin
    Result := FindClusterOfChain(FatNode, LongWord(Offset div Fat^.BytesPerCluster), Cluster);
    if Result = StatusEndOfDirectory then
      Exit(StatusCorrupted); { chain shorter than the file size says }
    if Result <> StatusSuccess then
      Exit;

    OffsetInCluster := Offset mod Fat^.BytesPerCluster;
    ChunkBytes := Fat^.BytesPerCluster - OffsetInCluster;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;

    if not VolumeRead(Node^.Volume, ClusterOffset(Fat, Cluster) + OffsetInCluster, ChunkBytes,
      Destination) then
      Exit(StatusIoError);

    Destination := Destination + ChunkBytes;
    Offset := Offset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
    BytesRead := BytesRead + ChunkBytes;
  end;
  Result := StatusSuccess;
end;

procedure FatReleaseNode(Node: PNode);
begin
  FreeKernelMemory(Node);
end;

{ --- Mounting -------------------------------------------------------- }

function IsPowerOfTwo(Value: LongWord): Boolean;
begin
  Result := (Value <> 0) and ((Value and (Value - 1)) = 0);
end;

function ReadBootSector(Device: PBlockDevice; out BootSector: TBootSector;
  out Signature: Word): Boolean;
begin
  Result := CachedRead(Device, 0, SizeOf(TBootSector), @BootSector) and
    CachedRead(Device, BootSignatureOffset, 2, @Signature);
end;

function BootSectorLooksValid(const BootSector: TBootSector; Signature: Word): Boolean;
begin
  Result := (Signature = BootSignature) and
    ((BootSector.JumpInstruction[0] = $EB) or (BootSector.JumpInstruction[0] = $E9)) and
    (BootSector.BytesPerSector >= 512) and (BootSector.BytesPerSector <= 4096) and
    IsPowerOfTwo(BootSector.BytesPerSector) and
    IsPowerOfTwo(BootSector.SectorsPerCluster) and
    (BootSector.ReservedSectorCount > 0) and
    (BootSector.NumberOfFats > 0) and
    ((BootSector.FatSize16 <> 0) or (BootSector.FatSize32 <> 0)) and
    ((BootSector.TotalSectors16 <> 0) or (BootSector.TotalSectors32 <> 0));
end;

function FatProbe(Device: PBlockDevice): Boolean;
var
  BootSector: TBootSector;
  Signature: Word;
begin
  Result := ReadBootSector(Device, BootSector, Signature) and
    BootSectorLooksValid(BootSector, Signature);
end;

procedure CopyLabel(const Source: array of Char; var Destination: array of Char);
var
  Length: Integer;
  Index: Integer;
begin
  Length := 11;
  while (Length > 0) and (Source[Length - 1] = ' ') do
    Dec(Length);
  for Index := 0 to Length - 1 do
    Destination[Index] := Source[Index];
  Destination[Length] := #0;
  if TextIsEqual(@Destination[0], 'NO NAME') then
    Destination[0] := #0;
end;

{ The authoritative label is the volume ID entry in the root directory. }
procedure ReadLabelFromRootDirectory(Volume: PVolume; Root: PFatNode);
var
  Index: QWord;
  DirectoryRecord: TDirectoryRecord;
  RawLabel: array[0..10] of Char;
  LabelText: array[0..11] of Char;
  CharacterIndex: Integer;
begin
  Index := 0;
  while ReadDirectoryRecord(Root, Index, DirectoryRecord) = StatusSuccess do
  begin
    if DirectoryRecord.Name[0] = EntryEndOfDirectory then
      Exit;
    if (DirectoryRecord.Name[0] <> EntryDeleted) and
       ((DirectoryRecord.Attributes and AttributeLongNameMask) <> AttributeLongName) and
       ((DirectoryRecord.Attributes and AttributeVolumeId) <> 0) then
    begin
      for CharacterIndex := 0 to 10 do
        RawLabel[CharacterIndex] := Char(DirectoryRecord.Name[CharacterIndex]);
      CopyLabel(RawLabel, LabelText);
      CopyText(@Volume^.VolumeLabel[0], @LabelText[0], VolumeLabelLength);
      Exit;
    end;
    Inc(Index);
  end;
end;

function FatMount(Volume: PVolume): TFileSystemStatus;
var
  BootSector: TBootSector;
  Signature: Word;
  Fat: PFatVolume;
  FatSize: QWord;
  TotalSectors: QWord;
  RootDirectorySectors: QWord;
  DataSectors: QWord;
  FirstDataSector: QWord;
  ActiveFat: LongWord;
  LabelText: array[0..11] of Char;
  Root: PFatNode;
begin
  if not ReadBootSector(Volume^.Device, BootSector, Signature) then
    Exit(StatusIoError);
  if not BootSectorLooksValid(BootSector, Signature) then
    Exit(StatusCorrupted);

  Fat := PFatVolume(AllocateZeroedKernelMemory(SizeOf(TFatVolume)));
  if Fat = nil then
    Exit(StatusOutOfMemory);

  if BootSector.FatSize16 <> 0 then
    FatSize := BootSector.FatSize16
  else
    FatSize := BootSector.FatSize32;
  if BootSector.TotalSectors16 <> 0 then
    TotalSectors := BootSector.TotalSectors16
  else
    TotalSectors := BootSector.TotalSectors32;

  Fat^.BytesPerSector := BootSector.BytesPerSector;
  Fat^.SectorsPerCluster := BootSector.SectorsPerCluster;
  Fat^.BytesPerCluster := Fat^.BytesPerSector * Fat^.SectorsPerCluster;
  Fat^.RootEntryCount := BootSector.RootEntryCount;

  RootDirectorySectors := (QWord(BootSector.RootEntryCount) * DirectoryEntrySize +
    Fat^.BytesPerSector - 1) div Fat^.BytesPerSector;
  FirstDataSector := BootSector.ReservedSectorCount + BootSector.NumberOfFats * FatSize +
    RootDirectorySectors;
  if FirstDataSector >= TotalSectors then
  begin
    FreeKernelMemory(Fat);
    Exit(StatusCorrupted);
  end;
  DataSectors := TotalSectors - FirstDataSector;
  Fat^.ClusterCount := LongWord(DataSectors div Fat^.SectorsPerCluster);

  if Fat^.ClusterCount < 4085 then
  begin
    Fat^.Variant := FatVariant12;
    Fat^.EndOfChainMinimum := $FF8;
  end
  else if Fat^.ClusterCount < 65525 then
  begin
    Fat^.Variant := FatVariant16;
    Fat^.EndOfChainMinimum := $FFF8;
  end
  else
  begin
    Fat^.Variant := FatVariant32;
    Fat^.EndOfChainMinimum := $0FFFFFF8;
  end;

  { FAT32 may mirror all tables or use just one active table. }
  ActiveFat := 0;
  if (Fat^.Variant = FatVariant32) and ((BootSector.ExtendedFlags and $80) <> 0) then
    ActiveFat := BootSector.ExtendedFlags and $0F;
  Fat^.FatOffset := (QWord(BootSector.ReservedSectorCount) + ActiveFat * FatSize) * Fat^.BytesPerSector;
  Fat^.RootDirectoryOffset := (QWord(BootSector.ReservedSectorCount) +
    BootSector.NumberOfFats * FatSize) * Fat^.BytesPerSector;
  Fat^.DataOffset := FirstDataSector * Fat^.BytesPerSector;
  Fat^.RootCluster := BootSector.RootCluster;

  Volume^.DriverData := Fat;
  Volume^.TotalBytes := TotalSectors * Fat^.BytesPerSector;

  case Fat^.Variant of
    FatVariant12:
      begin
        CopyText(@Volume^.TypeName[0], 'fat12', FileSystemTypeNameLength);
        CopyLabel(BootSector.VolumeLabel16, LabelText);
      end;
    FatVariant16:
      begin
        CopyText(@Volume^.TypeName[0], 'fat16', FileSystemTypeNameLength);
        CopyLabel(BootSector.VolumeLabel16, LabelText);
      end;
  else
    begin
      CopyText(@Volume^.TypeName[0], 'fat32', FileSystemTypeNameLength);
      CopyLabel(BootSector.VolumeLabel32, LabelText);
      if not IsValidDataCluster(Fat, Fat^.RootCluster) then
      begin
        FreeKernelMemory(Fat);
        Volume^.DriverData := nil;
        Exit(StatusCorrupted);
      end;
    end;
  end;
  CopyText(@Volume^.VolumeLabel[0], @LabelText[0], VolumeLabelLength);

  Root := CreateRootNode(Volume);
  if Root = nil then
  begin
    FreeKernelMemory(Fat);
    Volume^.DriverData := nil;
    Exit(StatusOutOfMemory);
  end;
  Volume^.RootNode := @Root^.Common;
  ReadLabelFromRootDirectory(Volume, Root);
  Result := StatusSuccess;
end;

procedure FatUnmount(Volume: PVolume);
begin
  FreeKernelMemory(Volume^.RootNode);
  FreeKernelMemory(Volume^.DriverData);
  Volume^.RootNode := nil;
  Volume^.DriverData := nil;
end;

function FatFileSystemDriver: PFileSystemDriver;
begin
  Driver.Name := 'FAT';
  Driver.Probe := @FatProbe;
  Driver.Mount := @FatMount;
  Driver.Unmount := @FatUnmount;
  Driver.Lookup := @FatLookup;
  Driver.ReadDirectory := @FatReadDirectory;
  Driver.ReadFile := @FatReadFile;
  Driver.ReadSymbolicLink := nil;
  Driver.ReleaseNode := @FatReleaseNode;
  Result := @Driver;
end;

end.
