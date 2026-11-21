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

{ WebView.Engine: painting through the backing surface. }

const
  SelectionAlpha = 110;
  InnerBarThickness = 6;

procedure TWebEngineView.InvalidateViewport;
begin
  Invalidate;
end;

{ The backing surface has the viewport's size; a new one is painted
  whole. }
procedure TWebEngineView.EnsureBacking;
var
  Width, Height: LongInt;
begin
  Width := ViewportPixelWidth;
  Height := ViewportPixelHeight;
  if (FBacking.Pixels <> nil) and (FBacking.Width = Width) and (FBacking.Height = Height) then
    Exit;
  FreeSurface(FBacking);
  if not CreateSurface(FBacking, Width, Height, ColorWhite) then
    FBacking := Default(TSurface);
  FBackingValid := False;
end;

function TWebEngineView.PageHasFixedBoxes: Boolean;
var
  Index: Integer;
  List: TDisplayList;
begin
  if FPainter = nil then
    Exit(False);
  FPainter.Refresh;
  if FFixedChecked and (FFixedCheckedVersion = FPainter.BuiltVersion) then
    Exit(FListHasFixed);
  List := FPainter.DisplayList;
  FListHasFixed := False;
  for Index := 0 to List.Count - 1 do
    if List.Items[Index].Kind in [diPushFixed, diPushSticky] then
    begin
      FListHasFixed := True;
      Break;
    end;
  FFixedChecked := True;
  FFixedCheckedVersion := FPainter.BuiltVersion;
  Result := FListHasFixed;
end;

{ Paints what is out of date into the backing surface. }
procedure TWebEngineView.PaintBacking;
var
  Whole: TRectangle;
  BackingCanvas: TCanvas;
begin
  EnsureBacking;
  if FBacking.Pixels = nil then
    Exit;
  Whole := MakeRectangle(0, 0, FBacking.Width, FBacking.Height);
  if (FLayout = nil) or (FPainter = nil) then
  begin
    BeginCanvas(BackingCanvas, FBacking);
    FillRectangle(BackingCanvas, Whole, ColorWhite);
    Exit;
  end;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  if not FBackingValid or (FBackingVersion <> FLayout.PaintVersion) then
  begin
    FBackingDirty := Whole;
    FBackingVersion := FLayout.PaintVersion;
    FBackingValid := True;
  end;
  if RectangleIsEmpty(FBackingDirty) then
    Exit;
  FPainter.Paint(FBacking, FBackingDirty);
  FBackingDirty := MakeRectangle(0, 0, 0, 0);
end;

procedure TWebEngineView.Paint(var Canvas: TCanvas);
var
  Overlay: TCanvas;
  Width, Height: LongInt;
  Corner: TRectangle;
  Started: QWord;
begin
  Started := GetTickCount64;
  { The square between the two scroll bars. }
  if FVerticalBar.Visible and FHorizontalBar.Visible then
  begin
    Width := RectangleWidth(PixelBounds);
    Height := RectangleHeight(PixelBounds);
    Corner := MakeRectangle(ViewportPixelWidth, ViewportPixelHeight, Width - ViewportPixelWidth,
      Height - ViewportPixelHeight);
    FillRectangle(Canvas, Corner, Theme.Face);
  end;
  PaintBacking;
  if FBacking.Pixels <> nil then
    DrawSurface(Canvas, FBacking, MakeRectangle(0, 0, FBacking.Width, FBacking.Height), 0, 0, False, AlphaOpaque);
  { The overlays stay within the viewport, on a canvas of their own
    (the one given goes on to the scroll bars). }
  Overlay := Canvas;
  CopyRegion(Canvas.Clip, Overlay.Clip);
  NarrowCanvasClip(Overlay, MakeRectangle(0, 0, ViewportPixelWidth, ViewportPixelHeight));
  PaintSelection(Overlay);
  PaintCaret(Overlay);
  PaintInnerScrollBars(Overlay);
  FPaintCost := GetTickCount64 - Started;
end;

procedure TWebEngineView.PaintSelection(var Canvas: TCanvas);
var
  Rectangles: TTextRectangleArray;
  Index: Integer;
  Scale: Double;
  ScrollX, ScrollY: Single;
  OffsetX, OffsetY: Double;
  Area: TRectangle;
begin
  if FLayout = nil then
    Exit;
  if FSelectionFromDocument then
  begin
    EnsureTextIndex;
    PullSelectionFromDocument;
  end;
  if (FSelectionAnchor.Run < 0) or (TPageTextIndex.Compare(FSelectionAnchor, FSelectionFocus) = 0) then
    Exit;
  EnsureTextIndex;
  Rectangles := FTextIndex.RangeRectangles(FSelectionAnchor, FSelectionFocus);
  Scale := DeviceScale;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  for Index := 0 to High(Rectangles) do
  begin
    OffsetX := ScrollX;
    OffsetY := ScrollY;
    if Rectangles[Index].Fixed then
    begin
      OffsetX := 0;
      OffsetY := 0;
    end;
    Area.Left := Floor((Rectangles[Index].X - OffsetX) * Scale);
    Area.Top := Floor((Rectangles[Index].Y - OffsetY) * Scale);
    Area.Right := Ceil((Rectangles[Index].X + Rectangles[Index].Width - OffsetX) * Scale);
    Area.Bottom := Ceil((Rectangles[Index].Y + Rectangles[Index].Height - OffsetY) * Scale);
    FillRectangle(Canvas, Area, WithAlpha(Theme.Selection, SelectionAlpha));
  end;
end;

{ A text field with the focus shows its caret where its selection's
  focus is (on its line in a text area). }
procedure TWebEngineView.PaintCaret(var Canvas: TCanvas);
var
  Box: TLayoutBox;
  BoxX, BoxY, TextWidth, LineHeight, LineTop: Single;
  ScrollX, ScrollY: Single;
  Scale: Double;
  Value, Before, Direction: string;
  Left, Top, Bottom: LongInt;
  Font: TTextFont;
  Kind: TFormControlKind;
  Start, Finish, Caret, LineIndex, Index: Integer;
  TargetLayout: TDocumentLayout;
  OriginX, OriginY: Single;
begin
  if (FLayout = nil) or (FFocusedElement = nil) or not Focused then
    Exit;
  Kind := FormControlKindOf(FFocusedElement);
  if not (Kind in [FormControlText, FormControlPassword, FormControlTextArea]) then
    Exit;
  { A field in a frame: its document's layout, at its frame's place. }
  if not DocumentViewportOrigin(FLayout, FFocusedElement.NodeDocument, OriginX, OriginY, TargetLayout) then
    Exit;
  Box := TargetLayout.BoxOf(FFocusedElement);
  if Box = nil then
    Exit;
  Box.AbsolutePosition(BoxX, BoxY);
  Value := ControlValue(FFocusedElement);
  GetTextSelection(FFocusedElement, Start, Finish, Direction);
  if Direction = 'backward' then
    Caret := Start
  else
    Caret := Finish;
  Before := Copy(Value, 1, ByteIndexOfUtf16(Value, Caret) - 1);
  LineIndex := 0;
  if Kind = FormControlTextArea then
  begin
    for Index := 1 to Length(Before) do
      if Before[Index] = #10 then
        Inc(LineIndex);
    if LastDelimiter(#10, Before) > 0 then
      Before := Copy(Before, LastDelimiter(#10, Before) + 1, MaxInt);
  end
  else if Kind = FormControlPassword then
    Before := StringOfChar('*', Utf16CountOf(Before));
  Font := TextFontOf(Box.Style);
  TextWidth := 0;
  if Before <> '' then
    TextWidth := Font.MeasureText(Before, 1, Length(Before));
  { Where the painter puts the text (Web.Paint.Raster's DrawControlText):
    a field's line centred in its content box, a text area's lines from
    its top. }
  LineHeight := Font.Ascent + Font.Descent;
  if Kind = FormControlTextArea then
    LineTop := LineIndex * LineHeight
  else
    LineTop := (Box.ContentHeight - LineHeight) / 2;
  TargetLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  ScrollX := ScrollX - OriginX;
  ScrollY := ScrollY - OriginY;
  Scale := DeviceScale;
  Left := Round((BoxX + Box.ContentLeft + Min(TextWidth, Box.ContentWidth) - ScrollX) * Scale);
  Top := Round((BoxY + Box.ContentTop + Max(0, LineTop) - ScrollY) * Scale);
  Bottom := Round((BoxY + Box.ContentTop + Max(0, LineTop) + Min(Box.ContentHeight, LineHeight) - ScrollY) *
    Scale);
  FillRectangle(Canvas, MakeRectangle(Left, Top, Max(1, Round(Scale)), Max(1, Bottom - Top)), ColorBlack);
end;

{ Whether what is at the viewport point (CSS px) is Container or inside
  it: a bar under something painted over its container (a pop-up, a
  menu) is not drawn over that. }
function TWebEngineView.ShowsAt(Container: TNode; X, Y: Single): Boolean;
var
  Node: TNode;
begin
  Result := False;
  if (FPainter = nil) or (Container = nil) then
    Exit;
  Node := FPainter.HitTest(X, Y).Element;
  while Node <> nil do
  begin
    if Node = Container then
      Exit(True);
    Node := Node.ParentNode;
  end;
end;

{ Scroll containers inside the page show a thin bar of the theme's
  colours along their right (and bottom) edge. }
procedure TWebEngineView.PaintInnerScrollBars(var Canvas: TCanvas);
var
  Containers: TScrollContainerArray;
  Index: Integer;
  Scale: Double;
  ScrollX, ScrollY: Single;
  Info: TScrollContainerInfo;
  Track, Thumb: TRectangle;
  Thickness, Length_, ThumbLength, ThumbStart: LongInt;
begin
  if FLayout = nil then
    Exit;
  Containers := FLayout.ScrollContainers;
  Scale := DeviceScale;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Thickness := Scaled(InnerBarThickness);
  for Index := 1 to High(Containers) do
  begin
    Info := Containers[Index];
    if (Info.Height <= 0) or (Info.Width <= 0) then
      Continue;
    if Info.BarY and (Info.ScrollHeight > Info.Height + 0.5) and
      ShowsAt(Info.Node, Info.X + Info.Width - 2 - ScrollX, Info.Y + Info.Height / 2 - ScrollY) then
    begin
      Track := MakeRectangle(Round((Info.X + Info.Width - ScrollX) * Scale) - Thickness,
        Round((Info.Y - ScrollY) * Scale), Thickness, Round(Info.Height * Scale));
      FillRectangle(Canvas, Track, WithAlpha(Theme.ScrollTrack, 200));
      Length_ := RectangleHeight(Track);
      ThumbLength := Max(Thickness * 2, Round(Length_ * Info.Height / Info.ScrollHeight));
      ThumbStart := Round((Length_ - ThumbLength) * Info.ScrollY / Max(1, Info.ScrollHeight - Info.Height));
      Thumb := MakeRectangle(Track.Left, Track.Top + ThumbStart, Thickness, ThumbLength);
      FillRectangle(Canvas, Thumb, Theme.Shadow);
    end;
    if Info.BarX and (Info.ScrollWidth > Info.Width + 0.5) and
      ShowsAt(Info.Node, Info.X + Info.Width / 2 - ScrollX, Info.Y + Info.Height - 2 - ScrollY) then
    begin
      Track := MakeRectangle(Round((Info.X - ScrollX) * Scale), Round((Info.Y + Info.Height - ScrollY) * Scale) -
        Thickness, Round(Info.Width * Scale), Thickness);
      FillRectangle(Canvas, Track, WithAlpha(Theme.ScrollTrack, 200));
      Length_ := RectangleWidth(Track);
      ThumbLength := Max(Thickness * 2, Round(Length_ * Info.Width / Info.ScrollWidth));
      ThumbStart := Round((Length_ - ThumbLength) * Info.ScrollX / Max(1, Info.ScrollWidth - Info.Width));
      Thumb := MakeRectangle(Track.Left + ThumbStart, Track.Top, ThumbLength, Thickness);
      FillRectangle(Canvas, Thumb, Theme.Shadow);
    end;
  end;
end;
