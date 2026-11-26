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
  The collapsing border model (CSS 2.2 17.6.2). Every grid line segment
  (a column wide between two rows, a row tall between two columns)
  gets one border: of the cells, rows, row groups, columns, column
  groups and the table that meet there, hidden wins over everything,
  none loses, then the wider, then the style (double, solid, dashed,
  dotted, ridge, outset, groove, inset), then the element (cell, row,
  row group, column, column group, table; left and top first). A
  border is centred on its line, the larger half above or left of it:
  each cell's used border is the half of the widest segment on its side
  that falls inside it, the table's the half of its outer edges that
  falls outside the cells (the table has no padding). The table paints
  the segments over its cells' backgrounds (Web.Paint.Builder).
}
unit Web.Layout.TableBorders;

{$mode objfpc}
{$H+}

interface

uses
  Css.Keywords, Web.Layout.Boxes, Web.Layout.TableGrid;

type
  TCollapsedEdge = record
    Width: Single;
    Style: TCssKeyword;
    { Whose border it is (its color is that box's on Side). }
    Owner: TLayoutBox;
    Side: TBoxSide;
  end;

  TCollapsedBorders = class
  public
    RowCount, ColumnCount: Integer;
    { (RowCount + 1) x ColumnCount: line Row, column Column at
      Row * ColumnCount + Column. }
    Horizontal: array of TCollapsedEdge;
    { RowCount x (ColumnCount + 1): row Row, line Column at
      Row * (ColumnCount + 1) + Column. }
    Vertical: array of TCollapsedEdge;
    { The grid lines, relative to the table's border box (set by the
      table layout). }
    RowLines, ColumnLines: array of Single;
    function HorizontalAt(Row, Column: Integer): TCollapsedEdge;
    function VerticalAt(Row, Column: Integer): TCollapsedEdge;
  end;

function CollapsesBorders(Box: TLayoutBox): Boolean;
{ Resolves Table's collapsed edges (Table must be a TTableBox) and sets
  the used borders of it and its cells. }
procedure CollapseTableBorders(Table: TLayoutBox; const Grid: TTableGrid);
{ The part of a border of Width above or left of its line. }
{ Back to separate borders (the table's border-collapse changed). }
procedure SeparateTableBorders(Table: TLayoutBox; const Grid: TTableGrid);
function LeadingHalf(Width: Single): Single;
function TrailingHalf(Width: Single): Single;

implementation

uses
  Math, SysUtils, Css.ComputedStyle, Css.PropertyIds;

const
  WidthIds: array[TBoxSide] of TCssPropertyId = (cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth,
    cpBorderLeftWidth);
  StyleIds: array[TBoxSide] of TCssPropertyId = (cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle,
    cpBorderLeftStyle);

function TCollapsedBorders.HorizontalAt(Row, Column: Integer): TCollapsedEdge;
begin
  Result := Horizontal[Row * ColumnCount + Column];
end;

function TCollapsedBorders.VerticalAt(Row, Column: Integer): TCollapsedEdge;
begin
  Result := Vertical[Row * (ColumnCount + 1) + Column];
end;

function CollapsesBorders(Box: TLayoutBox): Boolean;
begin
  Result := (Box is TTableBox) and (Box.Style.Keyword(cpBorderCollapse) = kwCollapse);
end;

function LeadingHalf(Width: Single): Single;
begin
  Result := Width - Floor(Width / 2);
end;

function TrailingHalf(Width: Single): Single;
begin
  Result := Floor(Width / 2);
end;

function StyleRank(Style: TCssKeyword): Integer;
begin
  case Style of
    kwDouble: Result := 8;
    kwSolid: Result := 7;
    kwDashed: Result := 6;
    kwDotted: Result := 5;
    kwRidge: Result := 4;
    kwOutset: Result := 3;
    kwGroove: Result := 2;
    kwInset: Result := 1;
  else
    Result := 0;
  end;
end;

{ Candidate's border on Side takes Edge's place when it wins (an earlier
  candidate wins a tie). }
procedure Consider(var Edge: TCollapsedEdge; Candidate: TLayoutBox; Side: TBoxSide);
var
  Style: TCssKeyword;
  Width: Single;
begin
  if Candidate = nil then
    Exit;
  if Edge.Style = kwHidden then
    Exit;
  Style := Candidate.Style.Keyword(StyleIds[Side]);
  Width := Candidate.Style.Value(WidthIds[Side])^.Number;
  if Style = kwHidden then
  begin
    Edge.Style := kwHidden;
    Edge.Width := 0;
    Edge.Owner := Candidate;
    Edge.Side := Side;
    Exit;
  end;
  if (Style = kwNone) or (Width <= 0) then
    Exit;
  if (Edge.Owner <> nil) and (Edge.Style <> kwNone) then
  begin
    if Width < Edge.Width then
      Exit;
    if (Width = Edge.Width) and (StyleRank(Style) <= StyleRank(Edge.Style)) then
      Exit;
  end;
  Edge.Width := Width;
  Edge.Style := Style;
  Edge.Owner := Candidate;
  Edge.Side := Side;
end;

type
  TCellMap = array of array of Integer;

{ The column element (col, else its colgroup) of Column; nil when none. }
function ColumnOf(const Grid: TTableGrid; Column: Integer): TLayoutBox;
begin
  Result := nil;
  if (Column >= 0) and (Column < Length(Grid.ColumnBoxes)) then
    Result := Grid.ColumnBoxes[Column];
end;

function ColumnGroupOf(const Grid: TTableGrid; Column: Integer): TLayoutBox;
begin
  Result := ColumnOf(Grid, Column);
  if Result = nil then
    Exit;
  if Result.Kind = bkTableColumn then
  begin
    if (Result.Parent <> nil) and (Result.Parent.Kind = bkTableColumnGroup) then
      Result := Result.Parent
    else
      Result := nil;
  end;
end;

function CellAt(const Grid: TTableGrid; const Map: TCellMap; Row, Column: Integer): PGridCell;
begin
  Result := nil;
  if (Row < 0) or (Row >= Grid.RowCount) or (Column < 0) or (Column >= Grid.ColumnCount) then
    Exit;
  if Map[Row][Column] >= 0 then
    Result := @Grid.Cells[Map[Row][Column]];
end;

procedure ResolveHorizontal(Table: TLayoutBox; const Grid: TTableGrid; const Map: TCellMap; Row, Column: Integer;
  out Edge: TCollapsedEdge);
var
  Above, Below: PGridCell;
  Inside: Boolean;
begin
  Edge := Default(TCollapsedEdge);
  Edge.Style := kwNone;
  Above := CellAt(Grid, Map, Row - 1, Column);
  Below := CellAt(Grid, Map, Row, Column);
  { Inside a cell spanning rows: no edge. }
  Inside := (Above <> nil) and (Above = Below);
  if Inside then
    Exit;
  if Above <> nil then
    Consider(Edge, Above^.Cell, sideBottom);
  if Below <> nil then
    Consider(Edge, Below^.Cell, sideTop);
  if Row > 0 then
    Consider(Edge, Grid.Rows[Row - 1], sideBottom);
  if Row < Grid.RowCount then
    Consider(Edge, Grid.Rows[Row], sideTop);
  if (Row > 0) and ((Row = Grid.RowCount) or (Grid.RowGroups[Row] <> Grid.RowGroups[Row - 1])) then
    Consider(Edge, Grid.RowGroups[Row - 1], sideBottom);
  if (Row < Grid.RowCount) and ((Row = 0) or (Grid.RowGroups[Row] <> Grid.RowGroups[Row - 1])) then
    Consider(Edge, Grid.RowGroups[Row], sideTop);
  if Row = 0 then
  begin
    Consider(Edge, ColumnOf(Grid, Column), sideTop);
    Consider(Edge, ColumnGroupOf(Grid, Column), sideTop);
    Consider(Edge, Table, sideTop);
  end;
  if Row = Grid.RowCount then
  begin
    Consider(Edge, ColumnOf(Grid, Column), sideBottom);
    Consider(Edge, ColumnGroupOf(Grid, Column), sideBottom);
    Consider(Edge, Table, sideBottom);
  end;
end;

procedure ResolveVertical(Table: TLayoutBox; const Grid: TTableGrid; const Map: TCellMap; Row, Column: Integer;
  out Edge: TCollapsedEdge);
var
  Left, Right: PGridCell;
  LeftGroup, RightGroup: TLayoutBox;
begin
  Edge := Default(TCollapsedEdge);
  Edge.Style := kwNone;
  Left := CellAt(Grid, Map, Row, Column - 1);
  Right := CellAt(Grid, Map, Row, Column);
  if (Left <> nil) and (Left = Right) then
    Exit;
  if Left <> nil then
    Consider(Edge, Left^.Cell, sideRight);
  if Right <> nil then
    Consider(Edge, Right^.Cell, sideLeft);
  if Column = 0 then
  begin
    Consider(Edge, Grid.Rows[Row], sideLeft);
    Consider(Edge, Grid.RowGroups[Row], sideLeft);
  end;
  if Column = Grid.ColumnCount then
  begin
    Consider(Edge, Grid.Rows[Row], sideRight);
    Consider(Edge, Grid.RowGroups[Row], sideRight);
  end;
  Consider(Edge, ColumnOf(Grid, Column - 1), sideRight);
  Consider(Edge, ColumnOf(Grid, Column), sideLeft);
  LeftGroup := ColumnGroupOf(Grid, Column - 1);
  RightGroup := ColumnGroupOf(Grid, Column);
  if LeftGroup <> RightGroup then
  begin
    Consider(Edge, LeftGroup, sideRight);
    Consider(Edge, RightGroup, sideLeft);
  end;
  if Column = 0 then
    Consider(Edge, Table, sideLeft);
  if Column = Grid.ColumnCount then
    Consider(Edge, Table, sideRight);
end;

procedure CollapseTableBorders(Table: TLayoutBox; const Grid: TTableGrid);
var
  Borders: TCollapsedBorders;
  Map: TCellMap;
  Row, Column, Index, Other: Integer;
  Cell: TTableCellBox;
  Edges: TBoxEdges;
begin
  Borders := TCollapsedBorders.Create;
  TTableBox(Table).CollapsedEdges.Free;
  TTableBox(Table).CollapsedEdges := Borders;
  Borders.RowCount := Grid.RowCount;
  Borders.ColumnCount := Grid.ColumnCount;
  Map := nil;
  SetLength(Map, Grid.RowCount, Grid.ColumnCount);
  for Row := 0 to Grid.RowCount - 1 do
    for Column := 0 to Grid.ColumnCount - 1 do
      Map[Row][Column] := -1;
  for Index := 0 to Grid.CellCount - 1 do
    for Row := Grid.Cells[Index].Row to Grid.Cells[Index].Row + Grid.Cells[Index].RowSpan - 1 do
      for Column := Grid.Cells[Index].Column to Grid.Cells[Index].Column + Grid.Cells[Index].ColumnSpan - 1 do
        if (Row < Grid.RowCount) and (Column < Grid.ColumnCount) then
          Map[Row][Column] := Index;
  SetLength(Borders.Horizontal, (Grid.RowCount + 1) * Grid.ColumnCount);
  SetLength(Borders.Vertical, Grid.RowCount * (Grid.ColumnCount + 1));
  for Row := 0 to Grid.RowCount do
    for Column := 0 to Grid.ColumnCount - 1 do
      ResolveHorizontal(Table, Grid, Map, Row, Column, Borders.Horizontal[Row * Grid.ColumnCount + Column]);
  for Row := 0 to Grid.RowCount - 1 do
    for Column := 0 to Grid.ColumnCount do
      ResolveVertical(Table, Grid, Map, Row, Column, Borders.Vertical[Row * (Grid.ColumnCount + 1) + Column]);
  { The cells' halves. }
  for Index := 0 to Grid.CellCount - 1 do
  begin
    Cell := Grid.Cells[Index].Cell;
    Edges[sideTop] := 0;
    Edges[sideRight] := 0;
    Edges[sideBottom] := 0;
    Edges[sideLeft] := 0;
    Row := Grid.Cells[Index].Row;
    Column := Grid.Cells[Index].Column;
    for Other := Column to Min(Column + Grid.Cells[Index].ColumnSpan, Grid.ColumnCount) - 1 do
    begin
      Edges[sideTop] := Max(Edges[sideTop], TrailingHalf(Borders.HorizontalAt(Row, Other).Width));
      Edges[sideBottom] := Max(Edges[sideBottom],
        LeadingHalf(Borders.HorizontalAt(Min(Row + Grid.Cells[Index].RowSpan, Grid.RowCount), Other).Width));
    end;
    for Other := Row to Min(Row + Grid.Cells[Index].RowSpan, Grid.RowCount) - 1 do
    begin
      Edges[sideLeft] := Max(Edges[sideLeft], TrailingHalf(Borders.VerticalAt(Other, Column).Width));
      Edges[sideRight] := Max(Edges[sideRight],
        LeadingHalf(Borders.VerticalAt(Other, Min(Column + Grid.Cells[Index].ColumnSpan, Grid.ColumnCount)).Width));
    end;
    Cell.CollapsedBorder := Edges;
    Include(Cell.Flags, bfCollapsedBorders);
  end;
  { The table's outer halves. }
  Edges[sideTop] := 0;
  Edges[sideRight] := 0;
  Edges[sideBottom] := 0;
  Edges[sideLeft] := 0;
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    Edges[sideTop] := Max(Edges[sideTop], LeadingHalf(Borders.HorizontalAt(0, Column).Width));
    Edges[sideBottom] := Max(Edges[sideBottom], TrailingHalf(Borders.HorizontalAt(Grid.RowCount, Column).Width));
  end;
  for Row := 0 to Grid.RowCount - 1 do
  begin
    Edges[sideLeft] := Max(Edges[sideLeft], LeadingHalf(Borders.VerticalAt(Row, 0).Width));
    Edges[sideRight] := Max(Edges[sideRight], TrailingHalf(Borders.VerticalAt(Row, Grid.ColumnCount).Width));
  end;
  { A table without cells keeps its own borders' halves. }
  if Grid.CellCount = 0 then
  begin
    Edges[sideTop] := LeadingHalf(Table.Style.Value(cpBorderTopWidth)^.Number);
    Edges[sideRight] := TrailingHalf(Table.Style.Value(cpBorderRightWidth)^.Number);
    Edges[sideBottom] := TrailingHalf(Table.Style.Value(cpBorderBottomWidth)^.Number);
    Edges[sideLeft] := LeadingHalf(Table.Style.Value(cpBorderLeftWidth)^.Number);
  end;
  TTableBox(Table).CollapsedBorder := Edges;
  Include(Table.Flags, bfCollapsedBorders);
end;

procedure SeparateTableBorders(Table: TLayoutBox; const Grid: TTableGrid);
var
  Index: Integer;
begin
  if not (bfCollapsedBorders in Table.Flags) then
    Exit;
  Exclude(Table.Flags, bfCollapsedBorders);
  if Table is TTableBox then
    FreeAndNil(TTableBox(Table).CollapsedEdges);
  for Index := 0 to Grid.CellCount - 1 do
    Exclude(Grid.Cells[Index].Cell.Flags, bfCollapsedBorders);
end;

end.
