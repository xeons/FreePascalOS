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
  Hinting: a light autohinter, vertical only.

  The choice: a font's own TrueType instructions are a whole virtual
  machine to run for each glyph and are tuned for the black-and-white
  rendering of their day; what makes small anti-aliased text crisp is
  mostly that horizontal strokes (the baseline, the top of an x, the
  bars of an e or an E) sit on whole pixels rather than smeared over
  two. So the system hints every outline font itself, the way
  FreeType's "light" autohinting does: only up and down, never sideways,
  so advances and letter shapes stay as designed and text measures the
  same hinted or not.

  For each font, once (MeasureBlueZones): its blue zones, the heights
  letters line up on, measured from the letters themselves: the
  baseline (H's foot, o's overshoot below it), the x height (x, o), the
  cap height (H, O), the ascender (l) and the descender (p, g).

  For each glyph at a size (HintOutline, on the outline in pixels):
  - its horizontal edges: runs between two consecutive points that are
    nearly level and not too short, each a top edge (ink below it) or a
    bottom edge (ink above), told apart by the direction the contour
    goes (worked out from its area, whatever way the font winds);
  - an edge in a blue zone of its kind goes to the zone's height
    rounded to a whole pixel (with the overshoot added only once it
    comes to half a pixel or more, so round letters do not poke above
    flat ones at small sizes);
  - a bottom edge and the nearest top edge above it, over the same
    columns and less than a fifth of the em apart, are a stem (a bar,
    a round letter's stroke): its thickness is rounded to whole pixels
    (at least one), and it is put on whole pixels: kept to an edge that
    is already placed, else rounded by its middle;
  - every point then moves by the piecewise-linear map that takes each
    placed edge's height to where it went (points between two edges in
    proportion, those beyond the outermost moved as far as it). Edges
    that were not placed just follow.
}
unit Font.Hinting;

{$mode objfpc}
{$H+}

interface

uses
  Font.Outlines;

{ The font's blue zones (in its BlueZones), if not measured yet. }
procedure MeasureBlueZones(Font: TOutlineFont);
{ Moves Outline's points (pixels, y up from the baseline, Scale pixels
  to a font unit) up or down as described above. }
procedure HintOutline(Font: TOutlineFont; Scale: Double; var Outline: TGlyphOutline);

implementation

const
  { A run counts as level if it climbs at most this much a unit across. }
  LevelSlope = 0.12;
  { Runs shorter than this part of the em are not edges. }
  ShortestEdge = 1 / 50;
  { Edges this part of the em apart, of one kind, are one edge. }
  EdgeTolerance = 1 / 200;
  { How far outside a blue zone an edge may lie and still be in it. }
  ZoneSlack = 1 / 100;
  { The thickest bar taken for a stem. }
  ThickestStem = 1 / 5;

type
  TEdge = record
    Y: Double;
    IsTop: Boolean;
    Left: Double;
    Right: Double;
    Placed: Boolean;
    Target: Double;
    Paired: Boolean;
  end;

  TEdgeList = record
    Items: array of TEdge;
    Count: LongInt;
  end;

  TControlPoint = record
    Y: Double;
    Target: Double;
  end;
  TControlPoints = array of TControlPoint;

{ --- Blue zones ------------------------------------------------------- }

{ The lowest and highest point of a character's outline (font units);
  False if the font has no such character or it is empty. }
function CharacterExtent(Font: TOutlineFont; CodePoint: LongWord; out Bottom, Top: LongInt): Boolean;
var
  Outline: TGlyphOutline;
  Glyph: LongWord;
  Index: LongInt;
  Y: Double;
  Lowest: Double;
  Highest: Double;
begin
  Result := False;
  Bottom := 0;
  Top := 0;
  Glyph := Font.GlyphOf(CodePoint);
  if (Glyph = 0) or not Font.LoadOutline(Glyph, Outline) or (Outline.PointCount = 0) then
    Exit;
  Lowest := Outline.Points[0].Y;
  Highest := Lowest;
  for Index := 1 to Outline.PointCount - 1 do
  begin
    Y := Outline.Points[Index].Y;
    if Y < Lowest then
      Lowest := Y;
    if Y > Highest then
      Highest := Y;
  end;
  Bottom := RoundHalfUp(Lowest);
  Top := RoundHalfUp(Highest);
  Result := True;
end;

procedure AddZone(Font: TOutlineFont; Reference, Overshoot: LongInt; IsTop: Boolean);
begin
  if Font.BlueZones.Count > High(Font.BlueZones.Zones) then
    Exit;
  Font.BlueZones.Zones[Font.BlueZones.Count].Reference := Reference;
  Font.BlueZones.Zones[Font.BlueZones.Count].Overshoot := Overshoot;
  Font.BlueZones.Zones[Font.BlueZones.Count].IsTop := IsTop;
  Inc(Font.BlueZones.Count);
end;

procedure MeasureBlueZones(Font: TOutlineFont);
var
  FlatBottom: LongInt;
  FlatTop: LongInt;
  RoundBottom: LongInt;
  RoundTop: LongInt;
  Ignored: LongInt;
  Second: LongInt;
begin
  if Font.BlueZones.Measured then
    Exit;
  Font.BlueZones.Count := 0;
  { The baseline and the cap height: H flat, O round. }
  if CharacterExtent(Font, Ord('H'), FlatBottom, FlatTop) then
  begin
    if not CharacterExtent(Font, Ord('O'), RoundBottom, RoundTop) then
    begin
      RoundBottom := FlatBottom;
      RoundTop := FlatTop;
    end;
    AddZone(Font, FlatBottom, RoundBottom, False);
    AddZone(Font, FlatTop, RoundTop, True);
  end
  else
    AddZone(Font, 0, 0, False);
  { The x height: x flat, o round (o's bottom overshoots the baseline
    much as O's does). }
  if CharacterExtent(Font, Ord('x'), Ignored, FlatTop) then
  begin
    if not CharacterExtent(Font, Ord('o'), RoundBottom, RoundTop) then
      RoundTop := FlatTop;
    AddZone(Font, FlatTop, RoundTop, True);
  end;
  { The ascender (l) and the descender (p, g). }
  if CharacterExtent(Font, Ord('l'), Ignored, FlatTop) then
    AddZone(Font, FlatTop, FlatTop, True);
  if CharacterExtent(Font, Ord('p'), FlatBottom, Ignored) then
  begin
    if CharacterExtent(Font, Ord('g'), RoundBottom, Ignored) and (RoundBottom < FlatBottom) then
      Second := RoundBottom
    else
      Second := FlatBottom;
    AddZone(Font, FlatBottom, Second, False);
  end;
  Font.BlueZones.Measured := True;
end;

{ --- Edges ------------------------------------------------------------ }

{ Twice the outline's signed area: positive if it winds anticlockwise
  (y up), as PostScript-style fonts do; TrueType's go clockwise. }
function OutlineArea(const Outline: TGlyphOutline): Double;
var
  Contour: LongInt;
  First: LongInt;
  Last: LongInt;
  Index: LongInt;
  Next: LongInt;
begin
  Result := 0;
  First := 0;
  for Contour := 0 to Outline.ContourCount - 1 do
  begin
    Last := Outline.ContourEnds[Contour];
    for Index := First to Last do
    begin
      if Index = Last then
        Next := First
      else
        Next := Index + 1;
      Result := Result + Outline.Points[Index].X * Outline.Points[Next].Y -
        Outline.Points[Next].X * Outline.Points[Index].Y;
    end;
    First := Last + 1;
  end;
end;

procedure AddEdge(var List: TEdgeList; Y, Left, Right: Double; IsTop: Boolean);
begin
  if List.Count = Length(List.Items) then
    SetLength(List.Items, 2 * List.Count + 16);
  List.Items[List.Count].Y := Y;
  List.Items[List.Count].IsTop := IsTop;
  List.Items[List.Count].Left := Left;
  List.Items[List.Count].Right := Right;
  List.Items[List.Count].Placed := False;
  List.Items[List.Count].Target := 0;
  List.Items[List.Count].Paired := False;
  Inc(List.Count);
end;

{ Every level run of the outline, sorted by height, those of a kind
  close together joined. }
procedure FindEdges(const Outline: TGlyphOutline; Em: Double; out Edges: TEdgeList);
var
  Clockwise: Boolean;
  Contour: LongInt;
  First: LongInt;
  Last: LongInt;
  Index: LongInt;
  Next: LongInt;
  DeltaX: Double;
  DeltaY: Double;
  IsTop: Boolean;
  Sorted: LongInt;
  Edge: TEdge;
  Kept: LongInt;
  Previous: LongInt;
  Merged: Boolean;
begin
  Edges.Items := nil;
  Edges.Count := 0;
  Clockwise := OutlineArea(Outline) <= 0;
  First := 0;
  for Contour := 0 to Outline.ContourCount - 1 do
  begin
    Last := Outline.ContourEnds[Contour];
    for Index := First to Last do
    begin
      if Index = Last then
        Next := First
      else
        Next := Index + 1;
      DeltaX := Outline.Points[Next].X - Outline.Points[Index].X;
      DeltaY := Outline.Points[Next].Y - Outline.Points[Index].Y;
      if (Abs(DeltaX) < ShortestEdge * Em) or (Abs(DeltaY) > LevelSlope * Abs(DeltaX)) then
        Continue;
      { Clockwise, the ink is below a run going right. }
      IsTop := (DeltaX > 0) = Clockwise;
      if DeltaX > 0 then
        AddEdge(Edges, 0.5 * (Outline.Points[Index].Y + Outline.Points[Next].Y), Outline.Points[Index].X,
          Outline.Points[Next].X, IsTop)
      else
        AddEdge(Edges, 0.5 * (Outline.Points[Index].Y + Outline.Points[Next].Y), Outline.Points[Next].X,
          Outline.Points[Index].X, IsTop);
    end;
    First := Last + 1;
  end;
  { By height (few edges: insertion sort). }
  for Index := 1 to Edges.Count - 1 do
  begin
    Edge := Edges.Items[Index];
    Sorted := Index - 1;
    while (Sorted >= 0) and (Edges.Items[Sorted].Y > Edge.Y) do
    begin
      Edges.Items[Sorted + 1] := Edges.Items[Sorted];
      Dec(Sorted);
    end;
    Edges.Items[Sorted + 1] := Edge;
  end;
  { Edges of a kind at nearly one height become one, across both. }
  Kept := 0;
  for Index := 0 to Edges.Count - 1 do
  begin
    Edge := Edges.Items[Index];
    Merged := False;
    Previous := Kept - 1;
    while (Previous >= 0) and (Edge.Y - Edges.Items[Previous].Y <= EdgeTolerance * Em) do
    begin
      if Edges.Items[Previous].IsTop = Edge.IsTop then
      begin
        if Edge.Left < Edges.Items[Previous].Left then
          Edges.Items[Previous].Left := Edge.Left;
        if Edge.Right > Edges.Items[Previous].Right then
          Edges.Items[Previous].Right := Edge.Right;
        Merged := True;
        Break;
      end;
      Dec(Previous);
    end;
    if not Merged then
    begin
      Edges.Items[Kept] := Edge;
      Inc(Kept);
    end;
  end;
  Edges.Count := Kept;
end;

{ --- Placing edges ---------------------------------------------------- }

procedure PlaceInZones(Font: TOutlineFont; Scale: Double; var Edges: TEdgeList);
var
  Index: LongInt;
  ZoneIndex: LongInt;
  Zone: TBlueZone;
  Low: Double;
  High: Double;
  Slack: Double;
  Reference: Double;
  Best: Double;
  Distance: Double;
begin
  Slack := ZoneSlack * Font.UnitsPerEm * Scale;
  for Index := 0 to Edges.Count - 1 do
  begin
    Best := -1;
    for ZoneIndex := 0 to Font.BlueZones.Count - 1 do
    begin
      Zone := Font.BlueZones.Zones[ZoneIndex];
      if Zone.IsTop <> Edges.Items[Index].IsTop then
        Continue;
      Low := Zone.Reference * Scale;
      High := Zone.Overshoot * Scale;
      if Low > High then
      begin
        Reference := Low;
        Low := High;
        High := Reference;
      end;
      if (Edges.Items[Index].Y < Low - Slack) or (Edges.Items[Index].Y > High + Slack) then
        Continue;
      Reference := Zone.Reference * Scale;
      Distance := Abs(Edges.Items[Index].Y - Reference);
      if (Best >= 0) and (Distance >= Best) then
        Continue;
      Best := Distance;
      Edges.Items[Index].Target := RoundHalfUp(Reference) + RoundHalfUp(Edges.Items[Index].Y - Reference);
      Edges.Items[Index].Placed := True;
    end;
  end;
end;

function Overlap(const First, Second: TEdge): Boolean;
begin
  Result := (First.Left < Second.Right) and (Second.Left < First.Right);
end;

procedure PlaceStems(Font: TOutlineFont; Scale: Double; var Edges: TEdgeList);
var
  Bottom: LongInt;
  Top: LongInt;
  Found: LongInt;
  Thickness: Double;
  Rounded: LongInt;
  Middle: Double;
begin
  for Bottom := 0 to Edges.Count - 1 do
  begin
    if Edges.Items[Bottom].IsTop or Edges.Items[Bottom].Paired then
      Continue;
    Found := -1;
    for Top := Bottom + 1 to Edges.Count - 1 do
    begin
      if Edges.Items[Top].Y - Edges.Items[Bottom].Y > ThickestStem * Font.UnitsPerEm * Scale then
        Break;
      if Edges.Items[Top].IsTop and not Edges.Items[Top].Paired and
         Overlap(Edges.Items[Bottom], Edges.Items[Top]) then
      begin
        Found := Top;
        Break;
      end;
    end;
    if Found < 0 then
      Continue;
    Edges.Items[Bottom].Paired := True;
    Edges.Items[Found].Paired := True;
    Thickness := Edges.Items[Found].Y - Edges.Items[Bottom].Y;
    Rounded := RoundHalfUp(Thickness);
    if Rounded < 1 then
      Rounded := 1;
    if Edges.Items[Bottom].Placed and Edges.Items[Found].Placed then
      Continue;
    if Edges.Items[Bottom].Placed then
      Edges.Items[Found].Target := Edges.Items[Bottom].Target + Rounded
    else if Edges.Items[Found].Placed then
      Edges.Items[Bottom].Target := Edges.Items[Found].Target - Rounded
    else
    begin
      Middle := 0.5 * (Edges.Items[Bottom].Y + Edges.Items[Found].Y);
      Edges.Items[Bottom].Target := RoundHalfUp(Middle - 0.5 * Rounded);
      Edges.Items[Found].Target := Edges.Items[Bottom].Target + Rounded;
    end;
    Edges.Items[Bottom].Placed := True;
    Edges.Items[Found].Placed := True;
  end;
end;

{ --- Moving the points ------------------------------------------------ }

{ The placed edges as a map from heights to heights: increasing, never
  going down. }
function ControlPointsOf(const Edges: TEdgeList): TControlPoints;
var
  Index: LongInt;
  Count: LongInt;
begin
  Result := nil;
  SetLength(Result, Edges.Count);
  Count := 0;
  for Index := 0 to Edges.Count - 1 do
  begin
    if not Edges.Items[Index].Placed then
      Continue;
    { Edges are sorted by height; one at the height of the last keeps
      the last's place. }
    if (Count > 0) and (Edges.Items[Index].Y - Result[Count - 1].Y < 1E-6) then
      Continue;
    Result[Count].Y := Edges.Items[Index].Y;
    Result[Count].Target := Edges.Items[Index].Target;
    if (Count > 0) and (Result[Count].Target < Result[Count - 1].Target) then
      Result[Count].Target := Result[Count - 1].Target;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function MovedHeight(const Points: TControlPoints; Y: Double): Double;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Last: LongInt;
begin
  Last := Length(Points) - 1;
  if Y <= Points[0].Y then
    Exit(Y + Points[0].Target - Points[0].Y);
  if Y >= Points[Last].Y then
    Exit(Y + Points[Last].Target - Points[Last].Y);
  { The last control point at or below Y. }
  Low := 0;
  High := Last;
  while High - Low > 1 do
  begin
    Middle := (Low + High) div 2;
    if Points[Middle].Y <= Y then
      Low := Middle
    else
      High := Middle;
  end;
  Result := Points[Low].Target + (Y - Points[Low].Y) * (Points[High].Target - Points[Low].Target) /
    (Points[High].Y - Points[Low].Y);
end;

procedure HintOutline(Font: TOutlineFont; Scale: Double; var Outline: TGlyphOutline);
var
  Edges: TEdgeList;
  Points: TControlPoints;
  Index: LongInt;
begin
  if Outline.PointCount = 0 then
    Exit;
  MeasureBlueZones(Font);
  FindEdges(Outline, Font.UnitsPerEm * Scale, Edges);
  PlaceInZones(Font, Scale, Edges);
  PlaceStems(Font, Scale, Edges);
  Points := ControlPointsOf(Edges);
  if Length(Points) = 0 then
    Exit;
  for Index := 0 to Outline.PointCount - 1 do
    Outline.Points[Index].Y := MovedHeight(Points, Outline.Points[Index].Y);
end;

end.
