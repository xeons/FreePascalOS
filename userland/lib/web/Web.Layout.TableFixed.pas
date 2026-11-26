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
  The fixed table layout (CSS 2.2 17.5.2.1, table-layout: fixed with a
  width that is not auto; an auto width is laid out automatically, as
  browsers do). A column's width comes from its column element's width,
  else from the cell of the first row in it (a length, or a percentage
  of the table, both with the cell's padding and border; a spanning
  cell is shared out evenly), never from content. Columns that took too
  much give back from their percentages; columns without a width share
  what is left evenly, else the rest goes to the columns with lengths in
  proportion to them, else to the percentage columns.
}
unit Web.Layout.TableFixed;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.TableGrid;

function UsesFixedLayout(Box: TLayoutBox): Boolean;
{ What the columns need at least: their lengths (column elements and the
  first row's cells; percentages count for nothing), without spacing. }
function FixedColumnsMinimum(const Grid: TTableGrid): Single;
{ Grid.ColumnWidth for Available, the table's content width less its
  border spacing. }
procedure FixedColumnWidths(var Grid: TTableGrid; Available: Single);

implementation

uses
  Math, Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Values;

type
  TColumnWidthKind = (ColumnAuto, ColumnLength, ColumnPercentage);

function UsesFixedLayout(Box: TLayoutBox): Boolean;
begin
  Result := (Box.Style.Keyword(cpTableLayout) = kwFixed) and not IsAutoValue(Box.Style, cpWidth);
end;

{ The cell of the first row that covers Column; nil when none. }
function FirstRowCell(const Grid: TTableGrid; Column: Integer): PGridCell;
var
  Index: Integer;
begin
  for Index := 0 to Grid.CellCount - 1 do
    if (Grid.Cells[Index].Row = 0) and (Grid.Cells[Index].Column <= Column) and
       (Column < Grid.Cells[Index].Column + Grid.Cells[Index].ColumnSpan) then
      Exit(@Grid.Cells[Index]);
  Result := nil;
end;

{ Column's width as its column element or first-row cell gives it: a
  length (Width), a percentage (Percent, 0 to 1, and Width resolved
  against Available) or nothing. }
function ColumnWidthOf(const Grid: TTableGrid; Column: Integer; Available: Single; out Width,
  Percent: Single): TColumnWidthKind;
var
  Value: PCssComputedValue;
  Cell: PGridCell;
  Span: Integer;
begin
  Width := 0;
  Percent := 0;
  Result := ColumnAuto;
  if Grid.ColumnBoxes[Column] <> nil then
  begin
    Value := Grid.ColumnBoxes[Column].Style.Value(cpWidth);
    if Value^.Kind = cvLength then
    begin
      Width := Max(0, Value^.Number);
      Exit(ColumnLength);
    end;
    if Value^.Kind = cvPercentage then
    begin
      Percent := Max(0, Value^.Percent / 100);
      Width := Floor(Percent * Max(0, Available));
      Exit(ColumnPercentage);
    end;
  end;
  Cell := FirstRowCell(Grid, Column);
  if Cell = nil then
    Exit;
  Span := Cell^.ColumnSpan;
  ResolveBoxEdges(Cell^.Cell, Max(0, Available));
  Value := Cell^.Cell.Style.Value(cpWidth);
  if Value^.Kind = cvLength then
  begin
    Width := Max(0, SpecifiedBorderBoxWidth(Cell^.Cell, Max(0, Available)));
    Width := Max(0, (Width + Grid.SpacingX) / Span - Grid.SpacingX);
    Result := ColumnLength;
  end
  else if Value^.Kind = cvPercentage then
  begin
    Percent := Max(0, Value^.Percent / 100);
    Width := Floor(Percent * Max(0, Available));
    if Cell^.Cell.Style.Keyword(cpBoxSizing) <> kwBorderBox then
      Width := Width + HorizontalBorderPadding(Cell^.Cell);
    Width := Max(0, (Width + Grid.SpacingX) / Span - Grid.SpacingX);
    Percent := Percent / Span;
    Result := ColumnPercentage;
  end;
end;

function FixedColumnsMinimum(const Grid: TTableGrid): Single;
var
  Column: Integer;
  Width, Percent: Single;
begin
  Result := 0;
  for Column := 0 to Grid.ColumnCount - 1 do
    if ColumnWidthOf(Grid, Column, 0, Width, Percent) = ColumnLength then
      Result := Result + Width;
end;

procedure FixedColumnWidths(var Grid: TTableGrid; Available: Single);
var
  Column, Unassigned: Integer;
  Kinds: array of TColumnWidthKind;
  Percents: array of Single;
  Width, Percent, Remaining, PercentTotal, LengthTotal, Reduce, Share: Single;
begin
  Kinds := nil;
  Percents := nil;
  SetLength(Kinds, Grid.ColumnCount);
  SetLength(Percents, Grid.ColumnCount);
  Remaining := Available;
  PercentTotal := 0;
  LengthTotal := 0;
  Unassigned := 0;
  for Column := 0 to Grid.ColumnCount - 1 do
  begin
    Kinds[Column] := ColumnWidthOf(Grid, Column, Available, Width, Percent);
    Percents[Column] := Percent;
    Grid.ColumnWidth[Column] := Width;
    case Kinds[Column] of
      ColumnAuto: Inc(Unassigned);
      ColumnLength: LengthTotal := LengthTotal + Width;
      ColumnPercentage: PercentTotal := PercentTotal + Percent;
    end;
    if Kinds[Column] <> ColumnAuto then
      Remaining := Remaining - Width;
  end;
  if Remaining < 0 then
  begin
    { Too wide: the percentage columns give back what they can. }
    if PercentTotal > 0 then
    begin
      Reduce := Min(Floor(PercentTotal * Max(0, Available)), -Remaining);
      for Column := 0 to Grid.ColumnCount - 1 do
        if Kinds[Column] = ColumnPercentage then
          Grid.ColumnWidth[Column] := Max(0, Grid.ColumnWidth[Column] - Floor(Percents[Column] / PercentTotal * Reduce));
    end;
    Remaining := 0;
  end;
  if Unassigned > 0 then
  begin
    Share := Remaining / Unassigned;
    for Column := 0 to Grid.ColumnCount - 1 do
      if Kinds[Column] = ColumnAuto then
        Grid.ColumnWidth[Column] := Share;
  end
  else if Remaining > 0 then
  begin
    if LengthTotal > 0 then
    begin
      for Column := 0 to Grid.ColumnCount - 1 do
        if Kinds[Column] = ColumnLength then
          Grid.ColumnWidth[Column] := Grid.ColumnWidth[Column] + Remaining * Grid.ColumnWidth[Column] / LengthTotal;
    end
    else if PercentTotal > 0 then
    begin
      for Column := 0 to Grid.ColumnCount - 1 do
        if Kinds[Column] = ColumnPercentage then
          Grid.ColumnWidth[Column] := Grid.ColumnWidth[Column] + Remaining * Percents[Column] / PercentTotal;
    end
    else if Grid.ColumnCount > 0 then
      for Column := 0 to Grid.ColumnCount - 1 do
        Grid.ColumnWidth[Column] := Grid.ColumnWidth[Column] + Remaining / Grid.ColumnCount;
  end;
end;

end.
