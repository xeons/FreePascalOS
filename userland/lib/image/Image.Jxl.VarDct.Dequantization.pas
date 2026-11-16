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
  Dequantizing a JPEG XL varblock (ISO/IEC 18181-1 annex I.2.4): a
  quantized coefficient becomes a value (0 stays 0, +-1 become the
  channel's bias, larger ones are pulled towards 0 by bias / value),
  times the matrix entry and the block's step (the global scale over
  its quantization field, times the X and B matrix scales); X and B
  then get the Y value times the chroma-from-luma factors of the tile.
}
unit Image.Jxl.VarDct.Dequantization;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TJxlQuantBiases = array[0..3] of Single;

  TJxlBlockDequantization = record
    { The block's step: inverse global scale over its quantization field. }
    Step: Single;
    XMultiplier: Single;
    BMultiplier: Single;
    XFromY: Single;
    BFromY: Single;
  end;

{ Dequantizes Count coefficients of the three channels (QuantizedX/Y/B)
  into Output (X, Y, B one after the other, Count values each), with the
  matrices of X, Y and B. }
procedure DequantizeJxlBlock(const Parameters: TJxlBlockDequantization; const Biases: TJxlQuantBiases;
  QuantizedX, QuantizedY, QuantizedB: PLongInt; MatrixX, MatrixY, MatrixB: PSingle; Count: LongInt;
  Output: PSingle);

implementation

function AdjustQuantBias(Channel: LongInt; Quantized: LongInt; const Biases: TJxlQuantBiases): Single; inline;
var
  Value: Single;
begin
  if Quantized = 0 then
    Exit(0);
  if Quantized = 1 then
    Exit(Biases[Channel]);
  if Quantized = -1 then
    Exit(-Biases[Channel]);
  Value := Quantized;
  Result := Value - Biases[3] / Value;
end;

procedure DequantizeJxlBlock(const Parameters: TJxlBlockDequantization; const Biases: TJxlQuantBiases;
  QuantizedX, QuantizedY, QuantizedB: PLongInt; MatrixX, MatrixY, MatrixB: PSingle; Count: LongInt;
  Output: PSingle);
var
  StepX: Single;
  StepY: Single;
  StepB: Single;
  Index: LongInt;
  ValueX: Single;
  ValueY: Single;
  ValueB: Single;
begin
  StepX := Parameters.Step * Parameters.XMultiplier;
  StepY := Parameters.Step;
  StepB := Parameters.Step * Parameters.BMultiplier;
  for Index := 0 to Count - 1 do
  begin
    ValueX := AdjustQuantBias(0, QuantizedX[Index], Biases) * (MatrixX[Index] * StepX);
    ValueY := AdjustQuantBias(1, QuantizedY[Index], Biases) * (MatrixY[Index] * StepY);
    ValueB := AdjustQuantBias(2, QuantizedB[Index], Biases) * (MatrixB[Index] * StepB);
    Output[Index] := Parameters.XFromY * ValueY + ValueX;
    Output[Count + Index] := ValueY;
    Output[2 * Count + Index] := Parameters.BFromY * ValueY + ValueB;
  end;
end;

end.
