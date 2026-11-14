{
  Journaled transactions for ext3 and ext4.

  Every change the driver makes to a journaled volume - one driver call,
  such as creating a file - is a transaction. Metadata (inodes, bitmaps,
  group descriptors, the superblock, directory, extent and block pointer
  blocks) is not written in place while the call runs: each block it
  changes is copied into the transaction, which reads see in place of
  the disk. When the call ends the transaction is committed:

    1. its blocks are written to the log, after a descriptor block naming
       where each belongs, followed by a revoke block if needed;
    2. the disk is flushed, the commit block written, and flushed again:
       from now on the change survives a crash, as recovery replays it;
    3. the blocks are written in place ("checkpointed").

  File data is not journaled ("ordered" mode): it is written in place
  right away, so it is on the disk before the commit that makes it part
  of a file. A data write to a block the transaction also holds (freed
  metadata used again for data) goes into its copy too, so the
  checkpoint does not undo it.

  Transactions follow one another in the log, and the log is reset to
  its start when the next one does not fit (all earlier ones are already
  checkpointed). Recovery would replay every transaction since the
  reset, so a metadata block freed and then used for file data must not
  get its old contents back: freeing a block that is in the log adds a
  revoke record to the transaction, and recovery skips older copies of
  revoked blocks.

  While the log holds anything, the file system is marked as needing
  recovery and the journal superblock names the log's start; marking it
  clean (when the volume is synced or unmounted) undoes both. A call
  that changes more blocks than a transaction may hold commits part way
  and goes on in a new transaction.

  Volumes without a journal (ext2) have no TExtJournal: their writes go
  straight to the disk, as before.
}
unit FileSystem.Ext.Transactions;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.JournalFormat;

type
  { Consecutive journal file blocks that are consecutive on the disk. }
  PJournalRun = ^TJournalRun;
  TJournalRun = record
    LogicalStart: QWord;
    PhysicalStart: QWord;
    Count: QWord;
  end;

  PLoggedBlock = ^TLoggedBlock;
  TLoggedBlock = record
    Block: QWord;
    Data: PByte;
  end;

  PExtJournal = ^TExtJournal;
  TExtJournal = record
    Volume: PVolume;
    Format: TJournalFormat;
    { Where the journal file's blocks are. }
    Runs: PJournalRun;
    RunCount: LongWord;
    { Journal blocks in all, and the first block of the log. }
    TotalBlocks: QWord;
    FirstLogBlock: QWord;
    { The log is used up to (not including) this block. }
    LogEnd: QWord;
    { The journal superblock as last written. }
    Superblock: array[0..JournalSuperblockSize - 1] of Byte;
    { The ext volume's metadata checksums, for its superblock. }
    VolumeHasMetadataChecksums: Boolean;
    { Sequence number of the next transaction, and of the first one in
      the log (the superblock's). }
    Sequence: LongWord;
    LogStartSequence: LongWord;
    { Next free log block. }
    Head: QWord;
    { The file system is marked as needing recovery. }
    IsDirty: Boolean;

    { The running transaction. }
    Depth: LongInt;
    Blocks: PLoggedBlock;
    BlockCount: LongWord;
    MaximumBlocks: LongWord;
    LastFound: LongWord;
    Revoked: PQWord;
    RevokedCount: LongWord;
    MaximumRevoked: LongWord;

    { File system blocks in the log since its start (a hash set holding
      block + 1, 0 for free slots). }
    LoggedSet: PQWord;
    LoggedSetCapacity: LongWord;

    { Writing the log failed: nothing more is written. }
    Failed: Boolean;
    { For tests: the next commit stops before its checkpoint, as if the
      machine crashed there; nothing is written afterwards. }
    StopBeforeCheckpoint: Boolean;
    Halted: Boolean;
  end;

{ Prepares Journal (its format, runs, geometry, Superblock and Sequence
  filled in by the caller) for transactions; False if memory is short. }
function StartJournal(Journal: PExtJournal): Boolean;
procedure FreeJournal(Journal: PExtJournal);

{ The disk position of journal block LogicalBlock, 0 if outside. }
function JournalBlockAddress(Journal: PExtJournal; LogicalBlock: QWord): QWord;
{ Writes the journal superblock (Journal^.Superblock) to the disk. }
function WriteJournalSuperblock(Journal: PExtJournal): Boolean;

procedure BeginTransaction(Journal: PExtJournal);
{ Ends a transaction begun with BeginTransaction, committing it when the
  outermost one ends. }
function EndTransaction(Journal: PExtJournal): TFileSystemStatus;
{ Empties the log and clears the needs-recovery mark. }
function MarkJournalClean(Journal: PExtJournal): TFileSystemStatus;

{ Reads through the running transaction. Journal may be nil. }
function JournalRead(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
{ Writes metadata (Buffer nil: zeros) into the running transaction, or
  in place without one. }
function JournalWriteMetadata(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
{ Writes file data (Buffer nil: zeros) in place, or into the running
  transaction for blocks it holds. }
function JournalWriteData(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
{ Block was freed: its older copies in the log must not be replayed. }
procedure JournalNoteFreedBlock(Journal: PExtJournal; Block: QWord);

{ Sets or clears the needs-recovery feature in the ext superblock. }
function SetNeedsRecovery(Volume: PVolume; NeedsRecovery, HasMetadataChecksums: Boolean): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Checksums,
  Memory.KernelHeap,
  Io.BlockDevice,
  Kernel.Clock,
  FileSystem.Ext.Structures;

const
  { The log space used (journals can be much larger; the rest stays
    unused, which only means resetting the log more often). }
  MaximumUsedLogBlocks = 8192;
  MaximumTransactionBlocks = 2048;
  MinimumTransactionBlocks = 16;
  SuperblockFeatureIncompatibleOffset = $60;

{ --- The journal file -------------------------------------------------- }

function JournalBlockAddress(Journal: PExtJournal; LogicalBlock: QWord): QWord;
var
  Index: LongWord;
  Run: PJournalRun;
begin
  for Index := 1 to Journal^.RunCount do
  begin
    Run := @Journal^.Runs[Index - 1];
    if (LogicalBlock >= Run^.LogicalStart) and (LogicalBlock < Run^.LogicalStart + Run^.Count) then
      Exit((Run^.PhysicalStart + LogicalBlock - Run^.LogicalStart) * Journal^.Format.BlockSize);
  end;
  Result := 0;
end;

function WriteLogBlock(Journal: PExtJournal; LogicalBlock: QWord; Data: PByte): Boolean;
var
  Address: QWord;
begin
  Address := JournalBlockAddress(Journal, LogicalBlock);
  Result := (Address <> 0) and VolumeWrite(Journal^.Volume, Address, Journal^.Format.BlockSize, Data);
end;

function WriteJournalSuperblock(Journal: PExtJournal): Boolean;
var
  Address: QWord;
begin
  SetJournalSuperblockChecksum(Journal^.Format, @Journal^.Superblock[0]);
  Address := JournalBlockAddress(Journal, 0);
  Result := (Address <> 0) and
    VolumeWrite(Journal^.Volume, Address, JournalSuperblockSize, @Journal^.Superblock[0]);
end;

function FlushVolume(Volume: PVolume): Boolean;
begin
  Result := FlushBlockDevice(Volume^.Device);
end;

{ --- Logged block set -------------------------------------------------- }

function LoggedSetSlot(Journal: PExtJournal; Block: QWord): LongWord;
begin
  Result := LongWord((Block * QWord($9E3779B97F4A7C15)) shr 40) and (Journal^.LoggedSetCapacity - 1);
end;

function IsInLog(Journal: PExtJournal; Block: QWord): Boolean;
var
  Slot: LongWord;
begin
  Slot := LoggedSetSlot(Journal, Block);
  while Journal^.LoggedSet[Slot] <> 0 do
  begin
    if Journal^.LoggedSet[Slot] = Block + 1 then
      Exit(True);
    Slot := (Slot + 1) and (Journal^.LoggedSetCapacity - 1);
  end;
  Result := False;
end;

procedure AddToLoggedSet(Journal: PExtJournal; Block: QWord);
var
  Slot: LongWord;
begin
  Slot := LoggedSetSlot(Journal, Block);
  while Journal^.LoggedSet[Slot] <> 0 do
  begin
    if Journal^.LoggedSet[Slot] = Block + 1 then
      Exit;
    Slot := (Slot + 1) and (Journal^.LoggedSetCapacity - 1);
  end;
  Journal^.LoggedSet[Slot] := Block + 1;
end;

procedure ClearLoggedSet(Journal: PExtJournal);
begin
  FillMemory(Journal^.LoggedSet, Journal^.LoggedSetCapacity * SizeOf(QWord), 0);
end;

{ --- Setting up ------------------------------------------------------- }

function StartJournal(Journal: PExtJournal): Boolean;
var
  LogBlocks: QWord;
begin
  LogBlocks := Journal^.TotalBlocks - Journal^.FirstLogBlock;
  if LogBlocks > MaximumUsedLogBlocks then
    LogBlocks := MaximumUsedLogBlocks;
  Journal^.LogEnd := Journal^.FirstLogBlock + LogBlocks;
  Journal^.Head := Journal^.FirstLogBlock;
  Journal^.LogStartSequence := Journal^.Sequence;

  { A quarter of the log, so that a transaction (with its descriptor,
    revoke and commit blocks) always fits in a freshly reset log. }
  Journal^.MaximumBlocks := LongWord(LogBlocks div 4);
  if Journal^.MaximumBlocks > MaximumTransactionBlocks then
    Journal^.MaximumBlocks := MaximumTransactionBlocks;
  Journal^.MaximumRevoked := Journal^.MaximumBlocks;

  Journal^.LoggedSetCapacity := 1;
  while Journal^.LoggedSetCapacity < 2 * LogBlocks do
    Journal^.LoggedSetCapacity := Journal^.LoggedSetCapacity * 2;

  Journal^.Blocks := PLoggedBlock(AllocateZeroedKernelMemory(Journal^.MaximumBlocks * SizeOf(TLoggedBlock)));
  Journal^.Revoked := PQWord(AllocateZeroedKernelMemory(Journal^.MaximumRevoked * SizeOf(QWord)));
  Journal^.LoggedSet := PQWord(AllocateZeroedKernelMemory(Journal^.LoggedSetCapacity * SizeOf(QWord)));
  Result := (Journal^.MaximumBlocks >= MinimumTransactionBlocks) and (Journal^.Blocks <> nil) and
    (Journal^.Revoked <> nil) and (Journal^.LoggedSet <> nil);
end;

procedure DropTransaction(Journal: PExtJournal);
var
  Index: LongWord;
begin
  for Index := 1 to Journal^.BlockCount do
    FreeKernelMemory(Journal^.Blocks[Index - 1].Data);
  Journal^.BlockCount := 0;
  Journal^.RevokedCount := 0;
  Journal^.LastFound := 0;
end;

procedure FreeJournal(Journal: PExtJournal);
begin
  if Journal = nil then
    Exit;
  if Journal^.Blocks <> nil then
    DropTransaction(Journal);
  FreeKernelMemory(Journal^.Blocks);
  FreeKernelMemory(Journal^.Revoked);
  FreeKernelMemory(Journal^.LoggedSet);
  FreeKernelMemory(Journal^.Runs);
  FreeKernelMemory(Journal);
end;

function FindLoggedBlock(Journal: PExtJournal; Block: QWord): PLoggedBlock; forward;

{ --- The needs-recovery mark ------------------------------------------- }

{ Sets or clears the feature in the ext superblock at Superblock. }
procedure ApplyNeedsRecovery(Superblock: PByte; NeedsRecovery, HasMetadataChecksums: Boolean);
var
  Features: PLongWord;
begin
  Features := PLongWord(Superblock + SuperblockFeatureIncompatibleOffset);
  if NeedsRecovery then
    Features^ := Features^ or IncompatibleNeedsRecovery
  else
    Features^ := Features^ and not IncompatibleNeedsRecovery;
  if HasMetadataChecksums then
    PLongWord(Superblock + SuperblockChecksumOffset)^ :=
      Crc32cUpdate(Crc32InitialValue, Superblock, SuperblockChecksumOffset);
end;

function SetNeedsRecovery(Volume: PVolume; NeedsRecovery, HasMetadataChecksums: Boolean): Boolean;
var
  Buffer: array[0..SuperblockSize - 1] of Byte;
begin
  if not VolumeRead(Volume, SuperblockOffset, SuperblockSize, @Buffer[0]) then
    Exit(False);
  ApplyNeedsRecovery(@Buffer[0], NeedsRecovery, HasMetadataChecksums);
  Result := VolumeWrite(Volume, SuperblockOffset, SuperblockSize, @Buffer[0]);
end;

{ Points the journal superblock at the start of the log, with the
  sequence number of the next transaction. }
function ResetLog(Journal: PExtJournal): Boolean;
begin
  { Everything checkpointed so far must be on the disk before the log
    that could replay it is given up. }
  Result := FlushVolume(Journal^.Volume);
  if not Result then
    Exit;
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockStart], LongWord(Journal^.FirstLogBlock));
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockSequence], Journal^.Sequence);
  Result := WriteJournalSuperblock(Journal) and FlushVolume(Journal^.Volume);
  Journal^.Head := Journal^.FirstLogBlock;
  Journal^.LogStartSequence := Journal^.Sequence;
  ClearLoggedSet(Journal);
end;

{ Marks the file system as needing recovery and opens the log, before
  the first transaction is written to it. }
function MarkJournalDirty(Journal: PExtJournal): Boolean;
var
  BlockSize: QWord;
  Logged: PLoggedBlock;
begin
  if Journal^.IsDirty then
    Exit(True);
  { Mark first: a mark without a log only costs a look at the journal. }
  Result := SetNeedsRecovery(Journal^.Volume, True, Journal^.VolumeHasMetadataChecksums) and
    ResetLog(Journal);
  Journal^.IsDirty := Result;
  { A copy of the superblock in the transaction was taken before the
    mark; its checkpoint must not take the mark away again. }
  BlockSize := Journal^.Format.BlockSize;
  Logged := FindLoggedBlock(Journal, SuperblockOffset div BlockSize);
  if Result and (Logged <> nil) then
    ApplyNeedsRecovery(Logged^.Data + SuperblockOffset mod BlockSize, True,
      Journal^.VolumeHasMetadataChecksums);
end;

function MarkJournalClean(Journal: PExtJournal): TFileSystemStatus;
begin
  if (Journal = nil) or not Journal^.IsDirty or Journal^.Halted then
    Exit(StatusSuccess);
  if not FlushVolume(Journal^.Volume) then
    Exit(StatusIoError);
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockStart], 0);
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockSequence], Journal^.Sequence);
  if not WriteJournalSuperblock(Journal) or not FlushVolume(Journal^.Volume) then
    Exit(StatusIoError);
  if not SetNeedsRecovery(Journal^.Volume, False, Journal^.VolumeHasMetadataChecksums) or
     not FlushVolume(Journal^.Volume) then
    Exit(StatusIoError);
  Journal^.IsDirty := False;
  Journal^.Head := Journal^.FirstLogBlock;
  Journal^.LogStartSequence := Journal^.Sequence;
  ClearLoggedSet(Journal);
  Result := StatusSuccess;
end;

{ --- Committing --------------------------------------------------------- }

function TagsPerDescriptor(Journal: PExtJournal): LongWord;
var
  Space: LongWord;
begin
  Space := Journal^.Format.BlockSize - JournalHeaderSize - TailSize(Journal^.Format) - JournalUuidSize;
  Result := Space div TagSize(Journal^.Format);
end;

function RevokesPerBlock(Journal: PExtJournal): LongWord;
begin
  Result := (Journal^.Format.BlockSize - RevokeHeaderSize - TailSize(Journal^.Format)) div
    RevokeRecordSize(Journal^.Format);
end;

function DivideRoundingUp(Value, Divisor: LongWord): LongWord;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

{ Log blocks the running transaction needs, its commit block included. }
function LogBlocksNeeded(Journal: PExtJournal): QWord;
begin
  Result := DivideRoundingUp(Journal^.BlockCount, TagsPerDescriptor(Journal)) + Journal^.BlockCount +
    DivideRoundingUp(Journal^.RevokedCount, RevokesPerBlock(Journal)) + 1;
end;

{ Fills in the next tag of a descriptor block, at Position, for Logged
  (Escaped: it is logged with its first word cleared). }
procedure WriteTag(Journal: PExtJournal; Descriptor: PByte; var Position: LongWord;
  const Logged: TLoggedBlock; IsFirst, IsLast, Escaped: Boolean);
var
  Tag: PByte;
  Flags: LongWord;
  FirstWord: LongWord;
begin
  Tag := Descriptor + Position;
  FillMemory(Tag, TagSize(Journal^.Format), 0);
  Flags := 0;
  if not IsFirst then
    Flags := Flags or JournalTagSameUuid;
  if IsLast then
    Flags := Flags or JournalTagLastTag;
  if Escaped then
    Flags := Flags or JournalTagEscaped;
  WriteBigEndian32(Tag + TagBlockLow, LongWord(Logged.Block));
  if HasJournal64Bit(Journal^.Format) then
    WriteBigEndian32(Tag + TagBlockHigh, LongWord(Logged.Block shr 32));
  if HasChecksumV3(Journal^.Format) then
  begin
    WriteBigEndian32(Tag + TagFlags32, Flags);
    { The checksum covers the block as logged, escaped. }
    FirstWord := PLongWord(Logged.Data)^;
    if Escaped then
      PLongWord(Logged.Data)^ := 0;
    WriteBigEndian32(Tag + TagChecksumV3,
      LoggedBlockChecksum(Journal^.Format, Journal^.Sequence, Logged.Data));
    PLongWord(Logged.Data)^ := FirstWord;
  end
  else
  begin
    Tag[TagFlags16] := Byte(Flags shr 8);
    Tag[TagFlags16 + 1] := Byte(Flags);
  end;
  Position := Position + TagSize(Journal^.Format);
  if IsFirst then
  begin
    CopyMemory(Descriptor + Position, @Journal^.Format.Uuid[0], JournalUuidSize);
    Position := Position + JournalUuidSize;
  end;
end;

{ Writes the transaction's descriptor and logged blocks from log block
  Position on, advancing it. }
function WriteLoggedBlocks(Journal: PExtJournal; Descriptor, Escaped: PByte;
  var Position: QWord): Boolean;
var
  First: LongWord;
  Count: LongWord;
  Index: LongWord;
  TagPosition: LongWord;
  Logged: PLoggedBlock;
  NeedsEscape: Boolean;
begin
  Result := True;
  First := 0;
  while First < Journal^.BlockCount do
  begin
    Count := Journal^.BlockCount - First;
    if Count > TagsPerDescriptor(Journal) then
      Count := TagsPerDescriptor(Journal);
    FillMemory(Descriptor, Journal^.Format.BlockSize, 0);
    WriteJournalHeader(Descriptor, JournalBlockDescriptor, Journal^.Sequence);
    TagPosition := JournalHeaderSize;
    for Index := 0 to Count - 1 do
    begin
      Logged := @Journal^.Blocks[First + Index];
      NeedsEscape := ReadBigEndian32(Logged^.Data) = JournalMagic;
      WriteTag(Journal, Descriptor, TagPosition, Logged^, Index = 0, Index = Count - 1, NeedsEscape);
    end;
    SetBlockTail(Journal^.Format, Descriptor);
    if not WriteLogBlock(Journal, Position, Descriptor) then
      Exit(False);
    Inc(Position);
    for Index := 0 to Count - 1 do
    begin
      Logged := @Journal^.Blocks[First + Index];
      { A block that starts like a journal block is logged with its
        first word cleared (the tag says so), so recovery cannot take it
        for one. }
      if ReadBigEndian32(Logged^.Data) = JournalMagic then
      begin
        CopyMemory(Escaped, Logged^.Data, Journal^.Format.BlockSize);
        PLongWord(Escaped)^ := 0;
        Result := WriteLogBlock(Journal, Position, Escaped);
      end
      else
        Result := WriteLogBlock(Journal, Position, Logged^.Data);
      if not Result then
        Exit;
      Inc(Position);
    end;
    First := First + Count;
  end;
end;

function WriteRevokeBlocks(Journal: PExtJournal; Buffer: PByte; var Position: QWord): Boolean;
var
  First: LongWord;
  Count: LongWord;
  Index: LongWord;
  RecordSize: LongWord;
  Offset: LongWord;
begin
  Result := True;
  RecordSize := RevokeRecordSize(Journal^.Format);
  First := 0;
  while First < Journal^.RevokedCount do
  begin
    Count := Journal^.RevokedCount - First;
    if Count > RevokesPerBlock(Journal) then
      Count := RevokesPerBlock(Journal);
    FillMemory(Buffer, Journal^.Format.BlockSize, 0);
    WriteJournalHeader(Buffer, JournalBlockRevoke, Journal^.Sequence);
    Offset := RevokeHeaderSize;
    for Index := 0 to Count - 1 do
    begin
      if RecordSize = 8 then
        WriteBigEndian64(Buffer + Offset, Journal^.Revoked[First + Index])
      else
        WriteBigEndian32(Buffer + Offset, LongWord(Journal^.Revoked[First + Index]));
      Offset := Offset + RecordSize;
    end;
    WriteBigEndian32(Buffer + RevokeCount, Offset);
    SetBlockTail(Journal^.Format, Buffer);
    if not WriteLogBlock(Journal, Position, Buffer) then
      Exit(False);
    Inc(Position);
    First := First + Count;
  end;
end;

function WriteCommitBlock(Journal: PExtJournal; Buffer: PByte; Position: QWord): Boolean;
var
  Now: QWord;
begin
  FillMemory(Buffer, Journal^.Format.BlockSize, 0);
  WriteJournalHeader(Buffer, JournalBlockCommit, Journal^.Sequence);
  Now := QWord(CurrentWallClockTime);
  WriteBigEndian64(Buffer + CommitSeconds, Now);
  SetCommitChecksum(Journal^.Format, Buffer);
  Result := WriteLogBlock(Journal, Position, Buffer);
end;

function Checkpoint(Journal: PExtJournal): Boolean;
var
  Index: LongWord;
  Logged: PLoggedBlock;
begin
  Result := True;
  for Index := 1 to Journal^.BlockCount do
  begin
    Logged := @Journal^.Blocks[Index - 1];
    if not VolumeWrite(Journal^.Volume, Logged^.Block * Journal^.Format.BlockSize,
      Journal^.Format.BlockSize, Logged^.Data) then
      Result := False;
    AddToLoggedSet(Journal, Logged^.Block);
  end;
end;

function CommitTransaction(Journal: PExtJournal): TFileSystemStatus;
var
  Descriptor: PByte;
  Escaped: PByte;
  Position: QWord;
  Written: Boolean;
begin
  if (Journal^.BlockCount = 0) and (Journal^.RevokedCount = 0) then
    Exit(StatusSuccess);
  if Journal^.Failed or Journal^.Halted then
  begin
    DropTransaction(Journal);
    Exit(StatusIoError);
  end;
  if not MarkJournalDirty(Journal) then
  begin
    Journal^.Failed := True;
    DropTransaction(Journal);
    Exit(StatusIoError);
  end;
  if (Journal^.Head + LogBlocksNeeded(Journal) > Journal^.LogEnd) and not ResetLog(Journal) then
  begin
    Journal^.Failed := True;
    DropTransaction(Journal);
    Exit(StatusIoError);
  end;

  Descriptor := PByte(AllocateKernelMemory(Journal^.Format.BlockSize));
  Escaped := PByte(AllocateKernelMemory(Journal^.Format.BlockSize));
  if (Descriptor = nil) or (Escaped = nil) then
  begin
    FreeKernelMemory(Descriptor);
    FreeKernelMemory(Escaped);
    DropTransaction(Journal);
    Exit(StatusOutOfMemory);
  end;

  Position := Journal^.Head;
  { The commit block goes only after everything before it - the logged
    blocks and the file data written in place - is on the disk. }
  Written := WriteLoggedBlocks(Journal, Descriptor, Escaped, Position) and
    WriteRevokeBlocks(Journal, Descriptor, Position) and FlushVolume(Journal^.Volume) and
    WriteCommitBlock(Journal, Descriptor, Position) and FlushVolume(Journal^.Volume);
  FreeKernelMemory(Descriptor);
  FreeKernelMemory(Escaped);
  if not Written then
  begin
    Journal^.Failed := True;
    DropTransaction(Journal);
    Exit(StatusIoError);
  end;

  if Journal^.StopBeforeCheckpoint then
  begin
    Journal^.Halted := True;
    DropTransaction(Journal);
    Exit(StatusSuccess);
  end;

  Journal^.Head := Position + 1;
  Inc(Journal^.Sequence);
  if not Checkpoint(Journal) then
    Result := StatusIoError
  else
    Result := StatusSuccess;
  DropTransaction(Journal);
end;

procedure BeginTransaction(Journal: PExtJournal);
begin
  if Journal <> nil then
    Inc(Journal^.Depth);
end;

function EndTransaction(Journal: PExtJournal): TFileSystemStatus;
begin
  if Journal = nil then
    Exit(StatusSuccess);
  Dec(Journal^.Depth);
  if Journal^.Depth > 0 then
    Exit(StatusSuccess);
  Result := CommitTransaction(Journal);
end;

{ --- Reading and writing through the transaction ------------------------ }

function FindLoggedBlock(Journal: PExtJournal; Block: QWord): PLoggedBlock;
var
  Index: LongWord;
begin
  if Journal^.BlockCount = 0 then
    Exit(nil);
  if (Journal^.LastFound < Journal^.BlockCount) and
     (Journal^.Blocks[Journal^.LastFound].Block = Block) then
    Exit(@Journal^.Blocks[Journal^.LastFound]);
  for Index := 0 to Journal^.BlockCount - 1 do
    if Journal^.Blocks[Index].Block = Block then
    begin
      Journal^.LastFound := Index;
      Exit(@Journal^.Blocks[Index]);
    end;
  Result := nil;
end;

procedure CancelRevoke(Journal: PExtJournal; Block: QWord);
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Journal^.RevokedCount do
  begin
    if Journal^.Revoked[Index] = Block then
    begin
      Journal^.Revoked[Index] := Journal^.Revoked[Journal^.RevokedCount - 1];
      Dec(Journal^.RevokedCount);
      Exit;
    end;
    Inc(Index);
  end;
end;

{ The transaction's copy of Block, made from the disk if it has none. A
  full transaction is committed first. }
function LoggedCopyOf(Journal: PExtJournal; Block: QWord): PLoggedBlock;
var
  Data: PByte;
begin
  Result := FindLoggedBlock(Journal, Block);
  if Result <> nil then
    Exit;
  if (Journal^.BlockCount = Journal^.MaximumBlocks) and (CommitTransaction(Journal) <> StatusSuccess) then
    Exit(nil);
  Data := PByte(AllocateKernelMemory(Journal^.Format.BlockSize));
  if Data = nil then
    Exit(nil);
  if not VolumeRead(Journal^.Volume, Block * Journal^.Format.BlockSize, Journal^.Format.BlockSize, Data) then
  begin
    FreeKernelMemory(Data);
    Exit(nil);
  end;
  CancelRevoke(Journal, Block);
  Result := @Journal^.Blocks[Journal^.BlockCount];
  Result^.Block := Block;
  Result^.Data := Data;
  Journal^.LastFound := Journal^.BlockCount;
  Inc(Journal^.BlockCount);
end;

function InTransaction(Journal: PExtJournal): Boolean;
begin
  Result := (Journal <> nil) and (Journal^.Depth > 0);
end;

function JournalRead(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
var
  BlockSize: QWord;
  Block: QWord;
  LastBlock: QWord;
  Logged: PLoggedBlock;
  Start: QWord;
  Finish: QWord;
begin
  Result := VolumeRead(Volume, Offset, ByteCount, Buffer);
  if not Result or (Journal = nil) or (Journal^.BlockCount = 0) or (ByteCount = 0) then
    Exit;
  BlockSize := Journal^.Format.BlockSize;
  Block := Offset div BlockSize;
  LastBlock := (Offset + ByteCount - 1) div BlockSize;
  while Block <= LastBlock do
  begin
    Logged := FindLoggedBlock(Journal, Block);
    if Logged <> nil then
    begin
      Start := Block * BlockSize;
      if Start < Offset then
        Start := Offset;
      Finish := (Block + 1) * BlockSize;
      if Finish > Offset + ByteCount then
        Finish := Offset + ByteCount;
      CopyMemory(PByte(Buffer) + (Start - Offset), Logged^.Data + (Start - Block * BlockSize),
        Finish - Start);
    end;
    Inc(Block);
  end;
end;

{ Copies the part of [Offset, Offset + ByteCount) that lies in Block into
  Logged (zeros if Buffer is nil). }
procedure PatchLoggedBlock(Journal: PExtJournal; Logged: PLoggedBlock; Offset, ByteCount: QWord;
  Buffer: Pointer);
var
  BlockSize: QWord;
  Start: QWord;
  Finish: QWord;
begin
  BlockSize := Journal^.Format.BlockSize;
  Start := Logged^.Block * BlockSize;
  if Start < Offset then
    Start := Offset;
  Finish := (Logged^.Block + 1) * BlockSize;
  if Finish > Offset + ByteCount then
    Finish := Offset + ByteCount;
  if Buffer = nil then
    FillMemory(Logged^.Data + (Start - Logged^.Block * BlockSize), Finish - Start, 0)
  else
    CopyMemory(Logged^.Data + (Start - Logged^.Block * BlockSize), PByte(Buffer) + (Start - Offset),
      Finish - Start);
end;

function WriteInPlace(Volume: PVolume; Offset, ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  if Buffer = nil then
    Result := VolumeWriteZeros(Volume, Offset, ByteCount)
  else
    Result := VolumeWrite(Volume, Offset, ByteCount, Buffer);
end;

function JournalWriteMetadata(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
var
  Block: QWord;
  LastBlock: QWord;
  Logged: PLoggedBlock;
begin
  if not InTransaction(Journal) then
    Exit(WriteInPlace(Volume, Offset, ByteCount, Buffer));
  if Journal^.Failed or Journal^.Halted then
    Exit(False);
  if ByteCount = 0 then
    Exit(True);
  Block := Offset div Journal^.Format.BlockSize;
  LastBlock := (Offset + ByteCount - 1) div Journal^.Format.BlockSize;
  while Block <= LastBlock do
  begin
    Logged := LoggedCopyOf(Journal, Block);
    if Logged = nil then
      Exit(False);
    { Freed and used again in this transaction: this copy is the one to
      replay. }
    if Journal^.RevokedCount > 0 then
      CancelRevoke(Journal, Block);
    PatchLoggedBlock(Journal, Logged, Offset, ByteCount, Buffer);
    Inc(Block);
  end;
  Result := True;
end;

function JournalWriteData(Journal: PExtJournal; Volume: PVolume; Offset, ByteCount: QWord;
  Buffer: Pointer): Boolean;
var
  Block: QWord;
  LastBlock: QWord;
  Logged: PLoggedBlock;
begin
  if (Journal <> nil) and Journal^.Halted then
    Exit(False);
  Result := WriteInPlace(Volume, Offset, ByteCount, Buffer);
  if not Result or not InTransaction(Journal) or (Journal^.BlockCount = 0) or (ByteCount = 0) then
    Exit;
  Block := Offset div Journal^.Format.BlockSize;
  LastBlock := (Offset + ByteCount - 1) div Journal^.Format.BlockSize;
  while Block <= LastBlock do
  begin
    Logged := FindLoggedBlock(Journal, Block);
    if Logged <> nil then
      PatchLoggedBlock(Journal, Logged, Offset, ByteCount, Buffer);
    Inc(Block);
  end;
end;

procedure JournalNoteFreedBlock(Journal: PExtJournal; Block: QWord);
var
  Index: LongWord;
begin
  if not InTransaction(Journal) then
    Exit;
  if not IsInLog(Journal, Block) and (FindLoggedBlock(Journal, Block) = nil) then
    Exit;
  for Index := 1 to Journal^.RevokedCount do
    if Journal^.Revoked[Index - 1] = Block then
      Exit;
  if (Journal^.RevokedCount = Journal^.MaximumRevoked) and (CommitTransaction(Journal) <> StatusSuccess) then
    Exit;
  Journal^.Revoked[Journal^.RevokedCount] := Block;
  Inc(Journal^.RevokedCount);
end;

end.
