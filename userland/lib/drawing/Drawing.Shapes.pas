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
  Shapes: lines, ellipses and polygons, drawn as spans (so clipped and
  blended like everything on a canvas).

  Lines include both end points (Bresenham's steps, the same pixels
  whichever end is given first). An ellipse fills the pixels whose
  centres lie in the ellipse that touches its bounding rectangle's
  edges; its outline is those of them next to a pixel outside. A polygon
  fills the pixels whose centres are inside it, by the even-odd rule.
}
unit Drawing.Shapes;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas;

procedure DrawLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: LongInt; Color: TColor);
procedure FillEllipse(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
procedure DrawEllipseOutline(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
procedure FillPolygon(const Canvas: TCanvas; const Points: array of TPoint; Color: TColor);
{ The polygon's edges as lines, closing back to the first point. }
procedure DrawPolygonOutline(const Canvas: TCanvas; const Points: array of TPoint; Color: TColor);

implementation

procedure DrawLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: LongInt; Color: TColor);
var
  DeltaX: LongInt;
  DeltaY: LongInt;
  StepX: LongInt;
  StepY: LongInt;
  Error: LongInt;
  Doubled: LongInt;
  Swap: LongInt;
begin
  { Always from the upper end (or the left, if level), so the pixels do
    not depend on the order the ends are given in. }
  if (FromY > ToY) or ((FromY = ToY) and (FromX > ToX)) then
  begin
    Swap := FromX;
    FromX := ToX;
    ToX := Swap;
    Swap := FromY;
    FromY := ToY;
    ToY := Swap;
  end;
  DeltaX := Abs(ToX - FromX);
  DeltaY := -Abs(ToY - FromY);
  if FromX < ToX then
    StepX := 1
  else
    StepX := -1;
  StepY := 1;
  Error := DeltaX + DeltaY;
  repeat
    DrawPixel(Canvas, FromX, FromY, Color);
    if (FromX = ToX) and (FromY = ToY) then
      Break;
    Doubled := 2 * Error;
    if Doubled >= DeltaY then
    begin
      Error := Error + DeltaY;
      FromX := FromX + StepX;
    end;
    if Doubled <= DeltaX then
    begin
      Error := Error + DeltaX;
      FromY := FromY + StepY;
    end;
  until False;
end;

function IntegerSquareRoot(Value: QWord): QWord;
var
  Bit: QWord;
begin
  Result := 0;
  Bit := QWord(1) shl 62;
  while Bit > Value do
    Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Value >= Result + Bit then
    begin
      Value := Value - (Result + Bit);
      Result := (Result shr 1) + Bit;
    end
    else
      Result := Result shr 1;
    Bit := Bit shr 2;
  end;
end;

{ Value / 2 rounded down, negative values too. }
function FloorHalf(Value: Int64): Int64;
begin
  if Value >= 0 then
    Result := Value div 2
  else
    Result := -((-Value + 1) div 2);
end;

{ The pixels of the ellipse in Bounds on row Y: Left to Right inclusive;
  False if none. Worked in doubled coordinates, so everything stays
  whole: pixel x's centre is 2x + 1, the ellipse's centre L + R (and
  T + B), its radii the width W and height H. The pixel is inside if
  (dx / W)^2 + (dy / H)^2 <= 1, dx and dy the doubled distances. }
function EllipseRow(const Bounds: TRectangle; Y: LongInt; out Left, Right: LongInt): Boolean;
var
  Width: Int64;
  Height: Int64;
  DoubledCentreX: Int64;
  DoubledDistanceY: Int64;
  Remaining: Int64;
  Reach: Int64;
begin
  Left := 0;
  Right := -1;
  Width := RectangleWidth(Bounds);
  Height := RectangleHeight(Bounds);
  if (Width <= 0) or (Height <= 0) or (Y < Bounds.Top) or (Y >= Bounds.Bottom) then
    Exit(False);
  { Against the doubled centre less one, 2x stands for the centre 2x + 1. }
  DoubledCentreX := Int64(Bounds.Left) + Bounds.Right - 1;
  DoubledDistanceY := Abs(2 * Int64(Y) - (Int64(Bounds.Top) + Bounds.Bottom - 1));
  Remaining := Height * Height - DoubledDistanceY * DoubledDistanceY;
  if Remaining < 0 then
    Exit(False);
  { The largest doubled distance in x still inside: Width * sqrt(Remaining) / Height. }
  Reach := Int64(IntegerSquareRoot(QWord(Width * Width * Remaining))) div Height;
  { Pixel x is inside if |2x - DoubledCentreX| <= Reach: from the
    smallest x with 2x >= DoubledCentreX - Reach to the largest with
    2x <= DoubledCentreX + Reach. }
  Left := LongInt(-FloorHalf(Reach - DoubledCentreX));
  Right := LongInt(FloorHalf(DoubledCentreX + Reach));
  Result := Left <= Right;
end;

procedure FillEllipse(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
var
  Y: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  for Y := Bounds.Top to Bounds.Bottom - 1 do
    if EllipseRow(Bounds, Y, Left, Right) then
      FillSpan(Canvas, Y + Canvas.OriginY, Left + Canvas.OriginX, Right + 1 + Canvas.OriginX, Color);
end;

procedure DrawEllipseOutline(const Canvas: TCanvas; const Bounds: TRectangle; Color: TColor);
var
  Y: LongInt;
  Left: LongInt;
  Right: LongInt;
  AboveLeft: LongInt;
  AboveRight: LongInt;
  BelowLeft: LongInt;
  BelowRight: LongInt;
  InnerLeft: LongInt;
  InnerRight: LongInt;
begin
  for Y := Bounds.Top to Bounds.Bottom - 1 do
  begin
    if not EllipseRow(Bounds, Y, Left, Right) then
      Continue;
    { Inside, not at the row's ends, and covered above and below: not on
      the outline. }
    InnerLeft := Left + 1;
    InnerRight := Right - 1;
    if EllipseRow(Bounds, Y - 1, AboveLeft, AboveRight) and EllipseRow(Bounds, Y + 1, BelowLeft, BelowRight) then
    begin
      if AboveLeft > InnerLeft then
        InnerLeft := AboveLeft;
      if BelowLeft > InnerLeft then
        InnerLeft := BelowLeft;
      if AboveRight < InnerRight then
        InnerRight := AboveRight;
      if BelowRight < InnerRight then
        InnerRight := BelowRight;
    end
    else
    begin
      InnerLeft := Right + 1;
      InnerRight := Right;
    end;
    if InnerLeft > InnerRight then
      FillSpan(Canvas, Y + Canvas.OriginY, Left + Canvas.OriginX, Right + 1 + Canvas.OriginX, Color)
    else
    begin
      FillSpan(Canvas, Y + Canvas.OriginY, Left + Canvas.OriginX, InnerLeft + Canvas.OriginX, Color);
      FillSpan(Canvas, Y + Canvas.OriginY, InnerRight + 1 + Canvas.OriginX, Right + 1 + Canvas.OriginX, Color);
    end;
  end;
end;

{ The smallest whole number at least Value. }
function Ceiling(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Value > Result then
    Inc(Result);
end;

procedure FillPolygon(const Canvas: TCanvas; const Points: array of TPoint; Color: TColor);
var
  Top: LongInt;
  Bottom: LongInt;
  Index: LongInt;
  Next: LongInt;
  Y: LongInt;
  CentreY: Double;
  Crossings: array of Double;
  CrossingCount: LongInt;
  First: TPoint;
  Second: TPoint;
  Sorted: LongInt;
  Value: Double;
  Pair: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  if Length(Points) < 3 then
    Exit;
  Top := Points[0].Y;
  Bottom := Points[0].Y;
  for Index := 1 to High(Points) do
  begin
    if Points[Index].Y < Top then
      Top := Points[Index].Y;
    if Points[Index].Y > Bottom then
      Bottom := Points[Index].Y;
  end;
  SetLength(Crossings, Length(Points));
  for Y := Top to Bottom - 1 do
  begin
    CentreY := Y + 0.5;
    CrossingCount := 0;
    for Index := 0 to High(Points) do
    begin
      Next := (Index + 1) mod Length(Points);
      First := Points[Index];
      Second := Points[Next];
      { An edge counts on the rows whose centres lie between its ends
        (the upper end in, the lower out). }
      if ((First.Y <= CentreY) and (Second.Y > CentreY)) or ((Second.Y <= CentreY) and (First.Y > CentreY)) then
      begin
        Crossings[CrossingCount] := First.X + (CentreY - First.Y) * (Second.X - First.X) / (Second.Y - First.Y);
        Inc(CrossingCount);
      end;
    end;
    { Few crossings: insertion sort. }
    for Index := 1 to CrossingCount - 1 do
    begin
      Value := Crossings[Index];
      Sorted := Index - 1;
      while (Sorted >= 0) and (Crossings[Sorted] > Value) do
      begin
        Crossings[Sorted + 1] := Crossings[Sorted];
        Dec(Sorted);
      end;
      Crossings[Sorted + 1] := Value;
    end;
    { Pixels whose centres lie from one crossing (in) to the next (out):
      x + 0.5 >= first and x + 0.5 < second. }
    Pair := 0;
    while Pair + 1 < CrossingCount do
    begin
      Left := Ceiling(Crossings[Pair] - 0.5);
      Right := Ceiling(Crossings[Pair + 1] - 0.5);
      FillSpan(Canvas, Y + Canvas.OriginY, Left + Canvas.OriginX, Right + Canvas.OriginX, Color);
      Pair := Pair + 2;
    end;
  end;
end;

procedure DrawPolygonOutline(const Canvas: TCanvas; const Points: array of TPoint; Color: TColor);
var
  Index: LongInt;
  Next: LongInt;
begin
  for Index := 0 to High(Points) do
  begin
    Next := (Index + 1) mod Length(Points);
    DrawLine(Canvas, Points[Index].X, Points[Index].Y, Points[Next].X, Points[Next].Y, Color);
  end;
end;

end.
