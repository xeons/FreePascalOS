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
  On-disk format of the ext3/ext4 journal (JBD2).

  The journal is a circular log of blocks inside a file (inode 8). Its
  first block is the journal superblock; the rest is the log. Every
  journal structure is big endian, unlike the rest of ext.

  The log holds transactions, each a run of blocks with the same
  sequence number:

    descriptor block   a header and one tag per logged block: where the
                       block belongs in the file system, and flags
    logged blocks      the new contents of those blocks, in tag order
    (more descriptors and blocks)
    revoke block       file system blocks whose older logged copies must
                       not be replayed (they were freed meanwhile)
    commit block       the transaction is complete

  A transaction counts only if its commit block is there (and its
  checksums are right). The superblock names where the log starts
  (Start, 0 if the journal is empty) and the sequence number expected
  there; recovery replays transactions from there for as long as the
  sequence numbers follow on.

  Checksums: with the "checksum v3" feature every descriptor and revoke
  block ends with a CRC32C tail, the commit block carries one, and each
  tag carries the CRC32C of its block (seeded with the sequence number).
  All are seeded with the CRC32C of the journal's UUID. The superblock
  carries its own CRC32C. Older checksum schemes (v1: a CRC32 in the
  commit block; v2: 16-bit tag checksums) are not written by this driver.
}
unit FileSystem.Ext.JournalFormat;

{$mode objfpc}
{$pointermath on}

interface

const
  JournalMagic = LongWord($C03B3998);

  JournalBlockDescriptor = 1;
  JournalBlockCommit = 2;
  JournalBlockSuperblockVersion1 = 3;
  JournalBlockSuperblockVersion2 = 4;
  JournalBlockRevoke = 5;

  JournalCompatibleChecksum = $1;

  JournalIncompatibleRevoke = $1;
  JournalIncompatible64Bit = $2;
  JournalIncompatibleAsyncCommit = $4;
  JournalIncompatibleChecksumV2 = $8;
  JournalIncompatibleChecksumV3 = $10;
  JournalIncompatibleFastCommit = $20;

  { Incompatible features recovery understands, and the ones this
    driver can also write with. }
  JournalReadableIncompatible = JournalIncompatibleRevoke or JournalIncompatible64Bit or
    JournalIncompatibleAsyncCommit or JournalIncompatibleChecksumV3;
  JournalWritableIncompatible = JournalIncompatibleRevoke or JournalIncompatible64Bit or
    JournalIncompatibleChecksumV3;

  { Byte offsets in every journal block's header. }
  JournalHeaderMagic = 0;
  JournalHeaderBlockType = 4;
  JournalHeaderSequence = 8;
  JournalHeaderSize = 12;

  { Byte offsets in the journal superblock. }
  JournalSuperblockBlockSize = 12;
  JournalSuperblockMaximumLength = 16;
  JournalSuperblockFirst = 20;
  JournalSuperblockSequence = 24;
  JournalSuperblockStart = 28;
  JournalSuperblockErrno = 32;
  JournalSuperblockCompatible = 36;
  JournalSuperblockIncompatible = 40;
  JournalSuperblockReadOnlyCompatible = 44;
  JournalSuperblockUuid = 48;
  JournalSuperblockChecksumType = 80;
  JournalSuperblockChecksum = $FC;
  JournalSuperblockSize = 1024;

  JournalChecksumTypeCrc32c = 4;

  { Tag flags. }
  JournalTagEscaped = 1;
  JournalTagSameUuid = 2;
  JournalTagLastTag = 8;

  { Byte offsets in a tag; the flags are the low 16 bits at 6 in both
    tag layouts. }
  TagBlockLow = 0;
  TagFlags16 = 6;
  TagFlags32 = 4;
  TagBlockHigh = 8;
  TagChecksumV3 = 12;
  JournalUuidSize = 16;

  { Commit block: the checksum (v3) right after the header, then the
    commit time. }
  CommitChecksumType = 12;
  CommitChecksumSize = 13;
  CommitChecksum = 16;
  CommitSeconds = 48;
  CommitNanoseconds = 56;

  { Revoke block: bytes used (header and count included), then the
    revoked block numbers. }
  RevokeCount = 12;
  RevokeHeaderSize = 16;

  { The checksum tail at the end of descriptor and revoke blocks. }
  JournalTailSize = 4;

function ReadBigEndian32(Data: PByte): LongWord;
procedure WriteBigEndian32(Data: PByte; Value: LongWord);
function ReadBigEndian64(Data: PByte): QWord;
procedure WriteBigEndian64(Data: PByte; Value: QWord);

type
  { What the journal superblock says about the log's format. }
  TJournalFormat = record
    BlockSize: LongWord;
    Incompatible: LongWord;
    Compatible: LongWord;
    { CRC32C of the journal UUID, for v3 checksums. }
    ChecksumSeed: LongWord;
    Uuid: array[0..JournalUuidSize - 1] of Byte;
  end;

function HasChecksumV3(const Format: TJournalFormat): Boolean;
function HasJournal64Bit(const Format: TJournalFormat): Boolean;
{ Bytes per tag in a descriptor block. }
function TagSize(const Format: TJournalFormat): LongWord;
{ Bytes per revoked block number. }
function RevokeRecordSize(const Format: TJournalFormat): LongWord;
{ Bytes at the end of descriptor and revoke blocks reserved for the tail. }
function TailSize(const Format: TJournalFormat): LongWord;

{ Fills in the header of a journal block. }
procedure WriteJournalHeader(Block: PByte; BlockType: LongWord; Sequence: LongWord);
{ True if Block has the journal magic, the given type and sequence. }
function HeaderMatches(Block: PByte; Sequence: LongWord): Boolean;
function JournalBlockType(Block: PByte): LongWord;

{ The checksum of a whole descriptor or revoke block with its tail
  zeroed; SetBlockTail stores it, BlockTailIsValid checks it. }
procedure SetBlockTail(const Format: TJournalFormat; Block: PByte);
function BlockTailIsValid(const Format: TJournalFormat; Block: PByte): Boolean;
procedure SetCommitChecksum(const Format: TJournalFormat; Block: PByte);
function CommitChecksumIsValid(const Format: TJournalFormat; Block: PByte): Boolean;
{ The v3 checksum of a logged block. }
function LoggedBlockChecksum(const Format: TJournalFormat; Sequence: LongWord; Data: PByte): LongWord;
{ The checksum of a journal superblock (v2/v3), and storing it. }
function JournalSuperblockChecksumOf(Superblock: PByte): LongWord;
procedure SetJournalSuperblockChecksum(const Format: TJournalFormat; Superblock: PByte);

implementation

uses
  Runtime.Checksums;

function ReadBigEndian32(Data: PByte): LongWord;
begin
  Result := (LongWord(Data[0]) shl 24) or (LongWord(Data[1]) shl 16) or
    (LongWord(Data[2]) shl 8) or LongWord(Data[3]);
end;

procedure WriteBigEndian32(Data: PByte; Value: LongWord);
begin
  Data[0] := Byte(Value shr 24);
  Data[1] := Byte(Value shr 16);
  Data[2] := Byte(Value shr 8);
  Data[3] := Byte(Value);
end;

function ReadBigEndian64(Data: PByte): QWord;
begin
  Result := (QWord(ReadBigEndian32(Data)) shl 32) or ReadBigEndian32(Data + 4);
end;

procedure WriteBigEndian64(Data: PByte; Value: QWord);
begin
  WriteBigEndian32(Data, LongWord(Value shr 32));
  WriteBigEndian32(Data + 4, LongWord(Value));
end;

function HasChecksumV3(const Format: TJournalFormat): Boolean;
begin
  Result := (Format.Incompatible and JournalIncompatibleChecksumV3) <> 0;
end;

function HasJournal64Bit(const Format: TJournalFormat): Boolean;
begin
  Result := (Format.Incompatible and JournalIncompatible64Bit) <> 0;
end;

function TagSize(const Format: TJournalFormat): LongWord;
begin
  if HasChecksumV3(Format) then
    Result := 16
  else if HasJournal64Bit(Format) then
    Result := 12
  else
    Result := 8;
end;

function RevokeRecordSize(const Format: TJournalFormat): LongWord;
begin
  if HasJournal64Bit(Format) then
    Result := 8
  else
    Result := 4;
end;

function TailSize(const Format: TJournalFormat): LongWord;
begin
  if HasChecksumV3(Format) then
    Result := JournalTailSize
  else
    Result := 0;
end;

procedure WriteJournalHeader(Block: PByte; BlockType: LongWord; Sequence: LongWord);
begin
  WriteBigEndian32(Block + JournalHeaderMagic, JournalMagic);
  WriteBigEndian32(Block + JournalHeaderBlockType, BlockType);
  WriteBigEndian32(Block + JournalHeaderSequence, Sequence);
end;

function HeaderMatches(Block: PByte; Sequence: LongWord): Boolean;
begin
  Result := (ReadBigEndian32(Block + JournalHeaderMagic) = JournalMagic) and
    (ReadBigEndian32(Block + JournalHeaderSequence) = Sequence);
end;

function JournalBlockType(Block: PByte): LongWord;
begin
  Result := ReadBigEndian32(Block + JournalHeaderBlockType);
end;

{ The checksum of Block with the four bytes at ChecksumOffset taken as
  zero (they are restored). }
function ChecksumWithFieldZeroed(const Format: TJournalFormat; Block: PByte;
  ChecksumOffset: LongWord): LongWord;
var
  Saved: LongWord;
begin
  Saved := PLongWord(Block + ChecksumOffset)^;
  PLongWord(Block + ChecksumOffset)^ := 0;
  Result := Crc32cUpdate(Format.ChecksumSeed, Block, Format.BlockSize);
  PLongWord(Block + ChecksumOffset)^ := Saved;
end;

procedure SetBlockTail(const Format: TJournalFormat; Block: PByte);
var
  TailOffset: LongWord;
begin
  if not HasChecksumV3(Format) then
    Exit;
  TailOffset := Format.BlockSize - JournalTailSize;
  WriteBigEndian32(Block + TailOffset, ChecksumWithFieldZeroed(Format, Block, TailOffset));
end;

function BlockTailIsValid(const Format: TJournalFormat; Block: PByte): Boolean;
var
  TailOffset: LongWord;
begin
  if not HasChecksumV3(Format) then
    Exit(True);
  TailOffset := Format.BlockSize - JournalTailSize;
  Result := ReadBigEndian32(Block + TailOffset) = ChecksumWithFieldZeroed(Format, Block, TailOffset);
end;

procedure SetCommitChecksum(const Format: TJournalFormat; Block: PByte);
begin
  if HasChecksumV3(Format) then
    WriteBigEndian32(Block + CommitChecksum, ChecksumWithFieldZeroed(Format, Block, CommitChecksum));
end;

function CommitChecksumIsValid(const Format: TJournalFormat; Block: PByte): Boolean;
begin
  if not HasChecksumV3(Format) then
    Exit(True);
  Result := ReadBigEndian32(Block + CommitChecksum) = ChecksumWithFieldZeroed(Format, Block, CommitChecksum);
end;

function LoggedBlockChecksum(const Format: TJournalFormat; Sequence: LongWord; Data: PByte): LongWord;
var
  SequenceBytes: array[0..3] of Byte;
begin
  WriteBigEndian32(@SequenceBytes[0], Sequence);
  Result := Crc32cUpdate(Format.ChecksumSeed, @SequenceBytes[0], 4);
  Result := Crc32cUpdate(Result, Data, Format.BlockSize);
end;

function JournalSuperblockChecksumOf(Superblock: PByte): LongWord;
var
  Saved: LongWord;
begin
  Saved := PLongWord(Superblock + JournalSuperblockChecksum)^;
  PLongWord(Superblock + JournalSuperblockChecksum)^ := 0;
  Result := Crc32cUpdate(Crc32InitialValue, Superblock, JournalSuperblockSize);
  PLongWord(Superblock + JournalSuperblockChecksum)^ := Saved;
end;

procedure SetJournalSuperblockChecksum(const Format: TJournalFormat; Superblock: PByte);
begin
  if HasChecksumV3(Format) then
    WriteBigEndian32(Superblock + JournalSuperblockChecksum, JournalSuperblockChecksumOf(Superblock));
end;

end.
