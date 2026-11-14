{
  Partition table discovery.

  Reads the partition table of a whole disk and registers a block device
  for every partition, named after the disk ("disk0p1", "disk0p2", ...).
  Two formats are understood:

    GPT  The GUID partition table. Recognized by the protective MBR entry
         (type 0xEE) and the "EFI PART" header in block 1. The header and
         entry array checksums are verified.
    MBR  The classic table in block 0 with four primary entries, plus
         logical partitions inside an extended partition (numbered from 5).
}
unit Io.Partitions;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.BlockDevice;

{ Returns the number of partitions found on Disk. }
function ScanPartitions(Disk: PBlockDevice): Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Checksums,
  Memory.KernelHeap,
  Debug.Output;

const
  MbrSignatureOffset = 510;
  MbrSignature = $AA55;
  MbrPartitionTableOffset = $1BE;
  MbrPrimaryEntryCount = 4;

  MbrTypeEmpty = $00;
  MbrTypeExtendedChs = $05;
  MbrTypeExtendedLba = $0F;
  MbrTypeExtendedLinux = $85;
  MbrTypeGptProtective = $EE;

  FirstLogicalPartitionNumber = 5;
  MaximumLogicalPartitions = 64;

  GptHeaderSignature = QWord($5452415020494645); { 'EFI PART' }
  MaximumGptEntries = 256;

type
  TMbrEntry = packed record
    Status: Byte;
    FirstChs: array[0..2] of Byte;
    PartitionType: Byte;
    LastChs: array[0..2] of Byte;
    FirstLba: LongWord;
    SectorCount: LongWord;
  end;
  PMbrEntry = ^TMbrEntry;

  TGptHeader = packed record
    Signature: QWord;
    Revision: LongWord;
    HeaderSize: LongWord;
    HeaderChecksum: LongWord;
    Reserved: LongWord;
    CurrentLba: QWord;
    BackupLba: QWord;
    FirstUsableLba: QWord;
    LastUsableLba: QWord;
    DiskGuid: array[0..15] of Byte;
    EntryArrayLba: QWord;
    EntryCount: LongWord;
    EntrySize: LongWord;
    EntryArrayChecksum: LongWord;
  end;
  PGptHeader = ^TGptHeader;

  TGptEntry = packed record
    TypeGuid: array[0..15] of Byte;
    UniqueGuid: array[0..15] of Byte;
    FirstLba: QWord;
    LastLba: QWord;
    Attributes: QWord;
    Name: array[0..35] of Word;
  end;
  PGptEntry = ^TGptEntry;

function ReadBlockIntoBuffer(Disk: PBlockDevice; Block: QWord; Buffer: Pointer): Boolean;
begin
  Result := ReadBlocks(Disk, Block, 1, Buffer);
end;

function MbrEntryAt(Sector: PByte; Index: Integer): PMbrEntry;
begin
  Result := PMbrEntry(Sector + MbrPartitionTableOffset + Index * SizeOf(TMbrEntry));
end;

function IsExtendedType(PartitionType: Byte): Boolean;
begin
  Result := (PartitionType = MbrTypeExtendedChs) or (PartitionType = MbrTypeExtendedLba) or
    (PartitionType = MbrTypeExtendedLinux);
end;

function GuidIsZero(const Guid: array of Byte): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Guid) do
  begin
    if Guid[Index] <> 0 then
      Exit(False);
  end;
  Result := True;
end;

function AddPartition(Disk: PBlockDevice; Number: LongWord; FirstBlock, BlockCount: QWord): Boolean;
var
  Partition: PBlockDevice;
begin
  Result := False;
  if (BlockCount = 0) or (FirstBlock >= Disk^.BlockCount) or
     (BlockCount > Disk^.BlockCount - FirstBlock) then
    Exit;
  Partition := CreatePartitionDevice(Disk, Number, FirstBlock, BlockCount);
  if Partition = nil then
    Exit;
  WriteBlockDeviceDescription(Partition);
  Result := True;
end;

{ --- GPT ------------------------------------------------------------- }

function HeaderChecksumIsValid(Header: PGptHeader): Boolean;
var
  StoredChecksum: LongWord;
  ComputedChecksum: LongWord;
begin
  if (Header^.HeaderSize < SizeOf(TGptHeader)) or (Header^.HeaderSize > 512) then
    Exit(False);
  StoredChecksum := Header^.HeaderChecksum;
  Header^.HeaderChecksum := 0;
  ComputedChecksum := Crc32(Header, Header^.HeaderSize);
  Header^.HeaderChecksum := StoredChecksum;
  Result := ComputedChecksum = StoredChecksum;
end;

function ScanGpt(Disk: PBlockDevice; Buffer: PByte): Integer;
var
  Header: TGptHeader;
  EntryArrayBytes: QWord;
  EntryArrayBlocks: QWord;
  EntryArray: PByte;
  EntryIndex: LongWord;
  Entry: PGptEntry;
begin
  Result := 0;
  if not ReadBlockIntoBuffer(Disk, 1, Buffer) then
    Exit;
  if PGptHeader(Buffer)^.Signature <> GptHeaderSignature then
    Exit;
  if not HeaderChecksumIsValid(PGptHeader(Buffer)) then
  begin
    DebugWriteTag('partitions');
    DebugWriteLine('GPT header checksum mismatch, ignoring the table');
    Exit;
  end;
  Header := PGptHeader(Buffer)^;

  if (Header.EntrySize < SizeOf(TGptEntry)) or (Header.EntryCount > MaximumGptEntries) then
    Exit;

  EntryArrayBytes := QWord(Header.EntryCount) * Header.EntrySize;
  EntryArrayBlocks := (EntryArrayBytes + Disk^.BlockSize - 1) div Disk^.BlockSize;
  EntryArray := PByte(AllocateKernelMemory(EntryArrayBlocks * Disk^.BlockSize));
  if EntryArray = nil then
    Exit;

  if ReadBlocks(Disk, Header.EntryArrayLba, LongWord(EntryArrayBlocks), EntryArray) and
     (Crc32(EntryArray, EntryArrayBytes) = Header.EntryArrayChecksum) then
  begin
    EntryIndex := 0;
    while EntryIndex < Header.EntryCount do
    begin
      Entry := PGptEntry(EntryArray + QWord(EntryIndex) * Header.EntrySize);
      Inc(EntryIndex);
      if GuidIsZero(Entry^.TypeGuid) or (Entry^.LastLba < Entry^.FirstLba) then
        Continue;
      if AddPartition(Disk, EntryIndex, Entry^.FirstLba, Entry^.LastLba - Entry^.FirstLba + 1) then
        Inc(Result);
    end;
  end
  else
  begin
    DebugWriteTag('partitions');
    DebugWriteLine('GPT entry array could not be read or has a bad checksum');
  end;

  FreeKernelMemory(EntryArray);
end;

{ --- MBR ------------------------------------------------------------- }

{ Walks the chain of extended boot records. Each one describes a single
  logical partition (relative to itself) and links to the next record
  (relative to the start of the extended partition). }
function ScanLogicalPartitions(Disk: PBlockDevice; ExtendedStart: QWord; Buffer: PByte): Integer;
var
  RecordBlock: QWord;
  Logical: PMbrEntry;
  NextLink: PMbrEntry;
  Number: LongWord;
  RecordsVisited: Integer;
begin
  Result := 0;
  RecordBlock := ExtendedStart;
  Number := FirstLogicalPartitionNumber;

  for RecordsVisited := 1 to MaximumLogicalPartitions do
  begin
    if not ReadBlockIntoBuffer(Disk, RecordBlock, Buffer) then
      Exit;
    if PWord(Buffer + MbrSignatureOffset)^ <> MbrSignature then
      Exit;

    Logical := MbrEntryAt(Buffer, 0);
    NextLink := MbrEntryAt(Buffer, 1);

    if (Logical^.PartitionType <> MbrTypeEmpty) and (Logical^.SectorCount <> 0) then
    begin
      if AddPartition(Disk, Number, RecordBlock + Logical^.FirstLba, Logical^.SectorCount) then
        Inc(Result);
      Inc(Number);
    end;

    if (NextLink^.PartitionType = MbrTypeEmpty) or (NextLink^.FirstLba = 0) then
      Exit;
    RecordBlock := ExtendedStart + NextLink^.FirstLba;
  end;
end;

function ScanMbr(Disk: PBlockDevice; Buffer: PByte): Integer;
var
  EntryIndex: Integer;
  Entries: array[0..MbrPrimaryEntryCount - 1] of TMbrEntry;
begin
  Result := 0;
  for EntryIndex := 0 to MbrPrimaryEntryCount - 1 do
    Entries[EntryIndex] := MbrEntryAt(Buffer, EntryIndex)^;

  for EntryIndex := 0 to MbrPrimaryEntryCount - 1 do
  begin
    if (Entries[EntryIndex].PartitionType = MbrTypeEmpty) or (Entries[EntryIndex].SectorCount = 0) then
      Continue;

    if IsExtendedType(Entries[EntryIndex].PartitionType) then
      Result := Result + ScanLogicalPartitions(Disk, Entries[EntryIndex].FirstLba, Buffer)
    else if AddPartition(Disk, EntryIndex + 1, Entries[EntryIndex].FirstLba,
      Entries[EntryIndex].SectorCount) then
      Inc(Result);
  end;
end;

function HasProtectiveMbr(Sector: PByte): Boolean;
var
  EntryIndex: Integer;
begin
  for EntryIndex := 0 to MbrPrimaryEntryCount - 1 do
  begin
    if MbrEntryAt(Sector, EntryIndex)^.PartitionType = MbrTypeGptProtective then
      Exit(True);
  end;
  Result := False;
end;

function ScanPartitions(Disk: PBlockDevice): Integer;
var
  Buffer: PByte;
begin
  Result := 0;
  if (Disk^.BlockSize < 512) or BlockDeviceIsPartition(Disk) then
    Exit;

  Buffer := PByte(AllocateKernelMemory(Disk^.BlockSize));
  if Buffer = nil then
    Exit;

  if ReadBlockIntoBuffer(Disk, 0, Buffer) and (PWord(Buffer + MbrSignatureOffset)^ = MbrSignature) then
  begin
    if HasProtectiveMbr(Buffer) then
      Result := ScanGpt(Disk, Buffer)
    else
      Result := ScanMbr(Disk, Buffer);
  end;

  FreeKernelMemory(Buffer);
end;

end.
