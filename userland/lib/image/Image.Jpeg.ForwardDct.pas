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
  The forward DCT of an 8 x 8 block for the encoder, quantized.

  The transform is done by its definition, rows then columns, in
  floating point with the cosines worked out once: 2 x 8 x 64
  multiplications a block, exact to rounding, quick enough for an
  encoder that is not the hot path. Each coefficient is then divided
  by its quantization value and rounded to nearest.
}
unit Image.Jpeg.ForwardDct;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.Jpeg.Frames;

{ Samples: 64 values (row by row) already less 128. Output: the
  quantized coefficients in natural order. }
procedure ForwardDctBlock(Samples: PLongInt; constref Quantization: TJpegQuantizationTable; Output: PLongInt);

implementation

var
  { CosineTable[Frequency * 8 + Position]: C(u)/2 cos((2x + 1) u pi / 16). }
  CosineTable: array[0..63] of Double;
  CosineTableReady: Boolean = False;

procedure PrepareCosines;
var
  Frequency: LongInt;
  Position: LongInt;
  Factor: Double;
begin
  for Frequency := 0 to 7 do
  begin
    if Frequency = 0 then
      Factor := Sqrt(0.5) / 2
    else
      Factor := 0.5;
    for Position := 0 to 7 do
      CosineTable[Frequency * 8 + Position] := Factor * Cos((2 * Position + 1) * Frequency * Pi / 16);
  end;
  CosineTableReady := True;
end;

procedure ForwardDctBlock(Samples: PLongInt; constref Quantization: TJpegQuantizationTable; Output: PLongInt);
var
  Rows: array[0..63] of Double;
  Row: LongInt;
  Column: LongInt;
  Frequency: LongInt;
  Position: LongInt;
  Sum: Double;
begin
  if not CosineTableReady then
    PrepareCosines;
  for Row := 0 to 7 do
    for Frequency := 0 to 7 do
    begin
      Sum := 0;
      for Position := 0 to 7 do
        Sum := Sum + Samples[Row * 8 + Position] * CosineTable[Frequency * 8 + Position];
      Rows[Row * 8 + Frequency] := Sum;
    end;
  for Column := 0 to 7 do
    for Frequency := 0 to 7 do
    begin
      Sum := 0;
      for Position := 0 to 7 do
        Sum := Sum + Rows[Position * 8 + Column] * CosineTable[Frequency * 8 + Position];
      Output[Frequency * 8 + Column] := Round(Sum / Quantization[Frequency * 8 + Column]);
    end;
end;

end.
