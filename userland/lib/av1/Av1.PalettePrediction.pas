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
  The palette prediction process (specification section 7.11.4): a
  transform block of a palette coded block takes the colours its colour
  index map names.
}
unit Av1.PalettePrediction;

{$mode objfpc}

interface

uses
  Av1.TileContext;

{ predict_palette( plane, startX, startY, x, y, txSz ). }
procedure PredictPalette(Tile: TTileContext; Plane, StartX, StartY, X, Y, TxSz: Integer);

implementation

uses
  Av1.Tables, Av1.Picture;

procedure PredictPalette(Tile: TTileContext; Plane, StartX, StartY, X, Y, TxSz: Integer);
var
  W, H, Row, Col, Stride: Integer;
  Palette: ^TPaletteColors;
  Map: ^TColorMap;
  PlaneInfo: PPlane;
  Line: PWord;
begin
  W := Tx_Width[TxSz];
  H := Tx_Height[TxSz];
  if Plane = 0 then
    Palette := @Tile.palette_colors_y
  else if Plane = 1 then
    Palette := @Tile.palette_colors_u
  else
    Palette := @Tile.palette_colors_v;
  if Plane = 0 then
    Map := @Tile.ColorMapY
  else
    Map := @Tile.ColorMapUV;
  PlaneInfo := @Tile.Frame.CurrFrame.Planes[Plane];
  Stride := PlaneInfo^.Stride;
  for Row := 0 to H - 1 do
  begin
    Line := @PlaneInfo^.Samples[(StartY + Row) * Stride + StartX];
    for Col := 0 to W - 1 do
      Line[Col] := Palette^[Map^[Y * 4 + Row, X * 4 + Col]];
  end;
end;

end.
