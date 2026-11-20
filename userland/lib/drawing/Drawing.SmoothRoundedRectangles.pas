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
  Anti-aliased rectangles with rounded corners, filled through the
  rasterizer like Drawing.SmoothShapes: the rectangle is its bounds (in
  the rasterizer's coordinates, pixel (X, Y) being the square from
  (X, Y) to (X + 1, Y + 1)) with each corner a quarter circle of Radius
  (at most half the shorter side; 0 is a plain rectangle). Its outline
  is a band Thickness wide just inside the bounds, the inner corners
  rounded Thickness less.
}
unit Drawing.SmoothRoundedRectangles;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer;

{ The rounded rectangle's outline added to Shape: clockwise on the
  screen (filled), or not (a hole in a clockwise outline around it). }
procedure AddShapeRoundedRectangle(var Shape: TCoverageShape; Left, Top, Right, Bottom, Radius: Double;
  Clockwise: Boolean);
type
  { Each corner's horizontal and vertical radius: top left, top right,
    bottom right, bottom left (CSS's border-radius order). }
  TCornerRadii = array[0..3] of TPrecisePoint;

{ A rectangle with elliptical corners of their own sizes (scaled down
  together when adjacent ones do not fit, as CSS says), added to Shape. }
procedure AddShapeRoundedRectangleCorners(var Shape: TCoverageShape; Left, Top, Right, Bottom: Double;
  const Radii: TCornerRadii; Clockwise: Boolean);
{ CSS's rule: when two radii on a side add up to more than the side,
  all are scaled by the same factor. }
procedure FitCornerRadii(var Radii: TCornerRadii; Width, Height: Double);
procedure FillSmoothRoundedRectangle(const Canvas: TCanvas; const Bounds: TRectangle; Radius: Double;
  Color: TColor);
procedure DrawSmoothRoundedRectangleOutline(const Canvas: TCanvas; const Bounds: TRectangle; Radius,
  Thickness: Double; Color: TColor);

implementation

uses
  Math;

const
  { How far an edge may stray from a corner's arc, in pixels. }
  Tolerance = 0.01;
  MaximumCornerPieces = 128;

{ Pieces enough for a quarter circle of Radius. }
function CornerPieces(Radius: Double): LongInt;
var
  PieceAngle: Double;
begin
  if Radius <= Tolerance then
    Exit(1);
  { A piece across an angle A strays R (1 - cos(A / 2)) from the arc. }
  PieceAngle := 2 * ArcCos(1 - Tolerance / Radius);
  Result := Ceil((Pi / 2) / PieceAngle);
  if Result < 1 then
    Result := 1;
  if Result > MaximumCornerPieces then
    Result := MaximumCornerPieces;
end;

procedure AddShapeRoundedRectangle(var Shape: TCoverageShape; Left, Top, Right, Bottom, Radius: Double;
  Clockwise: Boolean);
var
  Points: array of TPrecisePoint;
  Pieces: LongInt;
  Corner: LongInt;
  Piece: LongInt;
  CentreX: Double;
  CentreY: Double;
  Angle: Double;
  Count: LongInt;
  Reversed: array of TPrecisePoint;
  Index: LongInt;
begin
  if (Right <= Left) or (Bottom <= Top) then
    Exit;
  Radius := Min(Radius, Min(Right - Left, Bottom - Top) / 2);
  if Radius < 0 then
    Radius := 0;
  Pieces := CornerPieces(Radius);
  Points := nil;
  SetLength(Points, 4 * (Pieces + 1));
  Count := 0;
  { The corners clockwise on the screen from the top right, each arc
    from its start angle on a quarter (angles measured from the right,
    growing downwards since Y grows downwards). }
  for Corner := 0 to 3 do
  begin
    case Corner of
      0: begin CentreX := Right - Radius; CentreY := Top + Radius; end;
      1: begin CentreX := Right - Radius; CentreY := Bottom - Radius; end;
      2: begin CentreX := Left + Radius; CentreY := Bottom - Radius; end;
    else
      begin CentreX := Left + Radius; CentreY := Top + Radius; end;
    end;
    for Piece := 0 to Pieces do
    begin
      Angle := -Pi / 2 + Corner * (Pi / 2) + Piece * (Pi / 2) / Pieces;
      Points[Count] := PrecisePoint(CentreX + Radius * Cos(Angle), CentreY + Radius * Sin(Angle));
      Inc(Count);
    end;
  end;
  if Clockwise then
    AddShapePolygon(Shape, Points)
  else
  begin
    Reversed := nil;
    SetLength(Reversed, Count);
    for Index := 0 to Count - 1 do
      Reversed[Index] := Points[Count - 1 - Index];
    AddShapePolygon(Shape, Reversed);
  end;
end;

procedure FitCornerRadii(var Radii: TCornerRadii; Width, Height: Double);
var
  Factor: Double;
  Corner: LongInt;

  procedure Limit(Sum, Side: Double);
  begin
    if (Sum > 0) and (Side / Sum < Factor) then
      Factor := Side / Sum;
  end;

begin
  Factor := 1;
  Limit(Radii[0].X + Radii[1].X, Width);
  Limit(Radii[3].X + Radii[2].X, Width);
  Limit(Radii[0].Y + Radii[3].Y, Height);
  Limit(Radii[1].Y + Radii[2].Y, Height);
  if Factor < 1 then
    for Corner := 0 to 3 do
    begin
      Radii[Corner].X := Radii[Corner].X * Factor;
      Radii[Corner].Y := Radii[Corner].Y * Factor;
    end;
end;

procedure AddShapeRoundedRectangleCorners(var Shape: TCoverageShape; Left, Top, Right, Bottom: Double;
  const Radii: TCornerRadii; Clockwise: Boolean);
var
  Fitted: TCornerRadii;
  Points, Reversed: array of TPrecisePoint;
  Corner, Piece, Pieces, Count, Index: LongInt;
  CentreX, CentreY, RadiusX, RadiusY, Angle: Double;
begin
  if (Right <= Left) or (Bottom <= Top) then
    Exit;
  Fitted := Radii;
  for Corner := 0 to 3 do
  begin
    if Fitted[Corner].X < 0 then
      Fitted[Corner].X := 0;
    if Fitted[Corner].Y < 0 then
      Fitted[Corner].Y := 0;
  end;
  FitCornerRadii(Fitted, Right - Left, Bottom - Top);
  Points := nil;
  Count := 0;
  { Clockwise from the top right corner (TCornerRadii index 1). }
  for Corner := 0 to 3 do
  begin
    case Corner of
      0:
        begin
          RadiusX := Fitted[1].X;
          RadiusY := Fitted[1].Y;
          CentreX := Right - RadiusX;
          CentreY := Top + RadiusY;
        end;
      1:
        begin
          RadiusX := Fitted[2].X;
          RadiusY := Fitted[2].Y;
          CentreX := Right - RadiusX;
          CentreY := Bottom - RadiusY;
        end;
      2:
        begin
          RadiusX := Fitted[3].X;
          RadiusY := Fitted[3].Y;
          CentreX := Left + RadiusX;
          CentreY := Bottom - RadiusY;
        end;
    else
      begin
        RadiusX := Fitted[0].X;
        RadiusY := Fitted[0].Y;
        CentreX := Left + RadiusX;
        CentreY := Top + RadiusY;
      end;
    end;
    if (RadiusX <= 0) or (RadiusY <= 0) then
      Pieces := 0
    else
      Pieces := CornerPieces(Max(RadiusX, RadiusY));
    SetLength(Points, Count + Pieces + 1);
    for Piece := 0 to Pieces do
    begin
      if Pieces = 0 then
        Angle := -Pi / 2 + Corner * (Pi / 2) + Pi / 4
      else
        Angle := -Pi / 2 + Corner * (Pi / 2) + Piece * (Pi / 2) / Pieces;
      if Pieces = 0 then
        Points[Count] := PrecisePoint(CentreX, CentreY)
      else
        Points[Count] := PrecisePoint(CentreX + RadiusX * Cos(Angle), CentreY + RadiusY * Sin(Angle));
      Inc(Count);
    end;
  end;
  if Clockwise then
    AddShapePolygon(Shape, Points)
  else
  begin
    Reversed := nil;
    SetLength(Reversed, Count);
    for Index := 0 to Count - 1 do
      Reversed[Index] := Points[Count - 1 - Index];
    AddShapePolygon(Shape, Reversed);
  end;
end;

procedure FillSmoothRoundedRectangle(const Canvas: TCanvas; const Bounds: TRectangle; Radius: Double;
  Color: TColor);
var
  Shape: TCoverageShape;
begin
  if RectangleIsEmpty(Bounds) then
    Exit;
  BeginShape(Shape);
  AddShapeRoundedRectangle(Shape, Bounds.Left, Bounds.Top, Bounds.Right, Bounds.Bottom, Radius, True);
  FillShape(Canvas, Shape, Color);
end;

procedure DrawSmoothRoundedRectangleOutline(const Canvas: TCanvas; const Bounds: TRectangle; Radius,
  Thickness: Double; Color: TColor);
var
  Shape: TCoverageShape;
begin
  if RectangleIsEmpty(Bounds) or (Thickness <= 0) then
    Exit;
  BeginShape(Shape);
  AddShapeRoundedRectangle(Shape, Bounds.Left, Bounds.Top, Bounds.Right, Bounds.Bottom, Radius, True);
  if (RectangleWidth(Bounds) > 2 * Thickness) and (RectangleHeight(Bounds) > 2 * Thickness) then
    AddShapeRoundedRectangle(Shape, Bounds.Left + Thickness, Bounds.Top + Thickness, Bounds.Right - Thickness,
      Bounds.Bottom - Thickness, Max(0, Radius - Thickness), False);
  FillShape(Canvas, Shape, Color);
end;

end.
