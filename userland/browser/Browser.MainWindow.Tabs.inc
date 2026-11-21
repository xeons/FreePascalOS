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

{ Browser.MainWindow: the tabs and the window's session. }

function TBrowserWindow.TabCount: Integer;
begin
  Result := FTabs.Count;
end;

function TBrowserWindow.TabUrl(Index: Integer): string;
begin
  Result := TabAt(Index).View.Url;
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

{ A tab with its view at Index, not chosen yet. }
function TBrowserWindow.NewTab(Index: Integer): TBrowserTab;
begin
  Result := TBrowserTab.Create;
  Result.View := TWebView.Create(FContent);
  Result.View.Align := AlignClient;
  Result.View.Visible := False;
  ApplyViewSettings(Result.View);
  HookView(Result.View);
  Result.View.AboutPageProvider := @AboutPage;
  if (Index < 0) or (Index > FTabs.Count) then
    Index := FTabs.Count;
  FTabs.Insert(Index, Result);
  FTabStrip.Insert(Index, 'New Tab');
  if (FActive >= Index) then
    Inc(FActive);
  Say('tabs ' + IntToStr(FTabs.Count));
  UpdateBarsVisible;
  BrowserApp.SessionChanged;
end;

function TBrowserWindow.OpenTab(const Url: string; Bringing: Boolean): TBrowserTab;
var
  Index: Integer;
begin
  if FActive < 0 then
    Index := FTabs.Count
  else
    Index := FActive + 1;
  Result := NewTab(Index);
  Index := FTabs.IndexOf(Result);
  if Bringing or (FActive < 0) then
    ActivateTab(Index);
  RefreshTab(Index);
  GoToAddressIn(Result, Url);
  { A page asked for gets the keys; a new tab's home page leaves them
    in the location bar. }
  if Bringing and (ShownAddress(Url) <> '') and (Url <> BrowserApp.Settings.HomePage) then
    FocusControl(Result.View);
end;

procedure TBrowserWindow.OpenAddresses(const Addresses: TStringArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Addresses) do
    OpenTab(Addresses[Index], Index = 0);
end;

procedure TBrowserWindow.OpenUrl(const Url: string; Disposition: TLinkDisposition);
var
  Pages: TStringArray;
begin
  case Disposition of
    LinkInNewTab:
      OpenTab(Url, BrowserApp.Settings.SwitchToNewTabs or (FTabs.Count = 0));
    LinkInBackgroundTab:
      OpenTab(Url, False);
    LinkInNewWindow:
      begin
        Pages := nil;
        SetLength(Pages, 1);
        Pages[0] := Url;
        BrowserApp.NewWindow(Pages);
      end;
  else
    GoToAddress(Url);
  end;
end;

procedure TBrowserWindow.ActivateTab(Index: Integer);
var
  Other: Integer;
  Tab: TBrowserTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  FActive := Index;
  for Other := 0 to FTabs.Count - 1 do
    TabAt(Other).View.Visible := Other = Index;
  FTabStrip.ActiveIndex := Index;
  Tab := TabAt(Index);
  RefreshChrome;
  if (FToolbars.LocationBar <> nil) and ((Tab.View.Url = '') or (ShownAddress(Tab.View.Url) = '')) then
    FToolbars.LocationBar.FocusAndSelect
  else
    FocusControl(Tab.View);
  Say('tab ' + IntToStr(Index));
end;

procedure TBrowserWindow.CloseTab(Index: Integer);
var
  Tab: TBrowserTab;
  Saved: TSessionTab;
  Session: TSession;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Exit;
  if FTabs.Count = 1 then
  begin
    CloseRequested;
    Exit;
  end;
  Tab := TabAt(Index);
  Saved := CaptureTab(Index);
  if not BrowserApp.PrivateBrowsing then
  begin
    Session := BrowserApp.Session;
    RememberClosedTab(Session, Saved, 0, Index, BrowserApp.NowUnix);
    BrowserApp.Session := Session;
  end;
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
  UpdateBarsVisible;
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.MoveTab(FromIndex, ToIndex: Integer);
var
  Tab: TBrowserTab;
begin
  if (FromIndex < 0) or (FromIndex >= FTabs.Count) or (ToIndex < 0) or (ToIndex >= FTabs.Count) or
     (FromIndex = ToIndex) then
    Exit;
  Tab := ActiveTab;
  FTabs.Move(FromIndex, ToIndex);
  FTabStrip.Move(FromIndex, ToIndex);
  FActive := FTabs.IndexOf(Tab);
  FTabStrip.ActiveIndex := FActive;
  Say('tab-moved ' + IntToStr(FromIndex) + ' ' + IntToStr(ToIndex));
  BrowserApp.SessionChanged;
end;

procedure TBrowserWindow.UndoCloseTab(Index: Integer);
var
  Session: TSession;
  Closed: TClosedTab;
  Tab: TBrowserTab;
begin
  Session := BrowserApp.Session;
  if not TakeClosedTab(Session, Index, Closed) then
    Exit;
  BrowserApp.Session := Session;
  Tab := NewTab(Min(Closed.Position, FTabs.Count));
  RestoreTab(Tab, Closed.Tab);
  ActivateTab(FTabs.IndexOf(Tab));
  Say('undo-close ' + CurrentEntry(Closed.Tab).Url);
end;

procedure TBrowserWindow.TabSelected(Sender: TObject; Index: Integer);
begin
  ActivateTab(Index);
end;

procedure TBrowserWindow.TabClosed(Sender: TObject; Index: Integer);
begin
  CloseTab(Index);
end;

procedure TBrowserWindow.TabMoved(Sender: TObject; FromIndex, ToIndex: Integer);
begin
  MoveTab(FromIndex, ToIndex);
end;

{ The tab goes to a window of its own (its page loaded again there,
  with its back and forward entries). }
procedure TBrowserWindow.TabTornOff(Sender: TObject; Index: Integer);
var
  Window: TSessionWindow;
begin
  if (Index < 0) or (Index >= FTabs.Count) or (FTabs.Count < 2) then
    Exit;
  Window := Default(TSessionWindow);
  SetLength(Window.Tabs, 1);
  Window.Tabs[0] := CaptureTab(Index);
  Window.Left := ScreenLeft + 40;
  Window.Top := ScreenTop + 40;
  Window.Width := ClientWidth;
  Window.Height := ClientHeight;
  Say('tab-torn-off ' + IntToStr(Index));
  { Not remembered among closed tabs: it lives on in the new window. }
  PostMessage(Self, MessageCloseTabLater, Index);
  BrowserApp.RestoreWindow(Window);
end;

procedure TBrowserWindow.NewTabClicked(Sender: TControl);
begin
  RunCommand(CommandNewTab);
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
  Item.Loading := TabIsLoading(Tab);
  FTabStrip.ItemChanged(Index);
end;

function TBrowserWindow.CaptureTab(Index: Integer): TSessionTab;
var
  View: TWebView;
begin
  View := TabAt(Index).View;
  Result.Entries := ViewHistory(View, Result.Index);
  Result.ZoomPercent := Round(View.Zoom * 100);
end;

procedure TBrowserWindow.RestoreTab(Tab: TBrowserTab; constref Saved: TSessionTab);
begin
  if Length(Saved.Entries) = 0 then
  begin
    GoToAddressIn(Tab, BrowserApp.Settings.HomePage);
    Exit;
  end;
  RestoreViewHistory(Tab.View, Saved.Entries, Saved.Index);
  if (Saved.ZoomPercent > 0) and (Saved.ZoomPercent <> 100) then
    Tab.View.Zoom := Saved.ZoomPercent / 100;
  Say('restore ' + CurrentEntry(Saved).Url);
end;

function TBrowserWindow.CaptureSession: TSessionWindow;
var
  Index: Integer;
begin
  Result := Default(TSessionWindow);
  Result.Left := ScreenLeft;
  Result.Top := ScreenTop;
  Result.Width := ClientWidth;
  Result.Height := ClientHeight;
  Result.Selected := Max(0, FActive);
  SetLength(Result.Tabs, FTabs.Count);
  for Index := 0 to FTabs.Count - 1 do
    Result.Tabs[Index] := CaptureTab(Index);
end;

procedure TBrowserWindow.RestoreSession(constref Saved: TSessionWindow);
var
  Index: Integer;
  Tab: TBrowserTab;
begin
  if (Saved.Width > 200) and (Saved.Height > 150) then
  begin
    MoveTo(Saved.Left, Saved.Top);
    SetClientSize(Saved.Width, Saved.Height);
  end;
  for Index := 0 to High(Saved.Tabs) do
  begin
    Tab := NewTab(FTabs.Count);
    RestoreTab(Tab, Saved.Tabs[Index]);
    RefreshTab(FTabs.Count - 1);
  end;
  if FTabs.Count = 0 then
    OpenTab(BrowserApp.Settings.HomePage, True)
  else
    ActivateTab(EnsureRange(Saved.Selected, 0, FTabs.Count - 1));
end;
