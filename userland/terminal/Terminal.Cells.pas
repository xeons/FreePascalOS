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
  A character cell of the terminal: the character and how it is drawn.

  Colours are numbers into the terminal's palette of sixteen (the eight
  ANSI colours and their bright forms), or ColorDefault for the
  terminal's own text and background colours; a cell also has bold,
  underline and reverse (text and background swapped). Bold text in one
  of the eight plain colours is drawn in its bright form, as terminals
  usually do.
}
unit Terminal.Cells;

{$mode objfpc}

interface

uses
  Drawing.Colors;

const
  { Not a palette entry: the terminal's own text or background colour. }
  ColorDefault = 255;
  PaletteSize = 16;
  { The bright form of colour N is N + BrightOffset. }
  BrightOffset = 8;

  AttributeBold = $01;
  AttributeUnderline = $02;
  AttributeReverse = $04;

  DefaultTextColor: TColor = $FFD0D0D0;
  DefaultBackgroundColor: TColor = $FF101010;

type
  TCell = record
    { A Unicode code point; a space for an empty cell. }
    CodePoint: LongWord;
    Foreground: Byte;
    Background: Byte;
    Attributes: Byte;
  end;
  PCell = ^TCell;
  TCellLine = array of TCell;

{ An empty cell in the colours of Pen (its character is ignored). }
function BlankCell(const Pen: TCell): TCell;
{ The default pen: default colours, no attributes. }
function DefaultPen: TCell;
{ The colours Cell is drawn in, reverse and bold taken into account. }
procedure CellColors(const Cell: TCell; out Text, Background: TColor);

implementation

const
  Palette: array[0..PaletteSize - 1] of TColor = (
    $FF000000, $FFCD3131, $FF0DBC79, $FFE5E510, $FF2472C8, $FFBC3FBC, $FF11A8CD, $FFE5E5E5,
    $FF666666, $FFF14C4C, $FF23D18B, $FFF5F543, $FF3B8EEA, $FFD670D6, $FF29B8DB, $FFFFFFFF);

function BlankCell(const Pen: TCell): TCell;
begin
  Result.CodePoint := 32;
  Result.Foreground := Pen.Foreground;
  Result.Background := Pen.Background;
  Result.Attributes := 0;
end;

function DefaultPen: TCell;
begin
  Result.CodePoint := 32;
  Result.Foreground := ColorDefault;
  Result.Background := ColorDefault;
  Result.Attributes := 0;
end;

function PaletteColor(Index: Byte; Fallback: TColor): TColor;
begin
  if Index < PaletteSize then
    Result := Palette[Index]
  else
    Result := Fallback;
end;

procedure CellColors(const Cell: TCell; out Text, Background: TColor);
var
  Foreground: Byte;
  Swapped: TColor;
begin
  Foreground := Cell.Foreground;
  if ((Cell.Attributes and AttributeBold) <> 0) and (Foreground < BrightOffset) then
    Foreground := Foreground + BrightOffset;
  Text := PaletteColor(Foreground, DefaultTextColor);
  Background := PaletteColor(Cell.Background, DefaultBackgroundColor);
  if (Cell.Attributes and AttributeReverse) <> 0 then
  begin
    Swapped := Text;
    Text := Background;
    Background := Swapped;
  end;
end;

end.
