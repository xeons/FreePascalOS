{
  Common types of the file system layer.

  The virtual file system (VFS) sits between callers, who work with paths
  and file objects, and file system drivers, which understand one on-disk
  format each. A driver describes itself with a TFileSystemDriver record
  of routines; the VFS calls those routines with nodes and volumes.

  Nodes
    A node is a file, directory or symbolic link on a mounted volume. A
    driver allocates nodes in Lookup (and for the root at mount time) and
    frees them in ReleaseNode. Drivers usually allocate a larger record
    that starts with a TNode and holds format specific data after it.

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
  Io.BlockDevice;

const
  { A 255 character name can take up to three bytes per character in
    UTF-8; one more byte for the terminator. }
  MaximumNameBytes = 768;

  VolumeNameLength = 32;
  FileSystemTypeNameLength = 16;
  VolumeLabelLength = 64;

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
    StatusReadOnly
  );

  TNodeKind = (
    NodeKindFile,
    NodeKindDirectory,
    NodeKindSymbolicLink,
    NodeKindOther
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
    ModificationTime: TUnixTime;
  end;

  PVolume = ^TVolume;
  PNode = ^TNode;
  PFileSystemDriver = ^TFileSystemDriver;

  TNode = record
    Volume: PVolume;
    Information: TNodeInformation;
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
  end;

function FileSystemStatusText(Status: TFileSystemStatus): PChar;
function NodeKindText(Kind: TNodeKind): PChar;

{ Reads ByteCount bytes at ByteOffset of the volume's device through the
  block cache. }
function VolumeRead(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;

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
  else
    Result := 'other';
  end;
end;

function VolumeRead(Volume: PVolume; ByteOffset: QWord; ByteCount: QWord;
  Buffer: Pointer): Boolean;
begin
  Result := CachedRead(Volume^.Device, ByteOffset, ByteCount, Buffer);
end;

end.
