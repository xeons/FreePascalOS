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
  The browser's window, top to bottom: the menu bar, the tab strip,
  the navigation bar (back, forward, reload or stop, home; the address
  bar; the bookmark button), the bookmarks bar, the pages (a web view
  per tab, the chosen one shown), the find bar and the status bar (the
  hovered link, the zoom). Its parts:

  - Browser.MainWindow.Menus.inc: the menus, their keys and commands;
  - Browser.MainWindow.Views.inc: what the web views tell (title,
    address, loading, icon, links for new tabs, downloads, prompts,
    console, context menus).
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
  Controls.EditBox,
  Controls.ToolBar,
  Controls.ImageList,
  Controls.StatusBar,
  Controls.Menus,
  Web.Navigation.Navigables,
  WebView.Control,
  Browser.Settings,
  Browser.Stores,
  Browser.Downloads,
  Browser.AboutPages,
  Browser.Tabs,
  Browser.TabStrip,
  Browser.FindBar,
  Browser.BookmarksBar;

const
  MessageDownloadChanged = MessageUser + 1;

type
  TBrowserWindow = class(TControlWindow)
  private
    FSettings: TBrowserSettings;
    FHistory: THistoryStore;
    FBookmarks: TBookmarkStore;
    FDownloads: TDownloadManager;
    FAboutPages: TAboutPages;
    FTabs: TList;
    FActive: Integer;
    FMenuBar: TMenuBar;
    FTabStrip: TTabStrip;
    FNavigationBar: TPanel;
    FToolImages: TImageList;
    FToolBar: TToolBar;
    FBackButton: TToolButton;
    FForwardButton: TToolButton;
    FReloadButton: TToolButton;
    FHomeButton: TToolButton;
    FAddress: TEditBox;
    FBookmarkBar: TToolBar;
    FBookmarkButton: TToolButton;
    FBookmarksBar: TBookmarksBar;
    FContent: TPanel;
    FFindBar: TFindBar;
    FStatusBar: TStatusBar;
    FContextMenu: TMenuItem;
    FContextLink: string;
    FBookmarksMenu: TMenuItem;
    FBookmarksBarItem: TMenuItem;
    FReloadImage, FStopImage: LongInt;
    { Building. }
    procedure BuildMenus;
    procedure BuildNavigationBar;
    procedure PlaceStatusPanels;
    { Tabs. }
    function TabCount: Integer;
    function TabAt(Index: Integer): TBrowserTab;
    function ActiveTab: TBrowserTab;
    function ActiveView: TWebView;
    function TabOfView(View: TWebView): Integer;
    procedure ActivateTab(Index: Integer);
    procedure CloseTab(Index: Integer);
    procedure TabSelected(Sender: TObject; Index: Integer);
    procedure TabClosed(Sender: TObject; Index: Integer);
    procedure NewTabClicked(Sender: TControl);
    procedure RefreshTab(Index: Integer);
    procedure RefreshChrome;
    procedure ShowStatus(const Text: string);
    { The address bar. }
    procedure AddressKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure AddressChanged(Sender: TControl);
    procedure GoToAddress(const Text: string);
    procedure GoToAddressIn(Tab: TBrowserTab; const Text: string);
    { Toolbar. }
    procedure BackClicked(Sender: TControl);
    procedure ForwardClicked(Sender: TControl);
    procedure ReloadClicked(Sender: TControl);
    procedure HomeClicked(Sender: TControl);
    procedure BookmarkClicked(Sender: TControl);
    procedure BookmarkOpened(const Url: string; NewTab: Boolean);
    procedure BookmarksChanged(Sender: TControl);
    procedure FindRequested(const Text: string; Forward, MatchCase, FromStart: Boolean);
    procedure FindClosed(Sender: TControl);
    { Menus and keys (Browser.MainWindow.Menus.inc). }
    procedure AddKey(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
      Code, Modifiers: LongWord);
    procedure NewTabChosen(Item: TMenuItem);
    procedure CloseTabChosen(Item: TMenuItem);
    procedure OpenFileChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure SelectAllChosen(Item: TMenuItem);
    procedure FindChosen(Item: TMenuItem);
    procedure FindNextChosen(Item: TMenuItem);
    procedure ReloadChosen(Item: TMenuItem);
    procedure StopChosen(Item: TMenuItem);
    procedure ZoomInChosen(Item: TMenuItem);
    procedure ZoomOutChosen(Item: TMenuItem);
    procedure ActualSizeChosen(Item: TMenuItem);
    procedure BookmarksBarChosen(Item: TMenuItem);
    procedure BackChosen(Item: TMenuItem);
    procedure ForwardChosen(Item: TMenuItem);
    procedure HomeChosen(Item: TMenuItem);
    procedure HistoryChosen(Item: TMenuItem);
    procedure BookmarkPageChosen(Item: TMenuItem);
    procedure ShowBookmarksChosen(Item: TMenuItem);
    procedure BookmarksMenuOpening(Item: TMenuItem);
    procedure BookmarkItemChosen(Item: TMenuItem);
    procedure DownloadsChosen(Item: TMenuItem);
    procedure SettingsChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure FocusAddress(Sender: TControlWindow);
    procedure NextTab(Sender: TControlWindow);
    procedure PreviousTab(Sender: TControlWindow);
    procedure ReloadKey(Sender: TControlWindow);
    procedure BookmarkKey(Sender: TControlWindow);
    procedure ZoomInKey(Sender: TControlWindow);
    procedure ApplySettings;
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
    procedure ViewAlert(Sender: TWebView; const Text: string);
    function ViewConfirm(Sender: TWebView; const Message: string): Boolean;
    function ViewPrompt(Sender: TWebView; const Message, Default: string; out Answer: string): Boolean;
    procedure ViewConsole(Sender: TWebView; const Level, Text: string);
    function AboutPage(const Path: string; out Html: string): Boolean;
  protected
    procedure Resized; override;
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Opens Url (as typed: Browser.Addresses) in a new tab after the
      chosen one; Bringing shows it. }
    function OpenTab(const Url: string; Bringing: Boolean): TBrowserTab;
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
  Controls.Keys,
  Controls.Clipboard,
  Controls.IconTheme,
  Controls.LayoutRules,
  Controls.MessageBoxes,
  Controls.FileDialog,
  Web.Navigation.Pages,
  WebView.Network,
  WebView.Zoom,
  Browser.Addresses,
  Browser.SettingsDialog,
  Browser.PromptDialog,
  Browser.Output;

const
  ProgramName = 'Browser';
  ToolIconSize = 16;
  StatusZoomWidth = 170;
  KeyT = $14;
  KeyW = $11;
  KeyO = $18;
  KeyD = $20;
  KeyH = $23;
  KeyJ = $24;
  KeyL = $26;
  KeyR = $13;
  KeyEquals = $0D;
  KeyMinus = $0C;
  KeyZero = $0B;
  KeyNumpadPlus = $4E;
  KeyNumpadMinus = $4A;
  KeyF = $21;

constructor TBrowserWindow.Create;
var
  Folder: string;
begin
  inherited Create(ProgramName, 60, 40, 1000, 680);
  IconName := 'app-web-browser';
  FSettings := LoadBrowserSettings;
  SetHttp3Allowed(FSettings.Http3);
  Folder := BrowserProfileFolder;
  FHistory := THistoryStore.Create(Folder + '/history.txt');
  FHistory.Load;
  FBookmarks := TBookmarkStore.Create(Folder + '/bookmarks.txt');
  FBookmarks.Load;
  FDownloads := TDownloadManager.Create(Self, MessageDownloadChanged);
  FAboutPages := TAboutPages.Create(FHistory, FBookmarks, FDownloads);
  FTabs := TList.Create;
  FActive := -1;
  BuildMenus;
  FTabStrip := TTabStrip.Create(Root);
  FTabStrip.Align := AlignTop;
  FTabStrip.AutoSize := True;
  FTabStrip.OnSelect := @TabSelected;
  FTabStrip.OnClose := @TabClosed;
  FTabStrip.OnNewTab := @NewTabClicked;
  BuildNavigationBar;
  FBookmarksBar := TBookmarksBar.Create(Root, FBookmarks);
  FBookmarksBar.Align := AlignTop;
  FBookmarksBar.AutoSize := True;
  FBookmarksBar.OnOpen := @BookmarkOpened;
  FBookmarksBar.OnChanged := @BookmarksChanged;
  FBookmarksBar.Visible := FSettings.BookmarksBar;
  FBookmarksBarItem.Checked := FSettings.BookmarksBar;
  FStatusBar := TStatusBar.Create(Root);
  FFindBar := TFindBar.Create(Root);
  FFindBar.Align := AlignBottom;
  FFindBar.AutoSize := True;
  FFindBar.OnFind := @FindRequested;
  FFindBar.OnClosed := @FindClosed;
  FContent := TPanel.Create(Root);
  FContent.Align := AlignClient;
  PlaceStatusPanels;
end;

destructor TBrowserWindow.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FTabs.Count - 1 do
    TBrowserTab(FTabs[Index]).Free;
  FTabs.Free;
  FContextMenu.Free;
  FDownloads.Free;
  FAboutPages.Free;
  FHistory.Free;
  FBookmarks.Free;
  FToolImages.Free;
  inherited Destroy;
end;

procedure TBrowserWindow.BuildNavigationBar;
begin
  FNavigationBar := TPanel.Create(Root);
  FNavigationBar.Align := AlignTop;
  FNavigationBar.SetBounds(0, 0, 400, 36);
  FToolImages := TImageList.Create(ToolIconSize, ToolIconSize);
  FToolBar := TToolBar.Create(FNavigationBar);
  FToolBar.Images := FToolImages;
  FToolBar.Align := AlignLeft;
  FToolBar.AutoSize := True;
  FToolBar.Margins := MakeSpacing(2, 2, 2, 2);
  FBackButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'action-back'), '', 'Back (Alt+Left)', 32,
    @BackClicked);
  FForwardButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'action-forward'), '', 'Forward (Alt+Right)', 32,
    @ForwardClicked);
  FReloadImage := AddThemeIcon(FToolImages, 'action-refresh');
  FStopImage := AddThemeIcon(FToolImages, 'action-stop');
  FReloadButton := FToolBar.AddImageButton(FReloadImage, '', 'Reload (F5)', 32, @ReloadClicked);
  FHomeButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'home'), '', 'Home page (Alt+Home)', 32,
    @HomeClicked);
  FBookmarkBar := TToolBar.Create(FNavigationBar);
  FBookmarkBar.Images := FToolImages;
  FBookmarkBar.Align := AlignRight;
  FBookmarkBar.AutoSize := True;
  FBookmarkBar.Margins := MakeSpacing(2, 2, 2, 2);
  FBookmarkButton := FBookmarkBar.AddImageButton(AddThemeIcon(FToolImages, 'favourites'), '',
    'Bookmark this page (Ctrl+D)', 32, @BookmarkClicked);
  FAddress := TEditBox.Create(FNavigationBar);
  FAddress.Align := AlignClient;
  FAddress.Margins := MakeSpacing(4, 6, 4, 6);
  FAddress.Hint := 'Type an address (Ctrl+L)';
  FAddress.OnKeyDown := @AddressKey;
  FAddress.OnChange := @AddressChanged;
end;

procedure TBrowserWindow.PlaceStatusPanels;
begin
  if FStatusBar <> nil then
    FStatusBar.SetPanels([Max(1, ClientWidth - StatusZoomWidth), StatusZoomWidth]);
end;

procedure TBrowserWindow.Resized;
begin
  inherited Resized;
  PlaceStatusPanels;
end;

procedure TBrowserWindow.CloseRequested;
begin
  Say('exit');
  QuitMessageLoop(0);
end;

procedure TBrowserWindow.ShowStatus(const Text: string);
begin
  FStatusBar.PanelText[0] := ' ' + Text;
end;

{ ---- tabs ---- }

function TBrowserWindow.TabCount: Integer;
begin
  Result := FTabs.Count;
end;

function TBrowserWindow.TabAt(Index: Integer): TBrowserTab;
begin
  Result := TBrowserTab(FTabs[Index]);
end;

function TBrowserWindow.ActiveTab: TBrowserTab;
begin
  if (FActive < 0) or (FActive >= FTabs.Count) then
    Result := nil
  else
    Result := TabAt(FActive);
end;

function TBrowserWindow.ActiveView: TWebView;
begin
  if ActiveTab = nil then
    Result := nil
  else
    Result := ActiveTab.View;
end;

function TBrowserWindow.TabOfView(View: TWebView): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FTabs.Count - 1 do
    if TabAt(Index).View = View then
      Exit(Index);
  Result := -1;
end;

function TBrowserWindow.OpenTab(const Url: string; Bringing: Boolean): TBrowserTab;
var
  Index: Integer;
begin
  Result := TBrowserTab.Create;
  Result.View := TWebView.Create(FContent);
  Result.View.Align := AlignClient;
  Result.View.Visible := False;
  Result.View.ScriptingEnabled := FSettings.JavaScript;
  HookView(Result.View);
  if FActive < 0 then
    Index := FTabs.Count
  else
    Index := FActive + 1;
  FTabs.Insert(Index, Result);
  FTabStrip.Insert(Index, 'New Tab');
  if (FActive >= Index) then
    Inc(FActive);
  Result.View.Navigable.Fetcher.AboutPageProvider := @AboutPage;
  Say('tabs ' + IntToStr(FTabs.Count));
  if Bringing or (FActive < 0) then
    ActivateTab(Index);
  RefreshTab(Index);
  GoToAddressIn(Result, Url);
end;

procedure TBrowserWindow.ActivateTab(Index: Integer);
var
  Index_: Integer;
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  FActive := Index;
  for Index_ := 0 to FTabs.Count - 1 do
    TabAt(Index_).View.Visible := Index_ = Index;
  FTabStrip.ActiveIndex := Index;
  Tab := TabAt(Index);
  if Tab.Typing then
    FAddress.Text := Tab.TypedAddress
  else
    FAddress.Text := ShownAddress(Tab.View.Url);
  if (Tab.View.Url = '') or (ShownAddress(Tab.View.Url) = '') then
    FocusControl(FAddress)
  else
    FocusControl(Tab.View);
  RefreshChrome;
end;

procedure TBrowserWindow.CloseTab(Index: Integer);
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
  Tab := TabAt(Index);
  FTabs.Delete(Index);
  FTabStrip.Delete(Index);
  if FActive > Index then
    Dec(FActive)
  else if FActive = Index then
    FActive := Min(Index, FTabs.Count - 1);
  Tab.View.Free;
  Tab.Free;
  FActive := EnsureRange(FActive, 0, FTabs.Count - 1);
  ActivateTab(FActive);
  Say('tabs ' + IntToStr(FTabs.Count));
end;

procedure TBrowserWindow.TabSelected(Sender: TObject; Index: Integer);
begin
  ActivateTab(Index);
end;

procedure TBrowserWindow.TabClosed(Sender: TObject; Index: Integer);
begin
  CloseTab(Index);
end;

procedure TBrowserWindow.NewTabClicked(Sender: TControl);
begin
  OpenTab(FSettings.HomePage, True);
end;

procedure TBrowserWindow.RefreshTab(Index: Integer);
var
  Tab: TBrowserTab;
  Item: TTabStripItem;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  Tab := TabAt(Index);
  Item := FTabStrip.Items[Index];
  Item.Title := Tab.Caption;
  Item.Icon := Tab.Icon;
  Item.Loading := Tab.View.LoadingState in [LoadingRequesting, LoadingReceiving, LoadingInteractive];
  FTabStrip.ItemChanged(Index);
end;

{ The window's title, the buttons and the status bar follow the chosen tab. }
procedure TBrowserWindow.RefreshChrome;
var
  View: TWebView;
  Loading: Boolean;
begin
  View := ActiveView;
  if View = nil then
    Exit;
  Title := ActiveTab.Caption + ' - ' + ProgramName;
  FBackButton.Enabled := View.CanGoBack;
  FForwardButton.Enabled := View.CanGoForward;
  Loading := View.LoadingState in [LoadingRequesting, LoadingReceiving, LoadingInteractive];
  if Loading then
  begin
    FReloadButton.ImageIndex := FStopImage;
    FReloadButton.Hint := 'Stop';
  end
  else
  begin
    FReloadButton.ImageIndex := FReloadImage;
    FReloadButton.Hint := 'Reload (F5)';
  end;
  FBookmarkButton.Down := (View.Url <> '') and (FBookmarks.IndexOf(View.Url) >= 0);
  if Loading then
    FStatusBar.PanelText[1] := ' Loading...  ' + ZoomText(View.Zoom)
  else
    FStatusBar.PanelText[1] := ' ' + ZoomText(View.Zoom);
  ShowStatus(View.StatusText);
end;

{ ---- the address bar ---- }

procedure TBrowserWindow.AddressKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    if (Modifiers and ModifierAlt) <> 0 then
      OpenTab(FAddress.Text, True)
    else
      GoToAddress(FAddress.Text);
  end
  else if Code = KeyEscape then
  begin
    Handled := True;
    if ActiveTab <> nil then
    begin
      ActiveTab.Typing := False;
      FAddress.Text := ShownAddress(ActiveView.Url);
      FAddress.SelectAll;
    end;
  end;
end;

procedure TBrowserWindow.AddressChanged(Sender: TControl);
begin
  if (ActiveTab <> nil) and FAddress.Focused then
  begin
    ActiveTab.Typing := True;
    ActiveTab.TypedAddress := FAddress.Text;
  end;
end;

procedure TBrowserWindow.GoToAddress(const Text: string);
var
  Tab: TBrowserTab;
begin
  Tab := ActiveTab;
  if Tab = nil then
    Exit;
  GoToAddressIn(Tab, Text);
  FocusControl(Tab.View);
end;

procedure TBrowserWindow.GoToAddressIn(Tab: TBrowserTab; const Text: string);
var
  Url: string;
begin
  Tab.Typing := False;
  case InterpretAddress(Text, FSettings.SearchUrl, Url) of
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

{ ---- toolbar and bars ---- }

procedure TBrowserWindow.BackClicked(Sender: TControl);
begin
  if ActiveView <> nil then
    ActiveView.GoBack;
end;

procedure TBrowserWindow.ForwardClicked(Sender: TControl);
begin
  if ActiveView <> nil then
    ActiveView.GoForward;
end;

procedure TBrowserWindow.ReloadClicked(Sender: TControl);
var
  View: TWebView;
begin
  View := ActiveView;
  if View = nil then
    Exit;
  if View.LoadingState in [LoadingRequesting, LoadingReceiving, LoadingInteractive] then
    View.Stop
  else
    View.Reload;
end;

procedure TBrowserWindow.HomeClicked(Sender: TControl);
begin
  GoToAddress(FSettings.HomePage);
end;

procedure TBrowserWindow.BookmarkClicked(Sender: TControl);
begin
  BookmarkPageChosen(nil);
end;

procedure TBrowserWindow.BookmarkOpened(const Url: string; NewTab: Boolean);
begin
  if NewTab then
    OpenTab(Url, False)
  else
    GoToAddress(Url);
end;

procedure TBrowserWindow.BookmarksChanged(Sender: TControl);
begin
  RefreshChrome;
end;

procedure TBrowserWindow.FindRequested(const Text: string; Forward, MatchCase, FromStart: Boolean);
var
  Found: Boolean;
begin
  if ActiveView = nil then
    Exit;
  Found := ActiveView.FindText(Text, Forward, MatchCase);
  FFindBar.ShowResult(Found);
  if Found then
    Say('found ' + Text)
  else
    Say('not-found ' + Text);
end;

procedure TBrowserWindow.FindClosed(Sender: TControl);
begin
  if ActiveView <> nil then
    FocusControl(ActiveView);
end;

procedure TBrowserWindow.ReceiveMessage(var Message: TPostedMessage);
var
  Item: TDownloadItem;
const
  StateNames: array[TDownloadState] of string = ('running', 'done', 'failed', 'cancelled');
begin
  if Message.Code = MessageDownloadChanged then
  begin
    Item := TDownloadItem(Message.Parameter1);
    case Item.State of
      DownloadRunning:
        ShowStatus('Downloading ' + Item.FileName + ': ' + IntToStr(Item.Received div 1024) + ' KiB');
      DownloadDone:
        ShowStatus('Downloaded ' + Item.FileName + ' to ' + Item.Path);
      DownloadFailed:
        ShowStatus('Download of ' + Item.FileName + ' failed: ' + Item.ErrorText);
      DownloadCancelled:
        ShowStatus('Download of ' + Item.FileName + ' cancelled');
    end;
    if Item.State <> DownloadRunning then
    begin
      Say('download ' + Item.FileName + ' ' + StateNames[Item.State]);
      FDownloads.Reap;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

function TBrowserWindow.AboutPage(const Path: string; out Html: string): Boolean;
begin
  Result := FAboutPages.Provide(Path, Html);
end;

{$I Browser.MainWindow.Menus.inc}
{$I Browser.MainWindow.Views.inc}

end.
