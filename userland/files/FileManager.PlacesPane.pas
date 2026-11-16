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
  The pane at the left: places to go to. The user's home folder, the
  file system's root, and Volumes with every volume under it (its label
  and name, a removable disk's icon for a disk that can be unplugged).

  The list of volumes is watched (Sys.Volumes): a disk plugged in shows
  at once ("volume-added NAME"), one unplugged goes ("volume-removed
  NAME", and OnVolumeRemoved, so a window showing a folder on it can go
  somewhere else). Choosing a place tells OnPlaceChosen; showing where
  the window is (ShowPath) picks the place the folder is in without
  telling. Files dragged onto a place drop into it (OnDropFiles).
}
unit FileManager.PlacesPane;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.DragData,
  Controls.TreeView,
  FileManager.FolderView;

type
  { What a node of the pane stands for. }
  TPlace = class
  public
    Path: string;
    { The volume's name, for a volume ('' for the others). }
    VolumeName: string;
    TestName: string;
  end;

  TPlaceEvent = procedure(Sender: TControl; const Path: string) of object;
  TVolumeEvent = procedure(Sender: TControl; const VolumeName, MountPoint: string) of object;

  TPlacesPane = class(TTreeView)
  private
    FPlaces: TList;
    FHomeNode: TTreeNode;
    FRootNode: TTreeNode;
    FVolumesNode: TTreeNode;
    FWatch: Int64;
    FShowingPath: Boolean;
    FOnPlaceChosen: TPlaceEvent;
    FOnVolumeRemoved: TVolumeEvent;
    FOnDropFiles: TDropFilesEvent;
    function AddPlace(ParentNode: TTreeNode; const Caption, Path, VolumeName, TestName: string): TTreeNode;
    procedure AddVolume(const Name: string);
    function VolumeNode(const Name: string): TTreeNode;
    procedure VolumesChanged(Handle: Int64);
    procedure SelectionChanged(Sender: TControl);
  protected
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function PlaceOf(Node: TTreeNode): TPlace;
    { Picks the place Path is in (without telling OnPlaceChosen). }
    procedure ShowPath(const Path: string);
    procedure TellPlaces;
    property OnPlaceChosen: TPlaceEvent read FOnPlaceChosen write FOnPlaceChosen;
    property OnVolumeRemoved: TVolumeEvent read FOnVolumeRemoved write FOnVolumeRemoved;
    property OnDropFiles: TDropFilesEvent read FOnDropFiles write FOnDropFiles;
  end;

{ The user's home folder ("/" without one). }
function HomeFolder: string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Files,
  Sys.Environment,
  Sys.FileWatches,
  Sys.Volumes,
  Windowing.Connection,
  Windowing.HandleWatches,
  Controls.Icons,
  Controls.FileNames,
  Controls.FileLists,
  FileManager.Paths,
  FileManager.FolderReading,
  FileManager.DropRules,
  FileManager.TestPlaces,
  FileManager.Output;

function HomeFolder: string;
var
  Home: PChar;
begin
  Home := GetVariable('HOME');
  if (Home = nil) or (Home^ = #0) then
    Exit('/');
  Result := CleanPath(StrPas(Home));
end;

constructor TPlacesPane.Create(AParent: TControl);
var
  Index: LongInt;
  Description: TVolumeDescription;
begin
  inherited Create(AParent);
  FPlaces := TList.Create;
  ShowLines := False;
  FHomeNode := AddPlace(nil, 'Home', HomeFolder, '', 'tree-home');
  FHomeNode.SetIcon(StockIconHome);
  FRootNode := AddPlace(nil, 'File system', '/', '', 'tree-root');
  FRootNode.SetIcon(StockIconFixedDisk);
  FVolumesNode := AddPlace(nil, 'Volumes', VolumesFolder, '', 'tree-volumes');
  FVolumesNode.SetIcon(StockIconComputer);
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    AddVolume(StrPas(@Description.Name[0]));
    Inc(Index);
  end;
  FVolumesNode.Expanded := True;
  FWatch := WatchVolumes;
  if FWatch >= 0 then
    WatchHandle(FWatch, @VolumesChanged);
  OnChange := @SelectionChanged;
end;

destructor TPlacesPane.Destroy;
var
  Index: LongInt;
begin
  if FWatch >= 0 then
  begin
    StopWatchingHandle(FWatch);
    CloseHandle(FWatch);
  end;
  for Index := 0 to FPlaces.Count - 1 do
    TPlace(FPlaces[Index]).Free;
  FPlaces.Free;
  inherited Destroy;
end;

function TPlacesPane.AddPlace(ParentNode: TTreeNode; const Caption, Path, VolumeName, TestName: string): TTreeNode;
var
  Place: TPlace;
begin
  Place := TPlace.Create;
  Place.Path := Path;
  Place.VolumeName := VolumeName;
  Place.TestName := TestName;
  FPlaces.Add(Place);
  if ParentNode = nil then
    Result := AddRoot(Caption)
  else
    Result := ParentNode.Add(Caption);
  Result.Data := Place;
end;

function TPlacesPane.PlaceOf(Node: TTreeNode): TPlace;
begin
  if Node = nil then
    Exit(nil);
  Result := TPlace(Node.Data);
end;

procedure TPlacesPane.AddVolume(const Name: string);
var
  Description: TVolumeDescription;
  Caption: string;
  Node: TTreeNode;
begin
  if (VolumeNode(Name) <> nil) or not FindVolumeDescription(PChar(Name), Description) then
    Exit;
  Caption := StrPas(@Description.VolumeLabel[0]);
  if Caption = '' then
    Caption := Name
  else
    Caption := Caption + ' (' + Name + ')';
  Node := AddPlace(FVolumesNode, Caption, StrPas(@Description.MountPoint[0]), Name, 'tree-volume-' + Name);
  if Description.IsRemovable then
    Node.SetIcon(StockIconRemovableDisk)
  else
    Node.SetIcon(StockIconFixedDisk);
end;

function TPlacesPane.VolumeNode(const Name: string): TTreeNode;
var
  Index: LongInt;
begin
  for Index := 0 to FVolumesNode.Count - 1 do
    if PlaceOf(FVolumesNode[Index]).VolumeName = Name then
      Exit(FVolumesNode[Index]);
  Result := nil;
end;

procedure TPlacesPane.VolumesChanged(Handle: Int64);
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
      FShowingPath := True;
      DeleteNode(Node);
      FShowingPath := False;
      FPlaces.Remove(Place);
      Place.Free;
      Say('volume-removed ' + Name);
      if Assigned(FOnVolumeRemoved) then
        FOnVolumeRemoved(Self, Name, MountPoint);
    end;
  end;
end;

procedure TPlacesPane.SelectionChanged(Sender: TControl);
begin
  if FShowingPath or (Selected = nil) then
    Exit;
  if Assigned(FOnPlaceChosen) then
    FOnPlaceChosen(Self, PlaceOf(Selected).Path);
end;

procedure TPlacesPane.ShowPath(const Path: string);
var
  Index: LongInt;
  Place: TPlace;
  Best: TPlace;
  BestNode: TTreeNode;
  Node: TTreeNode;
begin
  { The place chosen is kept while it is the folder shown (home and the
    file system are the same folder for root). }
  if (Selected <> nil) and (PlaceOf(Selected).Path = Path) then
    Exit;
  Best := nil;
  BestNode := nil;
  { The deepest place the path is in (the first of equals). }
  for Index := 0 to VisibleCount - 1 do
  begin
    Node := VisibleNode(Index);
    Place := PlaceOf(Node);
    if IsSameOrInside(Path, Place.Path) and ((Best = nil) or (Length(Place.Path) > Length(Best.Path))) then
    begin
      Best := Place;
      BestNode := Node;
    end;
  end;
  FShowingPath := True;
  Selected := BestNode;
  FShowingPath := False;
end;

procedure TPlacesPane.TellPlaces;
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

{ --- Dropping ------------------------------------------------------------------------- }

function TPlacesPane.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Node: TTreeNode;
  Paths: TStringList;
  Action: TFileListAction;
begin
  Result := DropNone;
  DropTarget := nil;
  Node := NodeAt(X, Y);
  if (Node = nil) or (Data.Format <> DragFormatFileList) or (PlaceOf(Node).Path = VolumesFolder) then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) or not CanDropInto(Paths, PlaceOf(Node).Path) then
      Exit;
    Result := DropEffectFor(VolumeNumberOf(Paths[0]), VolumeNumberOf(PlaceOf(Node).Path), (Modifiers and ModifierControl) <> 0,
      (Modifiers and ModifierShift) <> 0);
    DropTarget := Node;
  finally
    Paths.Free;
  end;
end;

procedure TPlacesPane.DragLeave;
begin
  DropTarget := nil;
end;

procedure TPlacesPane.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Node: TTreeNode;
  Paths: TStringList;
  Action: TFileListAction;
begin
  Node := NodeAt(X, Y);
  if Node = nil then
    Exit;
  Paths := TStringList.Create;
  try
    if DecodeFileList(Data.Text, Action, Paths) and Assigned(FOnDropFiles) then
      FOnDropFiles(Self, Paths, PlaceOf(Node).Path, Effect);
  finally
    Paths.Free;
  end;
end;

end.
