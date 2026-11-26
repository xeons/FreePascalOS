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
  Y'CbCr to BGRA conversion for Media.Frames.ConvertFrameToBgra.

  The matrix (Kr, Kb of the H.273 matrix coefficients) and the range
  become integer coefficients with 16 fraction bits, scaled for the
  frame's bit depth, so each pixel is a few multiplications and a clamp:

    R = Y' + 2(1 - Kr) Cr
    G = Y' - 2 Kb (1 - Kb) / Kg Cb - 2 Kr (1 - Kr) / Kg Cr
    B = Y' + 2(1 - Kb) Cb

  Limited range has black at 16 and white at 235 (chroma 16 to 240),
  scaled by 2^(BitDepth - 8); full range spans 0 to 2^BitDepth - 1.
  Chroma is upsampled by repeating each sample (4:2:0 and 4:2:2). The
  identity matrix (0) is G, B, R in the Y, U, V planes.
}
unit Media.ColorConversion;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Frames;

type
  TYuvCoefficients = record
    LumaOffset, ChromaOffset: Integer;
    LumaScale: Integer;
    RedFromCr, GreenFromCb, GreenFromCr, BlueFromCb: Integer;
    Identity: Boolean;
    { Down-shift from BitDepth to 8 bits for the identity matrix. }
    IdentityShift: Integer;
  end;

{ The coefficients for Frame's matrix, range and depth. }
function YuvCoefficientsOf(const Frame: TVideoFrame): TYuvCoefficients;
procedure ConvertYuvFrameToBgra(const Frame: TVideoFrame; Target: PByte; TargetStride: Integer);

implementation

const
  FractionBits = 16;
  RoundingHalf = 1 shl (FractionBits - 1);

procedure MatrixConstants(Matrix, Height: Integer; out Kr, Kb: Double);
begin
  case Matrix of
    MatrixBt709:
      begin
        Kr := 0.2126;
        Kb := 0.0722;
      end;
    MatrixFcc:
      begin
        Kr := 0.30;
        Kb := 0.11;
      end;
    MatrixBt470bg, MatrixSmpte170m:
      begin
        Kr := 0.299;
        Kb := 0.114;
      end;
    MatrixSmpte240m:
      begin
        Kr := 0.212;
        Kb := 0.087;
      end;
    MatrixBt2020NonConstant, MatrixBt2020Constant:
      begin
        Kr := 0.2627;
        Kb := 0.0593;
      end;
  else
    if Height > 576 then
    begin
      Kr := 0.2126;
      Kb := 0.0722;
    end
    else
    begin
      Kr := 0.299;
      Kb := 0.114;
    end;
  end;
end;

function YuvCoefficientsOf(const Frame: TVideoFrame): TYuvCoefficients;
var
  Kr, Kb, Kg: Double;
  DepthScale, LumaRange, ChromaRange: Double;
  BitDepth: Integer;
begin
  Result := Default(TYuvCoefficients);
  BitDepth := Frame.BitDepth;
  if BitDepth < 8 then
    BitDepth := 8;
  Result.IdentityShift := BitDepth - 8;
  Result.Identity := Frame.MatrixCoefficients = MatrixIdentity;
  MatrixConstants(Frame.MatrixCoefficients, Frame.Height, Kr, Kb);
  Kg := 1 - Kr - Kb;
  DepthScale := 1 shl (BitDepth - 8);
  Result.ChromaOffset := 128 shl (BitDepth - 8);
  if Frame.FullRange then
  begin
    Result.LumaOffset := 0;
    LumaRange := (1 shl BitDepth) - 1;
    ChromaRange := LumaRange;
  end
  else
  begin
    Result.LumaOffset := 16 shl (BitDepth - 8);
    LumaRange := 219 * DepthScale;
    ChromaRange := 224 * DepthScale;
  end;
  { Output is 0..255 with FractionBits of fraction. }
  Result.LumaScale := Round(255 / LumaRange * (1 shl FractionBits));
  Result.RedFromCr := Round(2 * (1 - Kr) * 255 / ChromaRange * (1 shl FractionBits));
  Result.BlueFromCb := Round(2 * (1 - Kb) * 255 / ChromaRange * (1 shl FractionBits));
  Result.GreenFromCb := Round(2 * Kb * (1 - Kb) / Kg * 255 / ChromaRange * (1 shl FractionBits));
  Result.GreenFromCr := Round(2 * Kr * (1 - Kr) / Kg * 255 / ChromaRange * (1 shl FractionBits));
end;

function ClampToByte(Value: Integer): Byte; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

function SampleAt(Row: PByte; X: Integer; Wide: Boolean): Integer; inline;
begin
  if Wide then
    Result := Row[X * 2] or (Row[X * 2 + 1] shl 8)
  else
    Result := Row[X];
end;

procedure ConvertRow(const Coefficients: TYuvCoefficients; LumaRow, CbRow, CrRow: PByte; Width, ChromaShiftX: Integer;
  Wide, Monochrome: Boolean; Pixel: PByte);
var
  X, Luma, Cb, Cr, ChromaX, Red, Green, Blue: Integer;
begin
  for X := 0 to Width - 1 do
  begin
    Luma := SampleAt(LumaRow, X, Wide);
    if Monochrome then
    begin
      Cb := Coefficients.ChromaOffset;
      Cr := Cb;
    end
    else
    begin
      ChromaX := X shr ChromaShiftX;
      Cb := SampleAt(CbRow, ChromaX, Wide);
      Cr := SampleAt(CrRow, ChromaX, Wide);
    end;
    if Coefficients.Identity then
    begin
      Green := Luma shr Coefficients.IdentityShift;
      Blue := Cb shr Coefficients.IdentityShift;
      Red := Cr shr Coefficients.IdentityShift;
    end
    else
    begin
      Luma := (Luma - Coefficients.LumaOffset) * Coefficients.LumaScale + RoundingHalf;
      Cb := Cb - Coefficients.ChromaOffset;
      Cr := Cr - Coefficients.ChromaOffset;
      Red := SarLongint(Luma + Cr * Coefficients.RedFromCr, FractionBits);
      Green := SarLongint(Luma - Cb * Coefficients.GreenFromCb - Cr * Coefficients.GreenFromCr, FractionBits);
      Blue := SarLongint(Luma + Cb * Coefficients.BlueFromCb, FractionBits);
    end;
    Pixel[0] := ClampToByte(Blue);
    Pixel[1] := ClampToByte(Green);
    Pixel[2] := ClampToByte(Red);
    Pixel[3] := 255;
    Inc(Pixel, 4);
  end;
end;

procedure ConvertYuvFrameToBgra(const Frame: TVideoFrame; Target: PByte; TargetStride: Integer);
var
  Coefficients: TYuvCoefficients;
  Y, ChromaY, ChromaShiftX, ChromaShiftY, Width, Height: Integer;
  Wide, Monochrome: Boolean;
  LumaRow, CbRow, CrRow: PByte;
begin
  Width := Frame.Width;
  Height := Frame.Height;
  if (Width <= 0) or (Height <= 0) or (Length(Frame.Planes[0].Data) = 0) then
    Exit;
  if Width > Frame.Planes[0].Width then
    Width := Frame.Planes[0].Width;
  if Height > Frame.Planes[0].Height then
    Height := Frame.Planes[0].Height;
  Coefficients := YuvCoefficientsOf(Frame);
  Wide := Frame.BitDepth > 8;
  Monochrome := (Frame.Layout = plMonochrome) or (Length(Frame.Planes[1].Data) = 0)
    or (Length(Frame.Planes[2].Data) = 0);
  ChromaShiftX := 0;
  ChromaShiftY := 0;
  case Frame.Layout of
    pl420:
      begin
        ChromaShiftX := 1;
        ChromaShiftY := 1;
      end;
    pl422:
      ChromaShiftX := 1;
  end;
  CbRow := nil;
  CrRow := nil;
  for Y := 0 to Height - 1 do
  begin
    LumaRow := @Frame.Planes[0].Data[Y * Frame.Planes[0].Stride];
    if not Monochrome then
    begin
      ChromaY := Y shr ChromaShiftY;
      if ChromaY >= Frame.Planes[1].Height then
        ChromaY := Frame.Planes[1].Height - 1;
      CbRow := @Frame.Planes[1].Data[ChromaY * Frame.Planes[1].Stride];
      CrRow := @Frame.Planes[2].Data[ChromaY * Frame.Planes[2].Stride];
    end;
    ConvertRow(Coefficients, LumaRow, CbRow, CrRow, Width, ChromaShiftX, Wide, Monochrome,
      Target + PtrInt(Y) * TargetStride);
  end;
end;

end.
