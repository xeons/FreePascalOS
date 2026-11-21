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
  The Library (Bookmarks > Organize Bookmarks..., History > Show All
  History): a window of its own with
  - a toolbar: Back and Forward (through the places chosen), Organize
    (New Bookmark..., New Folder..., New Separator, Delete, Close),
    Views (sort by name, or as they are), Import and Backup (Export
    Bookmarks to HTML..., Backup..., Restore...), and a search box;
  - a tree on the left: History (and its days), Tags (each tag), All
    Bookmarks with the Bookmarks Toolbar, Bookmarks Menu and Unsorted
    Bookmarks folders and theirs;
  - the chosen place's contents in a list with columns (Name, Tags,
    Location, Most Recent Visit, Visit Count);
  - under it the chosen bookmark's details - name, location, tags,
    keyword, description - kept as they are typed.
  Bookmarks dragged from the list onto a folder of the tree move there;
  a double click opens a bookmark (in the browser's window) or a folder.
}
unit Browser.LibraryWindow;

{$mode objfpc}
{$H+}

interface

type
  TLibraryMode = (LibraryHistory, LibraryBookmarks);

procedure ShowLibrary(Mode: TLibraryMode);

implementation

uses
  SysUtils,
  Classes,
  DateUtils,
  Controls.Base,
  Controls.Window,
  Controls.Panels,
  Controls.Labels,
  Controls.Buttons,
  Controls.EditBox,
  Controls.ToolBar,
  Controls.Menus,
  Controls.ImageList,
  Controls.IconTheme,
  Controls.TreeView,
  Controls.ListView,
  Controls.ListItems,
  Controls.Splitter,
  Controls.DragData,
  Controls.Icons,
  Controls.LayoutRules,
  Controls.FileDialog,
  Controls.MessageBoxes,
  Controls.Dialogs,
  Controls.Keys,
  Browser.History,
  Browser.Bookmarks,
  Browser.BookmarkDialogs,
  Browser.BookmarksToolbar,
  Browser.TextFiles,
  Browser.Profile,
  Browser.Application,
  Browser.Output;

type
  TPlaceKind = (PlaceHistory, PlaceHistoryAge, PlaceTags, PlaceTag, PlaceFolder);

  { What a tree node stands for. }
  TPlace = class
  public
    Kind: TPlaceKind;
    Age: THistoryAge;
    Tag: string;
    FolderId: Integer;
  end;

  { What a row of the list stands for. }
  TRow = class
  public
    Url: string;
    NodeId: Integer;
    Tag: string;
  end;

  TLibraryWindow = class(TControlWindow)
  private
    FImages: TImageList;
    FToolBar: TToolBar;
    FBackButton, FForwardButton: TToolButton;
    FOrganizeMenu, FViewsMenu, FBackupMenu: TMenuItem;
    FSearch: TEditBox;
    FTree: TTreeView;
    FList: TListView;
    FDetails: TPanel;
    FNameEdit, FLocationEdit, FTagsEdit, FKeywordEdit, FDescriptionEdit: TEditBox;
    FPlaces: TList;
    FRows: TList;
    FHistoryNode, FTagsNode, FAllNode: TTreeNode;
    FBack, FForward: TList;
    FNavigating: Boolean;
    FSorted: Boolean;
    FFilling: Boolean;
    FDetailNode: Integer;
    function NewPlace(Kind: TPlaceKind): TPlace;
    procedure BuildTree;
    procedure AddFolderNodes(Parent: TTreeNode; Folder: TBookmarkNode);
    function NodeOfFolder(FolderId: Integer): TTreeNode;
    function ChosenPlace: TPlace;
    function ChosenRow: TRow;
    procedure ClearRows;
    function AddRow(const Texts: array of string; const Url: string; NodeId: Integer; Icon: TStockIcon): TRow;
    procedure FillList;
    procedure FillHistory(Place: TPlace);
    procedure FillFolder(Folder: TBookmarkNode);
    procedure FillBookmarks(const Nodes: TBookmarkNodeList);
    procedure ShowDetails;
    procedure KeepDetails;
    procedure TreeChanged(Sender: TControl);
    procedure ListChanged(Sender: TControl);
    procedure ListActivated(Sender: TControl);
    procedure ListKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure ListStartDrag(Sender: TListView; var Data: TDragData);
    procedure TreeDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
      var Effect: TDropEffect);
    procedure TreeDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
    procedure TreeDragLeave(Sender: TControl);
    procedure SearchChanged(Sender: TControl);
    procedure DetailKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure BackClicked(Sender: TControl);
    procedure ForwardClicked(Sender: TControl);
    procedure OrganizeChosen(Item: TMenuItem);
    procedure ViewsChosen(Item: TMenuItem);
    procedure BackupChosen(Item: TMenuItem);
    procedure DeleteChosen;
    procedure ExportHtml;
    function CurrentFolder: TBookmarkNode;
    procedure UpdateNavigation;
  protected
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ShowMode(Mode: TLibraryMode);
    procedure Refresh;
  end;

var
  LibraryWindow: TLibraryWindow;

const
  OrganizeNewBookmark = 1;
  OrganizeNewFolder = 2;
  OrganizeNewSeparator = 3;
  OrganizeDelete = 4;
  OrganizeClose = 5;
  OrganizeForgetSite = 6;
  ViewsSortByName = 1;
  ViewsUnsorted = 2;
  BackupExport = 1;
  BackupSave = 2;
  BackupRestore = 3;
  BackupImport = 4;

{ ---- building ---- }

constructor TLibraryWindow.Create;
var
  Top: TControl;
  Splitter: TSplitter;
  Button: TToolButton;
  Row: LongInt;

  function DetailRow(const Caption: string): TEditBox;
  var
    Text: TLabel;
  begin
    Text := TLabel.Create(FDetails);
    Text.Text := Caption;
    Text.SetBounds(8, 8 + Row * 26 + 3, 90, 18);
    Result := TEditBox.Create(FDetails);
    Result.SetBounds(100, 8 + Row * 26, 400, 22);
    Result.Anchors := [akLeft, akTop, akRight];
    Result.OnKeyDown := @DetailKey;
    Inc(Row);
  end;

begin
  inherited Create('Library', 90, 70, 820, 560);
  IconName := 'library';
  FPlaces := TList.Create;
  FRows := TList.Create;
  FBack := TList.Create;
  FForward := TList.Create;
  FDetailNode := -1;
  FImages := TImageList.Create(16, 16);
  FToolBar := TToolBar.Create(Root);
  FToolBar.Images := FImages;
  FBackButton := FToolBar.AddImageButton(AddThemeIcon(FImages, 'action-back'), '', 'Go back', 28, @BackClicked);
  FForwardButton := FToolBar.AddImageButton(AddThemeIcon(FImages, 'action-forward'), '', 'Go forward', 28,
    @ForwardClicked);
  FToolBar.AddSeparator;
  FOrganizeMenu := TMenuItem.Create('');
  FOrganizeMenu.Add('New &Bookmark...', @OrganizeChosen).Tag := OrganizeNewBookmark;
  FOrganizeMenu.Add('New &Folder...', @OrganizeChosen).Tag := OrganizeNewFolder;
  FOrganizeMenu.Add('New &Separator', @OrganizeChosen).Tag := OrganizeNewSeparator;
  FOrganizeMenu.AddSeparator;
  FOrganizeMenu.Add('&Delete', @OrganizeChosen, 'Del').Tag := OrganizeDelete;
  FOrganizeMenu.Add('Forget About This &Site', @OrganizeChosen).Tag := OrganizeForgetSite;
  FOrganizeMenu.AddSeparator;
  FOrganizeMenu.Add('&Close', @OrganizeChosen).Tag := OrganizeClose;
  Button := FToolBar.AddButton('&Organize', 0);
  Button.DropDownKind := DropDownWhole;
  Button.DropDownMenu := FOrganizeMenu;
  FViewsMenu := TMenuItem.Create('');
  FViewsMenu.Add('&Unsorted', @ViewsChosen).Tag := ViewsUnsorted;
  FViewsMenu.Add('Sort by &Name', @ViewsChosen).Tag := ViewsSortByName;
  Button := FToolBar.AddButton('&Views', 0);
  Button.DropDownKind := DropDownWhole;
  Button.DropDownMenu := FViewsMenu;
  FBackupMenu := TMenuItem.Create('');
  FBackupMenu.Add('&Import Bookmarks from HTML...', @BackupChosen).Tag := BackupImport;
  FBackupMenu.Add('&Export Bookmarks to HTML...', @BackupChosen).Tag := BackupExport;
  FBackupMenu.AddSeparator;
  FBackupMenu.Add('&Backup...', @BackupChosen).Tag := BackupSave;
  FBackupMenu.Add('&Restore...', @BackupChosen).Tag := BackupRestore;
  Button := FToolBar.AddButton('&Import and Backup', 0);
  Button.DropDownKind := DropDownWhole;
  Button.DropDownMenu := FBackupMenu;
  Top := TPanel.Create(Root);
  TPanel(Top).Edge := PanelFlat;
  Top.Align := AlignTop;
  Top.SetBounds(0, 0, 400, 30);
  FSearch := TEditBox.Create(Top);
  FSearch.Align := AlignRight;
  FSearch.SetBounds(0, 0, 240, 22);
  FSearch.Margins := MakeSpacing(4, 4, 8, 4);
  FSearch.Placeholder := 'Search';
  FSearch.OnChange := @SearchChanged;
  FTree := TTreeView.Create(Root);
  FTree.Align := AlignLeft;
  FTree.SetBounds(0, 0, 200, 300);
  FTree.OnChange := @TreeChanged;
  FTree.OnDragOver := @TreeDragOver;
  FTree.OnDragDrop := @TreeDragDrop;
  FTree.OnDragLeave := @TreeDragLeave;
  Splitter := TSplitter.Create(Root);
  Splitter.Align := AlignLeft;
  FDetails := TPanel.Create(Root);
  FDetails.Edge := PanelFlat;
  FDetails.Align := AlignBottom;
  FDetails.SetBounds(0, 0, 400, 8 + 5 * 26 + 8);
  Row := 0;
  FNameEdit := DetailRow('&Name:');
  FLocationEdit := DetailRow('&Location:');
  FTagsEdit := DetailRow('&Tags:');
  FTagsEdit.Placeholder := 'Separate tags with commas';
  FKeywordEdit := DetailRow('&Keyword:');
  FDescriptionEdit := DetailRow('&Description:');
  FList := TListView.Create(Root);
  FList.Align := AlignClient;
  FList.AddColumn('Name', 220);
  FList.AddColumn('Tags', 100);
  FList.AddColumn('Location', 230);
  FList.AddColumn('Most Recent Visit', 120);
  FList.AddColumn('Visit Count', 70);
  FList.ColumnNumeric[4] := True;
  FList.IconsInDetails := True;
  FList.SortOnHeaderClick := True;
  FList.DragEnabled := True;
  FList.OnStartDrag := @ListStartDrag;
  FList.OnChange := @ListChanged;
  FList.OnActivate := @ListActivated;
  FList.OnKeyDown := @ListKey;
  BuildTree;
end;

destructor TLibraryWindow.Destroy;
var
  Index: Integer;
begin
  ClearRows;
  for Index := 0 to FPlaces.Count - 1 do
    TPlace(FPlaces[Index]).Free;
  FPlaces.Free;
  FRows.Free;
  FBack.Free;
  FForward.Free;
  FOrganizeMenu.Free;
  FViewsMenu.Free;
  FBackupMenu.Free;
  FImages.Free;
  inherited Destroy;
end;

procedure TLibraryWindow.CloseRequested;
begin
  KeepDetails;
  Hide;
end;

function TLibraryWindow.NewPlace(Kind: TPlaceKind): TPlace;
begin
  Result := TPlace.Create;
  Result.Kind := Kind;
  FPlaces.Add(Result);
end;

procedure TLibraryWindow.AddFolderNodes(Parent: TTreeNode; Folder: TBookmarkNode);
var
  Index: Integer;
  Node: TTreeNode;
  Place: TPlace;
begin
  for Index := 0 to Folder.Count - 1 do
    if Folder[Index].IsFolder then
    begin
      Node := Parent.Add(Folder[Index].ShownTitle);
      Node.SetIcon(StockIconFolder);
      Place := NewPlace(PlaceFolder);
      Place.FolderId := Folder[Index].Id;
      Node.Data := Place;
      AddFolderNodes(Node, Folder[Index]);
    end;
end;

procedure TLibraryWindow.BuildTree;
var
  Place: TPlace;
  Node: TTreeNode;
  Age: THistoryAge;
  Tags: TStringArray;
  Index: Integer;
begin
  FFilling := True;
  try
    FTree.Clear;
    for Index := 0 to FPlaces.Count - 1 do
      TPlace(FPlaces[Index]).Free;
    FPlaces.Clear;
    FHistoryNode := FTree.AddRoot('History');
    FHistoryNode.SetIcon(StockIconFolder);
    FHistoryNode.Data := NewPlace(PlaceHistory);
    for Age := Low(THistoryAge) to High(THistoryAge) do
    begin
      Node := FHistoryNode.Add(HistoryAgeName(Age));
      Node.SetIcon(StockIconFolder);
      Place := NewPlace(PlaceHistoryAge);
      Place.Age := Age;
      Node.Data := Place;
    end;
    FTagsNode := FTree.AddRoot('Tags');
    FTagsNode.SetIcon(StockIconFolder);
    FTagsNode.Data := NewPlace(PlaceTags);
    Tags := BrowserApp.Bookmarks.AllTags;
    for Index := 0 to High(Tags) do
    begin
      Node := FTagsNode.Add(Tags[Index]);
      Node.SetIcon(StockIconFolder);
      Place := NewPlace(PlaceTag);
      Place.Tag := Tags[Index];
      Node.Data := Place;
    end;
    FAllNode := FTree.AddRoot('All Bookmarks');
    FAllNode.SetIcon(StockIconFavourites);
    Place := NewPlace(PlaceFolder);
    Place.FolderId := RootFolderId;
    FAllNode.Data := Place;
    AddFolderNodes(FAllNode, BrowserApp.Bookmarks.Root);
    FAllNode.Expanded := True;
  finally
    FFilling := False;
  end;
end;

function TLibraryWindow.NodeOfFolder(FolderId: Integer): TTreeNode;

  function Find(Node: TTreeNode): TTreeNode;
  var
    Index: Integer;
  begin
    if (Node.Data <> nil) and (TPlace(Node.Data).Kind = PlaceFolder) and (TPlace(Node.Data).FolderId = FolderId) then
      Exit(Node);
    for Index := 0 to Node.Count - 1 do
    begin
      Result := Find(Node[Index]);
      if Result <> nil then
        Exit;
    end;
    Result := nil;
  end;

begin
  Result := Find(FAllNode);
end;

procedure TLibraryWindow.Refresh;
var
  Place: TPlace;
  FolderId: Integer;
  Kind: TPlaceKind;
  Node: TTreeNode;
begin
  Place := ChosenPlace;
  Kind := PlaceFolder;
  FolderId := RootFolderId;
  if Place <> nil then
  begin
    Kind := Place.Kind;
    FolderId := Place.FolderId;
  end;
  BuildTree;
  FFilling := True;
  try
    case Kind of
      PlaceHistory, PlaceHistoryAge:
        FTree.Selected := FHistoryNode;
      PlaceTags, PlaceTag:
        FTree.Selected := FTagsNode;
    else
      begin
        Node := NodeOfFolder(FolderId);
        if Node = nil then
          Node := FAllNode;
        FTree.Selected := Node;
      end;
    end;
  finally
    FFilling := False;
  end;
  FillList;
end;

procedure TLibraryWindow.ShowMode(Mode: TLibraryMode);
begin
  if Mode = LibraryHistory then
    FTree.Selected := FHistoryNode
  else
    FTree.Selected := FAllNode;
  FillList;
end;

{ ---- the list ---- }

function TLibraryWindow.ChosenPlace: TPlace;
begin
  if (FTree.Selected = nil) or (FTree.Selected.Data = nil) then
    Result := nil
  else
    Result := TPlace(FTree.Selected.Data);
end;

function TLibraryWindow.ChosenRow: TRow;
begin
  if (FList.ItemIndex < 0) or (FList.Items[FList.ItemIndex].Data = nil) then
    Result := nil
  else
    Result := TRow(FList.Items[FList.ItemIndex].Data);
end;

procedure TLibraryWindow.ClearRows;
var
  Index: Integer;
begin
  for Index := 0 to FRows.Count - 1 do
    TRow(FRows[Index]).Free;
  FRows.Clear;
  FList.Clear;
end;

function TLibraryWindow.AddRow(const Texts: array of string; const Url: string; NodeId: Integer;
  Icon: TStockIcon): TRow;
var
  Index: LongInt;
begin
  Result := TRow.Create;
  Result.Url := Url;
  Result.NodeId := NodeId;
  FRows.Add(Result);
  Index := FList.AddRow(Texts);
  FList.Items[Index].Data := Result;
  FList.Items[Index].IconKind := Icon;
end;

function VisitText(Time: Int64): string;
begin
  if Time <= 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', UniversalTimeToLocal(UnixToDateTime(Time)));
end;

procedure TLibraryWindow.FillHistory(Place: TPlace);
var
  Places: THistoryPlaceList;
  Index: Integer;
  Name: string;
  Now: Int64;
begin
  if Trim(FSearch.Text) <> '' then
    Places := BrowserApp.History.Search(FSearch.Text)
  else
    Places := BrowserApp.History.Places;
  Now := BrowserApp.NowUnix;
  for Index := 0 to High(Places) do
  begin
    if (Place.Kind = PlaceHistoryAge) and (HistoryAgeOf(Places[Index].LastVisit, Now) <> Place.Age) then
      Continue;
    Name := Places[Index].Title;
    if Name = '' then
      Name := Places[Index].Url;
    AddRow([Name, '', Places[Index].Url, VisitText(Places[Index].LastVisit), IntToStr(Places[Index].VisitCount)],
      Places[Index].Url, -1, StockIconInternet);
  end;
end;

procedure TLibraryWindow.FillBookmarks(const Nodes: TBookmarkNodeList);
var
  Index: Integer;
  Place: THistoryPlace;
  Node: TBookmarkNode;
begin
  for Index := 0 to High(Nodes) do
  begin
    Node := Nodes[Index];
    case Node.Kind of
      BookmarkFolder:
        AddRow([Node.ShownTitle, '', '', '', ''], '', Node.Id, StockIconFolder);
      BookmarkSeparator:
        AddRow(['----------------', '', '', '', ''], '', Node.Id, StockIconDocument);
      BookmarkItem:
        begin
          if not BrowserApp.History.FindPlace(Node.Url, Place) then
            Place := Default(THistoryPlace);
          AddRow([Node.ShownTitle, Node.TagText, Node.Url, VisitText(Place.LastVisit), IntToStr(Place.VisitCount)],
            Node.Url, Node.Id, StockIconInternet);
        end;
    end;
  end;
end;

procedure TLibraryWindow.FillFolder(Folder: TBookmarkNode);
var
  Nodes: TBookmarkNodeList;
  Index: Integer;
begin
  Nodes := nil;
  SetLength(Nodes, Folder.Count);
  for Index := 0 to Folder.Count - 1 do
    Nodes[Index] := Folder[Index];
  FillBookmarks(Nodes);
end;

procedure TLibraryWindow.FillList;
var
  Place: TPlace;
  Tags: TStringArray;
  Index: Integer;
  Folder: TBookmarkNode;
  Row: TRow;
begin
  KeepDetails;
  ClearRows;
  Place := ChosenPlace;
  if Place = nil then
    Exit;
  if (Trim(FSearch.Text) <> '') and (Place.Kind in [PlaceFolder, PlaceTags, PlaceTag]) then
    FillBookmarks(BrowserApp.Bookmarks.Search(FSearch.Text))
  else
    case Place.Kind of
      PlaceHistory, PlaceHistoryAge:
        FillHistory(Place);
      PlaceTags:
        begin
          Tags := BrowserApp.Bookmarks.AllTags;
          for Index := 0 to High(Tags) do
          begin
            Row := AddRow([Tags[Index], '', '', '', IntToStr(Length(BrowserApp.Bookmarks.Tagged(Tags[Index])))], '',
              -1, StockIconFolder);
            Row.Tag := Tags[Index];
          end;
        end;
      PlaceTag:
        FillBookmarks(BrowserApp.Bookmarks.Tagged(Place.Tag));
      PlaceFolder:
        begin
          Folder := BrowserApp.Bookmarks.NodeById(Place.FolderId);
          if Folder <> nil then
            FillFolder(Folder);
        end;
    end;
  if FSorted then
    FList.SortByColumn(0, True);
  ShowDetails;
  UpdateNavigation;
  Say('library ' + FTree.Selected.Text + ' ' + IntToStr(FList.RowCount));
end;

function TLibraryWindow.CurrentFolder: TBookmarkNode;
var
  Place: TPlace;
begin
  Result := nil;
  Place := ChosenPlace;
  if (Place <> nil) and (Place.Kind = PlaceFolder) then
    Result := BrowserApp.Bookmarks.NodeById(Place.FolderId);
  if (Result = nil) or (Result.Id = RootFolderId) then
    Result := BrowserApp.Bookmarks.MenuFolder;
end;

{ ---- details ---- }

procedure TLibraryWindow.ShowDetails;
var
  Row: TRow;
  Node: TBookmarkNode;
  IsBookmark: Boolean;
begin
  Row := ChosenRow;
  Node := nil;
  if (Row <> nil) and (Row.NodeId >= 0) then
    Node := BrowserApp.Bookmarks.NodeById(Row.NodeId);
  IsBookmark := (Node <> nil) and (Node.Kind = BookmarkItem);
  FNameEdit.Enabled := (Node <> nil) and (Node.Kind <> BookmarkSeparator) and (Node.Id > UnsortedFolderId);
  FLocationEdit.Enabled := IsBookmark;
  FTagsEdit.Enabled := IsBookmark;
  FKeywordEdit.Enabled := IsBookmark;
  FDescriptionEdit.Enabled := FNameEdit.Enabled;
  if Node = nil then
  begin
    FDetailNode := -1;
    FNameEdit.Text := '';
    FLocationEdit.Text := '';
    FTagsEdit.Text := '';
    FKeywordEdit.Text := '';
    FDescriptionEdit.Text := '';
    if Row <> nil then
    begin
      FNameEdit.Text := FList.Cells[FList.ItemIndex, 0];
      FLocationEdit.Text := Row.Url;
    end;
    Exit;
  end;
  FDetailNode := Node.Id;
  FNameEdit.Text := Node.Title;
  FLocationEdit.Text := Node.Url;
  FTagsEdit.Text := Node.TagText;
  FKeywordEdit.Text := Node.Keyword;
  FDescriptionEdit.Text := Node.Description;
end;

{ What was typed in the details goes into the bookmark. }
procedure TLibraryWindow.KeepDetails;
var
  Node: TBookmarkNode;
  Changed: Boolean;
begin
  if FDetailNode < 0 then
    Exit;
  Node := BrowserApp.Bookmarks.NodeById(FDetailNode);
  if (Node = nil) or (Node.Kind = BookmarkSeparator) then
    Exit;
  Changed := (Node.Title <> FNameEdit.Text) or (Node.Description <> FDescriptionEdit.Text);
  if Node.Kind = BookmarkItem then
    Changed := Changed or (Node.Url <> FLocationEdit.Text) or (Node.TagText <> FTagsEdit.Text) or
      (Node.Keyword <> FKeywordEdit.Text);
  if not Changed then
    Exit;
  Node.Title := FNameEdit.Text;
  Node.Description := FDescriptionEdit.Text;
  if Node.Kind = BookmarkItem then
  begin
    Node.Url := Trim(FLocationEdit.Text);
    Node.Tags := ParseTags(FTagsEdit.Text);
    Node.Keyword := Trim(FKeywordEdit.Text);
  end;
  BrowserApp.Bookmarks.Changed;
  Say('library edited ' + Node.Title);
end;

procedure TLibraryWindow.DetailKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    KeepDetails;
    Refresh;
  end;
end;

{ ---- events ---- }

procedure TLibraryWindow.TreeChanged(Sender: TControl);
var
  Place: TPlace;
begin
  if FFilling then
    Exit;
  Place := ChosenPlace;
  if not FNavigating and (Place <> nil) then
  begin
    FBack.Add(FTree.Selected);
    FForward.Clear;
  end;
  FillList;
end;

procedure TLibraryWindow.ListChanged(Sender: TControl);
begin
  KeepDetails;
  ShowDetails;
end;

procedure TLibraryWindow.ListActivated(Sender: TControl);
var
  Row: TRow;
  Node: TBookmarkNode;
  TreeNode: TTreeNode;
  Index: Integer;
begin
  Row := ChosenRow;
  if Row = nil then
    Exit;
  if Row.Tag <> '' then
  begin
    for Index := 0 to FTagsNode.Count - 1 do
      if FTagsNode[Index].Text = Row.Tag then
      begin
        FTagsNode.Expanded := True;
        FTree.Selected := FTagsNode[Index];
      end;
    Exit;
  end;
  Node := nil;
  if Row.NodeId >= 0 then
    Node := BrowserApp.Bookmarks.NodeById(Row.NodeId);
  if (Node <> nil) and Node.IsFolder then
  begin
    TreeNode := NodeOfFolder(Node.Id);
    if TreeNode <> nil then
    begin
      if TreeNode.Parent <> nil then
        TreeNode.Parent.Expanded := True;
      FTree.Selected := TreeNode;
    end;
    Exit;
  end;
  if Row.Url <> '' then
    BrowserApp.OpenInActiveWindow(Row.Url);
end;

procedure TLibraryWindow.ListKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if Code = KeyDelete then
  begin
    Handled := True;
    DeleteChosen;
  end;
end;

procedure TLibraryWindow.ListStartDrag(Sender: TListView; var Data: TDragData);
var
  Row: TRow;
begin
  Data := nil;
  Row := ChosenRow;
  if Row = nil then
    Exit;
  if Row.NodeId >= 0 then
    Data := TDragData.Create(DragFormatBookmark, IntToStr(Row.NodeId), Sender)
  else if Row.Url <> '' then
    Data := TDragData.Create(DragFormatText, Row.Url, Sender);
end;

procedure TLibraryWindow.TreeDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
  var Effect: TDropEffect);
var
  Node: TTreeNode;
begin
  Effect := DropNone;
  Node := FTree.NodeAt(X, Y);
  if (Node <> nil) and (Node.Data <> nil) and (TPlace(Node.Data).Kind = PlaceFolder) and
     (TPlace(Node.Data).FolderId <> RootFolderId) and
     ((Data.Format = DragFormatBookmark) or (Data.Format = DragFormatText)) then
  begin
    Effect := DropMove;
    FTree.DropTarget := Node;
  end
  else
    FTree.DropTarget := nil;
end;

procedure TLibraryWindow.TreeDragLeave(Sender: TControl);
begin
  FTree.DropTarget := nil;
end;

procedure TLibraryWindow.TreeDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Node: TTreeNode;
  Folder, Dragged: TBookmarkNode;
begin
  FTree.DropTarget := nil;
  Node := FTree.NodeAt(X, Y);
  if (Node = nil) or (Node.Data = nil) or (TPlace(Node.Data).Kind <> PlaceFolder) then
    Exit;
  Folder := BrowserApp.Bookmarks.NodeById(TPlace(Node.Data).FolderId);
  if Folder = nil then
    Exit;
  if Data.Format = DragFormatBookmark then
  begin
    Dragged := BrowserApp.Bookmarks.NodeById(StrToIntDef(Data.Text, 0));
    if (Dragged <> nil) and BrowserApp.Bookmarks.Move(Dragged, Folder, -1) then
      Say('library moved ' + Dragged.ShownTitle + ' to ' + Folder.ShownTitle);
  end
  else if Data.Format = DragFormatText then
    BrowserApp.Bookmarks.AddBookmark(Folder, Data.Text, Data.Text, -1, BrowserApp.NowUnix);
  Refresh;
end;

procedure TLibraryWindow.SearchChanged(Sender: TControl);
begin
  FillList;
end;

procedure TLibraryWindow.UpdateNavigation;
begin
  FBackButton.Enabled := FBack.Count > 1;
  FForwardButton.Enabled := FForward.Count > 0;
end;

procedure TLibraryWindow.BackClicked(Sender: TControl);
begin
  if FBack.Count < 2 then
    Exit;
  FForward.Add(FBack[FBack.Count - 1]);
  FBack.Delete(FBack.Count - 1);
  FNavigating := True;
  try
    FTree.Selected := TTreeNode(FBack[FBack.Count - 1]);
  finally
    FNavigating := False;
  end;
  FillList;
end;

procedure TLibraryWindow.ForwardClicked(Sender: TControl);
begin
  if FForward.Count = 0 then
    Exit;
  FBack.Add(FForward[FForward.Count - 1]);
  FForward.Delete(FForward.Count - 1);
  FNavigating := True;
  try
    FTree.Selected := TTreeNode(FBack[FBack.Count - 1]);
  finally
    FNavigating := False;
  end;
  FillList;
end;

procedure TLibraryWindow.DeleteChosen;
var
  Row: TRow;
  Place: TPlace;
  Node: TBookmarkNode;
begin
  Row := ChosenRow;
  Place := ChosenPlace;
  if (Row = nil) or (Place = nil) then
    Exit;
  FDetailNode := -1;
  if Place.Kind in [PlaceHistory, PlaceHistoryAge] then
  begin
    BrowserApp.History.RemoveUrl(Row.Url);
    Say('library forgot ' + Row.Url);
  end
  else if Row.NodeId >= 0 then
  begin
    Node := BrowserApp.Bookmarks.NodeById(Row.NodeId);
    if Node <> nil then
    begin
      Say('library deleted ' + Node.ShownTitle);
      BrowserApp.Bookmarks.Delete(Node);
    end;
  end;
  Refresh;
end;

procedure TLibraryWindow.OrganizeChosen(Item: TMenuItem);
var
  Row: TRow;
begin
  case Item.Tag of
    OrganizeNewBookmark:
      NewBookmarkNode(Self, BookmarkItem, CurrentFolder, -1, '', '');
    OrganizeNewFolder:
      NewBookmarkNode(Self, BookmarkFolder, CurrentFolder, -1, '', '');
    OrganizeNewSeparator:
      BrowserApp.Bookmarks.AddSeparator(CurrentFolder, -1);
    OrganizeDelete:
      DeleteChosen;
    OrganizeForgetSite:
      begin
        Row := ChosenRow;
        if (Row <> nil) and (HostOfUrl(Row.Url) <> '') then
          BrowserApp.History.RemoveHost(HostOfUrl(Row.Url));
      end;
    OrganizeClose:
      CloseRequested;
  end;
  if Item.Tag <> OrganizeClose then
    Refresh;
end;

procedure TLibraryWindow.ViewsChosen(Item: TMenuItem);
begin
  FSorted := Item.Tag = ViewsSortByName;
  FillList;
end;

{ The bookmarks as the HTML file browsers trade them in. }
procedure TLibraryWindow.ExportHtml;
var
  Lines: TStringList;
  Path: string;

  function Escape(const Text: string): string;
  begin
    Result := StringReplace(StringReplace(StringReplace(Text, '&', '&amp;', [rfReplaceAll]), '<', '&lt;',
      [rfReplaceAll]), '"', '&quot;', [rfReplaceAll]);
  end;

  procedure AddFolder(Folder: TBookmarkNode; Depth: Integer);
  var
    Index: Integer;
    Node: TBookmarkNode;
    Indent: string;
  begin
    Indent := StringOfChar(' ', Depth * 4);
    Lines.Add(Indent + '<DL><p>');
    for Index := 0 to Folder.Count - 1 do
    begin
      Node := Folder[Index];
      case Node.Kind of
        BookmarkFolder:
          begin
            Lines.Add(Indent + '    <DT><H3 ADD_DATE="' + IntToStr(Node.Added) + '">' + Escape(Node.ShownTitle) + '</H3>');
            AddFolder(Node, Depth + 1);
          end;
        BookmarkSeparator:
          Lines.Add(Indent + '    <HR>');
        BookmarkItem:
          Lines.Add(Indent + '    <DT><A HREF="' + Escape(Node.Url) + '" ADD_DATE="' + IntToStr(Node.Added) +
            '" SHORTCUTURL="' + Escape(Node.Keyword) + '" TAGS="' + Escape(Node.TagText) + '">' +
            Escape(Node.ShownTitle) + '</A>');
      end;
    end;
    Lines.Add(Indent + '</DL><p>');
  end;

begin
  if not ChooseFileToSave('Export Bookmarks File', ExcludeTrailingPathDelimiter(GetUserDir), '*.html', Path,
    'bookmarks.html') then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.Add('<!DOCTYPE NETSCAPE-Bookmark-file-1>');
    Lines.Add('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">');
    Lines.Add('<TITLE>Bookmarks</TITLE>');
    Lines.Add('<H1>Bookmarks</H1>');
    AddFolder(BrowserApp.Bookmarks.Root, 0);
    WriteLines(Lines, Path);
    Say('library exported ' + Path);
  finally
    Lines.Free;
  end;
end;

procedure TLibraryWindow.BackupChosen(Item: TMenuItem);
var
  Path: string;
  Lines: TStringList;
begin
  case Item.Tag of
    BackupExport:
      ExportHtml;
    BackupImport:
      ShowMessageBox('Import Bookmarks', 'Reading bookmarks from HTML files is not done yet; a backup made with ' +
        'Backup... can be restored with Restore....', MessageOk, SignInformation, Self);
    BackupSave:
      if ChooseFileToSave('Bookmarks Backup Filename', ExcludeTrailingPathDelimiter(GetUserDir), '*', Path,
        'bookmarks-backup.txt') then
      begin
        BrowserApp.Bookmarks.Save;
        Lines := ReadLines(ProfileFile('bookmarks.txt'));
        try
          WriteLines(Lines, Path);
        finally
          Lines.Free;
        end;
        Say('library backup ' + Path);
      end;
    BackupRestore:
      if ChooseFileToOpen('Select a bookmarks backup', ExcludeTrailingPathDelimiter(GetUserDir), '*', Path) then
        if ShowMessageBox('Revert Bookmarks', 'This will replace all of your current bookmarks with the backup. Are ' +
          'you sure?', MessageOkCancel, SignWarning, Self) = ResultOk then
        begin
          Lines := ReadLines(Path);
          try
            WriteLines(Lines, ProfileFile('bookmarks.txt'));
          finally
            Lines.Free;
          end;
          BrowserApp.Bookmarks.Load;
          BrowserApp.Bookmarks.Changed;
          Refresh;
        end;
  end;
end;

procedure ShowLibrary(Mode: TLibraryMode);
begin
  if LibraryWindow = nil then
    LibraryWindow := TLibraryWindow.Create;
  LibraryWindow.Refresh;
  LibraryWindow.ShowMode(Mode);
  LibraryWindow.Show;
  LibraryWindow.Activate;
  if Mode = LibraryHistory then
    Say('library open history')
  else
    Say('library open bookmarks');
end;

end.
