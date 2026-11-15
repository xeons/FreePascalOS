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
  Regions: areas made of rectangles that do not overlap, for clipping
  (what of a window is visible) and for the parts of the screen that
  need drawing again.

  Every operation keeps the rectangles apart: subtracting a rectangle
  splits each one it cuts into at most four (the bands above and below,
  the pieces left and right); adding one first subtracts it from what is
  there. The rectangles are in no particular order.
}
unit Drawing.Regions;

{$mode objfpc}

interface

uses
  Drawing.Rectangles;

type
  TRegion = record
    Rectangles: array of TRectangle;
    Count: LongInt;
  end;

procedure ClearRegion(out Region: TRegion);
procedure SetRegionToRectangle(out Region: TRegion; const Rectangle: TRectangle);
procedure CopyRegion(const Source: TRegion; out Destination: TRegion);
function RegionIsEmpty(const Region: TRegion): Boolean;
function RegionBounds(const Region: TRegion): TRectangle;
function RegionContainsPoint(const Region: TRegion; X, Y: LongInt): Boolean;
{ The number of pixels covered. }
function RegionArea(const Region: TRegion): Int64;

procedure AddRectangleToRegion(var Region: TRegion; const Rectangle: TRectangle);
procedure SubtractRectangleFromRegion(var Region: TRegion; const Rectangle: TRectangle);
{ Keeps only what lies in Rectangle. }
procedure IntersectRegionWithRectangle(var Region: TRegion; const Rectangle: TRectangle);
procedure AddRegionToRegion(var Region: TRegion; const Other: TRegion);
procedure SubtractRegionFromRegion(var Region: TRegion; const Other: TRegion);
procedure IntersectRegions(var Region: TRegion; const Other: TRegion);
procedure OffsetRegion(var Region: TRegion; DeltaX, DeltaY: LongInt);

implementation

procedure Append(var Region: TRegion; const Rectangle: TRectangle);
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  if Region.Count = Length(Region.Rectangles) then
    SetLength(Region.Rectangles, 2 * Region.Count + 4);
  Region.Rectangles[Region.Count] := Rectangle;
  Inc(Region.Count);
end;

procedure ClearRegion(out Region: TRegion);
begin
  Region.Rectangles := nil;
  Region.Count := 0;
end;

procedure SetRegionToRectangle(out Region: TRegion; const Rectangle: TRectangle);
begin
  ClearRegion(Region);
  Append(Region, Rectangle);
end;

procedure CopyRegion(const Source: TRegion; out Destination: TRegion);
begin
  Destination.Rectangles := Copy(Source.Rectangles, 0, Source.Count);
  Destination.Count := Source.Count;
end;

function RegionIsEmpty(const Region: TRegion): Boolean;
begin
  Result := Region.Count = 0;
end;

function RegionBounds(const Region: TRegion): TRectangle;
var
  Index: LongInt;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  for Index := 0 to Region.Count - 1 do
    Result := BoundingRectangle(Result, Region.Rectangles[Index]);
end;

function RegionContainsPoint(const Region: TRegion; X, Y: LongInt): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to Region.Count - 1 do
    if RectangleContainsPoint(Region.Rectangles[Index], X, Y) then
      Exit(True);
  Result := False;
end;

function RegionArea(const Region: TRegion): Int64;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to Region.Count - 1 do
    Result := Result + Int64(RectangleWidth(Region.Rectangles[Index])) * RectangleHeight(Region.Rectangles[Index]);
end;

{ Appends to Pieces what of Piece lies outside Cut (up to four parts). }
procedure AppendOutside(var Pieces: TRegion; const Piece, Cut: TRectangle);
var
  Common: TRectangle;
begin
  if not IntersectRectangles(Piece, Cut, Common) then
  begin
    Append(Pieces, Piece);
    Exit;
  end;
  { Above and below the cut, the whole width. }
  Append(Pieces, MakeRectangle(Piece.Left, Piece.Top, RectangleWidth(Piece), Common.Top - Piece.Top));
  Append(Pieces, MakeRectangle(Piece.Left, Common.Bottom, RectangleWidth(Piece), Piece.Bottom - Common.Bottom));
  { Left and right of it, its height. }
  Append(Pieces, MakeRectangle(Piece.Left, Common.Top, Common.Left - Piece.Left, RectangleHeight(Common)));
  Append(Pieces, MakeRectangle(Common.Right, Common.Top, Piece.Right - Common.Right, RectangleHeight(Common)));
end;

procedure SubtractRectangleFromRegion(var Region: TRegion; const Rectangle: TRectangle);
var
  Pieces: TRegion;
  Index: LongInt;
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  ClearRegion(Pieces);
  for Index := 0 to Region.Count - 1 do
    AppendOutside(Pieces, Region.Rectangles[Index], Rectangle);
  Region := Pieces;
end;

procedure AddRectangleToRegion(var Region: TRegion; const Rectangle: TRectangle);
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  SubtractRectangleFromRegion(Region, Rectangle);
  Append(Region, Rectangle);
end;

procedure IntersectRegionWithRectangle(var Region: TRegion; const Rectangle: TRectangle);
var
  Pieces: TRegion;
  Common: TRectangle;
  Index: LongInt;
begin
  ClearRegion(Pieces);
  for Index := 0 to Region.Count - 1 do
    if IntersectRectangles(Region.Rectangles[Index], Rectangle, Common) then
      Append(Pieces, Common);
  Region := Pieces;
end;

procedure AddRegionToRegion(var Region: TRegion; const Other: TRegion);
var
  Index: LongInt;
begin
  for Index := 0 to Other.Count - 1 do
    AddRectangleToRegion(Region, Other.Rectangles[Index]);
end;

procedure SubtractRegionFromRegion(var Region: TRegion; const Other: TRegion);
var
  Index: LongInt;
begin
  for Index := 0 to Other.Count - 1 do
    SubtractRectangleFromRegion(Region, Other.Rectangles[Index]);
end;

procedure IntersectRegions(var Region: TRegion; const Other: TRegion);
var
  Pieces: TRegion;
  Common: TRectangle;
  First: LongInt;
  Second: LongInt;
begin
  { The rectangles of each are apart, so the pairwise overlaps are too. }
  ClearRegion(Pieces);
  for First := 0 to Region.Count - 1 do
    for Second := 0 to Other.Count - 1 do
      if IntersectRectangles(Region.Rectangles[First], Other.Rectangles[Second], Common) then
        Append(Pieces, Common);
  Region := Pieces;
end;

procedure OffsetRegion(var Region: TRegion; DeltaX, DeltaY: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to Region.Count - 1 do
    Region.Rectangles[Index] := OffsetRectangle(Region.Rectangles[Index], DeltaX, DeltaY);
end;

end.
