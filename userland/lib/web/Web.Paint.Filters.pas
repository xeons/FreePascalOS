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
  The filter property (Filter Effects 1, section 13): the filter
  functions of a box's computed value, in order, applied to the box's
  painted group before it is clipped, masked and composited.

  blur() is a Gaussian blur (Drawing.Blurring, three box blurs);
  brightness(), contrast(), grayscale(), hue-rotate(), invert(),
  opacity(), saturate() and sepia() are the colour matrices and transfer
  functions of section 13.2, on unpremultiplied sRGB values. drop-shadow()
  and url() references are not drawn (the function is skipped).
}
unit Web.Paint.Filters;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle, Drawing.Surfaces;

type
  TFilterOperationKind = (foBlur, foBrightness, foContrast, foGrayscale, foHueRotate, foInvert, foOpacity,
    foSaturate, foSepia);

  TFilterOperation = record
    Kind: TFilterOperationKind;
    { blur: the standard deviation in CSS pixels; hue-rotate: degrees;
      the others: the amount (1 = 100%). }
    Amount: Single;
  end;

  TFilterOperations = array of TFilterOperation;

{ The functions of the box's filter that are drawn (none: empty). }
function FilterOperationsOf(Style: TCssComputedStyle): TFilterOperations;
{ Surface (unpremultiplied colours, Stride = Width) filtered in place;
  Scale is device pixels per CSS pixel. }
procedure ApplyFilterOperations(var Surface: TSurface; const Operations: TFilterOperations; Scale: Double);

implementation

uses
  Math, SysUtils, Css.ComputedValues, Css.PropertyIds, Css.Values, Css.Units, Drawing.Colors, Drawing.Blurring;

type
  TColorMatrix = array[0..2, 0..2] of Double;

function ArgumentAmount(Item: TCssValue; Default: Single): Single;
var
  Argument: TCssValue;
begin
  Result := Default;
  if Item.Count = 0 then
    Exit;
  Argument := Item.Items[0];
  case Argument.Kind of
    vkNumber, vkInteger: Result := Argument.Number;
    vkPercentage: Result := Argument.Number / 100;
    vkDimension:
      if UnitCategory(Argument.UnitValue) = ucAngle then
        Result := Argument.Number * CanonicalFactor(Argument.UnitValue)
      else
        Result := Argument.Number;
  end;
end;

function FilterOperationsOf(Style: TCssComputedStyle): TFilterOperations;
var
  Value: PCssComputedValue;
  List, Item: TCssValue;
  Index, Count: Integer;
  Operation: TFilterOperation;
  Name: string;
begin
  Result := nil;
  Value := Style.Value(cpFilter);
  if (Value^.Kind <> cvValue) or (Value^.Data = nil) then
    Exit;
  List := Value^.Data;
  if List.Kind = vkList then
    Count := List.Count
  else
    Count := 1;
  for Index := 0 to Count - 1 do
  begin
    if List.Kind = vkList then
      Item := List.Items[Index]
    else
      Item := List;
    if Item.Kind <> vkFunction then
      Continue;
    Name := LowerCase(Item.Text);
    if Name = 'blur' then
    begin
      Operation.Kind := foBlur;
      Operation.Amount := ArgumentAmount(Item, 0);
    end
    else if Name = 'hue-rotate' then
    begin
      Operation.Kind := foHueRotate;
      Operation.Amount := ArgumentAmount(Item, 0);
    end
    else
    begin
      if Name = 'brightness' then Operation.Kind := foBrightness
      else if Name = 'contrast' then Operation.Kind := foContrast
      else if Name = 'grayscale' then Operation.Kind := foGrayscale
      else if Name = 'invert' then Operation.Kind := foInvert
      else if Name = 'opacity' then Operation.Kind := foOpacity
      else if Name = 'saturate' then Operation.Kind := foSaturate
      else if Name = 'sepia' then Operation.Kind := foSepia
      else
        Continue;
      Operation.Amount := Max(0, ArgumentAmount(Item, 1));
      { grayscale, invert, opacity and sepia stop at 100%. }
      if Operation.Kind in [foGrayscale, foInvert, foOpacity, foSepia] then
        Operation.Amount := Min(Operation.Amount, 1);
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Operation;
  end;
end;

{ Filter Effects 1, 13.2: the matrices of saturate, hue-rotate,
  grayscale and sepia. }
function SaturateMatrix(S: Double): TColorMatrix;
begin
  Result[0, 0] := 0.213 + 0.787 * S; Result[0, 1] := 0.715 - 0.715 * S; Result[0, 2] := 0.072 - 0.072 * S;
  Result[1, 0] := 0.213 - 0.213 * S; Result[1, 1] := 0.715 + 0.285 * S; Result[1, 2] := 0.072 - 0.072 * S;
  Result[2, 0] := 0.213 - 0.213 * S; Result[2, 1] := 0.715 - 0.715 * S; Result[2, 2] := 0.072 + 0.928 * S;
end;

function HueRotateMatrix(Degrees: Double): TColorMatrix;
var
  C, S: Double;
begin
  C := Cos(DegToRad(Degrees));
  S := Sin(DegToRad(Degrees));
  Result[0, 0] := 0.213 + C * 0.787 - S * 0.213;
  Result[0, 1] := 0.715 - C * 0.715 - S * 0.715;
  Result[0, 2] := 0.072 - C * 0.072 + S * 0.928;
  Result[1, 0] := 0.213 - C * 0.213 + S * 0.143;
  Result[1, 1] := 0.715 + C * 0.285 + S * 0.140;
  Result[1, 2] := 0.072 - C * 0.072 - S * 0.283;
  Result[2, 0] := 0.213 - C * 0.213 - S * 0.787;
  Result[2, 1] := 0.715 - C * 0.715 + S * 0.715;
  Result[2, 2] := 0.072 + C * 0.928 + S * 0.072;
end;

function GrayscaleMatrix(A: Double): TColorMatrix;
var
  K: Double;
begin
  K := 1 - A;
  Result[0, 0] := 0.2126 + 0.7874 * K; Result[0, 1] := 0.7152 - 0.7152 * K; Result[0, 2] := 0.0722 - 0.0722 * K;
  Result[1, 0] := 0.2126 - 0.2126 * K; Result[1, 1] := 0.7152 + 0.2848 * K; Result[1, 2] := 0.0722 - 0.0722 * K;
  Result[2, 0] := 0.2126 - 0.2126 * K; Result[2, 1] := 0.7152 - 0.7152 * K; Result[2, 2] := 0.0722 + 0.9278 * K;
end;

function SepiaMatrix(A: Double): TColorMatrix;
var
  K: Double;
begin
  K := 1 - A;
  Result[0, 0] := 0.393 + 0.607 * K; Result[0, 1] := 0.769 - 0.769 * K; Result[0, 2] := 0.189 - 0.189 * K;
  Result[1, 0] := 0.349 - 0.349 * K; Result[1, 1] := 0.686 + 0.314 * K; Result[1, 2] := 0.168 - 0.168 * K;
  Result[2, 0] := 0.272 - 0.272 * K; Result[2, 1] := 0.534 - 0.534 * K; Result[2, 2] := 0.131 + 0.869 * K;
end;

function ClampChannel(Value: Double): Byte; inline;
begin
  if Value <= 0 then
    Result := 0
  else if Value >= 1 then
    Result := 255
  else
    Result := Round(Value * 255);
end;

procedure ApplyColorOperation(var Surface: TSurface; const Operation: TFilterOperation);
var
  Index, Count: LongInt;
  Pixel: PLongWord;
  Color: TColor;
  Red, Green, Blue, Alpha, A: Double;
  Matrix: TColorMatrix;
  UsesMatrix: Boolean;
begin
  UsesMatrix := Operation.Kind in [foGrayscale, foHueRotate, foSaturate, foSepia];
  case Operation.Kind of
    foGrayscale: Matrix := GrayscaleMatrix(Operation.Amount);
    foHueRotate: Matrix := HueRotateMatrix(Operation.Amount);
    foSaturate: Matrix := SaturateMatrix(Operation.Amount);
    foSepia: Matrix := SepiaMatrix(Operation.Amount);
  end;
  A := Operation.Amount;
  Count := Surface.Width * Surface.Height;
  Pixel := Surface.Pixels;
  for Index := 0 to Count - 1 do
  begin
    Color := Pixel[Index];
    if AlphaOf(Color) = 0 then
      Continue;
    Red := RedOf(Color) / 255;
    Green := GreenOf(Color) / 255;
    Blue := BlueOf(Color) / 255;
    Alpha := AlphaOf(Color) / 255;
    if UsesMatrix then
    begin
      Color := ArgbColor(AlphaOf(Color),
        ClampChannel(Matrix[0, 0] * Red + Matrix[0, 1] * Green + Matrix[0, 2] * Blue),
        ClampChannel(Matrix[1, 0] * Red + Matrix[1, 1] * Green + Matrix[1, 2] * Blue),
        ClampChannel(Matrix[2, 0] * Red + Matrix[2, 1] * Green + Matrix[2, 2] * Blue));
    end
    else
      case Operation.Kind of
        foBrightness:
          Color := ArgbColor(AlphaOf(Color), ClampChannel(Red * A), ClampChannel(Green * A), ClampChannel(Blue * A));
        foContrast:
          Color := ArgbColor(AlphaOf(Color), ClampChannel((Red - 0.5) * A + 0.5),
            ClampChannel((Green - 0.5) * A + 0.5), ClampChannel((Blue - 0.5) * A + 0.5));
        foInvert:
          Color := ArgbColor(AlphaOf(Color), ClampChannel(Red * (1 - A) + (1 - Red) * A),
            ClampChannel(Green * (1 - A) + (1 - Green) * A), ClampChannel(Blue * (1 - A) + (1 - Blue) * A));
        foOpacity:
          Color := ArgbColor(ClampChannel(Alpha * A), RedOf(Color), GreenOf(Color), BlueOf(Color));
      end;
    Pixel[Index] := Color;
  end;
end;

procedure ApplyFilterOperations(var Surface: TSurface; const Operations: TFilterOperations; Scale: Double);
var
  Index: Integer;
begin
  if (Surface.Pixels = nil) or (Surface.Stride <> Surface.Width) then
    Exit;
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = foBlur then
    begin
      if Operations[Index].Amount > 0 then
        BlurColors(Surface.Pixels, Surface.Width, Surface.Height, Operations[Index].Amount * Scale);
    end
    else
      ApplyColorOperation(Surface, Operations[Index]);
end;

end.
