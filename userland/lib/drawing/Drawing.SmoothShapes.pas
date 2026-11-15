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
  Anti-aliased ellipses and polygons, alongside Drawing.Shapes' exact
  ones: each pixel blended by how much of it the shape covers
  (Drawing.Rasterizer).

  An ellipse is the one that touches its bounding rectangle's edges, as
  in Drawing.Shapes; its outline is a ring Thickness pixels wide just
  inside them. A polygon's points are where FillPolygon's are (pixel
  (X, Y) is the square from (X, Y) to (X + 1, Y + 1)) and it is filled
  by the non-zero rule; its outline, like DrawPolygonOutline's, runs
  through the points as pixel centres, Width wide, with round corners.
}
unit Drawing.SmoothShapes;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer;

procedure FillSmoothEllipse(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
procedure DrawSmoothEllipseOutline(const Canvas: TCanvas; const Bounds: TRectangle; Thickness: Double; Color: TColor);
procedure FillSmoothPolygon(const Canvas: TCanvas; const Points: array of TPrecisePoint; Color: TColor);
procedure DrawSmoothPolygonOutline(const Canvas: TCanvas; const Points: array of TPrecisePoint; Width: Double;
  Color: TColor);

implementation

uses
  Drawing.SmoothLines;

procedure FillSmoothEllipse(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
var
  Shape: TCoverageShape;
begin
  if RectangleIsEmpty(Bounds) then
    Exit;
  BeginShape(Shape);
  AddShapeEllipse(Shape, (Bounds.Left + Bounds.Right) / 2, (Bounds.Top + Bounds.Bottom) / 2,
    RectangleWidth(Bounds) / 2, RectangleHeight(Bounds) / 2, True);
  FillShape(Canvas, Shape, Color);
end;

procedure DrawSmoothEllipseOutline(const Canvas: TCanvas; const Bounds: TRectangle; Thickness: Double; Color: TColor);
var
  Shape: TCoverageShape;
  CentreX: Double;
  CentreY: Double;
  RadiusX: Double;
  RadiusY: Double;
begin
  if RectangleIsEmpty(Bounds) or (Thickness <= 0) then
    Exit;
  CentreX := (Bounds.Left + Bounds.Right) / 2;
  CentreY := (Bounds.Top + Bounds.Bottom) / 2;
  RadiusX := RectangleWidth(Bounds) / 2;
  RadiusY := RectangleHeight(Bounds) / 2;
  BeginShape(Shape);
  AddShapeEllipse(Shape, CentreX, CentreY, RadiusX, RadiusY, True);
  { The inner ellipse the other way round cuts the hole (a ring thicker
    than the ellipse is the whole ellipse). }
  if (RadiusX > Thickness) and (RadiusY > Thickness) then
    AddShapeEllipse(Shape, CentreX, CentreY, RadiusX - Thickness, RadiusY - Thickness, False);
  FillShape(Canvas, Shape, Color);
end;

procedure FillSmoothPolygon(const Canvas: TCanvas; const Points: array of TPrecisePoint; Color: TColor);
var
  Shape: TCoverageShape;
begin
  if Length(Points) < 3 then
    Exit;
  BeginShape(Shape);
  AddShapePolygon(Shape, Points);
  FillShape(Canvas, Shape, Color);
end;

procedure DrawSmoothPolygonOutline(const Canvas: TCanvas; const Points: array of TPrecisePoint; Width: Double;
  Color: TColor);
var
  Shape: TCoverageShape;
  Index: LongInt;
  Next: LongInt;
begin
  if (Length(Points) < 2) or (Width <= 0) then
    Exit;
  { Every stroke and corner goes round the same way, so where they
    overlap they join rather than cancel. }
  BeginShape(Shape);
  for Index := 0 to High(Points) do
  begin
    Next := (Index + 1) mod Length(Points);
    AddLineStroke(Shape, Points[Index].X, Points[Index].Y, Points[Next].X, Points[Next].Y, Width);
    AddRoundJoint(Shape, Points[Index].X, Points[Index].Y, Width);
  end;
  FillShape(Canvas, Shape, Color);
end;

end.
