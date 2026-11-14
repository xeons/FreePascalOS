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
  exFAT file system driver.

  A file is described by a directory entry set (file entry, stream
  extension, file name entries). A file whose stream has the "no FAT
  chain" flag occupies consecutive clusters and the allocation table is
  not consulted for it; otherwise its clusters are linked through the FAT.

  Lookups compare names through the volume's own up-case table, which is
  what exFAT prescribes for case-insensitive matching.

  The work is split over several units:
    FileSystem.ExFat.Structures   on-disk records
    FileSystem.ExFat.Volume       clusters, bitmap, entry sets, nodes
    FileSystem.ExFat.Write        creating, writing, removing, renaming
    FileSystem.ExFat.Attributes   read-only flag, times, free space
    FileSystem.ExFat              (this unit) probing, mounting, reading
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
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.ExFat.Structures,
  FileSystem.ExFat.Volume,
  FileSystem.ExFat.Write,
  FileSystem.ExFat.Attributes;

var
  Driver: TFileSystemDriver;

{ --- Reading --------------------------------------------------------- }

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

  Node := CreateNodeFromEntry(Directory^.Volume, Entry);
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
  Entry.NodeNumber := ExFatEntry.SetEntryOffsets[0];
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

{ A node for one of the system files (bitmap, up-case table) described by
  an entry in the root directory. These are linked through the FAT. }
function CreateSystemFileNode(Volume: PVolume; const Entry: TSystemFileEntry): PExFatNode;
begin
  Result := PExFatNode(AllocateZeroedKernelMemory(SizeOf(TExFatNode)));
  if Result = nil then
    Exit;
  Result^.Common.Volume := Volume;
  Result^.FirstCluster := Entry.FirstCluster;
  Result^.DataLength := Entry.DataLength;
  Result^.ValidDataLength := Entry.DataLength;
  Result^.HasKnownLength := True;
  Result^.IsContiguous := False;
end;

{ Expands the compressed up-case table: a run of $FFFF followed by a count
  means that many characters map to themselves. }
function LoadUpcaseTable(Volume: PVolume; const TableEntry: TSystemFileEntry): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  TableNode: PExFatNode;
  Compressed: PWord;
  CompressedCount: QWord;
  SourceIndex: QWord;
  NextCharacter: LongWord;
  Character: LongWord;
begin
  ExFat := PExFatVolume(Volume^.DriverData);

  { Start with the identity mapping so a short table leaves the rest alone. }
  for Character := 0 to UpcaseTableCharacters - 1 do
    ExFat^.UpcaseTable[Character] := Word(Character);

  if (TableEntry.DataLength = 0) or (TableEntry.DataLength > 2 * UpcaseTableCharacters * 2) then
    Exit(StatusCorrupted);

  TableNode := CreateSystemFileNode(Volume, TableEntry);
  Compressed := PWord(AllocateKernelMemory(TableEntry.DataLength));
  if (TableNode = nil) or (Compressed = nil) then
  begin
    FreeKernelMemory(TableNode);
    FreeKernelMemory(Compressed);
    Exit(StatusOutOfMemory);
  end;

  Result := ReadNodeBytes(TableNode, 0, TableEntry.DataLength, PByte(Compressed));
  if Result = StatusSuccess then
  begin
    CompressedCount := TableEntry.DataLength div 2;
    SourceIndex := 0;
    NextCharacter := 0;
    while (SourceIndex < CompressedCount) and (NextCharacter < UpcaseTableCharacters) do
    begin
      if (Compressed[SourceIndex] = UpcaseIdentityRunMarker) and (SourceIndex + 1 < CompressedCount) then
      begin
        NextCharacter := NextCharacter + Compressed[SourceIndex + 1];
        SourceIndex := SourceIndex + 2;
      end
      else
      begin
        ExFat^.UpcaseTable[NextCharacter] := Compressed[SourceIndex];
        Inc(NextCharacter);
        Inc(SourceIndex);
      end;
    end;
  end;

  FreeKernelMemory(Compressed);
  FreeKernelMemory(TableNode);
end;

{ Reads the volume label, up-case table and allocation bitmap entries
  from the root directory. }
function ReadRootMetadata(Volume: PVolume; Root: PExFatNode): TFileSystemStatus;
var
  ExFat: PExFatVolume;
  Index: QWord;
  Entry: TRawEntry;
  LabelEntry: PVolumeLabelEntry;
  Builder: TUtf8Builder;
  FoundUpcaseTable: Boolean;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
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
          Result := LoadUpcaseTable(Volume, PSystemFileEntry(@Entry[0])^);
          if Result <> StatusSuccess then
            Exit;
          FoundUpcaseTable := True;
        end;
      EntryTypeAllocationBitmap:
        begin
          { The second bitmap of a TexFAT volume (flags bit 0) is ignored. }
          if (ExFat^.Bitmap = nil) and ((PSystemFileEntry(@Entry[0])^.Flags and 1) = 0) then
            ExFat^.Bitmap := CreateSystemFileNode(Volume, PSystemFileEntry(@Entry[0])^);
        end;
    end;
  until False;

  if FoundUpcaseTable and (ExFat^.Bitmap <> nil) then
    Result := StatusSuccess
  else
    Result := StatusCorrupted;
end;

procedure ReleaseVolumeData(Volume: PVolume);
var
  ExFat: PExFatVolume;
begin
  ExFat := PExFatVolume(Volume^.DriverData);
  if ExFat = nil then
    Exit;
  FreeKernelMemory(ExFat^.Bitmap);
  FreeKernelMemory(ExFat^.UpcaseTable);
  FreeKernelMemory(ExFat);
  Volume^.DriverData := nil;
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
  Volume^.DriverData := ExFat;
  ExFat^.UpcaseTable := PWord(AllocateKernelMemory(UpcaseTableCharacters * SizeOf(Word)));
  if ExFat^.UpcaseTable = nil then
  begin
    ReleaseVolumeData(Volume);
    Exit(StatusOutOfMemory);
  end;

  BytesPerSector := QWord(1) shl BootSector.BytesPerSectorShift;
  ExFat^.BytesPerCluster := BytesPerSector shl BootSector.SectorsPerClusterShift;
  ExFat^.FatOffset := QWord(BootSector.FatOffset) * BytesPerSector;
  ExFat^.ClusterHeapOffset := QWord(BootSector.ClusterHeapOffset) * BytesPerSector;
  ExFat^.ClusterCount := BootSector.ClusterCount;
  ExFat^.RootCluster := BootSector.FirstClusterOfRootDirectory;

  Volume^.TotalBytes := BootSector.VolumeLength * BytesPerSector;
  CopyText(@Volume^.TypeName[0], 'exfat', FileSystemTypeNameLength);

  { A volume left dirty may be inconsistent; do not make it worse. }
  if (BootSector.VolumeFlags and VolumeFlagDirty) <> 0 then
    Volume^.IsReadOnly := True;

  Root := CreateRootNode(Volume);
  if (Root = nil) or not IsValidCluster(ExFat, ExFat^.RootCluster) then
    Result := StatusCorrupted
  else
    Result := ReadRootMetadata(Volume, Root);

  if (Result = StatusSuccess) and not Volume^.IsReadOnly then
    Result := CountFreeClusters(Volume);

  if Result <> StatusSuccess then
  begin
    FreeKernelMemory(Root);
    ReleaseVolumeData(Volume);
    Exit;
  end;

  Volume^.RootNode := @Root^.Common;
end;

procedure ExFatUnmount(Volume: PVolume);
begin
  FreeKernelMemory(Volume^.RootNode);
  Volume^.RootNode := nil;
  ReleaseVolumeData(Volume);
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
  Driver.CreateNode := @ExFatCreateNode;
  Driver.WriteFile := @ExFatWriteFile;
  Driver.SetFileSize := @ExFatSetFileSize;
  Driver.RemoveNode := @ExFatRemoveNode;
  Driver.RenameNode := @ExFatRenameNode;
  Driver.Sync := @ExFatSync;
  Driver.SetAttributes := @ExFatSetAttributes;
  Driver.GetFreeSpace := @ExFatGetFreeSpace;
  Result := @Driver;
end;

end.
