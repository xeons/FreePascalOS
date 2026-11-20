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

{ Browser.MainWindow: what the web views tell. }

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
  View.OnScriptAlert := @ViewAlert;
  View.OnScriptConfirm := @ViewConfirm;
  View.OnScriptPrompt := @ViewPrompt;
  View.OnConsoleMessage := @ViewConsole;
end;

procedure TBrowserWindow.ViewTitleChanged(Sender: TWebView; const Text: string);
var
  Index: Integer;
begin
  Index := TabOfView(Sender);
  if Text <> '' then
  begin
    FHistory.SetTitle(Sender.Url, Text);
    Say('title ' + Text);
  end;
  RefreshTab(Index);
  if Index = FActive then
    RefreshChrome;
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
  if (Text <> 'about:blank') and (Text <> '') then
    FHistory.AddVisit(Text, Sender.Title, DateTimeToUnix(LocalTimeToUniversal(Now)));
  Say('location ' + Text);
  if Index = FActive then
  begin
    FAddress.Text := ShownAddress(Text);
    RefreshChrome;
  end;
  RefreshTab(Index);
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
end;

procedure TBrowserWindow.ViewStatusText(Sender: TWebView; const Text: string);
begin
  if TabOfView(Sender) = FActive then
    ShowStatus(Text);
end;

procedure TBrowserWindow.ViewHistoryChanged(Sender: TWebView);
begin
  if TabOfView(Sender) = FActive then
    RefreshChrome;
end;

procedure TBrowserWindow.ViewZoomChanged(Sender: TWebView);
begin
  Say('zoom ' + ZoomText(Sender.Zoom));
  if TabOfView(Sender) = FActive then
    RefreshChrome;
end;

procedure TBrowserWindow.ViewLinkClicked(Sender: TWebView; const Url: string; Disposition: TLinkDisposition;
  var Handled: Boolean);
begin
  Say('link ' + Url);
  if Disposition = LinkInView then
    Exit;
  { Ctrl+click opens behind; a middle click, a target or Shift in front. }
  OpenTab(Url, (HeldModifiers and ModifierControl) = 0);
  Handled := True;
end;

procedure TBrowserWindow.ViewDownloadRequested(Sender: TWebView; constref Download: TDownloadInfo);
var
  Item: TDownloadItem;
begin
  Item := FDownloads.Start(Download.Url, Download.FileName);
  Say('download ' + Item.FileName + ' started');
  ShowStatus('Downloading ' + Item.FileName);
end;

procedure TBrowserWindow.ViewNavigationFailed(Sender: TWebView; const Url, Reason: string);
begin
  Say('failed ' + Url + ' ' + Reason);
  if TabOfView(Sender) = FActive then
    ShowStatus('Could not open ' + Url + ': ' + Reason);
end;

const
  ContextOpenLinkInTab = 1;
  ContextOpenLink = 2;
  ContextCopyLink = 3;
  ContextBack = 4;
  ContextForward = 5;
  ContextReload = 6;
  ContextCopy = 7;
  ContextSelectAll = 8;
  ContextBookmark = 9;
  ContextFind = 10;

procedure TBrowserWindow.ViewContextMenu(Sender: TWebView; constref Info: TWebContextInfo; var Handled: Boolean);
var
  Item: TMenuItem;
begin
  Handled := True;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  FContextLink := Info.LinkUrl;
  if Info.LinkUrl <> '' then
  begin
    FContextMenu.Add('Open Link in New &Tab', @ContextMenuChosen).Tag := ContextOpenLinkInTab;
    FContextMenu.Add('&Open Link', @ContextMenuChosen).Tag := ContextOpenLink;
    FContextMenu.Add('Copy &Link Address', @ContextMenuChosen).Tag := ContextCopyLink;
    FContextMenu.AddSeparator;
  end;
  Item := FContextMenu.Add('&Back', @ContextMenuChosen, 'Alt+Left');
  Item.Tag := ContextBack;
  Item.Enabled := Sender.CanGoBack;
  Item := FContextMenu.Add('&Forward', @ContextMenuChosen, 'Alt+Right');
  Item.Tag := ContextForward;
  Item.Enabled := Sender.CanGoForward;
  FContextMenu.Add('&Reload', @ContextMenuChosen, 'F5').Tag := ContextReload;
  FContextMenu.AddSeparator;
  Item := FContextMenu.Add('&Copy', @ContextMenuChosen, 'Ctrl+C');
  Item.Tag := ContextCopy;
  Item.Enabled := Info.SelectedText <> '';
  FContextMenu.Add('Select &All', @ContextMenuChosen, 'Ctrl+A').Tag := ContextSelectAll;
  FContextMenu.Add('&Find...', @ContextMenuChosen, 'Ctrl+F').Tag := ContextFind;
  FContextMenu.AddSeparator;
  FContextMenu.Add('Bookmark This &Page', @ContextMenuChosen, 'Ctrl+D').Tag := ContextBookmark;
  ShowPopupMenu(Self, FContextMenu, ScreenLeft + Unscaled(Sender.PixelBounds.Left + Info.X),
    ScreenTop + Unscaled(Sender.PixelBounds.Top + Info.Y));
end;

procedure TBrowserWindow.ContextMenuChosen(Item: TMenuItem);
begin
  case Item.Tag of
    ContextOpenLinkInTab:
      OpenTab(FContextLink, False);
    ContextOpenLink:
      GoToAddress(FContextLink);
    ContextCopyLink:
      SetClipboardText(FContextLink);
    ContextBack:
      BackClicked(nil);
    ContextForward:
      ForwardClicked(nil);
    ContextReload:
      ReloadChosen(nil);
    ContextCopy:
      CopyChosen(nil);
    ContextSelectAll:
      if ActiveView <> nil then
        ActiveView.SelectAll;
    ContextBookmark:
      BookmarkPageChosen(nil);
    ContextFind:
      FFindBar.Open;
  end;
end;

procedure TBrowserWindow.ViewAlert(Sender: TWebView; const Text: string);
begin
  Say('alert ' + Text);
  ShowMessageBox(ShownAddress(Sender.Url), Text, MessageOk, SignInformation, Self);
end;

function TBrowserWindow.ViewConfirm(Sender: TWebView; const Message: string): Boolean;
begin
  Say('confirm ' + Message);
  Result := ShowMessageBox(ShownAddress(Sender.Url), Message, MessageOkCancel, SignQuestion, Self) = ResultOk;
end;

function TBrowserWindow.ViewPrompt(Sender: TWebView; const Message, Default: string; out Answer: string): Boolean;
begin
  Say('prompt ' + Message);
  Result := AskForText(Self, ShownAddress(Sender.Url), Message, Default, Answer);
end;

procedure TBrowserWindow.ViewConsole(Sender: TWebView; const Level, Text: string);
begin
  Say('console ' + Level + ' ' + Text);
end;
