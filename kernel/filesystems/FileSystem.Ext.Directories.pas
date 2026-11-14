{
  Directories on ext2/3/4.

  A directory's data blocks hold variable length records: inode number,
  record length, name length, file type and the name. Records never cross
  a block boundary, and the record length of the last one in a block
  reaches the end of the block. Unused space is either an entry with
  inode number zero or slack at the end of a record.

  With metadata checksums each block ends in a 12-byte "tail" that looks
  like an empty entry and holds the block's checksum.

  Directories with an htree index can be read linearly (the index blocks
  look like empty entries), but are not modified: adding to one would
  require maintaining the index.
}
unit FileSystem.Ext.Directories;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume;

type
  TExtDirectoryEntry = record
    Name: TFileName;
    NameLength: LongWord;
    InodeNumber: LongWord;
    FileType: Byte;
    { Byte offset of the record within the directory. }
    Offset: QWord;
  end;

{ Returns the next live entry at or after Cursor.Position, skipping "."
  and ".." unless IncludeDots is set. }
function NextDirectoryEntry(Directory: PExtNode; var Cursor: TDirectoryCursor;
  IncludeDots: Boolean; out Entry: TExtDirectoryEntry): TFileSystemStatus;
function FindDirectoryEntry(Directory: PExtNode; Name: PChar;
  out Entry: TExtDirectoryEntry): TFileSystemStatus;
function DirectoryIsEmpty(Directory: PExtNode; out IsEmpty: Boolean): TFileSystemStatus;

function AddDirectoryEntry(Directory: PExtNode; Name: PChar; InodeNumber: LongWord;
  FileType: Byte): TFileSystemStatus;
function RemoveDirectoryEntry(Directory: PExtNode; Name: PChar): TFileSystemStatus;
{ Points the ".." entry of Directory at NewParent. }
function SetParentEntry(Directory: PExtNode; NewParent: LongWord): TFileSystemStatus;

{ Fills a new directory's first block with "." and ".." (and the
  checksum tail) and writes it. The block must already be allocated. }
function WriteInitialDirectoryBlock(Directory: PExtNode; ParentInode: LongWord): TFileSystemStatus;

function DirectoryIsModifiable(Directory: PExtNode): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  FileSystem.Ext.Blocks;

function HasFileTypes(Ext: PExtVolume): Boolean;
begin
  Result := HasIncompatibleFeature(Ext, IncompatibleFileType);
end;

function EntryNameLength(Ext: PExtVolume; const Header: TDirectoryEntryHeader): LongWord;
begin
  if HasFileTypes(Ext) then
    Result := Header.NameLength
  else
    Result := Header.NameLength or (LongWord(Header.FileType) shl 8);
end;

{ Where usable space in a block ends (before the checksum tail). }
function UsableBlockBytes(Ext: PExtVolume): LongWord;
begin
  Result := LongWord(Ext^.BlockSize);
  if Ext^.HasMetadataChecksums then
    Result := Result - DirectoryTailSize;
end;

function DirectoryIsModifiable(Directory: PExtNode): TFileSystemStatus;
begin
  if (InodeRecord(Directory)^.Flags and (InodeFlagIndexedDirectory or InodeFlagInlineData)) <> 0 then
    Result := StatusUnsupported
  else
    Result := StatusSuccess;
end;

{ --- Reading --------------------------------------------------------- }

function NextDirectoryEntry(Directory: PExtNode; var Cursor: TDirectoryCursor;
  IncludeDots: Boolean; out Entry: TExtDirectoryEntry): TFileSystemStatus;
var
  Ext: PExtVolume;
  DirectorySize: QWord;
  Header: TDirectoryEntryHeader;
  NameLength: LongWord;
  BlockRemainder: QWord;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  DirectorySize := InodeSize(InodeRecord(Directory)^);
  if (InodeRecord(Directory)^.Flags and InodeFlagInlineData) <> 0 then
    Exit(StatusUnsupported);

  repeat
    if Cursor.Position + DirectoryEntryHeaderSize > DirectorySize then
      Exit(StatusEndOfDirectory);

    Result := ReadNodeData(Directory, Cursor.Position, DirectoryEntryHeaderSize, @Header);
    if Result <> StatusSuccess then
      Exit;

    BlockRemainder := Ext^.BlockSize - (Cursor.Position mod Ext^.BlockSize);
    if (Header.RecordLength < DirectoryEntryHeaderSize) or ((Header.RecordLength mod 4) <> 0) or
       (Header.RecordLength > BlockRemainder) then
      Exit(StatusCorrupted);

    NameLength := EntryNameLength(Ext, Header);
    if (Header.InodeNumber = 0) or (NameLength = 0) or
       (NameLength + DirectoryEntryHeaderSize > Header.RecordLength) then
    begin
      Cursor.Position := Cursor.Position + Header.RecordLength;
      Continue;
    end;

    Result := ReadNodeData(Directory, Cursor.Position + DirectoryEntryHeaderSize, NameLength,
      @Entry.Name[0]);
    if Result <> StatusSuccess then
      Exit;
    Entry.Name[NameLength] := #0;
    Entry.NameLength := NameLength;
    Entry.InodeNumber := Header.InodeNumber;
    Entry.Offset := Cursor.Position;
    if HasFileTypes(Ext) then
      Entry.FileType := Header.FileType
    else
      Entry.FileType := FileTypeUnknown;
    Cursor.Position := Cursor.Position + Header.RecordLength;

    if (not IncludeDots) and (TextIsEqual(@Entry.Name[0], '.') or TextIsEqual(@Entry.Name[0], '..')) then
      Continue;
    Exit(StatusSuccess);
  until False;
end;

function FindDirectoryEntry(Directory: PExtNode; Name: PChar;
  out Entry: TExtDirectoryEntry): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
begin
  Cursor.Position := 0;
  Cursor.Extra := 0;
  repeat
    Result := NextDirectoryEntry(Directory, Cursor, True, Entry);
    if Result = StatusEndOfDirectory then
      Exit(StatusNotFound);
    if Result <> StatusSuccess then
      Exit;
  until TextIsEqual(@Entry.Name[0], Name);
end;

function DirectoryIsEmpty(Directory: PExtNode; out IsEmpty: Boolean): TFileSystemStatus;
var
  Cursor: TDirectoryCursor;
  Entry: TExtDirectoryEntry;
begin
  Cursor.Position := 0;
  Cursor.Extra := 0;
  Result := NextDirectoryEntry(Directory, Cursor, False, Entry);
  IsEmpty := Result = StatusEndOfDirectory;
  if (Result = StatusEndOfDirectory) or (Result = StatusSuccess) then
    Result := StatusSuccess;
end;

{ --- Block access ---------------------------------------------------- }

function LoadDirectoryBlock(Directory: PExtNode; LogicalBlock: LongWord; out Buffer: PByte;
  out PhysicalBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  Buffer := nil;
  Result := MapLogicalBlock(Directory, LogicalBlock, PhysicalBlock);
  if Result <> StatusSuccess then
    Exit;
  if PhysicalBlock = 0 then
    Exit(StatusCorrupted); { directories have no holes }
  Buffer := PByte(AllocateKernelMemory(Ext^.BlockSize));
  if Buffer = nil then
    Exit(StatusOutOfMemory);
  if not ExtRead(Directory^.Common.Volume, PhysicalBlock * Ext^.BlockSize, Ext^.BlockSize, Buffer) then
  begin
    FreeKernelMemory(Buffer);
    Buffer := nil;
    Exit(StatusIoError);
  end;
end;

{ Rewrites the checksum tail (when the volume has checksums) and writes
  the block. }
function StoreDirectoryBlock(Directory: PExtNode; PhysicalBlock: QWord; Buffer: PByte): TFileSystemStatus;
var
  Ext: PExtVolume;
  Tail: PDirectoryEntryHeader;
  TailOffset: QWord;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  if Ext^.HasMetadataChecksums then
  begin
    TailOffset := Ext^.BlockSize - DirectoryTailSize;
    Tail := PDirectoryEntryHeader(Buffer + TailOffset);
    Tail^.InodeNumber := 0;
    Tail^.RecordLength := DirectoryTailSize;
    Tail^.NameLength := 0;
    Tail^.FileType := DirectoryTailFileType;
    PLongWord(Buffer + TailOffset + 8)^ := NodeBlockChecksum(Directory, Buffer, TailOffset);
  end;
  if ExtWriteMetadata(Directory^.Common.Volume, PhysicalBlock * Ext^.BlockSize, Ext^.BlockSize, Buffer) then
    Result := StatusSuccess
  else
    Result := StatusIoError;
end;

procedure WriteEntryAt(Ext: PExtVolume; Buffer: PByte; Offset: LongWord; InodeNumber: LongWord;
  RecordLength: LongWord; Name: PChar; NameLength: LongWord; FileType: Byte);
var
  Header: PDirectoryEntryHeader;
begin
  Header := PDirectoryEntryHeader(Buffer + Offset);
  Header^.InodeNumber := InodeNumber;
  Header^.RecordLength := Word(RecordLength);
  Header^.NameLength := Byte(NameLength);
  if HasFileTypes(Ext) then
    Header^.FileType := FileType
  else
    Header^.FileType := Byte(NameLength shr 8);
  CopyMemory(Buffer + Offset + DirectoryEntryHeaderSize, Name, NameLength);
end;

{ Looks for room for a record of Needed bytes in a block. On success the
  entry is written into Buffer. }
function TryPlaceInBlock(Ext: PExtVolume; Buffer: PByte; Name: PChar; NameLength: LongWord;
  InodeNumber: LongWord; FileType: Byte): Boolean;
var
  Offset: LongWord;
  Usable: LongWord;
  Needed: LongWord;
  Header: PDirectoryEntryHeader;
  UsedBytes: LongWord;
begin
  Result := False;
  Usable := UsableBlockBytes(Ext);
  Needed := DirectoryRecordLength(NameLength);
  Offset := 0;
  while Offset < Usable do
  begin
    Header := PDirectoryEntryHeader(Buffer + Offset);
    if (Header^.RecordLength < DirectoryEntryHeaderSize) or (Offset + Header^.RecordLength > Usable) then
      Exit; { damaged block; leave it alone }

    if Header^.InodeNumber = 0 then
      UsedBytes := 0
    else
      UsedBytes := DirectoryRecordLength(EntryNameLength(Ext, Header^));

    if Header^.RecordLength - UsedBytes >= Needed then
    begin
      if UsedBytes = 0 then
        { Reuse the empty record as a whole. }
        WriteEntryAt(Ext, Buffer, Offset, InodeNumber, Header^.RecordLength, Name, NameLength, FileType)
      else
      begin
        { Split the slack off the end of the existing record. }
        WriteEntryAt(Ext, Buffer, Offset + UsedBytes, InodeNumber, Header^.RecordLength - UsedBytes,
          Name, NameLength, FileType);
        Header^.RecordLength := Word(UsedBytes);
      end;
      Exit(True);
    end;
    Offset := Offset + Header^.RecordLength;
  end;
end;

{ --- Writing --------------------------------------------------------- }

function AddDirectoryEntry(Directory: PExtNode; Name: PChar; InodeNumber: LongWord;
  FileType: Byte): TFileSystemStatus;
var
  Ext: PExtVolume;
  NameLength: LongWord;
  BlockCount: LongWord;
  LogicalBlock: LongWord;
  Buffer: PByte;
  PhysicalBlock: QWord;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  Result := DirectoryIsModifiable(Directory);
  if Result <> StatusSuccess then
    Exit;
  NameLength := TextLength(Name);
  if (NameLength = 0) or (NameLength > 255) then
    Exit(StatusInvalidName);

  BlockCount := LongWord(InodeSize(InodeRecord(Directory)^) div Ext^.BlockSize);
  LogicalBlock := 0;
  while LogicalBlock < BlockCount do
  begin
    Result := LoadDirectoryBlock(Directory, LogicalBlock, Buffer, PhysicalBlock);
    if Result <> StatusSuccess then
      Exit;
    if TryPlaceInBlock(Ext, Buffer, Name, NameLength, InodeNumber, FileType) then
    begin
      Result := StoreDirectoryBlock(Directory, PhysicalBlock, Buffer);
      FreeKernelMemory(Buffer);
      Exit;
    end;
    FreeKernelMemory(Buffer);
    Inc(LogicalBlock);
  end;

  { No room anywhere: add a block holding just this entry. }
  Result := AllocateBlockRange(Directory, BlockCount, 1);
  if Result <> StatusSuccess then
    Exit;
  SetInodeSize(InodeRecord(Directory)^, QWord(BlockCount + 1) * Ext^.BlockSize);
  Directory^.Common.Information.SizeInBytes := InodeSize(InodeRecord(Directory)^);

  Result := MapLogicalBlock(Directory, BlockCount, PhysicalBlock);
  if Result <> StatusSuccess then
    Exit;
  Buffer := PByte(AllocateZeroedKernelMemory(Ext^.BlockSize));
  if Buffer = nil then
    Exit(StatusOutOfMemory);
  WriteEntryAt(Ext, Buffer, 0, InodeNumber, UsableBlockBytes(Ext), Name, NameLength, FileType);
  Result := StoreDirectoryBlock(Directory, PhysicalBlock, Buffer);
  FreeKernelMemory(Buffer);
  if Result = StatusSuccess then
    Result := WriteNodeInode(Directory);
end;

function RemoveDirectoryEntry(Directory: PExtNode; Name: PChar): TFileSystemStatus;
var
  Ext: PExtVolume;
  Entry: TExtDirectoryEntry;
  Buffer: PByte;
  PhysicalBlock: QWord;
  OffsetInBlock: LongWord;
  Offset: LongWord;
  PreviousOffset: LongInt;
  Header: PDirectoryEntryHeader;
  Previous: PDirectoryEntryHeader;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  Result := DirectoryIsModifiable(Directory);
  if Result <> StatusSuccess then
    Exit;
  Result := FindDirectoryEntry(Directory, Name, Entry);
  if Result <> StatusSuccess then
    Exit;

  Result := LoadDirectoryBlock(Directory, LongWord(Entry.Offset div Ext^.BlockSize), Buffer, PhysicalBlock);
  if Result <> StatusSuccess then
    Exit;
  OffsetInBlock := LongWord(Entry.Offset mod Ext^.BlockSize);

  { Find the record in front of it in the same block. }
  PreviousOffset := -1;
  Offset := 0;
  while Offset < OffsetInBlock do
  begin
    PreviousOffset := LongInt(Offset);
    Offset := Offset + PDirectoryEntryHeader(Buffer + Offset)^.RecordLength;
  end;

  Header := PDirectoryEntryHeader(Buffer + OffsetInBlock);
  if PreviousOffset >= 0 then
  begin
    { The previous record absorbs the removed one. }
    Previous := PDirectoryEntryHeader(Buffer + PreviousOffset);
    Previous^.RecordLength := Previous^.RecordLength + Header^.RecordLength;
  end
  else
    Header^.InodeNumber := 0;

  Result := StoreDirectoryBlock(Directory, PhysicalBlock, Buffer);
  FreeKernelMemory(Buffer);
end;

function SetParentEntry(Directory: PExtNode; NewParent: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Buffer: PByte;
  PhysicalBlock: QWord;
  First: PDirectoryEntryHeader;
  Second: PDirectoryEntryHeader;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  Result := LoadDirectoryBlock(Directory, 0, Buffer, PhysicalBlock);
  if Result <> StatusSuccess then
    Exit;

  { ".." is always the second record of the first block. }
  First := PDirectoryEntryHeader(Buffer);
  Second := PDirectoryEntryHeader(Buffer + First^.RecordLength);
  if (First^.RecordLength >= Ext^.BlockSize) or (Second^.NameLength <> 2) then
    Result := StatusCorrupted
  else
  begin
    Second^.InodeNumber := NewParent;
    Result := StoreDirectoryBlock(Directory, PhysicalBlock, Buffer);
  end;
  FreeKernelMemory(Buffer);
end;

function WriteInitialDirectoryBlock(Directory: PExtNode; ParentInode: LongWord): TFileSystemStatus;
const
  DotRecordLength = 12;
var
  Ext: PExtVolume;
  Buffer: PByte;
  PhysicalBlock: QWord;
begin
  Ext := ExtVolumeOf(@Directory^.Common);
  Result := MapLogicalBlock(Directory, 0, PhysicalBlock);
  if Result <> StatusSuccess then
    Exit;
  if PhysicalBlock = 0 then
    Exit(StatusCorrupted);

  Buffer := PByte(AllocateZeroedKernelMemory(Ext^.BlockSize));
  if Buffer = nil then
    Exit(StatusOutOfMemory);
  WriteEntryAt(Ext, Buffer, 0, Directory^.InodeNumber, DotRecordLength, '.', 1, FileTypeDirectory);
  WriteEntryAt(Ext, Buffer, DotRecordLength, ParentInode, UsableBlockBytes(Ext) - DotRecordLength,
    '..', 2, FileTypeDirectory);
  Result := StoreDirectoryBlock(Directory, PhysicalBlock, Buffer);
  FreeKernelMemory(Buffer);
end;

end.
