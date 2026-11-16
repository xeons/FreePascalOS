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
  The list of a folder's items: a list view showing them as large
  icons, a list, or details (name, size, type, modified, permissions,
  owner), sorted by any column either way round (FileManager.ItemOrder),
  with hidden items or without.

  The folder shown is watched (Sys.FileWatches): when any program
  changes it, it is read again, keeping the selection, the focused item
  and the scrolling where they were (by name), and "refreshed" is
  printed (and OnRefreshed told). Changes that come within RefreshDelay
  of the first are taken in one reading (a copy writes a file in many
  pieces: the folder is not read again for each), and none happens
  under a rename in place (it waits until the rename is over). If the folder itself goes away (removed, renamed, or its
  volume unplugged) OnFolderGone says so.

  Items are dragged as a file list (Controls.FileLists); files dragged
  over a folder item drop into it, elsewhere into the folder shown
  (unless that is where they came from); OnDropFiles hears of a drop,
  with what it should do (FileManager.DropRules).
}
unit FileManager.FolderView;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.DragData,
  Controls.Icons,
  Controls.ListItems,
  Controls.ListView,
  FileManager.Items,
  FileManager.ItemOrder;

type
  { One item shown: what the list item's Data points at. }
  TFolderEntry = class
  public
    Item: TFolderItem;
  end;

  TDropFilesEvent = procedure(Sender: TControl; Paths: TStrings; const TargetFolder: string;
    Effect: TDropEffect) of object;

  TFolderView = class(TListView)
  private
    FFolder: string;
    FShowHidden: Boolean;
    FOrderColumn: TSortColumn;
    FOrderAscending: Boolean;
    FWatch: Int64;
    { A timer object the message loop watches: due RefreshDelay after
      the first change of a burst. }
    FRefreshTimer: Int64;
    FRefreshDue: Boolean;
    FRefreshWanted: Boolean;
    FLastError: LongInt;
    FOnFolderGone: TControlEvent;
    FOnRefreshed: TControlEvent;
    FOnOrderChanged: TControlEvent;
    FOnDropFiles: TDropFilesEvent;
    procedure WatchFolder;
    procedure StopWatching;
    procedure FolderChanged(Handle: Int64);
    procedure RefreshTimerFired(Handle: Int64);
    procedure FreeEntries;
    procedure AddItemRow(const Item: TFolderItem);
    function CompareRows(First, Second: TListItem): LongInt;
    function CompareForHeader(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt;
    function OwnerNameOf(OwnerId: LongWord): string;
    procedure HeaderClicked(Sender: TListView; Column: LongInt);
    procedure ApplyOrder;
    procedure StartDragging(Sender: TListView; var Data: TDragData);
    function DropFolderAt(X, Y: LongInt; Data: TDragData; out Index: LongInt): string;
    procedure SetShowHidden(Value: Boolean);
  protected
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
    procedure EditingEnded; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Shows Folder; ErrorNone or why it cannot be read (the list is then
      empty). }
    function ShowFolder(const AFolder: string): LongInt;
    { Reads the folder shown again, keeping what was selected. }
    procedure Refresh;
    procedure SortBy(Column: TSortColumn; Ascending: Boolean);
    function EntryAt(Index: LongInt): TFolderEntry;
    function PathOf(Index: LongInt): string;
    function IndexOfName(const Name: string): LongInt;
    { The selected items' paths (in the order shown). }
    procedure GetSelectedPaths(Paths: TStrings);
    function SelectedTotalSize: QWord;
    { Selects only the items with these names (any not there are left
      out); the first becomes the focused one. }
    procedure SelectNames(Names: TStrings);
    { Says where the items are on the screen (place item-NAME X Y). }
    procedure TellPlaces;
    property Folder: string read FFolder;
    property ShowHidden: Boolean read FShowHidden write SetShowHidden;
    property OrderColumn: TSortColumn read FOrderColumn;
    property OrderAscending: Boolean read FOrderAscending;
    property LastError: LongInt read FLastError;
    property OnFolderGone: TControlEvent read FOnFolderGone write FOnFolderGone;
    { The folder was read again (it changed, or Refresh). }
    property OnRefreshed: TControlEvent read FOnRefreshed write FOnRefreshed;
    { The order was changed by a click on a column's header. }
    property OnOrderChanged: TControlEvent read FOnOrderChanged write FOnOrderChanged;
    property OnDropFiles: TDropFilesEvent read FOnDropFiles write FOnDropFiles;
  end;

{ The stock icon for an item. }
function IconOfItem(const Item: TFolderItem): TStockIcon;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Connection,
  Sys.Objects,
  Sys.Files,
  Sys.FileWatches,
  Drawing.Rectangles,
  Windowing.Windows,
  Windowing.HandleWatches,
  Controls.FileNames,
  Controls.FolderListing,
  Controls.FileLists,
  Util.Accounts,
  FileManager.FileTypes,
  FileManager.TimeTexts,
  FileManager.Permissions,
  FileManager.FolderReading,
  FileManager.DropRules,
  FileManager.TestPlaces,
  FileManager.Output;

const
  { Milliseconds a burst of changes is gathered before the folder is
    read again. }
  RefreshDelay = 300;
  { The columns, in order. }
  ColumnName = 0;
  ColumnSize = 1;
  ColumnType = 2;
  ColumnModified = 3;
  ColumnPermissions = 4;
  ColumnOwner = 5;
  { Items whose places are told (a test needs the first few). }
  MostPlacesTold = 60;

function IconOfItem(const Item: TFolderItem): TStockIcon;
begin
  case FileTypeOf(Item) of
    FileTypeFolder: Result := StockIconFolder;
    FileTypeProgram: Result := StockIconProgram;
    FileTypeText: Result := StockIconDocument;
  else
    Result := StockIconFile;
  end;
end;

constructor TFolderView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FWatch := -1;
  FRefreshTimer := CreateTimer(False);
  if (FRefreshTimer >= 0) and not WatchHandle(FRefreshTimer, @RefreshTimerFired) then
  begin
    CloseHandle(FRefreshTimer);
    FRefreshTimer := -1;
  end;
  FOrderAscending := True;
  MultiSelect := True;
  DragEnabled := True;
  IconsInDetails := True;
  AddColumn('Name', 170);
  AddColumn('Size', 70);
  AddColumn('Type', 105);
  AddColumn('Modified', 122);
  AddColumn('Permissions', 80);
  AddColumn('Owner', 60);
  OnColumnClick := @HeaderClicked;
  OnCompare := @CompareForHeader;
  OnStartDrag := @StartDragging;
end;

destructor TFolderView.Destroy;
begin
  StopWatching;
  if FRefreshTimer >= 0 then
  begin
    StopWatchingHandle(FRefreshTimer);
    CloseHandle(FRefreshTimer);
  end;
  FreeEntries;
  inherited Destroy;
end;

{ --- Reading ------------------------------------------------------------------------- }

procedure TFolderView.FreeEntries;
var
  Row: LongInt;
begin
  for Row := 0 to RowCount - 1 do
  begin
    TFolderEntry(Items[Row].Data).Free;
    Items[Row].Data := nil;
  end;
end;

function TFolderView.OwnerNameOf(OwnerId: LongWord): string;
begin
  if not FindUserName(OwnerId, Result) or (Result = '') then
    Result := IntToStr(OwnerId);
end;

procedure TFolderView.AddItemRow(const Item: TFolderItem);
var
  Entry: TFolderEntry;
  Row: LongInt;
  SizeColumn: string;
begin
  Entry := TFolderEntry.Create;
  Entry.Item := Item;
  SizeColumn := '';
  if Item.Kind = ItemFile then
    SizeColumn := SizeText(Item.SizeInBytes);
  Row := AddRow([Item.Name, SizeColumn, TypeTextOf(Item), TimeText(Item.ModificationTime),
    PermissionText(Item.Mode), OwnerNameOf(Item.OwnerId)]);
  Items[Row].Data := Entry;
  Items[Row].IconKind := IconOfItem(Item);
  if Item.IsLink then
    Items[Row].Overlay := OverlayLink;
end;

function TFolderView.ShowFolder(const AFolder: string): LongInt;
var
  FolderItems: TFolderItems;
  Index: LongInt;
begin
  EndEditing(False);
  FRefreshWanted := False;
  Result := ReadFolderItems(AFolder, FShowHidden, FolderItems);
  FLastError := Result;
  if AFolder <> FFolder then
  begin
    FFolder := AFolder;
    WatchFolder;
  end;
  FreeEntries;
  Clear;
  for Index := 0 to High(FolderItems) do
    AddItemRow(FolderItems[Index]);
  ApplyOrder;
end;

procedure TFolderView.Refresh;
var
  SelectedNames: TStringList;
  FocusedName: string;
  Row: LongInt;
  FirstShown: LongInt;
begin
  if IsEditing then
  begin
    FRefreshWanted := True;
    Exit;
  end;
  SelectedNames := TStringList.Create;
  try
    for Row := 0 to RowCount - 1 do
      if Selected[Row] then
        SelectedNames.Add(Items[Row].Caption);
    FocusedName := '';
    if ItemIndex >= 0 then
      FocusedName := Items[ItemIndex].Caption;
    FirstShown := FFirstLine;
    ShowFolder(FFolder);
    SelectNames(SelectedNames);
    if FocusedName <> '' then
    begin
      Row := IndexOfName(FocusedName);
      if Row >= 0 then
        FItemIndex := Row;
    end;
    SetFirstLine(FirstShown);
  finally
    SelectedNames.Free;
  end;
  Say('refreshed');
  TellPlaces;
  if Assigned(FOnRefreshed) then
    FOnRefreshed(Self);
end;

procedure TFolderView.EditingEnded;
begin
  if FRefreshWanted then
    Refresh;
end;

procedure TFolderView.SetShowHidden(Value: Boolean);
begin
  if Value = FShowHidden then
    Exit;
  FShowHidden := Value;
  if FFolder <> '' then
    Refresh;
end;

{ --- Watching ------------------------------------------------------------------------ }

procedure TFolderView.WatchFolder;
begin
  StopWatching;
  FWatch := WatchPath(PChar(FFolder), WatchNames or WatchContents or WatchAttributes);
  if FWatch < 0 then
    FWatch := -1
  else if not WatchHandle(FWatch, @FolderChanged) then
    StopWatching;
end;

procedure TFolderView.StopWatching;
begin
  if FWatch < 0 then
    Exit;
  StopWatchingHandle(FWatch);
  CloseHandle(FWatch);
  FWatch := -1;
end;

procedure TFolderView.FolderChanged(Handle: Int64);
var
  Reader: TFileChangeReader;
  Change: TFileChange;
  Gone: Boolean;
begin
  Gone := False;
  if ReadFileChanges(Reader, Handle) <> ErrorNone then
    Exit;
  while NextFileChange(Reader, Change) do
    if (Change.Kind = FileChangeWatchedItemRemoved) or (Change.Kind = FileChangeVolumeGone) or
       (Change.Kind = FileChangeWatchedItemMoved) then
      Gone := True;
  if Gone then
  begin
    StopWatching;
    if Assigned(FOnFolderGone) then
      FOnFolderGone(Self);
    Exit;
  end;
  { Many changes come at once (a copy writes a file in pieces): one
    reading for all of them, a moment after the first. }
  if FRefreshDue then
    Exit;
  FRefreshDue := True;
  if (FRefreshTimer < 0) or (SetTimer(FRefreshTimer, RefreshDelay, 0) <> ErrorNone) then
    RefreshTimerFired(-1);
end;

procedure TFolderView.RefreshTimerFired(Handle: Int64);
begin
  FRefreshDue := False;
  if FWatch >= 0 then
    Refresh;
end;

{ --- Order ----------------------------------------------------------------------------- }

function TFolderView.CompareRows(First, Second: TListItem): LongInt;
begin
  Result := CompareFolderItems(TFolderEntry(First.Data).Item, TFolderEntry(Second.Data).Item, FOrderColumn,
    FOrderAscending, @OwnerNameOf);
end;

{ Sorting through the list view's own (for the header's arrow): the
  direction is applied in CompareFolderItems, which keeps folders first
  either way, so the list view's own turning round is undone here. }
function TFolderView.CompareForHeader(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt;
begin
  Result := CompareRows(First, Second);
  if not FOrderAscending then
    Result := -Result;
end;

procedure TFolderView.ApplyOrder;
begin
  SortByColumn(Ord(FOrderColumn), FOrderAscending);
end;

procedure TFolderView.SortBy(Column: TSortColumn; Ascending: Boolean);
begin
  FOrderColumn := Column;
  FOrderAscending := Ascending;
  ApplyOrder;
end;

procedure TFolderView.HeaderClicked(Sender: TListView; Column: LongInt);
begin
  if (Column < Ord(Low(TSortColumn))) or (Column > Ord(High(TSortColumn))) then
    Exit;
  if TSortColumn(Column) = FOrderColumn then
    SortBy(FOrderColumn, not FOrderAscending)
  else
    SortBy(TSortColumn(Column), True);
  { Tell whoever shows the order (a menu's check marks, the settings). }
  if Assigned(FOnOrderChanged) then
    FOnOrderChanged(Self);
end;

{ --- Items ------------------------------------------------------------------------------ }

function TFolderView.EntryAt(Index: LongInt): TFolderEntry;
begin
  if (Index < 0) or (Index >= RowCount) then
    Exit(nil);
  Result := TFolderEntry(Items[Index].Data);
end;

function TFolderView.PathOf(Index: LongInt): string;
begin
  Result := CombinePath(FFolder, Items[Index].Caption);
end;

function TFolderView.IndexOfName(const Name: string): LongInt;
var
  Row: LongInt;
begin
  for Row := 0 to RowCount - 1 do
    if Items[Row].Caption = Name then
      Exit(Row);
  Result := -1;
end;

procedure TFolderView.GetSelectedPaths(Paths: TStrings);
var
  Row: LongInt;
begin
  Paths.Clear;
  for Row := 0 to RowCount - 1 do
    if Selected[Row] then
      Paths.Add(PathOf(Row));
end;

function TFolderView.SelectedTotalSize: QWord;
var
  Row: LongInt;
begin
  Result := 0;
  for Row := 0 to RowCount - 1 do
    if Selected[Row] and (EntryAt(Row).Item.Kind = ItemFile) then
      Result := Result + EntryAt(Row).Item.SizeInBytes;
end;

procedure TFolderView.SelectNames(Names: TStrings);
var
  Index: LongInt;
  Row: LongInt;
  First: LongInt;
begin
  ClearSelection;
  First := -1;
  for Index := 0 to Names.Count - 1 do
  begin
    Row := IndexOfName(Names[Index]);
    if Row < 0 then
      Continue;
    if First < 0 then
    begin
      First := Row;
      ItemIndex := Row;
    end
    else
      Selected[Row] := True;
  end;
end;

procedure TFolderView.TellPlaces;
var
  Row: LongInt;
  Box: TRectangle;
  Column: LongInt;
  Left: LongInt;
begin
  if ViewMode = ViewDetails then
  begin
    Left := 2;
    for Column := 0 to ColumnCount - 1 do
    begin
      TellPlace('header-' + LowerCase(FCaptions[Column]), Self, Left + Scaled(ColumnWidth(Column)) div 2, HeaderMiddle);
      Left := Left + Scaled(ColumnWidth(Column));
    end;
  end;
  Row := 0;
  while (Row < RowCount) and (Row < MostPlacesTold) do
  begin
    Box := CaptionBounds(Row);
    if (Box.Bottom > 0) and (Box.Top < RectangleHeight(PixelBounds)) then
      TellPlace('item-' + Items[Row].Caption, Self, Box.Left + RectangleWidth(Box) div 2,
        Box.Top + RectangleHeight(Box) div 2);
    Inc(Row);
  end;
  TellPlace('folder-empty-space', Self, RectangleWidth(PixelBounds) - 30, RectangleHeight(PixelBounds) - 30);
end;

{ --- Dragging ---------------------------------------------------------------------------- }

procedure TFolderView.StartDragging(Sender: TListView; var Data: TDragData);
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    GetSelectedPaths(Paths);
    if Paths.Count > 0 then
      Data := TDragData.Create(DragFormatFileList, EncodeFileList(FileListCopy, Paths), Self);
  finally
    Paths.Free;
  end;
end;

{ The folder a drop at (X, Y) goes into: a folder item under the pointer
  (Index; not one being dragged), else the folder shown (Index -1). }
function TFolderView.DropFolderAt(X, Y: LongInt; Data: TDragData; out Index: LongInt): string;
begin
  Index := ItemAt(X, Y);
  if (Index >= 0) and IsFolderItem(EntryAt(Index).Item) and not ((Data.Source = Self) and Selected[Index]) then
    Exit(PathOf(Index));
  Index := -1;
  Result := FFolder;
end;

function TFolderView.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Paths: TStringList;
  Action: TFileListAction;
  Target: string;
  Index: LongInt;
begin
  Result := DropNone;
  DropTarget := -1;
  if (Data.Format <> DragFormatFileList) or (FFolder = '') then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) then
      Exit;
    Target := DropFolderAt(X, Y, Data, Index);
    if not CanDropInto(Paths, Target) then
      Exit;
    Result := DropEffectFor(VolumeNumberOf(Paths[0]), VolumeNumberOf(Target), (Modifiers and ModifierControl) <> 0,
      (Modifiers and ModifierShift) <> 0);
    DropTarget := Index;
  finally
    Paths.Free;
  end;
end;

procedure TFolderView.DragLeave;
begin
  DropTarget := -1;
end;

procedure TFolderView.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Paths: TStringList;
  Action: TFileListAction;
  Target: string;
  Index: LongInt;
begin
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) then
      Exit;
    Target := DropFolderAt(X, Y, Data, Index);
    if Assigned(FOnDropFiles) and CanDropInto(Paths, Target) then
      FOnDropFiles(Self, Paths, Target, Effect);
  finally
    Paths.Free;
  end;
end;

end.
