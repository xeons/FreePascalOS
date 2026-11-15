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
  The terminal's screen: rows of character cells, the cursor, and the
  lines that scrolled off the top (the scrollback).

  Everything the emulator does lands here as an operation on the grid:
  a character at the cursor (with the line wrapping to the next one
  when it reaches the right edge: the cursor waits in the last column
  until the next character, as on a VT100), line feeds that scroll the
  scrolling region, erasing, inserting and deleting lines and
  characters, and moving the cursor. Lines scrolled off the top of a
  region that starts at the top of the screen go to the scrollback,
  which keeps the newest ScrollbackCapacity of them (the alternate
  screen of full-screen programs keeps none).

  The view reads the scrollback and the screen as one list of lines
  (CellAt): first the scrollback, oldest first, then the screen's rows.
  LinesScrolledOff counts every line that ever went to the scrollback,
  so the view can keep showing the same lines while the user has
  scrolled back.

  Rows and columns count from 0 here.
}
unit Terminal.Screen;

{$mode objfpc}
{$H+}

interface

uses
  Terminal.Cells;

const
  DefaultScrollbackLines = 2000;
  TabWidth = 8;

type
  TTerminalScreen = class
  private
    FRows: LongInt;
    FColumns: LongInt;
    FLines: array of TCellLine;
    FScrollback: array of TCellLine;
    FScrollbackCapacity: LongInt;
    FScrollbackStart: LongInt;
    FScrollbackCount: LongInt;
    FLinesScrolledOff: QWord;
    FCursorRow: LongInt;
    FCursorColumn: LongInt;
    FWrapPending: Boolean;
    FAutoWrap: Boolean;
    FCursorVisible: Boolean;
    FPen: TCell;
    FScrollTop: LongInt;
    FScrollBottom: LongInt;
    FSavedRow: LongInt;
    FSavedColumn: LongInt;
    FSavedPen: TCell;
    function BlankLine(Count: LongInt): TCellLine;
    procedure FitLine(var Line: TCellLine; Count: LongInt);
    procedure PushToScrollback(const Line: TCellLine);
    function PopFromScrollback(out Line: TCellLine): Boolean;
    procedure ClampCursor;
    procedure FillCells(Row, FirstColumn, LastColumn: LongInt);
    procedure ScrollRegionUp(Top, Bottom, Count: LongInt);
    procedure ScrollRegionDown(Top, Bottom, Count: LongInt);
  public
    constructor Create(ARows, AColumns, AScrollbackCapacity: LongInt);
    { A new size: lines keep their text (cut or padded on the right);
      when rows go, lines above the cursor go to the scrollback, and when
      rows come, lines come back from it. }
    procedure Resize(ARows, AColumns: LongInt);
    { Everything blank, the cursor home, the default pen, the whole
      screen the scrolling region (the scrollback stays). }
    procedure Reset;
    procedure PutCharacter(CodePoint: LongWord);
    procedure CarriageReturn;
    { Down a row, scrolling the region when at its bottom. }
    procedure LineFeed;
    { Up a row, scrolling the region down when at its top. }
    procedure ReverseLineFeed;
    procedure Backspace;
    procedure Tab;
    procedure MoveCursorTo(Row, Column: LongInt);
    { Mode 0: from the cursor on; 1: up to the cursor; 2: all. }
    procedure EraseInLine(Mode: LongInt);
    { The same for the screen; mode 3 empties the scrollback. }
    procedure EraseInDisplay(Mode: LongInt);
    procedure InsertLines(Count: LongInt);
    procedure DeleteLines(Count: LongInt);
    procedure InsertCharacters(Count: LongInt);
    procedure DeleteCharacters(Count: LongInt);
    procedure EraseCharacters(Count: LongInt);
    { The scrolling region up (text moves up) or down by Count lines. }
    procedure ScrollUp(Count: LongInt);
    procedure ScrollDown(Count: LongInt);
    { Rows Top to Bottom; anything invalid means the whole screen. The
      cursor goes home. }
    procedure SetScrollRegion(Top, Bottom: LongInt);
    procedure SaveCursor;
    procedure RestoreCursor;
    procedure ClearScrollback;
    { The scrollback and the screen as one list of lines. }
    function LineCount: LongInt;
    { The cell at Column of line Index of that list; a blank one past
      the end of a line. }
    function CellAt(Index, Column: LongInt): TCell;
    property Rows: LongInt read FRows;
    property Columns: LongInt read FColumns;
    property CursorRow: LongInt read FCursorRow;
    property CursorColumn: LongInt read FCursorColumn;
    property CursorVisible: Boolean read FCursorVisible write FCursorVisible;
    property AutoWrap: Boolean read FAutoWrap write FAutoWrap;
    property Pen: TCell read FPen write FPen;
    property ScrollbackCount: LongInt read FScrollbackCount;
    property LinesScrolledOff: QWord read FLinesScrolledOff;
  end;

implementation

constructor TTerminalScreen.Create(ARows, AColumns, AScrollbackCapacity: LongInt);
begin
  inherited Create;
  if ARows < 1 then
    ARows := 1;
  if AColumns < 1 then
    AColumns := 1;
  FRows := ARows;
  FColumns := AColumns;
  FScrollbackCapacity := AScrollbackCapacity;
  SetLength(FScrollback, FScrollbackCapacity);
  SetLength(FLines, FRows);
  FAutoWrap := True;
  Reset;
end;

function TTerminalScreen.BlankLine(Count: LongInt): TCellLine;
var
  Column: LongInt;
begin
  Result := nil;
  SetLength(Result, Count);
  for Column := 0 to Count - 1 do
    Result[Column] := BlankCell(FPen);
end;

{ Cuts or pads Line to Count cells (padding in the default colours). }
procedure TTerminalScreen.FitLine(var Line: TCellLine; Count: LongInt);
var
  OldCount: LongInt;
  Column: LongInt;
begin
  OldCount := Length(Line);
  SetLength(Line, Count);
  for Column := OldCount to Count - 1 do
    Line[Column] := BlankCell(DefaultPen);
end;

procedure TTerminalScreen.PushToScrollback(const Line: TCellLine);
var
  Slot: LongInt;
begin
  Inc(FLinesScrolledOff);
  if FScrollbackCapacity = 0 then
    Exit;
  if FScrollbackCount < FScrollbackCapacity then
  begin
    Slot := (FScrollbackStart + FScrollbackCount) mod FScrollbackCapacity;
    Inc(FScrollbackCount);
  end
  else
  begin
    { Full: the oldest line makes room. }
    Slot := FScrollbackStart;
    FScrollbackStart := (FScrollbackStart + 1) mod FScrollbackCapacity;
  end;
  FScrollback[Slot] := Line;
end;

function TTerminalScreen.PopFromScrollback(out Line: TCellLine): Boolean;
var
  Slot: LongInt;
begin
  Line := nil;
  Result := FScrollbackCount > 0;
  if not Result then
    Exit;
  Slot := (FScrollbackStart + FScrollbackCount - 1) mod FScrollbackCapacity;
  Line := FScrollback[Slot];
  FScrollback[Slot] := nil;
  Dec(FScrollbackCount);
  if FLinesScrolledOff > 0 then
    Dec(FLinesScrolledOff);
end;

procedure TTerminalScreen.ClampCursor;
begin
  if FCursorRow < 0 then
    FCursorRow := 0;
  if FCursorRow >= FRows then
    FCursorRow := FRows - 1;
  if FCursorColumn < 0 then
    FCursorColumn := 0;
  if FCursorColumn >= FColumns then
    FCursorColumn := FColumns - 1;
end;

procedure TTerminalScreen.Resize(ARows, AColumns: LongInt);
var
  Row: LongInt;
  Excess: LongInt;
  Shifted: LongInt;
  Line: TCellLine;
begin
  if ARows < 1 then
    ARows := 1;
  if AColumns < 1 then
    AColumns := 1;
  { Fewer rows: lines above the cursor go to the scrollback, so the
    cursor stays on the screen; then rows below it go. }
  if ARows < FRows then
  begin
    Excess := FCursorRow - ARows + 1;
    if Excess > 0 then
    begin
      for Row := 0 to Excess - 1 do
        PushToScrollback(FLines[Row]);
      for Row := 0 to FRows - Excess - 1 do
        FLines[Row] := FLines[Row + Excess];
      FCursorRow := FCursorRow - Excess;
    end;
    SetLength(FLines, ARows);
  end
  else if ARows > FRows then
  begin
    { More rows: lines come back from the scrollback at the top while
      there are any, else blank rows go at the bottom. }
    SetLength(FLines, ARows);
    for Row := FRows to ARows - 1 do
      FLines[Row] := nil;
    Row := FRows;
    while (Row < ARows) and PopFromScrollback(Line) do
    begin
      for Shifted := Row downto 1 do
        FLines[Shifted] := FLines[Shifted - 1];
      FLines[0] := Line;
      Inc(FCursorRow);
      Inc(Row);
    end;
  end;
  FRows := ARows;
  FColumns := AColumns;
  for Row := 0 to FRows - 1 do
    FitLine(FLines[Row], FColumns);
  FScrollTop := 0;
  FScrollBottom := FRows - 1;
  FWrapPending := False;
  ClampCursor;
end;

procedure TTerminalScreen.Reset;
var
  Row: LongInt;
begin
  FPen := DefaultPen;
  for Row := 0 to FRows - 1 do
    FLines[Row] := BlankLine(FColumns);
  FCursorRow := 0;
  FCursorColumn := 0;
  FWrapPending := False;
  FCursorVisible := True;
  FAutoWrap := True;
  FScrollTop := 0;
  FScrollBottom := FRows - 1;
  FSavedRow := 0;
  FSavedColumn := 0;
  FSavedPen := FPen;
end;

procedure TTerminalScreen.PutCharacter(CodePoint: LongWord);
var
  Cell: TCell;
begin
  if FWrapPending then
  begin
    CarriageReturn;
    LineFeed;
  end;
  Cell := FPen;
  Cell.CodePoint := CodePoint;
  FLines[FCursorRow][FCursorColumn] := Cell;
  if FCursorColumn < FColumns - 1 then
    Inc(FCursorColumn)
  else
    FWrapPending := FAutoWrap;
end;

procedure TTerminalScreen.CarriageReturn;
begin
  FCursorColumn := 0;
  FWrapPending := False;
end;

procedure TTerminalScreen.LineFeed;
begin
  FWrapPending := False;
  if FCursorRow = FScrollBottom then
    ScrollRegionUp(FScrollTop, FScrollBottom, 1)
  else if FCursorRow < FRows - 1 then
    Inc(FCursorRow);
end;

procedure TTerminalScreen.ReverseLineFeed;
begin
  FWrapPending := False;
  if FCursorRow = FScrollTop then
    ScrollRegionDown(FScrollTop, FScrollBottom, 1)
  else if FCursorRow > 0 then
    Dec(FCursorRow);
end;

procedure TTerminalScreen.Backspace;
begin
  FWrapPending := False;
  if FCursorColumn > 0 then
    Dec(FCursorColumn);
end;

procedure TTerminalScreen.Tab;
begin
  FWrapPending := False;
  FCursorColumn := (FCursorColumn div TabWidth + 1) * TabWidth;
  if FCursorColumn >= FColumns then
    FCursorColumn := FColumns - 1;
end;

procedure TTerminalScreen.MoveCursorTo(Row, Column: LongInt);
begin
  FCursorRow := Row;
  FCursorColumn := Column;
  FWrapPending := False;
  ClampCursor;
end;

{ Blanks columns FirstColumn to LastColumn of Row in the pen's colours. }
procedure TTerminalScreen.FillCells(Row, FirstColumn, LastColumn: LongInt);
var
  Column: LongInt;
begin
  if FirstColumn < 0 then
    FirstColumn := 0;
  if LastColumn >= FColumns then
    LastColumn := FColumns - 1;
  for Column := FirstColumn to LastColumn do
    FLines[Row][Column] := BlankCell(FPen);
end;

procedure TTerminalScreen.EraseInLine(Mode: LongInt);
begin
  case Mode of
    0: FillCells(FCursorRow, FCursorColumn, FColumns - 1);
    1: FillCells(FCursorRow, 0, FCursorColumn);
    2: FillCells(FCursorRow, 0, FColumns - 1);
  end;
end;

procedure TTerminalScreen.EraseInDisplay(Mode: LongInt);
var
  Row: LongInt;
begin
  case Mode of
    0:
      begin
        EraseInLine(0);
        for Row := FCursorRow + 1 to FRows - 1 do
          FillCells(Row, 0, FColumns - 1);
      end;
    1:
      begin
        for Row := 0 to FCursorRow - 1 do
          FillCells(Row, 0, FColumns - 1);
        EraseInLine(1);
      end;
    2:
      for Row := 0 to FRows - 1 do
        FillCells(Row, 0, FColumns - 1);
    3:
      ClearScrollback;
  end;
end;

{ Lines Top+Count .. Bottom move up to Top; the lines leaving at Top go to
  the scrollback when the region starts at the top of the screen. }
procedure TTerminalScreen.ScrollRegionUp(Top, Bottom, Count: LongInt);
var
  Step: LongInt;
  Row: LongInt;
begin
  if Count > Bottom - Top + 1 then
    Count := Bottom - Top + 1;
  for Step := 1 to Count do
  begin
    if Top = 0 then
      PushToScrollback(FLines[Top]);
    for Row := Top to Bottom - 1 do
      FLines[Row] := FLines[Row + 1];
    FLines[Bottom] := BlankLine(FColumns);
  end;
end;

procedure TTerminalScreen.ScrollRegionDown(Top, Bottom, Count: LongInt);
var
  Step: LongInt;
  Row: LongInt;
begin
  if Count > Bottom - Top + 1 then
    Count := Bottom - Top + 1;
  for Step := 1 to Count do
  begin
    for Row := Bottom downto Top + 1 do
      FLines[Row] := FLines[Row - 1];
    FLines[Top] := BlankLine(FColumns);
  end;
end;

procedure TTerminalScreen.InsertLines(Count: LongInt);
begin
  if (FCursorRow < FScrollTop) or (FCursorRow > FScrollBottom) or (Count < 1) then
    Exit;
  ScrollRegionDown(FCursorRow, FScrollBottom, Count);
  FCursorColumn := 0;
  FWrapPending := False;
end;

procedure TTerminalScreen.DeleteLines(Count: LongInt);
var
  Step: LongInt;
  Row: LongInt;
begin
  if (FCursorRow < FScrollTop) or (FCursorRow > FScrollBottom) or (Count < 1) then
    Exit;
  if Count > FScrollBottom - FCursorRow + 1 then
    Count := FScrollBottom - FCursorRow + 1;
  { Deleted lines do not go to the scrollback. }
  for Step := 1 to Count do
  begin
    for Row := FCursorRow to FScrollBottom - 1 do
      FLines[Row] := FLines[Row + 1];
    FLines[FScrollBottom] := BlankLine(FColumns);
  end;
  FCursorColumn := 0;
  FWrapPending := False;
end;

procedure TTerminalScreen.InsertCharacters(Count: LongInt);
var
  Column: LongInt;
begin
  if Count > FColumns - FCursorColumn then
    Count := FColumns - FCursorColumn;
  if Count < 1 then
    Exit;
  for Column := FColumns - 1 downto FCursorColumn + Count do
    FLines[FCursorRow][Column] := FLines[FCursorRow][Column - Count];
  FillCells(FCursorRow, FCursorColumn, FCursorColumn + Count - 1);
  FWrapPending := False;
end;

procedure TTerminalScreen.DeleteCharacters(Count: LongInt);
var
  Column: LongInt;
begin
  if Count > FColumns - FCursorColumn then
    Count := FColumns - FCursorColumn;
  if Count < 1 then
    Exit;
  for Column := FCursorColumn to FColumns - 1 - Count do
    FLines[FCursorRow][Column] := FLines[FCursorRow][Column + Count];
  FillCells(FCursorRow, FColumns - Count, FColumns - 1);
  FWrapPending := False;
end;

procedure TTerminalScreen.EraseCharacters(Count: LongInt);
begin
  if Count < 1 then
    Count := 1;
  FillCells(FCursorRow, FCursorColumn, FCursorColumn + Count - 1);
  FWrapPending := False;
end;

procedure TTerminalScreen.ScrollUp(Count: LongInt);
begin
  if Count >= 1 then
    ScrollRegionUp(FScrollTop, FScrollBottom, Count);
end;

procedure TTerminalScreen.ScrollDown(Count: LongInt);
begin
  if Count >= 1 then
    ScrollRegionDown(FScrollTop, FScrollBottom, Count);
end;

procedure TTerminalScreen.SetScrollRegion(Top, Bottom: LongInt);
begin
  if (Top < 0) or (Bottom >= FRows) or (Top >= Bottom) then
  begin
    Top := 0;
    Bottom := FRows - 1;
  end;
  FScrollTop := Top;
  FScrollBottom := Bottom;
  MoveCursorTo(0, 0);
end;

procedure TTerminalScreen.SaveCursor;
begin
  FSavedRow := FCursorRow;
  FSavedColumn := FCursorColumn;
  FSavedPen := FPen;
end;

procedure TTerminalScreen.RestoreCursor;
begin
  FPen := FSavedPen;
  MoveCursorTo(FSavedRow, FSavedColumn);
end;

procedure TTerminalScreen.ClearScrollback;
var
  Index: LongInt;
begin
  for Index := 0 to FScrollbackCapacity - 1 do
    FScrollback[Index] := nil;
  FScrollbackStart := 0;
  FScrollbackCount := 0;
end;

function TTerminalScreen.LineCount: LongInt;
begin
  Result := FScrollbackCount + FRows;
end;

function TTerminalScreen.CellAt(Index, Column: LongInt): TCell;
var
  Line: TCellLine;
begin
  Result := BlankCell(DefaultPen);
  if (Index < 0) or (Column < 0) then
    Exit;
  if Index < FScrollbackCount then
    Line := FScrollback[(FScrollbackStart + Index) mod FScrollbackCapacity]
  else if Index - FScrollbackCount < FRows then
    Line := FLines[Index - FScrollbackCount]
  else
    Exit;
  if Column < Length(Line) then
    Result := Line[Column];
end;

end.
