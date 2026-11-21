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

{ WebView.Engine: scrolling the viewport and the page's scroll containers. }

const
  { CSS pixels a wheel step scrolls. }
  WheelStep = 60;

procedure TWebEngineView.UpdateScrollBars;
var
  DocumentWidth, DocumentHeight, ViewWidth, ViewHeight: Double;
  ScrollX, ScrollY: Single;
  NeedVertical, NeedHorizontal: Boolean;
begin
  if FLayout = nil then
  begin
    FVerticalBar.Visible := False;
    FHorizontalBar.Visible := False;
    Exit;
  end;
  DocumentWidth := FLayout.DocumentWidth;
  DocumentHeight := FLayout.DocumentHeight;
  ViewWidth := ViewportCssWidth;
  ViewHeight := ViewportCssHeight;
  NeedVertical := DocumentHeight > ViewHeight + 1;
  NeedHorizontal := DocumentWidth > ViewWidth + 1;
  if NeedVertical <> FVerticalBar.Visible then
    FVerticalBar.Visible := NeedVertical;
  if NeedHorizontal <> FHorizontalBar.Visible then
    FHorizontalBar.Visible := NeedHorizontal;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  FSyncingBars := True;
  try
    if NeedVertical then
    begin
      FVerticalBar.SetRange(0, Ceil(DocumentHeight), Max(1, Floor(ViewHeight)));
      FVerticalBar.Position := Round(ScrollY);
    end;
    if NeedHorizontal then
    begin
      FHorizontalBar.SetRange(0, Ceil(DocumentWidth), Max(1, Floor(ViewWidth)));
      FHorizontalBar.Position := Round(ScrollX);
    end;
  finally
    FSyncingBars := False;
  end;
end;

procedure TWebEngineView.ScrollBarMoved(Bar: TScrollBar);
var
  ScrollX, ScrollY: Single;
begin
  if FSyncingBars or (FLayout = nil) then
    Exit;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  if Bar = FVerticalBar then
    ScrollViewportTo(ScrollX, Bar.Position)
  else
    ScrollViewportTo(Bar.Position, ScrollY);
end;

{ Moves the backing surface's rows by Delta (positive: the content goes
  up) and marks the rows that came into view. }
procedure ShiftSurfaceRows(var Surface: TSurface; Delta: LongInt; var Dirty: TRectangle);
var
  Row, RowBytes: LongInt;
begin
  RowBytes := Surface.Width * SizeOf(LongWord);
  if Delta > 0 then
  begin
    for Row := 0 to Surface.Height - Delta - 1 do
      Move(SurfaceLine(Surface, Row + Delta)^, SurfaceLine(Surface, Row)^, RowBytes);
    Dirty := MakeRectangle(0, Surface.Height - Delta, Surface.Width, Delta);
  end
  else
  begin
    for Row := Surface.Height - 1 downto -Delta do
      Move(SurfaceLine(Surface, Row + Delta)^, SurfaceLine(Surface, Row)^, RowBytes);
    Dirty := MakeRectangle(0, 0, Surface.Width, -Delta);
  end;
end;

procedure TWebEngineView.ScrollViewportTo(X, Y: Double);
var
  OldX, OldY, NewX, NewY: Single;
  Pixels: Double;
  CanShift: Boolean;
begin
  if FLayout = nil then
    Exit;
  FLayout.GetScrollOffset(nil, OldX, OldY);
  CanShift := FBackingValid and (FBacking.Pixels <> nil) and (FBackingVersion = FLayout.PaintVersion) and
    RectangleIsEmpty(FBackingDirty) and not PageHasFixedBoxes;
  FLayout.SetScrollOffset(nil, X, Y);
  FLayout.GetScrollOffset(nil, NewX, NewY);
  if (NewX = OldX) and (NewY = OldY) then
    Exit;
  if CanShift and (NewX = OldX) then
  begin
    Pixels := (NewY - OldY) * DeviceScale;
    if (Abs(Pixels - Round(Pixels)) < 0.001) and (Abs(Round(Pixels)) < FBacking.Height) then
    begin
      ShiftSurfaceRows(FBacking, Round(Pixels), FBackingDirty);
      FBackingVersion := FLayout.PaintVersion;
    end;
  end;
  if FPage <> nil then
    FPage.Navigable.SaveScrollPosition(NewX, NewY);
  UpdateScrollBars;
  InvalidateViewport;
end;

procedure TWebEngineView.ScrollBy(DeltaX, DeltaY: Double);
var
  ScrollX, ScrollY: Single;
begin
  if FLayout = nil then
    Exit;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  ScrollViewportTo(ScrollX + DeltaX, ScrollY + DeltaY);
end;

procedure TWebEngineView.ScrollTo(X, Y: Double);
begin
  ScrollViewportTo(X, Y);
end;

{ The innermost scroll container under the point that can still move
  that way takes the scroll. }
function TWebEngineView.ScrollInnerContainer(CssX, CssY, DeltaX, DeltaY: Double): Boolean;
var
  Hit: THitTestResult;
begin
  Result := False;
  if FPainter = nil then
    Exit;
  { Frames under the pointer first (their containers, their viewports). }
  if ScrollThroughFrames(CssX, CssY, DeltaX, DeltaY) then
    Exit(True);
  Hit := FPainter.HitTest(CssX, CssY);
  Result := ScrollBoxChain(FLayout, Hit.Box, DeltaX, DeltaY);
end;

{ The innermost scroll container from Box up that can move that way. }
function TWebEngineView.ScrollBoxChain(DocumentLayout: TDocumentLayout; Box: TLayoutBox; DeltaX, DeltaY: Double): Boolean;
var
  ClientWidth, ClientHeight, TargetX, TargetY: Single;
begin
  Result := False;
  if DocumentLayout = nil then
    Exit;
  while Box <> nil do
  begin
    if (bfScrollContainer in Box.Flags) and (Box.Kind <> bkViewport) and (Box.Node <> nil) then
    begin
      ClientWidth := Box.Width - Box.Border[sideLeft] - Box.Border[sideRight];
      ClientHeight := Box.Height - Box.Border[sideTop] - Box.Border[sideBottom];
      TargetX := EnsureRange(Box.ScrollX + DeltaX, 0, Max(0, Box.ScrollWidth - ClientWidth));
      TargetY := EnsureRange(Box.ScrollY + DeltaY, 0, Max(0, Box.ScrollHeight - ClientHeight));
      if (TargetX <> Box.ScrollX) or (TargetY <> Box.ScrollY) then
      begin
        DocumentLayout.SetScrollOffset(Box.Node, TargetX, TargetY);
        InvalidateViewport;
        Exit(True);
      end;
    end;
    Box := Box.Parent;
  end;
end;

function TWebEngineView.GetScrollState(out ScrollX, ScrollY, DocumentWidth, DocumentHeight: Double;
  out ViewportWidth, ViewportHeight: LongInt; out HasFixedBoxes: Boolean): Boolean;
var
  OffsetX, OffsetY: Single;
  Scale: Double;
begin
  ScrollX := 0;
  ScrollY := 0;
  DocumentWidth := 0;
  DocumentHeight := 0;
  ViewportWidth := ViewportPixelWidth;
  ViewportHeight := ViewportPixelHeight;
  HasFixedBoxes := False;
  if FLayout = nil then
    Exit(False);
  Scale := DeviceScale;
  FLayout.GetScrollOffset(nil, OffsetX, OffsetY);
  ScrollX := OffsetX * Scale;
  ScrollY := OffsetY * Scale;
  DocumentWidth := FLayout.DocumentWidth * Scale;
  DocumentHeight := FLayout.DocumentHeight * Scale;
  HasFixedBoxes := PageHasFixedBoxes;
  Result := True;
end;

procedure TWebEngineView.Wheel(Steps: LongInt);
var
  CssX, CssY, Delta: Double;
begin
  if (HeldModifiers and ModifierControl) <> 0 then
  begin
    if Steps > 0 then
      ZoomIn
    else if Steps < 0 then
      ZoomOut;
    Exit;
  end;
  if FLayout = nil then
    Exit;
  Delta := -Steps * WheelStep;
  CssX := FLastPointerX / DeviceScale;
  CssY := FLastPointerY / DeviceScale;
  if (HeldModifiers and ModifierShift) <> 0 then
  begin
    if not ScrollInnerContainer(CssX, CssY, Delta, 0) then
      ScrollBy(Delta, 0);
  end
  else if not ScrollInnerContainer(CssX, CssY, 0, Delta) then
    ScrollBy(0, Delta);
  { Scrolled while dragging a selection: its focus follows the text now
    under the pointer. }
  if FSelecting and FDragged and (FPressButton = ButtonLeft) then
    ExtendSelectionTo(FLastPointerX, FLastPointerY);
end;

procedure TWebEngineView.ScrollRectangleIntoView(X, Y, Width, Height: Double);
var
  ScrollX, ScrollY: Single;
  ViewWidth, ViewHeight, TargetX, TargetY, Margin: Double;
begin
  if FLayout = nil then
    Exit;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  ViewWidth := ViewportCssWidth;
  ViewHeight := ViewportCssHeight;
  Margin := Min(40, ViewHeight / 4);
  TargetX := ScrollX;
  TargetY := ScrollY;
  if Y < ScrollY + Margin then
    TargetY := Y - Margin
  else if Y + Height > ScrollY + ViewHeight - Margin then
    TargetY := Y + Height - ViewHeight + Margin;
  if X < ScrollX then
    TargetX := X
  else if X + Width > ScrollX + ViewWidth then
    TargetX := X + Width - ViewWidth;
  ScrollViewportTo(TargetX, TargetY);
end;

procedure TWebEngineView.ScrollToElement(Element: TElement);
var
  X, Y, Width, Height: Single;
begin
  if (FLayout <> nil) and FLayout.NodeBounds(Element, X, Y, Width, Height) then
    ScrollRectangleIntoView(X, Y, Width, Height);
end;

procedure TWebEngineView.ApplyPendingScroll;
var
  X, Y, Width, Height: Single;
begin
  if FLayout = nil then
    Exit;
  if FHasPendingFragment then
  begin
    if FPendingFragment = nil then
    begin
      ScrollViewportTo(0, 0);
      FHasPendingFragment := False;
    end
    else if FLayout.NodeBounds(FPendingFragment, X, Y, Width, Height) then
    begin
      ScrollViewportTo(0, Y);
      FHasPendingFragment := False;
      FPendingFragment.Release;
      FPendingFragment := nil;
    end;
  end;
  if FHasPendingRestore then
    if (FLayout.DocumentHeight >= FPendingRestoreY + ViewportCssHeight) or (FState = LoadingComplete) then
    begin
      ScrollViewportTo(FPendingRestoreX, FPendingRestoreY);
      FHasPendingRestore := False;
    end;
end;
