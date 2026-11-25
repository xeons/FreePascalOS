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

{ Browser.MainWindow: what the web views tell, and the context menus. }

procedure TBrowserWindow.HookView(View: TWebView);
begin
  View.OnTitleChanged := @ViewTitleChanged;
  View.OnLocationChanged := @ViewLocationChanged;
  View.OnLoadingStateChanged := @ViewLoadingStateChanged;
  View.OnFaviconChanged := @ViewFaviconChanged;
  View.OnStatusText := @ViewStatusText;
  View.OnHistoryChanged := @ViewHistoryChanged;
  View.OnZoomChanged := @ViewZoomChanged;
  View.OnLinkClicked := @ViewLinkClicked;
  View.OnDownloadRequested := @ViewDownloadRequested;
  View.OnNavigationFailed := @ViewNavigationFailed;
  View.OnContextMenuRequested := @ViewContextMenu;
  { The page's alert, confirm and prompt: the view's own sheet, modal
    for that tab only. }
  View.OnScriptDialog := @ViewDialog;
  View.OnConsoleMessage := @ViewConsole;
  View.OnFindResult := @ViewFindResult;
  View.OnFindDetails := @ViewFindDetails;
  View.OnProcessEvent := @ViewProcessEvent;
  View.OnPopupBlocked := @ViewPopupBlocked;
  View.OnPageInfo := @ViewPageInfo;
end;

procedure TBrowserWindow.ViewTitleChanged(Sender: TWebView; const Text: string);
var
  Index: Integer;
begin
  Index := TabOfView(Sender);
  if Text <> '' then
  begin
    BrowserApp.History.SetTitle(Sender.Url, Text);
    Say('title ' + Text);
  end;
  RefreshTab(Index);
  if Index = FActive then
    RefreshChrome;
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.ViewLocationChanged(Sender: TWebView; const Text: string);
var
  Index: Integer;
  Tab: TBrowserTab;
begin
  Index := TabOfView(Sender);
  if Index < 0 then
    Exit;
  Tab := TabAt(Index);
  Tab.Typing := False;
  Tab.TakeIcon(nil);
  if (Text <> 'about:blank') and (Text <> '') and (Pos('about:', Text) <> 1) then
    BrowserApp.History.AddVisit(Text, Sender.Title, BrowserApp.NowUnix);
  Say('location ' + Text);
  if Index = FActive then
  begin
    if FFindBar.Visible then
      FFindBar.ShowResult(True, False);
    RefreshChrome;
  end;
  RefreshTab(Index);
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.ViewLoadingStateChanged(Sender: TWebView; State: TLoadingState);
const
  StateNames: array[TLoadingState] of string = ('idle', 'requesting', 'receiving', 'interactive', 'complete');
var
  Index: Integer;
begin
  Index := TabOfView(Sender);
  Say('state ' + StateNames[State]);
  if State = LoadingComplete then
    Say('loaded ' + Sender.Url);
  { A navigation that made no page (a download, a stop): the bar shows
    the page's address again. }
  if (State in [LoadingIdle, LoadingComplete]) and (Index >= 0) then
    TabAt(Index).Typing := TabAt(Index).Typing and (Index = FActive) and (FToolbars.LocationBar <> nil) and
      FToolbars.LocationBar.Edit.Focused;
  RefreshTab(Index);
  if Index = FActive then
    RefreshChrome;
end;

procedure TBrowserWindow.ViewFaviconChanged(Sender: TWebView);
var
  Index: Integer;
begin
  Index := TabOfView(Sender);
  if Index < 0 then
    Exit;
  TabAt(Index).TakeIcon(Sender.Favicon);
  if Sender.Favicon <> nil then
    Say('icon ' + IntToStr(Sender.Favicon.Width) + 'x' + IntToStr(Sender.Favicon.Height));
  RefreshTab(Index);
  if Index = FActive then
    RefreshLocation;
end;

procedure TBrowserWindow.ViewStatusText(Sender: TWebView; const Text: string);
begin
  if TabOfView(Sender) = FActive then
  begin
    if Text = '' then
      RefreshChrome
    else
      ShowStatus(Text);
  end;
end;

procedure TBrowserWindow.ViewHistoryChanged(Sender: TWebView);
begin
  if TabOfView(Sender) = FActive then
    RefreshChrome;
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.ViewZoomChanged(Sender: TWebView);
begin
  Say('zoom ' + ZoomText(Sender.Zoom));
  if TabOfView(Sender) = FActive then
    RefreshChrome;
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.ViewLinkClicked(Sender: TWebView; const Url: string; Disposition: TLinkDisposition;
  var Handled: Boolean);
begin
  Say('link ' + Url);
  if Disposition = LinkInView then
    Exit;
  { A page that asks for a new window gets a tab, if the settings say. }
  if (Disposition = LinkInNewWindow) and BrowserApp.Settings.NewWindowsInTabs and
     ((HeldModifiers and ModifierShift) = 0) then
    Disposition := LinkInNewTab;
  OpenUrl(Url, Disposition);
  Handled := True;
end;

procedure TBrowserWindow.ViewDownloadRequested(Sender: TWebView; constref Download: TDownloadInfo);
var
  Path: string;
begin
  if BrowserApp.Settings.AskWhereToSave then
  begin
    Path := Download.FileName;
    if ChooseFileToSave('Save As', DownloadsFolder, '*', Path, Path) then
      BrowserApp.StartDownload(Download.Url, ExtractFileName(Path), Path);
  end
  else
    BrowserApp.StartDownload(Download.Url, Download.FileName);
  RefreshChrome;
end;

procedure TBrowserWindow.ViewNavigationFailed(Sender: TWebView; const Url, Reason: string);
begin
  Say('failed ' + Url + ' ' + Reason);
  if TabOfView(Sender) = FActive then
    ShowStatus('Could not open ' + Url + ': ' + Reason);
end;

procedure TBrowserWindow.ViewPopupBlocked(Sender: TWebView; const Url: string);
begin
  Say('popup-blocked ' + Url);
  if TabOfView(Sender) = FActive then
    ShowStatus('Prevented this site from opening a pop-up window: ' + Url);
end;

procedure TBrowserWindow.ViewPageInfo(Sender: TWebView; constref Info: TWebPageInfo);
begin
  PageInfoArrived(Sender, Info);
end;

{ ---- the page's context menu ---- }

function AddContext(Menu: TMenuItem; const Text: string; Command: LongInt; Handler: TMenuItemEvent;
  const Shortcut: string = ''): TMenuItem;
begin
  Result := Menu.Add(Text, Handler, Shortcut);
  Result.Tag := Command;
end;

procedure TBrowserWindow.ViewContextMenu(Sender: TWebView; constref Info: TWebContextInfo; var Handled: Boolean);
var
  Menu: TMenuItem;
  Selection: string;
  Item: TMenuItem;
begin
  Handled := True;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  Menu := FContextMenu;
  FContext := Info;
  FContextView := Sender;
  if Info.IsEditable or Info.InTextField then
  begin
    { A form field: spelling (no dictionary yet) and editing. }
    AddContext(Menu, '(No Spelling Suggestions)', CommandSpellNoSuggestions, @ContextMenuChosen).Enabled := False;
    Menu.AddSeparator;
    AddContext(Menu, '&Undo', CommandUndo, @ContextMenuChosen, 'Ctrl+Z').Enabled := False;
    Menu.AddSeparator;
    AddContext(Menu, 'Cu&t', CommandCut, @ContextMenuChosen, 'Ctrl+X').Enabled := Info.SelectedText <> '';
    AddContext(Menu, '&Copy', CommandCopy, @ContextMenuChosen, 'Ctrl+C').Enabled := Info.SelectedText <> '';
    AddContext(Menu, '&Paste', CommandPaste, @ContextMenuChosen, 'Ctrl+V');
    AddContext(Menu, '&Delete', CommandDelete, @ContextMenuChosen, 'Del').Enabled := Info.SelectedText <> '';
    Menu.AddSeparator;
    AddContext(Menu, 'Select &All', CommandSelectAll, @ContextMenuChosen, 'Ctrl+A');
  end
  else
  begin
    if Info.LinkUrl <> '' then
    begin
      AddContext(Menu, 'Open Link in New &Window', CommandOpenLinkInWindow, @ContextMenuChosen);
      AddContext(Menu, 'Open Link in New &Tab', CommandOpenLinkInTab, @ContextMenuChosen);
      Menu.AddSeparator;
      AddContext(Menu, 'Bookmark This &Link', CommandBookmarkLink, @ContextMenuChosen);
      AddContext(Menu, 'Save Lin&k As...', CommandSaveLink, @ContextMenuChosen);
      AddContext(Menu, 'Copy Link Loc&ation', CommandCopyLink, @ContextMenuChosen);
      Menu.AddSeparator;
    end;
    if Info.ImageUrl <> '' then
    begin
      AddContext(Menu, 'Vie&w Image', CommandViewImage, @ContextMenuChosen);
      AddContext(Menu, 'Cop&y Image Location', CommandCopyImageLocation, @ContextMenuChosen);
      AddContext(Menu, 'Sa&ve Image As...', CommandSaveImage, @ContextMenuChosen);
      AddContext(Menu, 'Set As Desktop &Background...', CommandSetDesktopBackground, @ContextMenuChosen);
      Menu.AddSeparator;
    end;
    if Info.SelectedText <> '' then
    begin
      AddContext(Menu, '&Copy', CommandCopy, @ContextMenuChosen, 'Ctrl+C');
      AddContext(Menu, 'Select &All', CommandSelectAll, @ContextMenuChosen, 'Ctrl+A');
      Selection := Trim(Info.SelectedText);
      if Length(Selection) > 15 then
        Selection := Copy(Selection, 1, 15) + '...';
      if BrowserApp.Settings.SearchEngine <> '' then
        AddContext(Menu, 'Search ' + MenuCaption(BrowserApp.Settings.SearchEngine) + ' for "' + MenuCaption(Selection) +
          '"', CommandSearchSelection, @ContextMenuChosen)
      else
        AddContext(Menu, 'Search for "' + MenuCaption(Selection) + '" (choose a search engine)',
          CommandSearchSelection, @ContextMenuChosen);
      Menu.AddSeparator;
      AddContext(Menu, 'View Selection S&ource', CommandViewSelectionSource, @ContextMenuChosen);
    end
    else if (Info.LinkUrl = '') and (Info.ImageUrl = '') then
    begin
      Item := AddContext(Menu, '&Back', CommandBack, @ContextMenuChosen, 'Alt+Left');
      Item.Enabled := Sender.CanGoBack;
      Item := AddContext(Menu, '&Forward', CommandForward, @ContextMenuChosen, 'Alt+Right');
      Item.Enabled := Sender.CanGoForward;
      if TabIsLoading(ActiveTab) then
        AddContext(Menu, '&Stop', CommandStop, @ContextMenuChosen, 'Esc')
      else
        AddContext(Menu, '&Reload', CommandReload, @ContextMenuChosen, 'F5');
      Menu.AddSeparator;
      AddContext(Menu, 'Bookmark This &Page', CommandBookmarkPage, @ContextMenuChosen, 'Ctrl+D');
      AddContext(Menu, 'Save Page &As...', CommandSavePage, @ContextMenuChosen, 'Ctrl+S');
      AddContext(Menu, 'Send &Link...', CommandSendLink, @ContextMenuChosen);
      Menu.AddSeparator;
      if Info.BackgroundImageUrl <> '' then
      begin
        AddContext(Menu, 'View Back&ground Image', CommandViewBackgroundImage, @ContextMenuChosen);
        Menu.AddSeparator;
      end;
      AddContext(Menu, 'Select &All', CommandSelectAll, @ContextMenuChosen, 'Ctrl+A');
      Menu.AddSeparator;
      AddContext(Menu, 'View Page S&ource', CommandPageSource, @ContextMenuChosen, 'Ctrl+U');
      AddContext(Menu, 'View Page &Info', CommandPageInfo, @ContextMenuChosen, 'Ctrl+I');
    end;
  end;
  Say('context-menu ' + IntToStr(Menu.Count));
  ShowPopupMenu(Self, FContextMenu, ScreenLeft + Unscaled(Sender.PixelBounds.Left + Info.X),
    ScreenTop + Unscaled(Sender.PixelBounds.Top + Info.Y));
end;

procedure TBrowserWindow.ContextMenuChosen(Item: TMenuItem);
var
  Selection: string;
begin
  case Item.Tag of
    CommandOpenLinkInWindow:
      OpenUrl(FContext.LinkUrl, LinkInNewWindow);
    CommandOpenLinkInTab:
      OpenUrl(FContext.LinkUrl, LinkInBackgroundTab);
    CommandBookmarkLink:
      NewBookmarkNode(Self, BookmarkItem, BrowserApp.Bookmarks.MenuFolder, -1, FContext.LinkText, FContext.LinkUrl);
    CommandSaveLink:
      SaveUrl(FContext.LinkUrl, FileNameOfUrl(FContext.LinkUrl));
    CommandCopyLink:
      SetClipboardText(FContext.LinkUrl);
    CommandViewImage:
      GoToAddress(FContext.ImageUrl);
    CommandCopyImageLocation, CommandCopyImage:
      SetClipboardText(FContext.ImageUrl);
    CommandSaveImage:
      SaveUrl(FContext.ImageUrl, FileNameOfUrl(FContext.ImageUrl));
    CommandSetDesktopBackground:
      SetDesktopBackground(FContext.ImageUrl);
    CommandViewBackgroundImage:
      GoToAddress(FContext.BackgroundImageUrl);
    CommandSearchSelection:
      begin
        Selection := Trim(FContext.SelectedText);
        WebSearch(Selection, True);
      end;
    CommandViewSelectionSource:
      if ActiveView <> nil then
        ShowPageSource(ActiveView.Url);
    CommandCopy:
      if FContextView <> nil then
        FContextView.CopySelection;
    CommandSelectAll:
      if FContextView <> nil then
        FContextView.SelectAll;
  else
    RunCommand(Item.Tag);
  end;
end;

{ ---- the tab context menu ---- }

procedure TBrowserWindow.TabMenuRequested(Sender: TObject; Index: Integer; X, Y: LongInt);
var
  Menu: TMenuItem;
begin
  FTabMenuIndex := Index;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  Menu := FContextMenu;
  AddContext(Menu, '&New Tab', CommandNewTab, @TabMenuChosen, 'Ctrl+T');
  Menu.AddSeparator;
  AddContext(Menu, 'R&eload Tab', CommandReloadTab, @TabMenuChosen).Enabled := Index >= 0;
  AddContext(Menu, 'Re&load All Tabs', CommandReloadAllTabs, @TabMenuChosen);
  AddContext(Menu, 'Close &Other Tabs', CommandCloseOtherTabs, @TabMenuChosen).Enabled := (Index >= 0) and
    (FTabs.Count > 1);
  Menu.AddSeparator;
  AddContext(Menu, '&Bookmark This Tab', CommandBookmarkTab, @TabMenuChosen).Enabled := Index >= 0;
  AddContext(Menu, 'Bookmark &All Tabs...', CommandBookmarkAllTabs, @TabMenuChosen, 'Ctrl+Shift+D');
  AddContext(Menu, '&Undo Close Tab', CommandUndoCloseTab, @TabMenuChosen, 'Ctrl+Shift+T').Enabled :=
    Length(BrowserApp.Session.ClosedTabs) > 0;
  Menu.AddSeparator;
  AddContext(Menu, '&Close Tab', CommandCloseTab, @TabMenuChosen, 'Ctrl+W').Enabled := Index >= 0;
  Say('tab-menu ' + IntToStr(Index));
  ShowPopupMenu(Self, FContextMenu, ScreenLeft + Unscaled(FTabStrip.PixelBounds.Left + X),
    ScreenTop + Unscaled(FTabStrip.PixelBounds.Top + Y));
end;

procedure TBrowserWindow.TabMenuChosen(Item: TMenuItem);
var
  Index: Integer;
begin
  Index := FTabMenuIndex;
  case Item.Tag of
    CommandReloadTab:
      if (Index >= 0) and (Index < FTabs.Count) then
        TabAt(Index).View.Reload;
    CommandBookmarkTab:
      if (Index >= 0) and (Index < FTabs.Count) then
      begin
        ActivateTab(Index);
        BookmarkThisPage;
      end;
    CommandCloseTab:
      CloseTab(Index);
  else
    RunCommand(Item.Tag);
  end;
  FTabMenuIndex := -1;
end;

procedure TBrowserWindow.ViewDialog(Sender: TWebView; const Kind, Message: string);
begin
  Say(Kind + ' ' + Message);
end;

procedure TBrowserWindow.ViewFindResult(Sender: TWebView; const Needle: string; Found: Boolean);
begin
  if Found then
    Say('found ' + Needle)
  else
    Say('not-found ' + Needle);
end;

procedure TBrowserWindow.ViewFindDetails(Sender: TWebView; const Needle: string; Found, Wrapped: Boolean;
  MatchCount: Integer);
begin
  if TabOfView(Sender) <> FActive then
    Exit;
  FFindBar.ShowResult(Found, Wrapped);
  if Wrapped then
    Say('find-wrapped ' + Needle);
end;

procedure TBrowserWindow.ViewProcessEvent(Sender: TWebView; const What: string; Value: Int64);
begin
  Say('process ' + What + ' ' + IntToStr(Value) + ' tab ' + IntToStr(TabOfView(Sender)));
  if What = 'crashed' then
    RefreshTab(TabOfView(Sender));
end;

function TBrowserWindow.RunDebugAddress(Tab: TBrowserTab; const Text: string): Boolean;
begin
  Result := True;
  if Text = 'about:crash' then
  begin
    Say('go about:crash');
    Tab.View.CrashContentProcess;
  end
  else if Text = 'about:kill' then
  begin
    Say('go about:kill');
    Tab.View.TerminateContentProcess;
  end
  else if Text = 'about:hang' then
  begin
    Say('go about:hang');
    Tab.View.HangContentProcess;
  end
  else
    Result := False;
end;

procedure TBrowserWindow.ViewConsole(Sender: TWebView; const Level, Text: string);
begin
  Say('console ' + Level + ' ' + Text);
  BrowserApp.Console.Add(Level, Text, Sender.Url, BrowserApp.NowUnix);
end;
