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
  On-disk structures of exFAT.

  All fields are little endian. Directory entries are 32 bytes; a file is
  described by an entry set: a file entry, a stream extension entry and
  one or more file name entries, protected by a checksum.
}
unit FileSystem.ExFat.Structures;

{$mode objfpc}

interface

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

  AttributeReadOnly = $01;
  AttributeDirectory = $10;
  AttributeArchive = $20;

  StreamFlagAllocationPossible = $01;
  StreamFlagNoFatChain = $02;

  VolumeFlagDirty = $0002;

  CharactersPerNameEntry = 15;
  MaximumNameCharacters = 255;
  MaximumSecondaryEntries = 18;
  MaximumEntrySetSize = MaximumSecondaryEntries + 1;

  DirectoryEntrySize = 32;
  EndOfChain = LongWord($FFFFFFFF);
  EndOfChainMinimum = LongWord($FFFFFFF8);

  UtcOffsetValid = $80;

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
  PRawEntry = ^TRawEntry;

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

  { The allocation bitmap and up-case table entries share this layout. }
  TSystemFileEntry = packed record
    EntryType: Byte;
    Flags: Byte;
    Reserved1: array[0..1] of Byte;
    TableChecksum: LongWord;
    Reserved2: array[0..11] of Byte;
    FirstCluster: LongWord;
    DataLength: QWord;
  end;
  PSystemFileEntry = ^TSystemFileEntry;

  TEntrySet = array[0..MaximumEntrySetSize - 1] of TRawEntry;

implementation

end.
