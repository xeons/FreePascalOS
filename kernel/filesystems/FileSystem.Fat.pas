{
  FAT12, FAT16 and FAT32 file system driver.

  The FAT variant is decided purely by the number of data clusters, as
  the specification requires. Files and directories are chains of
  clusters linked through the allocation table; directories hold 32-byte
  records, with long file names (VFAT) in extra records in front of the
  short 8.3 record.

  Lookups ignore letter case, like every FAT implementation.

  The work is split over several units:
    FileSystem.Fat.Structures   on-disk records
    FileSystem.Fat.Names        short and long names
    FileSystem.Fat.Volume       allocation table, clusters, directories
    FileSystem.Fat.Write        creating, writing, removing, renaming
    FileSystem.Fat              (this unit) probing, mounting, reading
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
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.Fat.Structures,
  FileSystem.Fat.Names,
  FileSystem.Fat.Volume,
  FileSystem.Fat.Write;

var
  Driver: TFileSystemDriver;

{ --- Reading --------------------------------------------------------- }

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

  Node := CreateNodeFromEntry(Directory^.Volume, Entry);
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
  if (FatEntry.DirectoryRecord.Attributes and AttributeDirectory) <> 0 then
    Entry.Kind := NodeKindDirectory
  else
    Entry.Kind := NodeKindFile;
  Entry.NodeNumber := FatEntry.EntryOffset;
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

{ The authoritative label is the volume ID record in the root directory. }
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
    if (DirectoryRecord.Name[0] <> EntryDeleted) and not RecordIsLongNamePart(DirectoryRecord) and
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

procedure DetermineVariant(Fat: PFatVolume);
begin
  if Fat^.ClusterCount < 4085 then
  begin
    Fat^.Variant := FatVariant12;
    Fat^.EndOfChainMinimum := $FF8;
    Fat^.EndOfChainMarker := $FFF;
  end
  else if Fat^.ClusterCount < 65525 then
  begin
    Fat^.Variant := FatVariant16;
    Fat^.EndOfChainMinimum := $FFF8;
    Fat^.EndOfChainMarker := $FFFF;
  end
  else
  begin
    Fat^.Variant := FatVariant32;
    Fat^.EndOfChainMinimum := $0FFFFFF8;
    Fat^.EndOfChainMarker := $0FFFFFFF;
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
  FirstDataSector: QWord;
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
  Fat^.BytesPerCluster := Fat^.BytesPerSector * BootSector.SectorsPerCluster;
  Fat^.RootEntryCount := BootSector.RootEntryCount;
  Fat^.NumberOfFats := BootSector.NumberOfFats;
  Fat^.FatSizeInBytes := FatSize * Fat^.BytesPerSector;
  Fat^.FirstFatOffset := QWord(BootSector.ReservedSectorCount) * Fat^.BytesPerSector;

  RootDirectorySectors := (QWord(BootSector.RootEntryCount) * DirectoryEntrySize +
    Fat^.BytesPerSector - 1) div Fat^.BytesPerSector;
  FirstDataSector := BootSector.ReservedSectorCount + BootSector.NumberOfFats * FatSize +
    RootDirectorySectors;
  if FirstDataSector >= TotalSectors then
  begin
    FreeKernelMemory(Fat);
    Exit(StatusCorrupted);
  end;
  Fat^.ClusterCount := LongWord((TotalSectors - FirstDataSector) div BootSector.SectorsPerCluster);
  DetermineVariant(Fat);

  { FAT32 may mirror all tables or use just one active table. }
  Fat^.MirrorFats := True;
  Fat^.ActiveFat := 0;
  if (Fat^.Variant = FatVariant32) and ((BootSector.ExtendedFlags and $80) <> 0) then
  begin
    Fat^.MirrorFats := False;
    Fat^.ActiveFat := BootSector.ExtendedFlags and $0F;
  end;
  Fat^.RootDirectoryOffset := Fat^.FirstFatOffset + BootSector.NumberOfFats * Fat^.FatSizeInBytes;
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
      if BootSector.FileSystemInformationSector <> 0 then
        Fat^.FileSystemInformationOffset := QWord(BootSector.FileSystemInformationSector) *
          Fat^.BytesPerSector;
      if not IsValidDataCluster(Fat, Fat^.RootCluster) then
      begin
        FreeKernelMemory(Fat);
        Volume^.DriverData := nil;
        Exit(StatusCorrupted);
      end;
    end;
  end;
  CopyText(@Volume^.VolumeLabel[0], @LabelText[0], VolumeLabelLength);

  { Allocation needs to know how much space is free. }
  if not Volume^.IsReadOnly then
  begin
    Result := CountFreeClusters(Volume);
    if Result <> StatusSuccess then
    begin
      FreeKernelMemory(Fat);
      Volume^.DriverData := nil;
      Exit;
    end;
  end;

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
  Driver.CreateNode := @FatCreateNode;
  Driver.WriteFile := @FatWriteFile;
  Driver.SetFileSize := @FatSetFileSize;
  Driver.RemoveNode := @FatRemoveNode;
  Driver.RenameNode := @FatRenameNode;
  Driver.Sync := @FatSync;
  Result := @Driver;
end;

end.
