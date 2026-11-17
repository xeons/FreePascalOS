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
  Split and scroll rules: where a split container's splitter goes, and
  whether a scrolling panel needs its scroll bars, apart from the
  controls (checked on the host).

  A split container is Total long along its split: the first panel
  (SplitterDistance long), the splitter (SplitterExtent), the second
  panel (the rest). Each panel keeps its minimum if there is room for
  both; if not, the first panel's minimum wins. When the container
  resizes, the fixed panel keeps its extent (none fixed: the distance
  keeps its share of the whole).
}
unit Controls.SplitRules;

{$mode objfpc}
{$H+}

interface

type
  TFixedPanel = (FixedNone, FixedPanel1, FixedPanel2);

{ Distance kept within both panels' minimums. }
function ClampSplitDistance(Distance, Total, SplitterExtent, Panel1Minimum, Panel2Minimum: LongInt): LongInt;
{ The distance after the container went from OldTotal to NewTotal long. }
function ResizedSplitDistance(Fixed: TFixedPanel; Distance, OldTotal, NewTotal, SplitterExtent: LongInt): LongInt;

{ Whether content ContentWidth x ContentHeight needs a horizontal and a
  vertical scroll bar (BarThickness each, taken from the area when
  shown) in an area AreaWidth x AreaHeight. }
procedure NeededScrollBars(ContentWidth, ContentHeight, AreaWidth, AreaHeight, BarThickness: LongInt;
  out Horizontal, Vertical: Boolean);
{ Position within 0 .. Content - Visible. }
function ClampScrollPosition(Position, Content, Visible: LongInt): LongInt;
{ The scroll position that brings Start .. Start + Extent (content
  coordinates) into the view Visible long now at Position: unchanged if
  it is in view, else just far enough (its start shown if it is longer
  than the view). }
function ScrollPositionToShow(Position, Visible, Start, Extent: LongInt): LongInt;

implementation

function ClampSplitDistance(Distance, Total, SplitterExtent, Panel1Minimum, Panel2Minimum: LongInt): LongInt;
var
  Largest: LongInt;
begin
  Largest := Total - SplitterExtent - Panel2Minimum;
  Result := Distance;
  if Result > Largest then
    Result := Largest;
  if Result < Panel1Minimum then
    Result := Panel1Minimum;
  if Result > Total - SplitterExtent then
    Result := Total - SplitterExtent;
  if Result < 0 then
    Result := 0;
end;

function ResizedSplitDistance(Fixed: TFixedPanel; Distance, OldTotal, NewTotal, SplitterExtent: LongInt): LongInt;
begin
  case Fixed of
    FixedPanel1: Result := Distance;
    FixedPanel2: Result := Distance + NewTotal - OldTotal;
  else
    if OldTotal > 0 then
      Result := LongInt((Int64(Distance) * NewTotal + OldTotal div 2) div OldTotal)
    else
      Result := Distance;
  end;
end;

procedure NeededScrollBars(ContentWidth, ContentHeight, AreaWidth, AreaHeight, BarThickness: LongInt;
  out Horizontal, Vertical: Boolean);
begin
  Horizontal := ContentWidth > AreaWidth;
  Vertical := ContentHeight > AreaHeight;
  { Each bar takes room from the other direction. }
  if Vertical and not Horizontal then
    Horizontal := ContentWidth > AreaWidth - BarThickness;
  if Horizontal and not Vertical then
    Vertical := ContentHeight > AreaHeight - BarThickness;
end;

function ClampScrollPosition(Position, Content, Visible: LongInt): LongInt;
begin
  Result := Position;
  if Result > Content - Visible then
    Result := Content - Visible;
  if Result < 0 then
    Result := 0;
end;

function ScrollPositionToShow(Position, Visible, Start, Extent: LongInt): LongInt;
begin
  Result := Position;
  if (Start >= Position) and (Start + Extent <= Position + Visible) then
    Exit;
  if (Extent > Visible) or (Start < Position) then
    Result := Start
  else
    Result := Start + Extent - Visible;
end;

end.
