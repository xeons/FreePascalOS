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
  ControlsTest: libcontrols' layout arithmetic, on the host.

    ControlsTest

  Anchors, docking with margins and padding, size constraints and
  placing in a cell (Controls.LayoutRules), flowing with and without
  wrapping in every direction (Controls.FlowArrangement), table tracks
  sized absolutely, automatically and by percent, with spans, and free
  cells found as the table grows (Controls.TableArrangement), and split
  containers' minimum sizes and fixed panels and scrolling panels' bars
  (Controls.SplitRules). Every check prints a line; the exit code is 1
  if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program ControlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Drawing.Rectangles,
  Controls.LayoutRules,
  Controls.FlowArrangement,
  Controls.TableArrangement,
  Controls.SplitRules;

var
  Checks: LongInt = 0;
  Failures: LongInt = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[controls] pass: ', Name)
  else
  begin
    WriteLn('[controls] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function RectangleText(const Rectangle: TRectangle): string;
begin
  Result := Format('(%d,%d %dx%d)', [Rectangle.Left, Rectangle.Top, RectangleWidth(Rectangle),
    RectangleHeight(Rectangle)]);
end;

procedure CheckRectangle(const Name: string; const Got: TRectangle; Left, Top, Width, Height: LongInt);
var
  Expected: TRectangle;
begin
  Expected := MakeRectangle(Left, Top, Width, Height);
  if not RectanglesAreEqual(Got, Expected) then
    WriteLn('[controls]   got ', RectangleText(Got), ', expected ', RectangleText(Expected));
  Check(Name, RectanglesAreEqual(Got, Expected));
end;

procedure CheckNumber(const Name: string; Got, Expected: LongInt);
begin
  if Got <> Expected then
    WriteLn('[controls]   got ', Got, ', expected ', Expected);
  Check(Name, Got = Expected);
end;

function NoConstraints: TSizeConstraints;
begin
  Result := MakeConstraints(0, 0, 0, 0);
end;

procedure TestAnchors;
var
  Placed: TRectangle;
begin
  { Placed 10,10 50x20 when the client area was 200x100; now 300x150. }
  Placed := MakeRectangle(10, 10, 50, 20);
  CheckRectangle('anchors: left and top keep the place', AnchoredRectangle([akLeft, akTop], Placed, 200, 100, 300, 150,
    NoConstraints), 10, 10, 50, 20);
  CheckRectangle('anchors: right and bottom keep the distances to those edges',
    AnchoredRectangle([akRight, akBottom], Placed, 200, 100, 300, 150, NoConstraints), 110, 60, 50, 20);
  CheckRectangle('anchors: left and right stretch', AnchoredRectangle([akLeft, akTop, akRight], Placed, 200, 100, 300,
    150, NoConstraints), 10, 10, 150, 20);
  CheckRectangle('anchors: all four stretch both ways', AnchoredRectangle([akLeft, akTop, akRight, akBottom], Placed,
    200, 100, 300, 150, NoConstraints), 10, 10, 150, 70);
  CheckRectangle('anchors: neither left nor right keeps the middle at its share',
    AnchoredRectangle([akTop], MakeRectangle(75, 10, 50, 20), 200, 100, 300, 150, NoConstraints), 125, 10, 50, 20);
  CheckRectangle('anchors: neither, at the same size, stays put',
    AnchoredRectangle([], MakeRectangle(33, 17, 51, 21), 200, 100, 200, 100, NoConstraints), 33, 17, 51, 21);
  CheckRectangle('anchors: stretching stops at the maximum width',
    AnchoredRectangle([akLeft, akTop, akRight], Placed, 200, 100, 300, 150, MakeConstraints(0, 0, 80, 0)),
    10, 10, 80, 20);
  CheckRectangle('anchors: a minimum width grows a right-anchored control to the left',
    AnchoredRectangle([akRight, akTop], Placed, 200, 100, 300, 150, MakeConstraints(60, 0, 0, 0)), 100, 10, 60, 20);
  CheckRectangle('anchors: shrinking past nothing leaves an empty control',
    AnchoredRectangle([akLeft, akTop, akRight], Placed, 200, 100, 100, 100, NoConstraints), 10, 10, 0, 20);
  CheckRectangle('anchors: shrinking stops at the minimum width',
    AnchoredRectangle([akLeft, akTop, akRight], Placed, 200, 100, 100, 100, MakeConstraints(30, 0, 0, 0)),
    10, 10, 30, 20);
end;

procedure TestConstraints;
begin
  CheckNumber('constraints: below the minimum', ConstrainExtent(5, 10, 0), 10);
  CheckNumber('constraints: above the maximum', ConstrainExtent(500, 0, 100), 100);
  CheckNumber('constraints: a maximum of 0 is none', ConstrainExtent(500, 0, 0), 500);
  CheckNumber('constraints: never below nothing', ConstrainExtent(-3, 0, 0), 0);
  CheckNumber('constraints: the minimum wins over a smaller maximum', ConstrainExtent(50, 40, 30), 40);
end;

procedure TestDocking;
var
  Remaining: TRectangle;
  Placed: TRectangle;
begin
  Remaining := MakeRectangle(0, 0, 200, 100);
  Placed := DockRectangle(AlignTop, Remaining, MakeSpacing(2, 3, 4, 5), MakeSize(0, 20), NoConstraints);
  CheckRectangle('docking: top, its margins kept clear', Placed, 2, 3, 194, 20);
  CheckRectangle('docking: top takes its strip and margins', Remaining, 0, 28, 200, 72);
  Placed := DockRectangle(AlignBottom, Remaining, UniformSpacing(1), MakeSize(0, 10), NoConstraints);
  CheckRectangle('docking: bottom', Placed, 1, 89, 198, 10);
  CheckRectangle('docking: bottom takes its strip', Remaining, 0, 28, 200, 60);
  Placed := DockRectangle(AlignLeft, Remaining, MakeSpacing(0, 0, 3, 0), MakeSize(40, 0), NoConstraints);
  CheckRectangle('docking: left', Placed, 0, 28, 40, 60);
  Placed := DockRectangle(AlignRight, Remaining, UniformSpacing(0), MakeSize(30, 0), MakeConstraints(50, 0, 0, 20));
  CheckRectangle('docking: right, its minimum width and maximum height kept', Placed, 150, 28, 50, 20);
  CheckRectangle('docking: what is left after the sides', Remaining, 43, 28, 107, 60);
  Placed := DockRectangle(AlignClient, Remaining, UniformSpacing(4), MakeSize(0, 0), NoConstraints);
  CheckRectangle('docking: the client area, inside its margins', Placed, 47, 32, 99, 52);
  CheckRectangle('docking: the client area leaves what is left', Remaining, 43, 28, 107, 60);
  Remaining := MakeRectangle(0, 0, 100, 30);
  DockRectangle(AlignTop, Remaining, UniformSpacing(0), MakeSize(0, 50), NoConstraints);
  CheckRectangle('docking: a strip larger than what is left leaves nothing', Remaining, 0, 30, 100, 0);
  CheckRectangle('padding: the client area inside it', DeflateBySpacing(MakeRectangle(10, 10, 100, 50),
    MakeSpacing(5, 6, 7, 8)), 15, 16, 88, 36);
  CheckRectangle('padding: more than the size leaves nothing', DeflateBySpacing(MakeRectangle(0, 0, 10, 10),
    UniformSpacing(8)), 8, 8, 0, 0);
end;

procedure TestCells;
var
  Cell: TRectangle;
begin
  Cell := MakeRectangle(0, 0, 100, 40);
  CheckRectangle('cell: no anchors centre it', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2), [], False,
    NoConstraints), 35, 10, 30, 20);
  CheckRectangle('cell: left and top', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2), [akLeft, akTop], False,
    NoConstraints), 2, 2, 30, 20);
  CheckRectangle('cell: right and bottom', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2), [akRight, akBottom],
    False, NoConstraints), 68, 18, 30, 20);
  CheckRectangle('cell: left and right stretch across', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2),
    [akLeft, akRight], False, NoConstraints), 2, 10, 96, 20);
  CheckRectangle('cell: filled, inside its margins', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2), [], True,
    NoConstraints), 2, 2, 96, 36);
  CheckRectangle('cell: filled, up to its maximum size', PlaceInCell(Cell, MakeSize(30, 20), UniformSpacing(2), [],
    True, MakeConstraints(0, 0, 50, 0)), 2, 2, 50, 36);
end;

function ThreeItems(Width, Height, Margin: LongInt): TFlowItems;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, 3);
  for Index := 0 to 2 do
    Result[Index] := MakeFlowItem(Width, Height, UniformSpacing(Margin));
end;

procedure TestFlow;
var
  Places: TRectangles;
  Size: TSize;
begin
  Places := ArrangeFlow(ThreeItems(40, 20, 0), MakeRectangle(0, 0, 100, 100), FlowLeftToRight, True);
  CheckRectangle('flow: left to right, first', Places[0], 0, 0, 40, 20);
  CheckRectangle('flow: left to right, second beside it', Places[1], 40, 0, 40, 20);
  CheckRectangle('flow: left to right, third wraps to a new row', Places[2], 0, 20, 40, 20);
  Places := ArrangeFlow(ThreeItems(40, 20, 0), MakeRectangle(10, 5, 100, 100), FlowLeftToRight, False);
  CheckRectangle('flow: without wrapping, past the edge', Places[2], 90, 5, 40, 20);
  Places := ArrangeFlow(ThreeItems(40, 20, 5), MakeRectangle(0, 0, 100, 100), FlowLeftToRight, True);
  CheckRectangle('flow: margins, first', Places[0], 5, 5, 40, 20);
  CheckRectangle('flow: margins, second', Places[1], 55, 5, 40, 20);
  CheckRectangle('flow: margins, wrapped below the row and its margins', Places[2], 5, 35, 40, 20);
  Places := ArrangeFlow(ThreeItems(40, 20, 0), MakeRectangle(0, 0, 100, 100), FlowRightToLeft, True);
  CheckRectangle('flow: right to left, first at the right', Places[0], 60, 0, 40, 20);
  CheckRectangle('flow: right to left, second', Places[1], 20, 0, 40, 20);
  CheckRectangle('flow: right to left, wrapped', Places[2], 60, 20, 40, 20);
  Places := ArrangeFlow(ThreeItems(40, 20, 0), MakeRectangle(0, 0, 100, 50), FlowTopDown, True);
  CheckRectangle('flow: top down, second below', Places[1], 0, 20, 40, 20);
  CheckRectangle('flow: top down, wraps to a new column', Places[2], 40, 0, 40, 20);
  Places := ArrangeFlow(ThreeItems(40, 20, 0), MakeRectangle(0, 0, 100, 50), FlowBottomUp, True);
  CheckRectangle('flow: bottom up, first at the bottom', Places[0], 0, 30, 40, 20);
  CheckRectangle('flow: bottom up, wrapped', Places[2], 40, 30, 40, 20);
  Size := FlowContentSize(ThreeItems(40, 20, 0), FlowLeftToRight, True, 100);
  CheckRectangle('flow: content size, wrapped', MakeRectangle(0, 0, Size.cx, Size.cy), 0, 0, 80, 40);
  Size := FlowContentSize(ThreeItems(40, 20, 0), FlowLeftToRight, False, 100);
  CheckRectangle('flow: content size, one row', MakeRectangle(0, 0, Size.cx, Size.cy), 0, 0, 120, 20);
  Size := FlowContentSize(ThreeItems(40, 20, 2), FlowTopDown, False, 0);
  CheckRectangle('flow: content size, one column with margins', MakeRectangle(0, 0, Size.cx, Size.cy), 0, 0, 44, 72);
end;

function Styles(const Sizings: array of TTrackSizing; const Values: array of LongInt): TTrackStyles;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Sizings));
  for Index := 0 to High(Sizings) do
    Result[Index] := MakeTrackStyle(Sizings[Index], Values[Index]);
end;

procedure AddSpan(var Spans: TTrackSpans; First, Count, Extent: LongInt);
begin
  SetLength(Spans, Length(Spans) + 1);
  Spans[High(Spans)] := MakeTrackSpan(First, Count, Extent);
end;

procedure TestTableTracks;
var
  Columns: TTrackStyles;
  Spans: TTrackSpans;
  Sizes: TTrackSizes;
  Offsets: TTrackSizes;
  RowOffsets: TTrackSizes;
begin
  Columns := Styles([TrackAbsolute, TrackAutoSize, TrackPercent, TrackPercent], [50, 0, 1, 3]);
  Spans := nil;
  AddSpan(Spans, 1, 1, 30);
  AddSpan(Spans, 1, 1, 45);
  AddSpan(Spans, 2, 1, 30);
  AddSpan(Spans, 3, 1, 30);
  Sizes := MeasureTracks(Columns, Spans, 300);
  CheckNumber('table: an absolute column', Sizes[0], 50);
  CheckNumber('table: an automatic column takes its largest item', Sizes[1], 45);
  CheckNumber('table: a percent column takes its share of the rest', Sizes[2], 51);
  CheckNumber('table: the last percent column takes what rounding left', Sizes[3], 154);
  CheckNumber('table: content extent keeps every share large enough', TracksContentExtent(Columns, Spans), 215);
  Sizes := MeasureTracks(Columns, Spans, 60);
  CheckNumber('table: no room left, percent columns get nothing', Sizes[2] + Sizes[3], 0);
  Columns := Styles([TrackAutoSize, TrackAutoSize, TrackAbsolute], [0, 0, 10]);
  Spans := nil;
  AddSpan(Spans, 0, 1, 20);
  AddSpan(Spans, 1, 1, 10);
  AddSpan(Spans, 0, 3, 70);
  Sizes := MeasureTracks(Columns, Spans, 0);
  CheckNumber('table: a spanning item widens the automatic columns, first', Sizes[0], 35);
  CheckNumber('table: a spanning item widens the automatic columns, last', Sizes[1], 25);
  CheckNumber('table: a spanning item leaves absolute columns alone', Sizes[2], 10);
  Offsets := TrackOffsets(5, Sizes);
  CheckNumber('table: offsets end after the last column', Offsets[3], 75);
  RowOffsets := TrackOffsets(0, MeasureTracks(Styles([TrackAbsolute, TrackAbsolute], [20, 30]), nil, 0));
  CheckRectangle('table: a cell spanning two columns and two rows', CellRectangle(Offsets, RowOffsets, 1, 0, 2, 2),
    40, 0, 35, 50);
  CheckRectangle('table: a span past the table is clipped', CellRectangle(Offsets, RowOffsets, 2, 1, 5, 5),
    65, 20, 10, 30);
end;

function Placement(Column, Row, ColumnSpan, RowSpan: LongInt; Fixed: Boolean): TCellPlacement;
begin
  Result.Column := Column;
  Result.Row := Row;
  Result.ColumnSpan := ColumnSpan;
  Result.RowSpan := RowSpan;
  Result.Fixed := Fixed;
end;

procedure TestTableCells;
var
  Cells: TCellPlacements;
  Index: LongInt;
  Columns: LongInt;
  Rows: LongInt;
begin
  Cells := nil;
  SetLength(Cells, 5);
  for Index := 0 to 4 do
    Cells[Index] := Placement(-1, -1, 1, 1, False);
  Columns := 2;
  Rows := 0;
  AssignFreeCells(Cells, Columns, Rows, GrowAddRows);
  CheckNumber('table cells: rows added as needed', Rows, 3);
  Check('table cells: row by row', (Cells[1].Column = 1) and (Cells[1].Row = 0) and (Cells[2].Column = 0) and
    (Cells[2].Row = 1) and (Cells[4].Column = 0) and (Cells[4].Row = 2));
  SetLength(Cells, 3);
  Cells[0] := Placement(-1, -1, 1, 1, False);
  Cells[1] := Placement(0, 0, 2, 1, True);
  Cells[2] := Placement(-1, -1, 1, 1, False);
  Columns := 2;
  Rows := 2;
  AssignFreeCells(Cells, Columns, Rows, GrowAddRows);
  Check('table cells: a fixed spanning cell is left to its owner',
    (Cells[0].Row = 1) and (Cells[0].Column = 0) and (Cells[2].Row = 1) and (Cells[2].Column = 1) and (Rows = 2));
  Cells[0] := Placement(-1, -1, 1, 1, False);
  Cells[1] := Placement(-1, -1, 1, 1, False);
  Cells[2] := Placement(-1, -1, 1, 1, False);
  Columns := 2;
  Rows := 1;
  AssignFreeCells(Cells, Columns, Rows, GrowFixedSize);
  Check('table cells: a full table of fixed size leaves the item out', (Cells[2].Column = -1) and (Rows = 1));
  Cells[2] := Placement(-1, -1, 1, 1, False);
  Columns := 2;
  Rows := 1;
  AssignFreeCells(Cells, Columns, Rows, GrowAddColumns);
  Check('table cells: columns added as needed', (Columns = 3) and (Cells[2].Column = 2) and (Cells[2].Row = 0));
  Cells[0] := Placement(-1, -1, 2, 1, False);
  Cells[1] := Placement(-1, -1, 1, 1, False);
  Cells[2] := Placement(-1, -1, 2, 1, False);
  Columns := 2;
  Rows := 0;
  AssignFreeCells(Cells, Columns, Rows, GrowAddRows);
  Check('table cells: spans take whole rows', (Cells[0].Row = 0) and (Cells[1].Row = 1) and (Cells[2].Row = 2) and
    (Rows = 3));
end;

procedure TestSplitAndScroll;
var
  Horizontal: Boolean;
  Vertical: Boolean;
begin
  CheckNumber('split: the first panel keeps its minimum', ClampSplitDistance(10, 200, 5, 25, 25), 25);
  CheckNumber('split: the second panel keeps its minimum', ClampSplitDistance(190, 200, 5, 25, 25), 170);
  CheckNumber('split: without room for both, the first minimum wins', ClampSplitDistance(100, 40, 5, 25, 25), 25);
  CheckNumber('split: never past the container', ClampSplitDistance(100, 20, 5, 25, 25), 15);
  CheckNumber('split: the first panel fixed keeps its extent', ResizedSplitDistance(FixedPanel1, 100, 200, 300, 5), 100);
  CheckNumber('split: the second panel fixed keeps its extent', ResizedSplitDistance(FixedPanel2, 100, 200, 300, 5),
    200);
  CheckNumber('split: none fixed keeps the share', ResizedSplitDistance(FixedNone, 100, 200, 300, 5), 150);
  NeededScrollBars(150, 80, 100, 100, 16, Horizontal, Vertical);
  Check('scrolling: wider content needs the horizontal bar only', Horizontal and not Vertical);
  NeededScrollBars(150, 90, 100, 100, 16, Horizontal, Vertical);
  Check('scrolling: the horizontal bar takes room, so the vertical one is needed too', Horizontal and Vertical);
  NeededScrollBars(100, 100, 100, 100, 16, Horizontal, Vertical);
  Check('scrolling: content that fits needs no bars', not Horizontal and not Vertical);
  CheckNumber('scrolling: kept within the content', ClampScrollPosition(500, 300, 100), 200);
  CheckNumber('scrolling: none when the content fits', ClampScrollPosition(50, 80, 100), 0);
  CheckNumber('scrolling: a control below the view scrolls into it', ScrollPositionToShow(0, 100, 120, 20), 40);
  CheckNumber('scrolling: a control above the view scrolls into it', ScrollPositionToShow(50, 100, 10, 20), 10);
  CheckNumber('scrolling: a control in view stays', ScrollPositionToShow(50, 100, 60, 20), 50);
end;

begin
  TestAnchors;
  TestConstraints;
  TestDocking;
  TestCells;
  TestFlow;
  TestTableTracks;
  TestTableCells;
  TestSplitAndScroll;
  WriteLn('[controls] ', Checks - Failures, ' passed, ', Failures, ' failed');
  if Failures > 0 then
    Halt(1);
end.
