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
  A table's grid (CSS 2.2 17.5, HTML's table model): its rows (header
  groups first, footer groups last), each cell at its row and column
  with its spans (colspan, rowspan; a cell skips the slots cells above
  span into), and the column elements that stand for each column (a
  col with span covers that many; a colgroup without cols covers its
  span), so a table has as many columns as its widest row or its column
  elements say.
}
unit Web.Layout.TableGrid;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes;

type
  TGridCell = record
    Cell: TTableCellBox;
    Row: Integer;
    Column, ColumnSpan, RowSpan: Integer;
  end;
  PGridCell = ^TGridCell;

  TTableGrid = record
    Rows: array of TLayoutBox;
    RowGroups: array of TLayoutBox;
    RowCount: Integer;
    Cells: array of TGridCell;
    CellCount: Integer;
    ColumnCount: Integer;
    { The col (or colgroup without cols) of each column; nil past them. }
    ColumnBoxes: array of TLayoutBox;
    ColumnMin, ColumnMax, ColumnWidth: array of Single;
    { A single-column cell of the column has a fixed width. }
    ColumnFixed: array of Boolean;
    SpacingX, SpacingY: Single;
  end;

{ The span attribute Name of Cell (colspan, rowspan, span), 1 to Limit. }
function SpanAttribute(Cell: TLayoutBox; const Name: string; Limit: Integer): Integer;
{ border-spacing (none with collapsing borders). }
procedure BorderSpacing(Box: TLayoutBox; out Horizontal, Vertical: Single);
procedure BuildGrid(Box: TLayoutBox; out Grid: TTableGrid);

implementation

uses
  SysUtils, Web.Dom, Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Css.Values;

const
  { HTML's limits: a span of more than 1000 columns or 65534 rows. }
  MostColumnsSpanned = 1000;
  MostRowsSpanned = 65534;

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

procedure AddColumnBox(var Grid: TTableGrid; Column: TLayoutBox; Span: Integer);
var
  Index: Integer;
begin
  for Index := 1 to Span do
  begin
    SetLength(Grid.ColumnBoxes, Length(Grid.ColumnBoxes) + 1);
    Grid.ColumnBoxes[High(Grid.ColumnBoxes)] := Column;
  end;
end;

{ The column elements, in order: a col covers its span, a colgroup its
  cols or, without any, its own span. }
procedure CollectColumns(Box: TLayoutBox; var Grid: TTableGrid);
var
  Child, Column: TLayoutBox;
  HasColumns: Boolean;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkTableColumn then
      AddColumnBox(Grid, Child, SpanAttribute(Child, 'span', MostColumnsSpanned))
    else if Child.Kind = bkTableColumnGroup then
    begin
      HasColumns := False;
      Column := Child.FirstChild;
      while Column <> nil do
      begin
        if Column.Kind = bkTableColumn then
        begin
          HasColumns := True;
          AddColumnBox(Grid, Column, SpanAttribute(Column, 'span', MostColumnsSpanned));
        end;
        Column := Column.NextSibling;
      end;
      if not HasColumns then
        AddColumnBox(Grid, Child, SpanAttribute(Child, 'span', MostColumnsSpanned));
    end;
    Child := Child.NextSibling;
  end;
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
        Span := SpanAttribute(Cell, 'colspan', MostColumnsSpanned);
        RowSpan := SpanAttribute(Cell, 'rowspan', MostRowsSpanned);
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
  CollectColumns(Box, Grid);
  if Length(Grid.ColumnBoxes) > Grid.ColumnCount then
    Grid.ColumnCount := Length(Grid.ColumnBoxes);
  Index := Length(Grid.ColumnBoxes);
  SetLength(Grid.ColumnBoxes, Grid.ColumnCount);
  for Column := Index to Grid.ColumnCount - 1 do
    Grid.ColumnBoxes[Column] := nil;
  SetLength(Grid.ColumnMin, Grid.ColumnCount);
  SetLength(Grid.ColumnMax, Grid.ColumnCount);
  SetLength(Grid.ColumnWidth, Grid.ColumnCount);
  SetLength(Grid.ColumnFixed, Grid.ColumnCount);
end;

end.
