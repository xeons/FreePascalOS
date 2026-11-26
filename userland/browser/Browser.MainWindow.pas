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
  A browser window, laid out as browsers were before they hid their
  menus, top to bottom: the menu bar (Browser.MenuBar; View > Toolbars
  hides it, Alt shows it again for a moment), the Navigation Toolbar and
  the Bookmarks Toolbar (Browser.Toolbars, customizable), the palette
  while customizing, the tab strip (Browser.TabStrip, under the
  toolbars), the sidebar (bookmarks or history) beside the pages, the
  pages (a web view per tab), the find bar and the status bar
  (Browser.StatusBar). The window's title is the page's, with
  "(Private Browsing)" while browsing privately.

  Its parts:
  - Browser.MainWindow.Tabs.inc: opening, closing, moving and choosing
    tabs, undoing a close, the session of the window;
  - Browser.MainWindow.Commands.inc: the commands (Browser.Commands)
    the menus, buttons and keys run, and what the menus show as they
    open (the history, bookmarks, recently closed tabs and windows);
  - Browser.MainWindow.Views.inc: what the web views tell (title,
    address, loading, icon, links for new tabs, downloads, the console,
    context menus) and the tab context menu.
}
unit Browser.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Windowing.Messages,
  Controls.Base,
  Controls.Window,
  Controls.Panels,
  Controls.Menus,
  Controls.Splitter,
  Controls.SuggestionPopup,
  Web.Navigation.Navigables,
  WebView.Control,
  WebView.Types,
  Browser.Settings,
  Browser.SessionStore,
  Browser.Downloads,
  Browser.Bookmarks,
  Browser.Tabs,
  Browser.TabStrip,
  Browser.FindBar,
  Browser.MenuBar,
  Browser.Toolbars,
  Browser.LocationBar,
  Browser.SearchBar,
  Browser.BookmarksToolbar,
  Browser.StatusBar,
  Browser.Sidebar;

const
  MessageEndCustomize = MessageUser + 10;
  MessageCloseTabLater = MessageUser + 11;

type
  TBrowserWindow = class(TControlWindow)
  private
    FTabs: TList;
    FActive: Integer;
    FMenus: TBrowserMenus;
    FToolbars: TBrowserToolbars;
    FTabStrip: TTabStrip;
    FSidebar: TBrowserSidebar;
    FSidebarSplitter: TSplitter;
    FContent: TPanel;
    FFindBar: TFindBar;
    FStatusBar: TBrowserStatusBar;
    FContextMenu: TMenuItem;
    { Items that only carry keys (AddKey): never shown. }
    FKeyItems: TMenuItem;
    FContext: TWebContextInfo;
    FContextView: TWebView;
    FTabMenuIndex: Integer;
    FFullScreen: Boolean;
    { The view whose page is fullscreen (the Fullscreen API: the window
      fills the screen with the page alone), nil if none. }
    FPageFullscreenView: TWebView;
    FClosing: Boolean;
    FLastFindText: string;
    { Building. }
    procedure BuildLayout;
    procedure AddKeys;
    procedure ItemMade(const ItemId: string; Control: TControl);
    procedure ToolbarsChanged(Sender: TControl);
    procedure CustomizeDone(Sender: TControl);
    procedure UpdateBarsVisible;
    { Tabs (Browser.MainWindow.Tabs.inc). }
    function TabAt(Index: Integer): TBrowserTab;
    function ActiveTab: TBrowserTab;
    function TabOfView(View: TWebView): Integer;
    function NewTab(Index: Integer): TBrowserTab;
    procedure ActivateTab(Index: Integer);
    procedure CloseTab(Index: Integer);
    procedure MoveTab(FromIndex, ToIndex: Integer);
    procedure UndoCloseTab(Index: Integer);
    procedure TabSelected(Sender: TObject; Index: Integer);
    procedure TabClosed(Sender: TObject; Index: Integer);
    procedure TabMoved(Sender: TObject; FromIndex, ToIndex: Integer);
    procedure TabTornOff(Sender: TObject; Index: Integer);
    procedure TabMenuRequested(Sender: TObject; Index: Integer; X, Y: LongInt);
    procedure NewTabClicked(Sender: TControl);
    procedure RefreshTab(Index: Integer);
    function CaptureTab(Index: Integer): TSessionTab;
    procedure RestoreTab(Tab: TBrowserTab; constref Saved: TSessionTab);
    { The chrome. }
    procedure RefreshChrome;
    procedure RefreshLocation;
    procedure ShowStatus(const Text: string);
    function TabIsLoading(Tab: TBrowserTab): Boolean;
    { The location bar and the search bar. }
    procedure LocationNavigate(Sender: TLocationBar; const Text: string; InNewTab: Boolean);
    procedure LocationSuggest(Sender: TLocationBar; const Typed: string; out Rows: TSuggestionRows;
      out Urls: TStringArray);
    procedure LocationDropDown(Sender: TLocationBar; const Typed: string; out Rows: TSuggestionRows;
      out Urls: TStringArray);
    procedure LocationRevert(Sender: TControl);
    procedure LocationEdited(Sender: TControl);
    procedure IdentityClicked(Sender: TControl);
    procedure StarClicked(Sender: TControl);
    procedure SearchRequested(Sender: TSearchBar; const Words: string; InNewTab: Boolean);
    procedure EngineChosen(Sender: TSearchBar; const Name: string);
    procedure ManageEnginesRequested(Sender: TControl);
    procedure GoToAddressIn(Tab: TBrowserTab; const Text: string);
    { Bookmarks toolbar and sidebar. }
    procedure BookmarkOpened(const Url: string; Disposition: TLinkDisposition);
    procedure BookmarkAddRequested(Kind: TBookmarkKind; Folder: TBookmarkNode; Index: Integer);
    procedure BookmarkEditRequested(Node: TBookmarkNode);
    procedure BookmarkFolderOpened(Folder: TBookmarkNode);
    procedure SidebarClosed(Sender: TControl);
    procedure ShowSidebar(Kind: TSidebarKind);
    { Find. }
    procedure FindRequested(const Text: string; Forward, MatchCase, FromStart: Boolean);
    procedure HighlightRequested(const Text: string; MatchCase, TurnedOn: Boolean);
    procedure FindClosed(Sender: TControl);
    { Status bar. }
    procedure LockClicked(Sender: TControl);
    procedure DownloadsClicked(Sender: TControl);
    { Commands and menus (Browser.MainWindow.Commands.inc). }
    procedure MenuCommand(Item: TMenuItem);
    function CommandEnabled(Command: LongInt): Boolean;
    function CommandChecked(Command: LongInt): Boolean;
    procedure UpdateMenu(Menu: TMenuItem);
    procedure MenuOpening(Item: TMenuItem);
    procedure HistoryMenuOpening(Item: TMenuItem);
    procedure BookmarksMenuOpening(Item: TMenuItem);
    procedure ClosedTabsOpening(Item: TMenuItem);
    procedure ClosedWindowsOpening(Item: TMenuItem);
    procedure ToolbarFolderOpening(Item: TMenuItem);
    procedure RecentlyBookmarkedOpening(Item: TMenuItem);
    procedure RecentTagsOpening(Item: TMenuItem);
    procedure EncodingOpening(Item: TMenuItem);
    procedure HistoryItemChosen(Item: TMenuItem);
    procedure BookmarkItemChosen(Item: TMenuItem);
    procedure TagItemChosen(Item: TMenuItem);
    procedure ClosedTabChosen(Item: TMenuItem);
    procedure ClosedWindowChosen(Item: TMenuItem);
    procedure EncodingChosen(Item: TMenuItem);
    procedure BackMenuOpening(Sender: TControl);
    procedure ForwardMenuOpening(Sender: TControl);
    procedure HistoryOffsetChosen(Item: TMenuItem);
    procedure AddKey(Command: LongInt; Code, Modifiers: LongWord);
    procedure BookmarkThisPage;
    procedure BookmarkAllTabs;
    procedure OpenLocation;
    procedure SaveUrl(const Url, SuggestedName: string);
    procedure SetDesktopBackground(const Url: string);
    procedure ToggleFullScreen;
    procedure ZoomView(Command: LongInt);
    procedure WebSearch(const Words: string; InNewTab: Boolean);
    { What the views tell (Browser.MainWindow.Views.inc). }
    procedure HookView(View: TWebView);
    procedure ViewTitleChanged(Sender: TWebView; const Text: string);
    procedure ViewLocationChanged(Sender: TWebView; const Text: string);
    procedure ViewLoadingStateChanged(Sender: TWebView; State: TLoadingState);
    procedure ViewFaviconChanged(Sender: TWebView);
    procedure ViewStatusText(Sender: TWebView; const Text: string);
    procedure ViewHistoryChanged(Sender: TWebView);
    procedure ViewZoomChanged(Sender: TWebView);
    procedure ViewLinkClicked(Sender: TWebView; const Url: string; Disposition: TLinkDisposition; var Handled: Boolean);
    procedure ViewDownloadRequested(Sender: TWebView; constref Download: TDownloadInfo);
    procedure ViewNavigationFailed(Sender: TWebView; const Url, Reason: string);
    procedure ViewContextMenu(Sender: TWebView; constref Info: TWebContextInfo; var Handled: Boolean);
    procedure ContextMenuChosen(Item: TMenuItem);
    procedure TabMenuChosen(Item: TMenuItem);
    procedure ViewDialog(Sender: TWebView; const Kind, Message: string);
    procedure ViewConsole(Sender: TWebView; const Level, Text: string);
    procedure ViewFindResult(Sender: TWebView; const Needle: string; Found: Boolean);
    procedure ViewFindDetails(Sender: TWebView; const Needle: string; Found, Wrapped: Boolean; MatchCount: Integer);
    procedure ViewProcessEvent(Sender: TWebView; const What: string; Value: Int64);
    procedure ViewPopupBlocked(Sender: TWebView; const Url: string);
    function ViewFullscreenRequest(Sender: TWebView; Enter: Boolean): Boolean;
    procedure LeavePageFullscreen(TellPage: Boolean);
    procedure ViewPageInfo(Sender: TWebView; constref Info: TWebPageInfo);
    procedure ApplyViewSettings(View: TWebView);
    { about:crash, about:kill and about:hang (tests): False for others. }
    function RunDebugAddress(Tab: TBrowserTab; const Text: string): Boolean;
    function AboutPage(const Path: string; out Html: string): Boolean;
  protected
    procedure CloseRequested; override;
    procedure ActiveChanged; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Opens Url (as typed: Browser.Addresses) in a new tab after the
      chosen one; Bringing shows it. }
    function OpenTab(const Url: string; Bringing: Boolean): TBrowserTab;
    { A tab per address, the first shown. }
    procedure OpenAddresses(const Addresses: TStringArray);
    { Url here, in a new tab, a background tab or a new window. }
    procedure OpenUrl(const Url: string; Disposition: TLinkDisposition);
    procedure GoToAddress(const Text: string);
    function ActiveView: TWebView;
    function TabCount: Integer;
    function TabUrl(Index: Integer): string;
    { The window's session, and the window from one. }
    function CaptureSession: TSessionWindow;
    procedure RestoreSession(constref Saved: TSessionWindow);
    { Closes without asking or remembering (the browser is ending). }
    procedure CloseQuietly;
    procedure ApplySettings;
    procedure BookmarksChanged;
    procedure SearchEnginesChanged;
    procedure DownloadChanged(Item: TDownloadItem);
    procedure RunCommand(Command: LongInt);
    { Prints where the bars are (tests): "layout menu Y toolbars Y tabs Y
      content Y status Y", pixels from the client area's top. }
    procedure ReportLayout;
  end;

implementation

uses
  Math,
  DateUtils,
  Abi.SystemCalls,
  Image.Model,
  Windowing.Windows,
  Windowing.Connection,
  Controls.Dialogs,
  Controls.EditBox,
  Controls.Keys,
  Controls.Clipboard,
  Controls.MessageBoxes,
  Controls.FileDialog,
  Controls.ImageList,
  Controls.ToolBar,
  Configuration.Settings,
  Configuration.Locations,
  WebView.Network,
  WebView.Zoom,
  Browser.Commands,
  Browser.Addresses,
  Browser.Keywords,
  Browser.History,
  Browser.AwesomeBar,
  Browser.SearchEngines,
  Browser.BookmarkMenus,
  Browser.ViewSupport,
  Browser.Application,
  Browser.AboutPages,
  Browser.Output,
  Browser.InputDialog,
  Browser.Options,
  Browser.LibraryWindow,
  Browser.PageInfo,
  Browser.PageSource,
  Browser.ErrorConsole,
  Browser.ClearHistory,
  Browser.BookmarkPanel,
  Browser.BookmarkDialogs,
  Browser.IdentityPopup,
  Browser.AboutDialog,
  Browser.SearchEngineDialog;

const
  ProgramName = 'Browser';

constructor TBrowserWindow.Create;
begin
  inherited Create(ProgramName, 60, 40, 1000, 700);
  IconName := 'app-web-browser';
  FTabs := TList.Create;
  FActive := -1;
  FTabMenuIndex := -1;
  BuildLayout;
  AddKeys;
  ApplySettings;
end;

destructor TBrowserWindow.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FTabs.Count - 1 do
    TBrowserTab(FTabs[Index]).Free;
  FTabs.Free;
  FContextMenu.Free;
  FKeyItems.Free;
  FToolbars.Free;
  inherited Destroy;
end;

procedure TBrowserWindow.BuildLayout;
begin
  BuildBrowserMenus(Self, Root, @MenuCommand, FMenus);
  FMenus.Bar.DockOrder := 0;
  FMenus.FileMenu.OnOpening := @MenuOpening;
  FMenus.EditMenu.OnOpening := @MenuOpening;
  FMenus.ViewMenu.OnOpening := @MenuOpening;
  FMenus.ToolbarsMenu.OnOpening := @MenuOpening;
  FMenus.SidebarMenu.OnOpening := @MenuOpening;
  FMenus.ZoomMenu.OnOpening := @MenuOpening;
  FMenus.PageStyleMenu.OnOpening := @MenuOpening;
  FMenus.EncodingMenu.OnOpening := @EncodingOpening;
  FMenus.HistoryMenu.OnOpening := @HistoryMenuOpening;
  FMenus.BookmarksMenu.OnOpening := @BookmarksMenuOpening;
  FMenus.ToolsMenu.OnOpening := @MenuOpening;
  FMenus.HelpMenu.OnOpening := @MenuOpening;
  FMenus.ClosedTabsMenu.OnOpening := @ClosedTabsOpening;
  FMenus.ClosedWindowsMenu.OnOpening := @ClosedWindowsOpening;
  FMenus.ToolbarFolderMenu.OnOpening := @ToolbarFolderOpening;
  FMenus.RecentlyBookmarkedMenu.OnOpening := @RecentlyBookmarkedOpening;
  FMenus.RecentTagsMenu.OnOpening := @RecentTagsOpening;
  { Submenus filled as they open need an item to show as submenus. }
  FMenus.ClosedTabsMenu.Add('(Empty)').Enabled := False;
  FMenus.ClosedWindowsMenu.Add('(Empty)').Enabled := False;
  FMenus.ToolbarFolderMenu.Add('(Empty)').Enabled := False;
  FMenus.RecentlyBookmarkedMenu.Add('(Empty)').Enabled := False;
  FMenus.RecentTagsMenu.Add('(Empty)').Enabled := False;
  FToolbars := TBrowserToolbars.Create(Root, BrowserApp.Bookmarks);
  FToolbars.Toolbox.DockOrder := 1;
  FToolbars.OnCommand := @RunCommand;
  FToolbars.OnItemMade := @ItemMade;
  FToolbars.OnBackMenu := @BackMenuOpening;
  FToolbars.OnForwardMenu := @ForwardMenuOpening;
  FToolbars.OnChanged := @ToolbarsChanged;
  FToolbars.OnCustomizeDone := @CustomizeDone;
  FToolbars.Load(BrowserApp.Settings);
  FTabStrip := TTabStrip.Create(Root);
  FTabStrip.Align := AlignTop;
  FTabStrip.DockOrder := 3;
  FTabStrip.AutoSize := True;
  FTabStrip.OnSelect := @TabSelected;
  FTabStrip.OnClose := @TabClosed;
  FTabStrip.OnNewTab := @NewTabClicked;
  FTabStrip.OnMove := @TabMoved;
  FTabStrip.OnTearOff := @TabTornOff;
  FTabStrip.OnTabMenu := @TabMenuRequested;
  FStatusBar := TBrowserStatusBar.Create(Root);
  FStatusBar.DockOrder := 0;
  FStatusBar.OnLockClick := @LockClicked;
  FStatusBar.OnDownloadsClick := @DownloadsClicked;
  FFindBar := TFindBar.Create(Root);
  FFindBar.Align := AlignBottom;
  FFindBar.DockOrder := 1;
  FFindBar.AutoSize := True;
  FFindBar.OnFind := @FindRequested;
  FFindBar.OnHighlight := @HighlightRequested;
  FFindBar.OnClosed := @FindClosed;
  FContent := TPanel.Create(Root);
  FContent.Align := AlignClient;
end;

{ A key running Command without an item in the menus. }
procedure TBrowserWindow.AddKey(Command: LongInt; Code, Modifiers: LongWord);
var
  Item: TMenuItem;
begin
  Item := FKeyItems.Add('', @MenuCommand);
  Item.Tag := Command;
  AddItemAccelerator(Self, Item, Code, Modifiers);
end;

{ Keys without a menu item of their own. }
procedure TBrowserWindow.AddKeys;
var
  Digit: LongWord;
begin
  FKeyItems := TMenuItem.Create('');
  AddKey(CommandFocusLocation, KeyL, ModifierControl);
  AddKey(CommandFocusLocation, KeyD, ModifierAlt);
  AddKey(CommandFocusLocation, KeyF6, 0);
  AddKey(CommandNextTab, KeyTab, ModifierControl);
  AddKey(CommandNextTab, KeyPageDown, ModifierControl);
  AddKey(CommandPreviousTab, KeyTab, ModifierControl or ModifierShift);
  AddKey(CommandPreviousTab, KeyPageUp, ModifierControl);
  AddKey(CommandReload, KeyR, ModifierControl);
  AddKey(CommandReloadBypassCache, KeyR, ModifierControl or ModifierShift);
  AddKey(CommandReloadBypassCache, KeyF5, ModifierControl);
  AddKey(CommandCloseTab, KeyF4, ModifierControl);
  AddKey(CommandUndoCloseTab, KeyT, ModifierControl or ModifierShift);
  AddKey(CommandFindAgain, KeyG, ModifierControl);
  AddKey(CommandFindPrevious, KeyF3, ModifierShift);
  AddKey(CommandFindPrevious, KeyG, ModifierControl or ModifierShift);
  AddKey(CommandZoomIn, KeyNumpadPlus, ModifierControl);
  AddKey(CommandZoomIn, KeyEquals, ModifierControl or ModifierShift);
  AddKey(CommandZoomOut, KeyNumpadMinus, ModifierControl);
  AddKey(CommandWebSearch, KeyE, ModifierControl);
  for Digit := Key1 to Key9 - 1 do
    AddKey(CommandSelectTab + LongInt(Digit - Key1), Digit, ModifierControl);
  AddKey(CommandLastTab, Key9, ModifierControl);
end;

procedure TBrowserWindow.ItemMade(const ItemId: string; Control: TControl);
begin
  if Control is TLocationBar then
  begin
    TLocationBar(Control).OnNavigate := @LocationNavigate;
    TLocationBar(Control).OnSuggest := @LocationSuggest;
    TLocationBar(Control).OnDropDown := @LocationDropDown;
    TLocationBar(Control).OnRevert := @LocationRevert;
    TLocationBar(Control).OnEdited := @LocationEdited;
    TLocationBar(Control).OnIdentityClick := @IdentityClicked;
    TLocationBar(Control).OnStarClick := @StarClicked;
    TLocationBar(Control).Images := FToolbars.SmallImages;
  end
  else if Control is TSearchBar then
  begin
    TSearchBar(Control).Engines := BrowserApp.Engines;
    TSearchBar(Control).EngineName := BrowserApp.Settings.SearchEngine;
    TSearchBar(Control).OnSearch := @SearchRequested;
    TSearchBar(Control).OnChooseEngine := @EngineChosen;
    TSearchBar(Control).OnManage := @ManageEnginesRequested;
  end
  else if Control is TBookmarksToolbar then
  begin
    TBookmarksToolbar(Control).OnOpen := @BookmarkOpened;
    TBookmarksToolbar(Control).OnAdd := @BookmarkAddRequested;
    TBookmarksToolbar(Control).OnEdit := @BookmarkEditRequested;
    TBookmarksToolbar(Control).OnOpenAll := @BookmarkFolderOpened;
  end;
end;

procedure TBrowserWindow.ToolbarsChanged(Sender: TControl);
var
  Settings: TBrowserSettings;
begin
  Settings := BrowserApp.Settings;
  FToolbars.Store(Settings);
  BrowserApp.Settings := Settings;
  BrowserApp.SaveSettings;
  RefreshChrome;
  RefreshLocation;
end;

procedure TBrowserWindow.CustomizeDone(Sender: TControl);
begin
  { The palette's own button: it goes once the click is over. }
  PostMessage(Self, MessageEndCustomize);
end;

procedure TBrowserWindow.UpdateBarsVisible;
var
  Settings: TBrowserSettings;
begin
  Settings := BrowserApp.Settings;
  FMenus.Bar.Visible := Settings.MenuBar and not FFullScreen;
  FToolbars.Navigation.Visible := (Settings.NavigationToolbar or FToolbars.Customizing) and
    (FPageFullscreenView = nil);
  FToolbars.BookmarksBar.Visible := (Settings.BookmarksToolbar and not FFullScreen) or FToolbars.Customizing;
  FStatusBar.Visible := Settings.StatusBar and not FFullScreen;
  FTabStrip.Visible := (Settings.AlwaysShowTabBar or (FTabs.Count > 1)) and (FPageFullscreenView = nil);
end;

procedure TBrowserWindow.ApplySettings;
var
  Index: Integer;
begin
  UpdateBarsVisible;
  for Index := 0 to FTabs.Count - 1 do
    ApplyViewSettings(TabAt(Index).View);
  SearchEnginesChanged;
  RefreshChrome;
end;

procedure TBrowserWindow.ApplyViewSettings(View: TWebView);
begin
  View.ScriptingEnabled := BrowserApp.Settings.JavaScript;
  View.ImagesEnabled := BrowserApp.Settings.LoadImages;
  View.PopupsBlocked := BrowserApp.Settings.BlockPopups;
end;

procedure TBrowserWindow.BookmarksChanged;
begin
  if FToolbars.BookmarksItems <> nil then
    FToolbars.BookmarksItems.BookmarksChanged;
  if FSidebar <> nil then
    FSidebar.Refresh;
  RefreshChrome;
end;

procedure TBrowserWindow.SearchEnginesChanged;
begin
  if FToolbars.SearchBar <> nil then
    FToolbars.SearchBar.EngineName := BrowserApp.Settings.SearchEngine;
end;

procedure TBrowserWindow.DownloadChanged(Item: TDownloadItem);
var
  Running: Integer;
begin
  Running := BrowserApp.Downloads.RunningCount;
  if Running = 0 then
    FStatusBar.DownloadsText := ''
  else if Running = 1 then
    FStatusBar.DownloadsText := '1 download'
  else
    FStatusBar.DownloadsText := IntToStr(Running) + ' downloads';
  if ActiveTab <> nil then
    case Item.State of
      DownloadRunning:
        ShowStatus('Downloading ' + Item.FileName + ': ' + SizeText(Item.Received));
      DownloadDone:
        ShowStatus('Downloaded ' + Item.FileName + ' to ' + Item.Path);
      DownloadFailed:
        ShowStatus('Download of ' + Item.FileName + ' failed: ' + Item.ErrorText);
    end;
end;

procedure TBrowserWindow.CloseRequested;
var
  Answer: LongInt;
begin
  if FClosing then
    Exit;
  if BrowserApp.WindowCount <= 1 then
  begin
    BrowserApp.Quit;
    Exit;
  end;
  if BrowserApp.Settings.WarnClosingTabs and (FTabs.Count > 1) then
  begin
    Answer := ShowMessageBox('Confirm close', 'You are about to close ' + IntToStr(FTabs.Count) +
      ' tabs. Are you sure you want to continue?', MessageOkCancel, SignWarning, Self);
    if Answer <> ResultOk then
      Exit;
  end;
  FClosing := True;
  BrowserApp.WindowClosed(Self);
  Hide;
  PostMessage(BrowserApp, MessageCloseWindowLater, PtrInt(Self));
end;

procedure TBrowserWindow.CloseQuietly;
begin
  FClosing := True;
  Hide;
  PostMessage(BrowserApp, MessageCloseWindowLater, PtrInt(Self));
end;

procedure TBrowserWindow.ActiveChanged;
begin
  inherited ActiveChanged;
  if Active then
    BrowserApp.ActiveWindow := Self;
end;

procedure TBrowserWindow.ShowStatus(const Text: string);
begin
  FStatusBar.Status := Text;
end;

function TBrowserWindow.TabIsLoading(Tab: TBrowserTab): Boolean;
begin
  Result := (Tab <> nil) and (Tab.View.LoadingState in [LoadingRequesting, LoadingReceiving, LoadingInteractive]);
end;

{ The location bar shows the chosen tab's address, icon, security and
  whether it is bookmarked. }
procedure TBrowserWindow.RefreshLocation;
var
  Bar: TLocationBar;
  Tab: TBrowserTab;
  Host: string;
begin
  Bar := FToolbars.LocationBar;
  Tab := ActiveTab;
  if (Bar = nil) or (Tab = nil) then
    Exit;
  if Tab.Typing then
    Bar.Address := Tab.TypedAddress
  else
    Bar.Address := ShownAddress(Tab.View.Url);
  Bar.Favicon := Tab.Icon;
  Bar.PageUrl := Tab.View.Url;
  Bar.PageTitle := Tab.Caption;
  Host := '';
  if Pos('https://', LowerCase(Tab.View.Url)) = 1 then
    Host := HostOfUrl(Tab.View.Url);
  Bar.SecureHost := Host;
  Bar.Bookmarked := BrowserApp.Bookmarks.IsBookmarked(Tab.View.Url);
end;

{ The window's title, the buttons and the status bar follow the chosen tab. }
procedure TBrowserWindow.RefreshChrome;
var
  View: TWebView;
  Loading: Boolean;
  Button: TToolButton;
  Caption: string;
begin
  View := ActiveView;
  if View = nil then
    Exit;
  Caption := ActiveTab.Caption + ' - ' + ProgramName;
  if BrowserApp.PrivateBrowsing then
    Caption := Caption + ' (Private Browsing)';
  Title := Caption;
  Loading := TabIsLoading(ActiveTab);
  Button := FToolbars.Button('back');
  if Button <> nil then
    Button.Enabled := View.CanGoBack;
  Button := FToolbars.Button('forward');
  if Button <> nil then
    Button.Enabled := View.CanGoForward;
  Button := FToolbars.Button('stop');
  if Button <> nil then
    Button.Enabled := Loading;
  if Loading then
    FStatusBar.Progress := 50
  else
    FStatusBar.Progress := -1;
  if Abs(View.Zoom - 1) < 0.001 then
    FStatusBar.ZoomText := ''
  else
    FStatusBar.ZoomText := ZoomText(View.Zoom);
  FStatusBar.Secure := Pos('https://', LowerCase(View.Url)) = 1;
  FStatusBar.Offline := WorkOffline;
  if View.StatusText <> '' then
    ShowStatus(View.StatusText)
  else if Loading then
    ShowStatus('Loading ' + View.Url + '...')
  else
    ShowStatus('Done');
  RefreshLocation;
end;

{ ---- the location bar and the search bar ---- }

procedure TBrowserWindow.LocationNavigate(Sender: TLocationBar; const Text: string; InNewTab: Boolean);
var
  Tab: TBrowserTab;
begin
  if Trim(Text) = '' then
    Exit;
  if InNewTab then
  begin
    OpenTab(Text, True);
    Exit;
  end;
  GoToAddress(Text);
  Tab := ActiveTab;
  if Tab <> nil then
    FocusControl(Tab.View);
end;

procedure TBrowserWindow.LocationSuggest(Sender: TLocationBar; const Typed: string; out Rows: TSuggestionRows;
  out Urls: TStringArray);
const
  Behaviours: array[TLocationSuggest] of TSuggestBehaviour = (SuggestHistoryAndBookmarks, SuggestHistory,
    SuggestBookmarks, SuggestNothing);
var
  Found: TSuggestions;
  Index: Integer;
begin
  Rows := nil;
  Urls := nil;
  Found := SuggestPlaces(Typed, BrowserApp.History, BrowserApp.Bookmarks, BrowserApp.NowUnix,
    Behaviours[BrowserApp.Settings.LocationSuggest]);
  SetLength(Rows, Length(Found));
  SetLength(Urls, Length(Found));
  for Index := 0 to High(Found) do
  begin
    Rows[Index].Title := Found[Index].Title;
    if Rows[Index].Title = '' then
      Rows[Index].Title := Found[Index].Url;
    Rows[Index].Detail := Found[Index].Url;
    Rows[Index].ImageIndex := -1;
    Rows[Index].Marked := Found[Index].Bookmarked;
    Rows[Index].Note := string.Join(', ', Found[Index].Tags);
    Urls[Index] := Found[Index].Url;
  end;
  Say('suggest ' + Typed + ' ' + IntToStr(Length(Found)));
end;

procedure TBrowserWindow.LocationDropDown(Sender: TLocationBar; const Typed: string; out Rows: TSuggestionRows;
  out Urls: TStringArray);
var
  Places: THistoryPlaceList;
  Index: Integer;
begin
  Places := BrowserApp.History.RecentPlaces(12);
  Rows := nil;
  Urls := nil;
  SetLength(Rows, Length(Places));
  SetLength(Urls, Length(Places));
  for Index := 0 to High(Places) do
  begin
    Rows[Index].Title := Places[Index].Title;
    if Rows[Index].Title = '' then
      Rows[Index].Title := Places[Index].Url;
    Rows[Index].Detail := Places[Index].Url;
    Rows[Index].ImageIndex := -1;
    Rows[Index].Marked := BrowserApp.Bookmarks.IsBookmarked(Places[Index].Url);
    Urls[Index] := Places[Index].Url;
  end;
end;

procedure TBrowserWindow.LocationRevert(Sender: TControl);
begin
  if ActiveTab = nil then
    Exit;
  ActiveTab.Typing := False;
  RefreshLocation;
  if FToolbars.LocationBar <> nil then
    FToolbars.LocationBar.Edit.SelectAll;
end;

procedure TBrowserWindow.LocationEdited(Sender: TControl);
begin
  if (ActiveTab <> nil) and (FToolbars.LocationBar <> nil) and FToolbars.LocationBar.Edit.Focused then
  begin
    ActiveTab.Typing := True;
    ActiveTab.TypedAddress := FToolbars.LocationBar.Address;
  end;
end;

procedure TBrowserWindow.IdentityClicked(Sender: TControl);
begin
  if ActiveView <> nil then
    ShowIdentityPopup(Self, FToolbars.LocationBar.Identity, ActiveView);
end;

procedure TBrowserWindow.StarClicked(Sender: TControl);
begin
  BookmarkThisPage;
end;

procedure TBrowserWindow.SearchRequested(Sender: TSearchBar; const Words: string; InNewTab: Boolean);
begin
  WebSearch(Words, InNewTab);
end;

procedure TBrowserWindow.WebSearch(const Words: string; InNewTab: Boolean);
var
  Url: string;
begin
  if BrowserApp.Settings.SearchUrl = '' then
  begin
    if FToolbars.SearchBar <> nil then
      FToolbars.SearchBar.OpenEngineMenu;
    Exit;
  end;
  Url := BuildSearchUrl(BrowserApp.Settings.SearchUrl, Words);
  Say('search ' + Words);
  if InNewTab then
    OpenTab(Url, True)
  else
    GoToAddress(Url);
end;

procedure TBrowserWindow.EngineChosen(Sender: TSearchBar; const Name: string);
begin
  BrowserApp.ChooseSearchEngine(Name);
end;

procedure TBrowserWindow.ManageEnginesRequested(Sender: TControl);
begin
  ManageSearchEngines(Self);
end;

procedure TBrowserWindow.GoToAddress(const Text: string);
var
  Tab: TBrowserTab;
begin
  Tab := ActiveTab;
  if Tab = nil then
    Exit;
  GoToAddressIn(Tab, Text);
end;

procedure TBrowserWindow.GoToAddressIn(Tab: TBrowserTab; const Text: string);
var
  Url: string;
begin
  Tab.Typing := False;
  if RunDebugAddress(Tab, Text) then
    Exit;
  case ResolveLocation(Text, BrowserApp.Settings.SearchUrl, BrowserApp.Bookmarks, BrowserApp.Engines, Url) of
    AddressUrl, AddressSearch:
      begin
        Say('go ' + Url);
        if not Tab.View.Navigate(Url) then
          Tab.View.LoadHtml(InvalidAddressPage(Text), 'about:blank');
      end;
  else
    Say('not-an-address ' + Text);
    Tab.View.LoadHtml(InvalidAddressPage(Text), 'about:blank');
  end;
end;

{ ---- bookmarks toolbar and sidebar ---- }

procedure TBrowserWindow.BookmarkOpened(const Url: string; Disposition: TLinkDisposition);
begin
  OpenUrl(Url, Disposition);
end;

procedure TBrowserWindow.BookmarkAddRequested(Kind: TBookmarkKind; Folder: TBookmarkNode; Index: Integer);
begin
  NewBookmarkNode(Self, Kind, Folder, Index, '', '');
end;

procedure TBrowserWindow.BookmarkEditRequested(Node: TBookmarkNode);
begin
  EditBookmarkProperties(Self, Node);
end;

procedure TBrowserWindow.BookmarkFolderOpened(Folder: TBookmarkNode);
var
  Index: Integer;
  First: Boolean;
begin
  First := True;
  for Index := 0 to Folder.Count - 1 do
    if Folder[Index].Kind = BookmarkItem then
    begin
      OpenTab(Folder[Index].Url, First);
      First := False;
    end;
end;

procedure TBrowserWindow.ShowSidebar(Kind: TSidebarKind);
begin
  if (FSidebar <> nil) and (FSidebar.Kind = Kind) and FSidebar.Visible then
  begin
    SidebarClosed(FSidebar);
    Exit;
  end;
  if FSidebar = nil then
  begin
    FSidebar := TBrowserSidebar.Create(Root);
    FSidebar.Align := AlignLeft;
    FSidebar.DockOrder := 5;
    FSidebar.SetBounds(0, 0, 220, 300);
    FSidebar.OnOpen := @BookmarkOpened;
    FSidebar.OnClose := @SidebarClosed;
    FSidebarSplitter := TSplitter.Create(Root);
    FSidebarSplitter.Align := AlignLeft;
    FSidebarSplitter.DockOrder := 5;
  end;
  FSidebar.Kind := Kind;
  FSidebar.Visible := True;
  FSidebarSplitter.Visible := True;
  FSidebar.FocusSearch;
end;

procedure TBrowserWindow.SidebarClosed(Sender: TControl);
begin
  if FSidebar = nil then
    Exit;
  FSidebar.Visible := False;
  FSidebarSplitter.Visible := False;
  if ActiveView <> nil then
    FocusControl(ActiveView);
end;

{ ---- find ---- }

{ The answer comes to ViewFindDetails (from the page's process). }
procedure TBrowserWindow.FindRequested(const Text: string; Forward, MatchCase, FromStart: Boolean);
begin
  if ActiveView = nil then
    Exit;
  FLastFindText := Text;
  if Text = '' then
  begin
    ActiveView.ClearSelection;
    FFindBar.ShowResult(True, False);
    Exit;
  end;
  ActiveView.FindText(Text, Forward, MatchCase);
end;

procedure TBrowserWindow.HighlightRequested(const Text: string; MatchCase, TurnedOn: Boolean);
begin
  if ActiveView = nil then
    Exit;
  if TurnedOn then
    SetViewFindHighlight(ActiveView, Text, MatchCase)
  else
    SetViewFindHighlight(ActiveView, '', MatchCase);
  if TurnedOn then
    Say('highlight ' + Text)
  else
    Say('highlight off');
end;

procedure TBrowserWindow.FindClosed(Sender: TControl);
begin
  if ActiveView <> nil then
    FocusControl(ActiveView);
end;

procedure TBrowserWindow.LockClicked(Sender: TControl);
begin
  if ActiveView <> nil then
    ShowPageInfo(ActiveView, Self, PageInfoSecurity);
end;

procedure TBrowserWindow.DownloadsClicked(Sender: TControl);
begin
  BrowserApp.ShowDownloadsWindow(True);
end;

procedure TBrowserWindow.ReceiveMessage(var Message: TPostedMessage);
var
  Settings: TBrowserSettings;
begin
  if Message.Code = MessageEndCustomize then
  begin
    FToolbars.EndCustomize;
    Settings := BrowserApp.Settings;
    FToolbars.Store(Settings);
    BrowserApp.Settings := Settings;
    BrowserApp.SaveSettings;
    UpdateBarsVisible;
    RefreshChrome;
    Say('customize done ' + Settings.NavigationItems);
    Exit;
  end;
  if Message.Code = MessageCloseTabLater then
  begin
    CloseTab(Message.Parameter1);
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TBrowserWindow.ReportLayout;
begin
  Say('layout menu ' + IntToStr(FMenus.Bar.PixelBounds.Top) + ' toolbars ' +
    IntToStr(FToolbars.Toolbox.PixelBounds.Top) + ' tabs ' + IntToStr(FTabStrip.PixelBounds.Top) + ' content ' +
    IntToStr(FContent.PixelBounds.Top) + ' status ' + IntToStr(FStatusBar.PixelBounds.Top));
end;

function TBrowserWindow.AboutPage(const Path: string; out Html: string): Boolean;
begin
  Result := BrowserApp.AboutPages.Provide(Path, Html);
end;

{$I Browser.MainWindow.Tabs.inc}
{$I Browser.MainWindow.Commands.inc}
{$I Browser.MainWindow.Views.inc}

end.
