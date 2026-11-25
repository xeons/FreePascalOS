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

{ WebView.Control: the page in a content process - which process, what
  it tells, its frames. }

function TWebView.NextRequestId: LongWord;
begin
  Inc(FNextRequestId);
  if FNextRequestId = 0 then
    FNextRequestId := 1;
  Result := FNextRequestId;
end;

procedure TWebView.SendToProcess(Kind: Word; const Payload: TBytes; RequestId: LongWord);
begin
  if (FProcess = nil) or (FLink = nil) then
    Exit;
  ContentProcesses.Send(FProcess, Kind, FLink.ViewId, RequestId, Payload);
end;

function TWebView.RemoteSite: string;
begin
  if FProcess <> nil then
    Result := FProcess.Site
  else
    Result := '';
end;

function TWebView.IsShown: Boolean;
var
  Control: TControl;
begin
  Control := Self;
  while Control <> nil do
  begin
    if not Control.Visible then
      Exit(False);
    Control := Control.Parent;
  end;
  Result := True;
end;

function TWebView.CurrentGeometry: TIpcViewGeometry;
begin
  Result.Width := Max(1, RectangleWidth(PixelBounds));
  Result.Height := Max(1, RectangleHeight(PixelBounds));
  Result.ScalePercent := DisplayScale;
  Result.Dpi := DisplayDpi;
end;

procedure TWebView.SendGeometryIfChanged;
var
  Geometry: TIpcViewGeometry;
begin
  if FProcess = nil then
    Exit;
  Geometry := CurrentGeometry;
  if (Geometry.Width <> FSentGeometry.Width) or (Geometry.Height <> FSentGeometry.Height) or
     (Geometry.ScalePercent <> FSentGeometry.ScalePercent) or (Geometry.Dpi <> FSentGeometry.Dpi) then
  begin
    FSentGeometry := Geometry;
    SendToProcess(IpcResize, EncodeGeometry(Geometry));
  end;
  if IsShown <> FSentVisible then
  begin
    FSentVisible := IsShown;
    SendToProcess(IpcSetVisible, EncodeFlag(FSentVisible));
  end;
end;

{ The view's page moves to a process of Site (a new view there); False
  when there is none to be had (the page runs in the program then). }
function TWebView.EnsureProcessFor(const Site: string): Boolean;
var
  Process: TContentProcess;
  Setup: TIpcViewSetup;
begin
  if (FProcess <> nil) and (FProcess.Site = Site) then
    Exit(True);
  FModelChosen := True;
  Process := ContentProcesses.ProcessForSite(Site);
  if Process = nil then
    Exit(False);
  LeaveProcess;
  if FLink = nil then
  begin
    FLink := TViewContentLink.Create;
    TViewContentLink(FLink).View := Self;
  end;
  FProcess := Process;
  ContentProcesses.Attach(FProcess, FLink);
  Setup := Default(TIpcViewSetup);
  Setup.Geometry := CurrentGeometry;
  Setup.Zoom := FZoom;
  Setup.Visible := IsShown;
  Setup.Focused := Focused;
  Setup.ScriptingEnabled := FScriptingEnabled;
  FSentGeometry := Setup.Geometry;
  FSentVisible := Setup.Visible;
  FSentFocused := Setup.Focused;
  SendToProcess(IpcCreateView, EncodeViewSetup(Setup));
  SendDisplayOptions;
  FRemoteCanGoBack := False;
  FRemoteCanGoForward := False;
  FRemoteEntries := nil;
  FRemoteIndex := -1;
  FInputSequence := 0;
  FFrameInfo := Default(TIpcFrameInfo);
  FScrollShift := 0;
  FInterruptTimes := nil;
  HideCrashPanel;
  HideHangBar;
  FStateTimer.Enabled := True;
  TellProcessEvent('started', FProcess.ProcessId);
  Result := True;
end;

procedure TWebView.LeaveProcess;
begin
  CloseSheet;
  if FProcess = nil then
    Exit;
  ContentProcesses.Detach(FProcess, FLink);
  FProcess := nil;
  FreeAndNil(FShared);
  FSharedId := 0;
end;

{ A navigation from the host or from a page: to the process of its
  site, which may be another than now. }
procedure TWebView.NavigateRemote(constref Open: TIpcOpenUrl);
var
  Site: string;
begin
  Site := SiteOfText(Open.Url);
  if (FProcess = nil) or ((Site <> '') and (Site <> FProcess.Site)) then
  begin
    { The entries of the site left stay as back (and, for a page that
      replaces the current one, forward) entries: Back comes here again. }
    LeaveSiteHistory(not Open.Replace);
    if not EnsureProcessFor(Site) then
    begin
      EnsureEngine;
      FEngine.Navigate(Open.Url);
      Exit;
    end;
    { The entry on its way, until the process tells its history. }
    SetLength(FRemoteEntries, 1);
    FRemoteEntries[0].Url := Open.Url;
    FRemoteEntries[0].Title := '';
    FRemoteIndex := 0;
  end;
  SendToProcess(IpcNavigate, EncodeOpenUrl(Open));
end;

{ ---- what the content process tells ---- }

procedure TWebView.RemoteReceived(Message: TIpcMessage);
var
  Number: LongInt;
  Amount: Double;
  Value, Second: string;
begin
  case Message.Kind of
    IpcSurfaceCreated: TakeSurface(Message);
    IpcFramePresented: TakeFrame(Message);
    IpcTitleChanged: TellTitle(DecodeText(Message.Payload));
    IpcLocationChanged:
      begin
        TellLocation(DecodeText(Message.Payload));
        HideCrashPanel;
      end;
    IpcLoadingStateChanged:
      begin
        Number := DecodeNumber(Message.Payload);
        if (Number >= Ord(Low(TLoadingState))) and (Number <= Ord(High(TLoadingState))) then
          TellLoadingState(TLoadingState(Number));
      end;
    IpcFaviconChanged: TakeFavicon(Message);
    IpcStatusText: TellStatus(DecodeText(Message.Payload));
    IpcHistoryState: TakeHistoryState(Message);
    IpcPopupBlocked: TellPopupBlocked(DecodeText(Message.Payload));
    IpcZoomChanged:
      begin
        Amount := DecodeReal(Message.Payload);
        TellZoom(ClampZoom(Amount));
      end;
    IpcCursorChanged: PointerShape := LongWord(DecodeNumber(Message.Payload));
    IpcLinkClicked: TakeLinkClicked(Message);
    IpcDownloadRequested: TakeDownload(Message);
    IpcNavigationFailed:
      begin
        DecodeTexts(Message.Payload, Value, Second);
        TellFailure(Value, Second);
      end;
    IpcContextMenu: TakeContextMenu(Message);
    IpcPopupMenu: TakePopupMenu(Message);
    IpcConsoleMessage:
      begin
        DecodeTexts(Message.Payload, Value, Second);
        TellConsole(Value, Second);
      end;
    IpcScriptDialog, IpcConfirmUnload: TakeDialog(Message);
    IpcClipboardWrite: SetClipboardText(DecodeText(Message.Payload));
    IpcClipboardRead: AnswerClipboardRead(Message);
    IpcSelectionChanged: FSelectedText := DecodeText(Message.Payload);
    IpcPageText: FPageText := DecodeText(Message.Payload);
    IpcOpenUrl: TakeOpenUrl(Message);
    IpcScriptInterrupted: NoteScriptInterrupted;
    IpcInputHandled:
      begin
        FFrameInfo.InputHandled := LongWord(DecodeNumber(Message.Payload));
        if FFrameInfo.InputHandled >= FShiftUntilInput then
          FShiftUntilInput := 0;
      end;
    IpcAboutPage: AnswerAboutPage(Message);
    IpcReply:
      if (Message.RequestId = FFindRequestId) and (FFindRequestId <> 0) then
        TakeFindResult(Message)
      else if (Message.RequestId = FPageInfoRequestId) and (FPageInfoRequestId <> 0) then
        TakePageInfo(Message);
  end;
end;

procedure TWebView.TakeSurface(Message: TIpcMessage);
var
  Info: TIpcSurfaceInfo;
begin
  if Length(Message.Handles) < 1 then
    Exit;
  Info := DecodeSurfaceInfo(Message.Payload);
  FreeAndNil(FShared);
  FShared := TSharedSurface.OpenSection(Message.Handles[0], Info.Width, Info.Height, Info.StrideBytes);
  { The section is the surface's now (or closed). }
  Message.Handles[0] := -1;
  if FShared <> nil then
    FSharedId := Info.SurfaceId
  else
    FSharedId := 0;
end;

{ Copies what changed out of the shared surface into the view's own
  picture (the renderer paints the next frame only once told it may),
  and shows it. }
procedure TWebView.TakeFrame(Message: TIpcMessage);
var
  Info: TIpcFrameInfo;
  Damage: TRectangle;
  Canvas: TCanvas;
begin
  Info := DecodeFrameInfo(Message.Payload);
  if (FShared = nil) or (Info.SurfaceId <> FSharedId) or (Info.Width > FShared.Width) or
     (Info.Height > FShared.Height) then
  begin
    SendToProcess(IpcFrameAck, EncodeNumber(LongInt(Info.FrameNumber)));
    Exit;
  end;
  if (FFrame.Width <> Info.Width) or (FFrame.Height <> Info.Height) then
  begin
    FreeSurface(FFrame);
    if not CreateSurface(FFrame, Info.Width, Info.Height, ColorWhite) then
    begin
      SendToProcess(IpcFrameAck, EncodeNumber(LongInt(Info.FrameNumber)));
      Exit;
    end;
    Damage := MakeRectangle(0, 0, Info.Width, Info.Height);
  end
  else
    Damage := MakeRectangle(Max(0, Info.DamageLeft), Max(0, Info.DamageTop),
      Min(Info.Width, Info.DamageRight) - Max(0, Info.DamageLeft),
      Min(Info.Height, Info.DamageBottom) - Max(0, Info.DamageTop));
  if (RectangleWidth(Damage) > 0) and (RectangleHeight(Damage) > 0) then
  begin
    BeginCanvas(Canvas, FFrame);
    DrawSurface(Canvas, FShared.Surface, Damage, Damage.Left, Damage.Top, False, 255);
  end;
  SendToProcess(IpcFrameAck, EncodeNumber(LongInt(Info.FrameNumber)));
  FFrameInfo := Info;
  FHasFrame := True;
  FFrameAt := GetTickCount64;
  { The renderer caught up with the scrolling shown meanwhile. }
  if (FShiftUntilInput = 0) or (Info.InputHandled >= FShiftUntilInput) then
  begin
    if FScrollShift <> 0 then
      Damage := MakeRectangle(0, 0, Info.Width, Info.Height);
    FScrollShift := 0;
    FShiftUntilInput := 0;
  end;
  if (Host <> nil) and (FScrollShift = 0) then
    Host.InvalidatePixels(MakeRectangle(PixelBounds.Left + Damage.Left, PixelBounds.Top + Damage.Top,
      RectangleWidth(Damage), RectangleHeight(Damage)))
  else
    Invalidate;
end;

procedure TWebView.TakeFavicon(Message: TIpcMessage);
var
  Icon: TIpcFavicon;
  Image: TImage;
begin
  Icon := DecodeFavicon(Message.Payload);
  Image := nil;
  if (Icon.Width > 0) and (Icon.Height > 0) then
  begin
    Image := TImage.Create(Icon.Width, Icon.Height);
    Move(Icon.Pixels[0], Image.Line(0)^, Length(Icon.Pixels) * 4);
  end;
  TellFavicon(Image);
end;

procedure TWebView.TakeLinkClicked(Message: TIpcMessage);
var
  LinkUrl: string;
  Number: LongInt;
  Reader: TIpcReader;
  Disposition: TLinkDisposition;
  Handled: Boolean;
begin
  Reader := TIpcReader.Create(Message.Payload);
  try
    LinkUrl := Reader.ReadString;
    Number := Reader.ReadByte;
  finally
    Reader.Free;
  end;
  if Number > Ord(High(TLinkDisposition)) then
    Number := Ord(LinkInView);
  Disposition := TLinkDisposition(Number);
  Handled := False;
  TellLink(LinkUrl, Disposition, Handled);
  { A link for elsewhere nobody took: here, then. }
  if not Handled and (Disposition <> LinkInView) then
    Navigate(LinkUrl);
end;

procedure TWebView.TakeDownload(Message: TIpcMessage);
var
  Reader: TIpcReader;
  Download: TDownloadInfo;
begin
  Reader := TIpcReader.Create(Message.Payload);
  try
    Download.Url := Reader.ReadString;
    Download.MimeType := Reader.ReadString;
    Download.FileName := Reader.ReadString;
  finally
    Reader.Free;
  end;
  TellDownload(Download);
end;

procedure TWebView.TakeContextMenu(Message: TIpcMessage);
var
  Wire: TIpcContextInfo;
  Info: TWebContextInfo;
  Handled: Boolean;
begin
  Wire := DecodeContextInfo(Message.Payload);
  Info.X := Wire.X;
  Info.Y := Wire.Y;
  Info.FromKeyboard := Wire.FromKeyboard;
  Info.LinkUrl := Wire.LinkUrl;
  Info.LinkText := Wire.LinkText;
  Info.ImageUrl := Wire.ImageUrl;
  Info.SelectedText := Wire.SelectedText;
  Info.InTextField := Wire.InTextField;
  Info.BackgroundImageUrl := Wire.BackgroundImageUrl;
  Info.IsEditable := Wire.IsEditable;
  Info.FrameUrl := Wire.FrameUrl;
  Info.CanCopy := Wire.CanCopy;
  FSelectedText := Wire.SelectedText;
  Handled := False;
  if Assigned(FOnContextMenuRequested) then
    FOnContextMenuRequested(Self, Info, Handled);
  if not Handled then
    ShowDefaultMenu(Info);
end;

procedure TWebView.ShowDefaultMenu(constref Info: TWebContextInfo);
var
  Window: TControlWindow;
  Item: TMenuItem;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FDefaultMenu.Free;
  FDefaultMenu := TMenuItem.Create('');
  FDefaultMenuLink := Info.LinkUrl;
  Item := FDefaultMenu.Add('&Back');
  Item.Tag := ViewCommandBack;
  Item.Enabled := CanGoBack;
  Item := FDefaultMenu.Add('&Forward');
  Item.Tag := ViewCommandForward;
  Item.Enabled := CanGoForward;
  Item := FDefaultMenu.Add('&Reload');
  Item.Tag := ViewCommandReload;
  FDefaultMenu.AddSeparator;
  Item := FDefaultMenu.Add('&Copy', nil, 'Ctrl+C');
  Item.Tag := ViewCommandCopy;
  Item.Enabled := Info.SelectedText <> '';
  if Info.LinkUrl <> '' then
  begin
    Item := FDefaultMenu.Add('Copy &Link Address');
    Item.Tag := ViewCommandCopyLink;
  end;
  Item := FDefaultMenu.Add('Select &All', nil, 'Ctrl+A');
  Item.Tag := ViewCommandSelectAll;
  ShowPopupMenu(Window, FDefaultMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Info.X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Info.Y), @DefaultMenuChosen);
end;

procedure TWebView.DefaultMenuChosen(Item: TMenuItem);
begin
  case Item.Tag of
    ViewCommandBack: GoBack;
    ViewCommandForward: GoForward;
    ViewCommandReload: Reload;
    ViewCommandCopy: CopySelection;
    ViewCommandCopyLink: SetClipboardText(FDefaultMenuLink);
    ViewCommandSelectAll: SelectAll;
  end;
end;

procedure TWebView.TakePopupMenu(Message: TIpcMessage);
var
  Menu: TIpcPopupMenu;
  Window: TControlWindow;
  Index: Integer;
  Item: TMenuItem;
begin
  Menu := DecodePopupMenu(Message.Payload);
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FPopupMenu.Free;
  FPopupMenu := TMenuItem.Create('');
  FPopupMenuId := Menu.MenuId;
  for Index := 0 to High(Menu.Items) do
    if Menu.Items[Index].Separator then
      FPopupMenu.AddSeparator
    else
    begin
      Item := FPopupMenu.Add(Menu.Items[Index].Caption, nil, Menu.Items[Index].Shortcut);
      Item.Tag := Menu.Items[Index].Tag;
      Item.Enabled := Menu.Items[Index].Enabled;
      Item.Checked := Menu.Items[Index].Checked;
    end;
  ShowPopupMenu(Window, FPopupMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Menu.X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Menu.Y), @PopupItemChosen);
end;

procedure TWebView.PopupItemChosen(Item: TMenuItem);
begin
  SendToProcess(IpcMenuChosen, EncodeNumbers(LongInt(FPopupMenuId), Item.Tag));
end;

{ A page navigated its window to another site: the view moves there. }
procedure TWebView.TakeOpenUrl(Message: TIpcMessage);
var
  Open: TIpcOpenUrl;
  Handled: Boolean;
begin
  Open := DecodeOpenUrl(Message.Payload);
  if Open.Disposition <> Ord(LinkInView) then
  begin
    Handled := False;
    TellLink(Open.Url, TLinkDisposition(Min(Open.Disposition, Ord(High(TLinkDisposition)))), Handled);
    if Handled then
      Exit;
  end;
  Open.Disposition := Ord(LinkInView);
  NavigateRemote(Open);
end;

procedure TWebView.AnswerAboutPage(Message: TIpcMessage);
var
  Html: string;
  Found: Boolean;
  Writer: TIpcWriter;
begin
  Html := '';
  Found := (FProcess <> nil) and (FProcess.Site = SiteBrowserPages) and Assigned(FAboutPageProvider) and
    FAboutPageProvider(DecodeText(Message.Payload), Html);
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Found);
    Writer.WriteString(Html);
    SendToProcess(IpcReply, Writer.Data, Message.RequestId);
  finally
    Writer.Free;
  end;
end;

procedure TWebView.AnswerClipboardRead(Message: TIpcMessage);
begin
  SendToProcess(IpcReply, EncodeText(ClipboardText), Message.RequestId);
end;

procedure TWebView.RemoteEnded(Crashed: Boolean; ExitCode: LongInt);
var
  Reason: string;
begin
  CloseSheet;
  HideHangBar;
  FProcess := nil;
  FreeAndNil(FShared);
  FSharedId := 0;
  if not Crashed then
    Exit;
  TellProcessEvent('crashed', ExitCode);
  if ExitCode = 137 then
    Reason := 'The page''s process was ended (it stopped responding, or memory ran out).'
  else
    Reason := 'The page''s process ended unexpectedly (status ' + IntToStr(ExitCode) +
      '). Other tabs are not affected.';
  ShowCrashPanel(Reason);
  if FState <> LoadingIdle then
    TellLoadingState(LoadingIdle);
end;

procedure TWebView.RemoteResponsive(Responsive: Boolean);
begin
  if Responsive then
  begin
    TellProcessEvent('responsive', 1);
    HideHangBar;
  end
  else
  begin
    TellProcessEvent('hung', 1);
    if GetTickCount64 >= FHangWaitUntil then
      ShowHangBar('This page is not responding.');
  end;
end;

{ Every quarter second: the size, being shown, a hang bar that Wait put
  off. }
procedure TWebView.StateTimerFired(Sender: TTimer);
begin
  if FProcess = nil then
  begin
    FStateTimer.Enabled := False;
    Exit;
  end;
  SendGeometryIfChanged;
  if FProcess.Hung and (FHangBar = nil) and (FHangWaitUntil <> 0) and (GetTickCount64 >= FHangWaitUntil) then
    ShowHangBar('This page is still not responding.');
end;
