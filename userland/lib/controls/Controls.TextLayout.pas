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
  A line of text laid out in a face: where each character is, and the
  rows it wraps into.

  Characters are measured as libfont draws them (advances and kerning);
  a tab moves to the next tab stop, every eight spaces' widths from the
  line's start, and other control characters take no room. With a wrap
  width the line breaks into rows (Controls.TextWrap); without one it is
  a single row. A row is drawn from its start, so X positions in a row
  are relative to its first character.
}
unit Controls.TextLayout;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Font.Faces,
  Controls.TextPositions,
  Controls.TextWrap;

type
  TLineLayout = record
    { Where each character starts in the line's bytes (and its end). }
    Bytes: TByteOffsets;
    { Where each character starts, in pixels from the line's start (and
      where the last one ends). }
    Positions: TCharacterPositions;
    Rows: TRowStarts;
  end;

{ Text laid out in Face; WrapWidth 0 or less: no wrapping. }
function LayOutLine(Face: PFontFace; const Text: string; WrapWidth: LongInt): TLineLayout;
function CharacterCountOfLayout(const Layout: TLineLayout): LongInt;
function RowCountOfLayout(const Layout: TLineLayout): LongInt;
{ The character after the last of row Row. }
function RowEnd(const Layout: TLineLayout; Row: LongInt): LongInt;
{ The furthest a caret goes in row Row: the end of the line in the last
  row, else the last character (its end is where the next row starts,
  which the caret shows at). }
function RowCaretLimit(const Layout: TLineLayout; Row: LongInt): LongInt;
{ The row the caret at Column shows in. }
function RowOfColumn(const Layout: TLineLayout; Column: LongInt): LongInt;
{ Pixels from row Row's start to character Column. }
function XInRow(const Layout: TLineLayout; Row, Column: LongInt): LongInt;
{ The caret position in row Row nearest X (pixels from the row's start). }
function ColumnNearestX(const Layout: TLineLayout; Row, X: LongInt): LongInt;
{ The last character of row Row starting at or before X (pixels from the
  row's start); the row's first if none. }
function ColumnAtX(const Layout: TLineLayout; Row, X: LongInt): LongInt;
{ Characters First to Last - 1 of Text (in row Row) drawn with the row's
  start at RowLeft and the line's top at Top. }
procedure DrawLayoutRange(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Layout: TLineLayout;
  Row, First, Last, RowLeft, Top: LongInt; Color: TColor);

implementation

uses
  Font.Text;

const
  TabCharacter = 9;
  SpacesPerTab = 8;
  FirstPrintable = 32;

function TabStopWidth(Face: PFontFace): LongInt;
begin
  Result := SpacesPerTab * CharacterAdvance(Face^, 32);
  if Result < 1 then
    Result := 1;
end;

function LayOutLine(Face: PFontFace; const Text: string; WrapWidth: LongInt): TLineLayout;
var
  Count: LongInt;
  Index: LongInt;
  CodePoint: LongWord;
  Previous: LongWord;
  X: LongInt;
  TabWidth: LongInt;
  BreakAfter: TBreakFlags;
begin
  Result.Bytes := ByteOffsetsOf(Text);
  Count := Length(Result.Bytes) - 1;
  SetLength(Result.Positions, Count + 1);
  SetLength(BreakAfter, Count);
  X := 0;
  Previous := 0;
  TabWidth := 1;
  if Face <> nil then
    TabWidth := TabStopWidth(Face);
  for Index := 0 to Count - 1 do
  begin
    Result.Positions[Index] := X;
    CharacterAt(Text, Result.Bytes[Index] + 1, CodePoint);
    BreakAfter[Index] := (CodePoint = 32) or (CodePoint = TabCharacter);
    if Face = nil then
      Continue;
    if CodePoint = TabCharacter then
      X := (X div TabWidth + 1) * TabWidth
    else
    begin
      { As libfont measures: no kerning next to a control character. }
      if (Previous >= FirstPrintable) and (CodePoint >= FirstPrintable) and FaceHasKerning(Face^) then
        X := X + KerningBetween(Face^, Previous, CodePoint);
      X := X + CharacterAdvance(Face^, CodePoint);
    end;
    Previous := CodePoint;
  end;
  Result.Positions[Count] := X;
  if WrapWidth > 0 then
    Result.Rows := WrapRows(Result.Positions, BreakAfter, WrapWidth)
  else
    Result.Rows := SingleRow;
end;

function CharacterCountOfLayout(const Layout: TLineLayout): LongInt;
begin
  Result := Length(Layout.Bytes) - 1;
end;

function RowCountOfLayout(const Layout: TLineLayout): LongInt;
begin
  Result := Length(Layout.Rows);
end;

function RowEnd(const Layout: TLineLayout; Row: LongInt): LongInt;
begin
  if Row + 1 < Length(Layout.Rows) then
    Result := Layout.Rows[Row + 1]
  else
    Result := CharacterCountOfLayout(Layout);
end;

function RowCaretLimit(const Layout: TLineLayout; Row: LongInt): LongInt;
begin
  Result := RowEnd(Layout, Row);
  if Row + 1 < Length(Layout.Rows) then
    Result := Result - 1;
  if Result < Layout.Rows[Row] then
    Result := Layout.Rows[Row];
end;

function RowOfColumn(const Layout: TLineLayout; Column: LongInt): LongInt;
begin
  Result := Length(Layout.Rows) - 1;
  while (Result > 0) and (Layout.Rows[Result] > Column) do
    Dec(Result);
end;

function XInRow(const Layout: TLineLayout; Row, Column: LongInt): LongInt;
begin
  if Column > CharacterCountOfLayout(Layout) then
    Column := CharacterCountOfLayout(Layout);
  if Column < 0 then
    Column := 0;
  Result := Layout.Positions[Column] - Layout.Positions[Layout.Rows[Row]];
end;

function ColumnNearestX(const Layout: TLineLayout; Row, X: LongInt): LongInt;
var
  Column: LongInt;
  Limit: LongInt;
begin
  Limit := RowCaretLimit(Layout, Row);
  Column := ColumnAtX(Layout, Row, X);
  if Column > Limit then
    Column := Limit;
  { Past the middle of the character: after it. }
  if (Column < Limit) and (X >= (XInRow(Layout, Row, Column) + XInRow(Layout, Row, Column + 1)) div 2) then
    Inc(Column);
  Result := Column;
end;

function ColumnAtX(const Layout: TLineLayout; Row, X: LongInt): LongInt;
var
  Lower: LongInt;
  Upper: LongInt;
  Middle: LongInt;
begin
  { Positions only grow along a line: halved until one is left. }
  Lower := Layout.Rows[Row];
  Upper := RowEnd(Layout, Row);
  while Lower < Upper do
  begin
    Middle := (Lower + Upper + 1) div 2;
    if XInRow(Layout, Row, Middle) <= X then
      Lower := Middle
    else
      Upper := Middle - 1;
  end;
  Result := Lower;
end;

procedure DrawLayoutRange(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Layout: TLineLayout;
  Row, First, Last, RowLeft, Top: LongInt; Color: TColor);
var
  RunStart: LongInt;
  Column: LongInt;
  Piece: string;

  function IsTab(Index: LongInt): Boolean;
  begin
    Result := Text[Layout.Bytes[Index] + 1] = #9;
  end;

begin
  if Face = nil then
    Exit;
  { Runs between tabs, each drawn where its first character is. }
  Column := First;
  while Column < Last do
  begin
    while (Column < Last) and IsTab(Column) do
      Inc(Column);
    RunStart := Column;
    while (Column < Last) and not IsTab(Column) do
      Inc(Column);
    if Column > RunStart then
    begin
      Piece := Copy(Text, Layout.Bytes[RunStart] + 1, Layout.Bytes[Column] - Layout.Bytes[RunStart]);
      DrawText(Canvas, Face^, RowLeft + XInRow(Layout, Row, RunStart), Top, PChar(Piece), Color);
    end;
  end;
end;

end.
