{
  Paths and open files.

  Paths are absolute and use '/' as separator. The first component names
  a mounted volume and the rest is resolved by that volume's driver:

    /                       the root: lists the mounted volumes
    /disk1p2                root directory of volume disk1p2
    /disk1p2/docs/readme    a file on it

  "." and ".." are resolved textually before the lookup starts. Symbolic
  links are followed (up to MaximumSymbolicLinkDepth deep); an absolute
  link target is taken relative to the root of the link's own volume.

  An open file is an object of type "File" holding the node it refers to
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

type
  POpenFile = ^TOpenFile;
  TOpenFile = record
    { nil for the root directory, which lists volumes. }
    Volume: PVolume;
    Node: PNode;
    Position: QWord;
    Cursor: TDirectoryCursor;
    Lock: TMutex;
  end;

procedure InitializeFileObjects;

function OpenPath(Path: PChar; out OpenedFile: POpenFile): TFileSystemStatus;
procedure CloseFile(OpenedFile: POpenFile);

function ReadFromFile(OpenedFile: POpenFile; Buffer: Pointer; ByteCount: QWord;
  out BytesRead: QWord): TFileSystemStatus;
procedure SetFilePosition(OpenedFile: POpenFile; Position: QWord);
function GetFilePosition(OpenedFile: POpenFile): QWord;

function ReadDirectoryEntry(OpenedFile: POpenFile; out Entry: TDirectoryEntry): TFileSystemStatus;

function GetFileInformation(OpenedFile: POpenFile; out Information: TNodeInformation): TFileSystemStatus;
function GetPathInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
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

var
  FileObjectType: TObjectType;

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

{ --- Resolution within a volume -------------------------------------- }

procedure ReleaseNodeUnlessRoot(Volume: PVolume; Node: PNode);
begin
  if (Node <> nil) and (Node <> Volume^.RootNode) then
    Volume^.Driver^.ReleaseNode(Node);
end;

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
  ComponentIndex := 0;

  while (Result = StatusSuccess) and (ComponentIndex < Split^.ComponentCount) do
  begin
    if Node^.Information.Kind <> NodeKindDirectory then
    begin
      Result := StatusNotADirectory;
      Break;
    end;

    Result := Volume^.Driver^.Lookup(Node, Split^.Components[ComponentIndex], NextNode);
    ReleaseNodeUnlessRoot(Volume, Node);
    Node := nil;
    if Result <> StatusSuccess then
      Break;

    IsFinalComponent := ComponentIndex = Split^.ComponentCount - 1;
    if (NextNode^.Information.Kind = NodeKindSymbolicLink) and
       ((not IsFinalComponent) or FollowFinalLink) then
    begin
      Result := FollowLink(Volume, NextNode, Split, ComponentIndex, FollowFinalLink, Depth, Node);
      ReleaseNodeUnlessRoot(Volume, NextNode);
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
    ReleaseNodeUnlessRoot(Volume, Node);
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

function ResolvePath(Path: PChar; FollowFinalLink: Boolean; out Volume: PVolume;
  out Node: PNode): TFileSystemStatus;
var
  RemainingPath: PChar;
begin
  Node := nil;
  Result := SelectVolume(Path, Volume, RemainingPath);
  if (Result <> StatusSuccess) or (Volume = nil) then
    Exit;
  Result := ResolveInVolume(Volume, RemainingPath, FollowFinalLink, 0, Node);
end;

{ --- Open files ------------------------------------------------------ }

procedure DeleteOpenFile(ObjectBody: Pointer);
var
  OpenedFile: POpenFile;
begin
  OpenedFile := POpenFile(ObjectBody);
  if OpenedFile^.Volume <> nil then
    ReleaseNodeUnlessRoot(OpenedFile^.Volume, OpenedFile^.Node);
end;

procedure InitializeFileObjects;
begin
  RegisterObjectType(FileObjectType, 'File', SizeOf(TOpenFile), @DeleteOpenFile);
end;

function OpenPath(Path: PChar; out OpenedFile: POpenFile): TFileSystemStatus;
var
  Volume: PVolume;
  Node: PNode;
begin
  OpenedFile := nil;
  Result := ResolvePath(Path, True, Volume, Node);
  if Result <> StatusSuccess then
    Exit;

  OpenedFile := POpenFile(CreateObject(FileObjectType, nil));
  if OpenedFile = nil then
  begin
    if Volume <> nil then
      ReleaseNodeUnlessRoot(Volume, Node);
    Exit(StatusOutOfMemory);
  end;

  OpenedFile^.Volume := Volume;
  OpenedFile^.Node := Node;
  OpenedFile^.Position := 0;
  InitializeMutex(OpenedFile^.Lock);
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
begin
  BytesRead := 0;
  if IsRootDirectory(OpenedFile) or (OpenedFile^.Node^.Information.Kind = NodeKindDirectory) then
    Exit(StatusIsADirectory);

  AcquireMutex(OpenedFile^.Lock);
  Result := OpenedFile^.Volume^.Driver^.ReadFile(OpenedFile^.Node, OpenedFile^.Position,
    Buffer, ByteCount, BytesRead);
  if Result = StatusSuccess then
    OpenedFile^.Position := OpenedFile^.Position + BytesRead;
  ReleaseMutex(OpenedFile^.Lock);
end;

procedure SetFilePosition(OpenedFile: POpenFile; Position: QWord);
begin
  AcquireMutex(OpenedFile^.Lock);
  OpenedFile^.Position := Position;
  ReleaseMutex(OpenedFile^.Lock);
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
begin
  AcquireMutex(OpenedFile^.Lock);
  if IsRootDirectory(OpenedFile) then
    Result := ReadRootDirectoryEntry(OpenedFile, Entry)
  else if OpenedFile^.Node^.Information.Kind <> NodeKindDirectory then
    Result := StatusNotADirectory
  else
    Result := OpenedFile^.Volume^.Driver^.ReadDirectory(OpenedFile^.Node, OpenedFile^.Cursor, Entry);
  ReleaseMutex(OpenedFile^.Lock);
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
    Information := OpenedFile^.Node^.Information;
  Result := StatusSuccess;
end;

function GetPathInformation(Path: PChar; out Information: TNodeInformation): TFileSystemStatus;
var
  Volume: PVolume;
  Node: PNode;
begin
  Result := ResolvePath(Path, True, Volume, Node);
  if Result <> StatusSuccess then
    Exit;
  if Volume = nil then
    DescribeRootDirectory(Information)
  else
  begin
    Information := Node^.Information;
    ReleaseNodeUnlessRoot(Volume, Node);
  end;
end;

end.
