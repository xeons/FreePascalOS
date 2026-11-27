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
  The text selected with the mouse: from where the button went down (the
  anchor) to where the pointer is (the extent), in reading order.

  Positions are a line and a column boundary (column N is the left edge
  of cell N). Lines are counted from the first line that ever was
  (Terminal.Screen's LinesScrolledOff tells how many went before the
  scrollback), so a selection stays on its text while more output
  scrolls it up.
}
unit Terminal.Selection;

{$mode objfpc}
{$H+}

interface

uses
  Terminal.Screen;

type
  TTextPlace = record
    Line: Int64;
    Column: LongInt;
  end;

  TTerminalSelection = record
    Anchor: TTextPlace;
    Extent: TTextPlace;
  end;

function MakeTextPlace(Line: Int64; Column: LongInt): TTextPlace;
{ The line number (as above) of line Index of the screen's list, and
  back. }
function AbsoluteLineOf(Screen: TTerminalScreen; Index: LongInt): Int64;
function IndexOfAbsoluteLine(Screen: TTerminalScreen; Line: Int64): Int64;

procedure ClearSelection(out Selection: TTerminalSelection);
function SelectionIsEmpty(const Selection: TTerminalSelection): Boolean;
{ Whether the cell at Column of Line is selected. }
function CellIsSelected(const Selection: TTerminalSelection; Line: Int64; Column: LongInt): Boolean;
{ The selected text: each line's cells as UTF-8 without the spaces at its
  end, lines joined by line feeds. }
function SelectedText(const Selection: TTerminalSelection; Screen: TTerminalScreen): string;

implementation

uses
  Terminal.Cells,
  Terminal.Keys;

function MakeTextPlace(Line: Int64; Column: LongInt): TTextPlace;
begin
  Result.Line := Line;
  Result.Column := Column;
end;

function AbsoluteLineOf(Screen: TTerminalScreen; Index: LongInt): Int64;
begin
  Result := Int64(Screen.LinesScrolledOff) - Screen.ScrollbackCount + Index;
end;

function IndexOfAbsoluteLine(Screen: TTerminalScreen; Line: Int64): Int64;
begin
  Result := Line - (Int64(Screen.LinesScrolledOff) - Screen.ScrollbackCount);
end;

function PlaceBefore(const First, Second: TTextPlace): Boolean;
begin
  Result := (First.Line < Second.Line) or ((First.Line = Second.Line) and (First.Column < Second.Column));
end;

procedure OrderedPlaces(const Selection: TTerminalSelection; out Start, Finish: TTextPlace);
begin
  if PlaceBefore(Selection.Extent, Selection.Anchor) then
  begin
    Start := Selection.Extent;
    Finish := Selection.Anchor;
  end
  else
  begin
    Start := Selection.Anchor;
    Finish := Selection.Extent;
  end;
end;

procedure ClearSelection(out Selection: TTerminalSelection);
begin
  Selection.Anchor := MakeTextPlace(0, 0);
  Selection.Extent := Selection.Anchor;
end;

function SelectionIsEmpty(const Selection: TTerminalSelection): Boolean;
begin
  Result := (Selection.Anchor.Line = Selection.Extent.Line) and (Selection.Anchor.Column = Selection.Extent.Column);
end;

function CellIsSelected(const Selection: TTerminalSelection; Line: Int64; Column: LongInt): Boolean;
var
  Start: TTextPlace;
  Finish: TTextPlace;
begin
  if SelectionIsEmpty(Selection) then
    Exit(False);
  OrderedPlaces(Selection, Start, Finish);
  Result := not PlaceBefore(MakeTextPlace(Line, Column), Start) and PlaceBefore(MakeTextPlace(Line, Column), Finish);
end;

{ Columns FromColumn up to (not including) ToColumn of a line, trimmed. }
function LineText(Screen: TTerminalScreen; Line: Int64; FromColumn, ToColumn: LongInt): string;
var
  Index: Int64;
  Column: LongInt;
  LastUsed: LongInt;
  Cell: TCell;
begin
  Result := '';
  Index := IndexOfAbsoluteLine(Screen, Line);
  if (Index < 0) or (Index >= Screen.LineCount) then
    Exit;
  if ToColumn > Screen.Columns then
    ToColumn := Screen.Columns;
  LastUsed := FromColumn - 1;
  for Column := FromColumn to ToColumn - 1 do
    if Screen.CellAt(LongInt(Index), Column).CodePoint <> 32 then
      LastUsed := Column;
  for Column := FromColumn to LastUsed do
  begin
    Cell := Screen.CellAt(LongInt(Index), Column);
    Result := Result + Utf8Of(Cell.CodePoint);
  end;
end;

function SelectedText(const Selection: TTerminalSelection; Screen: TTerminalScreen): string;
var
  Start: TTextPlace;
  Finish: TTextPlace;
  Line: Int64;
begin
  Result := '';
  if SelectionIsEmpty(Selection) then
    Exit;
  OrderedPlaces(Selection, Start, Finish);
  if Start.Line = Finish.Line then
    Exit(LineText(Screen, Start.Line, Start.Column, Finish.Column));
  Result := LineText(Screen, Start.Line, Start.Column, Screen.Columns);
  Line := Start.Line + 1;
  while Line < Finish.Line do
  begin
    Result := Result + #10 + LineText(Screen, Line, 0, Screen.Columns);
    Inc(Line);
  end;
  Result := Result + #10 + LineText(Screen, Finish.Line, 0, Finish.Column);
end;

end.
