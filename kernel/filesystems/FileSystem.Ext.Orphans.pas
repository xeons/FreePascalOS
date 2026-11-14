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

function ProcessOrphans(Volume: PVolume; out Count: LongWord): TFileSystemStatus;
var
  InodesCount: LongWord;
  InodeNumber: LongWord;
  Node: PExtNode;
  Next: LongWord;
begin
  Count := 0;
  if not ReadLastOrphan(Volume, InodeNumber) or
     not ExtRead(Volume, SuperblockOffset, 4, @InodesCount) then
    Exit(StatusIoError);
  Result := StatusSuccess;
  { A damaged list (a loop, or numbers out of range) ends where it goes
    wrong; e2fsck can sort out the rest. }
  while (InodeNumber <> 0) and (InodeNumber <= InodesCount) and (Count < InodesCount) do
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
  if Count > 0 then
    Result := WriteLastOrphan(Volume, 0);
end;

end.
