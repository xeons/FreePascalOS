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
  On-disk structures of the FAT file system family.

  FAT12, FAT16 and FAT32 share these records. All multi-byte fields are
  little endian, matching the processor, so the records are read and
  written directly.
}
unit FileSystem.Fat.Structures;

{$mode objfpc}

interface

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
  { A real first name byte of $E5 is stored as $05. }
  EntryKanjiE5 = $05;

  LongNameLastEntryFlag = $40;
  LongNameOrdinalMask = $1F;
  CharactersPerLongNameEntry = 13;
  MaximumLongNameEntries = 20;
  MaximumLongNameCharacters = 255;

  { Bits of TDirectoryRecord.CaseFlags (a Windows NT extension). }
  CaseLowerBase = $08;
  CaseLowerExtension = $10;

  DirectoryEntrySize = 32;
  ShortNameLength = 11;

  FileSystemInformationLeadSignature = LongWord($41615252);
  FileSystemInformationStructSignature = LongWord($61417272);
  FileSystemInformationTrailSignature = LongWord($AA550000);
  FileSystemInformationUnknown = LongWord($FFFFFFFF);

  MaximumFatFileSize = QWord($FFFFFFFF);

type
  TFatVariant = (FatVariant12, FatVariant16, FatVariant32);

  TShortName = array[0..ShortNameLength - 1] of Byte;

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

  TDirectoryRecord = packed record
    Name: TShortName;
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

  { The FAT32 FSInfo sector, which caches the free cluster count. }
  TFileSystemInformationSector = packed record
    LeadSignature: LongWord;
    Reserved1: array[0..479] of Byte;
    StructSignature: LongWord;
    FreeCount: LongWord;
    NextFree: LongWord;
    Reserved2: array[0..11] of Byte;
    TrailSignature: LongWord;
  end;

function RecordFirstCluster(const DirectoryRecord: TDirectoryRecord): LongWord;
procedure SetRecordFirstCluster(var DirectoryRecord: TDirectoryRecord; Cluster: LongWord);
function RecordIsLongNamePart(const DirectoryRecord: TDirectoryRecord): Boolean;

implementation

function RecordFirstCluster(const DirectoryRecord: TDirectoryRecord): LongWord;
begin
  Result := (LongWord(DirectoryRecord.FirstClusterHigh) shl 16) or DirectoryRecord.FirstClusterLow;
end;

procedure SetRecordFirstCluster(var DirectoryRecord: TDirectoryRecord; Cluster: LongWord);
begin
  DirectoryRecord.FirstClusterHigh := Word(Cluster shr 16);
  DirectoryRecord.FirstClusterLow := Word(Cluster and $FFFF);
end;

function RecordIsLongNamePart(const DirectoryRecord: TDirectoryRecord): Boolean;
begin
  Result := (DirectoryRecord.Attributes and AttributeLongNameMask) = AttributeLongName;
end;

end.
