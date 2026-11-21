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
  The file manager's window as far as finding one's way goes: its
  parts, laid out, its tabs, and going from place to place.

  From the top: the tabs (Controls.TabStrip: new, close, reorder, drag
  one out to a window of its own), the navigation bar (Back, Forward,
  Up, Refresh; the address bar, Controls.BreadcrumbBar: a segment's
  click goes there, its chevron lists the folders inside, a click on
  the empty part edits the address as text with completion; the search
  box), the command bar (FileManager.MainWindow fills it), then the
  navigation pane at the left (FileManager.NavigationPane), the page
  (FileManager.FolderView) and the details or preview pane at the right
  (FileManager.SidePane), with splitters between them, and the status
  bar: how many items, how many selected and their size.

  Every tab has its own place and history (FileManager.Tabs); the
  controls show the active one. Going somewhere adds it to the history;
  Up goes to the place above. The title is the place's. A folder that
  goes away while shown is left for the nearest folder above it that is
  still there (or Home) and forgotten from the history.

  It prints "folder ADDRESS COUNT" for each place shown, "tab ..." for
  the tabs, "search ..." for searches and where its parts are.
}
unit FileManager.BrowserWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.Window,
  Controls.Panels,
  Controls.EditBox,
  Controls.Menus,
  Controls.ToolBar,
  Controls.ImageList,
  Controls.StatusBar,
  Controls.Splitter,
  Controls.TabStrip,
  Controls.BreadcrumbBar,
  Controls.CommandBar,
  Controls.SuggestionList,
  FileManager.Settings,
  FileManager.Locations,
  FileManager.Tabs,
  FileManager.FolderView,
  FileManager.NavigationPane,
  FileManager.SidePane;

type
  TBrowserWindow = class(TControlWindow)
  private
    FTabs: TList;
    FActiveTab: LongInt;
    FTabImages: TImageList;
    FTabIcons: TStringList;
    FNavigationBar: TPanel;
    FNavigationButtons: TCommandBar;
    FBackButton: TCommandButton;
    FForwardButton: TCommandButton;
    FUpButton: TCommandButton;
    FRefreshButton: TCommandButton;
    FTabMenu: TMenuItem;
    FTabMenuIndex: LongInt;
    FSearchSuggestions: TSuggestionDropDown;
    function TabIcon(const Name: string): LongInt;
    procedure BackClicked(Sender: TControl);
    procedure ForwardClicked(Sender: TControl);
    procedure UpClicked(Sender: TControl);
    procedure RefreshClicked(Sender: TControl);
    procedure SegmentChosen(Sender: TControl; const Path: string);
    procedure SegmentChildren(Sender: TControl; const Path: string; Names: TStrings);
    procedure AddressEntered(Sender: TControl; const Text: string);
    procedure AddressCompletion(Sender: TControl; const Text: string; Suggestions: TStrings);
    procedure SearchKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure SearchFocusChanged(Sender: TControl);
    procedure SearchSuggestionAccepted(Index: LongInt);
    procedure PlaceChosen(Sender: TControl; const Address: string);
    procedure VolumeRemoved(Sender: TControl; const VolumeName, MountPoint: string);
    procedure FolderGone(Sender: TControl);
    procedure ViewRefreshed(Sender: TControl);
    procedure TabClicked(Sender: TControl);
    procedure NewTabClicked(Sender: TControl);
    procedure TabCloseClicked(Sender: TControl; Index: LongInt);
    procedure TabMoved(Sender: TControl; FromIndex, ToIndex: LongInt);
    procedure TabDraggedOut(Sender: TControl; Index, ScreenX, ScreenY: LongInt);
    procedure TabMenuWanted(Sender: TControl; Index, X, Y: LongInt);
    procedure TabMenuChosen(Item: TMenuItem);
    procedure PlaceStatusPanels;
    procedure SaveActiveTab;
    procedure ShowTabCaption(Index: LongInt);
  protected
    FOptions: TFileManagerOptions;
    FTabStrip: TTabStrip;
    FBreadcrumb: TBreadcrumbBar;
    FSearchBox: TEditBox;
    FCommandBar: TCommandBar;
    FCommandImages: TImageList;
    FPlaces: TNavigationPane;
    FSplitter: TSplitter;
    FView: TFolderView;
    FSidePane: TSidePane;
    FSideSplitter: TSplitter;
    FStatusBar: TStatusBar;
    FScaleWasChanged: Boolean;
    procedure Resized; override;
    procedure Moved; override;
    procedure ScaleChanged; override;
    { The place shown changed (another place, or read again). }
    procedure FolderShown; virtual;
    { The selection changed: the side pane and the status follow. }
    procedure SelectionShown; virtual;
    procedure UpdateNavigation;
    function ActiveTab: TBrowserTab;
  public
    constructor Create;
    destructor Destroy; override;
    { Goes to Location in the active tab; False (after saying why) if it
      cannot be shown. AddToHistory: not for Back and Forward. }
    function Navigate(const Location: TLocation; AddToHistory: Boolean = True): Boolean;
    { Goes to what was typed or chosen (an address or a path). }
    function NavigateAddress(const Text: string): Boolean;
    procedure GoBack;
    procedure GoForward;
    procedure GoUp;
    procedure RefreshFolder;
    { Searches the place shown (or Home's folder) for Text. }
    procedure StartSearch(const Text: string);
    procedure FocusAddress;
    procedure FocusSearch;
    { Tabs. }
    procedure NewTab(const Location: TLocation);
    procedure CloseTab(Index: LongInt);
    procedure SwitchToTab(Index: LongInt);
    procedure DuplicateTab(Index: LongInt);
    procedure MoveTabToNewWindow(Index: LongInt);
    procedure NextTab(Forward: Boolean);
    function TabCount: LongInt;
    { The details or preview pane (or none). }
    procedure ShowSidePane(Kind: TSidePaneKind);
    procedure HideSidePane;
    function SidePaneShown: Boolean;
    procedure UpdateStatus;
    { Says where the window's parts are (place NAME X Y). }
    procedure TellPlaces; virtual;
  end;

const
  ProgramTitle = 'Files';

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Drawing.Rectangles,
  Windowing.Windows,
  Windowing.Connection,
  Controls.LayoutRules,
  Controls.Keys,
  Controls.MessageBoxes,
  Controls.Icons,
  Controls.IconTheme,
  Controls.FileNames,
  Controls.FolderListing,
  Controls.ItemViewItems,
  Archive.Readers,
  Archive.Folders,
  FileManager.Items,
  FileManager.Entries,
  FileManager.Paths,
  FileManager.FolderReading,
  FileManager.Sources,
  FileManager.UserLists,
  FileManager.ErrorTexts,
  FileManager.Launching,
  FileManager.TestPlaces,
  FileManager.Output;

type
  { Controls.FolderListing has a TFolderEntry of its own. }
  TFolderEntry = FileManager.Entries.TFolderEntry;

const
  NavigationBarHeight = 36;
  { Four buttons of 32 with their gaps, the padding, and room the bar
    keeps for its overflow button. }
  NavigationButtonsWidth = 4 * 34 + 8 + 32 + 4;
  SearchBoxWidth = 220;
  ItemsPanelWidth = 160;
  MostCompletions = 12;

constructor TBrowserWindow.Create;
begin
  FOptions := RememberedOptions;
  inherited Create(ProgramTitle, FOptions.WindowLeft, FOptions.WindowTop, FOptions.WindowWidth,
    FOptions.WindowHeight);
  IconName := 'app-file-manager';
  EnsureStandardFolders;
  FTabs := TList.Create;
  FActiveTab := -1;
  FTabIcons := TStringList.Create;
  FTabImages := TImageList.Create(SmallIconSize, SmallIconSize);
  FCommandImages := TImageList.Create(SmallIconSize, SmallIconSize);
  { Docked in the order made: the bars at the top, the status bar at the
    bottom, the panes at the sides with their splitters, the page in what
    is left. }
  FTabStrip := TTabStrip.Create(Root);
  FTabStrip.Align := AlignTop;
  FTabStrip.Images := FTabImages;
  FTabStrip.OnChange := @TabClicked;
  FTabStrip.OnNewTab := @NewTabClicked;
  FTabStrip.OnCloseTab := @TabCloseClicked;
  FTabStrip.OnTabMoved := @TabMoved;
  FTabStrip.OnTabDraggedOut := @TabDraggedOut;
  FTabStrip.OnTabContextMenu := @TabMenuWanted;
  FNavigationBar := TPanel.Create(Root);
  FNavigationBar.SetBounds(0, 0, 0, NavigationBarHeight);
  FNavigationBar.Align := AlignTop;
  FNavigationButtons := TCommandBar.Create(FNavigationBar);
  FNavigationButtons.Images := FCommandImages;
  FNavigationButtons.Align := AlignLeft;
  FNavigationButtons.SetBounds(0, 0, NavigationButtonsWidth, NavigationBarHeight);
  FBackButton := FNavigationButtons.AddCommand('Back', AddThemeIcon(FCommandImages, 'action-back'),
    'Back (Alt+Left)', @BackClicked, False);
  FForwardButton := FNavigationButtons.AddCommand('Forward', AddThemeIcon(FCommandImages, 'action-forward'),
    'Forward (Alt+Right)', @ForwardClicked, False);
  FUpButton := FNavigationButtons.AddCommand('Up', AddThemeIcon(FCommandImages, 'action-up'), 'Up (Alt+Up)',
    @UpClicked, False);
  FRefreshButton := FNavigationButtons.AddCommand('Refresh', AddThemeIcon(FCommandImages, 'action-refresh'),
    'Refresh (F5)', @RefreshClicked, False);
  FSearchBox := TEditBox.Create(FNavigationBar);
  FSearchBox.Align := AlignRight;
  FSearchBox.SetBounds(0, 0, SearchBoxWidth, 24);
  FSearchBox.Margins := MakeSpacing(4, 6, 8, 6);
  FSearchBox.Hint := 'Search (Ctrl+E): kind:image size:>1MB modified:today ext:pas';
  FSearchBox.OnKeyDown := @SearchKeyDown;
  FSearchBox.OnFocusChanged := @SearchFocusChanged;
  FSearchSuggestions := TSuggestionDropDown.Create(FSearchBox, FSearchBox);
  FSearchSuggestions.OnAccept := @SearchSuggestionAccepted;
  FBreadcrumb := TBreadcrumbBar.Create(FNavigationBar);
  FBreadcrumb.Align := AlignClient;
  FBreadcrumb.Margins := MakeSpacing(4, 5, 4, 5);
  FBreadcrumb.OnNavigate := @SegmentChosen;
  FBreadcrumb.OnListChildren := @SegmentChildren;
  FBreadcrumb.OnPathEntered := @AddressEntered;
  FBreadcrumb.OnComplete := @AddressCompletion;
  FCommandBar := TCommandBar.Create(Root);
  FCommandBar.Align := AlignTop;
  FCommandBar.Images := FCommandImages;
  FStatusBar := TStatusBar.Create(Root);
  FPlaces := TNavigationPane.Create(Root);
  FPlaces.SetBounds(0, 0, FOptions.PlacesWidth, 0);
  FPlaces.Align := AlignLeft;
  FPlaces.OnPlaceChosen := @PlaceChosen;
  FPlaces.OnVolumeRemoved := @VolumeRemoved;
  FSplitter := TSplitter.Create(Root);
  FSplitter.Pane := FPlaces;
  FSidePane := TSidePane.Create(Root);
  FSidePane.SetBounds(0, 0, FOptions.PanesWidth, 0);
  FSidePane.Align := AlignRight;
  FSideSplitter := TSplitter.Create(Root);
  FSideSplitter.Pane := FSidePane;
  FView := TFolderView.Create(Root);
  FView.Align := AlignClient;
  FView.Compact := FOptions.Compact;
  FView.ShowCheckBoxes := FOptions.ShowCheckBoxes;
  FView.SingleClickOpens := FOptions.SingleClick;
  FView.SetShowHidden(FOptions.ShowHidden);
  FView.SetShowExtensions(FOptions.ShowExtensions);
  FView.SetHomeSections(FOptions.ShowRecent, FOptions.ShowFavorites);
  FView.OnFolderGone := @FolderGone;
  FView.OnRefreshed := @ViewRefreshed;
  FView.OnSearchFinished := @ViewRefreshed;
  if FOptions.ShowPreviewPane then
    ShowSidePane(SidePanePreview)
  else if FOptions.ShowDetailsPane then
    ShowSidePane(SidePaneDetails)
  else
    HideSidePane;
  PlaceStatusPanels;
  Resized;
  FocusControl(FView);
end;

destructor TBrowserWindow.Destroy;
var
  Index: LongInt;
  TabPictures: TImageList;
  CommandPictures: TImageList;
begin
  for Index := 0 to FTabs.Count - 1 do
    TBrowserTab(FTabs[Index]).Free;
  FTabs.Free;
  FTabIcons.Free;
  FTabMenu.Free;
  TabPictures := FTabImages;
  CommandPictures := FCommandImages;
  inherited Destroy;
  TabPictures.Free;
  CommandPictures.Free;
end;

function TBrowserWindow.TabIcon(const Name: string): LongInt;
var
  Position: LongInt;
begin
  Position := FTabIcons.IndexOf(Name);
  if Position >= 0 then
    Exit(PtrInt(FTabIcons.Objects[Position]));
  Result := AddThemeIcon(FTabImages, Name);
  FTabIcons.AddObject(Name, TObject(PtrInt(Result)));
end;

procedure TBrowserWindow.PlaceStatusPanels;
begin
  FStatusBar.SetPanels([ItemsPanelWidth, ClientWidth - ItemsPanelWidth]);
end;

procedure TBrowserWindow.Moved;
begin
  inherited Moved;
  if FView <> nil then
    TellPlaces;
end;

procedure TBrowserWindow.Resized;
begin
  inherited Resized;
  if FStatusBar = nil then
    Exit;
  PlaceStatusPanels;
  if FScaleWasChanged then
  begin
    FScaleWasChanged := False;
    TellPlaces;
  end;
end;

procedure TBrowserWindow.ScaleChanged;
begin
  inherited ScaleChanged;
  FScaleWasChanged := True;
end;

function TBrowserWindow.ActiveTab: TBrowserTab;
begin
  if (FActiveTab < 0) or (FActiveTab >= FTabs.Count) then
    Exit(nil);
  Result := TBrowserTab(FTabs[FActiveTab]);
end;

function TBrowserWindow.TabCount: LongInt;
begin
  Result := FTabs.Count;
end;

procedure TBrowserWindow.FocusAddress;
begin
  FBreadcrumb.BeginEditing;
  Say('address-editing');
end;

procedure TBrowserWindow.FocusSearch;
begin
  FocusControl(FSearchBox);
  FSearchBox.SelectAll;
end;

{ --- Going places ------------------------------------------------------------------------------ }

function TBrowserWindow.Navigate(const Location: TLocation; AddToHistory: Boolean): Boolean;
var
  Error: LongInt;
  Information: TFileInformation;
  Problem: string;
begin
  if ActiveTab = nil then
  begin
    NewTab(Location);
    Exit(SameLocation(ActiveTab.Location, Location));
  end;
  Error := ErrorNone;
  Problem := '';
  if Location.Kind = LocationFolder then
  begin
    Error := GetFileInformation(PChar(Location.Path), Information);
    if (Error = ErrorNone) and (Information.Kind <> KindDirectory) then
      Error := ErrorNotDirectory;
  end
  else if (Location.Kind = LocationArchive) and (OpenArchiveCached(Location.Path, Problem) = nil) then
    Error := ErrorInvalidArgument;
  if Error = ErrorNone then
  begin
    if ActiveTab <> nil then
      SaveActiveTab;
    Error := FView.ShowLocation(Location);
  end;
  if Error <> ErrorNone then
  begin
    if Problem = '' then
      Problem := ReasonText(Error);
    Say('error cannot show ' + LocationAddress(Location) + ': ' + Problem);
    if Error = ErrorNotDirectory then
      ShowMessageBox(ProgramTitle, Location.Path + ' is not a folder.', MessageOk, SignError, Self)
    else
      ShowMessageBox(ProgramTitle, 'Cannot show ' + LocationAddress(Location) + ':'#10 + Problem, MessageOk,
        SignError, Self);
    FBreadcrumb.EditText := LocationAddress(FView.Location);
    Exit(False);
  end;
  ActiveTab.Location := Location;
  if AddToHistory then
    ActiveTab.History.Visit(LocationKey(Location));
  FolderShown;
  Result := True;
end;

function TBrowserWindow.NavigateAddress(const Text: string): Boolean;
var
  Location: TLocation;
  Current: string;
begin
  Current := FView.Folder;
  if Current = '' then
    Current := HomeFolder;
  if not ParseAddress(Text, Current, Location) then
  begin
    Say('error no such place ' + Text);
    ShowMessageBox(ProgramTitle, 'Cannot find "' + Text + '".'#10'Check the spelling and try again.', MessageOk,
      SignError, Self);
    Exit(False);
  end;
  Result := Navigate(Location);
end;

procedure TBrowserWindow.ShowTabCaption(Index: LongInt);
var
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  Tab := TBrowserTab(FTabs[Index]);
  FTabStrip.TabCaption[Index] := LocationTitle(Tab.Location);
  FTabStrip.TabImageIndex[Index] := TabIcon(LocationIcon(Tab.Location));
  FTabStrip.TabHint[Index] := LocationAddress(Tab.Location);
end;

procedure TBrowserWindow.FolderShown;
var
  Location: TLocation;
  Segments: TBreadcrumbSegments;
  Captions: array of string;
  Paths: array of string;
  Index: LongInt;
begin
  Location := FView.Location;
  Title := LocationTitle(Location) + ' - ' + ProgramTitle;
  Segments := LocationSegments(Location);
  Captions := nil;
  Paths := nil;
  SetLength(Captions, Length(Segments));
  SetLength(Paths, Length(Segments));
  for Index := 0 to High(Segments) do
  begin
    Captions[Index] := Segments[Index].Caption;
    Paths[Index] := Segments[Index].Address;
  end;
  FBreadcrumb.SetSegments(Captions, Paths);
  FBreadcrumb.EditText := LocationAddress(Location);
  if Location.Kind = LocationSearch then
    FSearchBox.Text := Location.Query
  else
    FSearchBox.Text := '';
  FPlaces.ShowAddress(LocationAddress(Location), FView.Folder);
  FPlaces.UpdateTrash;
  ShowTabCaption(FActiveTab);
  UpdateNavigation;
  UpdateStatus;
  SelectionShown;
  Say('folder ' + LocationAddress(Location) + ' ' + IntToStr(FView.Count));
  TellPlaces;
end;

procedure TBrowserWindow.SelectionShown;
var
  Entries: TList;
  Items: TList;
  Index: LongInt;
begin
  UpdateStatus;
  if not FSidePane.Visible then
    Exit;
  Entries := TList.Create;
  Items := TList.Create;
  try
    for Index := 0 to FView.Count - 1 do
      if FView.Selected[Index] then
      begin
        Entries.Add(FView.EntryAt(Index));
        Items.Add(FView.Items[Index]);
      end;
    FSidePane.ShowSelection(Entries, Items, FView.Location, FView.Count);
  finally
    Entries.Free;
    Items.Free;
  end;
end;

procedure TBrowserWindow.UpdateNavigation;
var
  Parent: TLocation;
begin
  FBackButton.Enabled := (ActiveTab <> nil) and ActiveTab.History.CanGoBack;
  FForwardButton.Enabled := (ActiveTab <> nil) and ActiveTab.History.CanGoForward;
  FUpButton.Enabled := ParentLocation(FView.Location, Parent);
end;

procedure TBrowserWindow.GoBack;
var
  Current: TLocation;
begin
  if (ActiveTab = nil) or not ActiveTab.History.CanGoBack then
    Exit;
  Current := FView.Location;
  if not Navigate(LocationFromKey(ActiveTab.History.GoBack), False) then
    ActiveTab.History.GoForward;
  { Back up: the folder just left is selected, as one expects. }
  if (Current.Kind = LocationFolder) and (FView.Location.Kind = LocationFolder) and
     IsSameOrInside(Current.Path, FView.Location.Path) then
    FView.ItemIndex := FView.IndexOfName(LastPartOf(Current.Path));
end;

procedure TBrowserWindow.GoForward;
begin
  if (ActiveTab = nil) or not ActiveTab.History.CanGoForward then
    Exit;
  if not Navigate(LocationFromKey(ActiveTab.History.GoForward), False) then
    ActiveTab.History.GoBack;
end;

procedure TBrowserWindow.GoUp;
var
  Current: TLocation;
  Parent: TLocation;
begin
  Current := FView.Location;
  if not ParentLocation(Current, Parent) then
    Exit;
  if Navigate(Parent) and (Current.Kind in [LocationFolder, LocationArchive]) then
  begin
    if Current.Kind = LocationArchive then
    begin
      if Current.InnerPath = '' then
        FView.ItemIndex := FView.IndexOfPath(Current.Path)
      else
        FView.ItemIndex := FView.IndexOfName(LastPartOf('/' + Current.InnerPath));
    end
    else
      FView.ItemIndex := FView.IndexOfName(LastPartOf(Current.Path));
  end;
end;

procedure TBrowserWindow.RefreshFolder;
begin
  if FView.Location.Kind = LocationSearch then
    StartSearch(FView.Location.Query)
  else
    FView.Refresh;
end;

procedure TBrowserWindow.StartSearch(const Text: string);
var
  Scope: string;
begin
  if Trim(Text) = '' then
    Exit;
  Scope := FView.Folder;
  if FView.Location.Kind = LocationSearch then
    Scope := FView.Location.Path;
  if Scope = '' then
    Scope := HomeFolder;
  AddToUserList(ListSearchHistory, Trim(Text));
  Say('search ' + Scope + ' ' + Trim(Text));
  SaveActiveTab;
  FView.StartSearch(Scope, Trim(Text));
  ActiveTab.Location := FView.Location;
  ActiveTab.History.Visit(LocationKey(FView.Location));
  FolderShown;
end;

procedure TBrowserWindow.BackClicked(Sender: TControl);
begin
  GoBack;
end;

procedure TBrowserWindow.ForwardClicked(Sender: TControl);
begin
  GoForward;
end;

procedure TBrowserWindow.UpClicked(Sender: TControl);
begin
  GoUp;
end;

procedure TBrowserWindow.RefreshClicked(Sender: TControl);
begin
  RefreshFolder;
end;

{ --- The address bar ----------------------------------------------------------------------------- }

procedure TBrowserWindow.SegmentChosen(Sender: TControl; const Path: string);
begin
  if Path <> '' then
    NavigateAddress(Path);
end;

procedure TBrowserWindow.SegmentChildren(Sender: TControl; const Path: string; Names: TStrings);
var
  Location: TLocation;
  Items: TFolderItems;
  Index: LongInt;
  Reader: TArchiveReader;
  Problem: string;
  Inside: TArchiveFolderItems;
begin
  if not ParseAddress(Path, '/', Location) then
    Exit;
  case Location.Kind of
    LocationFolder:
      if ReadFolderItems(Location.Path, FView.ShowHidden, Items) = ErrorNone then
        for Index := 0 to High(Items) do
          if IsFolderItem(Items[Index]) then
            Names.Add(Items[Index].Name);
    LocationArchive:
      begin
        Reader := OpenArchiveCached(Location.Path, Problem);
        if Reader <> nil then
        begin
          Inside := ListArchiveFolder(Reader, Location.InnerPath);
          for Index := 0 to High(Inside) do
            if Inside[Index].IsFolder then
              Names.Add(Inside[Index].Name);
        end;
      end;
    LocationComputer:
      for Index := Ord(Low(TStandardFolder)) to Ord(High(TStandardFolder)) do
        Names.Add(StandardFolderNames[TStandardFolder(Index)]);
  end;
  if Names is TStringList then
    TStringList(Names).Sort;
  Say('chevron ' + Path + ' ' + IntToStr(Names.Count));
end;

procedure TBrowserWindow.AddressEntered(Sender: TControl; const Text: string);
begin
  Say('address-entered ' + Text);
  if NavigateAddress(Text) then
    FocusControl(FView);
end;

procedure TBrowserWindow.AddressCompletion(Sender: TControl; const Text: string; Suggestions: TStrings);
var
  Folder: string;
  Prefix: string;
  Slash: LongInt;
  Items: TFolderItems;
  Index: LongInt;
  Kind: TLocationKind;
  Typed: string;
begin
  Typed := Text;
  if Copy(Typed, 1, 1) = '~' then
    Typed := HomeFolder + Copy(Typed, 2, Length(Typed));
  if (Typed = '') or (Typed[1] <> '/') then
  begin
    for Kind := LocationHome to LocationTrash do
      if SameText(Copy(LocationAddress(PageLocation(Kind)), 1, Length(Typed)), Typed) then
        Suggestions.Add(LocationAddress(PageLocation(Kind)));
    Exit;
  end;
  Slash := Length(Typed);
  while (Slash > 1) and (Typed[Slash] <> '/') do
    Dec(Slash);
  Folder := Copy(Typed, 1, Slash);
  if Folder = '' then
    Folder := '/';
  Prefix := Copy(Typed, Slash + 1, Length(Typed));
  if ReadFolderItems(CleanPath(Folder), FView.ShowHidden or (Copy(Prefix, 1, 1) = '.'), Items) <> ErrorNone then
    Exit;
  for Index := 0 to High(Items) do
    if IsFolderItem(Items[Index]) and SameText(Copy(Items[Index].Name, 1, Length(Prefix)), Prefix) then
    begin
      Suggestions.Add(CombinePath(CleanPath(Folder), Items[Index].Name));
      if Suggestions.Count >= MostCompletions then
        Break;
    end;
end;

{ --- The search box ----------------------------------------------------------------------------- }

procedure TBrowserWindow.SearchKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord;
  var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    FSearchSuggestions.Close;
    StartSearch(FSearchBox.Text);
    FocusControl(FView);
  end
  else if Code = KeyEscape then
  begin
    Handled := True;
    FSearchSuggestions.Close;
    if FView.Searching then
    begin
      FView.CancelSearch;
      Say('search-cancelled');
    end
    else if FView.Location.Kind = LocationSearch then
      GoBack;
    FSearchBox.Text := '';
    FocusControl(FView);
  end;
end;

procedure TBrowserWindow.SearchFocusChanged(Sender: TControl);
var
  History: TStringList;
  Item: string;
begin
  if not FSearchBox.Focused then
    Exit;
  History := TStringList.Create;
  try
    for Item in ReadUserList(ListSearchHistory) do
      History.Add(Item);
    if History.Count > 0 then
      FSearchSuggestions.Show(History);
  finally
    History.Free;
  end;
end;

procedure TBrowserWindow.SearchSuggestionAccepted(Index: LongInt);
begin
  FSearchBox.Text := FSearchSuggestions.ChosenText;
  StartSearch(FSearchBox.Text);
end;

{ --- The panes -------------------------------------------------------------------------------- }

procedure TBrowserWindow.PlaceChosen(Sender: TControl; const Address: string);
begin
  NavigateAddress(Address);
end;

function NearestFolder(const Path: string): string;
begin
  Result := Path;
  while (Result <> '/') and not IsDirectory(PChar(Result)) do
    Result := ParentFolderOf(Result);
  if not IsDirectory(PChar(Result)) then
    Result := HomeFolder;
end;

procedure TBrowserWindow.FolderGone(Sender: TControl);
var
  Gone: string;
begin
  Gone := FView.Folder;
  Say('folder-gone ' + Gone);
  ActiveTab.History.Forget(LocationKey(FolderLocation(Gone)));
  Navigate(FolderLocation(NearestFolder(ParentFolderOf(Gone))));
end;

procedure TBrowserWindow.ViewRefreshed(Sender: TControl);
begin
  UpdateStatus;
  SelectionShown;
end;

procedure TBrowserWindow.VolumeRemoved(Sender: TControl; const VolumeName, MountPoint: string);
begin
  if ActiveTab <> nil then
    ActiveTab.History.Forget(LocationKey(FolderLocation(MountPoint)));
  if (FView.Folder <> '') and IsSameOrInside(FView.Folder, MountPoint) then
    FolderGone(FView)
  else if FView.Location.Kind = LocationComputer then
    FView.Refresh;
  UpdateNavigation;
end;

procedure TBrowserWindow.ShowSidePane(Kind: TSidePaneKind);
begin
  FSidePane.Kind := Kind;
  FSidePane.Visible := True;
  FSideSplitter.Visible := True;
  Root.RequestLayout;
  SelectionShown;
  if Kind = SidePanePreview then
    Say('pane preview')
  else
    Say('pane details');
end;

procedure TBrowserWindow.HideSidePane;
begin
  FSidePane.Visible := False;
  FSideSplitter.Visible := False;
  FSidePane.ShowMessage('');
  Root.RequestLayout;
  Say('pane none');
end;

function TBrowserWindow.SidePaneShown: Boolean;
begin
  Result := FSidePane.Visible;
end;

{ --- Tabs ------------------------------------------------------------------------------------- }

procedure TBrowserWindow.SaveActiveTab;
var
  Tab: TBrowserTab;
begin
  Tab := ActiveTab;
  if Tab = nil then
    Exit;
  FView.GetSelectedPaths(Tab.SelectedPaths, True);
end;

procedure TBrowserWindow.NewTab(const Location: TLocation);
var
  Tab: TBrowserTab;
  Index: LongInt;
  Previous: LongInt;
begin
  SaveActiveTab;
  Tab := TBrowserTab.Create(Location);
  Index := FTabs.Add(Tab);
  FTabStrip.AddTab(LocationTitle(Location), TabIcon(LocationIcon(Location)));
  Previous := FActiveTab;
  FActiveTab := Index;
  FTabStrip.ActiveIndex := Index;
  if not Navigate(Location) then
  begin
    { Cannot be shown: the tab goes again. }
    FTabs.Delete(Index);
    Tab.Free;
    FTabStrip.DeleteTab(Index);
    FActiveTab := Previous;
    if FActiveTab >= 0 then
    begin
      FTabStrip.ActiveIndex := FActiveTab;
      FView.ShowLocation(ActiveTab.Location);
      FolderShown;
    end;
    Exit;
  end;
  Say('tab new ' + IntToStr(FTabs.Count));
end;

procedure TBrowserWindow.SwitchToTab(Index: LongInt);
var
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) or (Index = FActiveTab) then
    Exit;
  SaveActiveTab;
  FActiveTab := Index;
  FTabStrip.ActiveIndex := Index;
  Tab := ActiveTab;
  if Tab.Location.Kind = LocationSearch then
    FView.StartSearch(Tab.Location.Path, Tab.Location.Query)
  else if FView.ShowLocation(Tab.Location) <> ErrorNone then
    FView.ShowLocation(PageLocation(LocationHome));
  FView.SelectPaths(Tab.SelectedPaths);
  FolderShown;
  Say('tab switch ' + IntToStr(Index));
end;

procedure TBrowserWindow.CloseTab(Index: LongInt);
var
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  if FTabs.Count = 1 then
  begin
    CloseRequested;
    Exit;
  end;
  Tab := TBrowserTab(FTabs[Index]);
  FTabs.Delete(Index);
  FTabStrip.DeleteTab(Index);
  Tab.Free;
  Say('tab close ' + IntToStr(FTabs.Count));
  if Index = FActiveTab then
  begin
    FActiveTab := -1;
    if Index >= FTabs.Count then
      Index := FTabs.Count - 1;
    SwitchToTab(Index);
  end
  else
  begin
    if Index < FActiveTab then
      Dec(FActiveTab);
    FTabStrip.ActiveIndex := FActiveTab;
  end;
end;

procedure TBrowserWindow.DuplicateTab(Index: LongInt);
var
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  SaveActiveTab;
  Tab := TBrowserTab(FTabs[Index]).Clone;
  Index := Index + 1;
  FTabs.Insert(Index, Tab);
  FTabStrip.InsertTab(Index, LocationTitle(Tab.Location), TabIcon(LocationIcon(Tab.Location)));
  if FActiveTab >= Index then
    Inc(FActiveTab);
  SwitchToTab(Index);
  Say('tab duplicate ' + IntToStr(FTabs.Count));
end;

procedure TBrowserWindow.MoveTabToNewWindow(Index: LongInt);
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  OpenNewWindow(LocationAddress(TBrowserTab(FTabs[Index]).Location));
  if FTabs.Count > 1 then
    CloseTab(Index);
end;

procedure TBrowserWindow.NextTab(Forward: Boolean);
var
  Index: LongInt;
begin
  if FTabs.Count < 2 then
    Exit;
  if Forward then
    Index := (FActiveTab + 1) mod FTabs.Count
  else
    Index := (FActiveTab + FTabs.Count - 1) mod FTabs.Count;
  SwitchToTab(Index);
end;

procedure TBrowserWindow.TabClicked(Sender: TControl);
begin
  SwitchToTab(FTabStrip.ActiveIndex);
end;

procedure TBrowserWindow.NewTabClicked(Sender: TControl);
begin
  NewTab(PageLocation(LocationHome));
end;

procedure TBrowserWindow.TabCloseClicked(Sender: TControl; Index: LongInt);
begin
  CloseTab(Index);
end;

procedure TBrowserWindow.TabMoved(Sender: TControl; FromIndex, ToIndex: LongInt);
begin
  { The strip moved its tab already; the tabs follow. }
  FTabs.Move(FromIndex, ToIndex);
  if FActiveTab = FromIndex then
    FActiveTab := ToIndex
  else if (FromIndex < FActiveTab) and (ToIndex >= FActiveTab) then
    Dec(FActiveTab)
  else if (FromIndex > FActiveTab) and (ToIndex <= FActiveTab) then
    Inc(FActiveTab);
  Say('tab moved ' + IntToStr(FromIndex) + ' ' + IntToStr(ToIndex));
end;

procedure TBrowserWindow.TabDraggedOut(Sender: TControl; Index, ScreenX, ScreenY: LongInt);
begin
  MoveTabToNewWindow(Index);
end;

procedure TBrowserWindow.TabMenuWanted(Sender: TControl; Index, X, Y: LongInt);
var
  Item: TMenuItem;
begin
  FTabMenuIndex := Index;
  FTabMenu.Free;
  FTabMenu := TMenuItem.Create('');
  Item := FTabMenu.Add('&New tab', @TabMenuChosen, 'Ctrl+T');
  Item.Tag := 0;
  if Index >= 0 then
  begin
    Item := FTabMenu.Add('&Duplicate tab', @TabMenuChosen);
    Item.Tag := 1;
    Item := FTabMenu.Add('&Move to a new window', @TabMenuChosen);
    Item.Tag := 2;
    FTabMenu.AddSeparator;
    Item := FTabMenu.Add('&Close tab', @TabMenuChosen, 'Ctrl+W');
    Item.Tag := 3;
    Item := FTabMenu.Add('Close &other tabs', @TabMenuChosen);
    Item.Tag := 4;
    Item.Enabled := FTabs.Count > 1;
    Item := FTabMenu.Add('Close tabs to the &right', @TabMenuChosen);
    Item.Tag := 5;
    Item.Enabled := Index < FTabs.Count - 1;
  end;
  ShowPopupMenu(Self, FTabMenu, ScreenLeft + Unscaled(FTabStrip.PixelBounds.Left + X),
    ScreenTop + Unscaled(FTabStrip.PixelBounds.Top + Y));
end;

procedure TBrowserWindow.TabMenuChosen(Item: TMenuItem);
var
  Index: LongInt;
begin
  case Item.Tag of
    0: NewTab(PageLocation(LocationHome));
    1: DuplicateTab(FTabMenuIndex);
    2: MoveTabToNewWindow(FTabMenuIndex);
    3: CloseTab(FTabMenuIndex);
    4:
      begin
        Index := FTabs.Count - 1;
        while Index >= 0 do
        begin
          if Index <> FTabMenuIndex then
          begin
            CloseTab(Index);
            if Index < FTabMenuIndex then
              Dec(FTabMenuIndex);
          end;
          Dec(Index);
        end;
      end;
    5:
      while FTabs.Count - 1 > FTabMenuIndex do
        CloseTab(FTabs.Count - 1);
  end;
end;

{ --- Status ---------------------------------------------------------------------------------- }

procedure TBrowserWindow.UpdateStatus;
var
  Count: LongInt;
  Chosen: LongInt;
  Text: string;
begin
  Count := FView.Count;
  if Count = 1 then
    Text := '1 item'
  else
    Text := IntToStr(Count) + ' items';
  if FView.Searching then
    Text := Text + ' (searching)';
  FStatusBar.PanelText[0] := Text;
  Chosen := FView.SelectedCount;
  if Chosen = 0 then
    FStatusBar.PanelText[1] := ''
  else
  begin
    if Chosen = 1 then
      Text := '1 item selected'
    else
      Text := IntToStr(Chosen) + ' items selected';
    if FView.SelectedTotalSize > 0 then
      Text := Text + '  ' + SizeText(FView.SelectedTotalSize);
    FStatusBar.PanelText[1] := Text;
  end;
end;

procedure TBrowserWindow.TellPlaces;
var
  Index: LongInt;
  Box: TRectangle;
  Point: TPoint;
begin
  Box := FNavigationButtons.ButtonBounds(FBackButton);
  TellPlace('back', FNavigationButtons, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  Box := FNavigationButtons.ButtonBounds(FForwardButton);
  TellPlace('forward', FNavigationButtons, Box.Left + RectangleWidth(Box) div 2,
    Box.Top + RectangleHeight(Box) div 2);
  Box := FNavigationButtons.ButtonBounds(FUpButton);
  TellPlace('up', FNavigationButtons, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  Box := FNavigationButtons.ButtonBounds(FRefreshButton);
  TellPlace('refresh', FNavigationButtons, Box.Left + RectangleWidth(Box) div 2,
    Box.Top + RectangleHeight(Box) div 2);
  TellControlPlace('search', FSearchBox);
  Point := FBreadcrumb.EmptyAreaPoint;
  TellPlace('address', FBreadcrumb, Point.X, Point.Y);
  for Index := 0 to FBreadcrumb.SegmentCount - 1 do
  begin
    Box := FBreadcrumb.SegmentBounds(Index);
    if RectangleWidth(Box) > 0 then
      TellPlace('segment-' + FBreadcrumb.SegmentCaption(Index), FBreadcrumb, Box.Left + RectangleWidth(Box) div 2,
        Box.Top + RectangleHeight(Box) div 2);
    Box := FBreadcrumb.ChevronBounds(Index);
    if RectangleWidth(Box) > 0 then
      TellPlace('chevron-' + FBreadcrumb.SegmentCaption(Index), FBreadcrumb, Box.Left + RectangleWidth(Box) div 2,
        Box.Top + RectangleHeight(Box) div 2);
  end;
  for Index := 0 to FTabStrip.TabCount - 1 do
  begin
    Box := FTabStrip.TabBounds(Index);
    TellPlace('tab-' + IntToStr(Index), FTabStrip, Box.Left + RectangleWidth(Box) div 2,
      Box.Top + RectangleHeight(Box) div 2);
  end;
  Box := FTabStrip.NewTabButtonBounds;
  TellPlace('tab-new', FTabStrip, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  FPlaces.TellPlaces;
  FView.TellPlaces;
end;

end.
