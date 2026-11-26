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
  Table layout: the automatic table layout algorithm in brief (CSS 2.2
  17.5.2.2, CSS Tables 3).

  The rows and their cells are placed on a grid (Web.Layout.TableGrid),
  cells spanning columns and rows (colspan, rowspan); table-layout:
  fixed takes its column widths from Web.Layout.TableFixed. Each column gets a minimum and maximum width from its
  single-column cells (their min-content and max-content widths, a
  fixed cell width as a floor), then cells spanning several columns
  spread what they need beyond those. The table is as wide as its width
  says, or shrinks to fit between the sum of the minimums and the sum
  of the maximums; the columns get their minimums plus the free space
  in proportion to what they could still use. What a spanning cell
  needs beyond its columns goes to them in proportion to their maximum
  widths, its maximum to the columns without a fixed width first (as
  browsers do), so a long colspan row does not widen a narrow fixed
  column. Rows are as tall as
  their tallest cell (or their height); cells are laid out at their
  column widths and stretched to their rows, and their contents moved
  for vertical-align (top, middle, bottom, baseline). border-spacing
  separates the cells; a caption goes above (or below) the grid.
  Collapsing borders are laid out as separate ones without spacing.
}
unit Web.Layout.Table;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

procedure LayoutTable(Box: TLayoutBox; const Input: TLayoutInput);
{ Border box min/max widths of a table. }
procedure TableIntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);

implementation

uses
  Math, SysUtils, Web.Dom, Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Css.Values,
  Web.Layout.Values, Web.Layout.Sizing, Web.Layout.Dispatch, Web.Layout.TableGrid, Web.Layout.TableFixed;

{ Spreads Extra over the columns Cell spans, in proportion to their
  maximum widths (evenly when those are all zero); with AutoFirst only
  over the columns without a fixed width, when there are such. }
procedure DistributeExtra(var Grid: TTableGrid; var Widths: array of Single; constref Cell: TGridCell;
  Extra: Single; AutoFirst: Boolean);
var
  Column, Count: Integer;
  Total: Single;
  OnlyAuto: Boolean;
begin
  OnlyAuto := False;
  if AutoFirst then
    for Column := Cell.Column to Cell.Column + Cell.ColumnSpan - 1 do
      if not Grid.ColumnFixed[Column] then
        OnlyAuto := True;
  Total := 0;
  Count := 0;
  for Column := Cell.Column to Cell.Column + Cell.ColumnSpan - 1 do
    if not OnlyAuto or not Grid.ColumnFixed[Column] then
    begin
      Total := Total + Grid.ColumnMax[Column];
      Inc(Count);
    end;
  for Column := Cell.Column to Cell.Column + Cell.ColumnSpan - 1 do
    if not OnlyAuto or not Grid.ColumnFixed[Column] then
    begin
      if Total > 0 then
        Widths[Column] := Widths[Column] + Extra * Grid.ColumnMax[Column] / Total
      else
        Widths[Column] := Widths[Column] + Extra / Count;
    end;
end;

procedure ColumnWidths(var Grid: TTableGrid);
var
  Index, Column, Pass: Integer;
  Cell: ^TGridCell;
  CellMin, CellMax, SpanMin, SpanMax, Fixed: Single;
  Value: PCssComputedValue;
begin
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    Grid.ColumnMin[Column] := 0;
    Grid.ColumnMax[Column] := 0;
    Grid.ColumnFixed[Column] := False;
  end;
  for Pass := 0 to 1 do
    for Index := 0 to Grid.CellCount - 1 do
    begin
      Cell := @Grid.Cells[Index];
      if (Pass = 0) <> (Cell^.ColumnSpan = 1) then
        Continue;
      ResolveBoxEdges(Cell^.Cell, 0);
      IntrinsicWidths(Cell^.Cell, CellMin, CellMax);
      Value := Cell^.Cell.Style.Value(cpWidth);
      if Value^.Kind = cvLength then
      begin
        Fixed := SpecifiedBorderBoxWidth(Cell^.Cell, 0);
        if Fixed > CellMin then
          CellMax := Max(Fixed, CellMin)
        else
          CellMax := CellMin;
      end;
      if Cell^.ColumnSpan = 1 then
      begin
        Column := Cell^.Column;
        if Value^.Kind = cvLength then
          Grid.ColumnFixed[Column] := True;
        Grid.ColumnMin[Column] := Max(Grid.ColumnMin[Column], CellMin);
        Grid.ColumnMax[Column] := Max(Grid.ColumnMax[Column], CellMax);
      end
      else
      begin
        SpanMin := Grid.SpacingX * (Cell^.ColumnSpan - 1);
        SpanMax := SpanMin;
        for Column := Cell^.Column to Cell^.Column + Cell^.ColumnSpan - 1 do
        begin
          SpanMin := SpanMin + Grid.ColumnMin[Column];
          SpanMax := SpanMax + Grid.ColumnMax[Column];
        end;
        if CellMin > SpanMin then
          DistributeExtra(Grid, Grid.ColumnMin, Cell^, CellMin - SpanMin, False);
        if CellMax > SpanMax then
          DistributeExtra(Grid, Grid.ColumnMax, Cell^, CellMax - SpanMax, True);
      end;
    end;
  for Column := 0 to Grid.ColumnCount - 1 do
    if Grid.ColumnMax[Column] < Grid.ColumnMin[Column] then
      Grid.ColumnMax[Column] := Grid.ColumnMin[Column];
end;

function TableEdges(Box: TLayoutBox): Single;
begin
  Result := Box.Style.Value(cpBorderLeftWidth)^.Number + Box.Style.Value(cpBorderRightWidth)^.Number +
    Abs(LengthOf(Box.Style, cpPaddingLeft, 0)) + Abs(LengthOf(Box.Style, cpPaddingRight, 0));
end;

procedure SumColumns(const Grid: TTableGrid; out SumMin, SumMax: Single);
var
  Column: Integer;
begin
  SumMin := 0;
  SumMax := 0;
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    SumMin := SumMin + Grid.ColumnMin[Column];
    SumMax := SumMax + Grid.ColumnMax[Column];
  end;
end;

{ The automatic layout's column widths for Free: their maximums and the
  rest in proportion to them, or between their minimums and maximums,
  or their minimums. }
procedure AutoColumnWidths(var Grid: TTableGrid; Free, SumMin, SumMax: Single);
var
  Column: Integer;
  Weight: Single;
begin
  for Column := 0 to Grid.ColumnCount - 1 do
    if Free >= SumMax then
    begin
      if SumMax > 0 then
        Weight := Grid.ColumnMax[Column] / SumMax
      else
        Weight := 1 / Grid.ColumnCount;
      Grid.ColumnWidth[Column] := Grid.ColumnMax[Column] + (Free - SumMax) * Weight;
    end
    else if (Free > SumMin) and (SumMax > SumMin) then
      Grid.ColumnWidth[Column] := Grid.ColumnMin[Column] + (Grid.ColumnMax[Column] - Grid.ColumnMin[Column]) *
        (Free - SumMin) / (SumMax - SumMin)
    else
      Grid.ColumnWidth[Column] := Grid.ColumnMin[Column];
end;

procedure TableIntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Grid: TTableGrid;
  SumMin, SumMax, Spacing, Caption, CaptionMax: Single;
  Child: TLayoutBox;
begin
  BuildGrid(Box, Grid);
  ColumnWidths(Grid);
  SumColumns(Grid, SumMin, SumMax);
  Spacing := Grid.SpacingX * (Grid.ColumnCount + 1);
  if Grid.ColumnCount = 0 then
    Spacing := 0;
  MinWidth := SumMin + Spacing + TableEdges(Box);
  MaxWidth := SumMax + Spacing + TableEdges(Box);
  if UsesFixedLayout(Box) then
    MinWidth := FixedColumnsMinimum(Grid) + Spacing + TableEdges(Box);
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkTableCaption then
    begin
      IntrinsicWidths(Child, Caption, CaptionMax);
      MinWidth := Max(MinWidth, Caption);
    end;
    Child := Child.NextSibling;
  end;
  if MaxWidth < MinWidth then
    MaxWidth := MinWidth;
end;

procedure LayoutCell(const Input: TLayoutInput; Cell: TLayoutBox; Width, Height: Single);
var
  ChildInput: TLayoutInput;
begin
  ChildInput := MakeChildInput(Input, Width, Indefinite, wmFixed);
  ChildInput.FixedWidth := Width;
  ChildInput.FixedHeight := Height;
  ChildInput.Floats := nil;
  ChildInput.BfcX := 0;
  ChildInput.BfcY := 0;
  LayoutBox(Cell, ChildInput);
end;

{ The absolutely positioned children of a table, row group or row go to
  their containing block's list, their static position the top left of
  Parent's content box (where an in-flow block would start). }
procedure HandOverPositioned(Parent: TLayoutBox; const Input: TLayoutInput);
var
  Child: TLayoutBox;
begin
  Child := Parent.FirstChild;
  while Child <> nil do
  begin
    if Child.IsAbsolutelyPositioned then
    begin
      Child.StaticX := Parent.ContentLeft;
      Child.StaticY := Parent.ContentTop;
      if bfFixed in Child.Flags then
      begin
        if Input.FixedBoxes <> nil then
          Input.FixedBoxes.Add(Child);
      end
      else if Input.Positioned <> nil then
        Input.Positioned.Add(Child);
    end
    else if Child.Kind in [bkTableRowGroup, bkTableRow] then
      HandOverPositioned(Child, Input);
    Child := Child.NextSibling;
  end;
end;

procedure LayoutTable(Box: TLayoutBox; const Input: TLayoutInput);
var
  Grid: TTableGrid;
  SumMin, SumMax, Available, Spacing, TableWidth, Specified, Free, X, Y, CellWidth, Height: Single;
  ContentHeight, Extra, Offset, GroupTop, CaptionHeight: Single;
  Column, Index, RowIndex, Last: Integer;
  RowHeights, RowTops, ColumnLefts, RowBaselines: array of Single;
  Cell: ^TGridCell;
  Child, Group, Row: TLayoutBox;
  Align: TCssKeyword;
  ChildInput: TLayoutInput;
  Fixed: Boolean;
begin
  BuildGrid(Box, Grid);
  Fixed := UsesFixedLayout(Box);
  if Fixed then
  begin
    SumMin := FixedColumnsMinimum(Grid);
    SumMax := SumMin;
  end
  else
  begin
    ColumnWidths(Grid);
    SumColumns(Grid, SumMin, SumMax);
  end;
  Spacing := Grid.SpacingX * (Grid.ColumnCount + 1);
  if Grid.ColumnCount = 0 then
    Spacing := 0;
  { The table's width. }
  Specified := SpecifiedBorderBoxWidth(Box, Input.AvailableWidth);
  Available := Input.AvailableWidth - Box.Margin[sideLeft] - Box.Margin[sideRight];
  if Input.WidthMode = wmFixed then
    TableWidth := Input.FixedWidth
  else if Specified >= 0 then
    TableWidth := Specified
  else
    TableWidth := Min(Available, SumMax + Spacing + HorizontalBorderPadding(Box));
  TableWidth := ClampWidth(Box, TableWidth, Input.AvailableWidth);
  if TableWidth < SumMin + Spacing + HorizontalBorderPadding(Box) then
    TableWidth := SumMin + Spacing + HorizontalBorderPadding(Box);
  Box.Width := TableWidth;
  { The columns. }
  Free := TableWidth - HorizontalBorderPadding(Box) - Spacing;
  if Fixed then
    FixedColumnWidths(Grid, Free)
  else
    AutoColumnWidths(Grid, Free, SumMin, SumMax);
  SetLength(ColumnLefts, Grid.ColumnCount + 1);
  X := Grid.SpacingX;
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    ColumnLefts[Column] := X;
    X := X + Grid.ColumnWidth[Column] + Grid.SpacingX;
  end;
  ColumnLefts[Grid.ColumnCount] := X;
  { Cells at their widths; rows as tall as their cells. }
  SetLength(RowHeights, Grid.RowCount);
  SetLength(RowTops, Grid.RowCount + 1);
  SetLength(RowBaselines, Grid.RowCount);
  for RowIndex := 0 to Grid.RowCount - 1 do
  begin
    RowHeights[RowIndex] := Max(0, SpecifiedBorderBoxHeight(Grid.Rows[RowIndex], Indefinite));
    RowBaselines[RowIndex] := 0;
  end;
  for Index := 0 to Grid.CellCount - 1 do
  begin
    Cell := @Grid.Cells[Index];
    Last := Cell^.Column + Cell^.ColumnSpan - 1;
    CellWidth := ColumnLefts[Last] + Grid.ColumnWidth[Last] - ColumnLefts[Cell^.Column];
    LayoutCell(Input, Cell^.Cell, CellWidth, -1);
    if (Cell^.RowSpan = 1) and (Cell^.Cell.Height > RowHeights[Cell^.Row]) then
      RowHeights[Cell^.Row] := Cell^.Cell.Height;
    if (Cell^.Cell.Style.Keyword(cpVerticalAlign) = kwBaseline) and (Cell^.Cell.FirstBaseline >= 0) then
      RowBaselines[Cell^.Row] := Max(RowBaselines[Cell^.Row], Cell^.Cell.FirstBaseline);
  end;
  { Cells spanning rows make their last row taller if they need it. }
  for Index := 0 to Grid.CellCount - 1 do
  begin
    Cell := @Grid.Cells[Index];
    if Cell^.RowSpan <= 1 then
      Continue;
    Height := Grid.SpacingY * (Cell^.RowSpan - 1);
    for RowIndex := Cell^.Row to Cell^.Row + Cell^.RowSpan - 1 do
      Height := Height + RowHeights[RowIndex];
    if Cell^.Cell.Height > Height then
      RowHeights[Cell^.Row + Cell^.RowSpan - 1] := RowHeights[Cell^.Row + Cell^.RowSpan - 1] +
        Cell^.Cell.Height - Height;
  end;
  { Captions on top. }
  CaptionHeight := 0;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if (Child.Kind = bkTableCaption) and (Child.Style.Keyword(cpCaptionSide) <> kwBottom) then
    begin
      ChildInput := MakeChildInput(Input, Box.ContentWidth, Indefinite, wmStretch);
      ChildInput.Floats := nil;
      LayoutBox(Child, ChildInput);
      Child.X := Box.ContentLeft + Child.Margin[sideLeft];
      CaptionHeight := CaptionHeight + Child.MarginBoxHeight;
    end;
    Child := Child.NextSibling;
  end;
  Y := Grid.SpacingY;
  for RowIndex := 0 to Grid.RowCount - 1 do
  begin
    RowTops[RowIndex] := Y;
    Y := Y + RowHeights[RowIndex] + Grid.SpacingY;
  end;
  RowTops[Grid.RowCount] := Y;
  if Grid.RowCount = 0 then
    Y := 0;
  ContentHeight := Y;
  { A specified table height taller than the rows: the rows share it. }
  Specified := SpecifiedBorderBoxHeight(Box, Input.ContainingHeight);
  if (Specified > ContentHeight + VerticalBorderPadding(Box)) and (Grid.RowCount > 0) then
  begin
    Extra := (Specified - ContentHeight - VerticalBorderPadding(Box)) / Grid.RowCount;
    Y := Grid.SpacingY;
    for RowIndex := 0 to Grid.RowCount - 1 do
    begin
      RowHeights[RowIndex] := RowHeights[RowIndex] + Extra;
      RowTops[RowIndex] := Y;
      Y := Y + RowHeights[RowIndex] + Grid.SpacingY;
    end;
    RowTops[Grid.RowCount] := Y;
    ContentHeight := Y;
  end;
  { Row groups and rows as boxes. }
  Group := Box.FirstChild;
  while Group <> nil do
  begin
    if Group.Kind = bkTableRowGroup then
    begin
      ResolveBoxEdges(Group, 0);
      GroupTop := -1;
      Height := 0;
      for RowIndex := 0 to Grid.RowCount - 1 do
        if Grid.RowGroups[RowIndex] = Group then
        begin
          if GroupTop < 0 then
            GroupTop := RowTops[RowIndex];
          Height := RowTops[RowIndex] + RowHeights[RowIndex] - GroupTop;
        end;
      if GroupTop < 0 then
        GroupTop := 0;
      Group.X := Box.ContentLeft;
      Group.Y := Box.ContentTop + GroupTop;
      Group.Width := Box.ContentWidth;
      Group.Height := Height;
      Group.Flags := Group.Flags - [bfNeedsLayout, bfChildNeedsLayout];
      for RowIndex := 0 to Grid.RowCount - 1 do
        if Grid.RowGroups[RowIndex] = Group then
        begin
          Row := Grid.Rows[RowIndex];
          ResolveBoxEdges(Row, 0);
          Row.X := 0;
          Row.Y := RowTops[RowIndex] - GroupTop;
          Row.Width := Box.ContentWidth;
          Row.Height := RowHeights[RowIndex];
          Row.Flags := Row.Flags - [bfNeedsLayout, bfChildNeedsLayout];
        end;
    end
    else if Group.Kind in [bkTableColumn, bkTableColumnGroup] then
      Group.Flags := Group.Flags - [bfNeedsLayout, bfChildNeedsLayout];
    Group := Group.NextSibling;
  end;
  { Cells stretched to their rows, contents aligned. }
  for Index := 0 to Grid.CellCount - 1 do
  begin
    Cell := @Grid.Cells[Index];
    Last := Cell^.Column + Cell^.ColumnSpan - 1;
    CellWidth := ColumnLefts[Last] + Grid.ColumnWidth[Last] - ColumnLefts[Cell^.Column];
    Height := RowTops[Cell^.Row + Cell^.RowSpan - 1] + RowHeights[Cell^.Row + Cell^.RowSpan - 1] -
      RowTops[Cell^.Row];
    ContentHeight := Cell^.Cell.ContentExtent + VerticalBorderPadding(Cell^.Cell);
    if Abs(Cell^.Cell.Height - Height) > 0.01 then
    begin
      Cell^.Cell.MarkNeedsLayout;
      LayoutCell(Input, Cell^.Cell, CellWidth, Height);
    end;
    Cell^.Cell.X := ColumnLefts[Cell^.Column];
    Cell^.Cell.Y := 0;
    Align := Cell^.Cell.Style.Keyword(cpVerticalAlign);
    Offset := 0;
    Free := Height - ContentHeight;
    if Free > 0 then
      case Align of
        kwMiddle: Offset := Free / 2;
        kwBottom: Offset := Free;
        kwBaseline:
          if Cell^.Cell.FirstBaseline >= 0 then
            Offset := RowBaselines[Cell^.Row] - Cell^.Cell.FirstBaseline;
      end;
    ShiftLayoutContents(Cell^.Cell, Offset);
  end;
  { Captions go outside the grid's border: above it (in the space added
    to the top margin) and below it. }
  ContentHeight := RowTops[Grid.RowCount];
  if Grid.RowCount = 0 then
    ContentHeight := 0;
  Box.Height := Max(ContentHeight + VerticalBorderPadding(Box), SpecifiedBorderBoxHeight(Box, Input.ContainingHeight));
  Y := -CaptionHeight;
  Extra := 0;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkTableCaption then
    begin
      if Child.Style.Keyword(cpCaptionSide) <> kwBottom then
      begin
        Child.Y := Y + Child.Margin[sideTop];
        Y := Y + Child.MarginBoxHeight;
      end
      else
      begin
        ChildInput := MakeChildInput(Input, Box.ContentWidth, Indefinite, wmStretch);
        ChildInput.Floats := nil;
        LayoutBox(Child, ChildInput);
        Child.X := Box.ContentLeft + Child.Margin[sideLeft];
        Child.Y := Box.Height + Extra + Child.Margin[sideTop];
        Extra := Extra + Child.MarginBoxHeight;
      end;
    end;
    Child := Child.NextSibling;
  end;
  Box.LeadingOffset := CaptionHeight;
  Box.Margin[sideBottom] := Box.Margin[sideBottom] + Extra;
  Box.FirstBaseline := -1;
  if (Grid.RowCount > 0) and (Grid.CellCount > 0) and (Grid.Cells[0].Cell.FirstBaseline >= 0) then
    Box.FirstBaseline := Box.ContentTop + RowTops[0] + Grid.Cells[0].Cell.FirstBaseline;
  Box.LastBaseline := Box.FirstBaseline;
  Box.TopPositive := Max(Box.Margin[sideTop], 0);
  Box.TopNegative := Min(Box.Margin[sideTop], 0);
  Box.BottomPositive := Max(Box.Margin[sideBottom], 0);
  Box.BottomNegative := Min(Box.Margin[sideBottom], 0);
  Box.CollapsesThrough := False;
  HandOverPositioned(Box, Input);
end;

end.
