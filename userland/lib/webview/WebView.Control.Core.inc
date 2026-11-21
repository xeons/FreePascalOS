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

{ WebView.Control: the page, its document, the event loop, navigation. }

const
  { Milliseconds of tasks run per turn of the program's message loop. }
  TaskBudgetMilliseconds = 12;
  FrameIntervalMilliseconds = 16;

constructor TWebView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FScriptingEnabled := True;
  FZoom := 1;
  FState := LoadingIdle;
  FSink := TLayoutResourceSink.Create;
  FScriptLayout := TDocumentScriptLayout.Create;
  TDocumentScriptLayout(FScriptLayout).OnScrolled := @ScriptScrolled;
  FTextIndex := TPageTextIndex.Create;
  FFieldEditor := TTextFieldEditor.Create;
  FFieldEditor.OnEdited := @FireInputEvent;
  FFieldEditor.OnSelectionMoved := @FieldSelectionMoved;
  FFieldEditor.OnSubmit := @SubmitImplicitly;
  FFieldEditor.OnReadClipboard := @ReadClipboard;
  FFieldEditor.OnWriteClipboard := @WriteClipboard;
  FSelectionAnchor := TextPosition(-1, 0);
  FSelectionFocus := FSelectionAnchor;
  FVerticalBar := TScrollBar.Create(Self);
  FVerticalBar.Kind := ScrollVertical;
  FVerticalBar.Visible := False;
  FVerticalBar.Step := 40;
  FHorizontalBar := TScrollBar.Create(Self);
  FHorizontalBar.Kind := ScrollHorizontal;
  FHorizontalBar.Visible := False;
  FHorizontalBar.Step := 40;
  FLoopTimer := TTimer.Create(Self);
  FLoopTimer.OnTimer := @LoopTimerFired;
  FFrameTimer := TTimer.Create(Self);
  FFrameTimer.Interval := FrameIntervalMilliseconds;
  FFrameTimer.OnTimer := @FrameTimerFired;
end;

destructor TWebView.Destroy;
begin
  FLoopTimer.Free;
  FFrameTimer.Free;
  if FPage <> nil then
  begin
    FPage.OnWake := nil;
    FPage.OnRenderingRequested := nil;
    FPage.Navigable.ObserverObject := nil;
  end;
  if FExecutor is TPageScriptExecutor then
    TPageScriptExecutor(FExecutor).Shutdown;
  ReleaseDocument;
  FPage.Free;
  FExecutor.Free;
  FObserver.Free;
  FSink.Free;
  FScriptLayout.Free;
  FTextIndex.Free;
  FFieldEditor.Free;
  FFavicon.Free;
  FSelectMenu.Free;
  FOwnMenu.Free;
  FreeSurface(FBacking);
  inherited Destroy;
end;

procedure TWebView.ScriptScrolled;
begin
  UpdateScrollBars;
  InvalidateViewport;
  RequestFrame;
end;

procedure TWebView.EnsurePage;
var
  Factory: TScriptExecutorFactory;
begin
  if FPage <> nil then
    Exit;
  FPage := TWebPage.Create(SharedNetworkContext, FSink, nil);
  FSink.AttachNavigable(FPage.Navigable);
  Factory := FScriptExecutorFactory;
  if not Assigned(Factory) then
    Factory := DefaultScriptExecutorFactory;
  if Assigned(Factory) then
    FExecutor := Factory(Self, FPage)
  else
  begin
    FExecutor := TPageScriptExecutor.Create(FPage.Navigable);
    TPageScriptExecutor(FExecutor).Environment.UserAgentText := WebViewUserAgent;
    TPageScriptExecutor(FExecutor).Environment.LocalStorage := SharedLocalStorage;
    TPageScriptExecutor(FExecutor).Environment.Layout := TDocumentScriptLayout(FScriptLayout);
    TPageScriptExecutor(FExecutor).OnAlert := @ScriptAlert;
    TPageScriptExecutor(FExecutor).OnConfirm := @ScriptConfirm;
    TPageScriptExecutor(FExecutor).OnPrompt := @ScriptPrompt;
    TPageScriptExecutor(FExecutor).OnConsoleMessage := @ScriptConsole;
  end;
  if FScriptingEnabled then
    FPage.Navigable.Executor := FExecutor;
  FObserver := TViewObserver.Create;
  TViewObserver(FObserver).View := Self;
  FPage.Navigable.ObserverObject := FObserver;
  FPage.OnWake := @PageWake;
  FPage.OnRenderingRequested := @RenderingRequested;
  AdoptDocument(FPage.Navigable.ActiveDocument);
end;

function TWebView.GetNavigable: TNavigable;
begin
  EnsurePage;
  Result := FPage.Navigable;
end;

{ Element pointers die with their document: drop every one held. }
procedure TWebView.ForgetElements;
var
  Index: Integer;
begin
  for Index := 0 to High(FHoverChain) do
    FHoverChain[Index].Release;
  FHoverChain := nil;
  for Index := 0 to High(FActiveChain) do
    FActiveChain[Index].Release;
  FActiveChain := nil;
  if FFocusedElement <> nil then
    FFocusedElement.Release;
  FFocusedElement := nil;
  if FPressedLink <> nil then
    FPressedLink.Release;
  FPressedLink := nil;
  if FPressedControl <> nil then
    FPressedControl.Release;
  FPressedControl := nil;
  if FPressedTarget <> nil then
    FPressedTarget.Release;
  FPressedTarget := nil;
  if FSelectElement <> nil then
    FSelectElement.Release;
  FSelectElement := nil;
  if FPendingFragment <> nil then
    FPendingFragment.Release;
  FPendingFragment := nil;
  FHasPendingFragment := False;
end;

procedure TWebView.ReleaseDocument;
begin
  ForgetElements;
  FTextIndex.Clear;
  FTextIndexValid := False;
  FSelectionAnchor := TextPosition(-1, 0);
  FSelectionFocus := FSelectionAnchor;
  TDocumentScriptLayout(FScriptLayout).Layout := nil;
  TDocumentScriptLayout(FScriptLayout).Painter := nil;
  FreeAndNil(FPainter);
  FreeAndNil(FLayout);
  if (FDocument <> nil) and (FDocumentObserver <> nil) then
    FDocument.RemoveObserver(FDocumentObserver);
  FreeAndNil(FDocumentObserver);
  if FDocument <> nil then
  begin
    FSink.DocumentGoing(FDocument);
    FreeDocumentResources(FDocument);
  end;
  FDocument := nil;
  FBackingValid := False;
  FFixedChecked := False;
end;

procedure TWebView.AdoptDocument(Document: TDocument);
begin
  if Document = FDocument then
    Exit;
  ReleaseDocument;
  FHasPendingRestore := False;
  SetStatus('');
  FDocument := Document;
  if Document = nil then
    Exit;
  FSink.PrepareDocument(Document);
  FDocumentObserver := TViewDocumentObserver.Create;
  TViewDocumentObserver(FDocumentObserver).View := Self;
  Document.AddObserver(FDocumentObserver);
  FLayout := TDocumentLayout.Create(Document);
  FPainter := TDocumentPainter.Create(FLayout);
  TDocumentScriptLayout(FScriptLayout).Layout := FLayout;
  TDocumentScriptLayout(FScriptLayout).Painter := FPainter;
  ApplyViewport;
  RequestFrame;
  InvalidateViewport;
end;

{ ---- the event loop ---- }

{ Any thread: the page has work. }
procedure TWebView.PageWake(Sender: TObject);
begin
  PostWake;
end;

procedure TWebView.PostWake;
begin
  if InterlockedExchange(FWakePending, 1) = 0 then
    if not PostMessage(Self, MessageWebViewWake) then
      FWakePending := 0;
end;

procedure TWebView.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageWebViewWake then
  begin
    FWakePending := 0;
    PumpEventLoop;
    Exit;
  end;
  if (Message.Code = MessageNotify) and ((TControl(Message.Parameter1) = FVerticalBar) or
     (TControl(Message.Parameter1) = FHorizontalBar)) then
  begin
    if Message.Parameter2 = NotifyChanged then
      ScrollBarMoved(TScrollBar(Message.Parameter1));
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TWebView.PumpEventLoop;
var
  Delay: Double;
begin
  if FPage = nil then
    Exit;
  if FModalDepth > 0 then
  begin
    { A script waits for a prompt's answer: come back when it is given. }
    FLoopTimer.Interval := 50;
    FLoopTimer.Enabled := True;
    Exit;
  end;
  FPage.ProcessPendingWork(TaskBudgetMilliseconds);
  if FPage.Loop.HasReadyTask then
    PostWake;
  Delay := FPage.MillisecondsUntilNextTimer;
  if Delay >= 0 then
  begin
    FLoopTimer.Interval := Max(1, Ceil(Delay));
    FLoopTimer.Enabled := True;
  end
  else
    FLoopTimer.Enabled := False;
  RequestFrame;
end;

procedure TWebView.LoopTimerFired(Sender: TTimer);
begin
  FLoopTimer.Enabled := False;
  PumpEventLoop;
end;

procedure TWebView.RenderingRequested(Sender: TObject);
begin
  RequestFrame;
end;

{ A frame soon: something changed (input, a task, a layout). A frame
  put off by RequestAnimationFrame is brought forward. }
procedure TWebView.RequestFrame;
begin
  if FFrameTimer.Enabled and (FFrameTimer.Interval = FrameIntervalMilliseconds) then
    Exit;
  FFrameTimer.Interval := FrameIntervalMilliseconds;
  FFrameTimer.Enabled := True;
end;

{ The next frame of running CSS animations: no sooner than twice what the
  last frame and paint cost, so the animations take at most half the GUI
  thread on a slow machine or a heavy page. }
procedure TWebView.RequestAnimationFrame;
begin
  if FFrameTimer.Enabled then
    Exit;
  FFrameTimer.Interval := Max(FrameIntervalMilliseconds, 2 * (FFrameCost + FPaintCost));
  FFrameTimer.Enabled := True;
end;

procedure TWebView.FrameTimerFired(Sender: TTimer);
begin
  FFrameTimer.Enabled := False;
  RenderFrame;
end;

procedure TWebView.RenderFrame;
var
  Started: QWord;
begin
  if (FPage = nil) or (FModalDepth > 0) then
    Exit;
  Started := GetTickCount64;
  try
    RenderFrameSteps;
  finally
    FFrameCost := GetTickCount64 - Started;
  end;
  { Running CSS animations get their next frame, paced by what this one
    cost. }
  if (FLayout <> nil) and FLayout.AnimationsRunning and HasRoom then
    RequestAnimationFrame;
end;

procedure TWebView.RenderFrameSteps;
begin
  FPage.RenderingOpportunity;
  if FLayout = nil then
    Exit;
  { A hidden view (a tab in the background) lays out when it is shown
    and has its size: Layout asks for a frame then. }
  if not HasRoom then
    Exit;
  { CSS animations and transitions move on with each frame. }
  if FLayout.AnimationsRunning then
    FLayout.AdvanceAnimations;
  UpdateLayout;
  QueueAnimationEvents(FPage.Loop, FDocument, FLayout.TakeAnimationEvents);
  ApplyPendingScroll;
  if not FBackingValid or (FLayout.PaintVersion <> FBackingVersion) then
    InvalidateViewport;
  { Tasks the frame queued (animation frame callbacks, events). }
  if FPage.Loop.HasReadyTask then
    PostWake;
end;

{ ---- geometry ---- }

function TWebView.DeviceScale: Double;
begin
  Result := DeviceScaleFor(Scaled(1000) / 1000, FZoom);
end;

function TWebView.ViewportPixelWidth: LongInt;
begin
  Result := RectangleWidth(PixelBounds);
  if FVerticalBar.Visible then
    Dec(Result, RectangleWidth(FVerticalBar.PixelBounds));
  if Result < 1 then
    Result := 1;
end;

function TWebView.ViewportPixelHeight: LongInt;
begin
  Result := RectangleHeight(PixelBounds);
  if FHorizontalBar.Visible then
    Dec(Result, RectangleHeight(FHorizontalBar.PixelBounds));
  if Result < 1 then
    Result := 1;
end;

function TWebView.ViewportCssWidth: Double;
begin
  Result := ViewportPixelWidth / DeviceScale;
end;

function TWebView.ViewportCssHeight: Double;
begin
  Result := ViewportPixelHeight / DeviceScale;
end;

function TWebView.HasRoom: Boolean;
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
  Result := (RectangleWidth(PixelBounds) > 1) and (RectangleHeight(PixelBounds) > 1);
end;

procedure TWebView.ApplyViewport;
begin
  if not HasRoom then
    Exit;
  FSink.SetViewport(ViewportCssWidth, ViewportCssHeight, DeviceScale);
  if FLayout <> nil then
    FLayout.SetViewport(ViewportCssWidth, ViewportCssHeight, DeviceScale);
end;

const
  { Layouts quicker than this always run at once. }
  QuickLayoutMilliseconds = 25;

{ Whether a layout may run now: a slow one (a long page loading on a slow
  machine) waits until the GUI had twice its time to itself since the
  last, so input and painting go on between them. }
function TWebView.LayoutDue: Boolean;
begin
  Result := (FLayoutCost < QuickLayoutMilliseconds) or (GetTickCount64 - FLayoutDoneAt >= 2 * FLayoutCost);
end;

{ Lays the page out, and again if the scroll bars came or went. Unless
  Force, a layout that is not due (LayoutDue) is left for a later frame:
  what is shown and hit tested meanwhile is the last layout. }
procedure TWebView.UpdateLayout(Force: Boolean);
var
  Started: QWord;
begin
  if (FLayout = nil) or not HasRoom then
    Exit;
  if not Force and FLayout.NeedsUpdate and not LayoutDue then
  begin
    RequestFrame;
    Exit;
  end;
  Started := GetTickCount64;
  try
    UpdateLayoutRounds;
  finally
    FLayoutDoneAt := GetTickCount64;
    FLayoutCost := FLayoutDoneAt - Started;
  end;
end;

procedure TWebView.UpdateLayoutRounds;
var
  Round_: Integer;
  HadVertical, HadHorizontal: Boolean;
begin
  for Round_ := 1 to 3 do
  begin
    ApplyViewport;
    if FLayout.NeedsUpdate then
      FLayout.Update;
    HadVertical := FVerticalBar.Visible;
    HadHorizontal := FHorizontalBar.Visible;
    UpdateScrollBars;
    if (HadVertical = FVerticalBar.Visible) and (HadHorizontal = FHorizontalBar.Visible) then
      Break;
    { The bars take room: place them now, the viewport is narrower. }
    Layout;
  end;
end;

procedure TWebView.Layout;
begin
  inherited Layout;
  ApplyViewport;
  RequestFrame;
  InvalidateViewport;
end;

{ The scroll bars along the right and bottom edges (the theme's width). }
procedure TWebView.PlaceChildren(const Area: TRectangle);
var
  BarWidth, BottomRoom, RightRoom: LongInt;
begin
  BarWidth := Scaled(Theme.ScrollBarWidth);
  BottomRoom := 0;
  RightRoom := 0;
  if FHorizontalBar.Visible then
    BottomRoom := BarWidth;
  if FVerticalBar.Visible then
    RightRoom := BarWidth;
  if FVerticalBar.Visible then
    PlaceChild(FVerticalBar, MakeRectangle(Area.Right - BarWidth, Area.Top, BarWidth,
      RectangleHeight(Area) - BottomRoom));
  if FHorizontalBar.Visible then
    PlaceChild(FHorizontalBar, MakeRectangle(Area.Left, Area.Bottom - BarWidth, RectangleWidth(Area) - RightRoom,
      BarWidth));
end;

{ ---- navigation ---- }

function TWebView.Navigate(const Address: string): Boolean;
var
  ScrollX, ScrollY: Single;
begin
  EnsurePage;
  if FLayout <> nil then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    FPage.Navigable.SaveScrollPosition(ScrollX, ScrollY);
  end;
  Result := FPage.NavigateTo(Address);
  PostWake;
end;

procedure TWebView.LoadHtml(const Html, BaseUrl: string);
var
  Base: TUrlRecord;
begin
  EnsurePage;
  if not ParseUrl(BaseUrl, Base) then
    ParseUrl('about:blank', Base);
  FPage.Navigable.LoadHtml(Html, Base);
  PostWake;
end;

procedure TWebView.GoBack;
begin
  EnsurePage;
  FPage.Navigable.Back;
  PostWake;
end;

procedure TWebView.GoForward;
begin
  EnsurePage;
  FPage.Navigable.Forward;
  PostWake;
end;

procedure TWebView.Reload(BypassCache: Boolean);
begin
  EnsurePage;
  FPage.Navigable.Reload(BypassCache);
  PostWake;
end;

procedure TWebView.Stop;
begin
  if FPage = nil then
    Exit;
  FPage.Navigable.Stop;
  PostWake;
end;

function TWebView.GetCanGoBack: Boolean;
begin
  Result := (FPage <> nil) and FPage.Navigable.History.CanGoBack;
end;

function TWebView.GetCanGoForward: Boolean;
begin
  Result := (FPage <> nil) and FPage.Navigable.History.CanGoForward;
end;

{ ---- zoom ---- }

procedure TWebView.SetZoom(Value: Double);
var
  ScrollX, ScrollY: Single;
  Ratio: Double;
begin
  Value := ClampZoom(Value);
  if Abs(Value - FZoom) < 0.0001 then
    Exit;
  { Keep the same part of the page at the top. }
  ScrollX := 0;
  ScrollY := 0;
  Ratio := 0;
  if FLayout <> nil then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    if FLayout.DocumentHeight > 0 then
      Ratio := ScrollY / FLayout.DocumentHeight;
  end;
  FZoom := Value;
  ApplyViewport;
  if FLayout <> nil then
  begin
    UpdateLayout(True);
    ScrollViewportTo(ScrollX, Ratio * FLayout.DocumentHeight);
  end;
  InvalidateViewport;
  if Assigned(FOnZoomChanged) then
    FOnZoomChanged(Self);
end;

procedure TWebView.ZoomIn;
begin
  SetZoom(ZoomedIn(FZoom));
end;

procedure TWebView.ZoomOut;
begin
  SetZoom(ZoomedOut(FZoom));
end;

procedure TWebView.ResetZoom;
begin
  SetZoom(1);
end;

{ ---- what the navigable tells ---- }

procedure TWebView.NavigableLocationChanged(const Url: string);
begin
  FUrl := Url;
  if Assigned(FOnLocationChanged) then
    FOnLocationChanged(Self, Url);
end;

procedure TWebView.NavigableTitleChanged(const Title: string);
begin
  FTitle := Title;
  if Assigned(FOnTitleChanged) then
    FOnTitleChanged(Self, Title);
end;

procedure TWebView.NavigableLoadingStateChanged(State: TLoadingState);
begin
  FState := State;
  if Assigned(FOnLoadingStateChanged) then
    FOnLoadingStateChanged(Self, State);
  RequestFrame;
end;

procedure TWebView.NavigableFaviconChanged(Image: TImage);
begin
  FFavicon.Free;
  FFavicon := Image;
  if Assigned(FOnFaviconChanged) then
    FOnFaviconChanged(Self);
end;

procedure TWebView.NavigableHistoryChanged;
begin
  if Assigned(FOnHistoryChanged) then
    FOnHistoryChanged(Self);
end;

procedure TWebView.NavigableScrollToFragment(Element: TElement);
begin
  if FPendingFragment <> nil then
    FPendingFragment.Release;
  FPendingFragment := Element;
  if Element <> nil then
    Element.Retain;
  FHasPendingFragment := True;
  RequestFrame;
end;

procedure TWebView.NavigableRestoreScrollPosition(X, Y: Double);
begin
  FHasPendingRestore := True;
  FPendingRestoreX := X;
  FPendingRestoreY := Y;
  RequestFrame;
end;

function TWebView.NavigableConfirmUnload: Boolean;
begin
  if Assigned(FOnConfirmUnload) then
    Result := FOnConfirmUnload(Self)
  else
    Result := True;
end;

procedure TWebView.NavigableDownloadRequested(constref Download: TDownloadInfo);
begin
  if Assigned(FOnDownloadRequested) then
    FOnDownloadRequested(Self, Download);
end;

procedure TWebView.NavigableFailed(const Url, Reason: string);
begin
  if Assigned(FOnNavigationFailed) then
    FOnNavigationFailed(Self, Url, Reason);
end;

{ ---- scripting ---- }

procedure TWebView.SetScriptingEnabled(Value: Boolean);
begin
  FScriptingEnabled := Value;
  if FPage = nil then
    Exit;
  if Value then
    FPage.Navigable.Executor := FExecutor
  else
    FPage.Navigable.Executor := nil;
end;

procedure TWebView.ScriptAlert(const Message: string);
begin
  if not Assigned(FOnScriptAlert) then
    Exit;
  Inc(FModalDepth);
  try
    FOnScriptAlert(Self, Message);
  finally
    Dec(FModalDepth);
  end;
end;

function TWebView.ScriptConfirm(const Message: string): Boolean;
begin
  Result := False;
  if not Assigned(FOnScriptConfirm) then
    Exit;
  Inc(FModalDepth);
  try
    Result := FOnScriptConfirm(Self, Message);
  finally
    Dec(FModalDepth);
  end;
end;

function TWebView.ScriptPrompt(const Message, Default: string; out Answer: string): Boolean;
begin
  Result := False;
  Answer := '';
  if not Assigned(FOnScriptPrompt) then
    Exit;
  Inc(FModalDepth);
  try
    Result := FOnScriptPrompt(Self, Message, Default, Answer);
  finally
    Dec(FModalDepth);
  end;
end;

procedure TWebView.ScriptConsole(const Level, Line: string);
begin
  if Assigned(FOnConsoleMessage) then
    FOnConsoleMessage(Self, Level, Line);
end;
