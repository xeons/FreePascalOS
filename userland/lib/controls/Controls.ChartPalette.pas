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
  The colours a chart gives its series (or a pie its slices) that have
  none of their own: eight hues, far apart and of a like weight, in an
  order where neighbours differ most (blue, orange, green, purple, red,
  teal, gold, pink), then round again.

  They are chosen for the background they are drawn on: on a light one
  as they are, on a dark one lightened so they stand out as well. Text
  over a colour (a percentage on a slice) is black or white, whichever
  reads better.
}
unit Controls.ChartPalette;

{$mode objfpc}

interface

uses
  Drawing.Colors;

const
  ChartPaletteSize = 8;

{ The palette's colour for Index (0 the first series), on Background. }
function ChartPaletteColor(Index: LongInt; Background: TColor): TColor;
{ Perceived brightness, 0 (black) to 255 (white). }
function ColorBrightness(Color: TColor): LongInt;
function IsDarkColor(Color: TColor): Boolean;
{ Black or white, for text on Fill. }
function ContrastingTextColor(Fill: TColor): TColor;

implementation

const
  BasePalette: array[0..ChartPaletteSize - 1] of TColor = (
    $FF2F6DB5,  { blue }
    $FFE07B26,  { orange }
    $FF3A9A4A,  { green }
    $FF8A3FB0,  { purple }
    $FFC8413B,  { red }
    $FF1F9A9A,  { teal }
    $FFC49A1C,  { gold }
    $FFD25C9E   { pink }
  );
  { How far towards white the colours go on a dark background. }
  DarkBackgroundLightening = 90;
  DarkThreshold = 110;

function ColorBrightness(Color: TColor): LongInt;
begin
  { The usual weights of red, green and blue (0.299, 0.587, 0.114). }
  Result := (299 * RedOf(Color) + 587 * GreenOf(Color) + 114 * BlueOf(Color)) div 1000;
end;

function IsDarkColor(Color: TColor): Boolean;
begin
  Result := ColorBrightness(Color) < DarkThreshold;
end;

function ChartPaletteColor(Index: LongInt; Background: TColor): TColor;
begin
  if Index < 0 then
    Index := 0;
  Result := BasePalette[Index mod ChartPaletteSize];
  if IsDarkColor(Background) then
    Result := MixColors(Result, $FFFFFFFF, DarkBackgroundLightening);
end;

function ContrastingTextColor(Fill: TColor): TColor;
begin
  if ColorBrightness(Fill) < 150 then
    Result := $FFFFFFFF
  else
    Result := $FF000000;
end;

end.
