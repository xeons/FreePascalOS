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
  Stroking: the outline of a line of some width drawn along polylines,
  with SVG's and the canvas API's caps (butt, round, square), joins
  (miter within a limit, else bevel; round; bevel) and miter limit.

  The stroke comes out as pieces that overlap: a rectangle along every
  segment, a wedge or disc at every corner, a cap at each open end. All
  pieces go the same way round, so the rasterizer's non-zero rule fills
  their union, and where they overlap nothing is blended twice.

  Work in the space the stroke width is given in (an SVG element's user
  space) and transform the pieces afterwards (TransformPolylines), so
  that a stroke under a skewing or unequal scaling transform is skewed
  and scaled with it.
}
unit Drawing.Stroking;

{$mode objfpc}

interface

uses
  Drawing.Rasterizer,
  Drawing.Paths;

type
  TLineCap = (LineCapButt, LineCapRound, LineCapSquare);
  TLineJoin = (LineJoinMiter, LineJoinRound, LineJoinBevel, LineJoinMiterClip, LineJoinArcs);

  TStrokeStyle = record
    Width: Double;
    Cap: TLineCap;
    Join: TLineJoin;
    { The longest a miter may be, in stroke widths. }
    MiterLimit: Double;
  end;

function DefaultStrokeStyle(Width: Double): TStrokeStyle;
{ The pieces of the stroke along Lines; Tolerance is how far round
  parts may stray from circles (in the lines' space). }
function StrokePolylines(const Lines: TPolylines; const Style: TStrokeStyle; Tolerance: Double): TPolylines;

implementation

uses
  Math;

type
  TPieceList = record
    Pieces: TPolylines;
    Count: LongInt;
    Tolerance: Double;
  end;

function DefaultStrokeStyle(Width: Double): TStrokeStyle;
begin
  Result.Width := Width;
  Result.Cap := LineCapButt;
  Result.Join := LineJoinMiter;
  Result.MiterLimit := 4;
end;

{ Twice the signed area. }
function SignedArea(const Points: array of TPrecisePoint; Count: LongInt): Double;
var
  Index: LongInt;
  Next: LongInt;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
  begin
    Next := (Index + 1) mod Count;
    Result := Result + Points[Index].X * Points[Next].Y - Points[Next].X * Points[Index].Y;
  end;
end;

procedure AddPiece(var List: TPieceList; const Points: array of TPrecisePoint);
var
  Index: LongInt;
  Count: LongInt;
  Reverse: Boolean;
begin
  Count := Length(Points);
  if Count < 3 then
    Exit;
  Reverse := SignedArea(Points, Count) < 0;
  if List.Count = Length(List.Pieces) then
    SetLength(List.Pieces, 2 * List.Count + 16);
  List.Pieces[List.Count].Points := nil;
  SetLength(List.Pieces[List.Count].Points, Count);
  for Index := 0 to Count - 1 do
    if Reverse then
      List.Pieces[List.Count].Points[Index] := Points[Count - 1 - Index]
    else
      List.Pieces[List.Count].Points[Index] := Points[Index];
  List.Pieces[List.Count].Count := Count;
  List.Pieces[List.Count].Closed := True;
  Inc(List.Count);
end;

procedure AddDisc(var List: TPieceList; CentreX, CentreY, Radius: Double);
var
  Sides: LongInt;
  Side: LongInt;
  Points: array of TPrecisePoint;
  Angle: Double;
begin
  if Radius <= 0 then
    Exit;
  if Radius <= List.Tolerance then
    Sides := 8
  else
    Sides := Ceil(Pi / ArcCos(1 - List.Tolerance / Radius));
  if Sides < 8 then
    Sides := 8;
  if Sides > 512 then
    Sides := 512;
  Points := nil;
  SetLength(Points, Sides);
  for Side := 0 to Sides - 1 do
  begin
    Angle := 2 * Pi * Side / Sides;
    Points[Side] := PrecisePoint(CentreX + Radius * Cos(Angle), CentreY + Radius * Sin(Angle));
  end;
  AddPiece(List, Points);
end;

procedure AddQuad(var List: TPieceList; const P0, P1, P2, P3: TPrecisePoint);
var
  Points: array[0..3] of TPrecisePoint;
begin
  Points[0] := P0;
  Points[1] := P1;
  Points[2] := P2;
  Points[3] := P3;
  AddPiece(List, Points);
end;

procedure AddTriangle(var List: TPieceList; const P0, P1, P2: TPrecisePoint);
var
  Points: array[0..2] of TPrecisePoint;
begin
  Points[0] := P0;
  Points[1] := P1;
  Points[2] := P2;
  AddPiece(List, Points);
end;

function Offset(const Point: TPrecisePoint; DX, DY, Distance: Double): TPrecisePoint;
begin
  Result.X := Point.X + DX * Distance;
  Result.Y := Point.Y + DY * Distance;
end;

{ The unit direction from From to Target; False if they are one point. }
function Direction(const From, Target: TPrecisePoint; out DX, DY: Double): Boolean;
var
  Length: Double;
begin
  DX := Target.X - From.X;
  DY := Target.Y - From.Y;
  Length := Sqrt(DX * DX + DY * DY);
  if Length < 1E-12 then
  begin
    DX := 1;
    DY := 0;
    Exit(False);
  end;
  DX := DX / Length;
  DY := DY / Length;
  Result := True;
end;

procedure AddSegment(var List: TPieceList; const From, Target: TPrecisePoint; HalfWidth: Double);
var
  DX, DY: Double;
begin
  if not Direction(From, Target, DX, DY) then
    Exit;
  { The left normal is (-DY, DX). }
  AddQuad(List, Offset(From, -DY, DX, HalfWidth), Offset(Target, -DY, DX, HalfWidth),
    Offset(Target, DY, -DX, HalfWidth), Offset(From, DY, -DX, HalfWidth));
end;

procedure AddJoin(var List: TPieceList; const Previous, Corner, Next: TPrecisePoint; const Style: TStrokeStyle);
var
  InX, InY, OutX, OutY: Double;
  HalfWidth: Double;
  Cross, Dot: Double;
  Side: Double;
  Normal0X, Normal0Y, Normal1X, Normal1Y: Double;
  SumX, SumY, SumSquare: Double;
  CosHalf: Double;
  OuterIn, OuterOut, Tip: TPrecisePoint;
begin
  if not Direction(Previous, Corner, InX, InY) or not Direction(Corner, Next, OutX, OutY) then
    Exit;
  HalfWidth := Style.Width / 2;
  Cross := InX * OutY - InY * OutX;
  Dot := InX * OutX + InY * OutY;
  { Straight on: the segments' rectangles meet exactly. }
  if (Abs(Cross) < 1E-9) and (Dot > 0) then
    Exit;
  if Style.Join = LineJoinRound then
  begin
    AddDisc(List, Corner.X, Corner.Y, HalfWidth);
    Exit;
  end;
  { The outer side is away from the turn. }
  if Cross > 0 then
    Side := -1
  else
    Side := 1;
  Normal0X := -InY * Side;
  Normal0Y := InX * Side;
  Normal1X := -OutY * Side;
  Normal1Y := OutX * Side;
  OuterIn := Offset(Corner, Normal0X, Normal0Y, HalfWidth);
  OuterOut := Offset(Corner, Normal1X, Normal1Y, HalfWidth);
  if Style.Join in [LineJoinMiter, LineJoinMiterClip, LineJoinArcs] then
  begin
    SumX := Normal0X + Normal1X;
    SumY := Normal0Y + Normal1Y;
    SumSquare := SumX * SumX + SumY * SumY;
    { cos of half the turn: the miter is 1 / that stroke widths long. }
    CosHalf := Sqrt(SumSquare) / 2;
    if (CosHalf > 1E-9) and (1 / CosHalf <= Style.MiterLimit) then
    begin
      Tip.X := Corner.X + SumX * 2 * HalfWidth / SumSquare;
      Tip.Y := Corner.Y + SumY * 2 * HalfWidth / SumSquare;
      AddQuad(List, Corner, OuterIn, Tip, OuterOut);
      Exit;
    end;
  end;
  AddTriangle(List, Corner, OuterIn, OuterOut);
end;

{ A cap at End, the line arriving there in direction (DX, DY). }
procedure AddCap(var List: TPieceList; const EndPoint: TPrecisePoint; DX, DY: Double; const Style: TStrokeStyle);
var
  HalfWidth: Double;
  Beyond: TPrecisePoint;
begin
  HalfWidth := Style.Width / 2;
  case Style.Cap of
    LineCapRound:
      AddDisc(List, EndPoint.X, EndPoint.Y, HalfWidth);
    LineCapSquare:
      begin
        Beyond := Offset(EndPoint, DX, DY, HalfWidth);
        AddQuad(List, Offset(EndPoint, -DY, DX, HalfWidth), Offset(Beyond, -DY, DX, HalfWidth),
          Offset(Beyond, DY, -DX, HalfWidth), Offset(EndPoint, DY, -DX, HalfWidth));
      end;
  end;
end;

procedure StrokeOne(var List: TPieceList; const Line: TPolyline; const Style: TStrokeStyle);
var
  Index: LongInt;
  Count: LongInt;
  HalfWidth: Double;
  DX, DY: Double;
  Points: array[0..3] of TPrecisePoint;
begin
  Count := Line.Count;
  HalfWidth := Style.Width / 2;
  if Count = 0 then
    Exit;
  if Count = 1 then
  begin
    { A subpath of no length: a dot for round caps, a square for square
      ones (lined up with the axes), nothing for butt caps. }
    case Style.Cap of
      LineCapRound:
        AddDisc(List, Line.Points[0].X, Line.Points[0].Y, HalfWidth);
      LineCapSquare:
        begin
          Points[0] := PrecisePoint(Line.Points[0].X - HalfWidth, Line.Points[0].Y - HalfWidth);
          Points[1] := PrecisePoint(Line.Points[0].X + HalfWidth, Line.Points[0].Y - HalfWidth);
          Points[2] := PrecisePoint(Line.Points[0].X + HalfWidth, Line.Points[0].Y + HalfWidth);
          Points[3] := PrecisePoint(Line.Points[0].X - HalfWidth, Line.Points[0].Y + HalfWidth);
          AddPiece(List, Points);
        end;
    end;
    Exit;
  end;
  for Index := 0 to Count - 2 do
    AddSegment(List, Line.Points[Index], Line.Points[Index + 1], HalfWidth);
  if Line.Closed and (Count > 2) then
  begin
    AddSegment(List, Line.Points[Count - 1], Line.Points[0], HalfWidth);
    for Index := 0 to Count - 1 do
      AddJoin(List, Line.Points[(Index + Count - 1) mod Count], Line.Points[Index], Line.Points[(Index + 1) mod Count],
        Style);
  end
  else
  begin
    for Index := 1 to Count - 2 do
      AddJoin(List, Line.Points[Index - 1], Line.Points[Index], Line.Points[Index + 1], Style);
    Direction(Line.Points[1], Line.Points[0], DX, DY);
    AddCap(List, Line.Points[0], DX, DY, Style);
    Direction(Line.Points[Count - 2], Line.Points[Count - 1], DX, DY);
    AddCap(List, Line.Points[Count - 1], DX, DY, Style);
  end;
end;

function StrokePolylines(const Lines: TPolylines; const Style: TStrokeStyle; Tolerance: Double): TPolylines;
var
  List: TPieceList;
  Index: LongInt;
begin
  Result := nil;
  if Style.Width <= 0 then
    Exit;
  List.Pieces := nil;
  List.Count := 0;
  List.Tolerance := Tolerance;
  if List.Tolerance <= 0 then
    List.Tolerance := DefaultFlatteningTolerance;
  for Index := 0 to High(Lines) do
    StrokeOne(List, Lines[Index], Style);
  SetLength(List.Pieces, List.Count);
  Result := List.Pieces;
end;

end.
