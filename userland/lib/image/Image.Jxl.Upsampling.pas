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
  JPEG XL's non-separable upsampling (ISO/IEC 18181-1 annex K.2): a
  frame coded at half, a quarter or an eighth of its size is enlarged
  by 2, 4 or 8, each output sample a weighted sum of the 5 x 5 input
  samples around its source (weights from the custom transform data,
  mirrored into the four quadrants), clamped to the range of those 25
  samples. Borders are mirrored, as libjxl's render pipeline does.
}
unit Image.Jxl.Upsampling;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.Headers,
  Image.Jxl.Planes;

{ Plane enlarged Factor times (2, 4 or 8) and cropped to Width x
  Height; the result is a new plane. }
function UpsampleJxlPlane(Plane: TJxlPlane; Factor: LongInt; const Transform: TJxlTransformData;
  Width, Height: LongInt): TJxlPlane;

implementation

type
  TKernel = array[0..64 * 25 - 1] of Single;

procedure BuildKernel(Factor: LongInt; const Transform: TJxlTransformData; out Kernel: TKernel);
var
  Half: LongInt;
  KernelY: LongInt;
  KernelX: LongInt;
  PositionY: LongInt;
  PositionX: LongInt;
  Offset0: LongInt;
  Offset1: LongInt;
  Offset2: LongInt;
  Offset3: LongInt;
  I: LongInt;
  J: LongInt;
  Low: LongInt;
  High: LongInt;
  Weight: Single;
  WeightIndex: LongInt;
begin
  FillChar(Kernel, SizeOf(Kernel), 0);
  Half := Factor div 2;
  for KernelY := 0 to Half - 1 do
    for KernelX := 0 to Half - 1 do
    begin
      Offset0 := (KernelY * Factor + KernelX) * 25;
      Offset1 := (KernelY * Factor + (Factor - 1 - KernelX)) * 25;
      Offset2 := ((Factor - 1 - KernelY) * Factor + KernelX) * 25;
      Offset3 := ((Factor - 1 - KernelY) * Factor + (Factor - 1 - KernelX)) * 25;
      for PositionY := 0 to 4 do
        for PositionX := 0 to 4 do
        begin
          J := 5 * KernelY + PositionY;
          I := 5 * KernelX + PositionX;
          if I < J then
          begin
            Low := I;
            High := J;
          end
          else
          begin
            Low := J;
            High := I;
          end;
          WeightIndex := 5 * Half * Low - Low * (Low - 1) div 2 + High - Low;
          case Factor of
            2: Weight := Transform.Upsampling2Weights[WeightIndex];
            4: Weight := Transform.Upsampling4Weights[WeightIndex];
          else
            Weight := Transform.Upsampling8Weights[WeightIndex];
          end;
          Kernel[Offset0 + PositionY * 5 + PositionX] := Weight;
          Kernel[Offset1 + PositionY * 5 + (4 - PositionX)] := Weight;
          Kernel[Offset2 + (4 - PositionY) * 5 + PositionX] := Weight;
          Kernel[Offset3 + (4 - PositionY) * 5 + (4 - PositionX)] := Weight;
        end;
    end;
end;

function UpsampleJxlPlane(Plane: TJxlPlane; Factor: LongInt; const Transform: TJxlTransformData;
  Width, Height: LongInt): TJxlPlane;
var
  Kernel: TKernel;
  Window: array[0..24] of Single;
  X: LongInt;
  Y: LongInt;
  OutputX: LongInt;
  OutputY: LongInt;
  TargetX: LongInt;
  TargetY: LongInt;
  Index: LongInt;
  Lowest: Single;
  Highest: Single;
  Sum: Single;
  KernelIndex: LongInt;
  Columns: array of LongInt;
  Rows: array[0..4] of PSingle;
begin
  BuildKernel(Factor, Transform, Kernel);
  Result := TJxlPlane.Create(Width, Height);
  SetLength(Columns, Plane.Width + 4);
  for X := 0 to Plane.Width + 3 do
    Columns[X] := JxlMirror(X - 2, Plane.Width);
  for Y := 0 to Plane.Height - 1 do
  begin
    if Y * Factor >= Height then
      Break;
    for Index := 0 to 4 do
      Rows[Index] := Plane.Row(JxlMirror(Y + Index - 2, Plane.Height));
    for X := 0 to Plane.Width - 1 do
    begin
      if X * Factor >= Width then
        Break;
      for Index := 0 to 24 do
        Window[Index] := Rows[Index div 5][Columns[X + Index mod 5]];
      Lowest := Window[0];
      Highest := Window[0];
      for Index := 1 to 24 do
      begin
        if Window[Index] < Lowest then
          Lowest := Window[Index];
        if Window[Index] > Highest then
          Highest := Window[Index];
      end;
      for OutputY := 0 to Factor - 1 do
      begin
        TargetY := Y * Factor + OutputY;
        if TargetY >= Height then
          Break;
        for OutputX := 0 to Factor - 1 do
        begin
          TargetX := X * Factor + OutputX;
          if TargetX >= Width then
            Break;
          KernelIndex := (Factor * OutputY + OutputX) * 25;
          Sum := 0;
          for Index := 0 to 24 do
            Sum := Sum + Window[Index] * Kernel[KernelIndex + Index];
          if Sum < Lowest then
            Sum := Lowest;
          if Sum > Highest then
            Sum := Highest;
          Result.Row(TargetY)[TargetX] := Sum;
        end;
      end;
    end;
  end;
end;

end.
