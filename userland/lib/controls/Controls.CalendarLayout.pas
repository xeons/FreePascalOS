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
  Where the parts of a month calendar go (Controls.Calendar): a header
  with the previous and next buttons either side of the title (the
  month and year), the names of the days of the week, the grid of cells
  (six weeks of days; or four by three months, or years), optionally a
  column of week numbers before the days, and optionally a line for
  today at the bottom.

  All in pixels, from the metrics given (so it needs nothing of the
  screen, and builds for the host too).
}
unit Controls.CalendarLayout;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles;

type
  TCalendarPart = (CalendarPartNone, CalendarPartPrevious, CalendarPartNext, CalendarPartTitle, CalendarPartCell,
    CalendarPartWeekdays, CalendarPartToday);

  TCalendarMetrics = record
    { A line of text, and the space around things. }
    LineHeight: LongInt;
    Gap: LongInt;
    { The width of the week numbers' column (0: none). }
    WeekColumnWidth: LongInt;
    { The days' grid (seven by six with the day names) or four by three
      (months or years). }
    ShowsDays: Boolean;
    ShowsToday: Boolean;
  end;

  TCalendarLayout = record
    Header: TRectangle;
    Previous: TRectangle;
    Next: TRectangle;
    Title: TRectangle;
    { Empty unless days are shown. }
    Weekdays: TRectangle;
    WeekNumbers: TRectangle;
    Grid: TRectangle;
    Footer: TRectangle;
    Columns: LongInt;
    Rows: LongInt;
  end;

const
  MonthColumns = 4;
  MonthRows = 3;

function ComputeCalendarLayout(const Box: TRectangle; const Metrics: TCalendarMetrics): TCalendarLayout;
{ Cell Index (row by row) of the grid. }
function CalendarCellBounds(const Layout: TCalendarLayout; Index: LongInt): TRectangle;
{ The row's place in the week numbers' column. }
function CalendarWeekNumberBounds(const Layout: TCalendarLayout; Row: LongInt): TRectangle;
{ What is at (X, Y), and the cell there (-1 if it is no cell). }
function CalendarPartAt(const Layout: TCalendarLayout; X, Y: LongInt; out Cell: LongInt): TCalendarPart;
{ The size a calendar needs for cells CellWidth x CellHeight (pixels). }
procedure CalendarSizeFor(const Metrics: TCalendarMetrics; CellWidth, CellHeight: LongInt; out Width, Height: LongInt);

implementation

uses
  Controls.CalendarDates;

function HeaderHeight(const Metrics: TCalendarMetrics): LongInt;
begin
  Result := Metrics.LineHeight + 4 * Metrics.Gap;
end;

function WeekdaysHeight(const Metrics: TCalendarMetrics): LongInt;
begin
  Result := Metrics.LineHeight + 2 * Metrics.Gap;
end;

function FooterHeight(const Metrics: TCalendarMetrics): LongInt;
begin
  Result := Metrics.LineHeight + 3 * Metrics.Gap;
end;

function ComputeCalendarLayout(const Box: TRectangle; const Metrics: TCalendarMetrics): TCalendarLayout;
var
  Top: LongInt;
  Bottom: LongInt;
  ButtonSize: LongInt;
  GridLeft: LongInt;
begin
  Top := Box.Top;
  Result.Header := MakeRectangle(Box.Left, Top, RectangleWidth(Box), HeaderHeight(Metrics));
  ButtonSize := RectangleHeight(Result.Header) - 2 * Metrics.Gap;
  Result.Previous := MakeRectangle(Box.Left + Metrics.Gap, Top + Metrics.Gap, ButtonSize, ButtonSize);
  Result.Next := MakeRectangle(Box.Right - Metrics.Gap - ButtonSize, Top + Metrics.Gap, ButtonSize, ButtonSize);
  Result.Title := MakeRectangle(Result.Previous.Right + Metrics.Gap, Top + Metrics.Gap,
    Result.Next.Left - Result.Previous.Right - 2 * Metrics.Gap, ButtonSize);
  Top := Result.Header.Bottom;
  Bottom := Box.Bottom;
  if Metrics.ShowsToday then
  begin
    Result.Footer := MakeRectangle(Box.Left, Bottom - FooterHeight(Metrics), RectangleWidth(Box),
      FooterHeight(Metrics));
    Bottom := Result.Footer.Top;
  end
  else
    Result.Footer := MakeRectangle(Box.Left, Bottom, 0, 0);
  if Metrics.ShowsDays then
  begin
    GridLeft := Box.Left + Metrics.Gap + Metrics.WeekColumnWidth;
    Result.Weekdays := MakeRectangle(GridLeft, Top, Box.Right - Metrics.Gap - GridLeft, WeekdaysHeight(Metrics));
    Top := Result.Weekdays.Bottom;
    Result.Grid := MakeRectangle(GridLeft, Top, RectangleWidth(Result.Weekdays), Bottom - Top - Metrics.Gap);
    Result.WeekNumbers := MakeRectangle(Box.Left + Metrics.Gap, Top, Metrics.WeekColumnWidth,
      RectangleHeight(Result.Grid));
    Result.Columns := DaysInWeek;
    Result.Rows := GridWeeks;
  end
  else
  begin
    Result.Weekdays := MakeRectangle(Box.Left, Top, 0, 0);
    Result.WeekNumbers := MakeRectangle(Box.Left, Top, 0, 0);
    Result.Grid := MakeRectangle(Box.Left + Metrics.Gap, Top + Metrics.Gap, RectangleWidth(Box) - 2 * Metrics.Gap,
      Bottom - Top - 2 * Metrics.Gap);
    Result.Columns := MonthColumns;
    Result.Rows := MonthRows;
  end;
end;

{ Edge Index of Count equal parts of Length from Start (rounded so the
  parts fill it exactly). }
function PartEdge(Start, Length, Count, Index: LongInt): LongInt;
begin
  Result := Start + (Length * Index) div Count;
end;

function CalendarCellBounds(const Layout: TCalendarLayout; Index: LongInt): TRectangle;
var
  Row: LongInt;
  Column: LongInt;
  Grid: TRectangle;
begin
  Grid := Layout.Grid;
  Row := Index div Layout.Columns;
  Column := Index mod Layout.Columns;
  Result.Left := PartEdge(Grid.Left, RectangleWidth(Grid), Layout.Columns, Column);
  Result.Right := PartEdge(Grid.Left, RectangleWidth(Grid), Layout.Columns, Column + 1);
  Result.Top := PartEdge(Grid.Top, RectangleHeight(Grid), Layout.Rows, Row);
  Result.Bottom := PartEdge(Grid.Top, RectangleHeight(Grid), Layout.Rows, Row + 1);
end;

function CalendarWeekNumberBounds(const Layout: TCalendarLayout; Row: LongInt): TRectangle;
begin
  Result := Layout.WeekNumbers;
  Result.Top := PartEdge(Layout.Grid.Top, RectangleHeight(Layout.Grid), Layout.Rows, Row);
  Result.Bottom := PartEdge(Layout.Grid.Top, RectangleHeight(Layout.Grid), Layout.Rows, Row + 1);
end;

function CalendarPartAt(const Layout: TCalendarLayout; X, Y: LongInt; out Cell: LongInt): TCalendarPart;
var
  Index: LongInt;
begin
  Cell := -1;
  if RectangleContainsPoint(Layout.Previous, X, Y) then
    Exit(CalendarPartPrevious);
  if RectangleContainsPoint(Layout.Next, X, Y) then
    Exit(CalendarPartNext);
  if RectangleContainsPoint(Layout.Title, X, Y) then
    Exit(CalendarPartTitle);
  if RectangleContainsPoint(Layout.Footer, X, Y) then
    Exit(CalendarPartToday);
  if RectangleContainsPoint(Layout.Weekdays, X, Y) then
    Exit(CalendarPartWeekdays);
  if RectangleContainsPoint(Layout.Grid, X, Y) then
    for Index := 0 to Layout.Columns * Layout.Rows - 1 do
      if RectangleContainsPoint(CalendarCellBounds(Layout, Index), X, Y) then
      begin
        Cell := Index;
        Exit(CalendarPartCell);
      end;
  Result := CalendarPartNone;
end;

procedure CalendarSizeFor(const Metrics: TCalendarMetrics; CellWidth, CellHeight: LongInt; out Width, Height: LongInt);
begin
  Width := 2 * Metrics.Gap + Metrics.WeekColumnWidth + DaysInWeek * CellWidth;
  Height := HeaderHeight(Metrics) + WeekdaysHeight(Metrics) + GridWeeks * CellHeight + Metrics.Gap;
  if Metrics.ShowsToday then
    Inc(Height, FooterHeight(Metrics));
end;

end.
