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

  The rows (header groups first, footer groups last) and their cells
  are placed on a grid, cells spanning columns and rows (colspan,
  rowspan). Each column gets a minimum and maximum width from its
  single-column cells (their min-content and max-content widths, a
  fixed cell width as a floor), then cells spanning several columns
  spread what they need beyond those. The table is as wide as its width
  says, or shrinks to fit between the sum of the minimums and the sum
  of the maximums; the columns get their minimums plus the free space
  in proportion to what they could still use. Rows are as tall as
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
  Web.Layout.Values, Web.Layout.Sizing, Web.Layout.Dispatch;

type
  TGridCell = record
    Cell: TTableCellBox;
    Row: Integer;
    Column, ColumnSpan, RowSpan: Integer;
  end;

  TTableGrid = record
    Rows: array of TLayoutBox;
    RowGroups: array of TLayoutBox;
    RowCount: Integer;
    Cells: array of TGridCell;
    CellCount: Integer;
    ColumnCount: Integer;
    ColumnMin, ColumnMax, ColumnWidth: array of Single;
    SpacingX, SpacingY: Single;
  end;

function SpanAttribute(Cell: TLayoutBox; const Name: string; Limit: Integer): Integer;
var
  Code: Integer;
begin
  Result := 1;
  if (Cell.Node = nil) or not Cell.Node.IsElement then
    Exit;
  Val(Trim(TElement(Cell.Node).GetAttribute(Name)), Result, Code);
  if (Code <> 0) or (Result < 1) then
    Result := 1;
  if Result > Limit then
    Result := Limit;
end;

procedure BorderSpacing(Box: TLayoutBox; out Horizontal, Vertical: Single);
var
  Value: PCssComputedValue;
begin
  Horizontal := 0;
  Vertical := 0;
  if Box.Style.Keyword(cpBorderCollapse) = kwCollapse then
    Exit;
  Value := Box.Style.Value(cpBorderSpacing);
  if Value^.Kind = cvLength then
  begin
    Horizontal := Value^.Number;
    Vertical := Value^.Number;
  end
  else if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
  begin
    if Value^.Data.Kind = vkDimension then
    begin
      Horizontal := Value^.Data.Number;
      Vertical := Horizontal;
    end
    else if (Value^.Data.Kind = vkList) and (Value^.Data.Count >= 1) then
    begin
      Horizontal := Value^.Data.Items[0].Number;
      Vertical := Horizontal;
      if Value^.Data.Count >= 2 then
        Vertical := Value^.Data.Items[1].Number;
    end;
  end;
end;

procedure AddRowsOf(var Grid: TTableGrid; Group: TLayoutBox);
var
  Row: TLayoutBox;
begin
  Row := Group.FirstChild;
  while Row <> nil do
  begin
    if Row.Kind = bkTableRow then
    begin
      if Grid.RowCount >= Length(Grid.Rows) then
      begin
        SetLength(Grid.Rows, Grid.RowCount * 2 + 4);
        SetLength(Grid.RowGroups, Length(Grid.Rows));
      end;
      Grid.Rows[Grid.RowCount] := Row;
      Grid.RowGroups[Grid.RowCount] := Group;
      Inc(Grid.RowCount);
    end;
    Row := Row.NextSibling;
  end;
end;

function GroupKind(Group: TLayoutBox): Integer;
var
  Display: TCssKeyword;
begin
  Display := Group.Style.Keyword(cpDisplay);
  if Display = kwTableHeaderGroup then
    Result := 0
  else if Display = kwTableFooterGroup then
    Result := 2
  else
    Result := 1;
end;

procedure BuildGrid(Box: TLayoutBox; out Grid: TTableGrid);
var
  Group, Row, Cell: TLayoutBox;
  Pass, RowIndex, Column, Span, RowSpan, Index, Other: Integer;
  Occupied: array of array of Boolean;
begin
  Grid := Default(TTableGrid);
  BorderSpacing(Box, Grid.SpacingX, Grid.SpacingY);
  for Pass := 0 to 2 do
  begin
    Group := Box.FirstChild;
    while Group <> nil do
    begin
      if (Group.Kind = bkTableRowGroup) and (GroupKind(Group) = Pass) then
        AddRowsOf(Grid, Group);
      Group := Group.NextSibling;
    end;
  end;
  Occupied := nil;
  SetLength(Occupied, Grid.RowCount + 1);
  for RowIndex := 0 to Grid.RowCount - 1 do
  begin
    Row := Grid.Rows[RowIndex];
    Column := 0;
    Cell := Row.FirstChild;
    while Cell <> nil do
    begin
      if Cell.Kind = bkTableCell then
      begin
        while (Column < Length(Occupied[RowIndex])) and Occupied[RowIndex][Column] do
          Inc(Column);
        Span := SpanAttribute(Cell, 'colspan', 1000);
        RowSpan := SpanAttribute(Cell, 'rowspan', 65534);
        if RowIndex + RowSpan > Grid.RowCount then
          RowSpan := Grid.RowCount - RowIndex;
        if RowSpan < 1 then
          RowSpan := 1;
        for Index := RowIndex to RowIndex + RowSpan - 1 do
        begin
          if Length(Occupied[Index]) < Column + Span then
            SetLength(Occupied[Index], Column + Span);
          for Other := Column to Column + Span - 1 do
            Occupied[Index][Other] := True;
        end;
        if Grid.CellCount >= Length(Grid.Cells) then
          SetLength(Grid.Cells, Grid.CellCount * 2 + 8);
        Grid.Cells[Grid.CellCount].Cell := TTableCellBox(Cell);
        Grid.Cells[Grid.CellCount].Row := RowIndex;
        Grid.Cells[Grid.CellCount].Column := Column;
        Grid.Cells[Grid.CellCount].ColumnSpan := Span;
        Grid.Cells[Grid.CellCount].RowSpan := RowSpan;
        TTableCellBox(Cell).Column := Column;
        TTableCellBox(Cell).Row := RowIndex;
        TTableCellBox(Cell).ColumnSpan := Span;
        TTableCellBox(Cell).RowSpan := RowSpan;
        Inc(Grid.CellCount);
        Inc(Column, Span);
        if Column > Grid.ColumnCount then
          Grid.ColumnCount := Column;
      end;
      Cell := Cell.NextSibling;
    end;
  end;
  SetLength(Grid.ColumnMin, Grid.ColumnCount);
  SetLength(Grid.ColumnMax, Grid.ColumnCount);
  SetLength(Grid.ColumnWidth, Grid.ColumnCount);
end;

procedure ColumnWidths(var Grid: TTableGrid);
var
  Index, Column, Pass: Integer;
  Cell: ^TGridCell;
  CellMin, CellMax, SpanMin, SpanMax, Extra, Fixed: Single;
  Value: PCssComputedValue;
begin
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    Grid.ColumnMin[Column] := 0;
    Grid.ColumnMax[Column] := 0;
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
        begin
          Extra := (CellMin - SpanMin) / Cell^.ColumnSpan;
          for Column := Cell^.Column to Cell^.Column + Cell^.ColumnSpan - 1 do
            Grid.ColumnMin[Column] := Grid.ColumnMin[Column] + Extra;
        end;
        if CellMax > SpanMax then
        begin
          Extra := (CellMax - SpanMax) / Cell^.ColumnSpan;
          for Column := Cell^.Column to Cell^.Column + Cell^.ColumnSpan - 1 do
            Grid.ColumnMax[Column] := Grid.ColumnMax[Column] + Extra;
        end;
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

{ Moves the boxes positioned relative to Box (its children, and those
  inside its inline boxes). }
procedure ShiftChildren(Box: TLayoutBox; Delta: Single);
var
  Child: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
      ShiftChildren(Child, Delta)
    else
      Child.Y := Child.Y + Delta;
    Child := Child.NextSibling;
  end;
end;

procedure ShiftContents(Box: TLayoutBox; Delta: Single);
var
  Index: Integer;
begin
  if Delta = 0 then
    Exit;
  ShiftChildren(Box, Delta);
  if Box.Inline <> nil then
  begin
    for Index := 0 to Box.Inline.FragmentCount - 1 do
    begin
      Box.Inline.Fragments[Index].Y := Box.Inline.Fragments[Index].Y + Delta;
      Box.Inline.Fragments[Index].Baseline := Box.Inline.Fragments[Index].Baseline + Delta;
    end;
    for Index := 0 to Box.Inline.LineCount - 1 do
    begin
      Box.Inline.Lines[Index].Top := Box.Inline.Lines[Index].Top + Delta;
      Box.Inline.Lines[Index].Baseline := Box.Inline.Lines[Index].Baseline + Delta;
    end;
    { Inline atomic boxes were moved with the children. }
  end;
  if Box.FirstBaseline >= 0 then
    Box.FirstBaseline := Box.FirstBaseline + Delta;
  if Box.LastBaseline >= 0 then
    Box.LastBaseline := Box.LastBaseline + Delta;
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

procedure LayoutTable(Box: TLayoutBox; const Input: TLayoutInput);
var
  Grid: TTableGrid;
  SumMin, SumMax, Available, Spacing, TableWidth, Specified, Free, Weight, X, Y, CellWidth, Height: Single;
  ContentHeight, Extra, Offset, GroupTop, CaptionHeight: Single;
  Column, Index, RowIndex, Last: Integer;
  RowHeights, RowTops, ColumnLefts, RowBaselines: array of Single;
  Cell: ^TGridCell;
  Child, Group, Row: TLayoutBox;
  Align: TCssKeyword;
  ChildInput: TLayoutInput;
begin
  BuildGrid(Box, Grid);
  ColumnWidths(Grid);
  SumColumns(Grid, SumMin, SumMax);
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
      Child.Y := Box.ContentTop + CaptionHeight + Child.Margin[sideTop];
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
  ContentHeight := CaptionHeight + Y;
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
    ContentHeight := CaptionHeight + Y;
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
      Group.Y := Box.ContentTop + CaptionHeight + GroupTop;
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
    ContentHeight := Cell^.Cell.Height;
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
    ShiftContents(Cell^.Cell, Offset);
  end;
  { Captions below. }
  ContentHeight := CaptionHeight + RowTops[Grid.RowCount];
  if Grid.RowCount = 0 then
    ContentHeight := CaptionHeight;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if (Child.Kind = bkTableCaption) and (Child.Style.Keyword(cpCaptionSide) = kwBottom) then
    begin
      ChildInput := MakeChildInput(Input, Box.ContentWidth, Indefinite, wmStretch);
      ChildInput.Floats := nil;
      LayoutBox(Child, ChildInput);
      Child.X := Box.ContentLeft + Child.Margin[sideLeft];
      Child.Y := Box.ContentTop + ContentHeight + Child.Margin[sideTop];
      ContentHeight := ContentHeight + Child.MarginBoxHeight;
    end;
    Child := Child.NextSibling;
  end;
  Box.Height := Max(ContentHeight + VerticalBorderPadding(Box), SpecifiedBorderBoxHeight(Box, Input.ContainingHeight));
  Box.FirstBaseline := -1;
  if (Grid.RowCount > 0) and (Grid.CellCount > 0) and (Grid.Cells[0].Cell.FirstBaseline >= 0) then
    Box.FirstBaseline := Box.ContentTop + CaptionHeight + RowTops[0] + Grid.Cells[0].Cell.FirstBaseline;
  Box.LastBaseline := Box.FirstBaseline;
  Box.TopPositive := Max(Box.Margin[sideTop], 0);
  Box.TopNegative := Min(Box.Margin[sideTop], 0);
  Box.BottomPositive := Max(Box.Margin[sideBottom], 0);
  Box.BottomNegative := Min(Box.Margin[sideBottom], 0);
  Box.CollapsesThrough := False;
end;

end.
