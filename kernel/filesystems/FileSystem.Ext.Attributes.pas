{
  Attributes, hard links and free space for ext2, ext3 and ext4.

  Owner and group are stored as 32-bit ids split over two 16-bit inode
  fields. Times are stored in seconds; on inodes large enough to have
  the extra time fields, their nanoseconds and epoch bits are cleared,
  which is correct for every time up to 2038.
}
unit FileSystem.Ext.Attributes;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function ExtSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
function ExtCreateHardLink(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
function ExtGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;

implementation

uses
  Kernel.Clock,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume,
  FileSystem.Ext.Directories,
  FileSystem.Ext.Write;

const
  { Offsets of the extra time fields within a large inode, and the
    extra size that has to be present for each. }
  InodeChangeTimeExtraOffset = $84;
  InodeModificationTimeExtraOffset = $88;
  InodeAccessTimeExtraOffset = $8C;
  { ext4 counts more links than this as "many" (1); stay below it. }
  MaximumLinkCount = 65000;

{ Clears an extra time field if this inode has it. }
procedure ClearExtraTime(Node: PExtNode; FieldOffset: LongWord);
var
  Ext: PExtVolume;
  ExtraSize: Word;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  if Ext^.InodeSize <= GoodOldInodeSize then
    Exit;
  ExtraSize := PWord(@Node^.InodeBytes[InodeExtraSizeOffset])^;
  if GoodOldInodeSize + ExtraSize >= FieldOffset + 4 then
    PLongWord(@Node^.InodeBytes[FieldOffset])^ := 0;
end;

function ExtSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
var
  ExtNode: PExtNode;
  Inode: PInode;
begin
  ExtNode := PExtNode(Node);
  Inode := InodeRecord(ExtNode);

  if (Changes.Fields and AttributeChangeMode) <> 0 then
    Inode^.Mode := (Inode^.Mode and ModeTypeMask) or (Changes.Mode and ModePermissionMask);
  if (Changes.Fields and AttributeChangeOwner) <> 0 then
  begin
    Inode^.UserId := Word(Changes.OwnerId and $FFFF);
    Inode^.UserIdHigh := Word(Changes.OwnerId shr 16);
  end;
  if (Changes.Fields and AttributeChangeGroup) <> 0 then
  begin
    Inode^.GroupId := Word(Changes.GroupId and $FFFF);
    Inode^.GroupIdHigh := Word(Changes.GroupId shr 16);
  end;
  if (Changes.Fields and AttributeChangeModificationTime) <> 0 then
  begin
    Inode^.ModificationTime := LongWord(Changes.ModificationTime);
    ClearExtraTime(ExtNode, InodeModificationTimeExtraOffset);
  end;
  if (Changes.Fields and AttributeChangeAccessTime) <> 0 then
  begin
    Inode^.AccessTime := LongWord(Changes.AccessTime);
    ClearExtraTime(ExtNode, InodeAccessTimeExtraOffset);
  end;

  Inode^.ChangeTime := LongWord(CurrentWallClockTime);
  ClearExtraTime(ExtNode, InodeChangeTimeExtraOffset);
  RefreshNodeInformation(ExtNode);
  Result := WriteNodeInode(ExtNode);
end;

function ExtCreateHardLink(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
var
  Parent: PExtNode;
  ExtNode: PExtNode;
  Now: LongWord;
begin
  Parent := PExtNode(Directory);
  ExtNode := PExtNode(Node);
  if InodeRecord(ExtNode)^.LinksCount >= MaximumLinkCount then
    Exit(StatusTooManyLinks);
  Result := DirectoryIsModifiable(Parent);
  if Result <> StatusSuccess then
    Exit;

  Result := AddDirectoryEntry(Parent, Name, ExtNode^.InodeNumber, FileTypeOf(Node^.Information.Kind));
  if Result <> StatusSuccess then
    Exit;

  Now := LongWord(CurrentWallClockTime);
  Inc(InodeRecord(ExtNode)^.LinksCount);
  InodeRecord(ExtNode)^.ChangeTime := Now;
  RefreshNodeInformation(ExtNode);
  Result := WriteNodeInode(ExtNode);
  if Result <> StatusSuccess then
    Exit;

  InodeRecord(Parent)^.ChangeTime := Now;
  InodeRecord(Parent)^.ModificationTime := Now;
  RefreshNodeInformation(Parent);
  Result := WriteNodeInode(Parent);
end;

function ExtGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  FreeBytes := Ext^.FreeBlockCount * Ext^.BlockSize;
  Result := StatusSuccess;
end;

end.
