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
  Drawing pictures on a design grid: the desktop's program icons, the
  taskbar's marks and the stock icons of files, programs and disks
  (Controls.FileIcons).

  Every such picture is designed on a square grid GridSize steps across
  and drawn into whatever box the display's scale makes of it, with
  libdrawing's anti-aliased shapes, so it is as smooth at 32 pixels as
  at 64. A TPictureGrid maps the design's points (fractions of a step
  allowed) to the box's pixels; the helpers fill and outline shapes
  given in those points.
}
unit Controls.PictureGrid;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer;

const
  GridSize = 32;

type
  TPictureGrid = record
    Left: Double;
    Top: Double;
    { Pixels per design step. }
    Step: Double;
  end;

function GridFor(const Box: TRectangle): TPictureGrid;
function GridPoint(const Grid: TPictureGrid; X, Y: Double): TPrecisePoint;
{ A length of the design in pixels. }
function GridLength(const Grid: TPictureGrid; Length: Double): Double;

{ The rectangle (Left, Top)-(Right, Bottom) of the design with corners
  rounded by Radius, filled, and outlined Thickness steps wide if
  OutlineColor is not transparent. }
procedure DrawRoundedBox(const Canvas: TCanvas; const Grid: TPictureGrid; Left, Top, Right, Bottom, Radius: Double;
  FillColor, OutlineColor: TColor; Thickness: Double);
{ A polygon of design points, filled and outlined the same way. }
procedure DrawGridPolygon(const Canvas: TCanvas; const Grid: TPictureGrid; const Points: array of TPrecisePoint;
  FillColor, OutlineColor: TColor; Thickness: Double);
{ A line of the design, Width steps wide. }
procedure DrawGridLine(const Canvas: TCanvas; const Grid: TPictureGrid; FromX, FromY, ToX, ToY, Width: Double;
  Color: TColor);
{ A disc of the design (centre and radius in steps). }
procedure DrawGridDisc(const Canvas: TCanvas; const Grid: TPictureGrid; CenterX, CenterY, Radius: Double;
  Color: TColor);
{ A ring of the design, Thickness steps wide. }
procedure DrawGridRing(const Canvas: TCanvas; const Grid: TPictureGrid; CenterX, CenterY, Radius, Thickness: Double;
  Color: TColor);

implementation

uses
  Drawing.SmoothShapes,
  Drawing.SmoothLines;

const
  { Points on each rounded corner. }
  CornerSteps = 6;

function GridFor(const Box: TRectangle): TPictureGrid;
var
  Side: LongInt;
begin
  Side := RectangleWidth(Box);
  if RectangleHeight(Box) < Side then
    Side := RectangleHeight(Box);
  Result.Step := Side / GridSize;
  Result.Left := Box.Left + (RectangleWidth(Box) - Side) / 2;
  Result.Top := Box.Top + (RectangleHeight(Box) - Side) / 2;
end;

function GridPoint(const Grid: TPictureGrid; X, Y: Double): TPrecisePoint;
begin
  Result := PrecisePoint(Grid.Left + X * Grid.Step, Grid.Top + Y * Grid.Step);
end;

function GridLength(const Grid: TPictureGrid; Length: Double): Double;
begin
  Result := Length * Grid.Step;
end;

procedure DrawGridPolygon(const Canvas: TCanvas; const Grid: TPictureGrid; const Points: array of TPrecisePoint;
  FillColor, OutlineColor: TColor; Thickness: Double);
var
  Mapped: array of TPrecisePoint;
  Index: LongInt;
begin
  Mapped := nil;
  SetLength(Mapped, Length(Points));
  for Index := 0 to High(Points) do
    Mapped[Index] := GridPoint(Grid, Points[Index].X, Points[Index].Y);
  if AlphaOf(FillColor) <> 0 then
    FillSmoothPolygon(Canvas, Mapped, FillColor);
  if AlphaOf(OutlineColor) <> 0 then
    DrawSmoothPolygonOutline(Canvas, Mapped, GridLength(Grid, Thickness), OutlineColor);
end;

procedure DrawRoundedBox(const Canvas: TCanvas; const Grid: TPictureGrid; Left, Top, Right, Bottom, Radius: Double;
  FillColor, OutlineColor: TColor; Thickness: Double);
var
  Points: array[0..4 * (CornerSteps + 1) - 1] of TPrecisePoint;
  CornerX: array[0..3] of Double;
  CornerY: array[0..3] of Double;
  Corner: LongInt;
  Step: LongInt;
  Angle: Double;
begin
  { The corners' centres clockwise from the top left; each corner is a
    quarter circle round its centre, starting where the last ended. }
  CornerX[0] := Left + Radius;
  CornerY[0] := Top + Radius;
  CornerX[1] := Right - Radius;
  CornerY[1] := Top + Radius;
  CornerX[2] := Right - Radius;
  CornerY[2] := Bottom - Radius;
  CornerX[3] := Left + Radius;
  CornerY[3] := Bottom - Radius;
  for Corner := 0 to 3 do
    for Step := 0 to CornerSteps do
    begin
      Angle := Pi + (Corner + Step / CornerSteps) * (Pi / 2);
      Points[Corner * (CornerSteps + 1) + Step] := PrecisePoint(CornerX[Corner] + Radius * Cos(Angle),
        CornerY[Corner] + Radius * Sin(Angle));
    end;
  DrawGridPolygon(Canvas, Grid, Points, FillColor, OutlineColor, Thickness);
end;

procedure DrawGridLine(const Canvas: TCanvas; const Grid: TPictureGrid; FromX, FromY, ToX, ToY, Width: Double;
  Color: TColor);
var
  FromPoint: TPrecisePoint;
  ToPoint: TPrecisePoint;
begin
  FromPoint := GridPoint(Grid, FromX, FromY);
  ToPoint := GridPoint(Grid, ToX, ToY);
  DrawSmoothLine(Canvas, FromPoint.X, FromPoint.Y, ToPoint.X, ToPoint.Y, GridLength(Grid, Width), Color);
end;

{ The pixel box around a circle of the design. }
function CircleBox(const Grid: TPictureGrid; CenterX, CenterY, Radius: Double): TRectangle;
var
  TopLeft: TPrecisePoint;
  Side: LongInt;
begin
  TopLeft := GridPoint(Grid, CenterX - Radius, CenterY - Radius);
  Side := Round(GridLength(Grid, 2 * Radius));
  if Side < 1 then
    Side := 1;
  Result := MakeRectangle(Round(TopLeft.X), Round(TopLeft.Y), Side, Side);
end;

procedure DrawGridDisc(const Canvas: TCanvas; const Grid: TPictureGrid; CenterX, CenterY, Radius: Double;
  Color: TColor);
begin
  FillSmoothEllipse(Canvas, CircleBox(Grid, CenterX, CenterY, Radius), Color);
end;

procedure DrawGridRing(const Canvas: TCanvas; const Grid: TPictureGrid; CenterX, CenterY, Radius, Thickness: Double;
  Color: TColor);
begin
  DrawSmoothEllipseOutline(Canvas, CircleBox(Grid, CenterX, CenterY, Radius), GridLength(Grid, Thickness), Color);
end;

end.
