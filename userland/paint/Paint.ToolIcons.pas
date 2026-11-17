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
  The tools' pictures, drawn rather than read from files so they are
  sharp at any scale: each is drawn on a grid of 16 by 16 units fitted
  to the box it is given, in lines and shapes from libdrawing,
  anti-aliased, in the colour given (the theme's text colour).
}
unit Paint.ToolIcons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Paint.ToolKinds;

procedure DrawToolIcon(const Canvas: TCanvas; Kind: TToolKind; const Box: TRectangle; Color: TColor);

implementation

uses
  Math,
  Drawing.Rasterizer,
  Drawing.Shapes,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Drawing.SmoothStrokes,
  Drawing.SmoothRoundedRectangles,
  Drawing.Curves;

const
  GridUnits = 16;

type
  TIconGrid = record
    Left: Double;
    Top: Double;
    UnitSize: Double;
  end;

function GridOf(const Box: TRectangle): TIconGrid;
var
  Side: LongInt;
begin
  Side := Min(RectangleWidth(Box), RectangleHeight(Box));
  Result.UnitSize := Side / GridUnits;
  Result.Left := Box.Left + (RectangleWidth(Box) - Side) / 2;
  Result.Top := Box.Top + (RectangleHeight(Box) - Side) / 2;
end;

{ Grid point (X, Y) in centre coordinates (for strokes). }
function At(const Grid: TIconGrid; X, Y: Double): TPrecisePoint;
begin
  Result := PrecisePoint(Grid.Left + X * Grid.UnitSize - 0.5, Grid.Top + Y * Grid.UnitSize - 0.5);
end;

{ Grid rectangle in pixels. }
function GridRectangle(const Grid: TIconGrid; Left, Top, Right, Bottom: Double): TRectangle;
begin
  Result.Left := Round(Grid.Left + Left * Grid.UnitSize);
  Result.Top := Round(Grid.Top + Top * Grid.UnitSize);
  Result.Right := Round(Grid.Left + Right * Grid.UnitSize);
  Result.Bottom := Round(Grid.Top + Bottom * Grid.UnitSize);
end;

function LineWidth(const Grid: TIconGrid): Double;
begin
  Result := Max(1, Grid.UnitSize * 1.2);
end;

procedure Stroke(const Canvas: TCanvas; const Grid: TIconGrid; const Points: array of TPrecisePoint;
  Width: Double; Color: TColor);
begin
  DrawSmoothRoundStroke(Canvas, Points, Width, Color);
end;

procedure DrawDottedBox(const Canvas: TCanvas; const Box: TRectangle; Color: TColor);
begin
  DrawDottedHorizontalLine(Canvas, Box.Left, Box.Right, Box.Top, 1, Color);
  DrawDottedHorizontalLine(Canvas, Box.Left, Box.Right, Box.Bottom - 1, 1, Color);
  DrawDottedVerticalLine(Canvas, Box.Left, Box.Top, Box.Bottom, 1, Color);
  DrawDottedVerticalLine(Canvas, Box.Right - 1, Box.Top, Box.Bottom, 1, Color);
end;

procedure DrawToolIcon(const Canvas: TCanvas; Kind: TToolKind; const Box: TRectangle; Color: TColor);
var
  Grid: TIconGrid;
  Width: Double;
  Points: array of TPrecisePoint;
  Curve: TPrecisePoints;
begin
  Grid := GridOf(Box);
  Width := LineWidth(Grid);
  case Kind of
    ToolSelect:
      DrawDottedBox(Canvas, GridRectangle(Grid, 2, 3, 14, 13), Color);
    ToolFreeFormSelect:
      begin
        Curve := FlattenCubicCurve(At(Grid, 3, 9), At(Grid, 0, 1), At(Grid, 16, 0), At(Grid, 12, 9));
        Stroke(Canvas, Grid, Curve, Max(1, Width * 0.7), Color);
        Curve := FlattenQuadraticCurve(At(Grid, 12, 9), At(Grid, 9, 15), At(Grid, 3, 9));
        Stroke(Canvas, Grid, Curve, Max(1, Width * 0.7), Color);
      end;
    ToolEraser:
      begin
        Points := nil;
        SetLength(Points, 4);
        Points[0] := At(Grid, 2, 10);
        Points[1] := At(Grid, 9, 3);
        Points[2] := At(Grid, 14, 8);
        Points[3] := At(Grid, 7, 15);
        FillSmoothPolygon(Canvas, Points, FadeColor(Color, 70));
        DrawSmoothPolygonOutline(Canvas, Points, Max(1, Width * 0.8), Color);
        Stroke(Canvas, Grid, [At(Grid, 5, 7), At(Grid, 10, 12)], Max(1, Width * 0.8), Color);
      end;
    ToolFill:
      begin
        Points := nil;
        SetLength(Points, 4);
        Points[0] := At(Grid, 2, 8);
        Points[1] := At(Grid, 8, 2);
        Points[2] := At(Grid, 13, 7);
        Points[3] := At(Grid, 7, 13);
        DrawSmoothPolygonOutline(Canvas, Points, Width, Color);
        Stroke(Canvas, Grid, [At(Grid, 13, 7), At(Grid, 14.5, 11), At(Grid, 14.5, 13)], Width * 1.4, Color);
      end;
    ToolPicker:
      begin
        Stroke(Canvas, Grid, [At(Grid, 3, 13), At(Grid, 10, 6)], Width, Color);
        Stroke(Canvas, Grid, [At(Grid, 10, 6), At(Grid, 12.5, 3.5)], Width * 2.4, Color);
        Stroke(Canvas, Grid, [At(Grid, 8, 4), At(Grid, 12, 8)], Width, Color);
      end;
    ToolPencil:
      begin
        Stroke(Canvas, Grid, [At(Grid, 4, 12), At(Grid, 13, 3)], Width * 2.2, Color);
        Stroke(Canvas, Grid, [At(Grid, 2.5, 13.5), At(Grid, 4, 12)], Width, Color);
      end;
    ToolBrush:
      begin
        Stroke(Canvas, Grid, [At(Grid, 8, 8), At(Grid, 14, 2)], Width, Color);
        DrawSmoothDot(Canvas, At(Grid, 5.5, 10.5).X, At(Grid, 5.5, 10.5).Y, Grid.UnitSize * 5, Color);
        Stroke(Canvas, Grid, [At(Grid, 4, 12), At(Grid, 2, 14)], Width * 1.5, Color);
      end;
    ToolAirbrush:
      begin
        DrawRectangleOutline(Canvas, GridRectangle(Grid, 8, 6, 13, 15), Color);
        Stroke(Canvas, Grid, [At(Grid, 10.5, 6), At(Grid, 10.5, 3), At(Grid, 7, 3)], Width, Color);
        DrawSmoothDot(Canvas, At(Grid, 4, 2).X, At(Grid, 4, 2).Y, Max(1, Grid.UnitSize), Color);
        DrawSmoothDot(Canvas, At(Grid, 2, 4).X, At(Grid, 2, 4).Y, Max(1, Grid.UnitSize), Color);
        DrawSmoothDot(Canvas, At(Grid, 4, 5).X, At(Grid, 4, 5).Y, Max(1, Grid.UnitSize), Color);
        DrawSmoothDot(Canvas, At(Grid, 2, 1).X, At(Grid, 2, 1).Y, Max(1, Grid.UnitSize), Color);
      end;
    ToolText:
      begin
        Stroke(Canvas, Grid, [At(Grid, 3, 14), At(Grid, 8, 2), At(Grid, 13, 14)], Width * 1.2, Color);
        Stroke(Canvas, Grid, [At(Grid, 5, 10), At(Grid, 11, 10)], Width, Color);
      end;
    ToolLine:
      Stroke(Canvas, Grid, [At(Grid, 2, 14), At(Grid, 14, 2)], Width, Color);
    ToolCurve:
      begin
        Curve := FlattenCubicCurve(At(Grid, 2, 13), At(Grid, 4, 0), At(Grid, 12, 16), At(Grid, 14, 3));
        Stroke(Canvas, Grid, Curve, Width, Color);
      end;
    ToolRectangle:
      DrawSmoothRoundedRectangleOutline(Canvas, GridRectangle(Grid, 2, 4, 14, 12), 0, Width, Color);
    ToolPolygon:
      begin
        Points := nil;
        SetLength(Points, 5);
        Points[0] := At(Grid, 3, 13);
        Points[1] := At(Grid, 2, 6);
        Points[2] := At(Grid, 8, 2);
        Points[3] := At(Grid, 14, 6);
        Points[4] := At(Grid, 11, 13);
        DrawSmoothPolygonOutline(Canvas, Points, Width, Color);
      end;
    ToolEllipse:
      DrawSmoothEllipseOutline(Canvas, GridRectangle(Grid, 1.5, 3.5, 14.5, 12.5), Width, Color);
    ToolRoundedRectangle:
      DrawSmoothRoundedRectangleOutline(Canvas, GridRectangle(Grid, 2, 4, 14, 12), Grid.UnitSize * 3, Width, Color);
  end;
end;

end.
