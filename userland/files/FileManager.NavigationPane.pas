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
  The navigation pane at the left, a tree:

    Home
    Gallery
    (the pinned folders)
    Computer
      Desktop, Documents, Downloads, Pictures, Music, Videos
      (every volume: label and name, a removable disk's icon)
    Network
    Recycle bin

  Every folder opens with a box (its subfolders read when first opened,
  hidden ones left out). The volumes are watched (Sys.Volumes): a disk
  plugged in shows at once ("volume-added NAME"), one unplugged goes
  ("volume-removed NAME", OnVolumeRemoved), and the trash's icon shows
  whether it holds anything. Choosing a node tells OnPlaceChosen with
  its address; ShowAddress picks the node a location is in without
  telling. Files dropped on a folder go into it (OnDropFiles); folders
  dropped on Home are pinned (OnPinFolders).
}
unit FileManager.NavigationPane;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.DragData,
  Controls.ImageList,
  Controls.TreeView,
  FileManager.FolderView;

type
  { What a node stands for. }
  TPlace = class
  public
    Address: string;
    { A folder's path ('' for the pages). }
    Path: string;
    VolumeName: string;
    Pinned: Boolean;
    TestName: string;
  end;

  TPlaceEvent = procedure(Sender: TControl; const Address: string) of object;
  TVolumeEvent = procedure(Sender: TControl; const VolumeName, MountPoint: string) of object;
  TPinFoldersEvent = procedure(Sender: TControl; Paths: TStrings) of object;

  TNavigationPane = class(TTreeView)
  private
    FPlaces: TList;
    FImages: TImageList;
    FHomeNode: TTreeNode;
    FGalleryNode: TTreeNode;
    FComputerNode: TTreeNode;
    FNetworkNode: TTreeNode;
    FTrashNode: TTreeNode;
    FPinnedNodes: TList;
    FWatch: Int64;
    FShowingAddress: Boolean;
    FIconIndexes: TStringList;
    FOnPlaceChosen: TPlaceEvent;
    FOnVolumeRemoved: TVolumeEvent;
    FOnDropFiles: TDropFilesEvent;
    FOnPinFolders: TPinFoldersEvent;
    function IconIndex(const Name: string): LongInt;
    function AddPlace(ParentNode: TTreeNode; const Caption, Address, Path, Icon, TestName: string;
      Expandable: Boolean; Position: LongInt = -1): TTreeNode;
    procedure AddVolume(const Name: string);
    function VolumeNode(const Name: string): TTreeNode;
    procedure VolumesChanged(Handle: Int64);
    procedure SelectionChanged(Sender: TControl);
    procedure NodeExpanded(Sender: TTreeView; Node: TTreeNode);
    procedure FillSubfolders(Node: TTreeNode);
    procedure ForgetPlacesUnder(Node: TTreeNode);
  protected
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function PlaceOf(Node: TTreeNode): TPlace;
    { The pinned folders again (after a pin or unpin). }
    procedure ShowPinned;
    { The trash's icon (empty or full). }
    procedure UpdateTrash;
    { Picks the node Address is in (without telling OnPlaceChosen). }
    procedure ShowAddress(const Address, Path: string);
    procedure TellPlaces;
    property OnPlaceChosen: TPlaceEvent read FOnPlaceChosen write FOnPlaceChosen;
    property OnVolumeRemoved: TVolumeEvent read FOnVolumeRemoved write FOnVolumeRemoved;
    property OnDropFiles: TDropFilesEvent read FOnDropFiles write FOnDropFiles;
    property OnPinFolders: TPinFoldersEvent read FOnPinFolders write FOnPinFolders;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Files,
  Sys.FileWatches,
  Sys.Volumes,
  Sys.Mounts,
  Windowing.Windows,
  Windowing.HandleWatches,
  Windowing.Connection,
  Controls.Icons,
  Controls.IconTheme,
  Controls.FileNames,
  Controls.FileLists,
  Util.Trash,
  FileManager.Items,
  FileManager.Paths,
  FileManager.Locations,
  FileManager.FolderReading,
  FileManager.UserLists,
  FileManager.DropRules,
  FileManager.TestPlaces,
  FileManager.Output;

constructor TNavigationPane.Create(AParent: TControl);
var
  Folder: TStandardFolder;
  Index: LongInt;
  Description: TVolumeDescription;
begin
  inherited Create(AParent);
  FPlaces := TList.Create;
  FPinnedNodes := TList.Create;
  FIconIndexes := TStringList.Create;
  FImages := TImageList.Create(SmallIconSize, SmallIconSize);
  Images := FImages;
  ShowLines := False;
  FHomeNode := AddPlace(nil, 'Home', HomeAddress, '', 'home', 'tree-home', False);
  FGalleryNode := AddPlace(nil, 'Gallery', GalleryAddress, '', 'gallery', 'tree-gallery', False);
  ShowPinned;
  FComputerNode := AddPlace(nil, 'Computer', ComputerAddress, '', 'computer', 'tree-computer', False);
  for Folder := Low(TStandardFolder) to High(TStandardFolder) do
    AddPlace(FComputerNode, StandardFolderNames[Folder], StandardFolderPath(Folder), StandardFolderPath(Folder),
      StandardFolderIcons[Folder], 'tree-' + LowerCase(StandardFolderNames[Folder]), True);
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    AddVolume(StrPas(@Description.Name[0]));
    Inc(Index);
  end;
  FComputerNode.Expanded := True;
  FNetworkNode := AddPlace(nil, 'Network', NetworkAddress, '', 'network', 'tree-network', False);
  FTrashNode := AddPlace(nil, 'Recycle bin', TrashAddress, '', 'trash-empty', 'tree-trash', False);
  UpdateTrash;
  FWatch := WatchVolumes;
  if FWatch >= 0 then
    WatchHandle(FWatch, @VolumesChanged);
  OnChange := @SelectionChanged;
  OnExpandChanged := @NodeExpanded;
end;

destructor TNavigationPane.Destroy;
var
  Index: LongInt;
  Pictures: TImageList;
begin
  if FWatch >= 0 then
  begin
    StopWatchingHandle(FWatch);
    CloseHandle(FWatch);
  end;
  for Index := 0 to FPlaces.Count - 1 do
    TPlace(FPlaces[Index]).Free;
  FPlaces.Free;
  FPinnedNodes.Free;
  FIconIndexes.Free;
  Pictures := FImages;
  inherited Destroy;
  Pictures.Free;
end;

function TNavigationPane.IconIndex(const Name: string): LongInt;
var
  Position: LongInt;
begin
  Position := FIconIndexes.IndexOf(Name);
  if Position >= 0 then
    Exit(PtrInt(FIconIndexes.Objects[Position]));
  Result := AddThemeIcon(FImages, Name);
  FIconIndexes.AddObject(Name, TObject(PtrInt(Result)));
end;

function TNavigationPane.AddPlace(ParentNode: TTreeNode; const Caption, Address, Path, Icon, TestName: string;
  Expandable: Boolean; Position: LongInt): TTreeNode;
var
  Place: TPlace;
begin
  Place := TPlace.Create;
  Place.Address := Address;
  Place.Path := Path;
  Place.TestName := TestName;
  FPlaces.Add(Place);
  if (ParentNode = nil) and (Position >= 0) then
    Result := InsertRoot(Position, Caption)
  else if ParentNode = nil then
    Result := AddRoot(Caption)
  else
    Result := ParentNode.Add(Caption);
  Result.Data := Place;
  Result.ImageIndex := IconIndex(Icon);
  if Result.ImageIndex < 0 then
    Result.SetIcon(StockIconFolder);
  Result.MayHaveChildren := Expandable;
end;

function TNavigationPane.PlaceOf(Node: TTreeNode): TPlace;
begin
  if Node = nil then
    Exit(nil);
  Result := TPlace(Node.Data);
end;

procedure TNavigationPane.ForgetPlacesUnder(Node: TTreeNode);
var
  Index: LongInt;
begin
  for Index := 0 to Node.Count - 1 do
  begin
    ForgetPlacesUnder(Node[Index]);
    FPlaces.Remove(Node[Index].Data);
    TPlace(Node[Index].Data).Free;
  end;
end;

procedure TNavigationPane.ShowPinned;
var
  Paths: TStringArray;
  Path: string;
  Node: TTreeNode;
  Index: LongInt;
  Folder: TStandardFolder;
  Icon: string;
begin
  FShowingAddress := True;
  for Index := 0 to FPinnedNodes.Count - 1 do
  begin
    Node := TTreeNode(FPinnedNodes[Index]);
    ForgetPlacesUnder(Node);
    FPlaces.Remove(Node.Data);
    TPlace(Node.Data).Free;
    DeleteNode(Node);
  end;
  FPinnedNodes.Clear;
  { The pinned folders go between Gallery and Computer. }
  Paths := ReadUserList(ListPinned);
  for Path in Paths do
  begin
    if not IsDirectory(PChar(Path)) then
      Continue;
    if StandardFolderAt(Path, Folder) then
      Icon := StandardFolderIcons[Folder]
    else
      Icon := 'folder';
    Node := AddPlace(nil, LastPartOf(Path), Path, Path, Icon, 'tree-pinned-' + LastPartOf(Path), True,
      2 + FPinnedNodes.Count);
    PlaceOf(Node).Pinned := True;
    FPinnedNodes.Add(Node);
  end;
  FShowingAddress := False;
end;

procedure TNavigationPane.UpdateTrash;
begin
  if FTrashNode = nil then
    Exit;
  if TrashHasItems then
    FTrashNode.ImageIndex := IconIndex('trash-full')
  else
    FTrashNode.ImageIndex := IconIndex('trash-empty');
end;

procedure TNavigationPane.AddVolume(const Name: string);
var
  Description: TVolumeDescription;
  Caption: string;
  Node: TTreeNode;
  MountPoint: string;
  Mount: TMountDescription;
  Index: LongInt;
  Icon: string;
begin
  if (VolumeNode(Name) <> nil) or not FindVolumeDescription(PChar(Name), Description) then
    Exit;
  Caption := StrPas(@Description.VolumeLabel[0]);
  if Description.IsSystemVolume then
    Caption := 'System (' + Name + ')'
  else if Caption = '' then
    Caption := Name
  else
    Caption := Caption + ' (' + Name + ')';
  MountPoint := StrPas(@Description.MountPoint[0]);
  Index := 0;
  while GetMountDescription(Index, Mount) do
  begin
    if (Mount.Name = Name) and Mount.IsAtDirectory then
      MountPoint := Mount.MountPoint;
    Inc(Index);
  end;
  if Description.IsRemovable then
    Icon := 'drive-usb'
  else
    Icon := 'drive';
  Node := AddPlace(FComputerNode, Caption, MountPoint, MountPoint, Icon, 'tree-volume-' + Name, True);
  PlaceOf(Node).VolumeName := Name;
end;

function TNavigationPane.VolumeNode(const Name: string): TTreeNode;
var
  Index: LongInt;
begin
  Result := nil;
  if FComputerNode = nil then
    Exit;
  for Index := 0 to FComputerNode.Count - 1 do
    if PlaceOf(FComputerNode[Index]).VolumeName = Name then
      Exit(FComputerNode[Index]);
end;

procedure TNavigationPane.VolumesChanged(Handle: Int64);
var
  Reader: TFileChangeReader;
  Change: TFileChange;
  Name: string;
  Node: TTreeNode;
  Place: TPlace;
  MountPoint: string;
begin
  if ReadFileChanges(Reader, Handle) <> ErrorNone then
    Exit;
  while NextFileChange(Reader, Change) do
  begin
    if Change.Name = nil then
      Continue;
    Name := StrPas(Change.Name);
    if Change.Kind = FileChangeCreated then
    begin
      AddVolume(Name);
      Say('volume-added ' + Name);
      TellPlaces;
    end
    else if Change.Kind = FileChangeRemoved then
    begin
      Node := VolumeNode(Name);
      if Node = nil then
        Continue;
      Place := PlaceOf(Node);
      MountPoint := Place.Path;
      FShowingAddress := True;
      ForgetPlacesUnder(Node);
      DeleteNode(Node);
      FShowingAddress := False;
      FPlaces.Remove(Place);
      Place.Free;
      Say('volume-removed ' + Name);
      if Assigned(FOnVolumeRemoved) then
        FOnVolumeRemoved(Self, Name, MountPoint);
    end;
  end;
end;

procedure TNavigationPane.FillSubfolders(Node: TTreeNode);
var
  Items: TFolderItems;
  Index: LongInt;
  Path: string;
  Child: TTreeNode;
begin
  if (Node.Count > 0) or (PlaceOf(Node).Path = '') then
    Exit;
  Path := PlaceOf(Node).Path;
  if ReadFolderItems(Path, False, Items) <> ErrorNone then
  begin
    Node.MayHaveChildren := False;
    Exit;
  end;
  for Index := 0 to High(Items) do
    if IsFolderItem(Items[Index]) then
    begin
      Child := AddPlace(Node, Items[Index].Name, CombinePath(Path, Items[Index].Name),
        CombinePath(Path, Items[Index].Name), 'folder', 'tree-folder-' + Items[Index].Name, True);
      if Child = nil then
        Break;
    end;
  if Node.Count = 0 then
    Node.MayHaveChildren := False;
end;

procedure TNavigationPane.NodeExpanded(Sender: TTreeView; Node: TTreeNode);
begin
  if Node.Expanded and (PlaceOf(Node).Path <> '') then
  begin
    FillSubfolders(Node);
    TellPlaces;
  end;
end;

procedure TNavigationPane.SelectionChanged(Sender: TControl);
begin
  if FShowingAddress or (Selected = nil) then
    Exit;
  if Assigned(FOnPlaceChosen) then
    FOnPlaceChosen(Self, PlaceOf(Selected).Address);
end;

procedure TNavigationPane.ShowAddress(const Address, Path: string);
var
  Index: LongInt;
  Node: TTreeNode;
  Place: TPlace;
  Best: TTreeNode;
begin
  if (Selected <> nil) and (PlaceOf(Selected).Address = Address) then
    Exit;
  Best := nil;
  for Index := 0 to VisibleCount - 1 do
  begin
    Node := VisibleNode(Index);
    Place := PlaceOf(Node);
    if Place.Address = Address then
    begin
      Best := Node;
      Break;
    end;
    if (Path <> '') and (Place.Path <> '') and IsSameOrInside(Path, Place.Path) and
       ((Best = nil) or (Length(Place.Path) > Length(PlaceOf(Best).Path))) then
      Best := Node;
  end;
  FShowingAddress := True;
  Selected := Best;
  FShowingAddress := False;
end;

procedure TNavigationPane.TellPlaces;
var
  Index: LongInt;
  Node: TTreeNode;
begin
  for Index := 0 to VisibleCount - 1 do
  begin
    Node := VisibleNode(Index);
    TellPlace(PlaceOf(Node).TestName, Self, NodeTextLeft(Node) + Scaled(12), RowMiddle(Index));
  end;
end;

{ --- Dropping --------------------------------------------------------------------------------- }

function TNavigationPane.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Node: TTreeNode;
  Paths: TStringList;
  Action: TFileListAction;
begin
  Result := DropNone;
  DropTarget := nil;
  Node := NodeAt(X, Y);
  if (Node = nil) or (Data.Format <> DragFormatFileList) then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) or (Paths.Count = 0) then
      Exit;
    if Node = FHomeNode then
    begin
      { Folders dropped on Home are pinned. }
      if IsDirectory(PChar(Paths[0])) then
      begin
        Result := DropLink;
        DropTarget := Node;
      end;
      Exit;
    end;
    if (PlaceOf(Node).Path = '') or not CanDropInto(Paths, PlaceOf(Node).Path) then
      Exit;
    Result := DropEffectFor(VolumeNumberOf(Paths[0]), VolumeNumberOf(PlaceOf(Node).Path),
      (Modifiers and ModifierControl) <> 0, (Modifiers and ModifierShift) <> 0);
    DropTarget := Node;
  finally
    Paths.Free;
  end;
end;

procedure TNavigationPane.DragLeave;
begin
  DropTarget := nil;
end;

procedure TNavigationPane.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Node: TTreeNode;
  Paths: TStringList;
  Action: TFileListAction;
begin
  DropTarget := nil;
  Node := NodeAt(X, Y);
  if Node = nil then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) then
      Exit;
    if (Node = FHomeNode) and Assigned(FOnPinFolders) then
      FOnPinFolders(Self, Paths)
    else if (PlaceOf(Node).Path <> '') and Assigned(FOnDropFiles) then
      FOnDropFiles(Self, Paths, PlaceOf(Node).Path, Effect);
  finally
    Paths.Free;
  end;
end;

end.
