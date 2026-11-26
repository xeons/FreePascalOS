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
  The canvas filter attribute (HTML Standard 4.12.5.1.19): "none" or a
  list of CSS filter functions (Filter Effects Level 1, 13): blur(),
  brightness(), contrast(), drop-shadow(), grayscale(), hue-rotate(),
  invert(), opacity(), saturate() and sepia(), applied in order to what
  a drawing operation makes before its shadow and compositing. url()
  references to SVG filters are not supported here, so a value with one
  is not accepted (the attribute keeps its value). The colour functions
  work on sRGB values, as browsers' canvas filters do.
}
unit Web.Canvas.Filters;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors;

type
  TCanvasFilterKind = (FilterBlur, FilterBrightness, FilterContrast, FilterDropShadow, FilterGrayscale,
    FilterHueRotate, FilterInvert, FilterOpacity, FilterSaturate, FilterSepia);

  TCanvasFilterStep = record
    Kind: TCanvasFilterKind;
    { The function's amount (a fraction), angle (degrees) or blur
      radius (pixels). }
    Amount: Double;
    { drop-shadow() }
    OffsetX, OffsetY: Double;
    Color: TColor;
  end;

  TCanvasFilter = array of TCanvasFilterStep;

{ Text as a filter value ('none' gives no steps); False when it is not
  one. CurrentColor: what currentcolor means (drop-shadow's default). }
function ParseCanvasFilter(const Text: string; CurrentColor: TColor; out Filter: TCanvasFilter): Boolean;
{ How far the filter can spread what it is given (pixels, each side). }
function FilterMargin(const Filter: TCanvasFilter): LongInt;
{ Pixels (Width x Height, not premultiplied) filtered in place. }
procedure ApplyCanvasFilter(const Filter: TCanvasFilter; var Pixels: array of TColor; Width, Height: LongInt);

implementation

uses
  SysUtils,
  Math,
  Css.Tokens,
  Css.Tokenizer,
  Css.Values,
  Css.Units,
  Css.Colors,
  Css.ColorParser,
  Drawing.Blurring;

const
  FilterNames: array[TCanvasFilterKind] of string = ('blur', 'brightness', 'contrast', 'drop-shadow',
    'grayscale', 'hue-rotate', 'invert', 'opacity', 'saturate', 'sepia');

function KindByName(const Name: string; out Kind: TCanvasFilterKind): Boolean;
var
  Candidate: TCanvasFilterKind;
begin
  for Candidate := Low(TCanvasFilterKind) to High(TCanvasFilterKind) do
    if FilterNames[Candidate] = Name then
    begin
      Kind := Candidate;
      Exit(True);
    end;
  Kind := FilterBlur;
  Result := False;
end;

{ A length in pixels from a token (a dimension, or a zero number). }
function LengthOf(const Token: TCssToken; out Pixels: Double): Boolean;
var
  UnitValue: TCssUnit;
begin
  Result := False;
  Pixels := 0;
  if (Token.Kind = tkNumber) and (Token.Number = 0) then
    Exit(True);
  if Token.Kind <> tkDimension then
    Exit;
  UnitValue := UnitByName(LowerCase(Token.Text));
  if not IsAbsoluteLength(UnitValue) then
    Exit;
  Pixels := Token.Number * CanonicalFactor(UnitValue);
  Result := True;
end;

function AngleOf(const Token: TCssToken; out Degrees: Double): Boolean;
var
  Name: string;
begin
  Result := True;
  Degrees := 0;
  if (Token.Kind = tkNumber) and (Token.Number = 0) then
    Exit;
  Result := False;
  if Token.Kind <> tkDimension then
    Exit;
  Name := LowerCase(Token.Text);
  if Name = 'deg' then
    Degrees := Token.Number
  else if Name = 'rad' then
    Degrees := Token.Number * 180 / Pi
  else if Name = 'grad' then
    Degrees := Token.Number * 0.9
  else if Name = 'turn' then
    Degrees := Token.Number * 360
  else
    Exit;
  Result := True;
end;

function AmountOf(const Token: TCssToken; out Amount: Double): Boolean;
begin
  Result := True;
  case Token.Kind of
    tkNumber: Amount := Token.Number;
    tkPercentage: Amount := Token.Number / 100;
  else
    Result := False;
  end;
  if Result and (Amount < 0) then
    Result := False;
end;

{ The arguments of one function: Tokens[First..Stop - 1] without white
  space. }
function ParseStep(Kind: TCanvasFilterKind; const Tokens: TCssTokenArray; First, Stop: Integer;
  CurrentColor: TColor; out Step: TCanvasFilterStep): Boolean;
var
  Arguments: array of TCssToken;
  Index, Lengths: Integer;
  Cursor: TCssTokenCursor;
  ColorValue: TCssValue;
  Resolved, Current: TCssColor;
  Rgba: TCssRgba8;
  Value: Double;
begin
  Result := False;
  Step := Default(TCanvasFilterStep);
  Step.Kind := Kind;
  Arguments := nil;
  if Kind = FilterDropShadow then
  begin
    Step.Color := CurrentColor;
    Lengths := 0;
    Index := First;
    while Index < Stop do
    begin
      if Tokens[Index].Kind = tkWhitespace then
      begin
        Inc(Index);
        Continue;
      end;
      if LengthOf(Tokens[Index], Value) and (Lengths < 3) then
      begin
        case Lengths of
          0: Step.OffsetX := Value;
          1: Step.OffsetY := Value;
        else
          begin
            if Value < 0 then
              Exit;
            Step.Amount := Value;
          end;
        end;
        Inc(Lengths);
        Inc(Index);
        Continue;
      end;
      Cursor := TCssTokenCursor.CreateRange(Tokens, Index, Stop);
      ColorValue := ParseColor(Cursor);
      if ColorValue = nil then
        Exit;
      Current := MakeRgbColor(RedOf(CurrentColor) / 255, GreenOf(CurrentColor) / 255, BlueOf(CurrentColor) / 255,
        AlphaOf(CurrentColor) / 255);
      if not ResolveColor(ColorValue, Current, False, Resolved) then
      begin
        ReleaseValue(ColorValue);
        Exit;
      end;
      ReleaseValue(ColorValue);
      Rgba := ColorToRgba8(Resolved);
      Step.Color := ArgbColor(Rgba.Alpha, Rgba.Red, Rgba.Green, Rgba.Blue);
      Index := Cursor.Position;
    end;
    Exit(Lengths >= 2);
  end;
  for Index := First to Stop - 1 do
    if Tokens[Index].Kind <> tkWhitespace then
    begin
      SetLength(Arguments, Length(Arguments) + 1);
      Arguments[High(Arguments)] := Tokens[Index];
    end;
  if Length(Arguments) > 1 then
    Exit;
  case Kind of
    FilterBlur:
      begin
        Step.Amount := 0;
        if Length(Arguments) = 1 then
          if not LengthOf(Arguments[0], Step.Amount) or (Step.Amount < 0) then
            Exit;
      end;
    FilterHueRotate:
      begin
        Step.Amount := 0;
        if Length(Arguments) = 1 then
          if not AngleOf(Arguments[0], Step.Amount) then
            Exit;
      end;
  else
    begin
      Step.Amount := 1;
      if Length(Arguments) = 1 then
        if not AmountOf(Arguments[0], Step.Amount) then
          Exit;
      if Kind in [FilterGrayscale, FilterInvert, FilterOpacity, FilterSepia] then
        Step.Amount := Min(Step.Amount, 1);
    end;
  end;
  Result := True;
end;

function ParseCanvasFilter(const Text: string; CurrentColor: TColor; out Filter: TCanvasFilter): Boolean;
var
  Tokens: TCssTokenArray;
  Index: Integer;
  Kind: TCanvasFilterKind;
  Step: TCanvasFilterStep;
begin
  Filter := nil;
  Result := False;
  Tokens := TokenizeCss(Text);
  Index := 0;
  while (Index < Length(Tokens)) and (Tokens[Index].Kind = tkWhitespace) do
    Inc(Index);
  if (Index < Length(Tokens)) and (Tokens[Index].Kind = tkIdent) and (LowerCase(Tokens[Index].Text) = 'none') then
  begin
    Inc(Index);
    while (Index < Length(Tokens)) and (Tokens[Index].Kind = tkWhitespace) do
      Inc(Index);
    Exit((Index >= Length(Tokens)) or (Tokens[Index].Kind = tkEof));
  end;
  while Index < Length(Tokens) do
  begin
    case Tokens[Index].Kind of
      tkWhitespace:
        Inc(Index);
      tkEof:
        Break;
      tkFunction:
        begin
          if not KindByName(LowerCase(Tokens[Index].Text), Kind) then
            Exit;
          if (Tokens[Index].Match <= Index) or (Tokens[Index].Match >= Length(Tokens)) or
             (Tokens[Tokens[Index].Match].Kind <> tkCloseParen) then
            Exit;
          if not ParseStep(Kind, Tokens, Index + 1, Tokens[Index].Match, CurrentColor, Step) then
            Exit;
          SetLength(Filter, Length(Filter) + 1);
          Filter[High(Filter)] := Step;
          Index := Tokens[Index].Match + 1;
        end;
    else
      Exit;
    end;
  end;
  Result := Length(Filter) > 0;
end;

function FilterMargin(const Filter: TCanvasFilter): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Filter) do
    case Filter[Index].Kind of
      FilterBlur:
        Inc(Result, BlurMargin(Filter[Index].Amount));
      FilterDropShadow:
        Inc(Result, BlurMargin(Filter[Index].Amount) +
          Ceil(Max(Abs(Filter[Index].OffsetX), Abs(Filter[Index].OffsetY))));
    end;
end;

type
  TColorMatrix = array[0..2, 0..2] of Double;

function ByteOf(Value: Double): Byte; inline;
begin
  if Value <= 0 then
    Exit(0);
  if Value >= 255 then
    Exit(255);
  Result := Round(Value);
end;

procedure ApplyMatrix(const Matrix: TColorMatrix; var Pixels: array of TColor);
var
  Index: Integer;
  Color: TColor;
  R, G, B: Double;
begin
  for Index := 0 to High(Pixels) do
  begin
    Color := Pixels[Index];
    if AlphaOf(Color) = 0 then
      Continue;
    R := RedOf(Color);
    G := GreenOf(Color);
    B := BlueOf(Color);
    Pixels[Index] := ArgbColor(AlphaOf(Color), ByteOf(Matrix[0, 0] * R + Matrix[0, 1] * G + Matrix[0, 2] * B),
      ByteOf(Matrix[1, 0] * R + Matrix[1, 1] * G + Matrix[1, 2] * B),
      ByteOf(Matrix[2, 0] * R + Matrix[2, 1] * G + Matrix[2, 2] * B));
  end;
end;

function GrayscaleMatrix(Amount: Double): TColorMatrix;
var
  A: Double;
begin
  A := 1 - Amount;
  Result[0, 0] := 0.2126 + 0.7874 * A; Result[0, 1] := 0.7152 - 0.7152 * A; Result[0, 2] := 0.0722 - 0.0722 * A;
  Result[1, 0] := 0.2126 - 0.2126 * A; Result[1, 1] := 0.7152 + 0.2848 * A; Result[1, 2] := 0.0722 - 0.0722 * A;
  Result[2, 0] := 0.2126 - 0.2126 * A; Result[2, 1] := 0.7152 - 0.7152 * A; Result[2, 2] := 0.0722 + 0.9278 * A;
end;

function SepiaMatrix(Amount: Double): TColorMatrix;
var
  A: Double;
begin
  A := 1 - Amount;
  Result[0, 0] := 0.393 + 0.607 * A; Result[0, 1] := 0.769 - 0.769 * A; Result[0, 2] := 0.189 - 0.189 * A;
  Result[1, 0] := 0.349 - 0.349 * A; Result[1, 1] := 0.686 + 0.314 * A; Result[1, 2] := 0.168 - 0.168 * A;
  Result[2, 0] := 0.272 - 0.272 * A; Result[2, 1] := 0.534 - 0.534 * A; Result[2, 2] := 0.131 + 0.869 * A;
end;

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
  C := Cos(Degrees * Pi / 180);
  S := Sin(Degrees * Pi / 180);
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

procedure ApplyTransfer(Kind: TCanvasFilterKind; Amount: Double; var Pixels: array of TColor);
var
  Index: Integer;
  Color: TColor;

  function Channel(Value: Byte): Byte;
  var
    C: Double;
  begin
    C := Value / 255;
    case Kind of
      FilterBrightness: C := C * Amount;
      FilterContrast: C := (C - 0.5) * Amount + 0.5;
    else
      C := Amount * (1 - C) + (1 - Amount) * C;
    end;
    Result := ByteOf(C * 255);
  end;

begin
  for Index := 0 to High(Pixels) do
  begin
    Color := Pixels[Index];
    if AlphaOf(Color) = 0 then
      Continue;
    if Kind = FilterOpacity then
      Pixels[Index] := WithAlpha(Color, ByteOf(AlphaOf(Color) * Amount))
    else
      Pixels[Index] := ArgbColor(AlphaOf(Color), Channel(RedOf(Color)), Channel(GreenOf(Color)),
        Channel(BlueOf(Color)));
  end;
end;

procedure ApplyDropShadow(const Step: TCanvasFilterStep; var Pixels: array of TColor; Width, Height: LongInt);
var
  Plane: TBlurPlane;
  Shifted: array of TColor;
  X, Y, SourceX, SourceY, ShiftX, ShiftY: LongInt;
  Alpha: LongWord;
begin
  Plane := nil;
  SetLength(Plane, Width * Height);
  ShiftX := Round(Step.OffsetX);
  ShiftY := Round(Step.OffsetY);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      SourceX := X - ShiftX;
      SourceY := Y - ShiftY;
      if (SourceX >= 0) and (SourceX < Width) and (SourceY >= 0) and (SourceY < Height) then
        Plane[Y * Width + X] := AlphaOf(Pixels[SourceY * Width + SourceX]);
    end;
  BlurPlane(Plane, Width, Height, Step.Amount, Step.Amount);
  Shifted := nil;
  SetLength(Shifted, Width * Height);
  for X := 0 to Width * Height - 1 do
  begin
    Alpha := (LongWord(AlphaOf(Step.Color)) * Plane[X] + 127) div 255;
    Shifted[X] := BlendColors(WithAlpha(Step.Color, Alpha), Pixels[X]);
  end;
  for X := 0 to Width * Height - 1 do
    Pixels[X] := Shifted[X];
end;

procedure ApplyCanvasFilter(const Filter: TCanvasFilter; var Pixels: array of TColor; Width, Height: LongInt);
var
  Index: Integer;
begin
  for Index := 0 to High(Filter) do
    case Filter[Index].Kind of
      FilterBlur:
        if Length(Pixels) > 0 then
          BlurColors(@Pixels[0], Width, Height, Filter[Index].Amount);
      FilterGrayscale:
        ApplyMatrix(GrayscaleMatrix(Filter[Index].Amount), Pixels);
      FilterSepia:
        ApplyMatrix(SepiaMatrix(Filter[Index].Amount), Pixels);
      FilterSaturate:
        ApplyMatrix(SaturateMatrix(Filter[Index].Amount), Pixels);
      FilterHueRotate:
        ApplyMatrix(HueRotateMatrix(Filter[Index].Amount), Pixels);
      FilterBrightness, FilterContrast, FilterInvert, FilterOpacity:
        ApplyTransfer(Filter[Index].Kind, Filter[Index].Amount, Pixels);
      FilterDropShadow:
        ApplyDropShadow(Filter[Index], Pixels, Width, Height);
    end;
end;

end.
