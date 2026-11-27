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
  The selection: which pixels of the picture are selected.

  A rectangular selection is its bounds. A free-form one is drawn as a
  closed line through pixels; its bounds hold that line, and its mask
  (a byte for each pixel of the bounds, row by row, 1 where selected)
  says which pixels are inside: those whose centre the line goes round
  (more than half of the pixel covered, by the rasterizer). Its outline
  is kept to be drawn. Moving the selection moves bounds and outline
  together; the bounds may then reach past the picture's sides (a
  selection being dragged), and anything outside the picture is simply
  not there.
}
unit Paint.Selection;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Rectangles,
  Paint.ShapeGeometry;

type
  TSelection = class
  private
    FActive: Boolean;
    FBounds: TRectangle;
    FMask: TBytes;
    { The free-form line, relative to the bounds' top left. }
    FOutline: TPointArray;
    function GetOutlinePoint(Index: LongInt): TPoint;
    function GetOutlineCount: LongInt;
  public
    procedure Clear;
    procedure SetRectangle(const Area: TRectangle);
    { A free-form selection round Points (at least three, or it is the
      rectangle holding them). }
    procedure SetFreeForm(const Points: array of TPoint);
    function Contains(X, Y: LongInt): Boolean;
    procedure MoveBy(DeltaX, DeltaY: LongInt);
    procedure MoveTo(Left, Top: LongInt);
    function IsRectangular: Boolean;
    function Width: LongInt;
    function Height: LongInt;
    property Active: Boolean read FActive;
    property Bounds: TRectangle read FBounds;
    { Width x Height bytes, or empty for a rectangle (all selected). }
    property Mask: TBytes read FMask;
    property OutlineCount: LongInt read GetOutlineCount;
    { The free-form line's points, in the picture's pixels. }
    property OutlinePoints[Index: LongInt]: TPoint read GetOutlinePoint;
  end;

{ The mask of the polygon round Points (pixels, their centres joined)
  over Bounds: 1 for each pixel more than half inside. }
function PolygonMask(const Points: array of TPoint; const Bounds: TRectangle): TBytes;

implementation

uses
  Drawing.Rasterizer;

const
  HalfCovered = 128;

function PolygonMask(const Points: array of TPoint; const Bounds: TRectangle): TBytes;
var
  Shape: TCoverageShape;
  Corners: array of TPrecisePoint;
  Coverage: array of Byte;
  Index: LongInt;
begin
  Result := nil;
  if RectangleIsEmpty(Bounds) then
    Exit;
  Corners := nil;
  SetLength(Corners, Length(Points));
  for Index := 0 to High(Points) do
    Corners[Index] := PrecisePoint(Points[Index].X + 0.5, Points[Index].Y + 0.5);
  BeginShape(Shape);
  AddShapePolygon(Shape, Corners);
  Coverage := nil;
  SetLength(Coverage, RectangleWidth(Bounds) * RectangleHeight(Bounds));
  ShapeCoverage(Shape, Bounds, Coverage);
  SetLength(Result, Length(Coverage));
  for Index := 0 to High(Coverage) do
    if Coverage[Index] >= HalfCovered then
      Result[Index] := 1
    else
      Result[Index] := 0;
end;

procedure TSelection.Clear;
begin
  FActive := False;
  FBounds := MakeRectangle(0, 0, 0, 0);
  FMask := nil;
  FOutline := nil;
end;

procedure TSelection.SetRectangle(const Area: TRectangle);
begin
  Clear;
  if RectangleIsEmpty(Area) then
    Exit;
  FActive := True;
  FBounds := Area;
end;

procedure TSelection.SetFreeForm(const Points: array of TPoint);
var
  Area: TRectangle;
  Index: LongInt;
begin
  Area := PointsBounds(Points);
  if Length(Points) < 3 then
  begin
    SetRectangle(Area);
    Exit;
  end;
  Clear;
  FActive := True;
  FBounds := Area;
  FMask := PolygonMask(Points, Area);
  SetLength(FOutline, Length(Points));
  for Index := 0 to High(Points) do
    FOutline[Index] := MakePoint(Points[Index].X - Area.Left, Points[Index].Y - Area.Top);
end;

function TSelection.Contains(X, Y: LongInt): Boolean;
begin
  if not FActive or not RectangleContainsPoint(FBounds, X, Y) then
    Exit(False);
  if Length(FMask) = 0 then
    Exit(True);
  Result := FMask[(Y - FBounds.Top) * Width + (X - FBounds.Left)] <> 0;
end;

procedure TSelection.MoveBy(DeltaX, DeltaY: LongInt);
begin
  FBounds := OffsetRectangle(FBounds, DeltaX, DeltaY);
end;

procedure TSelection.MoveTo(Left, Top: LongInt);
begin
  MoveBy(Left - FBounds.Left, Top - FBounds.Top);
end;

function TSelection.IsRectangular: Boolean;
begin
  Result := Length(FMask) = 0;
end;

function TSelection.Width: LongInt;
begin
  Result := RectangleWidth(FBounds);
end;

function TSelection.Height: LongInt;
begin
  Result := RectangleHeight(FBounds);
end;

function TSelection.GetOutlinePoint(Index: LongInt): TPoint;
begin
  Result := MakePoint(FOutline[Index].X + FBounds.Left, FOutline[Index].Y + FBounds.Top);
end;

function TSelection.GetOutlineCount: LongInt;
begin
  Result := Length(FOutline);
end;

end.
