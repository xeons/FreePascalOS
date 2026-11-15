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
  Where a list view's items are: every view is a grid of equal cells.

  Details is one cell per line (a row across the whole width); small and
  large icons fill a line across, then the next line down; the list view
  fills a column down, then the next column to the right. So a "line"
  is a row of cells, or a column of them when the grid goes down first
  (ColumnMajor), and scrolling moves by lines: down for rows, across for
  columns. The arrow keys move along a line or to the next one, the same
  way in every view.
}
unit Controls.ListViewLayout;

{$mode objfpc}

interface

uses
  Drawing.Rectangles;

type
  TListViewGrid = record
    { Where the cells are shown (pixels of the control). }
    Area: TRectangle;
    CellWidth: LongInt;
    CellHeight: LongInt;
    { Down first, then across (the list view). }
    ColumnMajor: Boolean;
    ItemCount: LongInt;
    { The line shown first (scrolled to). }
    FirstLine: LongInt;
  end;

  TGridDirection = (GridUp, GridDown, GridLeft, GridRight);

function ItemsPerLine(const Grid: TListViewGrid): LongInt;
function LineCount(const Grid: TListViewGrid): LongInt;
{ Whole lines that fit in the area (at least one). }
function VisibleLineCount(const Grid: TListViewGrid): LongInt;
function LineOfItem(const Grid: TListViewGrid; Index: LongInt): LongInt;
{ Item Index's cell as scrolled now (it may be outside the area). }
function ItemCell(const Grid: TListViewGrid; Index: LongInt): TRectangle;
{ The item whose cell holds (X, Y), or -1. }
function ItemAtPoint(const Grid: TListViewGrid; X, Y: LongInt): LongInt;
{ The item one step from Index in Direction (Index itself at an edge). }
function ItemInDirection(const Grid: TListViewGrid; Index: LongInt; Direction: TGridDirection): LongInt;

implementation

function ItemsPerLine(const Grid: TListViewGrid): LongInt;
begin
  if Grid.ColumnMajor then
    Result := RectangleHeight(Grid.Area) div Grid.CellHeight
  else
    Result := RectangleWidth(Grid.Area) div Grid.CellWidth;
  if Result < 1 then
    Result := 1;
end;

function LineCount(const Grid: TListViewGrid): LongInt;
var
  PerLine: LongInt;
begin
  PerLine := ItemsPerLine(Grid);
  Result := (Grid.ItemCount + PerLine - 1) div PerLine;
end;

function VisibleLineCount(const Grid: TListViewGrid): LongInt;
begin
  if Grid.ColumnMajor then
    Result := RectangleWidth(Grid.Area) div Grid.CellWidth
  else
    Result := RectangleHeight(Grid.Area) div Grid.CellHeight;
  if Result < 1 then
    Result := 1;
end;

function LineOfItem(const Grid: TListViewGrid; Index: LongInt): LongInt;
begin
  Result := Index div ItemsPerLine(Grid);
end;

function ItemCell(const Grid: TListViewGrid; Index: LongInt): TRectangle;
var
  PerLine: LongInt;
  Line: LongInt;
  Place: LongInt;
begin
  PerLine := ItemsPerLine(Grid);
  Line := Index div PerLine - Grid.FirstLine;
  Place := Index mod PerLine;
  if Grid.ColumnMajor then
    Result := MakeRectangle(Grid.Area.Left + Line * Grid.CellWidth, Grid.Area.Top + Place * Grid.CellHeight,
      Grid.CellWidth, Grid.CellHeight)
  else
    Result := MakeRectangle(Grid.Area.Left + Place * Grid.CellWidth, Grid.Area.Top + Line * Grid.CellHeight,
      Grid.CellWidth, Grid.CellHeight);
end;

function ItemAtPoint(const Grid: TListViewGrid; X, Y: LongInt): LongInt;
var
  Column: LongInt;
  Row: LongInt;
  PerLine: LongInt;
begin
  Result := -1;
  if not RectangleContainsPoint(Grid.Area, X, Y) then
    Exit;
  Column := (X - Grid.Area.Left) div Grid.CellWidth;
  Row := (Y - Grid.Area.Top) div Grid.CellHeight;
  PerLine := ItemsPerLine(Grid);
  if Grid.ColumnMajor then
  begin
    if Row >= PerLine then
      Exit;
    Result := (Grid.FirstLine + Column) * PerLine + Row;
  end
  else
  begin
    if Column >= PerLine then
      Exit;
    Result := (Grid.FirstLine + Row) * PerLine + Column;
  end;
  if Result >= Grid.ItemCount then
    Result := -1;
end;

function ItemInDirection(const Grid: TListViewGrid; Index: LongInt; Direction: TGridDirection): LongInt;
var
  PerLine: LongInt;
  AlongLine: Boolean;
  MovingForward: Boolean;
begin
  PerLine := ItemsPerLine(Grid);
  { Along a line is down in a column, across in a row. }
  AlongLine := (Direction in [GridUp, GridDown]) = Grid.ColumnMajor;
  MovingForward := Direction in [GridDown, GridRight];
  if AlongLine and (PerLine = 1) then
    Exit(Index);
  if AlongLine and MovingForward and ((Index + 1) mod PerLine <> 0) then
    Result := Index + 1
  else if AlongLine and not MovingForward and (Index mod PerLine <> 0) then
    Result := Index - 1
  else if not AlongLine and MovingForward then
    Result := Index + PerLine
  else if not AlongLine then
    Result := Index - PerLine
  else
    Result := Index;
  if (Result < 0) or (Result >= Grid.ItemCount) then
    Result := Index;
end;

end.
