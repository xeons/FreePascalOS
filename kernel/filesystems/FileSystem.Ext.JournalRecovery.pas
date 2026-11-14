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
  Journal recovery: replaying the log of a volume that was not unmounted
  cleanly.

  Three passes over the log, from the start the journal superblock names:

    scan     find the end: the first block that is not the next expected
             one (wrong magic or sequence number, or a bad checksum).
             Only transactions with a valid commit block count.
    revoke   collect the revoke records of those transactions, keeping
             for each block the newest transaction that revoked it.
    replay   write every logged block to its place in the file system,
             unless a transaction at least as new revoked it (or, with
             checksums, its checksum is wrong).

  The log is circular: after its last block it goes on at the first log
  block. Afterwards the journal is marked empty, with the next sequence
  number, and the caller clears the volume's needs-recovery mark.
}
unit FileSystem.Ext.JournalRecovery;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.Transactions;

{ Replays Journal's log, if any, and marks the journal empty. Journal
  has its format, runs, geometry and Superblock filled in. Returns how
  many blocks were replayed in ReplayedBlocks. }
function RecoverJournal(Journal: PExtJournal; out ReplayedBlocks: QWord): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.Ext.JournalFormat;

type
  TRecoveryPass = (PassScan, PassRevoke, PassReplay);

  TRevokeRecord = record
    Block: QWord;
    Sequence: LongWord;
  end;
  PRevokeRecord = ^TRevokeRecord;

  TRecovery = record
    Journal: PExtJournal;
    Buffer: PByte;
    Data: PByte;
    StartBlock: QWord;
    StartSequence: LongWord;
    { The first sequence number not committed (found by the scan). }
    EndSequence: LongWord;
    Revokes: PRevokeRecord;
    RevokeCount: LongWord;
    RevokeCapacity: LongWord;
    Replayed: QWord;
    Failed: Boolean;
  end;

function NextLogBlock(Journal: PExtJournal; Block: QWord): QWord;
begin
  Result := Block + 1;
  if Result >= Journal^.TotalBlocks then
    Result := Journal^.FirstLogBlock;
end;

function ReadLogBlock(Journal: PExtJournal; Block: QWord; Destination: PByte): Boolean;
var
  Address: QWord;
begin
  Address := JournalBlockAddress(Journal, Block);
  Result := (Address <> 0) and VolumeRead(Journal^.Volume, Address, Journal^.Format.BlockSize, Destination);
end;

function SequenceIsBefore(Left, Right: LongWord): Boolean;
begin
  Result := LongInt(Left - Right) < 0;
end;

{ --- Revoke records ---------------------------------------------------- }

function FindRevoke(var Recovery: TRecovery; Block: QWord): PRevokeRecord;
var
  Index: LongWord;
begin
  for Index := 1 to Recovery.RevokeCount do
    if Recovery.Revokes[Index - 1].Block = Block then
      Exit(@Recovery.Revokes[Index - 1]);
  Result := nil;
end;

procedure AddRevoke(var Recovery: TRecovery; Block: QWord; Sequence: LongWord);
var
  Existing: PRevokeRecord;
  Grown: PRevokeRecord;
begin
  Existing := FindRevoke(Recovery, Block);
  if Existing <> nil then
  begin
    if SequenceIsBefore(Existing^.Sequence, Sequence) then
      Existing^.Sequence := Sequence;
    Exit;
  end;
  if Recovery.RevokeCount = Recovery.RevokeCapacity then
  begin
    Grown := PRevokeRecord(AllocateKernelMemory((Recovery.RevokeCapacity * 2 + 64) * SizeOf(TRevokeRecord)));
    if Grown = nil then
    begin
      Recovery.Failed := True;
      Exit;
    end;
    if Recovery.RevokeCount > 0 then
      CopyMemory(Grown, Recovery.Revokes, Recovery.RevokeCount * SizeOf(TRevokeRecord));
    FreeKernelMemory(Recovery.Revokes);
    Recovery.Revokes := Grown;
    Recovery.RevokeCapacity := Recovery.RevokeCapacity * 2 + 64;
  end;
  Recovery.Revokes[Recovery.RevokeCount].Block := Block;
  Recovery.Revokes[Recovery.RevokeCount].Sequence := Sequence;
  Inc(Recovery.RevokeCount);
end;

function IsRevoked(var Recovery: TRecovery; Block: QWord; Sequence: LongWord): Boolean;
var
  Revoke: PRevokeRecord;
begin
  Revoke := FindRevoke(Recovery, Block);
  Result := (Revoke <> nil) and not SequenceIsBefore(Revoke^.Sequence, Sequence);
end;

procedure CollectRevokes(var Recovery: TRecovery; Sequence: LongWord);
var
  Format: TJournalFormat;
  Used: LongWord;
  Offset: LongWord;
  RecordSize: LongWord;
  Block: QWord;
begin
  Format := Recovery.Journal^.Format;
  RecordSize := RevokeRecordSize(Format);
  Used := ReadBigEndian32(Recovery.Buffer + RevokeCount);
  if Used > Format.BlockSize - TailSize(Format) then
    Used := Format.BlockSize - TailSize(Format);
  Offset := RevokeHeaderSize;
  while Offset + RecordSize <= Used do
  begin
    if RecordSize = 8 then
      Block := ReadBigEndian64(Recovery.Buffer + Offset)
    else
      Block := ReadBigEndian32(Recovery.Buffer + Offset);
    AddRevoke(Recovery, Block, Sequence);
    Offset := Offset + RecordSize;
  end;
end;

{ --- Descriptor blocks ------------------------------------------------- }

function TagFlagsAt(Tag: PByte): LongWord;
begin
  Result := (LongWord(Tag[TagFlags16]) shl 8) or Tag[TagFlags16 + 1];
end;

function TagBlockNumber(const Format: TJournalFormat; Tag: PByte): QWord;
begin
  Result := ReadBigEndian32(Tag + TagBlockLow);
  if HasJournal64Bit(Format) then
    Result := Result or (QWord(ReadBigEndian32(Tag + TagBlockHigh)) shl 32);
end;

{ Writes the logged block at LogBlock, described by Tag, to its place -
  unless it was revoked or its checksum is wrong. }
procedure ReplayLoggedBlock(var Recovery: TRecovery; Tag: PByte; Flags: LongWord; LogBlock: QWord;
  Sequence: LongWord);
var
  Journal: PExtJournal;
  Format: TJournalFormat;
  Target: QWord;
begin
  Journal := Recovery.Journal;
  Format := Journal^.Format;
  Target := TagBlockNumber(Format, Tag);
  if IsRevoked(Recovery, Target, Sequence) then
    Exit;
  if not ReadLogBlock(Journal, LogBlock, Recovery.Data) then
  begin
    Recovery.Failed := True;
    Exit;
  end;
  { The checksum covers the block as logged, still escaped. A damaged
    copy is left out: the block keeps what it has. }
  if HasChecksumV3(Format) and
     (ReadBigEndian32(Tag + TagChecksumV3) <> LoggedBlockChecksum(Format, Sequence, Recovery.Data)) then
    Exit;
  if (Flags and JournalTagEscaped) <> 0 then
    WriteBigEndian32(Recovery.Data, JournalMagic);
  if (Target * Format.BlockSize + Format.BlockSize > BlockDeviceSizeInBytes(Journal^.Volume^.Device)) or
     not VolumeWrite(Journal^.Volume, Target * Format.BlockSize, Format.BlockSize, Recovery.Data) then
    Recovery.Failed := True
  else
    Inc(Recovery.Replayed);
end;

{ Goes through the tags of the descriptor in Recovery.Buffer, whose
  logged blocks follow LogBlock. In the replay pass each block is written
  in place. Returns the log block after the last logged one. }
function ProcessDescriptor(var Recovery: TRecovery; LogBlock: QWord; Sequence: LongWord;
  Pass: TRecoveryPass): QWord;
var
  Journal: PExtJournal;
  Format: TJournalFormat;
  Position: LongWord;
  Limit: LongWord;
  Tag: PByte;
  Flags: LongWord;
begin
  Journal := Recovery.Journal;
  Format := Journal^.Format;
  Limit := Format.BlockSize - TailSize(Format);
  Position := JournalHeaderSize;
  Result := LogBlock;
  while Position + TagSize(Format) <= Limit do
  begin
    Tag := Recovery.Buffer + Position;
    Flags := TagFlagsAt(Tag);
    Result := NextLogBlock(Journal, Result);
    if Pass = PassReplay then
      ReplayLoggedBlock(Recovery, Tag, Flags, Result, Sequence);
    Position := Position + TagSize(Format);
    if (Flags and JournalTagSameUuid) = 0 then
      Position := Position + JournalUuidSize;
    if (Flags and JournalTagLastTag) <> 0 then
      Break;
  end;
end;

{ --- The passes -------------------------------------------------------- }

procedure RunPass(var Recovery: TRecovery; Pass: TRecoveryPass);
var
  Journal: PExtJournal;
  Format: TJournalFormat;
  LogBlock: QWord;
  Sequence: LongWord;
  Steps: QWord;
begin
  Journal := Recovery.Journal;
  Format := Journal^.Format;
  LogBlock := Recovery.StartBlock;
  Sequence := Recovery.StartSequence;
  Steps := 0;
  while Steps < Journal^.TotalBlocks do
  begin
    if (Pass <> PassScan) and (Sequence = Recovery.EndSequence) then
      Break;
    if not ReadLogBlock(Journal, LogBlock, Recovery.Buffer) or
       not HeaderMatches(Recovery.Buffer, Sequence) then
      Break;
    case JournalBlockType(Recovery.Buffer) of
      JournalBlockDescriptor:
        begin
          if (Pass = PassScan) and not BlockTailIsValid(Format, Recovery.Buffer) then
            Break;
          LogBlock := ProcessDescriptor(Recovery, LogBlock, Sequence, Pass);
          { The tags were read from Recovery.Buffer; it is reused below. }
        end;
      JournalBlockRevoke:
        begin
          if (Pass = PassScan) and not BlockTailIsValid(Format, Recovery.Buffer) then
            Break;
          if Pass = PassRevoke then
            CollectRevokes(Recovery, Sequence);
        end;
      JournalBlockCommit:
        begin
          if (Pass = PassScan) and not CommitChecksumIsValid(Format, Recovery.Buffer) then
            Break;
          Inc(Sequence);
          if Pass = PassScan then
            Recovery.EndSequence := Sequence;
        end;
    else
      Break;
    end;
    LogBlock := NextLogBlock(Journal, LogBlock);
    Inc(Steps);
  end;
end;

function RecoverJournal(Journal: PExtJournal; out ReplayedBlocks: QWord): TFileSystemStatus;
var
  Recovery: TRecovery;
begin
  ReplayedBlocks := 0;
  FillMemory(@Recovery, SizeOf(Recovery), 0);
  Recovery.Journal := Journal;
  Recovery.StartBlock := ReadBigEndian32(@Journal^.Superblock[JournalSuperblockStart]);
  Recovery.StartSequence := ReadBigEndian32(@Journal^.Superblock[JournalSuperblockSequence]);
  Recovery.EndSequence := Recovery.StartSequence;

  if Recovery.StartBlock <> 0 then
  begin
    if (Recovery.StartBlock < Journal^.FirstLogBlock) or (Recovery.StartBlock >= Journal^.TotalBlocks) then
      Exit(StatusCorrupted);
    Recovery.Buffer := PByte(AllocateKernelMemory(Journal^.Format.BlockSize));
    Recovery.Data := PByte(AllocateKernelMemory(Journal^.Format.BlockSize));
    if (Recovery.Buffer = nil) or (Recovery.Data = nil) then
    begin
      FreeKernelMemory(Recovery.Buffer);
      FreeKernelMemory(Recovery.Data);
      Exit(StatusOutOfMemory);
    end;
    RunPass(Recovery, PassScan);
    RunPass(Recovery, PassRevoke);
    if not Recovery.Failed then
      RunPass(Recovery, PassReplay);
    FreeKernelMemory(Recovery.Buffer);
    FreeKernelMemory(Recovery.Data);
    FreeKernelMemory(Recovery.Revokes);
    if Recovery.Failed then
      Exit(StatusIoError);
  end;
  ReplayedBlocks := Recovery.Replayed;

  { The replayed blocks must be on the disk before the log is given up. }
  if not FlushCachedDevice(Journal^.Volume^.Device) then
    Exit(StatusIoError);
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockStart], 0);
  WriteBigEndian32(@Journal^.Superblock[JournalSuperblockSequence], Recovery.EndSequence + 1);
  if not WriteJournalSuperblock(Journal) or not FlushCachedDevice(Journal^.Volume^.Device) then
    Exit(StatusIoError);
  Journal^.Sequence := Recovery.EndSequence + 1;
  Result := StatusSuccess;
end;

end.
