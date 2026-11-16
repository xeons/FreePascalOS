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
  Resampling with a filter kernel, for thumbnails and enlargements of
  good quality:

    ResamplingBox        the nearest source pixels averaged (support 0.5)
    ResamplingTriangle   bilinear (support 1)
    ResamplingMitchell   Mitchell-Netravali cubic, B = C = 1/3 (support 2):
                         smooth, hardly any ringing
    ResamplingLanczos3   windowed sinc over three lobes (support 3):
                         the sharpest, a little ringing at hard edges

  Two separable passes, across then down, as Pillow does it: output
  pixel i takes the source around its centre (i + 0.5) x scale, the
  kernel stretched by the scale when shrinking (so every source pixel
  counts), its weights normalised to 1. Colours are premultiplied by
  alpha for the passes, so transparent pixels lend no colour to their
  neighbours (no dark fringes), and divided out at the end; the passes
  work in single precision floating point. Results are clamped, so the
  overshoot of the cubic and sinc kernels never wraps.
}
unit Image.Resampling;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model;

type
  TResamplingFilter = (ResamplingBox, ResamplingTriangle, ResamplingMitchell, ResamplingLanczos3);

{ A new image of NewWidth x NewHeight (properties copied from Image). }
function ResampleImage(Image: TImage; NewWidth, NewHeight: LongInt; Filter: TResamplingFilter): TImage;
{ The kernel at X and its support (for tests). }
function ResamplingKernel(Filter: TResamplingFilter; X: Double): Double;
function ResamplingSupport(Filter: TResamplingFilter): Double;

implementation

uses
  Math;

type
  { The source pixels one output pixel takes, and their weights. }
  TContribution = record
    First: LongInt;
    Weights: array of Single;
  end;

  TContributions = array of TContribution;

  TPremultipliedPixel = record
    Blue: Single;
    Green: Single;
    Red: Single;
    Alpha: Single;
  end;

  PPremultipliedPixel = ^TPremultipliedPixel;

function Sinc(X: Double): Double;
begin
  if Abs(X) < 1e-9 then
    Result := 1
  else
    Result := Sin(Pi * X) / (Pi * X);
end;

function ResamplingSupport(Filter: TResamplingFilter): Double;
begin
  case Filter of
    ResamplingBox: Result := 0.5;
    ResamplingTriangle: Result := 1;
    ResamplingMitchell: Result := 2;
  else
    Result := 3;
  end;
end;

function MitchellKernel(X: Double): Double;
const
  B = 1.0 / 3.0;
  C = 1.0 / 3.0;
begin
  X := Abs(X);
  if X < 1 then
    Result := ((12 - 9 * B - 6 * C) * X * X * X + (-18 + 12 * B + 6 * C) * X * X + (6 - 2 * B)) / 6
  else if X < 2 then
    Result := ((-B - 6 * C) * X * X * X + (6 * B + 30 * C) * X * X + (-12 * B - 48 * C) * X + (8 * B + 24 * C)) / 6
  else
    Result := 0;
end;

function ResamplingKernel(Filter: TResamplingFilter; X: Double): Double;
begin
  case Filter of
    ResamplingBox:
      if (X > -0.5) and (X <= 0.5) then
        Result := 1
      else
        Result := 0;
    ResamplingTriangle:
      Result := Max(0, 1 - Abs(X));
    ResamplingMitchell:
      Result := MitchellKernel(X);
  else
    if Abs(X) < 3 then
      Result := Sinc(X) * Sinc(X / 3)
    else
      Result := 0;
  end;
end;

function ComputeContributions(SourceSize, TargetSize: LongInt; Filter: TResamplingFilter): TContributions;
var
  Scale: Double;
  FilterScale: Double;
  Support: Double;
  Center: Double;
  First: LongInt;
  Last: LongInt;
  Index: LongInt;
  Tap: LongInt;
  Total: Double;
  Weights: array of Double;
begin
  Result := nil;
  SetLength(Result, TargetSize);
  Scale := SourceSize / TargetSize;
  FilterScale := Max(Scale, 1);
  Support := ResamplingSupport(Filter) * FilterScale;
  Weights := nil;
  for Index := 0 to TargetSize - 1 do
  begin
    Center := (Index + 0.5) * Scale;
    First := Trunc(Center - Support + 0.5);
    if First < 0 then
      First := 0;
    Last := Trunc(Center + Support + 0.5);
    if Last > SourceSize then
      Last := SourceSize;
    if Last <= First then
    begin
      First := Min(Trunc(Center), SourceSize - 1);
      Last := First + 1;
    end;
    SetLength(Weights, Last - First);
    Total := 0;
    for Tap := 0 to Last - First - 1 do
    begin
      Weights[Tap] := ResamplingKernel(Filter, (First + Tap - Center + 0.5) / FilterScale);
      Total := Total + Weights[Tap];
    end;
    Result[Index].First := First;
    SetLength(Result[Index].Weights, Last - First);
    for Tap := 0 to Last - First - 1 do
      if Total <> 0 then
        Result[Index].Weights[Tap] := Weights[Tap] / Total
      else
        Result[Index].Weights[Tap] := 1 / (Last - First);
  end;
end;

procedure PremultiplyLine(Source: PLongWord; Target: PPremultipliedPixel; Count: LongInt);
var
  Index: LongInt;
  Pixel: LongWord;
  Alpha: Single;
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Source[Index];
    Alpha := (Pixel shr 24) / 255;
    Target[Index].Alpha := Pixel shr 24;
    Target[Index].Red := ((Pixel shr 16) and $FF) * Alpha;
    Target[Index].Green := ((Pixel shr 8) and $FF) * Alpha;
    Target[Index].Blue := (Pixel and $FF) * Alpha;
  end;
end;

{ One line across: Source (premultiplied, the source's width) into
  Target (the new width). }
procedure ResampleAcross(Source, Target: PPremultipliedPixel; constref Contributions: TContributions);
var
  Index: LongInt;
  Tap: LongInt;
  Weight: Single;
  Sum: TPremultipliedPixel;
  Pixel: PPremultipliedPixel;
begin
  for Index := 0 to High(Contributions) do
  begin
    Sum := Default(TPremultipliedPixel);
    Pixel := Source + Contributions[Index].First;
    for Tap := 0 to High(Contributions[Index].Weights) do
    begin
      Weight := Contributions[Index].Weights[Tap];
      Sum.Red := Sum.Red + Pixel^.Red * Weight;
      Sum.Green := Sum.Green + Pixel^.Green * Weight;
      Sum.Blue := Sum.Blue + Pixel^.Blue * Weight;
      Sum.Alpha := Sum.Alpha + Pixel^.Alpha * Weight;
      Inc(Pixel);
    end;
    Target[Index] := Sum;
  end;
end;

function ClampToByte(Value: Single): LongWord; inline;
begin
  if Value <= 0 then
    Result := 0
  else if Value >= 255 then
    Result := 255
  else
    Result := Round(Value);
end;

function Unpremultiply(constref Pixel: TPremultipliedPixel): LongWord;
var
  Alpha: LongWord;
  Scale: Single;
begin
  Alpha := ClampToByte(Pixel.Alpha);
  if Alpha = 0 then
    Exit(0);
  Scale := 255 / Max(Pixel.Alpha, 1e-6);
  Result := (Alpha shl 24) or (ClampToByte(Pixel.Red * Scale) shl 16) or (ClampToByte(Pixel.Green * Scale) shl 8) or
    ClampToByte(Pixel.Blue * Scale);
end;

function ResampleImage(Image: TImage; NewWidth, NewHeight: LongInt; Filter: TResamplingFilter): TImage;
var
  Across: TContributions;
  Down: TContributions;
  Line: array of TPremultipliedPixel;
  Middle: array of TPremultipliedPixel;
  Y: LongInt;
  X: LongInt;
  Tap: LongInt;
  Weight: Single;
  Sums: array of TPremultipliedPixel;
  Pixel: PPremultipliedPixel;
  Output: PLongWord;
begin
  CheckImageSize(NewWidth, NewHeight);
  Result := TImage.Create(NewWidth, NewHeight);
  try
    Result.CopyPropertiesFrom(Image);
    Across := ComputeContributions(Image.Width, NewWidth, Filter);
    Down := ComputeContributions(Image.Height, NewHeight, Filter);
    Line := nil;
    SetLength(Line, Image.Width);
    Middle := nil;
    SetLength(Middle, PtrInt(NewWidth) * Image.Height);
    for Y := 0 to Image.Height - 1 do
    begin
      PremultiplyLine(Image.Line(Y), @Line[0], Image.Width);
      ResampleAcross(@Line[0], @Middle[PtrInt(Y) * NewWidth], Across);
    end;
    Sums := nil;
    SetLength(Sums, NewWidth);
    for Y := 0 to NewHeight - 1 do
    begin
      FillChar(Sums[0], Length(Sums) * SizeOf(TPremultipliedPixel), 0);
      for Tap := 0 to High(Down[Y].Weights) do
      begin
        Weight := Down[Y].Weights[Tap];
        Pixel := @Middle[PtrInt(Down[Y].First + Tap) * NewWidth];
        for X := 0 to NewWidth - 1 do
        begin
          Sums[X].Red := Sums[X].Red + Pixel[X].Red * Weight;
          Sums[X].Green := Sums[X].Green + Pixel[X].Green * Weight;
          Sums[X].Blue := Sums[X].Blue + Pixel[X].Blue * Weight;
          Sums[X].Alpha := Sums[X].Alpha + Pixel[X].Alpha * Weight;
        end;
      end;
      Output := Result.Line(Y);
      for X := 0 to NewWidth - 1 do
        Output[X] := Unpremultiply(Sums[X]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
