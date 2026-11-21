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
  Common types of the file system layer.

  The virtual file system (VFS) sits between callers, who work with paths
  and file objects, and file system drivers, which understand one on-disk
  format each. A driver describes itself with a TFileSystemDriver record
  of routines; the VFS calls those routines with nodes and volumes.

  Nodes
    A node is a file, directory or symbolic link on a mounted volume. A
    driver allocates nodes in Lookup and CreateNode (and for the root at
    mount time) and frees them in ReleaseNode. Drivers usually allocate a
    larger record that starts with a TNode and holds format specific data
    after it.

    The VFS keeps one node per file in use (the node cache) and counts
    references to it, so every open of a file shares the same node. A
    driver must therefore give each node a NodeNumber that identifies the
    file uniquely within the volume for as long as the node exists, and
    update it if a rename changes the identity.

  Writing
    The write routines are optional; a driver without them only mounts
    read-only. The VFS calls every driver routine with the volume's lock
    held, so drivers need no locking of their own.

  Names
    Names passed to and returned by drivers are UTF-8, without a path
    separator. Whether lookups ignore case is up to the driver (FAT and
    exFAT do, ext does not).

  Status
    Every driver routine reports a TFileSystemStatus.
}
unit FileSystem.Types;

{$mode objfpc}

interface

uses
  Runtime.Time,
  Runtime.LinkedList,
  Kernel.Mutex,
  Io.BlockDevice,
  FileSystem.MountOptions;

const
  { A 255 character name can take up to three bytes per character in
    UTF-8; one more byte for the terminator. }
  MaximumNameBytes = 768;

  VolumeNameLength = 32;
  FileSystemTypeNameLength = 16;
  VolumeLabelLength = 64;

const
  AttributeChangeMode = $01;
  AttributeChangeOwner = $02;
  AttributeChangeGroup = $04;
  AttributeChangeModificationTime = $08;
  AttributeChangeAccessTime = $10;

  { TNodeInformation.VolumeFlags }
  VolumeFlagNoExecute = $01;
  VolumeFlagNoSetId = $02;

type
  TFileSystemStatus = (
    StatusSuccess,
    StatusNotFound,
    StatusNotADirectory,
    StatusIsADirectory,
    StatusEndOfDirectory,
    StatusInvalidPath,
    StatusNameTooLong,
    StatusTooManyLinks,
    StatusIoError,
    StatusCorrupted,
    StatusUnsupported,
    StatusOutOfMemory,
    StatusReadOnly,
    StatusAlreadyExists,
    StatusDirectoryNotEmpty,
    StatusNoSpace,
    StatusInUse,
    StatusInvalidName,
    StatusAccessDenied,
    { The volume went away (its disk was unplugged, or it was
      unmounted). }
    StatusVolumeGone,
    { The operation would join two volumes (a rename or a hard link
      from one to another). }
    StatusCrossesVolumes
  );

  { The advisory lock an open file holds (FileSystem.Locks). }
  TFileLockKind = (LockKindNone, LockKindShared, LockKindExclusive);

  TNodeKind = (
    NodeKindFile,
    NodeKindDirectory,
    NodeKindSymbolicLink,
    NodeKindOther,
    { A named pipe. }
    NodeKindFifo
  );

  TFileName = array[0..MaximumNameBytes - 1] of Char;

  TNodeInformation = record
    Kind: TNodeKind;
    SizeInBytes: QWord;
    { Inode number, first cluster or similar; unique within a volume. }
    NodeNumber: QWord;
    LinkCount: LongWord;
    { Unix style permission bits where the format has them, else zero. }
    Mode: LongWord;
    { Numeric owner and group; zero on formats without them. }
    OwnerId: LongWord;
    GroupId: LongWord;
    ModificationTime: TUnixTime;
    AccessTime: TUnixTime;
    { When the node's information last changed. }
    ChangeTime: TUnixTime;
    { When the node was made; 0 where the format does not keep it. }
    BirthTime: TUnixTime;
    { The parts of a second of the four times, where the format keeps
      them (0 otherwise). }
    ModificationNanoseconds: LongWord;
    AccessNanoseconds: LongWord;
    ChangeNanoseconds: LongWord;
    BirthNanoseconds: LongWord;
    { Space the node takes up on the volume. }
    AllocatedBytes: QWord;
    { The volume's Number: filled in when the information is described
      to a caller (drivers leave it alone). }
    VolumeNumber: LongWord;
    { The volume's mount options that matter to callers
      (VolumeFlagNoExecute, VolumeFlagNoSetId): filled in like
      VolumeNumber. }
    VolumeFlags: LongWord;
  end;

  { Which fields of TAttributeChanges apply. }
  TAttributeChanges = record
    Fields: LongWord;
    Mode: LongWord;
    OwnerId: LongWord;
    GroupId: LongWord;
    ModificationTime: TUnixTime;
    AccessTime: TUnixTime;
  end;

  PVolume = ^TVolume;
  PNode = ^TNode;
  PFileSystemDriver = ^TFileSystemDriver;

  TNode = record
    Volume: PVolume;
    Information: TNodeInformation;
    { Owned by the VFS node cache; drivers leave these alone. }
    ReferenceCount: LongInt;
    CacheLink: TListEntry;
    { Set by RemoveOpenNode when the node lost its last name while open:
      its storage is freed (FinishRemoval) when the last reference goes. }
    RemovalPending: Boolean;
    { Advisory locks held on the file (FileSystem.Locks), nil while
      nobody holds or waits for one. Drivers hand nodes out zeroed. }
    LockState: Pointer;
    { On formats without owners (TFileSystemDriver.HasNoOwners): the
      driver reported the read-only attribute, which the permissions
      made up from the mount options keep (FileSystem.Security). }
    HasReadOnlyAttribute: Boolean;
  end;

  { Position within a directory listing. Its meaning belongs to the
    driver; the VFS only zeroes it before the first call. }
  TDirectoryCursor = record
    Position: QWord;
    Extra: QWord;
  end;

  TDirectoryEntry = record
    Name: TFileName;
    Kind: TNodeKind;
    NodeNumber: QWord;
  end;

  TFileSystemDriver = record
    Name: PChar;

    { Returns True if Device holds this file system. Must not change
      anything on the device. }
    Probe: function(Device: PBlockDevice): Boolean;

    { Fills in Volume^.RootNode, DriverData, TypeName and Label. }
    Mount: function(Volume: PVolume): TFileSystemStatus;
    Unmount: procedure(Volume: PVolume);

    Lookup: function(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;

    { Returns the next entry and advances Cursor, or StatusEndOfDirectory.
      "." and ".." are not reported. }
    ReadDirectory: function(Directory: PNode; var Cursor: TDirectoryCursor;
      out Entry: TDirectoryEntry): TFileSystemStatus;

    { Reads up to ByteCount bytes at Offset. Reading at or past the end of
      the file succeeds with BytesRead = 0. }
    ReadFile: function(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
      out BytesRead: QWord): TFileSystemStatus;

    { Optional: copies a symbolic link's target into Target. }
    ReadSymbolicLink: function(Node: PNode; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;

    ReleaseNode: procedure(Node: PNode);

    { --- Optional write support --- }

    { Creates a file, directory or symbolic link (with target LinkTarget)
      named Name in Directory. The VFS has checked that Name is free. }
    CreateNode: function(Directory: PNode; Name: PChar; Kind: TNodeKind; LinkTarget: PChar;
      out Created: PNode): TFileSystemStatus;

    { Writes ByteCount bytes at Offset, growing the file as needed. A gap
      between the old end of the file and Offset reads back as zeros. }
    WriteFile: function(Node: PNode; Offset: QWord; Buffer: Pointer; ByteCount: QWord;
      out BytesWritten: QWord): TFileSystemStatus;

    { Shortens (releasing space) or lengthens (with zeros) a file. }
    SetFileSize: function(Node: PNode; NewSize: QWord): TFileSystemStatus;

    { Removes Node, which is named Name in Directory. Directories must be
      empty. The VFS guarantees nobody else is using Node. }
    RemoveNode: function(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;

    { Moves Node (named SourceName in SourceDirectory) to TargetName in
      TargetDirectory. The VFS has checked that TargetName is free and
      that a directory is not moved into itself. }
    RenameNode: function(SourceDirectory: PNode; SourceName: PChar; Node: PNode;
      TargetDirectory: PNode; TargetName: PChar): TFileSystemStatus;

    { Brings on-disk summary information (free space counters and the
      like) up to date. }
    Sync: function(Volume: PVolume): TFileSystemStatus;

    { Optional: changes permissions, owner, group or times of Node. A
      format that cannot store a requested change returns
      StatusUnsupported. }
    SetAttributes: function(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;

    { Optional: gives Node (not a directory) a further name, Name in
      Directory. The VFS has checked that Name is free. }
    CreateHardLink: function(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;

    { Optional: the space available for new data. }
    GetFreeSpace: function(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;

    { Optional: removes the name Name of Node (not a directory), which is
      still open. Reading and writing it go on working; if that was its
      last name the driver sets Node^.RemovalPending and keeps the
      storage until FinishRemoval. Without it, open files cannot be
      removed (and not replaced by a rename). }
    RemoveOpenNode: function(Directory: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
    { Frees the storage of a node removed while open, when it is closed
      for the last time (before ReleaseNode). }
    FinishRemoval: function(Node: PNode): TFileSystemStatus;

    { Optional: the driver calls between these reach the disk as one
      change (journaled formats), such as removing a file and renaming
      another onto its name. }
    BeginAtomicChange: procedure(Volume: PVolume);
    EndAtomicChange: function(Volume: PVolume): TFileSystemStatus;

    { The format has no owners and no permission bits (FAT, exFAT): the
      VFS makes them up from the mount options (uid, gid, umask, fmask,
      dmask), keeping the driver's read-only attribute. }
    HasNoOwners: Boolean;
    { The format lives in memory, not on a block device (tmpfs): its
      volumes are made by FileSystem.Volumes.MountMemoryVolume, never
      probed. }
    IsVirtual: Boolean;
  end;

  TVolume = record
    Name: array[0..VolumeNameLength - 1] of Char;
    Device: PBlockDevice;
    Driver: PFileSystemDriver;
    { Detected format, for example 'fat32' or 'ext4'. }
    TypeName: array[0..FileSystemTypeNameLength - 1] of Char;
    VolumeLabel: array[0..VolumeLabelLength - 1] of Char;
    RootNode: PNode;
    DriverData: Pointer;
    TotalBytes: QWord;
    IsReadOnly: Boolean;
    { Serializes every driver call on this volume. }
    Lock: TMutex;
    { Nodes currently in use, see "Nodes" above. }
    NodeCache: TListEntry;
    { Set (under Lock) when the volume went away: every operation on it
      fails with StatusVolumeGone from then on. The record itself is
      kept for good, since open files and other kernel tables may still
      name it; the driver's data is given back (Unmount) once the last
      node other than the root is released, which IsUnmounted records. }
    IsGone: Boolean;
    IsUnmounted: Boolean;
    { Nodes in the node cache besides the root, and nodes removed while
      open (out of the cache, still held). }
    NodesInUse: LongInt;
    { Unique since the system started (1, 2, ...): what file information
      reports as the volume a node is on. }
    Number: LongWord;
    { How it was mounted (FileSystem.MountOptions): read-only, noexec,
      nosuid, discard, and the owners and masks of formats without
      owners. }
    Options: TMountOptions;
    { The driver and device allow writing: a volume mounted read-only on
      request may be made writable again. }
    CanWrite: Boolean;
    { How many volumes are mounted on directories of this one
      (FileSystem.Mounts); path resolution only looks for mount points
      while there are any. Changed with Lock held. }
    MountsOnVolume: LongInt;
    { The mount record when the volume is mounted at a directory of
      another one (FileSystem.Mounts), else nil. }
    MountRecord: Pointer;
  end;

function FileSystemStatusText(Status: TFileSystemStatus): PChar;
function NodeKindText(Kind: TNodeKind): PChar;

{ Reads ByteCount bytes at ByteOffset of the volume's device through the
  block cache. }
function VolumeRead(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
function VolumeWrite(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
function VolumeWriteZeros(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord): Boolean;

function DriverSupportsWriting(Driver: PFileSystemDriver): Boolean;

implementation

uses
  Io.BlockCache;

function FileSystemStatusText(Status: TFileSystemStatus): PChar;
begin
  case Status of
    StatusSuccess: Result := 'success';
    StatusNotFound: Result := 'not found';
    StatusNotADirectory: Result := 'not a directory';
    StatusIsADirectory: Result := 'is a directory';
    StatusEndOfDirectory: Result := 'end of directory';
    StatusInvalidPath: Result := 'invalid path';
    StatusNameTooLong: Result := 'name too long';
    StatusTooManyLinks: Result := 'too many symbolic links';
    StatusIoError: Result := 'I/O error';
    StatusCorrupted: Result := 'file system is corrupted';
    StatusUnsupported: Result := 'unsupported';
    StatusOutOfMemory: Result := 'out of memory';
    StatusReadOnly: Result := 'read-only';
    StatusAlreadyExists: Result := 'already exists';
    StatusDirectoryNotEmpty: Result := 'directory not empty';
    StatusNoSpace: Result := 'no space left on volume';
    StatusInUse: Result := 'in use';
    StatusInvalidName: Result := 'invalid name';
    StatusAccessDenied: Result := 'access denied';
    StatusVolumeGone: Result := 'volume gone';
    StatusCrossesVolumes: Result := 'crosses volumes';
  else
    Result := 'unknown status';
  end;
end;

function NodeKindText(Kind: TNodeKind): PChar;
begin
  case Kind of
    NodeKindFile: Result := 'file';
    NodeKindDirectory: Result := 'directory';
    NodeKindSymbolicLink: Result := 'symlink';
    NodeKindFifo: Result := 'fifo';
  else
    Result := 'other';
  end;
end;

function VolumeRead(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
begin
  Result := CachedRead(Volume^.Device, ByteOffset, ByteCount, Buffer);
end;

function VolumeWrite(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
begin
  Result := CachedWrite(Volume^.Device, ByteOffset, ByteCount, Buffer);
end;

function VolumeWriteZeros(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord): Boolean;
begin
  Result := CachedWriteZeros(Volume^.Device, ByteOffset, ByteCount);
end;

function DriverSupportsWriting(Driver: PFileSystemDriver): Boolean;
begin
  Result := Assigned(Driver^.CreateNode) and Assigned(Driver^.WriteFile) and
    Assigned(Driver^.SetFileSize) and Assigned(Driver^.RemoveNode) and
    Assigned(Driver^.RenameNode) and Assigned(Driver^.Sync);
end;

end.
