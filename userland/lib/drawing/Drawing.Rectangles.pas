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
  Rectangles: Left and Top inside, Right and Bottom just outside, so a
  rectangle's width is Right - Left and two rectangles side by side
  share an edge value. Empty if either size is zero or less.
}
unit Drawing.Rectangles;

{$mode objfpc}

interface

type
  TRectangle = record
    Left: LongInt;
    Top: LongInt;
    Right: LongInt;
    Bottom: LongInt;
  end;
  PRectangle = ^TRectangle;

  TPoint = record
    X: LongInt;
    Y: LongInt;
  end;

function MakeRectangle(Left, Top, Width, Height: LongInt): TRectangle;
function MakePoint(X, Y: LongInt): TPoint;
function RectangleWidth(const Rectangle: TRectangle): LongInt;
function RectangleHeight(const Rectangle: TRectangle): LongInt;
function RectangleIsEmpty(const Rectangle: TRectangle): Boolean;
function RectanglesAreEqual(const First, Second: TRectangle): Boolean;
function RectangleContainsPoint(const Rectangle: TRectangle; X, Y: LongInt): Boolean;
{ True if Inner lies entirely in Outer (an empty Inner always does). }
function RectangleContains(const Outer, Inner: TRectangle): Boolean;
{ The common part; False (and Common empty) if there is none. }
function IntersectRectangles(const First, Second: TRectangle; out Common: TRectangle): Boolean;
{ The smallest rectangle holding both (an empty one adds nothing). }
function BoundingRectangle(const First, Second: TRectangle): TRectangle;
function OffsetRectangle(const Rectangle: TRectangle; DeltaX, DeltaY: LongInt): TRectangle;
{ Grown by Amount on every side (shrunk if negative). }
function InflateRectangle(const Rectangle: TRectangle; Amount: LongInt): TRectangle;

implementation

function MakeRectangle(Left, Top, Width, Height: LongInt): TRectangle;
begin
  Result.Left := Left;
  Result.Top := Top;
  Result.Right := Left + Width;
  Result.Bottom := Top + Height;
end;

function MakePoint(X, Y: LongInt): TPoint;
begin
  Result.X := X;
  Result.Y := Y;
end;

function RectangleWidth(const Rectangle: TRectangle): LongInt;
begin
  Result := Rectangle.Right - Rectangle.Left;
end;

function RectangleHeight(const Rectangle: TRectangle): LongInt;
begin
  Result := Rectangle.Bottom - Rectangle.Top;
end;

function RectangleIsEmpty(const Rectangle: TRectangle): Boolean;
begin
  Result := (Rectangle.Right <= Rectangle.Left) or (Rectangle.Bottom <= Rectangle.Top);
end;

function RectanglesAreEqual(const First, Second: TRectangle): Boolean;
begin
  Result := (First.Left = Second.Left) and (First.Top = Second.Top) and (First.Right = Second.Right) and
    (First.Bottom = Second.Bottom);
end;

function RectangleContainsPoint(const Rectangle: TRectangle; X, Y: LongInt): Boolean;
begin
  Result := (X >= Rectangle.Left) and (X < Rectangle.Right) and (Y >= Rectangle.Top) and (Y < Rectangle.Bottom);
end;

function RectangleContains(const Outer, Inner: TRectangle): Boolean;
begin
  if RectangleIsEmpty(Inner) then
    Exit(True);
  Result := (Inner.Left >= Outer.Left) and (Inner.Top >= Outer.Top) and (Inner.Right <= Outer.Right) and
    (Inner.Bottom <= Outer.Bottom);
end;

function Larger(First, Second: LongInt): LongInt;
begin
  if First > Second then
    Result := First
  else
    Result := Second;
end;

function Smaller(First, Second: LongInt): LongInt;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

function IntersectRectangles(const First, Second: TRectangle; out Common: TRectangle): Boolean;
begin
  Common.Left := Larger(First.Left, Second.Left);
  Common.Top := Larger(First.Top, Second.Top);
  Common.Right := Smaller(First.Right, Second.Right);
  Common.Bottom := Smaller(First.Bottom, Second.Bottom);
  Result := not RectangleIsEmpty(Common);
  if not Result then
    Common := MakeRectangle(0, 0, 0, 0);
end;

function BoundingRectangle(const First, Second: TRectangle): TRectangle;
begin
  if RectangleIsEmpty(First) then
    Exit(Second);
  if RectangleIsEmpty(Second) then
    Exit(First);
  Result.Left := Smaller(First.Left, Second.Left);
  Result.Top := Smaller(First.Top, Second.Top);
  Result.Right := Larger(First.Right, Second.Right);
  Result.Bottom := Larger(First.Bottom, Second.Bottom);
end;

function OffsetRectangle(const Rectangle: TRectangle; DeltaX, DeltaY: LongInt): TRectangle;
begin
  Result.Left := Rectangle.Left + DeltaX;
  Result.Top := Rectangle.Top + DeltaY;
  Result.Right := Rectangle.Right + DeltaX;
  Result.Bottom := Rectangle.Bottom + DeltaY;
end;

function InflateRectangle(const Rectangle: TRectangle; Amount: LongInt): TRectangle;
begin
  Result.Left := Rectangle.Left - Amount;
  Result.Top := Rectangle.Top - Amount;
  Result.Right := Rectangle.Right + Amount;
  Result.Bottom := Rectangle.Bottom + Amount;
end;

end.
