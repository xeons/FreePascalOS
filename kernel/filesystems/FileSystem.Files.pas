{
  Paths, open files and file operations.

  Paths are absolute and use '/' as separator. The first component names
  a mounted volume and the rest is resolved by that volume's driver:

    /                       the root: lists the mounted volumes
    /disk1p2                root directory of volume disk1p2
    /disk1p2/docs/readme    a file on it

  "." and ".." are resolved textually before the lookup starts. Symbolic
  links are followed (up to MaximumSymbolicLinkDepth deep); an absolute
  link target is taken relative to the root of the link's own volume.

  Node cache
    Every node handed out by a driver passes through InternNode, which
    makes sure there is only one node per file (keyed by its NodeNumber)
    and counts references to it. Two opens of the same file therefore see
    each other's writes and size changes. A node is given back to its
    driver when its last reference is released.

  Locking
    Every operation holds the lock of the volume it works on for its whole
    duration, which also protects that volume's node cache.

  An open file is an object of type "File" holding a reference to its node
  and the current position. Closing it drops the reference.
}
unit FileSystem.Files;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  FileSystem.Types;

const
  MaximumPathBytes = 1024;
  MaximumSymbolicLinkDepth = 8;
  MaximumNameLengthInBytes = 255;

  { Open flags. }
  OpenForReading = $01;
  OpenForWriting = $02;
  OpenCreate = $04;     { create the file if it does not exist }
  OpenExclusive = $08;  { with OpenCreate: fail if the file exists }
  OpenTruncate = $10;   { discard existing contents }
  OpenAppend = $20;     { every write goes to the end of the file }

type
  POpenFile = ^TOpenFile;
  TOpenFile = record
    { nil for the root directory, which lists volumes. }
    Volume: PVolume;
    Node: PNode;
    Flags: LongWord;
    Position: QWord;
    Cursor: TDirectoryCursor;
  end;

procedure InitializeFileObjects;

{ Called by the volume manager after a successful mount. }
procedure RegisterRootNode(Volume: PVolume);

function OpenFile(Path: PChar; Flags: LongWord; out OpenedFile: POpenFile): TFileSystemStatus;
{ Opens for reading only. }
function OpenPath(Path: PChar; out OpenedFile: POpenFile): TFileSystemStatus;
procedure CloseFile(OpenedFile: POpenFile);

function ReadFromFile(OpenedFile: POpenFile; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
function WriteToFile(OpenedFile: POpenFile; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
function ChangeFileSize(OpenedFile: POpenFile; NewSize: QWord): TFileSystemStatus;
procedure SetFilePosition(OpenedFile: POpenFile; Position: QWord);
function GetFilePosition(OpenedFile: POpenFile): QWord;

function ReadDirectoryEntry(OpenedFile: POpenFile; out Entry: TDirectoryEntry): TFileSystemStatus;

function GetFileInformation(OpenedFile: POpenFile; out Information: TNodeInformation): TFileSystemStatus;
function GetPathInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;
{ Like GetPathInformation, but describes a final symbolic link itself. }
function GetLinkInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;
{ Copies the target of the symbolic link at Path (not followed). }
function ReadSymbolicLinkTarget(Path: PChar; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;

function CreateDirectory(Path: PChar): TFileSystemStatus;
function CreateSymbolicLink(Path: PChar; Target: PChar): TFileSystemStatus;
{ Removes a file, symbolic link or empty directory. }
function RemovePath(Path: PChar): TFileSystemStatus;
{ Moves or renames within one volume. The target must not exist. }
function RenamePath(SourcePath: PChar; TargetPath: PChar): TFileSystemStatus;

{ Writes summary information of every writable volume to disk. }
{ Changes permissions, owner, group or times. FollowLinks selects whether
  a final symbolic link is changed or what it points to. }
function SetPathAttributes(Path: PChar; FollowLinks: Boolean;
  const Changes: TAttributeChanges): TFileSystemStatus;

{ Gives the file at ExistingPath the further name NewPath (same volume). }
function CreateHardLink(ExistingPath: PChar; NewPath: PChar): TFileSystemStatus;

{ False if the volume's driver cannot tell. }
function GetVolumeFreeSpace(Volume: PVolume; out FreeBytes: QWord): Boolean;

procedure SyncAllVolumes;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.LinkedList,
  Memory.KernelHeap,
  Objects.Manager,
  FileSystem.Volumes;

const
  MaximumComponents = 128;

type
  { A path split into components. The component texts point into Text,
    where the separators have been replaced by terminators. }
  TSplitPath = record
    Text: array[0..MaximumPathBytes - 1] of Char;
    Components: array[0..MaximumComponents - 1] of PChar;
    ComponentCount: Integer;
  end;
  PSplitPath = ^TSplitPath;

  { A resolved "parent directory plus final name", used by operations
    that create or remove names. }
  TParentAndName = record
    Volume: PVolume;
    Parent: PNode;
    Name: array[0..MaximumNameLengthInBytes] of Char;
    { The volume relative path, normalized, for loop checks in rename. }
    NormalizedPath: array[0..MaximumPathBytes - 1] of Char;
  end;
  PParentAndName = ^TParentAndName;

var
  FileObjectType: TObjectType;

{ --- Node cache ------------------------------------------------------ }

function NodeFromCacheLink(Entry: PListEntry): PNode;
begin
  Result := PNode(ContainingRecord(Entry, FieldOffset(PNode(nil)^.CacheLink)));
end;

{ Returns the cached node for Fresh's file if there is one (releasing
  Fresh), otherwise enters Fresh into the cache. Either way the caller
  owns one reference to the result. }
function InternNode(Volume: PVolume; Fresh: PNode): PNode;
var
  Entry: PListEntry;
  Cached: PNode;
begin
  Entry := Volume^.NodeCache.Next;
  while Entry <> @Volume^.NodeCache do
  begin
    Cached := NodeFromCacheLink(Entry);
    if Cached^.Information.NodeNumber = Fresh^.Information.NodeNumber then
    begin
      Volume^.Driver^.ReleaseNode(Fresh);
      Inc(Cached^.ReferenceCount);
      Exit(Cached);
    end;
    Entry := Entry^.Next;
  end;

  Fresh^.ReferenceCount := 1;
  InsertAtTail(Volume^.NodeCache, @Fresh^.CacheLink);
  Result := Fresh;
end;

procedure ReferenceNode(Node: PNode);
begin
  Inc(Node^.ReferenceCount);
end;

procedure ReleaseNodeReference(Volume: PVolume; Node: PNode);
begin
  if Node = nil then
    Exit;
  Dec(Node^.ReferenceCount);
  if Node^.ReferenceCount <= 0 then
  begin
    RemoveListEntry(@Node^.CacheLink);
    Volume^.Driver^.ReleaseNode(Node);
  end;
end;

procedure RegisterRootNode(Volume: PVolume);
begin
  { The volume itself keeps this reference for as long as it is mounted. }
  Volume^.RootNode^.ReferenceCount := 1;
  InsertAtTail(Volume^.NodeCache, @Volume^.RootNode^.CacheLink);
end;

function LookupAndIntern(Directory: PNode; Name: PChar; out Found: PNode): TFileSystemStatus;
var
  Fresh: PNode;
begin
  Found := nil;
  Result := Directory^.Volume^.Driver^.Lookup(Directory, Name, Fresh);
  if Result = StatusSuccess then
    Found := InternNode(Directory^.Volume, Fresh);
end;

{ --- Path splitting -------------------------------------------------- }

{ Splits Path at '/' and resolves "." and ".." textually. Leading '/'
  characters are ignored, so the result is always relative to some root. }
function SplitPath(Path: PChar; Split: PSplitPath): TFileSystemStatus;
var
  Position: PtrUInt;
  ComponentStart: PChar;
begin
  if TextLength(Path) >= MaximumPathBytes then
    Exit(StatusNameTooLong);
  CopyText(@Split^.Text[0], Path, MaximumPathBytes);
  Split^.ComponentCount := 0;

  Position := 0;
  while Split^.Text[Position] <> #0 do
  begin
    while Split^.Text[Position] = '/' do
    begin
      Split^.Text[Position] := #0;
      Inc(Position);
    end;
    if Split^.Text[Position] = #0 then
      Break;

    ComponentStart := @Split^.Text[Position];
    while (Split^.Text[Position] <> '/') and (Split^.Text[Position] <> #0) do
      Inc(Position);
    if Split^.Text[Position] = '/' then
    begin
      Split^.Text[Position] := #0;
      Inc(Position);
    end;

    if TextIsEqual(ComponentStart, '.') then
      Continue;
    if TextIsEqual(ComponentStart, '..') then
    begin
      if Split^.ComponentCount > 0 then
        Dec(Split^.ComponentCount);
      Continue;
    end;

    if Split^.ComponentCount >= MaximumComponents then
      Exit(StatusNameTooLong);
    Split^.Components[Split^.ComponentCount] := ComponentStart;
    Inc(Split^.ComponentCount);
  end;
  Result := StatusSuccess;
end;

procedure AppendComponent(Destination: PChar; Component: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  if Length + 1 < MaximumPathBytes then
  begin
    Destination[Length] := '/';
    Destination[Length + 1] := #0;
  end;
  Length := TextLength(Destination);
  CopyText(Destination + Length, Component, MaximumPathBytes - Length);
end;

{ --- Resolution within a volume (volume lock held) -------------------- }

function ResolveInVolume(Volume: PVolume; RelativePath: PChar; FollowFinalLink: Boolean;
  Depth: Integer; out Found: PNode): TFileSystemStatus; forward;

{ Builds the path that results from replacing component LinkIndex of
  Split by the link target, and resolves it. }
function FollowLink(Volume: PVolume; LinkNode: PNode; Split: PSplitPath; LinkIndex: Integer;
  FollowFinalLink: Boolean; Depth: Integer; out Found: PNode): TFileSystemStatus;
var
  Target: PChar;
  NewPath: PChar;
  ComponentIndex: Integer;
begin
  Found := nil;
  if Depth >= MaximumSymbolicLinkDepth then
    Exit(StatusTooManyLinks);
  if not Assigned(Volume^.Driver^.ReadSymbolicLink) then
    Exit(StatusUnsupported);

  Target := PChar(AllocateKernelMemory(MaximumPathBytes));
  NewPath := PChar(AllocateKernelMemory(MaximumPathBytes));
  if (Target = nil) or (NewPath = nil) then
  begin
    FreeKernelMemory(Target);
    FreeKernelMemory(NewPath);
    Exit(StatusOutOfMemory);
  end;

  Result := Volume^.Driver^.ReadSymbolicLink(LinkNode, Target, MaximumPathBytes);
  if Result = StatusSuccess then
  begin
    NewPath[0] := #0;
    { A relative target is resolved from the directory holding the link. }
    if Target[0] <> '/' then
    begin
      for ComponentIndex := 0 to LinkIndex - 1 do
        AppendComponent(NewPath, Split^.Components[ComponentIndex]);
    end;
    AppendComponent(NewPath, Target);
    for ComponentIndex := LinkIndex + 1 to Split^.ComponentCount - 1 do
      AppendComponent(NewPath, Split^.Components[ComponentIndex]);

    Result := ResolveInVolume(Volume, NewPath, FollowFinalLink, Depth + 1, Found);
  end;

  FreeKernelMemory(Target);
  FreeKernelMemory(NewPath);
end;

function ResolveInVolume(Volume: PVolume; RelativePath: PChar; FollowFinalLink: Boolean;
  Depth: Integer; out Found: PNode): TFileSystemStatus;
var
  Split: PSplitPath;
  Node: PNode;
  NextNode: PNode;
  ComponentIndex: Integer;
  IsFinalComponent: Boolean;
begin
  Found := nil;
  Split := PSplitPath(AllocateKernelMemory(SizeOf(TSplitPath)));
  if Split = nil then
    Exit(StatusOutOfMemory);

  Result := SplitPath(RelativePath, Split);
  Node := Volume^.RootNode;
  ReferenceNode(Node);
  ComponentIndex := 0;

  while (Result = StatusSuccess) and (ComponentIndex < Split^.ComponentCount) do
  begin
    if Node^.Information.Kind <> NodeKindDirectory then
    begin
      Result := StatusNotADirectory;
      Break;
    end;

    Result := LookupAndIntern(Node, Split^.Components[ComponentIndex], NextNode);
    ReleaseNodeReference(Volume, Node);
    Node := nil;
    if Result <> StatusSuccess then
      Break;

    IsFinalComponent := ComponentIndex = Split^.ComponentCount - 1;
    if (NextNode^.Information.Kind = NodeKindSymbolicLink) and
       ((not IsFinalComponent) or FollowFinalLink) then
    begin
      Result := FollowLink(Volume, NextNode, Split, ComponentIndex, FollowFinalLink, Depth, Node);
      ReleaseNodeReference(Volume, NextNode);
      FreeKernelMemory(Split);
      if Result = StatusSuccess then
        Found := Node;
      Exit;
    end;

    Node := NextNode;
    Inc(ComponentIndex);
  end;

  FreeKernelMemory(Split);
  if Result = StatusSuccess then
    Found := Node
  else
    ReleaseNodeReference(Volume, Node);
end;

{ Splits off the volume name (the first component) of an absolute path.
  Volume is nil for the root itself. RemainingPath points into Path. }
function SelectVolume(Path: PChar; out Volume: PVolume; out RemainingPath: PChar): TFileSystemStatus;
var
  VolumeName: array[0..VolumeNameLength - 1] of Char;
  NameLength: PtrUInt;
begin
  Volume := nil;
  RemainingPath := nil;
  if (Path = nil) or (Path^ <> '/') then
    Exit(StatusInvalidPath);

  while Path^ = '/' do
    Inc(Path);
  if Path^ = #0 then
    Exit(StatusSuccess);

  NameLength := 0;
  while (Path[NameLength] <> '/') and (Path[NameLength] <> #0) do
  begin
    if NameLength + 1 >= VolumeNameLength then
      Exit(StatusNotFound);
    VolumeName[NameLength] := Path[NameLength];
    Inc(NameLength);
  end;
  VolumeName[NameLength] := #0;

  Volume := FindVolumeByName(@VolumeName[0]);
  if Volume = nil then
    Exit(StatusNotFound);
  RemainingPath := Path + NameLength;
  Result := StatusSuccess;
end;

function NameIsValid(Name: PChar): Boolean;
var
  Length: PtrUInt;
begin
  Length := TextLength(Name);
  Result := (Length > 0) and (Length <= MaximumNameLengthInBytes) and
    not TextIsEqual(Name, '.') and not TextIsEqual(Name, '..');
end;

{ Resolves everything but the last component of RemainingPath (with the
  volume lock held). The last component becomes Target^.Name. }
function ResolveParent(Volume: PVolume; RemainingPath: PChar; Target: PParentAndName): TFileSystemStatus;
var
  Split: PSplitPath;
  ParentPath: array[0..MaximumPathBytes - 1] of Char;
  ComponentIndex: Integer;
begin
  Target^.Volume := Volume;
  Target^.Parent := nil;
  Split := PSplitPath(AllocateKernelMemory(SizeOf(TSplitPath)));
  if Split = nil then
    Exit(StatusOutOfMemory);

  Result := SplitPath(RemainingPath, Split);
  if (Result = StatusSuccess) and (Split^.ComponentCount = 0) then
    Result := StatusInvalidPath; { a volume root has no parent }

  if Result = StatusSuccess then
  begin
    ParentPath[0] := #0;
    Target^.NormalizedPath[0] := #0;
    for ComponentIndex := 0 to Split^.ComponentCount - 2 do
      AppendComponent(@ParentPath[0], Split^.Components[ComponentIndex]);
    for ComponentIndex := 0 to Split^.ComponentCount - 1 do
      AppendComponent(@Target^.NormalizedPath[0], Split^.Components[ComponentIndex]);

    if TextLength(Split^.Components[Split^.ComponentCount - 1]) > MaximumNameLengthInBytes then
      Result := StatusNameTooLong
    else
    begin
      CopyText(@Target^.Name[0], Split^.Components[Split^.ComponentCount - 1],
        MaximumNameLengthInBytes + 1);
      if not NameIsValid(@Target^.Name[0]) then
        Result := StatusInvalidName;
    end;
  end;
  FreeKernelMemory(Split);

  if Result <> StatusSuccess then
    Exit;

  Result := ResolveInVolume(Volume, @ParentPath[0], True, 0, Target^.Parent);
  if (Result = StatusSuccess) and (Target^.Parent^.Information.Kind <> NodeKindDirectory) then
  begin
    ReleaseNodeReference(Volume, Target^.Parent);
    Target^.Parent := nil;
    Result := StatusNotADirectory;
  end;
end;

{ --- Open files ------------------------------------------------------ }

procedure DeleteOpenFile(ObjectBody: Pointer);
var
  OpenedFile: POpenFile;
  Volume: PVolume;
begin
  OpenedFile := POpenFile(ObjectBody);
  Volume := OpenedFile^.Volume;
  if Volume <> nil then
  begin
    AcquireMutex(Volume^.Lock);
    ReleaseNodeReference(Volume, OpenedFile^.Node);
    ReleaseMutex(Volume^.Lock);
  end;
end;

procedure InitializeFileObjects;
begin
  RegisterObjectType(FileObjectType, 'File', SizeOf(TOpenFile), @DeleteOpenFile);
end;

function WantsWriteAccess(Flags: LongWord): Boolean;
begin
  Result := (Flags and (OpenForWriting or OpenCreate or OpenTruncate or OpenAppend)) <> 0;
end;

{ Finds or creates the file for OpenFile. Volume lock held. }
function ResolveForOpen(Volume: PVolume; RemainingPath: PChar; Flags: LongWord;
  out Node: PNode): TFileSystemStatus;
var
  Target: PParentAndName;
  Created: PNode;
begin
  Node := nil;
  if (Flags and OpenCreate) = 0 then
    Exit(ResolveInVolume(Volume, RemainingPath, True, 0, Node));

  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if Target = nil then
    Exit(StatusOutOfMemory);

  Result := ResolveParent(Volume, RemainingPath, Target);
  if Result = StatusSuccess then
  begin
    Result := LookupAndIntern(Target^.Parent, @Target^.Name[0], Node);
    if Result = StatusSuccess then
    begin
      if (Flags and OpenExclusive) <> 0 then
      begin
        ReleaseNodeReference(Volume, Node);
        Node := nil;
        Result := StatusAlreadyExists;
      end
      else if Node^.Information.Kind = NodeKindSymbolicLink then
      begin
        { Open what the link points at. }
        ReleaseNodeReference(Volume, Node);
        Node := nil;
        Result := ResolveInVolume(Volume, RemainingPath, True, 0, Node);
      end;
    end
    else if Result = StatusNotFound then
    begin
      Result := Volume^.Driver^.CreateNode(Target^.Parent, @Target^.Name[0], NodeKindFile, nil, Created);
      if Result = StatusSuccess then
        Node := InternNode(Volume, Created);
    end;
    ReleaseNodeReference(Volume, Target^.Parent);
  end;

  FreeKernelMemory(Target);
end;

function OpenFile(Path: PChar; Flags: LongWord; out OpenedFile: POpenFile): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
begin
  OpenedFile := nil;
  Node := nil;
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;

  if Volume = nil then
  begin
    if WantsWriteAccess(Flags) then
      Exit(StatusReadOnly);
  end
  else
  begin
    if WantsWriteAccess(Flags) and Volume^.IsReadOnly then
      Exit(StatusReadOnly);

    AcquireMutex(Volume^.Lock);
    Result := ResolveForOpen(Volume, RemainingPath, Flags, Node);
    if (Result = StatusSuccess) and WantsWriteAccess(Flags) and
       (Node^.Information.Kind = NodeKindDirectory) then
      Result := StatusIsADirectory;
    if (Result = StatusSuccess) and ((Flags and OpenTruncate) <> 0) and
       (Node^.Information.SizeInBytes <> 0) then
      Result := Volume^.Driver^.SetFileSize(Node, 0);
    if (Result <> StatusSuccess) and (Node <> nil) then
    begin
      ReleaseNodeReference(Volume, Node);
      Node := nil;
    end;
    ReleaseMutex(Volume^.Lock);
    if Result <> StatusSuccess then
      Exit;
  end;

  OpenedFile := POpenFile(CreateObject(FileObjectType, nil));
  if OpenedFile = nil then
  begin
    if Volume <> nil then
    begin
      AcquireMutex(Volume^.Lock);
      ReleaseNodeReference(Volume, Node);
      ReleaseMutex(Volume^.Lock);
    end;
    Exit(StatusOutOfMemory);
  end;

  OpenedFile^.Volume := Volume;
  OpenedFile^.Node := Node;
  OpenedFile^.Flags := Flags;
  OpenedFile^.Position := 0;
end;

function OpenPath(Path: PChar; out OpenedFile: POpenFile): TFileSystemStatus;
begin
  Result := OpenFile(Path, OpenForReading, OpenedFile);
end;

procedure CloseFile(OpenedFile: POpenFile);
begin
  if OpenedFile <> nil then
    DereferenceObject(OpenedFile);
end;

function IsRootDirectory(OpenedFile: POpenFile): Boolean;
begin
  Result := OpenedFile^.Volume = nil;
end;

function ReadFromFile(OpenedFile: POpenFile; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
var
  Volume: PVolume;
begin
  BytesRead := 0;
  if IsRootDirectory(OpenedFile) or (OpenedFile^.Node^.Information.Kind = NodeKindDirectory) then
    Exit(StatusIsADirectory);

  Volume := OpenedFile^.Volume;
  AcquireMutex(Volume^.Lock);
  Result := Volume^.Driver^.ReadFile(OpenedFile^.Node, OpenedFile^.Position, Buffer, ByteCount,
    BytesRead);
  if Result = StatusSuccess then
    OpenedFile^.Position := OpenedFile^.Position + BytesRead;
  ReleaseMutex(Volume^.Lock);
end;

function WriteToFile(OpenedFile: POpenFile; Buffer: Pointer; ByteCount: QWord;
  out BytesWritten: QWord): TFileSystemStatus;
var
  Volume: PVolume;
begin
  BytesWritten := 0;
  if IsRootDirectory(OpenedFile) or (OpenedFile^.Node^.Information.Kind = NodeKindDirectory) then
    Exit(StatusIsADirectory);
  if not WantsWriteAccess(OpenedFile^.Flags) then
    Exit(StatusReadOnly);
  if ByteCount = 0 then
    Exit(StatusSuccess);

  Volume := OpenedFile^.Volume;
  AcquireMutex(Volume^.Lock);
  if (OpenedFile^.Flags and OpenAppend) <> 0 then
    OpenedFile^.Position := OpenedFile^.Node^.Information.SizeInBytes;
  Result := Volume^.Driver^.WriteFile(OpenedFile^.Node, OpenedFile^.Position, Buffer, ByteCount,
    BytesWritten);
  OpenedFile^.Position := OpenedFile^.Position + BytesWritten;
  ReleaseMutex(Volume^.Lock);
end;

function ChangeFileSize(OpenedFile: POpenFile; NewSize: QWord): TFileSystemStatus;
var
  Volume: PVolume;
begin
  if IsRootDirectory(OpenedFile) or (OpenedFile^.Node^.Information.Kind <> NodeKindFile) then
    Exit(StatusIsADirectory);
  if not WantsWriteAccess(OpenedFile^.Flags) then
    Exit(StatusReadOnly);

  Volume := OpenedFile^.Volume;
  AcquireMutex(Volume^.Lock);
  Result := Volume^.Driver^.SetFileSize(OpenedFile^.Node, NewSize);
  ReleaseMutex(Volume^.Lock);
end;

procedure SetFilePosition(OpenedFile: POpenFile; Position: QWord);
begin
  OpenedFile^.Position := Position;
end;

function GetFilePosition(OpenedFile: POpenFile): QWord;
begin
  Result := OpenedFile^.Position;
end;

function ReadRootDirectoryEntry(OpenedFile: POpenFile; out Entry: TDirectoryEntry): TFileSystemStatus;
var
  Volume: PVolume;
begin
  Volume := VolumeAt(Integer(OpenedFile^.Cursor.Position));
  if Volume = nil then
    Exit(StatusEndOfDirectory);
  Inc(OpenedFile^.Cursor.Position);

  CopyText(@Entry.Name[0], @Volume^.Name[0], MaximumNameBytes);
  Entry.Kind := NodeKindDirectory;
  Entry.NodeNumber := 0;
  Result := StatusSuccess;
end;

function ReadDirectoryEntry(OpenedFile: POpenFile; out Entry: TDirectoryEntry): TFileSystemStatus;
var
  Volume: PVolume;
begin
  if IsRootDirectory(OpenedFile) then
    Exit(ReadRootDirectoryEntry(OpenedFile, Entry));
  if OpenedFile^.Node^.Information.Kind <> NodeKindDirectory then
    Exit(StatusNotADirectory);

  Volume := OpenedFile^.Volume;
  AcquireMutex(Volume^.Lock);
  Result := Volume^.Driver^.ReadDirectory(OpenedFile^.Node, OpenedFile^.Cursor, Entry);
  ReleaseMutex(Volume^.Lock);
end;

procedure DescribeRootDirectory(out Information: TNodeInformation);
begin
  ZeroMemory(@Information, SizeOf(Information));
  Information.Kind := NodeKindDirectory;
  Information.LinkCount := 1;
end;

function GetFileInformation(OpenedFile: POpenFile; out Information: TNodeInformation): TFileSystemStatus;
begin
  if IsRootDirectory(OpenedFile) then
    DescribeRootDirectory(Information)
  else
  begin
    AcquireMutex(OpenedFile^.Volume^.Lock);
    Information := OpenedFile^.Node^.Information;
    ReleaseMutex(OpenedFile^.Volume^.Lock);
  end;
  Result := StatusSuccess;
end;

function DescribePath(Path: PChar; FollowFinalLink: Boolean;
  out Information: TNodeInformation): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
begin
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
  begin
    DescribeRootDirectory(Information);
    Exit;
  end;

  AcquireMutex(Volume^.Lock);
  Result := ResolveInVolume(Volume, RemainingPath, FollowFinalLink, 0, Node);
  if Result = StatusSuccess then
  begin
    Information := Node^.Information;
    ReleaseNodeReference(Volume, Node);
  end;
  ReleaseMutex(Volume^.Lock);
end;

function GetPathInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;
begin
  Result := DescribePath(Path, True, Information);
end;

function GetLinkInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;
begin
  Result := DescribePath(Path, False, Information);
end;

function ReadSymbolicLinkTarget(Path: PChar; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
begin
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
    Exit(StatusInvalidPath);

  AcquireMutex(Volume^.Lock);
  Result := ResolveInVolume(Volume, RemainingPath, False, 0, Node);
  if Result = StatusSuccess then
  begin
    if Node^.Information.Kind <> NodeKindSymbolicLink then
      Result := StatusInvalidPath
    else if not Assigned(Volume^.Driver^.ReadSymbolicLink) then
      Result := StatusUnsupported
    else
      Result := Volume^.Driver^.ReadSymbolicLink(Node, Target, Capacity);
    ReleaseNodeReference(Volume, Node);
  end;
  ReleaseMutex(Volume^.Lock);
end;

{ --- Namespace changes ----------------------------------------------- }

{ Prepares a name changing operation: selects a writable volume, takes
  its lock and resolves the parent directory. On success the caller must
  call FinishNameOperation. }
function BeginNameOperation(Path: PChar; Target: PParentAndName): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
begin
  Target^.Volume := nil;
  Target^.Parent := nil;
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
    Exit(StatusInvalidPath);
  if Volume^.IsReadOnly then
    Exit(StatusReadOnly);

  AcquireMutex(Volume^.Lock);
  Result := ResolveParent(Volume, RemainingPath, Target);
  if Result <> StatusSuccess then
    ReleaseMutex(Volume^.Lock);
end;

procedure FinishNameOperation(Target: PParentAndName);
begin
  ReleaseNodeReference(Target^.Volume, Target^.Parent);
  ReleaseMutex(Target^.Volume^.Lock);
end;

function CreateNamedNode(Path: PChar; Kind: TNodeKind; LinkTarget: PChar): TFileSystemStatus;
var
  Target: PParentAndName;
  Existing: PNode;
  Created: PNode;
begin
  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if Target = nil then
    Exit(StatusOutOfMemory);

  Result := BeginNameOperation(Path, Target);
  if Result = StatusSuccess then
  begin
    Result := LookupAndIntern(Target^.Parent, @Target^.Name[0], Existing);
    if Result = StatusSuccess then
    begin
      ReleaseNodeReference(Target^.Volume, Existing);
      Result := StatusAlreadyExists;
    end
    else if Result = StatusNotFound then
    begin
      Result := Target^.Volume^.Driver^.CreateNode(Target^.Parent, @Target^.Name[0], Kind,
        LinkTarget, Created);
      if Result = StatusSuccess then
        ReleaseNodeReference(Target^.Volume, InternNode(Target^.Volume, Created));
    end;
    FinishNameOperation(Target);
  end;

  FreeKernelMemory(Target);
end;

function CreateDirectory(Path: PChar): TFileSystemStatus;
begin
  Result := CreateNamedNode(Path, NodeKindDirectory, nil);
end;

function CreateSymbolicLink(Path: PChar; Target: PChar): TFileSystemStatus;
begin
  if (Target = nil) or (Target^ = #0) or (TextLength(Target) >= MaximumPathBytes) then
    Exit(StatusInvalidPath);
  Result := CreateNamedNode(Path, NodeKindSymbolicLink, Target);
end;

function RemovePath(Path: PChar): TFileSystemStatus;
var
  Target: PParentAndName;
  Node: PNode;
begin
  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if Target = nil then
    Exit(StatusOutOfMemory);

  Result := BeginNameOperation(Path, Target);
  if Result = StatusSuccess then
  begin
    Result := LookupAndIntern(Target^.Parent, @Target^.Name[0], Node);
    if Result = StatusSuccess then
    begin
      { Our own lookup holds one reference; any other means it is open. }
      if Node^.ReferenceCount > 1 then
        Result := StatusInUse
      else
        Result := Target^.Volume^.Driver^.RemoveNode(Target^.Parent, @Target^.Name[0], Node);
      ReleaseNodeReference(Target^.Volume, Node);
    end;
    FinishNameOperation(Target);
  end;

  FreeKernelMemory(Target);
end;

{ True if Inner names Outer itself or something below it. }
function PathIsInside(Inner: PChar; Outer: PChar): Boolean;
var
  OuterLength: PtrUInt;
begin
  OuterLength := TextLength(Outer);
  Result := MemoryIsEqual(Inner, Outer, OuterLength) and
    ((Inner[OuterLength] = #0) or (Inner[OuterLength] = '/'));
end;

function RenamePath(SourcePath: PChar; TargetPath: PChar): TFileSystemStatus;
var
  Source: PParentAndName;
  Target: PParentAndName;
  TargetVolume: PVolume;
  RemainingTargetPath: PChar;
  Node: PNode;
  Existing: PNode;
begin
  Source := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if (Source = nil) or (Target = nil) then
  begin
    FreeKernelMemory(Source);
    FreeKernelMemory(Target);
    Exit(StatusOutOfMemory);
  end;

  Result := BeginNameOperation(SourcePath, Source);
  if Result = StatusSuccess then
  begin
    Result := SelectVolume(TargetPath, TargetVolume, RemainingTargetPath);
    if (Result = StatusSuccess) and (TargetVolume <> Source^.Volume) then
      Result := StatusUnsupported; { moving between volumes means copying }

    if Result = StatusSuccess then
      Result := ResolveParent(Source^.Volume, RemainingTargetPath, Target);

    if Result = StatusSuccess then
    begin
      Result := LookupAndIntern(Source^.Parent, @Source^.Name[0], Node);
      if Result = StatusSuccess then
      begin
        Existing := nil;
        if LookupAndIntern(Target^.Parent, @Target^.Name[0], Existing) <> StatusSuccess then
          Existing := nil;

        if (Existing <> nil) and (Existing <> Node) then
          Result := StatusAlreadyExists
        else if (Existing = Node) and TextIsEqual(@Source^.Name[0], @Target^.Name[0]) then
          Result := StatusSuccess { renaming something onto itself }
        else if (Node^.Information.Kind = NodeKindDirectory) and (Existing = nil) and
                PathIsInside(@Target^.NormalizedPath[0], @Source^.NormalizedPath[0]) then
          Result := StatusInvalidPath
        else
          { Includes changing only the letter case of a name on file
            systems that ignore case, where the lookup above finds Node. }
          Result := Source^.Volume^.Driver^.RenameNode(Source^.Parent, @Source^.Name[0], Node,
            Target^.Parent, @Target^.Name[0]);
        if Existing <> nil then
          ReleaseNodeReference(Source^.Volume, Existing);
        ReleaseNodeReference(Source^.Volume, Node);
      end;
      ReleaseNodeReference(Source^.Volume, Target^.Parent);
    end;
    FinishNameOperation(Source);
  end;

  FreeKernelMemory(Source);
  FreeKernelMemory(Target);
end;

function SetPathAttributes(Path: PChar; FollowLinks: Boolean;
  const Changes: TAttributeChanges): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
begin
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
    Exit(StatusUnsupported); { the namespace root is not a real directory }
  if Volume^.IsReadOnly then
    Exit(StatusReadOnly);
  if not Assigned(Volume^.Driver^.SetAttributes) then
    Exit(StatusUnsupported);

  AcquireMutex(Volume^.Lock);
  Result := ResolveInVolume(Volume, RemainingPath, FollowLinks, 0, Node);
  if Result = StatusSuccess then
  begin
    Result := Volume^.Driver^.SetAttributes(Node, Changes);
    ReleaseNodeReference(Volume, Node);
  end;
  ReleaseMutex(Volume^.Lock);
end;

function CreateHardLink(ExistingPath: PChar; NewPath: PChar): TFileSystemStatus;
var
  Target: PParentAndName;
  ExistingVolume: PVolume;
  RemainingExistingPath: PChar;
  Node: PNode;
  Occupant: PNode;
begin
  Result := SelectVolume(ExistingPath, ExistingVolume, RemainingExistingPath);
  if Result <> StatusSuccess then
    Exit;
  if ExistingVolume = nil then
    Exit(StatusIsADirectory);

  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if Target = nil then
    Exit(StatusOutOfMemory);
  Result := BeginNameOperation(NewPath, Target);
  if Result = StatusSuccess then
  begin
    if Target^.Volume <> ExistingVolume then
      Result := StatusUnsupported { links cannot cross volumes }
    else if not Assigned(Target^.Volume^.Driver^.CreateHardLink) then
      Result := StatusUnsupported
    else
    begin
      Result := ResolveInVolume(ExistingVolume, RemainingExistingPath, False, 0, Node);
      if Result = StatusSuccess then
      begin
        if Node^.Information.Kind = NodeKindDirectory then
          Result := StatusIsADirectory
        else if LookupAndIntern(Target^.Parent, @Target^.Name[0], Occupant) = StatusSuccess then
        begin
          ReleaseNodeReference(Target^.Volume, Occupant);
          Result := StatusAlreadyExists;
        end
        else
          Result := Target^.Volume^.Driver^.CreateHardLink(Target^.Parent, @Target^.Name[0], Node);
        ReleaseNodeReference(ExistingVolume, Node);
      end;
    end;
    FinishNameOperation(Target);
  end;
  FreeKernelMemory(Target);
end;

function GetVolumeFreeSpace(Volume: PVolume; out FreeBytes: QWord): Boolean;
begin
  FreeBytes := 0;
  if not Assigned(Volume^.Driver^.GetFreeSpace) then
    Exit(False);
  AcquireMutex(Volume^.Lock);
  Result := Volume^.Driver^.GetFreeSpace(Volume, FreeBytes) = StatusSuccess;
  ReleaseMutex(Volume^.Lock);
end;

procedure SyncAllVolumes;
var
  Index: Integer;
  Volume: PVolume;
begin
  for Index := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(Index);
    if Volume^.IsReadOnly then
      Continue;
    AcquireMutex(Volume^.Lock);
    Volume^.Driver^.Sync(Volume);
    ReleaseMutex(Volume^.Lock);
  end;
end;

end.
