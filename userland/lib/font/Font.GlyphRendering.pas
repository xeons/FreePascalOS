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

{
  Rendering an outline glyph: its outline scaled to the pixel size,
  hinted (Font.Hinting) if asked, its quadratic curves and lines handed
  to libdrawing's rasterizer (Drawing.Rasterizer: exact area coverage,
  non-zero winding), and the coverage of every pixel it touches kept as
  a bitmap.

  The pixel size is the em in pixels. The pen sits on the baseline at
  OffsetX pixels right of a pixel's left side (0 to under 1: subpixel
  positioning), so the same glyph can be drawn a fraction of a pixel
  further along.
}
unit Font.GlyphRendering;

{$mode objfpc}
{$H+}

interface

uses
  Font.Outlines;

const
  { The largest em rendered, and the largest bitmap side. }
  MaximumRenderedSize = 1024;
  MaximumBitmapSide = 4096;

{ Glyph of Font at PixelSize; False (and an empty bitmap) if its outline
  cannot be read or the size is out of reason. An empty glyph is True
  with an empty bitmap. }
function RenderGlyph(Font: TOutlineFont; Glyph: LongWord; PixelSize: LongInt; OffsetX: Double; Hinted: Boolean;
  out Bitmap: TGlyphBitmap): Boolean;

implementation

uses
  Math,
  Drawing.Rectangles,
  Drawing.Rasterizer,
  Font.Hinting;

procedure ClearBitmap(out Bitmap: TGlyphBitmap);
begin
  Bitmap.Left := 0;
  Bitmap.Top := 0;
  Bitmap.Width := 0;
  Bitmap.Height := 0;
  Bitmap.Coverage := nil;
end;

{ One contour's lines and curves into Shape (points in pixels, y down). }
procedure AddContour(var Shape: TCoverageShape; const Outline: TGlyphOutline; First, Last: LongInt);
var
  Count: LongInt;
  StartX: Double;
  StartY: Double;
  CurrentX: Double;
  CurrentY: Double;
  ControlX: Double;
  ControlY: Double;
  HasControl: Boolean;
  Step: LongInt;
  Steps: LongInt;
  Index: LongInt;
  Skip: LongInt;
  Point: TOutlinePoint;

  procedure GoTo_(X, Y: Double);
  begin
    if HasControl then
      AddShapeQuadratic(Shape, CurrentX, CurrentY, ControlX, ControlY, X, Y)
    else
      AddShapeEdge(Shape, CurrentX, CurrentY, X, Y);
    CurrentX := X;
    CurrentY := Y;
    HasControl := False;
  end;

begin
  Count := Last - First + 1;
  if Count < 2 then
    Exit;
  { Start on a point on the curve: the first, else the last, else the
    one implied between them. }
  if Outline.Points[First].OnCurve then
  begin
    StartX := Outline.Points[First].X;
    StartY := Outline.Points[First].Y;
    Skip := First;
    Steps := Count - 1;
  end
  else if Outline.Points[Last].OnCurve then
  begin
    StartX := Outline.Points[Last].X;
    StartY := Outline.Points[Last].Y;
    Skip := Last;
    Steps := Count - 1;
  end
  else
  begin
    StartX := 0.5 * (Outline.Points[First].X + Outline.Points[Last].X);
    StartY := 0.5 * (Outline.Points[First].Y + Outline.Points[Last].Y);
    Skip := -1;
    Steps := Count;
  end;
  CurrentX := StartX;
  CurrentY := StartY;
  HasControl := False;
  ControlX := 0;
  ControlY := 0;
  { Every other point once, in order from the one after the start. }
  if Skip = First then
    Index := First + 1
  else
    Index := First;
  for Step := 1 to Steps do
  begin
    if Index = Skip then
      Inc(Index);
    if Index > Last then
      Index := First;
    Point := Outline.Points[Index];
    if Point.OnCurve then
      GoTo_(Point.X, Point.Y)
    else
    begin
      if HasControl then
        GoTo_(0.5 * (ControlX + Point.X), 0.5 * (ControlY + Point.Y));
      ControlX := Point.X;
      ControlY := Point.Y;
      HasControl := True;
    end;
    Inc(Index);
  end;
  GoTo_(StartX, StartY);
end;

function RenderGlyph(Font: TOutlineFont; Glyph: LongWord; PixelSize: LongInt; OffsetX: Double; Hinted: Boolean;
  out Bitmap: TGlyphBitmap): Boolean;
var
  Outline: TGlyphOutline;
  Scale: Double;
  Index: LongInt;
  Contour: LongInt;
  First: LongInt;
  Shape: TCoverageShape;
  Left: Double;
  Right: Double;
  Top: Double;
  Bottom: Double;
  Area: TRectangle;
begin
  Result := False;
  ClearBitmap(Bitmap);
  if (Font = nil) or (PixelSize < 1) or (PixelSize > MaximumRenderedSize) or not Font.LoadOutline(Glyph, Outline) then
    Exit;
  Result := True;
  if Outline.PointCount = 0 then
    Exit;
  Scale := PixelSize / Font.UnitsPerEm;
  for Index := 0 to Outline.PointCount - 1 do
  begin
    Outline.Points[Index].X := Outline.Points[Index].X * Scale;
    Outline.Points[Index].Y := Outline.Points[Index].Y * Scale;
  end;
  if Hinted then
    HintOutline(Font, Scale, Outline);
  { To the raster: the pen moved along, y downwards. }
  Left := MaxDouble;
  Right := -MaxDouble;
  Top := MaxDouble;
  Bottom := -MaxDouble;
  for Index := 0 to Outline.PointCount - 1 do
  begin
    Outline.Points[Index].X := Outline.Points[Index].X + OffsetX;
    Outline.Points[Index].Y := -Outline.Points[Index].Y;
    Left := Min(Left, Outline.Points[Index].X);
    Right := Max(Right, Outline.Points[Index].X);
    Top := Min(Top, Outline.Points[Index].Y);
    Bottom := Max(Bottom, Outline.Points[Index].Y);
  end;
  Area.Left := Floor(Left);
  Area.Top := Floor(Top);
  Area.Right := Ceil(Right);
  Area.Bottom := Ceil(Bottom);
  if (RectangleWidth(Area) <= 0) or (RectangleHeight(Area) <= 0) or (RectangleWidth(Area) > MaximumBitmapSide) or
     (RectangleHeight(Area) > MaximumBitmapSide) then
    Exit;
  BeginShape(Shape);
  First := 0;
  for Contour := 0 to Outline.ContourCount - 1 do
  begin
    AddContour(Shape, Outline, First, Outline.ContourEnds[Contour]);
    First := Outline.ContourEnds[Contour] + 1;
  end;
  Bitmap.Left := Area.Left;
  Bitmap.Top := Area.Top;
  Bitmap.Width := RectangleWidth(Area);
  Bitmap.Height := RectangleHeight(Area);
  SetLength(Bitmap.Coverage, Bitmap.Width * Bitmap.Height);
  ShapeCoverage(Shape, Area, Bitmap.Coverage);
end;

end.
