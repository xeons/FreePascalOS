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
  Files and folders of a memory volume (tmpfs).

  Each file, folder, symbolic link or named pipe is a TMemoryInode: its
  information (kind, mode, owner, times to the nanosecond, the time it
  was made), its contents (FileSystem.Memory.Storage), a link's target,
  and for a folder the list of its entries (name and inode), in the
  order they were made; a folder's size counts its entries (40 bytes and
  20 more per entry, as Linux's tmpfs shows). Every entry has a serial number that only ever
  grows, which a listing's cursor holds, so names made or removed
  during a listing do not throw it off.

  An inode lives while it has a name or the VFS holds a node for it
  (NodeCount: the nodes handed out and not released); then its pages,
  entries and the record go back. The volume keeps all of its inodes on
  a list, so unmounting frees whatever is left.
}
unit FileSystem.Memory.Nodes;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  FileSystem.Types,
  FileSystem.Memory.Storage;

type
  PMemoryInode = ^TMemoryInode;

  PMemoryEntry = ^TMemoryEntry;
  TMemoryEntry = record
    Next: PMemoryEntry;
    Inode: PMemoryInode;
    Serial: QWord;
    Name: PChar;
  end;

  TMemoryInode = record
    { On the volume's list of inodes. }
    VolumeLink: TListEntry;
    Information: TNodeInformation;
    Storage: TFileStorage;
    LinkTarget: PChar;
    FirstEntry: PMemoryEntry;
    LastEntry: PMemoryEntry;
    EntryCount: QWord;
    { Nodes handed to the VFS and not released yet. }
    NodeCount: LongInt;
  end;

  PMemoryVolume = ^TMemoryVolume;
  TMemoryVolume = record
    Inodes: TListEntry;
    Root: PMemoryInode;
    NextNodeNumber: QWord;
    NextSerial: QWord;
    Budget: TStorageBudget;
    InodeCount: QWord;
  end;

  { The node the VFS sees: a TNode followed by its inode. }
  PMemoryNode = ^TMemoryNode;
  TMemoryNode = record
    Common: TNode;
    Inode: PMemoryInode;
  end;

{ A new inode of Kind, numbered and stamped now, on the volume's list. }
function CreateInode(Data: PMemoryVolume; Kind: TNodeKind): PMemoryInode;
{ Frees the inode, its storage and its entries (not the inodes they
  name). }
procedure DestroyInode(Data: PMemoryVolume; Inode: PMemoryInode);

{ The entry named Name in Directory, or nil. }
function FindEntry(Directory: PMemoryInode; Name: PChar): PMemoryEntry;
function AddEntry(Data: PMemoryVolume; Directory: PMemoryInode; Name: PChar; Inode: PMemoryInode): Boolean;
{ Takes the entry naming Inode as Name out of Directory. }
procedure RemoveEntry(Directory: PMemoryInode; Name: PChar);
{ The first entry with a serial above Serial, or nil. }
function EntryAfter(Directory: PMemoryInode; Serial: QWord): PMemoryEntry;

{ Stamps times: Modified also sets the modification time; the change
  time is always set. }
procedure StampInode(Inode: PMemoryInode; Modified: Boolean);
procedure SetAllocatedBytes(Inode: PMemoryInode);

{ A node for the VFS naming Inode. }
function CreateNodeFor(Volume: PVolume; Inode: PMemoryInode): PNode;
{ The node's copy of the inode's information, after a change. }
procedure RefreshNode(Node: PNode);
function InodeOf(Node: PNode): PMemoryInode;
function MemoryVolumeOf(Volume: PVolume): PMemoryVolume;

{ Frees Inode if nothing names it and no node holds it. }
procedure FreeInodeIfUnused(Data: PMemoryVolume; Inode: PMemoryInode);
function InodeFromVolumeLink(Entry: PListEntry): PMemoryInode;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Memory.Layout,
  Kernel.WallClock;

const
  { What a folder's size shows. }
  EmptyDirectorySize = 40;
  DirectoryEntrySize = 20;

function InodeFromVolumeLink(Entry: PListEntry): PMemoryInode;
begin
  Result := PMemoryInode(ContainingRecord(Entry, FieldOffset(PMemoryInode(nil)^.VolumeLink)));
end;

procedure StampInode(Inode: PMemoryInode; Modified: Boolean);
var
  Now: Int64;
  Seconds: Int64;
  Nanoseconds: LongWord;
begin
  Now := WallClockNanoseconds;
  Seconds := Now div 1000000000;
  Nanoseconds := LongWord(Now mod 1000000000);
  Inode^.Information.ChangeTime := Seconds;
  Inode^.Information.ChangeNanoseconds := Nanoseconds;
  if Modified then
  begin
    Inode^.Information.ModificationTime := Seconds;
    Inode^.Information.ModificationNanoseconds := Nanoseconds;
  end;
end;

procedure SetDirectorySize(Directory: PMemoryInode);
begin
  Directory^.Information.SizeInBytes := EmptyDirectorySize + Directory^.EntryCount * DirectoryEntrySize;
end;

procedure SetAllocatedBytes(Inode: PMemoryInode);
begin
  Inode^.Information.AllocatedBytes := Inode^.Storage.PageCount * PageSize;
end;

function CreateInode(Data: PMemoryVolume; Kind: TNodeKind): PMemoryInode;
begin
  Result := PMemoryInode(AllocateZeroedKernelMemory(SizeOf(TMemoryInode)));
  if Result = nil then
    Exit;
  Result^.Information.Kind := Kind;
  Result^.Information.NodeNumber := Data^.NextNodeNumber;
  Inc(Data^.NextNodeNumber);
  case Kind of
    NodeKindDirectory:
      begin
        Result^.Information.Mode := $1ED; { rwxr-xr-x }
        Result^.Information.LinkCount := 2;
        SetDirectorySize(Result);
      end;
    NodeKindSymbolicLink:
      begin
        Result^.Information.Mode := $1FF;
        Result^.Information.LinkCount := 1;
      end;
  else
    begin
      Result^.Information.Mode := $1A4; { rw-r--r-- }
      Result^.Information.LinkCount := 1;
    end;
  end;
  StampInode(Result, True);
  Result^.Information.AccessTime := Result^.Information.ModificationTime;
  Result^.Information.AccessNanoseconds := Result^.Information.ModificationNanoseconds;
  Result^.Information.BirthTime := Result^.Information.ModificationTime;
  Result^.Information.BirthNanoseconds := Result^.Information.ModificationNanoseconds;
  InsertAtTail(Data^.Inodes, @Result^.VolumeLink);
  Inc(Data^.InodeCount);
end;

procedure DestroyInode(Data: PMemoryVolume; Inode: PMemoryInode);
var
  Entry: PMemoryEntry;
  Next: PMemoryEntry;
begin
  FreeStorage(Inode^.Storage, @Data^.Budget);
  FreeKernelMemory(Inode^.LinkTarget);
  Entry := Inode^.FirstEntry;
  while Entry <> nil do
  begin
    Next := Entry^.Next;
    FreeKernelMemory(Entry^.Name);
    FreeKernelMemory(Entry);
    Entry := Next;
  end;
  RemoveListEntry(@Inode^.VolumeLink);
  Dec(Data^.InodeCount);
  FreeKernelMemory(Inode);
end;

procedure FreeInodeIfUnused(Data: PMemoryVolume; Inode: PMemoryInode);
begin
  if (Inode = Data^.Root) or (Inode^.NodeCount > 0) then
    Exit;
  if (Inode^.Information.Kind = NodeKindDirectory) and (Inode^.Information.LinkCount > 1) then
    Exit;
  if (Inode^.Information.Kind <> NodeKindDirectory) and (Inode^.Information.LinkCount > 0) then
    Exit;
  DestroyInode(Data, Inode);
end;

function FindEntry(Directory: PMemoryInode; Name: PChar): PMemoryEntry;
begin
  Result := Directory^.FirstEntry;
  while (Result <> nil) and not TextIsEqual(Result^.Name, Name) do
    Result := Result^.Next;
end;

function AddEntry(Data: PMemoryVolume; Directory: PMemoryInode; Name: PChar; Inode: PMemoryInode): Boolean;
var
  Entry: PMemoryEntry;
  NameLength: PtrUInt;
begin
  Entry := PMemoryEntry(AllocateZeroedKernelMemory(SizeOf(TMemoryEntry)));
  NameLength := TextLength(Name);
  if Entry <> nil then
    Entry^.Name := PChar(AllocateKernelMemory(NameLength + 1));
  if (Entry = nil) or (Entry^.Name = nil) then
  begin
    FreeKernelMemory(Entry);
    Exit(False);
  end;
  CopyText(Entry^.Name, Name, NameLength + 1);
  Entry^.Inode := Inode;
  Inc(Data^.NextSerial);
  Entry^.Serial := Data^.NextSerial;
  if Directory^.LastEntry = nil then
    Directory^.FirstEntry := Entry
  else
    Directory^.LastEntry^.Next := Entry;
  Directory^.LastEntry := Entry;
  Inc(Directory^.EntryCount);
  SetDirectorySize(Directory);
  Result := True;
end;

procedure RemoveEntry(Directory: PMemoryInode; Name: PChar);
var
  Entry: PMemoryEntry;
  Previous: PMemoryEntry;
begin
  Previous := nil;
  Entry := Directory^.FirstEntry;
  while (Entry <> nil) and not TextIsEqual(Entry^.Name, Name) do
  begin
    Previous := Entry;
    Entry := Entry^.Next;
  end;
  if Entry = nil then
    Exit;
  if Previous = nil then
    Directory^.FirstEntry := Entry^.Next
  else
    Previous^.Next := Entry^.Next;
  if Directory^.LastEntry = Entry then
    Directory^.LastEntry := Previous;
  Dec(Directory^.EntryCount);
  SetDirectorySize(Directory);
  FreeKernelMemory(Entry^.Name);
  FreeKernelMemory(Entry);
end;

function EntryAfter(Directory: PMemoryInode; Serial: QWord): PMemoryEntry;
begin
  Result := Directory^.FirstEntry;
  while (Result <> nil) and (Result^.Serial <= Serial) do
    Result := Result^.Next;
end;

function CreateNodeFor(Volume: PVolume; Inode: PMemoryInode): PNode;
var
  Node: PMemoryNode;
begin
  Node := PMemoryNode(AllocateZeroedKernelMemory(SizeOf(TMemoryNode)));
  if Node = nil then
    Exit(nil);
  Node^.Common.Volume := Volume;
  Node^.Inode := Inode;
  Node^.Common.Information := Inode^.Information;
  Inc(Inode^.NodeCount);
  Result := @Node^.Common;
end;

procedure RefreshNode(Node: PNode);
var
  Inode: PMemoryInode;
begin
  Inode := InodeOf(Node);
  SetAllocatedBytes(Inode);
  Node^.Information := Inode^.Information;
end;

function InodeOf(Node: PNode): PMemoryInode;
begin
  Result := PMemoryNode(Node)^.Inode;
end;

function MemoryVolumeOf(Volume: PVolume): PMemoryVolume;
begin
  Result := PMemoryVolume(Volume^.DriverData);
end;

end.
