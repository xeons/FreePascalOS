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

{ WebView.Control: painting through the backing surface. }

const
  SelectionAlpha = 110;
  InnerBarThickness = 6;

procedure TWebView.InvalidateViewport;
begin
  Invalidate;
end;

{ The backing surface has the viewport's size; a new one is painted
  whole. }
procedure TWebView.EnsureBacking;
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

function TWebView.PageHasFixedBoxes: Boolean;
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
    if List.Items[Index].Kind = diPushFixed then
    begin
      FListHasFixed := True;
      Break;
    end;
  FFixedChecked := True;
  FFixedCheckedVersion := FPainter.BuiltVersion;
  Result := FListHasFixed;
end;

{ Paints what is out of date into the backing surface. }
procedure TWebView.PaintBacking;
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

procedure TWebView.Paint(var Canvas: TCanvas);
var
  Width, Height: LongInt;
  Corner: TRectangle;
begin
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
  { The overlays stay within the viewport. }
  NarrowCanvasClip(Canvas, MakeRectangle(0, 0, ViewportPixelWidth, ViewportPixelHeight));
  PaintSelection(Canvas);
  PaintCaret(Canvas);
  PaintInnerScrollBars(Canvas);
end;

procedure TWebView.PaintSelection(var Canvas: TCanvas);
var
  Rectangles: TTextRectangleArray;
  Index: Integer;
  Scale: Double;
  ScrollX, ScrollY: Single;
  OffsetX, OffsetY: Double;
  Area: TRectangle;
begin
  if (FLayout = nil) or (FSelectionAnchor.Run < 0) or (TPageTextIndex.Compare(FSelectionAnchor,
     FSelectionFocus) = 0) then
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

{ A text field with the focus shows a caret after its text. }
procedure TWebView.PaintCaret(var Canvas: TCanvas);
var
  Box: TLayoutBox;
  BoxX, BoxY, TextWidth: Single;
  ScrollX, ScrollY: Single;
  Scale: Double;
  Value: string;
  Left, Top, Bottom: LongInt;
  Font: TTextFont;
  Kind: TFormControlKind;
begin
  if (FLayout = nil) or (FFocusedElement = nil) or not Focused then
    Exit;
  Kind := FormControlKindOf(FFocusedElement);
  if not (Kind in [FormControlText, FormControlPassword, FormControlTextArea]) then
    Exit;
  Box := FLayout.BoxOf(FFocusedElement);
  if Box = nil then
    Exit;
  Box.AbsolutePosition(BoxX, BoxY);
  Value := ControlValue(FFocusedElement);
  if Kind = FormControlTextArea then
  begin
    { The last line's text. }
    if LastDelimiter(#10, Value) > 0 then
      Value := Copy(Value, LastDelimiter(#10, Value) + 1, MaxInt);
  end
  else if Kind = FormControlPassword then
    Value := StringOfChar('*', Length(Value));
  Font := TextFontOf(Box.Style);
  TextWidth := 0;
  if Value <> '' then
    TextWidth := Font.MeasureText(Value, 1, Length(Value));
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Scale := DeviceScale;
  Left := Round((BoxX + Box.ContentLeft + Min(TextWidth, Box.ContentWidth) - ScrollX) * Scale);
  Top := Round((BoxY + Box.ContentTop - ScrollY) * Scale);
  Bottom := Round((BoxY + Box.ContentTop + Min(Box.ContentHeight, Font.Ascent + Font.Descent + 2) - ScrollY) * Scale);
  if Kind = FormControlTextArea then
  begin
    Top := Round((BoxY + Box.ContentTop + Box.ContentHeight - Font.Ascent - Font.Descent - 2 - ScrollY) * Scale);
    Bottom := Round((BoxY + Box.ContentTop + Box.ContentHeight - ScrollY) * Scale);
  end;
  FillRectangle(Canvas, MakeRectangle(Left, Top, Max(1, Round(Scale)), Max(1, Bottom - Top)), ColorBlack);
end;

{ Scroll containers inside the page show a thin bar of the theme's
  colours along their right (and bottom) edge. }
procedure TWebView.PaintInnerScrollBars(var Canvas: TCanvas);
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
    if Info.ScrollHeight > Info.Height + 0.5 then
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
    if Info.ScrollWidth > Info.Width + 0.5 then
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
