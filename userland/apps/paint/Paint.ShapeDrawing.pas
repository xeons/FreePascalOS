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
  The shapes the shape tools draw, on any canvas (the picture's).

  Points are pixels; a line or stroke runs through their centres. A
  shape has an outline Width wide in one colour, an interior in
  another, or both (TFillStyle). Rectangles keep crisp edges: their
  outline is the band Width pixels wide just inside the corners' pixels,
  as whole pixels. Everything else is anti-aliased through libdrawing:
  ellipses inside the same bounds, rectangles with rounded corners,
  polygons (filled by the non-zero rule, the outline closed with round
  corners), lines and curves with round ends (Drawing.SmoothStrokes;
  a straight line one pixel wide is Wu's thin line).
}
unit Paint.ShapeDrawing;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.Curves;

type
  TFillStyle = (FillStyleOutline, FillStyleInterior, FillStyleOutlineAndInterior);

  TShapeStyle = record
    Fill: TFillStyle;
    Width: LongInt;
    OutlineColor: TColor;
    InteriorColor: TColor;
  end;

function MakeShapeStyle(Fill: TFillStyle; Width: LongInt; OutlineColor, InteriorColor: TColor): TShapeStyle;
procedure DrawLineShape(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: LongInt; Color: TColor);
procedure DrawRectangleShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
procedure DrawEllipseShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
procedure DrawRoundedRectangleShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
{ A closed polygon through Points. }
procedure DrawPolygonShape(const Canvas: TCanvas; const Points: array of TPoint; const Style: TShapeStyle);
{ An open line through Points (a polygon being drawn). }
procedure DrawPolylineShape(const Canvas: TCanvas; const Points: array of TPoint; Width: LongInt; Color: TColor);
{ The curve from From to Target bent by one control point (quadratic)
  or two (cubic); with none it is the line. }
function CurvePoints(const From, Target: TPoint; const Controls: array of TPoint): TPrecisePoints;
procedure DrawCurveShape(const Canvas: TCanvas; const From, Target: TPoint; const Controls: array of TPoint;
  Width: LongInt; Color: TColor);
{ The corners' radius of a rounded rectangle in Bounds. }
function RoundedCornerRadius(const Bounds: TRectangle): Double;

implementation

uses
  Math,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Drawing.SmoothStrokes,
  Drawing.SmoothRoundedRectangles;

const
  CornerRadiusShare = 6;
  LargestCornerRadius = 24;

function MakeShapeStyle(Fill: TFillStyle; Width: LongInt; OutlineColor, InteriorColor: TColor): TShapeStyle;
begin
  Result.Fill := Fill;
  Result.Width := Max(1, Width);
  Result.OutlineColor := OutlineColor;
  Result.InteriorColor := InteriorColor;
end;

function HasOutline(const Style: TShapeStyle): Boolean;
begin
  Result := Style.Fill in [FillStyleOutline, FillStyleOutlineAndInterior];
end;

function HasInterior(const Style: TShapeStyle): Boolean;
begin
  Result := Style.Fill in [FillStyleInterior, FillStyleOutlineAndInterior];
end;

procedure DrawLineShape(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: LongInt; Color: TColor);
begin
  if Width <= 1 then
  begin
    if (FromX = ToX) and (FromY = ToY) then
      DrawPixel(Canvas, FromX, FromY, Color)
    else
      DrawSmoothLine(Canvas, FromX, FromY, ToX, ToY, 1, Color);
  end
  else
    DrawSmoothRoundLine(Canvas, FromX, FromY, ToX, ToY, Width, Color);
end;

procedure DrawRectangleShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
var
  Width: LongInt;
  Inner: TRectangle;
begin
  if RectangleIsEmpty(Bounds) then
    Exit;
  Width := Style.Width;
  if not HasOutline(Style) then
  begin
    FillRectangle(Canvas, Bounds, Style.InteriorColor);
    Exit;
  end;
  if (2 * Width >= RectangleWidth(Bounds)) or (2 * Width >= RectangleHeight(Bounds)) then
  begin
    FillRectangle(Canvas, Bounds, Style.OutlineColor);
    Exit;
  end;
  Inner := InflateRectangle(Bounds, -Width);
  if HasInterior(Style) then
    FillRectangle(Canvas, Inner, Style.InteriorColor);
  { The four sides: top and bottom whole, left and right between them. }
  FillRectangle(Canvas, MakeRectangle(Bounds.Left, Bounds.Top, RectangleWidth(Bounds), Width), Style.OutlineColor);
  FillRectangle(Canvas, MakeRectangle(Bounds.Left, Bounds.Bottom - Width, RectangleWidth(Bounds), Width),
    Style.OutlineColor);
  FillRectangle(Canvas, MakeRectangle(Bounds.Left, Inner.Top, Width, RectangleHeight(Inner)), Style.OutlineColor);
  FillRectangle(Canvas, MakeRectangle(Inner.Right, Inner.Top, Width, RectangleHeight(Inner)), Style.OutlineColor);
end;

procedure DrawEllipseShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
begin
  if RectangleIsEmpty(Bounds) then
    Exit;
  if HasInterior(Style) then
    FillSmoothEllipse(Canvas, Bounds, Style.InteriorColor);
  if HasOutline(Style) then
    DrawSmoothEllipseOutline(Canvas, Bounds, Style.Width, Style.OutlineColor);
end;

function RoundedCornerRadius(const Bounds: TRectangle): Double;
begin
  Result := Min(LargestCornerRadius, Min(RectangleWidth(Bounds), RectangleHeight(Bounds)) / CornerRadiusShare + 2);
end;

procedure DrawRoundedRectangleShape(const Canvas: TCanvas; const Bounds: TRectangle; const Style: TShapeStyle);
var
  Radius: Double;
begin
  if RectangleIsEmpty(Bounds) then
    Exit;
  Radius := RoundedCornerRadius(Bounds);
  if HasInterior(Style) then
    FillSmoothRoundedRectangle(Canvas, Bounds, Radius, Style.InteriorColor);
  if HasOutline(Style) then
    DrawSmoothRoundedRectangleOutline(Canvas, Bounds, Radius, Style.Width, Style.OutlineColor);
end;

{ Pixel centres as precise points, for strokes. }
function CentrePoints(const Points: array of TPoint): TPrecisePoints;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Points));
  for Index := 0 to High(Points) do
    Result[Index] := PrecisePoint(Points[Index].X, Points[Index].Y);
end;

procedure DrawPolygonShape(const Canvas: TCanvas; const Points: array of TPoint; const Style: TShapeStyle);
var
  Squares: TPrecisePoints;
  Index: LongInt;
begin
  if Length(Points) < 2 then
    Exit;
  if HasInterior(Style) and (Length(Points) >= 3) then
  begin
    { The rasterizer's coordinates: a pixel's centre is half a pixel
      into its square. }
    Squares := nil;
    SetLength(Squares, Length(Points));
    for Index := 0 to High(Points) do
      Squares[Index] := PrecisePoint(Points[Index].X + 0.5, Points[Index].Y + 0.5);
    FillSmoothPolygon(Canvas, Squares, Style.InteriorColor);
  end;
  if HasOutline(Style) then
    DrawSmoothPolygonOutline(Canvas, CentrePoints(Points), Style.Width, Style.OutlineColor);
end;

procedure DrawPolylineShape(const Canvas: TCanvas; const Points: array of TPoint; Width: LongInt; Color: TColor);
begin
  if Length(Points) = 0 then
    Exit;
  DrawSmoothRoundStroke(Canvas, CentrePoints(Points), Max(1, Width), Color);
end;

function CurvePoints(const From, Target: TPoint; const Controls: array of TPoint): TPrecisePoints;
var
  Start: TPrecisePoint;
  Finish: TPrecisePoint;
begin
  Start := PrecisePoint(From.X, From.Y);
  Finish := PrecisePoint(Target.X, Target.Y);
  case Length(Controls) of
    0:
      begin
        Result := nil;
        SetLength(Result, 2);
        Result[0] := Start;
        Result[1] := Finish;
      end;
    1: Result := FlattenQuadraticCurve(Start, PrecisePoint(Controls[0].X, Controls[0].Y), Finish);
  else
    Result := FlattenCubicCurve(Start, PrecisePoint(Controls[0].X, Controls[0].Y),
      PrecisePoint(Controls[1].X, Controls[1].Y), Finish);
  end;
end;

procedure DrawCurveShape(const Canvas: TCanvas; const From, Target: TPoint; const Controls: array of TPoint;
  Width: LongInt; Color: TColor);
begin
  { One shape, so the pieces' ends are not blended twice. }
  DrawSmoothRoundStroke(Canvas, CurvePoints(From, Target, Controls), Max(1, Width), Color);
end;

end.
