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

{ Browser.MainWindow: the commands and the menus filled as they open. }

const
  MaximumHistoryMenuEntries = 15;
  MaximumBackMenuEntries = 15;

procedure TBrowserWindow.MenuCommand(Item: TMenuItem);
begin
  RunCommand(Item.Tag);
end;

{ The edit box with the focus, if one has it. }
function FocusedEditBox(Window: TControlWindow): TEditBox;
begin
  if Window.FocusedControl is TEditBox then
    Result := TEditBox(Window.FocusedControl)
  else
    Result := nil;
end;

function TBrowserWindow.CommandEnabled(Command: LongInt): Boolean;
var
  View: TWebView;
  Edit: TEditBox;
begin
  View := ActiveView;
  Edit := FocusedEditBox(Self);
  case Command of
    CommandBack: Result := (View <> nil) and View.CanGoBack;
    CommandForward: Result := (View <> nil) and View.CanGoForward;
    CommandStop: Result := TabIsLoading(ActiveTab);
    CommandUndo, CommandRedo: Result := False;
    CommandCut, CommandDelete: Result := (Edit <> nil) and (Edit.SelectedText <> '');
    CommandCopy: Result := ((Edit <> nil) and (Edit.SelectedText <> '')) or ((Edit = nil) and (View <> nil) and
      View.HasSelection);
    CommandPaste: Result := Edit <> nil;
    CommandUndoCloseTab: Result := Length(BrowserApp.Session.ClosedTabs) > 0;
    CommandUndoCloseWindow: Result := Length(BrowserApp.Session.ClosedWindows) > 0;
    CommandPageSetup, CommandPrintPreview, CommandPrint: Result := True;
    CommandBookmarkAllTabs: Result := FTabs.Count > 1;
  else
    Result := True;
  end;
end;

function TBrowserWindow.CommandChecked(Command: LongInt): Boolean;
var
  View: TWebView;
begin
  View := ActiveView;
  case Command of
    CommandToggleMenuBar: Result := BrowserApp.Settings.MenuBar;
    CommandToggleNavigationToolbar: Result := BrowserApp.Settings.NavigationToolbar;
    CommandToggleBookmarksToolbar: Result := BrowserApp.Settings.BookmarksToolbar;
    CommandToggleStatusBar: Result := BrowserApp.Settings.StatusBar;
    CommandSidebarBookmarks: Result := (FSidebar <> nil) and FSidebar.Visible and (FSidebar.Kind = SidebarBookmarks);
    CommandSidebarHistory: Result := (FSidebar <> nil) and FSidebar.Visible and (FSidebar.Kind = SidebarHistory);
    CommandZoomTextOnly: Result := (View <> nil) and View.TextOnlyZoom;
    CommandPageStyleNone: Result := (View <> nil) and not View.AuthorStylesEnabled;
    CommandPageStyleBasic: Result := (View = nil) or View.AuthorStylesEnabled;
    CommandEncodingAuto: Result := (View = nil) or (View.EncodingOverride = '');
    CommandWorkOffline: Result := WorkOffline;
    CommandFullScreen: Result := FFullScreen;
  else
    Result := False;
  end;
end;

{ Every command item of Menu (and its submenus' heads) enabled and
  checked as the window is now. }
procedure TBrowserWindow.UpdateMenu(Menu: TMenuItem);
var
  Index: LongInt;
  Item: TMenuItem;
begin
  for Index := 0 to Menu.Count - 1 do
  begin
    Item := Menu[Index];
    if Item.IsSeparator or (Item.Count > 0) or (Item.Tag <= 0) then
      Continue;
    Item.Enabled := CommandEnabled(Item.Tag);
    Item.Checked := CommandChecked(Item.Tag);
  end;
  if Menu = FMenus.ToolsMenu then
  begin
    Item := FindCommandItem(Menu, CommandPrivateBrowsing);
    if Item <> nil then
      if BrowserApp.PrivateBrowsing then
        Item.Text := 'Stop &Private Browsing'
      else
        Item.Text := 'Start &Private Browsing';
  end;
end;

procedure TBrowserWindow.MenuOpening(Item: TMenuItem);
begin
  UpdateMenu(Item);
end;

{ History: its commands, then the pages visited last. }
procedure TBrowserWindow.HistoryMenuOpening(Item: TMenuItem);
var
  Places: THistoryPlaceList;
  Index: Integer;
  Entry: TMenuItem;
  Caption: string;
begin
  UpdateMenu(Item);
  Item.DeleteFrom(FMenus.HistoryFixedCount);
  FMenus.ClosedTabsMenu.Enabled := Length(BrowserApp.Session.ClosedTabs) > 0;
  FMenus.ClosedWindowsMenu.Enabled := Length(BrowserApp.Session.ClosedWindows) > 0;
  Places := BrowserApp.History.RecentPlaces(MaximumHistoryMenuEntries);
  for Index := 0 to High(Places) do
  begin
    Caption := Places[Index].Title;
    if Caption = '' then
      Caption := Places[Index].Url;
    Entry := Item.Add(MenuCaption(Caption), @HistoryItemChosen);
    Entry.Tag := Index;
  end;
  if Length(Places) = 0 then
    Item.Add('(No history)').Enabled := False;
end;

procedure TBrowserWindow.HistoryItemChosen(Item: TMenuItem);
var
  Places: THistoryPlaceList;
begin
  Places := BrowserApp.History.RecentPlaces(MaximumHistoryMenuEntries);
  if (Item.Tag >= 0) and (Item.Tag <= High(Places)) then
    GoToAddress(Places[Item.Tag].Url);
end;

procedure TBrowserWindow.ClosedTabsOpening(Item: TMenuItem);
var
  Index: Integer;
  Entry: TSessionEntry;
begin
  Item.Clear;
  for Index := 0 to High(BrowserApp.Session.ClosedTabs) do
  begin
    Entry := CurrentEntry(BrowserApp.Session.ClosedTabs[Index].Tab);
    if Entry.Title = '' then
      Entry.Title := Entry.Url;
    Item.Add(MenuCaption(Entry.Title), @ClosedTabChosen).Tag := Index;
  end;
  if Item.Count = 0 then
    Item.Add('(Empty)').Enabled := False
  else
  begin
    Item.AddSeparator;
    Item.Add('Restore All Tabs', @ClosedTabChosen).Tag := -1;
  end;
end;

procedure TBrowserWindow.ClosedTabChosen(Item: TMenuItem);
begin
  if Item.Tag >= 0 then
    UndoCloseTab(Item.Tag)
  else
    while Length(BrowserApp.Session.ClosedTabs) > 0 do
      UndoCloseTab(0);
end;

procedure TBrowserWindow.ClosedWindowsOpening(Item: TMenuItem);
var
  Index: Integer;
  Window: TSessionWindow;
  Caption: string;
begin
  Item.Clear;
  for Index := 0 to High(BrowserApp.Session.ClosedWindows) do
  begin
    Window := BrowserApp.Session.ClosedWindows[Index];
    Caption := '';
    if Length(Window.Tabs) > 0 then
      Caption := CurrentEntry(Window.Tabs[EnsureRange(Window.Selected, 0, High(Window.Tabs))]).Title;
    if Length(Window.Tabs) > 1 then
      Caption := Caption + ' (and ' + IntToStr(Length(Window.Tabs) - 1) + ' more)';
    Item.Add(MenuCaption(Caption), @ClosedWindowChosen).Tag := Index;
  end;
  if Item.Count = 0 then
    Item.Add('(Empty)').Enabled := False;
end;

procedure TBrowserWindow.ClosedWindowChosen(Item: TMenuItem);
var
  Session: TSession;
  Window: TSessionWindow;
begin
  Session := BrowserApp.Session;
  if TakeClosedWindow(Session, Item.Tag, Window) then
  begin
    BrowserApp.Session := Session;
    BrowserApp.RestoreWindow(Window);
  end;
end;

{ Bookmarks: its commands, then the Bookmarks Menu folder. }
procedure TBrowserWindow.BookmarksMenuOpening(Item: TMenuItem);
begin
  UpdateMenu(Item);
  Item.DeleteFrom(FMenus.BookmarksFixedCount);
  AddFolderItems(Item, BrowserApp.Bookmarks.MenuFolder, @BookmarkItemChosen, False);
  if Item.Count = FMenus.BookmarksFixedCount then
    Item.Add('(Empty)').Enabled := False;
end;

procedure TBrowserWindow.ToolbarFolderOpening(Item: TMenuItem);
begin
  Item.Clear;
  AddFolderItems(Item, BrowserApp.Bookmarks.ToolbarFolder, @BookmarkItemChosen);
  if Item.Count = 0 then
    Item.Add('(Empty)').Enabled := False;
end;

procedure TBrowserWindow.RecentlyBookmarkedOpening(Item: TMenuItem);
begin
  Item.Clear;
  AddBookmarkItems(Item, BrowserApp.Bookmarks.RecentlyBookmarked(10), @BookmarkItemChosen);
  if Item.Count = 0 then
    Item.Add('(Empty)').Enabled := False;
end;

procedure TBrowserWindow.RecentTagsOpening(Item: TMenuItem);
var
  Tags: TStringArray;
  Index: Integer;
  Sub: TMenuItem;
begin
  Item.Clear;
  Tags := BrowserApp.Bookmarks.RecentTags(10);
  for Index := 0 to High(Tags) do
  begin
    Sub := Item.Add(MenuCaption(Tags[Index]));
    AddBookmarkItems(Sub, BrowserApp.Bookmarks.Tagged(Tags[Index]), @BookmarkItemChosen);
  end;
  if Item.Count = 0 then
    Item.Add('(Empty)').Enabled := False;
end;

procedure TBrowserWindow.BookmarkItemChosen(Item: TMenuItem);
var
  Node: TBookmarkNode;
begin
  if Item.Tag < 0 then
  begin
    Node := BrowserApp.Bookmarks.NodeById(-Item.Tag);
    if Node <> nil then
      BookmarkFolderOpened(Node);
    Exit;
  end;
  Node := BrowserApp.Bookmarks.NodeById(Item.Tag);
  if Node <> nil then
  begin
    if (HeldModifiers and ModifierControl) <> 0 then
      OpenTab(Node.Url, False)
    else
      GoToAddress(Node.Url);
  end;
end;

procedure TBrowserWindow.TagItemChosen(Item: TMenuItem);
begin
  BookmarkItemChosen(Item);
end;

procedure TBrowserWindow.EncodingOpening(Item: TMenuItem);
var
  Names: TStringArray;
  Index: Integer;
  Entry: TMenuItem;
  View: TWebView;
begin
  View := ActiveView;
  Item.DeleteFrom(1);
  Item[0].Checked := (View = nil) or (View.EncodingOverride = '');
  Item.AddSeparator;
  Names := SupportedEncodings;
  for Index := 0 to High(Names) do
  begin
    Entry := Item.Add(MenuCaption(Names[Index]), @EncodingChosen);
    Entry.Tag := Index;
    Entry.Checked := (View <> nil) and SameText(View.EncodingOverride, Names[Index]);
  end;
end;

procedure TBrowserWindow.EncodingChosen(Item: TMenuItem);
var
  Names: TStringArray;
begin
  Names := SupportedEncodings;
  if (ActiveView <> nil) and (Item.Tag >= 0) and (Item.Tag <= High(Names)) then
  begin
    ActiveView.EncodingOverride := Names[Item.Tag];
    Say('encoding ' + Names[Item.Tag]);
  end;
end;

{ Back and Forward drop down the tab's entries on that side. }
procedure TBrowserWindow.BackMenuOpening(Sender: TControl);
var
  Entries: TSessionEntries;
  Current, Index: Integer;
  Caption: string;
begin
  FToolbars.BackMenu.Clear;
  if ActiveView = nil then
    Exit;
  Entries := ViewHistory(ActiveView, Current);
  Index := Current - 1;
  while (Index >= 0) and (Current - Index <= MaximumBackMenuEntries) do
  begin
    Caption := Entries[Index].Title;
    if Caption = '' then
      Caption := Entries[Index].Url;
    FToolbars.BackMenu.Add(MenuCaption(Caption), @HistoryOffsetChosen).Tag := Index - Current;
    Dec(Index);
  end;
  Say('back-menu ' + IntToStr(FToolbars.BackMenu.Count));
end;

procedure TBrowserWindow.ForwardMenuOpening(Sender: TControl);
var
  Entries: TSessionEntries;
  Current, Index: Integer;
  Caption: string;
begin
  FToolbars.ForwardMenu.Clear;
  if ActiveView = nil then
    Exit;
  Entries := ViewHistory(ActiveView, Current);
  Index := Current + 1;
  while (Index <= High(Entries)) and (Index - Current <= MaximumBackMenuEntries) do
  begin
    Caption := Entries[Index].Title;
    if Caption = '' then
      Caption := Entries[Index].Url;
    FToolbars.ForwardMenu.Add(MenuCaption(Caption), @HistoryOffsetChosen).Tag := Index - Current;
    Inc(Index);
  end;
end;

procedure TBrowserWindow.HistoryOffsetChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    GoToViewHistory(ActiveView, Item.Tag);
end;

procedure TBrowserWindow.BookmarkThisPage;
var
  View: TWebView;
  Node: TBookmarkNode;
  IsNew: Boolean;
begin
  View := ActiveView;
  if (View = nil) or (View.Url = '') or (View.Url = 'about:blank') then
    Exit;
  Node := BrowserApp.Bookmarks.FindUrl(View.Url);
  IsNew := Node = nil;
  if IsNew then
  begin
    Node := BrowserApp.Bookmarks.AddBookmark(BrowserApp.Bookmarks.UnsortedFolder, ActiveTab.Caption, View.Url, -1,
      BrowserApp.NowUnix);
    Say('bookmarked ' + View.Url);
  end;
  RefreshChrome;
  if FToolbars.LocationBar <> nil then
    ShowBookmarkPanel(Self, FToolbars.LocationBar.StarButton, Node, IsNew)
  else
    ShowBookmarkPanel(Self, Root, Node, IsNew);
end;

procedure TBrowserWindow.BookmarkAllTabs;
var
  Urls, Titles: TStringArray;
  Index: Integer;
begin
  Urls := nil;
  Titles := nil;
  SetLength(Urls, FTabs.Count);
  SetLength(Titles, FTabs.Count);
  for Index := 0 to FTabs.Count - 1 do
  begin
    Urls[Index] := TabAt(Index).View.Url;
    Titles[Index] := TabAt(Index).Caption;
  end;
  BookmarkTabsDialog(Self, Urls, Titles);
end;

procedure TBrowserWindow.OpenLocation;
var
  Text: string;
begin
  if (FToolbars.LocationBar <> nil) and FToolbars.Navigation.Visible then
  begin
    FToolbars.LocationBar.FocusAndSelect;
    Exit;
  end;
  Text := '';
  if AskText(Self, 'Open Web Location', 'Enter a web address (URL), or a local file:', Text) and (Trim(Text) <> '') then
    GoToAddress(Text);
end;

procedure TBrowserWindow.SaveUrl(const Url, SuggestedName: string);
var
  Path: string;
begin
  if Url = '' then
    Exit;
  Path := SuggestedName;
  if BrowserApp.Settings.AskWhereToSave or True then
  begin
    if not ChooseFileToSave('Save As', DownloadsFolder, '*', Path, Path) then
      Exit;
    BrowserApp.StartDownload(Url, ExtractFileName(Path), Path);
  end;
end;

procedure TBrowserWindow.SetDesktopBackground(const Url: string);
var
  Path: string;
  Item: TDownloadItem;
  Store: TSettings;
begin
  if Url = '' then
    Exit;
  if ShowMessageBox('Set Desktop Background', 'Use this picture as the desktop background?' + LineEnding + Url,
    MessageOkCancel, SignQuestion, Self) <> ResultOk then
    Exit;
  Path := ExcludeTrailingPathDelimiter(CurrentHome) + '/Pictures';
  ForceDirectories(Path);
  Path := Path + '/Desktop Background' + ExtractFileExt(FileNameOfUrl(Url));
  Item := BrowserApp.StartDownload(Url, ExtractFileName(Path), Path);
  if Item = nil then
    Exit;
  { The desktop takes the picture once it is there: it watches its
    setting, so writing it is all it needs. }
  Store := OpenSettings;
  try
    Store.WriteString('Desktop/Wallpaper', Path);
  finally
    Store.Free;
  end;
  Say('desktop-background ' + Path);
end;

procedure TBrowserWindow.ToggleFullScreen;
begin
  { F11 while a page is fullscreen ends the page's fullscreen. }
  if FPageFullscreenView <> nil then
  begin
    LeavePageFullscreen(True);
    Exit;
  end;
  FFullScreen := not FFullScreen;
  if FFullScreen then
    Maximize
  else
    Restore;
  UpdateBarsVisible;
end;

procedure TBrowserWindow.ZoomView(Command: LongInt);
begin
  if ActiveView = nil then
    Exit;
  case Command of
    CommandZoomIn: ActiveView.ZoomIn;
    CommandZoomOut: ActiveView.ZoomOut;
    CommandZoomReset: ActiveView.ResetZoom;
  end;
end;

procedure NotAvailable(Owner: TWindow; const What: string);
begin
  ShowMessageBox(What, What + ' is not available: this system has no printing yet.', MessageOk, SignInformation,
    Owner);
end;

procedure TBrowserWindow.RunCommand(Command: LongInt);
var
  View: TWebView;
  Edit: TEditBox;
  Settings: TBrowserSettings;
  Path: string;
  Pages: TStringArray;
  Index: Integer;
begin
  View := ActiveView;
  Edit := FocusedEditBox(Self);
  Settings := BrowserApp.Settings;
  Pages := nil;
  case Command of
    CommandNewWindow:
      BrowserApp.NewWindow(Pages);
    CommandNewTab:
      begin
        OpenTab('about:blank', True);
        if FToolbars.LocationBar <> nil then
          FToolbars.LocationBar.FocusAndSelect;
      end;
    CommandOpenLocation, CommandFocusLocation:
      OpenLocation;
    CommandOpenFile:
      if ChooseFileToOpen('Open File', ExcludeTrailingPathDelimiter(CurrentHome), '*.html;*.htm;*.txt;*', Path) then
        GoToAddress(Path);
    CommandCloseTab:
      CloseTab(FActive);
    CommandCloseWindow:
      CloseRequested;
    CommandSavePage:
      if View <> nil then
        SaveUrl(View.Url, FileNameOfUrl(View.Url));
    CommandSendLink:
      if View <> nil then
      begin
        SetClipboardText(View.Url);
        ShowMessageBox('Send Link', 'There is no mail program on this system. The link was copied to the clipboard:' +
          LineEnding + View.Url, MessageOk, SignInformation, Self);
      end;
    CommandPageSetup:
      NotAvailable(Self, 'Page Setup');
    CommandPrintPreview:
      NotAvailable(Self, 'Print Preview');
    CommandPrint:
      NotAvailable(Self, 'Printing');
    CommandImport:
      ShowMessageBox('Import Wizard', 'There is no other browser on this system to import settings, bookmarks or ' +
        'history from.', MessageOk, SignInformation, Self);
    CommandWorkOffline:
      begin
        SetWorkOffline(not WorkOffline);
        Say('offline ' + BoolToStr(WorkOffline, 'on', 'off'));
        RefreshChrome;
      end;
    CommandExit:
      BrowserApp.Quit;
    CommandCut:
      if Edit <> nil then
        Edit.CutToClipboard;
    CommandCopy:
      if Edit <> nil then
        Edit.CopyToClipboard
      else if View <> nil then
        View.CopySelection;
    CommandPaste:
      if Edit <> nil then
        Edit.PasteFromClipboard;
    CommandDelete:
      if Edit <> nil then
        Edit.HandleKeyDown(KeyDelete, 0, 0);
    CommandSelectAll:
      if Edit <> nil then
        Edit.SelectAll
      else if View <> nil then
        View.SelectAll;
    CommandFind:
      FFindBar.Open;
    CommandFindAgain:
      if FFindBar.Edit.Text = '' then
        FFindBar.Open
      else
      begin
        FFindBar.Visible := True;
        FFindBar.FindAgain(True);
      end;
    CommandFindPrevious:
      if FFindBar.Edit.Text = '' then
        FFindBar.Open
      else
      begin
        FFindBar.Visible := True;
        FFindBar.FindAgain(False);
      end;
    CommandToggleMenuBar:
      begin
        Settings.MenuBar := not Settings.MenuBar;
        BrowserApp.Settings := Settings;
        BrowserApp.SaveSettings;
        UpdateBarsVisible;
        Say('menu-bar ' + BoolToStr(Settings.MenuBar, 'shown', 'hidden'));
      end;
    CommandToggleNavigationToolbar:
      begin
        Settings.NavigationToolbar := not Settings.NavigationToolbar;
        BrowserApp.Settings := Settings;
        BrowserApp.SaveSettings;
        UpdateBarsVisible;
      end;
    CommandToggleBookmarksToolbar:
      begin
        Settings.BookmarksToolbar := not Settings.BookmarksToolbar;
        BrowserApp.Settings := Settings;
        BrowserApp.SaveSettings;
        UpdateBarsVisible;
        Say('bookmarks-toolbar ' + BoolToStr(Settings.BookmarksToolbar, 'shown', 'hidden'));
      end;
    CommandToggleStatusBar:
      begin
        Settings.StatusBar := not Settings.StatusBar;
        BrowserApp.Settings := Settings;
        BrowserApp.SaveSettings;
        UpdateBarsVisible;
      end;
    CommandCustomizeToolbars:
      begin
        FToolbars.BeginCustomize(Root);
        FToolbars.Palette.DockOrder := 2;
        UpdateBarsVisible;
        Say('customize');
      end;
    CommandSidebarBookmarks:
      ShowSidebar(SidebarBookmarks);
    CommandSidebarHistory:
      ShowSidebar(SidebarHistory);
    CommandStop:
      if View <> nil then
        View.Stop;
    CommandReload, CommandReloadTab:
      if View <> nil then
        View.Reload;
    CommandReloadBypassCache:
      if View <> nil then
        View.Reload(True);
    CommandReloadAllTabs:
      for Index := 0 to FTabs.Count - 1 do
        TabAt(Index).View.Reload;
    CommandZoomIn, CommandZoomOut, CommandZoomReset:
      ZoomView(Command);
    CommandZoomTextOnly:
      if View <> nil then
        View.TextOnlyZoom := not View.TextOnlyZoom;
    CommandPageStyleNone:
      if View <> nil then
        View.AuthorStylesEnabled := False;
    CommandPageStyleBasic:
      if View <> nil then
        View.AuthorStylesEnabled := True;
    CommandEncodingAuto:
      if View <> nil then
        View.EncodingOverride := '';
    CommandPageSource:
      if View <> nil then
        ShowPageSource(View.Url);
    CommandFullScreen:
      ToggleFullScreen;
    CommandBack:
      if View <> nil then
        View.GoBack;
    CommandForward:
      if View <> nil then
        View.GoForward;
    CommandHome:
      begin
        Pages := HomePages(Settings);
        GoToAddress(Pages[0]);
        for Index := 1 to High(Pages) do
          OpenTab(Pages[Index], False);
      end;
    CommandShowAllHistory:
      ShowLibrary(LibraryHistory);
    CommandUndoCloseTab:
      UndoCloseTab(0);
    CommandUndoCloseWindow:
      if Length(BrowserApp.Session.ClosedWindows) > 0 then
      begin
        FMenus.ClosedWindowsMenu.Tag := 0;
        ClosedWindowChosen(FMenus.ClosedWindowsMenu);
      end;
    CommandBookmarkPage, CommandBookmarkTab:
      BookmarkThisPage;
    CommandSubscribePage:
      ShowMessageBox('Subscribe', 'This page has no feeds this browser can subscribe to.', MessageOk, SignInformation,
        Self);
    CommandBookmarkAllTabs:
      BookmarkAllTabs;
    CommandOrganizeBookmarks:
      ShowLibrary(LibraryBookmarks);
    CommandWebSearch, CommandFocusSearch:
      if (FToolbars.SearchBar <> nil) and FToolbars.Navigation.Visible then
        FToolbars.SearchBar.FocusAndSelect
      else
        OpenLocation;
    CommandDownloads:
      BrowserApp.ShowDownloadsWindow(True);
    CommandAddOns:
      OpenTab('about:addons', True);
    CommandErrorConsole:
      ShowErrorConsole;
    CommandPageInfo:
      if View <> nil then
        ShowPageInfo(View, Self, PageInfoGeneral);
    CommandPrivateBrowsing:
      if BrowserApp.PrivateBrowsing then
        BrowserApp.StopPrivateBrowsing
      else if ShowMessageBox('Start Private Browsing', 'Private browsing puts your windows and tabs aside and ' +
        'keeps no history, cookies or cache past the session. Your current windows come back when you stop it.',
        MessageOkCancel, SignInformation, Self) = ResultOk then
        BrowserApp.StartPrivateBrowsing;
    CommandClearRecentHistory:
      ShowClearRecentHistory(Self);
    CommandOptions:
      ShowOptionsWindow(Self, -1);
    CommandManageSearchEngines:
      ManageSearchEngines(Self);
    CommandHelpContents:
      OpenTab('about:help', True);
    CommandTroubleshooting:
      OpenTab('about:support', True);
    CommandReportForgery:
      ShowMessageBox('Report Web Forgery', 'Reporting forged sites needs an online service, and this browser sends ' +
        'nothing to anyone.', MessageOk, SignInformation, Self);
    CommandCheckUpdates:
      ShowMessageBox('Software Update', 'Browser is updated with the system: there is nothing to check here.',
        MessageOk, SignInformation, Self);
    CommandAbout:
      ShowAboutBrowser(Self);
    CommandNextTab:
      if FTabs.Count > 1 then
        ActivateTab((FActive + 1) mod FTabs.Count);
    CommandPreviousTab:
      if FTabs.Count > 1 then
        ActivateTab((FActive + FTabs.Count - 1) mod FTabs.Count);
    CommandLastTab:
      ActivateTab(FTabs.Count - 1);
    CommandCloseOtherTabs:
      begin
        Index := FTabMenuIndex;
        if Index < 0 then
          Index := FActive;
        while FTabs.Count > Index + 1 do
          CloseTab(FTabs.Count - 1);
        while Index > 0 do
        begin
          CloseTab(0);
          Dec(Index);
        end;
      end;
    CommandSelectTab..CommandSelectTab + 7:
      if Command - CommandSelectTab < FTabs.Count then
        ActivateTab(Command - CommandSelectTab);
  end;
end;
