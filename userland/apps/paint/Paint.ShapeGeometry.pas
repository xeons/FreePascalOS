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
  The geometry of drawing by dragging: the rectangle two corners make
  (both corner pixels inside it), Shift's constraints (a square or
  circle instead of any rectangle, a line at a multiple of 45 degrees),
  and the rectangle of pixels a stroke through some points can touch,
  which is what an edit records for undo and the view paints again.
}
unit Paint.ShapeGeometry;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles;

type
  TPointArray = array of TPoint;

{ The rectangle from pixel (FirstX, FirstY) to pixel (SecondX, SecondY),
  both inside, whichever way round they are given. }
function RectangleFromCorners(FirstX, FirstY, SecondX, SecondY: LongInt): TRectangle;
{ The corner a drag from (FromX, FromY) to (ToX, ToY) ends at when it
  must make a square: the longer side wins, the direction is kept. }
function SquareCorner(FromX, FromY, ToX, ToY: LongInt): TPoint;
{ The end a line from (FromX, FromY) to (ToX, ToY) has when kept to the
  nearest multiple of 45 degrees: level, upright or diagonal. }
function LineAtSnappedAngle(FromX, FromY, ToX, ToY: LongInt): TPoint;
{ The pixels a stroke Width wide through Points can touch (anti-aliased
  edges included). }
function StrokeExtent(const Points: array of TPoint; Width: LongInt): TRectangle;
{ The smallest rectangle holding every point (as pixels). }
function PointsBounds(const Points: array of TPoint): TRectangle;
{ Whether (X, Y) is within Reach of (TargetX, TargetY) each way. }
function IsNear(X, Y, TargetX, TargetY, Reach: LongInt): Boolean;

implementation

function RectangleFromCorners(FirstX, FirstY, SecondX, SecondY: LongInt): TRectangle;
begin
  if FirstX <= SecondX then
  begin
    Result.Left := FirstX;
    Result.Right := SecondX + 1;
  end
  else
  begin
    Result.Left := SecondX;
    Result.Right := FirstX + 1;
  end;
  if FirstY <= SecondY then
  begin
    Result.Top := FirstY;
    Result.Bottom := SecondY + 1;
  end
  else
  begin
    Result.Top := SecondY;
    Result.Bottom := FirstY + 1;
  end;
end;

function SignOf(Value: LongInt): LongInt;
begin
  if Value < 0 then
    Result := -1
  else
    Result := 1;
end;

function SquareCorner(FromX, FromY, ToX, ToY: LongInt): TPoint;
var
  Side: LongInt;
begin
  Side := Abs(ToX - FromX);
  if Abs(ToY - FromY) > Side then
    Side := Abs(ToY - FromY);
  Result.X := FromX + SignOf(ToX - FromX) * Side;
  Result.Y := FromY + SignOf(ToY - FromY) * Side;
end;

function LineAtSnappedAngle(FromX, FromY, ToX, ToY: LongInt): TPoint;
var
  DeltaX: LongInt;
  DeltaY: LongInt;
  Diagonal: LongInt;
begin
  DeltaX := ToX - FromX;
  DeltaY := ToY - FromY;
  { tan(22.5 degrees) is about 0.4142: below it level (or upright),
    above it diagonal. In whole numbers: 1000 * small < 414 * large. }
  if Int64(Abs(DeltaY)) * 1000 < Int64(Abs(DeltaX)) * 414 then
    Exit(MakePoint(ToX, FromY));
  if Int64(Abs(DeltaX)) * 1000 < Int64(Abs(DeltaY)) * 414 then
    Exit(MakePoint(FromX, ToY));
  Diagonal := (Abs(DeltaX) + Abs(DeltaY)) div 2;
  Result := MakePoint(FromX + SignOf(DeltaX) * Diagonal, FromY + SignOf(DeltaY) * Diagonal);
end;

function PointsBounds(const Points: array of TPoint): TRectangle;
var
  Index: LongInt;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  if Length(Points) = 0 then
    Exit;
  Result := MakeRectangle(Points[0].X, Points[0].Y, 1, 1);
  for Index := 1 to High(Points) do
    Result := BoundingRectangle(Result, MakeRectangle(Points[Index].X, Points[Index].Y, 1, 1));
end;

function StrokeExtent(const Points: array of TPoint; Width: LongInt): TRectangle;
begin
  if Length(Points) = 0 then
    Exit(MakeRectangle(0, 0, 0, 0));
  if Width < 1 then
    Width := 1;
  { Half the width either side of the pixels' centres, and a pixel more
    for the anti-aliased edge. }
  Result := InflateRectangle(PointsBounds(Points), Width div 2 + 1);
end;

function IsNear(X, Y, TargetX, TargetY, Reach: LongInt): Boolean;
begin
  Result := (Abs(X - TargetX) <= Reach) and (Abs(Y - TargetY) <= Reach);
end;

end.
