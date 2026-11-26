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
  The reconstruct process of the AV1 specification (section 7.12.3):
  the coefficients of a transform block (the tile's Quant, in
  Quant[ i * tw + j ] order) are dequantized (with the quantizer matrix
  when the frame uses one), inverse transformed (Av1.InverseTransform)
  and added to the prediction in CurrFrame, flipped for the FLIPADST
  transform types.
}
unit Av1.Reconstruction;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.QuantizerMatrices, Av1.TileContext,
  Av1.InverseTransform, Av1.Picture;

{ reconstruct( plane, x, y, txSz ): the transform block of size TxSz whose
  top left sample is (StartX, StartY) of the plane. }
procedure Reconstruct(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer);

implementation

function QuantizerFromTable(BitDepth, QIndex: Integer; IsDc: Boolean): Integer; inline;
begin
  if IsDc then
    Result := Dc_Qlookup[(BitDepth - 8) shr 1, Clip3(0, 255, QIndex)]
  else
    Result := Ac_Qlookup[(BitDepth - 8) shr 1, Clip3(0, 255, QIndex)];
end;

{ get_dc_quant( plane ) and get_ac_quant( plane ). }
procedure GetQuantizers(Tile: TTileContext; Plane: Integer; out DcQuant, AcQuant: Integer);
var
  QIndex, BitDepth: Integer;
begin
  QIndex := Tile.GetQIndex(False, Tile.segment_id);
  BitDepth := Tile.Sequence^.BitDepth;
  case Plane of
    0:
      begin
        DcQuant := QuantizerFromTable(BitDepth, QIndex + Tile.Header^.DeltaQYDc, True);
        AcQuant := QuantizerFromTable(BitDepth, QIndex, False);
      end;
    1:
      begin
        DcQuant := QuantizerFromTable(BitDepth, QIndex + Tile.Header^.DeltaQUDc, True);
        AcQuant := QuantizerFromTable(BitDepth, QIndex + Tile.Header^.DeltaQUAc, False);
      end;
  else
    begin
      DcQuant := QuantizerFromTable(BitDepth, QIndex + Tile.Header^.DeltaQVDc, True);
      AcQuant := QuantizerFromTable(BitDepth, QIndex + Tile.Header^.DeltaQVAc, False);
    end;
  end;
end;

function DequantizationDenominator(TxSz: Integer): Integer; inline;
begin
  case TxSz of
    TX_32X32, TX_16X32, TX_32X16, TX_16X64, TX_64X16:
      Result := 2;
    TX_64X64, TX_32X64, TX_64X32:
      Result := 4;
  else
    Result := 1;
  end;
end;

procedure Dequantize(Tile: TTileContext; Plane, TxSz, CoefficientWidth, CoefficientHeight: Integer);
var
  DcQuant, AcQuant, Quantizer, QmLevel, Denominator, BitDepth: Integer;
  Low, High, I, J, Index, Coefficient: Integer;
  UseMatrix: Boolean;
  Product, Magnitude: Int64;
  MatrixRow: PByte;
begin
  GetQuantizers(Tile, Plane, DcQuant, AcQuant);
  BitDepth := Tile.Sequence^.BitDepth;
  Denominator := DequantizationDenominator(TxSz);
  QmLevel := 15;
  UseMatrix := False;
  if Tile.Header^.using_qmatrix and (Tile.PlaneTxType < IDTX) then
  begin
    QmLevel := Tile.Header^.SegQMLevel[Plane, Tile.segment_id];
    UseMatrix := QmLevel < 15;
  end;
  MatrixRow := nil;
  if UseMatrix then
    MatrixRow := @Quantizer_Matrix[QmLevel, Ord(Plane > 0), Qm_Offset[TxSz]];
  Low := -(1 shl (7 + BitDepth));
  High := (1 shl (7 + BitDepth)) - 1;
  for I := 0 to CoefficientHeight - 1 do
    for J := 0 to CoefficientWidth - 1 do
    begin
      Index := I * CoefficientWidth + J;
      Coefficient := Tile.Quant[Index];
      if Coefficient = 0 then
      begin
        Tile.ReconstructionDequant[Index] := 0;
        Continue;
      end;
      if Index = 0 then
        Quantizer := DcQuant
      else
        Quantizer := AcQuant;
      if UseMatrix then
        Quantizer := Round2(Quantizer * Integer(MatrixRow[Index]), 5);
      Product := Int64(Coefficient) * Quantizer;
      Magnitude := (Abs(Product) and $FFFFFF) div Denominator;
      if Product < 0 then
        Magnitude := -Magnitude;
      if Magnitude < Low then
        Magnitude := Low
      else if Magnitude > High then
        Magnitude := High;
      Tile.ReconstructionDequant[Index] := Integer(Magnitude);
    end;
end;

procedure Reconstruct(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer);
var
  Log2W, Log2H, Width, Height, CoefficientWidth, CoefficientHeight: Integer;
  FlipUpDown, FlipLeftRight: Boolean;
  I, J, X, Y, Value, MaxValue, Stride: Integer;
  Target: PPlane;
  Residual: PInteger;
  RowStart: PWord;
begin
  Log2W := Tx_Width_Log2[TxSz];
  Log2H := Tx_Height_Log2[TxSz];
  Width := 1 shl Log2W;
  Height := 1 shl Log2H;
  CoefficientWidth := Min(32, Width);
  CoefficientHeight := Min(32, Height);
  case Tile.PlaneTxType of
    FLIPADST_DCT, FLIPADST_ADST, V_FLIPADST, FLIPADST_FLIPADST: FlipUpDown := True;
  else
    FlipUpDown := False;
  end;
  case Tile.PlaneTxType of
    DCT_FLIPADST, ADST_FLIPADST, H_FLIPADST, FLIPADST_FLIPADST: FlipLeftRight := True;
  else
    FlipLeftRight := False;
  end;

  Dequantize(Tile, Plane, TxSz, CoefficientWidth, CoefficientHeight);
  InverseTransform2D(@Tile.ReconstructionDequant[0], CoefficientWidth, @Tile.ReconstructionResidual[0],
    TxSz, Tile.PlaneTxType, Tile.Sequence^.BitDepth, Tile.Lossless);

  Target := @Tile.Frame.CurrFrame.Planes[Plane];
  Stride := Target^.Stride;
  MaxValue := (1 shl Tile.Sequence^.BitDepth) - 1;
  Residual := @Tile.ReconstructionResidual[0];
  for I := 0 to Height - 1 do
  begin
    if FlipUpDown then
      Y := Height - I - 1
    else
      Y := I;
    RowStart := @Target^.Samples[(StartY + Y) * Stride + StartX];
    for J := 0 to Width - 1 do
    begin
      if FlipLeftRight then
        X := Width - J - 1
      else
        X := J;
      Value := RowStart[X] + Residual[I * Width + J];
      if Value < 0 then
        Value := 0
      else if Value > MaxValue then
        Value := MaxValue;
      RowStart[X] := Value;
    end;
  end;
end;

end.
