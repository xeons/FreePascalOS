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
  Word wrap: where a line of text breaks into rows that fit a width.

  A row breaks after the last space that still fits, so words stay
  whole; a word wider than the whole width is broken where it stops
  fitting. Spaces at the end of a row may go past the width (they are
  not seen), so a row never starts with the spaces that ended the one
  before. Every row holds at least one character, so a width too narrow
  for anything still makes progress.

  Plain logic, checked on the host: the caller measures the characters.
}
unit Controls.TextWrap;

{$mode objfpc}
{$H+}

interface

type
  { Pixels from the line's start to where each character starts, and one
    more entry: where the last one ends. }
  TCharacterPositions = array of LongInt;
  { Which characters a row may break after (spaces and tabs). }
  TBreakFlags = array of Boolean;
  { The character each row starts at; the first row starts at 0. }
  TRowStarts = array of LongInt;

function WrapRows(const Positions: TCharacterPositions; const BreakAfter: TBreakFlags;
  Width: LongInt): TRowStarts;
{ No wrapping: the whole line is one row. }
function SingleRow: TRowStarts;

implementation

function SingleRow: TRowStarts;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 0;
end;

function WrapRows(const Positions: TCharacterPositions; const BreakAfter: TBreakFlags;
  Width: LongInt): TRowStarts;
var
  Count: LongInt;
  RowCount: LongInt;
  RowStart: LongInt;
  BreakColumn: LongInt;
  Column: LongInt;
  TooWide: Boolean;
begin
  Count := Length(Positions) - 1;
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 0;
  RowCount := 1;
  if Width < 1 then
    Width := 1;
  RowStart := 0;
  { Where the row could break (after a space); RowStart while none. }
  BreakColumn := 0;
  Column := 0;
  while Column < Count do
  begin
    TooWide := Positions[Column + 1] - Positions[RowStart] > Width;
    if TooWide and (Column > RowStart) and not BreakAfter[Column] then
    begin
      if BreakColumn > RowStart then
        RowStart := BreakColumn
      else
        RowStart := Column;
      if RowCount = Length(Result) then
        SetLength(Result, RowCount * 2);
      Result[RowCount] := RowStart;
      Inc(RowCount);
      BreakColumn := RowStart;
      { Column is looked at again, in the new row. }
      Continue;
    end;
    if BreakAfter[Column] then
      BreakColumn := Column + 1;
    Inc(Column);
  end;
  SetLength(Result, RowCount);
end;

end.
