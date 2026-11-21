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
  Dashing: polylines cut into the dashes of a dash pattern (SVG's
  stroke-dasharray and stroke-dashoffset, the canvas API's setLineDash),
  before they are stroked.

  The pattern alternates dash and gap lengths; an odd number of lengths
  is used twice over (5,3,2 is 5,3,2,5,3,2). Every subpath starts the
  pattern again, Offset into it (a negative offset starts before it). A
  closed subpath is dashed all the way round, its closing segment too.
  A dash of no length is kept as a polyline of one point, which round
  and square caps draw as a dot.
}
unit Drawing.Dashing;

{$mode objfpc}

interface

uses
  Drawing.Rasterizer,
  Drawing.Paths;

{ The dashes of Lines (open polylines). Lines unchanged if the pattern
  is empty, has a negative length or adds up to nothing. }
function DashPolylines(const Lines: TPolylines; const Pattern: array of Double; Offset: Double): TPolylines;

implementation

type
  TDashOutput = record
    Lines: TPolylines;
    Count: LongInt;
    Open: Boolean;
  end;

procedure StartDash(var Output: TDashOutput; const Point: TPrecisePoint);
begin
  if Output.Count = Length(Output.Lines) then
    SetLength(Output.Lines, 2 * Output.Count + 8);
  Output.Lines[Output.Count].Points := nil;
  SetLength(Output.Lines[Output.Count].Points, 4);
  Output.Lines[Output.Count].Points[0] := Point;
  Output.Lines[Output.Count].Count := 1;
  Output.Lines[Output.Count].Closed := False;
  Inc(Output.Count);
  Output.Open := True;
end;

procedure ExtendDash(var Output: TDashOutput; const Point: TPrecisePoint);
var
  Line: ^TPolyline;
begin
  Line := @Output.Lines[Output.Count - 1];
  if (Line^.Points[Line^.Count - 1].X = Point.X) and (Line^.Points[Line^.Count - 1].Y = Point.Y) then
    Exit;
  if Line^.Count = Length(Line^.Points) then
    SetLength(Line^.Points, 2 * Line^.Count);
  Line^.Points[Line^.Count] := Point;
  Inc(Line^.Count);
end;

function DashPolylines(const Lines: TPolylines; const Pattern: array of Double; Offset: Double): TPolylines;
var
  Lengths: array of Double;
  Count: LongInt;
  Index: LongInt;
  Total: Double;
  Output: TDashOutput;
  LineIndex: LongInt;
  Segment: LongInt;
  Segments: LongInt;
  DashIndex: LongInt;
  Left: Double;
  DashOn: Boolean;
  From, Target: TPrecisePoint;
  SegmentLength: Double;
  Position: Double;
  Step: Double;
  T: Double;
  Point: TPrecisePoint;
begin
  Result := Lines;
  Count := Length(Pattern);
  if Count = 0 then
    Exit;
  Total := 0;
  for Index := 0 to Count - 1 do
  begin
    if Pattern[Index] < 0 then
      Exit;
    Total := Total + Pattern[Index];
  end;
  if Total <= 0 then
    Exit;
  Lengths := nil;
  if Odd(Count) then
  begin
    SetLength(Lengths, 2 * Count);
    for Index := 0 to Count - 1 do
    begin
      Lengths[Index] := Pattern[Index];
      Lengths[Index + Count] := Pattern[Index];
    end;
    Total := 2 * Total;
  end
  else
  begin
    SetLength(Lengths, Count);
    for Index := 0 to Count - 1 do
      Lengths[Index] := Pattern[Index];
  end;
  Count := Length(Lengths);
  Output.Lines := nil;
  Output.Count := 0;
  for LineIndex := 0 to High(Lines) do
  begin
    if Lines[LineIndex].Count < 2 then
      Continue;
    { Where in the pattern the subpath starts. }
    Position := Offset - Trunc(Offset / Total) * Total;
    if Position < 0 then
      Position := Position + Total;
    DashIndex := 0;
    while Position >= Lengths[DashIndex] do
    begin
      Position := Position - Lengths[DashIndex];
      DashIndex := (DashIndex + 1) mod Count;
    end;
    Left := Lengths[DashIndex] - Position;
    DashOn := not Odd(DashIndex);
    Output.Open := False;
    Segments := Lines[LineIndex].Count - 1;
    if Lines[LineIndex].Closed then
      Inc(Segments);
    for Segment := 0 to Segments - 1 do
    begin
      From := Lines[LineIndex].Points[Segment];
      Target := Lines[LineIndex].Points[(Segment + 1) mod Lines[LineIndex].Count];
      SegmentLength := Sqrt(Sqr(Target.X - From.X) + Sqr(Target.Y - From.Y));
      if DashOn and not Output.Open then
        StartDash(Output, From);
      Position := 0;
      while SegmentLength - Position > Left do
      begin
        Position := Position + Left;
        T := Position / SegmentLength;
        Point := PrecisePoint(From.X + (Target.X - From.X) * T, From.Y + (Target.Y - From.Y) * T);
        if DashOn then
        begin
          ExtendDash(Output, Point);
          Output.Open := False;
        end
        else
          StartDash(Output, Point);
        DashOn := not DashOn;
        DashIndex := (DashIndex + 1) mod Count;
        Left := Lengths[DashIndex];
        { Dashes of no length end where they start. }
        while (Left = 0) do
        begin
          if DashOn then
            Output.Open := False
          else
            StartDash(Output, Point);
          DashOn := not DashOn;
          DashIndex := (DashIndex + 1) mod Count;
          Left := Lengths[DashIndex];
        end;
      end;
      Step := SegmentLength - Position;
      Left := Left - Step;
      if DashOn then
        ExtendDash(Output, Target);
    end;
  end;
  SetLength(Output.Lines, Output.Count);
  Result := Output.Lines;
end;

end.
