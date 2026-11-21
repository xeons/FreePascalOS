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
  The page shown: an item view (Controls.ItemView) of a location's
  entries (FileManager.Sources; search results stream in from
  FileManager.Searcher) in the view, order, grouping and columns of its
  view settings, filtered by kind or date if asked (a query of the
  search syntax), extensions and hidden items shown or not.

  * Pages group by their own sections (Home, Computer), the gallery by
    month; a folder by what Group by says. Folders come first.
  * The details header's context menu chooses the columns.
  * Pictures get thumbnails (Controls.ThumbnailLoader) in the views big
    enough for them, and their dimensions when the column is shown.
  * A folder (or the recycle bin) is watched (Sys.FileWatches): changes
    made by any program read it again after RefreshDelay, keeping the
    selection, the focus and the scrolling; no reading under a rename in
    place; OnFolderGone when the folder itself goes.
  * Items are dragged as a file list; a drop on a folder item goes into
    it, elsewhere into the folder shown (OnDropFiles, with what
    FileManager.DropRules says it does).
  * Cut items are drawn dimmed until pasted (MarkCut).

  It prints "refreshed", "view ...", "sort ...", "group ...", "search-
  result N" and "search-done N", and where the items are (TellPlaces).
}
unit FileManager.FolderView;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Surfaces,
  Controls.Base,
  Controls.DragData,
  Controls.Menus,
  Controls.ItemViewItems,
  Controls.ItemViewLayout,
  Controls.ItemView,
  Controls.ThumbnailLoader,
  FileManager.Items,
  FileManager.Entries,
  FileManager.Locations,
  FileManager.ItemColumns,
  FileManager.Grouping,
  FileManager.SearchQuery,
  FileManager.Searcher,
  FileManager.Settings;

type
  TDropFilesEvent = procedure(Sender: TControl; Paths: TStrings; const TargetFolder: string;
    Effect: TDropEffect) of object;

  TFolderView = class(TItemView)
  private
    FLocation: TLocation;
    FEntries: TList;
    FSettings: TFolderViewSettings;
    FViewKey: string;
    FShowHidden: Boolean;
    FShowExtensions: Boolean;
    FShowRecent: Boolean;
    FShowFavorites: Boolean;
    FFilter: TSearchQuery;
    FFilterText: string;
    FCutPaths: TStringList;
    FWatch: Int64;
    FRefreshTimer: Int64;
    FRefreshDue: Boolean;
    FRefreshWanted: Boolean;
    FLastError: LongInt;
    FThumbnails: TThumbnailLoader;
    FSearcher: TFolderSearcher;
    FSearchCount: LongInt;
    FHeaderMenu: TMenuItem;
    FOnFolderGone: TControlEvent;
    FOnRefreshed: TControlEvent;
    FOnSettingsChanged: TControlEvent;
    FOnDropFiles: TDropFilesEvent;
    FOnSearchFinished: TControlEvent;
    FOnPictureMeasured: TControlEvent;
    procedure WatchLocation;
    procedure StopWatching;
    procedure LocationChanged(Handle: Int64);
    procedure RefreshTimerFired(Handle: Int64);
    procedure FreeEntries;
    procedure Rebuild;
    procedure AddEntryItem(Entry: TFolderEntry);
    procedure FillCells(Item: TItemViewItem; Entry: TFolderEntry);
    function DisplayName(Entry: TFolderEntry): string;
    procedure ApplyColumns;
    procedure ApplyGroups;
    function CompareItems(First, Second: TItemViewItem): LongInt;
    procedure ApplyOrder;
    function PassesFilter(Entry: TFolderEntry): Boolean;
    procedure RequestThumbnails;
    function WantsThumbnails: Boolean;
    procedure ThumbnailReady(Sender: TObject; const Path: string; const Picture: TSurface;
      OriginalWidth, OriginalHeight: LongInt);
    procedure SearchResults(Sender: TObject; Found: TList);
    procedure SearchFinished(Sender: TObject);
    procedure HeaderClicked(Sender: TItemView; Column: LongInt);
    procedure HeaderMenu(Sender: TItemView; X, Y: LongInt);
    procedure ColumnChosen(Item: TMenuItem);
    procedure ColumnResized(Sender: TItemView; Column: LongInt);
    procedure StartDragging(Sender: TItemView; var Data: TDragData);
    function DropFolderAt(X, Y: LongInt; Data: TDragData; out Index: LongInt): string;
    procedure SettingsChanged;
    function DefaultsFor(const Location: TLocation): TFolderViewSettings;
    function ColumnShown(Column: TColumnKind): Boolean;
  protected
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
    procedure EditingEnded; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Shows Location; ErrorNone or why it cannot be read. }
    function ShowLocation(const ALocation: TLocation): LongInt;
    { Searches Scope and below for Text (the search syntax), results
      coming in as they are found. }
    procedure StartSearch(const Scope, QueryText: string);
    procedure CancelSearch;
    function Searching: Boolean;
    { Reads the location again, keeping what was selected. }
    procedure Refresh;
    procedure SetMode(Value: TItemViewMode);
    procedure SetSort(Column: TColumnKind; Ascending: Boolean);
    procedure SetGroupBy(Value: TGroupBy);
    procedure SetColumnShown(Column: TColumnKind; Shown: Boolean);
    { A filter in the search syntax ('' for none: everything). }
    procedure SetFilter(const Filter: string);
    procedure SetShowHidden(Value: Boolean);
    procedure SetShowExtensions(Value: Boolean);
    procedure SetHomeSections(ShowRecent, ShowFavorites: Boolean);
    procedure MarkCut(Paths: TStrings);
    function EntryAt(Index: LongInt): TFolderEntry;
    function PathOf(Index: LongInt): string;
    function IndexOfName(const Name: string): LongInt;
    function IndexOfPath(const Path: string): LongInt;
    { The selected entries' full paths (real files only unless Any). }
    procedure GetSelectedPaths(Paths: TStrings; Any: Boolean = False);
    procedure GetSelectedEntries(List: TList);
    function SelectedTotalSize: QWord;
    function FocusedEntry: TFolderEntry;
    procedure SelectNames(Names: TStrings);
    procedure SelectPaths(Paths: TStrings);
    { Says where the items and the header are (place NAME X Y). }
    procedure TellPlaces;
    { The folder shown ('' on a page that is not a folder). }
    function Folder: string;
    property Location: TLocation read FLocation;
    property Settings: TFolderViewSettings read FSettings;
    property ShowHidden: Boolean read FShowHidden;
    property ShowExtensions: Boolean read FShowExtensions;
    property FilterText: string read FFilterText;
    property LastError: LongInt read FLastError;
    property SearchCount: LongInt read FSearchCount;
    property OnFolderGone: TControlEvent read FOnFolderGone write FOnFolderGone;
    property OnRefreshed: TControlEvent read FOnRefreshed write FOnRefreshed;
    { The view, order, grouping or columns changed (remembered here for
      the folder; the window updates its menus). }
    property OnSettingsChanged: TControlEvent read FOnSettingsChanged write FOnSettingsChanged;
    property OnDropFiles: TDropFilesEvent read FOnDropFiles write FOnDropFiles;
    property OnSearchFinished: TControlEvent read FOnSearchFinished write FOnSearchFinished;
    { A thumbnail told a picture's size (the details pane may show it). }
    property OnPictureMeasured: TControlEvent read FOnPictureMeasured write FOnPictureMeasured;
  end;

{ The icon of an entry: a theme icon's name ('' for a stock icon). }
function EntryIconName(Entry: TFolderEntry): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.FileWatches,
  Sys.Time,
  Sys.LocalTime,
  Drawing.Rectangles,
  Windowing.Windows,
  Windowing.Connection,
  Windowing.HandleWatches,
  Controls.ItemViewBase,
  Controls.Window,
  Controls.Icons,
  Controls.FileNames,
  Controls.FileLists,
  Controls.FileTypeIcons,
  Controls.NaturalOrder,
  Util.Trash,
  FileManager.FileKinds,
  FileManager.FileTypes,
  FileManager.FolderReading,
  FileManager.DropRules,
  FileManager.Paths,
  FileManager.Sources,
  FileManager.TestPlaces,
  FileManager.Output;

const
  RefreshDelay = 300;
  MostPlacesTold = 60;

{ --- Icons ------------------------------------------------------------------------------------ }

function EntryIconName(Entry: TFolderEntry): string;
var
  Folder: TStandardFolder;
begin
  if Entry.IconName <> '' then
    Exit(Entry.IconName);
  if Entry.IsFolder then
  begin
    if Entry.Kind = EntryFile then
    begin
      if Entry.FullPath = HomeFolder then
        Exit('home');
      if StandardFolderAt(Entry.FullPath, Folder) then
        Exit(StandardFolderIcons[Folder]);
    end;
    Exit(StockIconNames[IconForFolderName(Entry.Item.Name)]);
  end;
  if IsBrowsableArchiveExtension(Entry.Item.Name) then
    Exit('folder-compressed');
  case FileTypeOf(Entry.Item) of
    FileTypeProgram: Result := StockIconNames[StockIconProgram];
    FileTypeText: Result := StockIconNames[IconForFileName(Entry.Item.Name, StockIconDocument)];
    FileTypeBrokenLink: Result := StockIconNames[StockIconUnknown];
  else
    Result := StockIconNames[IconForFileName(Entry.Item.Name, StockIconFile)];
  end;
end;

function LocalOffsetNow: LongInt;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  Result := Local.Offset;
end;

{ --- Making and freeing ----------------------------------------------------------------------- }

constructor TFolderView.Create(AParent: TControl);
var
  Column: TColumnKind;
  Alignment: LongInt;
begin
  inherited Create(AParent);
  FEntries := TList.Create;
  FCutPaths := TStringList.Create;
  FCutPaths.Sorted := True;
  FShowExtensions := True;
  FShowRecent := True;
  FShowFavorites := True;
  FWatch := -1;
  FRefreshTimer := CreateTimer(False);
  if (FRefreshTimer >= 0) and not WatchHandle(FRefreshTimer, @RefreshTimerFired) then
  begin
    CloseHandle(FRefreshTimer);
    FRefreshTimer := -1;
  end;
  FThumbnails := TThumbnailLoader.Create;
  FThumbnails.OnThumbnail := @ThumbnailReady;
  FSearcher := TFolderSearcher.Create;
  FSearcher.OnResults := @SearchResults;
  FSearcher.OnFinished := @SearchFinished;
  for Column := Low(TColumnKind) to High(TColumnKind) do
  begin
    Alignment := ColumnAlignLeft;
    if Column in NumericColumns then
      Alignment := ColumnAlignRight;
    AddColumn(ColumnCaptions[Column], ColumnWidths[Column], Alignment, Column in DefaultColumns, Ord(Column));
  end;
  DragEnabled := True;
  EmptyText := 'This folder is empty.';
  FSettings := DefaultViewSettings(ItemViewDetails);
  OnColumnClick := @HeaderClicked;
  OnHeaderContextMenu := @HeaderMenu;
  OnColumnResized := @ColumnResized;
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
  FSearcher.Free;
  { The items point at the thumbnails: they go first. }
  Clear;
  FThumbnails.Free;
  FreeEntries;
  FEntries.Free;
  FCutPaths.Free;
  FHeaderMenu.Free;
  inherited Destroy;
end;

procedure TFolderView.FreeEntries;
var
  Index: LongInt;
begin
  for Index := 0 to FEntries.Count - 1 do
    TFolderEntry(FEntries[Index]).Free;
  FEntries.Clear;
end;

{ --- Settings ---------------------------------------------------------------------------------- }

function TFolderView.DefaultsFor(const Location: TLocation): TFolderViewSettings;
var
  Standard: TStandardFolder;
begin
  case Location.Kind of
    LocationHome, LocationComputer: Result := DefaultViewSettings(ItemViewTiles);
    LocationGallery:
      begin
        Result := DefaultViewSettings(ItemViewLargeIcons);
        Result.GroupBy := GroupByMonth;
        Result.SortColumn := ColumnModified;
        Result.SortAscending := False;
      end;
    LocationTrash:
      begin
        Result := DefaultViewSettings(ItemViewDetails);
        Result.Columns := [ColumnName, ColumnOriginalLocation, ColumnDeleted, ColumnSize, ColumnType];
        Result.SortColumn := ColumnDeleted;
        Result.SortAscending := False;
      end;
    LocationSearch:
      begin
        Result := DefaultViewSettings(ItemViewDetails);
        Result.Columns := [ColumnName, ColumnFolder, ColumnModified, ColumnType, ColumnSize];
      end;
  else
    if (Location.Kind = LocationFolder) and StandardFolderAt(Location.Path, Standard) and
       (Standard in [FolderPictures, FolderVideos]) then
      Result := DefaultViewSettings(ItemViewLargeIcons)
    else
      Result := DefaultViewSettings(ItemViewDetails);
  end;
end;

function ViewKeyOf(const Location: TLocation): string;
begin
  case Location.Kind of
    LocationFolder: Result := ViewKeyOfPath(Location.Path);
    LocationArchive: Result := 'archive';
    LocationSearch: Result := 'search';
  else
    Result := LowerCase(StringReplace(LocationAddress(Location), ' ', '', [rfReplaceAll]));
  end;
end;

function TFolderView.ColumnShown(Column: TColumnKind): Boolean;
var
  Each: TColumnKind;
begin
  for Each in FSettings.Columns do
    if Each = Column then
      Exit(True);
  Result := False;
end;

procedure TFolderView.SettingsChanged;
begin
  RememberView(FViewKey, FSettings);
  if Assigned(FOnSettingsChanged) then
    FOnSettingsChanged(Self);
end;

procedure TFolderView.ApplyColumns;
var
  Column: TColumnKind;
begin
  for Column := Low(TColumnKind) to High(TColumnKind) do
    SetColumnVisible(Ord(Column), (Column = ColumnName) or ColumnShown(Column));
  if FLocation.Kind = LocationComputer then
    SetTileColumns([Ord(ColumnFreeSpace)])
  else if FMode = ItemViewContent then
    SetTileColumns([Ord(ColumnType), Ord(ColumnModified), Ord(ColumnSize)])
  else
    SetTileColumns([Ord(ColumnType), Ord(ColumnSize)]);
  ShowSortArrow(Ord(FSettings.SortColumn), FSettings.SortAscending);
end;

procedure TFolderView.SetMode(Value: TItemViewMode);
begin
  FSettings.Mode := Value;
  Mode := Value;
  ApplyColumns;
  RequestThumbnails;
  Say('view ' + ViewModeKeys[Value]);
  SettingsChanged;
end;

procedure TFolderView.SetSort(Column: TColumnKind; Ascending: Boolean);
begin
  FSettings.SortColumn := Column;
  FSettings.SortAscending := Ascending;
  ApplyOrder;
  if Ascending then
    Say('sort ' + ColumnKeys[Column] + ' ascending')
  else
    Say('sort ' + ColumnKeys[Column] + ' descending');
  SettingsChanged;
end;

procedure TFolderView.SetGroupBy(Value: TGroupBy);
begin
  FSettings.GroupBy := Value;
  ApplyGroups;
  ApplyOrder;
  Say('group ' + GroupByKeys[Value]);
  SettingsChanged;
end;

procedure TFolderView.SetColumnShown(Column: TColumnKind; Shown: Boolean);
var
  Kept: array of TColumnKind;
  Each: TColumnKind;
  Index: LongInt;
begin
  if Column = ColumnName then
    Exit;
  Kept := nil;
  for Each in FSettings.Columns do
    if Each <> Column then
    begin
      SetLength(Kept, Length(Kept) + 1);
      Kept[High(Kept)] := Each;
    end;
  if Shown then
  begin
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := Column;
  end;
  FSettings.Columns := Kept;
  BeginUpdate;
  for Index := 0 to Count - 1 do
    FillCells(Items[Index], TFolderEntry(Items[Index].Data));
  EndUpdate;
  ApplyColumns;
  if Column = ColumnDimensions then
    RequestThumbnails;
  SettingsChanged;
end;

procedure TFolderView.SetFilter(const Filter: string);
begin
  FFilterText := Trim(Filter);
  FFilter := ParseSearchQuery(FFilterText, CurrentTime, LocalOffsetNow);
  Rebuild;
  Say('filter ' + FFilterText);
end;

procedure TFolderView.SetShowHidden(Value: Boolean);
begin
  if Value = FShowHidden then
    Exit;
  FShowHidden := Value;
  if FLocation.Kind = LocationFolder then
    Refresh;
end;

procedure TFolderView.SetShowExtensions(Value: Boolean);
var
  Index: LongInt;
begin
  if Value = FShowExtensions then
    Exit;
  FShowExtensions := Value;
  for Index := 0 to Count - 1 do
    Items[Index].Cells[0] := DisplayName(TFolderEntry(Items[Index].Data));
end;

procedure TFolderView.SetHomeSections(ShowRecent, ShowFavorites: Boolean);
begin
  FShowRecent := ShowRecent;
  FShowFavorites := ShowFavorites;
  if FLocation.Kind = LocationHome then
    Refresh;
end;

{ --- Reading ------------------------------------------------------------------------------------ }

function TFolderView.DisplayName(Entry: TFolderEntry): string;
var
  Extension: string;
begin
  Result := Entry.Item.Name;
  if FShowExtensions or Entry.IsFolder or not (Entry.Kind in [EntryFile, EntryTrashed, EntryArchived]) then
    Exit;
  Extension := ExtensionOf(Result);
  if Extension <> '' then
    Result := Copy(Result, 1, Length(Result) - Length(Extension) - 1);
end;

procedure TFolderView.FillCells(Item: TItemViewItem; Entry: TFolderEntry);
var
  Column: TColumnKind;
begin
  Item.Cells[0] := DisplayName(Entry);
  for Column := Succ(ColumnName) to High(TColumnKind) do
    if ColumnShown(Column) or (Column in [ColumnType, ColumnSize, ColumnModified, ColumnFreeSpace]) then
      Item.Cells[Ord(Column)] := ColumnText(Entry, Column)
    else
      Item.Cells[Ord(Column)] := '';
end;

function TFolderView.PassesFilter(Entry: TFolderEntry): Boolean;
begin
  if FFilterText = '' then
    Exit(True);
  Result := MatchesQuery(FFilter, Entry.Item.Name, Entry.IsFolder, Entry.Item.SizeInBytes,
    Entry.Item.ModificationTime);
end;

procedure TFolderView.AddEntryItem(Entry: TFolderEntry);
var
  Item: TItemViewItem;
begin
  if not PassesFilter(Entry) then
    Exit;
  Item := AddItem(DisplayName(Entry));
  Item.Data := Entry;
  FillCells(Item, Entry);
  Item.IconName := EntryIconName(Entry);
  if Entry.Item.IsLink then
    Item.Overlay := OverlayLink;
  if Entry.Kind = EntryVolume then
  begin
    if Entry.TotalBytes > 0 then
      Item.Meter := LongInt((Entry.TotalBytes - Entry.FreeBytes) * 1000 div Entry.TotalBytes)
    else
      Item.Meter := 0;
  end;
  Item.Dimmed := ((Entry.Kind = EntryFile) and IsHiddenName(Entry.Item.Name)) or
    (FCutPaths.IndexOf(Entry.FullPath) >= 0);
end;

procedure TFolderView.ApplyGroups;
var
  Captions: TStringList;
  Orders: array of Int64;
  Index: LongInt;
  Entry: TFolderEntry;
  Caption: string;
  Position: LongInt;
  Order: Int64;
  NowTime: Int64;
  Offset: LongInt;
  GroupBy: TGroupBy;
  Sorted: array of string;
  Other: LongInt;
  Swap: string;
  SwapOrder: Int64;
  Names: array of string;
begin
  NowTime := CurrentTime;
  Offset := LocalOffsetNow;
  GroupBy := FSettings.GroupBy;
  if FLocation.Kind in [LocationHome, LocationComputer] then
    GroupBy := GroupNone;
  Captions := TStringList.Create;
  try
    Orders := nil;
    for Index := 0 to Count - 1 do
    begin
      Entry := TFolderEntry(Items[Index].Data);
      if FLocation.Kind in [LocationHome, LocationComputer] then
      begin
        Caption := Entry.Section;
        Order := 0;
      end
      else if GroupBy = GroupNone then
        Caption := ''
      else
      begin
        Caption := GroupCaption(GroupBy, Entry.Item.Name, EntryTypeText(Entry), Entry.IsFolder,
          Entry.Item.SizeInBytes, Entry.Item.ModificationTime, NowTime, Offset);
        Order := GroupOrder(GroupBy, Caption, Entry.Item.ModificationTime);
      end;
      if Caption = '' then
      begin
        Items[Index].Group := -1;
        Continue;
      end;
      Position := Captions.IndexOf(Caption);
      if Position < 0 then
      begin
        Position := Captions.Add(Caption);
        SetLength(Orders, Length(Orders) + 1);
        Orders[Position] := Order;
      end
      else if Order < Orders[Position] then
        Orders[Position] := Order;
      Items[Index].Group := Position;
    end;
    if Captions.Count = 0 then
    begin
      ClearGroups;
      Exit;
    end;
    { The groups in their order (sections as met, which is their order;
      types by name), and the items told their new places. }
    Sorted := nil;
    SetLength(Sorted, Captions.Count);
    for Index := 0 to Captions.Count - 1 do
      Sorted[Index] := Captions[Index];
    if not (FLocation.Kind in [LocationHome, LocationComputer]) then
      for Index := 1 to High(Sorted) do
      begin
        Other := Index;
        while (Other > 0) and ((Orders[Other] < Orders[Other - 1]) or ((Orders[Other] = Orders[Other - 1]) and
          (NaturalCompare(Sorted[Other], Sorted[Other - 1]) < 0))) do
        begin
          Swap := Sorted[Other];
          Sorted[Other] := Sorted[Other - 1];
          Sorted[Other - 1] := Swap;
          SwapOrder := Orders[Other];
          Orders[Other] := Orders[Other - 1];
          Orders[Other - 1] := SwapOrder;
          Dec(Other);
        end;
      end;
    for Index := 0 to Count - 1 do
      if Items[Index].Group >= 0 then
        for Other := 0 to High(Sorted) do
          if Sorted[Other] = Captions[Items[Index].Group] then
          begin
            Items[Index].Group := Other;
            Break;
          end;
    Names := Sorted;
    SetGroups(Names);
  finally
    Captions.Free;
  end;
end;

function TFolderView.CompareItems(First, Second: TItemViewItem): LongInt;
var
  FirstEntry: TFolderEntry;
  SecondEntry: TFolderEntry;
begin
  FirstEntry := TFolderEntry(First.Data);
  SecondEntry := TFolderEntry(Second.Data);
  { Pages keep their own order (pinned folders, recent files). }
  if (FLocation.Kind in [LocationHome, LocationComputer]) and (FirstEntry.Section = SecondEntry.Section) then
    Exit(FEntries.IndexOf(FirstEntry) - FEntries.IndexOf(SecondEntry));
  Result := CompareEntries(FirstEntry, SecondEntry, FSettings.SortColumn, FSettings.SortAscending);
end;

procedure TFolderView.ApplyOrder;
begin
  SortItems(@CompareItems);
  ShowSortArrow(Ord(FSettings.SortColumn), FSettings.SortAscending);
end;

procedure TFolderView.Rebuild;
var
  Index: LongInt;
begin
  BeginUpdate;
  try
    Clear;
    for Index := 0 to FEntries.Count - 1 do
      AddEntryItem(TFolderEntry(FEntries[Index]));
    ApplyGroups;
    ApplyOrder;
  finally
    EndUpdate;
  end;
  RequestThumbnails;
end;

function TFolderView.ShowLocation(const ALocation: TLocation): LongInt;
var
  SameFolder: Boolean;
begin
  EndEditing(False);
  CancelSearch;
  FRefreshWanted := False;
  SameFolder := SameLocation(ALocation, FLocation);
  if not SameFolder then
  begin
    FLocation := ALocation;
    FViewKey := ViewKeyOf(FLocation);
    FSettings := RememberedView(FViewKey, DefaultsFor(FLocation));
    Mode := FSettings.Mode;
    FFilterText := '';
    FCutPaths.Clear;
    Clear;
    FThumbnails.Clear;
    WatchLocation;
  end;
  case FLocation.Kind of
    LocationNetwork: EmptyText := 'No network places have been set up yet.';
    LocationTrash: EmptyText := 'The recycle bin is empty.';
    LocationSearch: EmptyText := 'Searching...';
    LocationHome: EmptyText := 'Pin folders to see them here.';
  else
    EmptyText := 'This folder is empty.';
  end;
  FreeEntries;
  if FLocation.Kind = LocationSearch then
    Result := ErrorNone
  else
    Result := ReadLocationEntries(FLocation, FShowHidden, FShowRecent, FShowFavorites, FEntries);
  FLastError := Result;
  ApplyColumns;
  Rebuild;
end;

procedure TFolderView.Refresh;
var
  SelectedPaths: TStringList;
  FocusedPath: string;
  OldScrollY: LongInt;
  Index: LongInt;
begin
  if IsEditing then
  begin
    FRefreshWanted := True;
    Exit;
  end;
  if FLocation.Kind = LocationSearch then
    Exit;
  SelectedPaths := TStringList.Create;
  try
    GetSelectedPaths(SelectedPaths, True);
    FocusedPath := '';
    if FocusedEntry <> nil then
      FocusedPath := FocusedEntry.FullPath;
    OldScrollY := FScrollY;
    FreeEntries;
    FLastError := ReadLocationEntries(FLocation, FShowHidden, FShowRecent, FShowFavorites, FEntries);
    { The thumbnails stay (the items are made again, pointing at them). }
    BeginUpdate;
    Clear;
    for Index := 0 to FEntries.Count - 1 do
      AddEntryItem(TFolderEntry(FEntries[Index]));
    ApplyGroups;
    ApplyOrder;
    EndUpdate;
    FThumbnails.Clear;
    RequestThumbnails;
    SelectPaths(SelectedPaths);
    Index := IndexOfPath(FocusedPath);
    if Index >= 0 then
      FItemIndex := Index;
    SetScroll(FScrollX, OldScrollY);
  finally
    SelectedPaths.Free;
  end;
  Say('refreshed');
  TellPlaces;
  if Assigned(FOnRefreshed) then
    FOnRefreshed(Self);
end;

procedure TFolderView.EditingEnded;
begin
  if FRefreshWanted then
  begin
    FRefreshWanted := False;
    Refresh;
  end;
end;

{ --- Searching ----------------------------------------------------------------------------------- }

procedure TFolderView.StartSearch(const Scope, QueryText: string);
var
  Query: TSearchQuery;
begin
  ShowLocation(SearchLocation(Scope, QueryText));
  FSearchCount := 0;
  Query := ParseSearchQuery(QueryText, CurrentTime, LocalOffsetNow);
  FSearcher.Start(Scope, Query, FShowHidden);
end;

procedure TFolderView.CancelSearch;
begin
  if FSearcher.Running then
    FSearcher.Cancel;
end;

function TFolderView.Searching: Boolean;
begin
  Result := FSearcher.Running;
end;

procedure TFolderView.SearchResults(Sender: TObject; Found: TList);
var
  Index: LongInt;
begin
  if FLocation.Kind <> LocationSearch then
  begin
    for Index := 0 to Found.Count - 1 do
      TFolderEntry(Found[Index]).Free;
    Exit;
  end;
  BeginUpdate;
  for Index := 0 to Found.Count - 1 do
  begin
    FEntries.Add(Found[Index]);
    AddEntryItem(TFolderEntry(Found[Index]));
  end;
  ApplyGroups;
  ApplyOrder;
  EndUpdate;
  FSearchCount := FSearchCount + Found.Count;
  Say('search-result ' + IntToStr(FSearchCount));
  RequestThumbnails;
  if Assigned(FOnRefreshed) then
    FOnRefreshed(Self);
end;

procedure TFolderView.SearchFinished(Sender: TObject);
begin
  if FLocation.Kind <> LocationSearch then
    Exit;
  EmptyText := 'No items match your search.';
  Say('search-done ' + IntToStr(FSearchCount));
  TellPlaces;
  if Assigned(FOnSearchFinished) then
    FOnSearchFinished(Self);
end;

{ --- Thumbnails ---------------------------------------------------------------------------------- }

function TFolderView.WantsThumbnails: Boolean;
begin
  Result := (FMode in [ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons, ItemViewTiles,
    ItemViewContent]) or ColumnShown(ColumnDimensions);
end;

procedure TFolderView.RequestThumbnails;
var
  Index: LongInt;
  Entry: TFolderEntry;
begin
  if not WantsThumbnails then
    Exit;
  { Last first: the loader does the newest request first, so the top
    of the page comes first. }
  Index := Count - 1;
  while Index >= 0 do
  begin
    Entry := TFolderEntry(Items[Index].Data);
    if (Entry.Kind = EntryFile) and (Entry.Item.Kind = ItemFile) and HasThumbnail(ExtensionOf(Entry.Item.Name)) and
       not Items[Index].HasThumbnail then
      FThumbnails.Request(Entry.FullPath, Entry.Item.ModificationTime, Entry.Item.SizeInBytes);
    Dec(Index);
  end;
end;

procedure TFolderView.ThumbnailReady(Sender: TObject; const Path: string; const Picture: TSurface;
  OriginalWidth, OriginalHeight: LongInt);
var
  Index: LongInt;
  Entry: TFolderEntry;
begin
  Index := IndexOfPath(Path);
  if Index < 0 then
    Exit;
  Entry := TFolderEntry(Items[Index].Data);
  Entry.PictureWidth := OriginalWidth;
  Entry.PictureHeight := OriginalHeight;
  Items[Index].Cells[Ord(ColumnDimensions)] := ColumnText(Entry, ColumnDimensions);
  if Picture.Pixels <> nil then
    Items[Index].Thumbnail := Picture;
  if Assigned(FOnPictureMeasured) then
    FOnPictureMeasured(Self);
end;

{ --- Watching ------------------------------------------------------------------------------------- }

procedure TFolderView.WatchLocation;
var
  Path: string;
begin
  StopWatching;
  case FLocation.Kind of
    LocationFolder: Path := FLocation.Path;
    LocationTrash: Path := HomeTrashFolder + '/files';
  else
    Exit;
  end;
  FWatch := WatchPath(PChar(Path), WatchNames or WatchContents or WatchAttributes);
  if FWatch < 0 then
    FWatch := -1
  else if not WatchHandle(FWatch, @LocationChanged) then
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

procedure TFolderView.LocationChanged(Handle: Int64);
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
  if Gone and (FLocation.Kind = LocationFolder) then
  begin
    StopWatching;
    if Assigned(FOnFolderGone) then
      FOnFolderGone(Self);
    Exit;
  end;
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

{ --- The header ----------------------------------------------------------------------------------- }

procedure TFolderView.HeaderClicked(Sender: TItemView; Column: LongInt);
var
  Kind: TColumnKind;
begin
  if (Column < 0) or (Column > Ord(High(TColumnKind))) then
    Exit;
  Kind := TColumnKind(Column);
  if Kind = FSettings.SortColumn then
    SetSort(Kind, not FSettings.SortAscending)
  else
    SetSort(Kind, True);
end;

procedure TFolderView.ColumnResized(Sender: TItemView; Column: LongInt);
begin
  { Widths are the view's own; nothing to remember per folder yet. }
end;

procedure TFolderView.HeaderMenu(Sender: TItemView; X, Y: LongInt);
var
  Column: TColumnKind;
  Item: TMenuItem;
  Window: TControlWindow;
begin
  if not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FHeaderMenu.Free;
  FHeaderMenu := TMenuItem.Create('');
  for Column := Succ(ColumnName) to High(TColumnKind) do
  begin
    if (Column in [ColumnOriginalLocation, ColumnDeleted]) and (FLocation.Kind <> LocationTrash) then
      Continue;
    if (Column in [ColumnFreeSpace, ColumnFileSystem]) and (FLocation.Kind <> LocationComputer) then
      Continue;
    Item := FHeaderMenu.Add(ColumnCaptions[Column], @ColumnChosen);
    Item.Tag := Ord(Column);
    Item.Checked := ColumnShown(Column);
  end;
  Say('context-menu columns');
  ShowPopupMenu(Window, FHeaderMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Y));
end;

procedure TFolderView.ColumnChosen(Item: TMenuItem);
var
  Column: TColumnKind;
begin
  Column := TColumnKind(Item.Tag);
  SetColumnShown(Column, not ColumnShown(Column));
  if ColumnShown(Column) then
    Say('column shown ' + ColumnKeys[Column])
  else
    Say('column hidden ' + ColumnKeys[Column]);
  TellPlaces;
end;

{ --- Items ----------------------------------------------------------------------------------------- }

function TFolderView.Folder: string;
begin
  if FLocation.Kind = LocationFolder then
    Result := FLocation.Path
  else
    Result := '';
end;

function TFolderView.EntryAt(Index: LongInt): TFolderEntry;
begin
  if (Index < 0) or (Index >= Count) then
    Exit(nil);
  Result := TFolderEntry(Items[Index].Data);
end;

function TFolderView.FocusedEntry: TFolderEntry;
begin
  Result := EntryAt(ItemIndex);
end;

function TFolderView.PathOf(Index: LongInt): string;
begin
  if EntryAt(Index) = nil then
    Exit('');
  Result := EntryAt(Index).FullPath;
end;

function TFolderView.IndexOfName(const Name: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Count - 1 do
    if EntryAt(Index).Item.Name = Name then
      Exit(Index);
  Result := -1;
end;

function TFolderView.IndexOfPath(const Path: string): LongInt;
var
  Index: LongInt;
begin
  if Path = '' then
    Exit(-1);
  for Index := 0 to Count - 1 do
    if EntryAt(Index).FullPath = Path then
      Exit(Index);
  Result := -1;
end;

procedure TFolderView.GetSelectedPaths(Paths: TStrings; Any: Boolean);
var
  Index: LongInt;
begin
  Paths.Clear;
  for Index := 0 to Count - 1 do
    if Selected[Index] and (Any or EntryAt(Index).IsRealFile) then
      Paths.Add(EntryAt(Index).FullPath);
end;

procedure TFolderView.GetSelectedEntries(List: TList);
var
  Index: LongInt;
begin
  List.Clear;
  for Index := 0 to Count - 1 do
    if Selected[Index] then
      List.Add(EntryAt(Index));
end;

function TFolderView.SelectedTotalSize: QWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    if Selected[Index] and (EntryAt(Index).Item.Kind = ItemFile) then
      Result := Result + EntryAt(Index).Item.SizeInBytes;
end;

procedure TFolderView.SelectNames(Names: TStrings);
var
  Index: LongInt;
  Row: LongInt;
  First: Boolean;
begin
  ClearSelection;
  First := True;
  for Index := 0 to Names.Count - 1 do
  begin
    Row := IndexOfName(Names[Index]);
    if Row < 0 then
      Continue;
    if First then
    begin
      ItemIndex := Row;
      First := False;
    end
    else
      Selected[Row] := True;
  end;
end;

procedure TFolderView.SelectPaths(Paths: TStrings);
var
  Index: LongInt;
  Row: LongInt;
  First: Boolean;
begin
  ClearSelection;
  First := True;
  for Index := 0 to Paths.Count - 1 do
  begin
    Row := IndexOfPath(Paths[Index]);
    if Row < 0 then
      Continue;
    if First then
    begin
      ItemIndex := Row;
      First := False;
    end
    else
      Selected[Row] := True;
  end;
end;

procedure TFolderView.MarkCut(Paths: TStrings);
var
  Index: LongInt;
begin
  FCutPaths.Clear;
  if Paths <> nil then
    FCutPaths.AddStrings(Paths);
  for Index := 0 to Count - 1 do
    Items[Index].Dimmed := ((EntryAt(Index).Kind = EntryFile) and IsHiddenName(EntryAt(Index).Item.Name)) or
      (FCutPaths.IndexOf(EntryAt(Index).FullPath) >= 0);
end;

procedure TFolderView.TellPlaces;
var
  Index: LongInt;
  Box: TRectangle;
  Column: TColumnKind;
begin
  if Mode = ItemViewDetails then
    for Column := Low(TColumnKind) to High(TColumnKind) do
      if (Column = ColumnName) or ColumnShown(Column) then
      begin
        Box := ColumnHeaderBounds(Ord(Column));
        if RectangleWidth(Box) > 0 then
          TellPlace('header-' + ColumnKeys[Column], Self, Box.Left + RectangleWidth(Box) div 2,
            Box.Top + RectangleHeight(Box) div 2);
      end;
  Index := 0;
  while (Index < Count) and (Index < MostPlacesTold) do
  begin
    if IsItemShown(Index) then
    begin
      Box := NameBounds(Index);
      if (Box.Bottom > 0) and (Box.Top < RectangleHeight(PixelBounds)) then
        TellPlace('item-' + EntryAt(Index).Item.Name, Self, Box.Left + Scaled(12),
          Box.Top + RectangleHeight(Box) div 2);
    end;
    Inc(Index);
  end;
  for Index := 0 to GroupCount - 1 do
  begin
    Box := GroupBounds(Index);
    if RectangleWidth(Box) > 0 then
      TellPlace('group-' + StringReplace(LowerCase(Groups[Index].Caption), ' ', '-', [rfReplaceAll]), Self,
        Box.Left + Scaled(30), Box.Top + RectangleHeight(Box) div 2);
  end;
  TellPlace('folder-empty-space', Self, RectangleWidth(PixelBounds) - 30, RectangleHeight(PixelBounds) - 30);
end;

{ --- Dragging -------------------------------------------------------------------------------------- }

procedure TFolderView.StartDragging(Sender: TItemView; var Data: TDragData);
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

function TFolderView.DropFolderAt(X, Y: LongInt; Data: TDragData; out Index: LongInt): string;
var
  Entry: TFolderEntry;
begin
  Index := ItemAt(X, Y);
  Entry := EntryAt(Index);
  if (Entry <> nil) and Entry.IsFolder and (Entry.Kind in [EntryFile, EntryPlace, EntryVolume]) and
     not ((Data.Source = Self) and Selected[Index]) then
    Exit(Entry.FullPath);
  Index := -1;
  Result := Folder;
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
  if Data.Format <> DragFormatFileList then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) or (Paths.Count = 0) then
      Exit;
    Target := DropFolderAt(X, Y, Data, Index);
    if (Target = '') or not CanDropInto(Paths, Target) then
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
  DropTarget := -1;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) then
      Exit;
    Target := DropFolderAt(X, Y, Data, Index);
    if (Target <> '') and Assigned(FOnDropFiles) and CanDropInto(Paths, Target) then
      FOnDropFiles(Self, Paths, Target, Effect);
  finally
    Paths.Free;
  end;
end;

end.
