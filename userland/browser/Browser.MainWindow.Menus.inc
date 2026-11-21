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

{ Browser.MainWindow: the menus, their keys and their commands. }

procedure TBrowserWindow.AddKey(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
  Code, Modifiers: LongWord);
var
  Item: TMenuItem;
begin
  Item := Menu.Add(Text, Handler, Shortcut);
  if Code <> 0 then
    AddItemAccelerator(Self, Item, Code, Modifiers);
end;

procedure TBrowserWindow.BuildMenus;
var
  Menu: TMenuItem;
begin
  FMenuBar := TMenuBar.Create(Root);
  Menu := FMenuBar.Menu.Add('&File');
  AddKey(Menu, 'New &Tab', @NewTabChosen, 'Ctrl+T', KeyT, ModifierControl);
  AddKey(Menu, '&Close Tab', @CloseTabChosen, 'Ctrl+W', KeyW, ModifierControl);
  Menu.AddSeparator;
  AddKey(Menu, '&Open File...', @OpenFileChosen, 'Ctrl+O', KeyO, ModifierControl);
  Menu.AddSeparator;
  AddKey(Menu, 'E&xit', @ExitChosen, '', 0, 0);
  Menu := FMenuBar.Menu.Add('&Edit');
  AddKey(Menu, '&Copy', @CopyChosen, 'Ctrl+C', 0, 0);
  AddKey(Menu, 'Select &All', @SelectAllChosen, 'Ctrl+A', 0, 0);
  Menu.AddSeparator;
  AddKey(Menu, '&Find...', @FindChosen, 'Ctrl+F', KeyF, ModifierControl);
  AddKey(Menu, 'Find &Next', @FindNextChosen, 'F3', KeyF3, 0);
  Menu := FMenuBar.Menu.Add('&View');
  AddKey(Menu, '&Reload', @ReloadChosen, 'F5', KeyF5, 0);
  AddKey(Menu, '&Stop', @StopChosen, '', 0, 0);
  Menu.AddSeparator;
  AddKey(Menu, 'Zoom &In', @ZoomInChosen, 'Ctrl++', KeyEquals, ModifierControl);
  AddKey(Menu, 'Zoom &Out', @ZoomOutChosen, 'Ctrl+-', KeyMinus, ModifierControl);
  AddKey(Menu, '&Actual Size', @ActualSizeChosen, 'Ctrl+0', KeyZero, ModifierControl);
  Menu.AddSeparator;
  FBookmarksBarItem := Menu.Add('&Bookmarks Bar', @BookmarksBarChosen);
  Menu := FMenuBar.Menu.Add('&History');
  AddKey(Menu, '&Back', @BackChosen, 'Alt+Left', KeyArrowLeft, ModifierAlt);
  AddKey(Menu, '&Forward', @ForwardChosen, 'Alt+Right', KeyArrowRight, ModifierAlt);
  AddKey(Menu, '&Home Page', @HomeChosen, 'Alt+Home', KeyHome, ModifierAlt);
  Menu.AddSeparator;
  AddKey(Menu, '&Show History', @HistoryChosen, 'Ctrl+H', KeyH, ModifierControl);
  FBookmarksMenu := FMenuBar.Menu.Add('&Bookmarks');
  FBookmarksMenu.OnOpening := @BookmarksMenuOpening;
  BookmarksMenuOpening(FBookmarksMenu);
  Menu := FMenuBar.Menu.Add('&Tools');
  AddKey(Menu, '&Downloads', @DownloadsChosen, 'Ctrl+J', KeyJ, ModifierControl);
  AddKey(Menu, '&Settings...', @SettingsChosen, '', 0, 0);
  Menu := FMenuBar.Menu.Add('Hel&p');
  AddKey(Menu, '&About Browser', @AboutChosen, '', 0, 0);
  { Keys without a menu item. }
  AddAccelerator(KeyL, ModifierControl, @FocusAddress);
  AddAccelerator(KeyD, ModifierAlt, @FocusAddress);
  AddAccelerator(KeyTab, ModifierControl, @NextTab);
  AddAccelerator(KeyPageDown, ModifierControl, @NextTab);
  AddAccelerator(KeyTab, ModifierControl or ModifierShift, @PreviousTab);
  AddAccelerator(KeyPageUp, ModifierControl, @PreviousTab);
  AddAccelerator(KeyR, ModifierControl, @ReloadKey);
  AddAccelerator(KeyD, ModifierControl, @BookmarkKey);
  AddAccelerator(KeyNumpadPlus, ModifierControl, @ZoomInKey);
  AddAccelerator(KeyEquals, ModifierControl or ModifierShift, @ZoomInKey);
end;

{ The Bookmarks menu: its commands, then every bookmark. }
procedure TBrowserWindow.BookmarksMenuOpening(Item: TMenuItem);
var
  Index: Integer;
  Entry: TMenuItem;
  Caption: string;
begin
  FBookmarksMenu.Clear;
  AddKey(FBookmarksMenu, '&Bookmark This Page', @BookmarkPageChosen, 'Ctrl+D', 0, 0);
  AddKey(FBookmarksMenu, '&Show Bookmarks', @ShowBookmarksChosen, '', 0, 0);
  if FBookmarks.Count > 0 then
    FBookmarksMenu.AddSeparator;
  for Index := 0 to FBookmarks.Count - 1 do
  begin
    Caption := FBookmarks.Items[Index].Title;
    if Caption = '' then
      Caption := FBookmarks.Items[Index].Url;
    Entry := FBookmarksMenu.Add(StringReplace(Caption, '&', '&&', [rfReplaceAll]), @BookmarkItemChosen);
    Entry.Tag := Index;
  end;
end;

procedure TBrowserWindow.BookmarkItemChosen(Item: TMenuItem);
begin
  if (Item.Tag >= 0) and (Item.Tag < FBookmarks.Count) then
    GoToAddress(FBookmarks.Items[Item.Tag].Url);
end;

procedure TBrowserWindow.NewTabChosen(Item: TMenuItem);
begin
  OpenTab(FSettings.HomePage, True);
end;

procedure TBrowserWindow.CloseTabChosen(Item: TMenuItem);
begin
  CloseTab(FActive);
end;

procedure TBrowserWindow.OpenFileChosen(Item: TMenuItem);
var
  Path: string;
begin
  if ChooseFileToOpen('Open File', '/', '*.html;*.htm;*.txt;*', Path) then
    GoToAddress(Path);
end;

procedure TBrowserWindow.ExitChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TBrowserWindow.CopyChosen(Item: TMenuItem);
begin
  if FAddress.Focused then
    FAddress.CopyToClipboard
  else if ActiveView <> nil then
    ActiveView.CopySelection;
end;

procedure TBrowserWindow.SelectAllChosen(Item: TMenuItem);
begin
  if FAddress.Focused then
    FAddress.SelectAll
  else if ActiveView <> nil then
    ActiveView.SelectAll;
end;

procedure TBrowserWindow.FindChosen(Item: TMenuItem);
begin
  FFindBar.Open;
end;

procedure TBrowserWindow.FindNextChosen(Item: TMenuItem);
begin
  if FFindBar.Edit.Text = '' then
    FFindBar.Open
  else
    FindRequested(FFindBar.Edit.Text, True, False, False);
end;

procedure TBrowserWindow.ReloadChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    ActiveView.Reload;
end;

procedure TBrowserWindow.ReloadKey(Sender: TControlWindow);
begin
  ReloadChosen(nil);
end;

procedure TBrowserWindow.StopChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    ActiveView.Stop;
end;

procedure TBrowserWindow.ZoomInChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    ActiveView.ZoomIn;
end;

procedure TBrowserWindow.ZoomInKey(Sender: TControlWindow);
begin
  ZoomInChosen(nil);
end;

procedure TBrowserWindow.ZoomOutChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    ActiveView.ZoomOut;
end;

procedure TBrowserWindow.ActualSizeChosen(Item: TMenuItem);
begin
  if ActiveView <> nil then
    ActiveView.ResetZoom;
end;

procedure TBrowserWindow.BookmarksBarChosen(Item: TMenuItem);
begin
  FSettings.BookmarksToolbar := not FSettings.BookmarksToolbar;
  SaveBrowserSettings(FSettings);
  ApplySettings;
end;

procedure TBrowserWindow.BackChosen(Item: TMenuItem);
begin
  BackClicked(nil);
end;

procedure TBrowserWindow.ForwardChosen(Item: TMenuItem);
begin
  ForwardClicked(nil);
end;

procedure TBrowserWindow.HomeChosen(Item: TMenuItem);
begin
  HomeClicked(nil);
end;

procedure TBrowserWindow.HistoryChosen(Item: TMenuItem);
begin
  OpenTab('about:history', True);
end;

procedure TBrowserWindow.BookmarkPageChosen(Item: TMenuItem);
var
  View: TWebView;
  Index: Integer;
begin
  View := ActiveView;
  if (View = nil) or (View.Url = '') or (View.Url = 'about:blank') then
    Exit;
  Index := FBookmarks.IndexOf(View.Url);
  if Index >= 0 then
  begin
    FBookmarks.Delete(Index);
    Say('unbookmarked ' + View.Url);
  end
  else
  begin
    FBookmarks.Add(ActiveTab.Caption, View.Url);
    Say('bookmarked ' + View.Url);
  end;
  FBookmarksBar.Invalidate;
  RefreshChrome;
end;

procedure TBrowserWindow.BookmarkKey(Sender: TControlWindow);
begin
  BookmarkPageChosen(nil);
end;

procedure TBrowserWindow.ShowBookmarksChosen(Item: TMenuItem);
begin
  OpenTab('about:bookmarks', True);
end;

procedure TBrowserWindow.DownloadsChosen(Item: TMenuItem);
begin
  OpenTab('about:downloads', True);
end;

procedure TBrowserWindow.ApplySettings;
var
  Index: Integer;
begin
  SetHttp3Allowed(FSettings.Http3);
  FBookmarksBar.Visible := FSettings.BookmarksToolbar;
  FBookmarksBarItem.Checked := FSettings.BookmarksToolbar;
  for Index := 0 to FTabs.Count - 1 do
    TabAt(Index).View.ScriptingEnabled := FSettings.JavaScript;
end;

procedure TBrowserWindow.SettingsChosen(Item: TMenuItem);
begin
  if EditBrowserSettings(Self, FSettings) then
  begin
    SaveBrowserSettings(FSettings);
    ApplySettings;
    Say('settings home ' + FSettings.HomePage);
  end;
end;

procedure TBrowserWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Browser', 'Browser 1.0' + LineEnding + LineEnding +
    'A web browser for FreePascalOS: libweb (HTML, CSS, layout, JavaScript), libhttp and libquic ' +
    '(HTTP/1.1, HTTP/2 and HTTP/3).', MessageOk, SignInformation, Self);
end;

procedure TBrowserWindow.FocusAddress(Sender: TControlWindow);
begin
  FocusControl(FAddress);
  FAddress.SelectAll;
end;

procedure TBrowserWindow.NextTab(Sender: TControlWindow);
begin
  if FTabs.Count > 1 then
    ActivateTab((FActive + 1) mod FTabs.Count);
end;

procedure TBrowserWindow.PreviousTab(Sender: TControlWindow);
begin
  if FTabs.Count > 1 then
    ActivateTab((FActive + FTabs.Count - 1) mod FTabs.Count);
end;
