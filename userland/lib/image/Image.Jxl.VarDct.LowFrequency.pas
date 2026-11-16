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
  The LF (DC) image of a JPEG XL VarDCT frame (ISO/IEC 18181-1 annex
  I.2.1 and I.2.3): one sample per 8 x 8 block and channel, decoded in
  LF groups as a modular image of quantized values, scaled by the LF
  steps (with extra precision bits), the X and B channels corrected by
  the Y channel times the LF chroma-from-luma factors; then, unless the
  frame says otherwise, smoothed adaptively: each sample moves towards
  a 3 x 3 weighted average as far as the quantization step allows.
}
unit Image.Jxl.VarDct.LowFrequency;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.Planes;

{ Smooths the three LF planes (of one size) in place; Steps are the LF
  quantization steps of X, Y and B. }
procedure SmoothJxlLowFrequency(const Planes: array of TJxlPlane; const Steps: array of Single);

implementation

const
  SideWeight = 0.20345139757231578;
  CornerWeight = 0.0334829185968739;
  CenterWeight = 1.0 - 4.0 * (SideWeight + CornerWeight);

procedure SmoothJxlLowFrequency(const Planes: array of TJxlPlane; const Steps: array of Single);
var
  Width: LongInt;
  Height: LongInt;
  Smoothed: array[0..2] of TJxlPlane;
  Channel: LongInt;
  X: LongInt;
  Y: LongInt;
  Top: PSingle;
  Middle: PSingle;
  Bottom: PSingle;
  Centers: array[0..2] of Single;
  Averages: array[0..2] of Single;
  Gap: Single;
  Factor: Single;
  Corner: Single;
  Side: Single;
  Difference: Single;
begin
  Width := Planes[0].Width;
  Height := Planes[0].Height;
  if (Height <= 2) or (Width <= 2) then
    Exit;
  for Channel := 0 to 2 do
    Smoothed[Channel] := Planes[Channel].Clone;
  try
    for Y := 1 to Height - 2 do
      for X := 1 to Width - 2 do
      begin
        Gap := 0.5;
        for Channel := 0 to 2 do
        begin
          Top := Planes[Channel].Row(Y - 1);
          Middle := Planes[Channel].Row(Y);
          Bottom := Planes[Channel].Row(Y + 1);
          Corner := (Top[X - 1] + Top[X + 1]) + (Bottom[X - 1] + Bottom[X + 1]);
          Side := (Middle[X - 1] + Middle[X + 1]) + (Top[X] + Bottom[X]);
          Centers[Channel] := Middle[X];
          Averages[Channel] := Corner * CornerWeight + (Side * SideWeight + Middle[X] * CenterWeight);
          Difference := Abs((Centers[Channel] - Averages[Channel]) / Steps[Channel]);
          if Difference > Gap then
            Gap := Difference;
        end;
        Factor := 3.0 - 4.0 * Gap;
        if Factor < 0 then
          Factor := 0;
        for Channel := 0 to 2 do
          Smoothed[Channel].Row(Y)[X] := (Averages[Channel] - Centers[Channel]) * Factor + Centers[Channel];
      end;
    for Channel := 0 to 2 do
      Planes[Channel].Samples := Smoothed[Channel].Samples;
  finally
    for Channel := 0 to 2 do
      Smoothed[Channel].Free;
  end;
end;

end.
