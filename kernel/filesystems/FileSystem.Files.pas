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

  Changes
    Every change is reported to the watches (FileSystem.Watches) once it
    worked, with the trail of the folder it happened in (the nodes the
    path went through, FileSystem.NodeTrails). Name changes build a
    trail only while some watch exists; an open file on a writable
    volume always keeps the trail of its node, since a watch made later
    must still hear of its writes. A write is reported in the folder the
    file was opened in, under the name it was opened by.

  Volumes going away
    A volume whose disk was unplugged is marked gone (FileSystem.Volumes):
    every operation on it fails with StatusVolumeGone, except closing.
    Its driver data is given back once the last node besides the root
    is released (FinishGoneVolume).
}
unit FileSystem.Files;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  FileSystem.Types,
  FileSystem.NodeTrails,
  FileSystem.Watches;

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
    { The trail of Node as it was opened (nil on the root and on
      read-only volumes), for reporting its changes. }
    Trail: PSavedTrail;
  end;

procedure InitializeFileObjects;

type
  { Told after the contents of a file changed (written to, resized), so
    copies of it elsewhere (image sections) can be dropped. }
  TFileChangedHook = procedure(Volume: PVolume; NodeNumber: QWord);

procedure SetFileChangedHook(Hook: TFileChangedHook);

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
{ GetPathInformation or GetLinkInformation. }
function DescribePath(Path: PChar; FollowFinalLink: Boolean;
  out Information: TNodeInformation): TFileSystemStatus;
{ Copies the target of the symbolic link at Path (not followed). }
function ReadSymbolicLinkTarget(Path: PChar; Target: PChar; Capacity: PtrUInt): TFileSystemStatus;

function CreateDirectory(Path: PChar): TFileSystemStatus;
function CreateSymbolicLink(Path: PChar; Target: PChar): TFileSystemStatus;
{ Creates a named pipe. }
function CreateFifo(Path: PChar): TFileSystemStatus;
{ Removes a file, symbolic link or empty directory. }
function RemovePath(Path: PChar): TFileSystemStatus;
{ Moves or renames within one volume. The target must not exist. }
function RenamePath(SourcePath: PChar; TargetPath: PChar): TFileSystemStatus;

{ Writes summary information of every writable volume to disk. }
{ Changes permissions, owner, group or times. FollowLinks selects whether
  a final symbolic link is changed or what it points to. }
function SetPathAttributes(Path: PChar; FollowLinks: Boolean;
  const Changes: TAttributeChanges): TFileSystemStatus;
{ The same for the node of an open file. }
function SetFileAttributes(OpenedFile: POpenFile; const Changes: TAttributeChanges): TFileSystemStatus;

{ Gives the file at ExistingPath the further name NewPath (same volume). }
function CreateHardLink(ExistingPath: PChar; NewPath: PChar): TFileSystemStatus;

{ False if the volume's driver cannot tell. }
function GetVolumeFreeSpace(Volume: PVolume; out FreeBytes: QWord): Boolean;

{ Makes a watch (FileSystem.Watches) on the folder or file at Path ("/"
  is the list of volumes), for a caller who may read it. Flags are Abi
  Watch* flags. }
function WatchPath(Path: PChar; Flags: LongWord; out Watch: PWatch): TFileSystemStatus;

{ Marks Volume gone (FileSystem.Volumes takes it off its list first):
  waits for the operation running on it, fails every later one, and
  gives its driver data back as soon as no node of it is in use. }
procedure MarkVolumeGone(Volume: PVolume);

procedure SyncAllVolumes;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.LinkedList,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Objects.Manager,

  Io.BlockCache,
  FileSystem.Volumes,
  FileSystem.Security;

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
    { The trail of Parent, when the change is to be reported. }
    Trail: PNodeTrail;
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
  Inc(Volume^.NodesInUse);
  Result := Fresh;
end;

procedure ReferenceNode(Node: PNode);
begin
  Inc(Node^.ReferenceCount);
end;

{ Gives a gone volume's driver data back once no node besides the root
  is in use any more. Volume lock held. }
procedure FinishGoneVolume(Volume: PVolume);
begin
  if not Volume^.IsGone or Volume^.IsUnmounted or (Volume^.NodesInUse > 0) then
    Exit;
  RemoveListEntry(@Volume^.RootNode^.CacheLink);
  if Assigned(Volume^.Driver^.Unmount) then
    Volume^.Driver^.Unmount(Volume);
  Volume^.IsUnmounted := True;
end;

{ Called with the volume lock held. A node removed while it was open
  gives its storage back with its last reference. }
procedure ReleaseNodeReference(Volume: PVolume; Node: PNode);
begin
  if Node = nil then
    Exit;
  Dec(Node^.ReferenceCount);
  if Node^.ReferenceCount <= 0 then
  begin
    RemoveListEntry(@Node^.CacheLink);
    { On a volume that became read-only meanwhile the storage stays
      allocated (ext keeps it on its orphan list, freed when mounted). }
    if Node^.RemovalPending and not Volume^.IsReadOnly then
      Volume^.Driver^.FinishRemoval(Node);
    Volume^.Driver^.ReleaseNode(Node);
    Dec(Volume^.NodesInUse);
    FinishGoneVolume(Volume);
  end;
end;

{ Takes the volume's lock for an operation, unless the volume is gone. }
function LockVolume(Volume: PVolume): TFileSystemStatus;
begin
  AcquireMutex(Volume^.Lock);
  if Volume^.IsGone then
  begin
    ReleaseMutex(Volume^.Lock);
    Exit(StatusVolumeGone);
  end;
  Result := StatusSuccess;
end;

{ Takes a node that lost its last name out of the cache, so that a new
  file that gets the same node number is not mixed up with it. }
procedure ForgetRemovedNode(Node: PNode);
begin
  RemoveListEntry(@Node^.CacheLink);
  InitializeListHead(Node^.CacheLink);
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
  Depth: Integer; Trail: PNodeTrail; out Found: PNode): TFileSystemStatus; forward;

{ Builds the path that results from replacing component LinkIndex of
  Split by the link target, and resolves it. }
function FollowLink(Volume: PVolume; LinkNode: PNode; Split: PSplitPath; LinkIndex: Integer;
  FollowFinalLink: Boolean; Depth: Integer; Trail: PNodeTrail; out Found: PNode): TFileSystemStatus;
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

    { The path is resolved afresh from the root, and so is the trail. }
    Result := ResolveInVolume(Volume, NewPath, FollowFinalLink, Depth + 1, Trail, Found);
  end;

  FreeKernelMemory(Target);
  FreeKernelMemory(NewPath);
end;

{ Resolves RelativePath from the volume's root. Trail (if not nil)
  receives the nodes passed through, ending with Found. }
function ResolveInVolume(Volume: PVolume; RelativePath: PChar; FollowFinalLink: Boolean;
  Depth: Integer; Trail: PNodeTrail; out Found: PNode): TFileSystemStatus;
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
  if Trail <> nil then
    StartTrail(Trail, Node^.Information.NodeNumber);

  while (Result = StatusSuccess) and (ComponentIndex < Split^.ComponentCount) do
  begin
    if Node^.Information.Kind <> NodeKindDirectory then
    begin
      Result := StatusNotADirectory;
      Break;
    end;
    if not MayAccess(Node^.Information, AccessExecute) then
    begin
      Result := StatusAccessDenied;
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
      Result := FollowLink(Volume, NextNode, Split, ComponentIndex, FollowFinalLink, Depth, Trail, Node);
      ReleaseNodeReference(Volume, NextNode);
      FreeKernelMemory(Split);
      if Result = StatusSuccess then
        Found := Node;
      Exit;
    end;

    Node := NextNode;
    if Trail <> nil then
      ExtendTrail(Trail, Node^.Information.NodeNumber, Split^.Components[ComponentIndex]);
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

{ Changing the names in a directory needs write and search permission. }
function MayChangeDirectory(Directory: PNode): Boolean;
begin
  Result := MayAccess(Directory^.Information, AccessWrite or AccessExecute);
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

  Result := ResolveInVolume(Volume, @ParentPath[0], True, 0, Target^.Trail, Target^.Parent);
  if (Result = StatusSuccess) and (Target^.Parent^.Information.Kind <> NodeKindDirectory) then
  begin
    ReleaseNodeReference(Volume, Target^.Parent);
    Target^.Parent := nil;
    Result := StatusNotADirectory;
  end;
  { Looking the name up searches the parent. }
  if (Result = StatusSuccess) and not MayAccess(Target^.Parent^.Information, AccessExecute) then
  begin
    ReleaseNodeReference(Volume, Target^.Parent);
    Target^.Parent := nil;
    Result := StatusAccessDenied;
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
    { Also on a volume that is gone: the node must be given back. }
    AcquireMutex(Volume^.Lock);
    ReleaseNodeReference(Volume, OpenedFile^.Node);
    ReleaseMutex(Volume^.Lock);
  end;
  FreeKernelMemory(OpenedFile^.Trail);
end;

{ --- Reporting changes ------------------------------------------------- }

function IsDirectoryNode(Node: PNode): Boolean;
begin
  Result := Node^.Information.Kind = NodeKindDirectory;
end;

{ A change to the name Target^.Name in Target^.Parent, about Node. }
procedure ReportNameChange(Target: PParentAndName; Kind: Word; Node: PNode);
var
  Report: TChangeReport;
begin
  if Target^.Trail = nil then
    Exit;
  ZeroMemory(@Report, SizeOf(Report));
  Report.Volume := Target^.Volume;
  Report.Kind := Kind;
  Report.IsDirectory := IsDirectoryNode(Node);
  Report.ParentTrail := Target^.Trail;
  Report.Name := @Target^.Name[0];
  Report.NodeNumber := Node^.Information.NodeNumber;
  ReportChange(Report);
end;

{ A change to Node itself, whose trail (ending with Node) is Trail; the
  trail is shortened to its folder's on the way. }
procedure ReportNodeChange(Volume: PVolume; Trail: PNodeTrail; Kind: Word; Node: PNode);
var
  Report: TChangeReport;
  Name: array[0..MaximumNameLengthInBytes] of Char;
begin
  ZeroMemory(@Report, SizeOf(Report));
  CopyLastTrailName(Trail, @Name[0], SizeOf(Name));
  ShortenTrail(Trail);
  Report.Volume := Volume;
  Report.Kind := Kind;
  Report.IsDirectory := IsDirectoryNode(Node);
  Report.ParentTrail := Trail;
  Report.Name := @Name[0];
  Report.NodeNumber := Node^.Information.NodeNumber;
  ReportChange(Report);
end;

{ A change to the node of an open file, reported with the trail it was
  opened by. }
procedure ReportOpenFileChange(OpenedFile: POpenFile; Kind: Word);
var
  Trail: PNodeTrail;
begin
  if (OpenedFile^.Trail = nil) or not WatchesExist then
    Exit;
  Trail := AllocateTrail;
  if Trail = nil then
    Exit;
  RestoreTrail(OpenedFile^.Trail, Trail);
  ReportNodeChange(OpenedFile^.Volume, Trail, Kind, OpenedFile^.Node);
  FreeTrail(Trail);
end;

{ A trail for a name change, while watches exist (volume lock held, so
  no watch on the volume can be made meanwhile); nil otherwise or if
  memory ran out (then the change is not reported). }
function TrailForReporting: PNodeTrail;
begin
  Result := nil;
  if WatchesExist then
    Result := AllocateTrail;
end;

procedure InitializeFileObjects;
begin
  RegisterObjectType(FileObjectType, 'File', SizeOf(TOpenFile), @DeleteOpenFile);
end;

function WantsWriteAccess(Flags: LongWord): Boolean;
begin
  Result := (Flags and (OpenForWriting or OpenCreate or OpenTruncate or OpenAppend)) <> 0;
end;

{ Finds or creates the file for OpenFile. Volume lock held. Trail (if
  not nil) receives the trail of the node. }
function ResolveForOpen(Volume: PVolume; RemainingPath: PChar; Flags: LongWord; Trail: PNodeTrail;
  out Node: PNode; out WasCreated: Boolean): TFileSystemStatus;
var
  Target: PParentAndName;
  Created: PNode;
begin
  Node := nil;
  WasCreated := False;
  if (Flags and OpenCreate) = 0 then
    Exit(ResolveInVolume(Volume, RemainingPath, True, 0, Trail, Node));

  Target := PParentAndName(AllocateKernelMemory(SizeOf(TParentAndName)));
  if Target = nil then
    Exit(StatusOutOfMemory);

  Target^.Trail := Trail;
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
        Result := ResolveInVolume(Volume, RemainingPath, True, 0, Trail, Node);
      end
      else if Trail <> nil then
        ExtendTrail(Trail, Node^.Information.NodeNumber, @Target^.Name[0]);
    end
    else if Result = StatusNotFound then
    begin
      if not MayChangeDirectory(Target^.Parent) then
        Result := StatusAccessDenied
      else
      begin
        Result := Volume^.Driver^.CreateNode(Target^.Parent, @Target^.Name[0], NodeKindFile, nil, Created);
        if Result = StatusSuccess then
        begin
          Node := InternNode(Volume, Created);
          ApplyCreationAttributes(Node, DefaultFileMode, True);
          WasCreated := True;
          if (Trail <> nil) and WatchesExist then
            ReportNameChange(Target, WatchChangeCreated, Node);
          if Trail <> nil then
            ExtendTrail(Trail, Node^.Information.NodeNumber, @Target^.Name[0]);
        end;
      end;
    end;
    ReleaseNodeReference(Volume, Target^.Parent);
  end;

  FreeKernelMemory(Target);
end;

{ The permissions an open with Flags needs on an existing node. }
function AccessForFlags(Flags: LongWord): LongWord;
begin
  Result := 0;
  if (Flags and OpenForReading) <> 0 then
    Result := Result or AccessRead;
  if WantsWriteAccess(Flags) then
    Result := Result or AccessWrite;
end;

var
  FileChangedHook: TFileChangedHook = nil;

procedure SetFileChangedHook(Hook: TFileChangedHook);
begin
  FileChangedHook := Hook;
end;

function OpenFile(Path: PChar; Flags: LongWord; out OpenedFile: POpenFile): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
  WasCreated: Boolean;
  Trail: PNodeTrail;
  SavedTrail: PSavedTrail;
begin
  OpenedFile := nil;
  Node := nil;
  SavedTrail := nil;
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

    { Nothing on a read-only volume changes, so there is nothing to
      report about the file. }
    Trail := nil;
    if not Volume^.IsReadOnly then
    begin
      Trail := AllocateTrail;
      if Trail = nil then
        Exit(StatusOutOfMemory);
    end;
    Result := LockVolume(Volume);
    if Result <> StatusSuccess then
    begin
      FreeTrail(Trail);
      Exit;
    end;
    Result := ResolveForOpen(Volume, RemainingPath, Flags, Trail, Node, WasCreated);
    if (Result = StatusSuccess) and WantsWriteAccess(Flags) and
       (Node^.Information.Kind = NodeKindDirectory) then
      Result := StatusIsADirectory;
    { The creator of a file may open it whatever mode it got. }
    if (Result = StatusSuccess) and not WasCreated and
       not MayAccess(Node^.Information, AccessForFlags(Flags)) then
      Result := StatusAccessDenied;
    if (Result = StatusSuccess) and ((Flags and OpenTruncate) <> 0) and
       (Node^.Information.SizeInBytes <> 0) then
    begin
      Result := Volume^.Driver^.SetFileSize(Node, 0);
      if (Result = StatusSuccess) and (Trail <> nil) and WatchesExist then
      begin
        SavedTrail := SaveTrail(Trail);
        ReportNodeChange(Volume, Trail, WatchChangeWritten, Node);
      end;
    end;
    if (Result = StatusSuccess) and (Trail <> nil) and (SavedTrail = nil) then
    begin
      SavedTrail := SaveTrail(Trail);
      if SavedTrail = nil then
        Result := StatusOutOfMemory;
    end;
    if (Result <> StatusSuccess) and (Node <> nil) then
    begin
      ReleaseNodeReference(Volume, Node);
      Node := nil;
    end;
    ReleaseMutex(Volume^.Lock);
    FreeTrail(Trail);
    if Result <> StatusSuccess then
    begin
      FreeKernelMemory(SavedTrail);
      Exit;
    end;
    if ((Flags and OpenTruncate) <> 0) and Assigned(FileChangedHook) then
      FileChangedHook(Volume, Node^.Information.NodeNumber);
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
    FreeKernelMemory(SavedTrail);
    Exit(StatusOutOfMemory);
  end;

  OpenedFile^.Volume := Volume;
  OpenedFile^.Node := Node;
  OpenedFile^.Flags := Flags;
  OpenedFile^.Position := 0;
  OpenedFile^.Trail := SavedTrail;
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
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := Volume^.Driver^.ReadFile(OpenedFile^.Node, OpenedFile^.Position, Buffer, ByteCount,
    BytesRead);
  if Result = StatusSuccess then
    OpenedFile^.Position := OpenedFile^.Position + BytesRead;
  ReleaseMutex(Volume^.Lock);
end;

procedure NoteFileChanged(OpenedFile: POpenFile);
begin
  if Assigned(FileChangedHook) then
    FileChangedHook(OpenedFile^.Volume, OpenedFile^.Node^.Information.NodeNumber);
  ReportOpenFileChange(OpenedFile, WatchChangeWritten);
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
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  if (OpenedFile^.Flags and OpenAppend) <> 0 then
    OpenedFile^.Position := OpenedFile^.Node^.Information.SizeInBytes;
  Result := Volume^.Driver^.WriteFile(OpenedFile^.Node, OpenedFile^.Position, Buffer, ByteCount,
    BytesWritten);
  OpenedFile^.Position := OpenedFile^.Position + BytesWritten;
  ReleaseMutex(Volume^.Lock);
  if BytesWritten > 0 then
    NoteFileChanged(OpenedFile);
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
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := Volume^.Driver^.SetFileSize(OpenedFile^.Node, NewSize);
  ReleaseMutex(Volume^.Lock);
  NoteFileChanged(OpenedFile);
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
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
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
    { The node's information stays readable on a gone volume. }
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

  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := ResolveInVolume(Volume, RemainingPath, FollowFinalLink, 0, nil, Node);
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

  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := ResolveInVolume(Volume, RemainingPath, False, 0, nil, Node);
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
  Target^.Trail := nil;
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
    Exit(StatusInvalidPath);
  if Volume^.IsReadOnly then
    Exit(StatusReadOnly);

  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Target^.Trail := TrailForReporting;
  Result := ResolveParent(Volume, RemainingPath, Target);
  if Result <> StatusSuccess then
  begin
    FreeTrail(Target^.Trail);
    Target^.Trail := nil;
    ReleaseMutex(Volume^.Lock);
  end;
end;

procedure FinishNameOperation(Target: PParentAndName);
begin
  ReleaseNodeReference(Target^.Volume, Target^.Parent);
  ReleaseMutex(Target^.Volume^.Lock);
  FreeTrail(Target^.Trail);
  Target^.Trail := nil;
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
      if not MayChangeDirectory(Target^.Parent) then
        Result := StatusAccessDenied
      else
        Result := Target^.Volume^.Driver^.CreateNode(Target^.Parent, @Target^.Name[0], Kind,
          LinkTarget, Created);
      if Result = StatusSuccess then
      begin
        Created := InternNode(Target^.Volume, Created);
        { Symbolic links keep rwxrwxrwx; their target's mode matters. }
        case Kind of
          NodeKindDirectory: ApplyCreationAttributes(Created, DefaultDirectoryMode, True);
          NodeKindSymbolicLink: ApplyCreationAttributes(Created, SymbolicLinkMode, False);
        else
          ApplyCreationAttributes(Created, DefaultFileMode, True);
        end;
        ReportNameChange(Target, WatchChangeCreated, Created);
        ReleaseNodeReference(Target^.Volume, Created);
      end;
    end;
    FinishNameOperation(Target);
  end;

  FreeKernelMemory(Target);
end;

function CreateDirectory(Path: PChar): TFileSystemStatus;
begin
  Result := CreateNamedNode(Path, NodeKindDirectory, nil);
end;

function CreateFifo(Path: PChar): TFileSystemStatus;
begin
  Result := CreateNamedNode(Path, NodeKindFifo, nil);
end;

function CreateSymbolicLink(Path: PChar; Target: PChar): TFileSystemStatus;
begin
  if (Target = nil) or (Target^ = #0) or (TextLength(Target) >= MaximumPathBytes) then
    Exit(StatusInvalidPath);
  Result := CreateNamedNode(Path, NodeKindSymbolicLink, Target);
end;

{ Removes the name Name of Node in Parent, which the caller has looked
  up (holding one reference). A file that is open elsewhere keeps
  working until it is closed, if the driver supports that. }
function RemoveName(Volume: PVolume; Parent: PNode; Name: PChar; Node: PNode): TFileSystemStatus;
begin
  if not MayChangeDirectory(Parent) or not MayRemoveFromDirectory(Parent, Node) then
    Exit(StatusAccessDenied);
  if Node^.ReferenceCount <= 1 then
    Exit(Volume^.Driver^.RemoveNode(Parent, Name, Node));
  if (Node^.Information.Kind = NodeKindDirectory) or not Assigned(Volume^.Driver^.RemoveOpenNode) then
    Exit(StatusInUse);
  Result := Volume^.Driver^.RemoveOpenNode(Parent, Name, Node);
  if (Result = StatusSuccess) and Node^.RemovalPending then
    ForgetRemovedNode(Node);
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
      Result := RemoveName(Target^.Volume, Target^.Parent, @Target^.Name[0], Node);
      if Result = StatusSuccess then
        ReportNameChange(Target, WatchChangeRemoved, Node);
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

{ Renames Node onto the name of Existing, which goes (as on Unix: a file
  replaces a file, a directory an empty directory). On journaled formats
  both happen in one change. }
function ReplaceByRename(Source, Target: PParentAndName; Node, Existing: PNode): TFileSystemStatus;
var
  Volume: PVolume;
  EndStatus: TFileSystemStatus;
begin
  Volume := Source^.Volume;
  if (Node^.Information.Kind = NodeKindDirectory) and (Existing^.Information.Kind <> NodeKindDirectory) then
    Exit(StatusNotADirectory);
  if (Node^.Information.Kind <> NodeKindDirectory) and (Existing^.Information.Kind = NodeKindDirectory) then
    Exit(StatusIsADirectory);
  if Assigned(Volume^.Driver^.BeginAtomicChange) then
    Volume^.Driver^.BeginAtomicChange(Volume);
  Result := RemoveName(Volume, Target^.Parent, @Target^.Name[0], Existing);
  if Result = StatusSuccess then
  begin
    ReportNameChange(Target, WatchChangeRemoved, Existing);
    Result := Volume^.Driver^.RenameNode(Source^.Parent, @Source^.Name[0], Node, Target^.Parent,
      @Target^.Name[0]);
  end;
  if Assigned(Volume^.Driver^.EndAtomicChange) then
  begin
    EndStatus := Volume^.Driver^.EndAtomicChange(Volume);
    if Result = StatusSuccess then
      Result := EndStatus;
  end;
end;

{ Reports a rename that worked: Node went from Source to Target, and
  was numbered OldNodeNumber before. }
procedure ReportRename(Source, Target: PParentAndName; Node: PNode; OldNodeNumber: QWord);
var
  Report: TChangeReport;
begin
  if (Source^.Trail = nil) or (Target^.Trail = nil) then
    Exit;
  ZeroMemory(@Report, SizeOf(Report));
  Report.Volume := Source^.Volume;
  Report.Kind := WatchChangeRenamed;
  Report.IsDirectory := IsDirectoryNode(Node);
  Report.ParentTrail := Source^.Trail;
  Report.Name := @Source^.Name[0];
  Report.NodeNumber := OldNodeNumber;
  Report.TargetTrail := Target^.Trail;
  Report.TargetName := @Target^.Name[0];
  Report.NewNodeNumber := Node^.Information.NodeNumber;
  ReportChange(Report);
end;

function RenamePath(SourcePath: PChar; TargetPath: PChar): TFileSystemStatus;
var
  Source: PParentAndName;
  Target: PParentAndName;
  TargetVolume: PVolume;
  RemainingTargetPath: PChar;
  Node: PNode;
  Existing: PNode;
  OldNodeNumber: QWord;
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

    Target^.Trail := nil;
    if (Result = StatusSuccess) and (Source^.Trail <> nil) then
      Target^.Trail := AllocateTrail;
    if Result = StatusSuccess then
      Result := ResolveParent(Source^.Volume, RemainingTargetPath, Target);

    if Result = StatusSuccess then
    begin
      Result := LookupAndIntern(Source^.Parent, @Source^.Name[0], Node);
      if Result = StatusSuccess then
      begin
        OldNodeNumber := Node^.Information.NodeNumber;
        Existing := nil;
        if LookupAndIntern(Target^.Parent, @Target^.Name[0], Existing) <> StatusSuccess then
          Existing := nil;

        if not MayChangeDirectory(Source^.Parent) or not MayChangeDirectory(Target^.Parent) or
           not MayRemoveFromDirectory(Source^.Parent, Node) then
          Result := StatusAccessDenied
        else if (Existing = Node) and TextIsEqual(@Source^.Name[0], @Target^.Name[0]) then
          Result := StatusSuccess { renaming something onto itself }
        else if (Node^.Information.Kind = NodeKindDirectory) and
                PathIsInside(@Target^.NormalizedPath[0], @Source^.NormalizedPath[0]) then
          Result := StatusInvalidPath
        else
        begin
          if (Existing <> nil) and (Existing <> Node) then
            Result := ReplaceByRename(Source, Target, Node, Existing)
          else
            { Includes changing only the letter case of a name on file
              systems that ignore case, where the lookup above finds Node. }
            Result := Source^.Volume^.Driver^.RenameNode(Source^.Parent, @Source^.Name[0], Node,
              Target^.Parent, @Target^.Name[0]);
          if Result = StatusSuccess then
            ReportRename(Source, Target, Node, OldNodeNumber);
        end;
        if Existing <> nil then
          ReleaseNodeReference(Source^.Volume, Existing);
        ReleaseNodeReference(Source^.Volume, Node);
      end;
      ReleaseNodeReference(Source^.Volume, Target^.Parent);
    end;
    FreeTrail(Target^.Trail);
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
  Trail: PNodeTrail;
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

  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Trail := TrailForReporting;
  Result := ResolveInVolume(Volume, RemainingPath, FollowLinks, 0, Trail, Node);
  if Result = StatusSuccess then
  begin
    Result := Volume^.Driver^.SetAttributes(Node, Changes);
    if (Result = StatusSuccess) and (Trail <> nil) then
      ReportNodeChange(Volume, Trail, WatchChangeAttributes, Node);
    ReleaseNodeReference(Volume, Node);
  end;
  ReleaseMutex(Volume^.Lock);
  FreeTrail(Trail);
end;

function SetFileAttributes(OpenedFile: POpenFile; const Changes: TAttributeChanges): TFileSystemStatus;
var
  Volume: PVolume;
begin
  Volume := OpenedFile^.Volume;
  if Volume = nil then
    Exit(StatusUnsupported);
  if Volume^.IsReadOnly then
    Exit(StatusReadOnly);
  if not Assigned(Volume^.Driver^.SetAttributes) then
    Exit(StatusUnsupported);
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := Volume^.Driver^.SetAttributes(OpenedFile^.Node, Changes);
  ReleaseMutex(Volume^.Lock);
  if Result = StatusSuccess then
    ReportOpenFileChange(OpenedFile, WatchChangeAttributes);
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
      Result := ResolveInVolume(ExistingVolume, RemainingExistingPath, False, 0, nil, Node);
      if Result = StatusSuccess then
      begin
        if Node^.Information.Kind = NodeKindDirectory then
          Result := StatusIsADirectory
        else if not MayChangeDirectory(Target^.Parent) then
          Result := StatusAccessDenied
        else if LookupAndIntern(Target^.Parent, @Target^.Name[0], Occupant) = StatusSuccess then
        begin
          ReleaseNodeReference(Target^.Volume, Occupant);
          Result := StatusAlreadyExists;
        end
        else
        begin
          Result := Target^.Volume^.Driver^.CreateHardLink(Target^.Parent, @Target^.Name[0], Node);
          if Result = StatusSuccess then
            ReportNameChange(Target, WatchChangeCreated, Node);
        end;
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
  if LockVolume(Volume) <> StatusSuccess then
    Exit(False);
  Result := Volume^.Driver^.GetFreeSpace(Volume, FreeBytes) = StatusSuccess;
  ReleaseMutex(Volume^.Lock);
end;

{ The watch for WatchPath on a node: read permission on it. Volume lock
  held. }
function WatchNode(Volume: PVolume; Node: PNode; Flags: LongWord; out Watch: PWatch): TFileSystemStatus;
begin
  Watch := nil;
  if not MayAccess(Node^.Information, AccessRead) then
    Exit(StatusAccessDenied);
  Watch := CreateWatch(Volume, Node^.Information.NodeNumber, IsDirectoryNode(Node), Flags);
  if Watch = nil then
    Exit(StatusOutOfMemory);
  Result := StatusSuccess;
end;

function WatchPath(Path: PChar; Flags: LongWord; out Watch: PWatch): TFileSystemStatus;
var
  Volume: PVolume;
  RemainingPath: PChar;
  Node: PNode;
begin
  Watch := nil;
  Result := SelectVolume(Path, Volume, RemainingPath);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
  begin
    { The list of volumes is there for everyone to see. }
    Watch := CreateWatch(nil, 0, True, Flags);
    if Watch = nil then
      Exit(StatusOutOfMemory);
    Exit(StatusSuccess);
  end;
  Result := LockVolume(Volume);
  if Result <> StatusSuccess then
    Exit;
  Result := ResolveInVolume(Volume, RemainingPath, True, 0, nil, Node);
  if Result = StatusSuccess then
  begin
    Result := WatchNode(Volume, Node, Flags, Watch);
    ReleaseNodeReference(Volume, Node);
  end;
  ReleaseMutex(Volume^.Lock);
end;

procedure MarkVolumeGone(Volume: PVolume);
begin
  AcquireMutex(Volume^.Lock);
  Volume^.IsGone := True;
  { Nothing is written back to a disk that is not there; ext keeps
    nodes removed while open on its orphan list, which this skips. }
  Volume^.IsReadOnly := True;
  FinishGoneVolume(Volume);
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
    if (Volume = nil) or Volume^.IsReadOnly then
      Continue;
    if LockVolume(Volume) <> StatusSuccess then
      Continue;
    Volume^.Driver^.Sync(Volume);
    ReleaseMutex(Volume^.Lock);
  end;
  { Everything written so far reaches the disks. }
  FlushAllCachedDevices;
end;

end.
