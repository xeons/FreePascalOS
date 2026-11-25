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
  Files removed while still open, and the ext orphan list.

  A file whose last name is removed while it is open keeps its inode and
  blocks until it is closed. So that a crash in between does not leave
  them allocated for ever, the inode goes on the orphan list in the same
  transaction that removes the name: the superblock's "last orphan"
  names the newest, and each orphan's deletion time field names the next
  (0 ends the list). Closing the file takes it off the list and frees
  it. The driver keeps the open orphans in memory too (newest first), so
  that taking one off changes the in-memory inode of the one before it -
  the copy that is written back - rather than the disk behind its back.

  When a writable volume is mounted, orphans left by a crash (or by
  another system) are processed: inodes without names are freed, and
  inodes that still have names (Linux puts files being truncated on the
  list) lose the blocks past their size. The newer "orphan file" ext4
  feature is not used.
}
unit FileSystem.Ext.Orphans;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExtRemoveOpenNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
function ExtFinishRemoval(Node: PNode): TFileSystemStatus;
{ Takes a node being released off the in-memory orphan list, if it is
  still there (its volume became read-only before it was closed). }
procedure ForgetOrphan(Node: PNode);
{ Processes the orphan list of a volume being mounted; Count says how
  many orphans there were. }
function ProcessOrphans(Volume: PVolume; out Count: LongWord): TFileSystemStatus;

implementation

uses
  Runtime.Checksums,
  Memory.KernelHeap,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume,
  FileSystem.Ext.Blocks,
  FileSystem.Ext.Directories,
  FileSystem.Ext.Write;

const
  SuperblockLastOrphanOffset = $E8;
  { Orphans are files that were open when the system stopped: a list
    longer than this is damaged, and the rest is left to e2fsck. }
  MaximumOrphansAtMount = 65536;

{ --- The list head in the superblock ------------------------------------ }

function ReadLastOrphan(Volume: PVolume; out Value: LongWord): Boolean;
begin
  Result := ExtRead(Volume, SuperblockOffset + SuperblockLastOrphanOffset, 4, @Value);
end;

function WriteLastOrphan(Volume: PVolume; Value: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Buffer: array[0..SuperblockSize - 1] of Byte;
begin
  Ext := PExtVolume(Volume^.DriverData);
  if not ExtRead(Volume, SuperblockOffset, SuperblockSize, @Buffer[0]) then
    Exit(StatusIoError);
  PLongWord(@Buffer[SuperblockLastOrphanOffset])^ := Value;
  if Ext^.HasMetadataChecksums then
    PLongWord(@Buffer[SuperblockChecksumOffset])^ :=
      Crc32cUpdate(Crc32InitialValue, @Buffer[0], SuperblockChecksumOffset);
  if not ExtWriteMetadata(Volume, SuperblockOffset, SuperblockSize, @Buffer[0]) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

{ --- Removing open files ------------------------------------------------ }

function ExtRemoveOpenNode(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  Ext: PExtVolume;
  Parent: PExtNode;
  ExtNode: PExtNode;
  Head: LongWord;
begin
  Ext := ExtVolumeOf(Node);
  Parent := PExtNode(Directory);
  ExtNode := PExtNode(Node);
  if Node^.Information.Kind = NodeKindDirectory then
    Exit(StatusInUse);
  if not ReadLastOrphan(Node^.Volume, Head) then
    Exit(StatusIoError);

  Result := RemoveDirectoryEntry(Parent, Name);
  if Result <> StatusSuccess then
    Exit;
  if InodeRecord(ExtNode)^.LinksCount > 0 then
    Dec(InodeRecord(ExtNode)^.LinksCount);
  StampTimes(ExtNode, False);
  if InodeRecord(ExtNode)^.LinksCount = 0 then
  begin
    { First on the list, before the old first. }
    InodeRecord(ExtNode)^.DeletionTime := Head;
    Result := WriteLastOrphan(Node^.Volume, ExtNode^.InodeNumber);
    ExtNode^.IsOrphan := True;
    ExtNode^.NextOrphan := PExtNode(Ext^.FirstOrphan);
    Ext^.FirstOrphan := ExtNode;
    Node^.RemovalPending := True;
  end;
  WriteNodeInode(ExtNode);
  RefreshNodeInformation(ExtNode);
  StampTimes(Parent, True);
  RefreshNodeInformation(Parent);
  if Result = StatusSuccess then
    Result := WriteNodeInode(Parent);
end;

{ Takes Node off the in-memory list; Previous returns the orphan before
  it (nil if it was first). }
procedure UnlinkFromMemory(Ext: PExtVolume; Node: PExtNode; out Previous: PExtNode);
var
  Current: PExtNode;
begin
  Previous := nil;
  Current := PExtNode(Ext^.FirstOrphan);
  while (Current <> nil) and (Current <> Node) do
  begin
    Previous := Current;
    Current := Current^.NextOrphan;
  end;
  if Current = nil then
    Exit;
  if Previous = nil then
    Ext^.FirstOrphan := Node^.NextOrphan
  else
    Previous^.NextOrphan := Node^.NextOrphan;
  Node^.IsOrphan := False;
  Node^.NextOrphan := nil;
end;

function ExtFinishRemoval(Node: PNode): TFileSystemStatus;
var
  Ext: PExtVolume;
  ExtNode: PExtNode;
  Previous: PExtNode;
  Next: LongWord;
begin
  Ext := ExtVolumeOf(Node);
  ExtNode := PExtNode(Node);
  Result := StatusSuccess;
  if ExtNode^.IsOrphan then
  begin
    Next := InodeRecord(ExtNode)^.DeletionTime;
    UnlinkFromMemory(Ext, ExtNode, Previous);
    if Previous = nil then
      Result := WriteLastOrphan(Node^.Volume, Next)
    else
    begin
      InodeRecord(Previous)^.DeletionTime := Next;
      Result := WriteNodeInode(Previous);
    end;
  end;
  Node^.RemovalPending := False;
  DiscardInode(ExtNode, False);
end;

procedure ForgetOrphan(Node: PNode);
var
  ExtNode: PExtNode;
  Previous: PExtNode;
begin
  ExtNode := PExtNode(Node);
  if ExtNode^.IsOrphan then
    UnlinkFromMemory(ExtVolumeOf(Node), ExtNode, Previous);
end;

{ --- At mount ----------------------------------------------------------- }

function LoadOrphan(Volume: PVolume; InodeNumber: LongWord; out Node: PExtNode): TFileSystemStatus;
begin
  Node := PExtNode(AllocateZeroedKernelMemory(SizeOf(TExtNode)));
  if Node = nil then
    Exit(StatusOutOfMemory);
  Node^.Common.Volume := Volume;
  Node^.InodeNumber := InodeNumber;
  Result := ReadInodeBytes(Volume, InodeNumber, @Node^.InodeBytes[0]);
  if Result = StatusSuccess then
    RefreshNodeInformation(Node)
  else
  begin
    FreeKernelMemory(Node);
    Node := nil;
  end;
end;

{ Frees an orphan without names, or cuts one that has names to its size. }
procedure SettleOrphan(Node: PExtNode);
var
  Ext: PExtVolume;
  KeepBlocks: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  if InodeRecord(Node)^.LinksCount = 0 then
    DiscardInode(Node, (InodeRecord(Node)^.Mode and ModeTypeMask) = ModeTypeDirectory)
  else
  begin
    KeepBlocks := (InodeSize(InodeRecord(Node)^) + Ext^.BlockSize - 1) div Ext^.BlockSize;
    if (Node^.Common.Information.Kind = NodeKindFile) and (KeepBlocks <= High(LongWord)) then
      ReleaseBlocksFrom(Node, LongWord(KeepBlocks));
    InodeRecord(Node)^.DeletionTime := 0;
    WriteNodeInode(Node);
  end;
end;

{ An orphan list link can only name an ordinary inode the volume has:
  never a reserved one (the root, the journal), which settling would
  free. }
function IsOrphanNumber(Ext: PExtVolume; InodesCount, InodeNumber: LongWord): Boolean;
begin
  Result := (InodeNumber >= Ext^.FirstNonReservedInode) and (InodeNumber <= InodesCount);
end;

{ The orphan after InodeNumber on the list, 0 at its end or where it
  goes wrong. Reads only. }
function NextOrphanNumber(Volume: PVolume; InodesCount, InodeNumber: LongWord): LongWord;
var
  InodeBytes: array[0..MaximumInodeSize - 1] of Byte;
begin
  Result := 0;
  if not IsOrphanNumber(PExtVolume(Volume^.DriverData), InodesCount, InodeNumber) then
    Exit;
  if ReadInodeBytes(Volume, InodeNumber, @InodeBytes[0]) <> StatusSuccess then
    Exit;
  Result := PInode(@InodeBytes[0])^.DeletionTime;
  if not IsOrphanNumber(PExtVolume(Volume^.DriverData), InodesCount, Result) then
    Result := 0;
end;

{ How many orphans the list starting at Head holds before it ends or
  comes back to one already on it (a damaged list may loop), at most
  MaximumOrphansAtMount. Settling an orphan rewrites its link, so the
  list is measured first, reading only (tortoise and hare). }
function CountDistinctOrphans(Volume: PVolume; InodesCount, Head: LongWord): LongWord;
var
  Slow: LongWord;
  Fast: LongWord;
  Steps: LongWord;
  LoopStart: LongWord;
  LoopLength: LongWord;
begin
  Result := 0;
  if not IsOrphanNumber(PExtVolume(Volume^.DriverData), InodesCount, Head) then
    Exit;
  Slow := Head;
  Fast := Head;
  Steps := 0;
  repeat
    Fast := NextOrphanNumber(Volume, InodesCount, Fast);
    if Fast <> 0 then
      Fast := NextOrphanNumber(Volume, InodesCount, Fast);
    Slow := NextOrphanNumber(Volume, InodesCount, Slow);
    Inc(Steps);
  until (Fast = 0) or (Fast = Slow) or (Steps > MaximumOrphansAtMount);

  if Fast = 0 then
  begin
    { No loop: count to the end. }
    Fast := Head;
    while (Fast <> 0) and (Result < MaximumOrphansAtMount) do
    begin
      Inc(Result);
      Fast := NextOrphanNumber(Volume, InodesCount, Fast);
    end;
    Exit;
  end;
  if Steps > MaximumOrphansAtMount then
    Exit(MaximumOrphansAtMount);

  { A loop: the part before it, then the loop itself, once. }
  LoopStart := Head;
  while LoopStart <> Slow do
  begin
    LoopStart := NextOrphanNumber(Volume, InodesCount, LoopStart);
    Slow := NextOrphanNumber(Volume, InodesCount, Slow);
    Inc(Result);
  end;
  LoopLength := 1;
  Fast := NextOrphanNumber(Volume, InodesCount, LoopStart);
  while (Fast <> LoopStart) and (LoopLength < MaximumOrphansAtMount) do
  begin
    Inc(LoopLength);
    Fast := NextOrphanNumber(Volume, InodesCount, Fast);
  end;
  Result := Result + LoopLength;
  if Result > MaximumOrphansAtMount then
    Result := MaximumOrphansAtMount;
end;

function ProcessOrphans(Volume: PVolume; out Count: LongWord): TFileSystemStatus;
var
  InodesCount: LongWord;
  InodeNumber: LongWord;
  Node: PExtNode;
  Next: LongWord;
  Distinct: LongWord;
begin
  Count := 0;
  if not ReadLastOrphan(Volume, InodeNumber) or
     not ExtRead(Volume, SuperblockOffset, 4, @InodesCount) then
    Exit(StatusIoError);
  Result := StatusSuccess;
  { A damaged list (a loop, reserved inodes or numbers out of range)
    ends where it goes wrong; e2fsck can sort out the rest. }
  Distinct := CountDistinctOrphans(Volume, InodesCount, InodeNumber);
  while (Count < Distinct) and IsOrphanNumber(PExtVolume(Volume^.DriverData), InodesCount, InodeNumber) do
  begin
    Result := LoadOrphan(Volume, InodeNumber, Node);
    if Result <> StatusSuccess then
      Break;
    Next := InodeRecord(Node)^.DeletionTime;
    SettleOrphan(Node);
    FreeKernelMemory(Node);
    Inc(Count);
    InodeNumber := Next;
  end;
  if (Count > 0) or (InodeNumber <> 0) then
    Result := WriteLastOrphan(Volume, 0);
end;

end.
