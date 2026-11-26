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
  The predict chroma from luma process (specification section 7.11.5):
  the DC predicted chroma block gets the reconstructed luma's variation,
  scaled by CflAlphaU or CflAlphaV.
}
unit Av1.ChromaFromLuma;

{$mode objfpc}

interface

uses
  Av1.TileContext;

{ predict_chroma_from_luma( plane, startX, startY, txSz ). }
procedure PredictChromaFromLuma(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer);

implementation

uses
  Av1.Common, Av1.Tables, Av1.Picture;

procedure PredictChromaFromLuma(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer);
var
  W, H, SubX, SubY, Alpha, LumaAverage, Row, Col, LumaX, LumaY, Total, Value: Integer;
  LumaStride, ChromaStride, MaxValue: Integer;
  LumaPlane, ChromaPlane: PPlane;
  LumaLine, Line: PWord;
begin
  W := Tx_Width[TxSz];
  H := Tx_Height[TxSz];
  SubX := Tile.Sequence^.subsampling_x;
  SubY := Tile.Sequence^.subsampling_y;
  if Plane = 1 then
    Alpha := Tile.CflAlphaU
  else
    Alpha := Tile.CflAlphaV;
  LumaPlane := @Tile.Frame.CurrFrame.Planes[0];
  LumaStride := LumaPlane^.Stride;
  LumaAverage := 0;
  for Row := 0 to H - 1 do
  begin
    LumaY := Min((StartY + Row) shl SubY, Tile.MaxLumaH - (1 shl SubY));
    LumaLine := @LumaPlane^.Samples[LumaY * LumaStride];
    for Col := 0 to W - 1 do
    begin
      LumaX := Min((StartX + Col) shl SubX, Tile.MaxLumaW - (1 shl SubX));
      Total := LumaLine[LumaX];
      if SubX <> 0 then
        Inc(Total, LumaLine[LumaX + 1]);
      if SubY <> 0 then
      begin
        Inc(Total, LumaLine[LumaStride + LumaX]);
        if SubX <> 0 then
          Inc(Total, LumaLine[LumaStride + LumaX + 1]);
      end;
      Value := Total shl (3 - SubX - SubY);
      Tile.CflLuma[Row * W + Col] := Value;
      Inc(LumaAverage, Value);
    end;
  end;
  LumaAverage := Round2(LumaAverage, Tx_Width_Log2[TxSz] + Tx_Height_Log2[TxSz]);

  ChromaPlane := @Tile.Frame.CurrFrame.Planes[Plane];
  ChromaStride := ChromaPlane^.Stride;
  MaxValue := (1 shl Tile.Sequence^.BitDepth) - 1;
  for Row := 0 to H - 1 do
  begin
    Line := @ChromaPlane^.Samples[(StartY + Row) * ChromaStride + StartX];
    for Col := 0 to W - 1 do
      Line[Col] := Clip3(0, MaxValue, Line[Col] +
        Round2Signed(Alpha * (Tile.CflLuma[Row * W + Col] - LumaAverage), 6));
  end;
end;

end.
