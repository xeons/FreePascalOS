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
  Paints: what fills a shape, pixel by pixel. A solid colour, a linear
  gradient, a radial gradient (two circles: the focal one, possibly of
  some radius, and the end one, as SVG 2's and the canvas API's
  createRadialGradient) or a pattern (a tile surface repeated).

  A gradient is defined in its own space; ToPaintSpace takes surface
  coordinates there (the inverse of everything that placed the
  gradient: SVG's gradientTransform, the bounding box for
  objectBoundingBox units, the element's transforms). Stops are colours
  at offsets from 0 to 1; between them colours are interpolated with
  premultiplied alpha, through a table of 256 colours made once
  (PreparePaint). Beyond 0 and 1 the spread method pads, reflects or
  repeats.

  A pattern's ToPaintSpace takes surface coordinates to the tile
  surface's pixels; the tile repeats in both directions.

  PaintSpan gives the colours of a run of pixels on one line, sampled
  at the pixels' centres.
}
unit Drawing.Paints;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Transforms;

type
  TPaintKind = (PaintSolid, PaintLinearGradient, PaintRadialGradient, PaintPattern, PaintConicGradient);
  TSpreadMethod = (SpreadPad, SpreadReflect, SpreadRepeat);

  TGradientStop = record
    Offset: Double;
    Color: TColor;
  end;

  TGradientStops = array of TGradientStop;

  TPaint = record
    Kind: TPaintKind;
    Color: TColor;
    Stops: TGradientStops;
    Spread: TSpreadMethod;
    { Linear: from (X1, Y1) at 0 to (X2, Y2) at 1. }
    X1, Y1, X2, Y2: Double;
    { Radial: the end circle at 1 and the focal circle at 0. }
    CentreX, CentreY, Radius: Double;
    FocusX, FocusY, FocusRadius: Double;
    { Conic: round (CentreX, CentreY), offset 0 at StartAngle (radians
      from the positive x axis, clockwise on the screen) and a whole
      turn later 1. }
    StartAngle: Double;
    ToPaintSpace: TAffineTransform;
    { Pattern: the tile (not owned), repeated or transparent outside
      it, sampled at the nearest pixel or between the four nearest. }
    Tile: TSurface;
    TileRepeat: Boolean;
    { With TileRepeat: the tile is not repeated along that axis (a
      repeat-x or repeat-y pattern), transparent beyond it there. }
    NoRepeatX, NoRepeatY: Boolean;
    Smooth: Boolean;
    { Gradients: colours between stops mixed without premultiplying
      their alpha (canvas gradients) rather than premultiplied (CSS,
      SVG). Set before PreparePaint. }
    InterpolateUnpremultiplied: Boolean;
    { Made by PreparePaint. }
    Ramp: array of TColor;
  end;

function SolidPaint(Color: TColor): TPaint;
function LinearGradientPaint(X1, Y1, X2, Y2: Double; const Stops: TGradientStops; Spread: TSpreadMethod;
  const ToPaintSpace: TAffineTransform): TPaint;
function RadialGradientPaint(CentreX, CentreY, Radius, FocusX, FocusY, FocusRadius: Double;
  const Stops: TGradientStops; Spread: TSpreadMethod; const ToPaintSpace: TAffineTransform): TPaint;
function PatternPaint(const Tile: TSurface; const ToPaintSpace: TAffineTransform): TPaint;
function ConicGradientPaint(CentreX, CentreY, StartAngle: Double; const Stops: TGradientStops;
  const ToPaintSpace: TAffineTransform): TPaint;
{ Builds the gradient's colour table (call after changing the stops). }
procedure PreparePaint(var Paint: TPaint);
{ The colours of pixels Left .. Left + Count - 1 of line Y (surface
  coordinates). }
procedure PaintSpan(const Paint: TPaint; Y, Left, Count: LongInt; var Colors: array of TColor);
{ A gradient whose stops make one colour (or none) is that colour. }
function GradientIsSolid(const Stops: TGradientStops; out Color: TColor): Boolean;

implementation

uses
  Math;

const
  RampSize = 256;

function SolidPaint(Color: TColor): TPaint;
begin
  Result := Default(TPaint);
  Result.Kind := PaintSolid;
  Result.Color := Color;
  Result.ToPaintSpace := IdentityTransform;
end;

function LinearGradientPaint(X1, Y1, X2, Y2: Double; const Stops: TGradientStops; Spread: TSpreadMethod;
  const ToPaintSpace: TAffineTransform): TPaint;
begin
  Result := Default(TPaint);
  Result.Kind := PaintLinearGradient;
  Result.X1 := X1;
  Result.Y1 := Y1;
  Result.X2 := X2;
  Result.Y2 := Y2;
  Result.Stops := Stops;
  Result.Spread := Spread;
  Result.ToPaintSpace := ToPaintSpace;
  PreparePaint(Result);
end;

function RadialGradientPaint(CentreX, CentreY, Radius, FocusX, FocusY, FocusRadius: Double;
  const Stops: TGradientStops; Spread: TSpreadMethod; const ToPaintSpace: TAffineTransform): TPaint;
begin
  Result := Default(TPaint);
  Result.Kind := PaintRadialGradient;
  Result.CentreX := CentreX;
  Result.CentreY := CentreY;
  Result.Radius := Radius;
  Result.FocusX := FocusX;
  Result.FocusY := FocusY;
  Result.FocusRadius := FocusRadius;
  Result.Stops := Stops;
  Result.Spread := Spread;
  Result.ToPaintSpace := ToPaintSpace;
  PreparePaint(Result);
end;

function PatternPaint(const Tile: TSurface; const ToPaintSpace: TAffineTransform): TPaint;
begin
  Result := Default(TPaint);
  Result.Kind := PaintPattern;
  Result.Tile := Tile;
  Result.TileRepeat := True;
  Result.ToPaintSpace := ToPaintSpace;
end;

function ConicGradientPaint(CentreX, CentreY, StartAngle: Double; const Stops: TGradientStops;
  const ToPaintSpace: TAffineTransform): TPaint;
begin
  Result := Default(TPaint);
  Result.Kind := PaintConicGradient;
  Result.CentreX := CentreX;
  Result.CentreY := CentreY;
  Result.StartAngle := StartAngle;
  Result.Stops := Stops;
  Result.Spread := SpreadPad;
  Result.ToPaintSpace := ToPaintSpace;
  PreparePaint(Result);
end;

function RepeatsX(const Paint: TPaint): Boolean; inline;
begin
  Result := Paint.TileRepeat and not Paint.NoRepeatX;
end;

function RepeatsY(const Paint: TPaint): Boolean; inline;
begin
  Result := Paint.TileRepeat and not Paint.NoRepeatY;
end;

{ The tile's pixel at (X, Y): wrapped along the axes it repeats on,
  else clamped to its edge. }
function TilePixel(const Paint: TPaint; X, Y: LongInt): TColor;
begin
  if RepeatsX(Paint) then
  begin
    X := X mod Paint.Tile.Width;
    if X < 0 then
      Inc(X, Paint.Tile.Width);
  end
  else
  begin
    if X < 0 then
      X := 0;
    if X >= Paint.Tile.Width then
      X := Paint.Tile.Width - 1;
  end;
  if RepeatsY(Paint) then
  begin
    Y := Y mod Paint.Tile.Height;
    if Y < 0 then
      Inc(Y, Paint.Tile.Height);
  end
  else
  begin
    if Y < 0 then
      Y := 0;
    if Y >= Paint.Tile.Height then
      Y := Paint.Tile.Height - 1;
  end;
  Result := SurfaceLine(Paint.Tile, Y)[X];
end;

{ Four colours mixed by their weights, premultiplied. }
function MixFour(C00, C10, C01, C11: TColor; FractionX, FractionY: Double): TColor;
var
  W00, W10, W01, W11: Double;
  A00, A10, A01, A11: Double;
  Alpha, Red, Green, Blue: Double;
begin
  W00 := (1 - FractionX) * (1 - FractionY);
  W10 := FractionX * (1 - FractionY);
  W01 := (1 - FractionX) * FractionY;
  W11 := FractionX * FractionY;
  A00 := AlphaOf(C00) * W00;
  A10 := AlphaOf(C10) * W10;
  A01 := AlphaOf(C01) * W01;
  A11 := AlphaOf(C11) * W11;
  Alpha := A00 + A10 + A01 + A11;
  if Alpha < 0.5 then
    Exit(ColorTransparent);
  Red := (RedOf(C00) * A00 + RedOf(C10) * A10 + RedOf(C01) * A01 + RedOf(C11) * A11) / Alpha;
  Green := (GreenOf(C00) * A00 + GreenOf(C10) * A10 + GreenOf(C01) * A01 + GreenOf(C11) * A11) / Alpha;
  Blue := (BlueOf(C00) * A00 + BlueOf(C10) * A10 + BlueOf(C01) * A01 + BlueOf(C11) * A11) / Alpha;
  Result := ArgbColor(Min(255, Round(Alpha)), Min(255, Round(Red)), Min(255, Round(Green)), Min(255, Round(Blue)));
end;

function SampleTile(const Paint: TPaint; X, Y: Double): TColor;
var
  BaseX, BaseY: LongInt;
  FractionX, FractionY: Double;
begin
  if not RepeatsX(Paint) and ((X < 0) or (X >= Paint.Tile.Width)) then
    Exit(ColorTransparent);
  if not RepeatsY(Paint) and ((Y < 0) or (Y >= Paint.Tile.Height)) then
    Exit(ColorTransparent);
  if not Paint.Smooth then
    Exit(TilePixel(Paint, Floor(X), Floor(Y)));
  X := X - 0.5;
  Y := Y - 0.5;
  BaseX := Floor(X);
  BaseY := Floor(Y);
  FractionX := X - BaseX;
  FractionY := Y - BaseY;
  Result := MixFour(TilePixel(Paint, BaseX, BaseY), TilePixel(Paint, BaseX + 1, BaseY),
    TilePixel(Paint, BaseX, BaseY + 1), TilePixel(Paint, BaseX + 1, BaseY + 1), FractionX, FractionY);
end;

function GradientIsSolid(const Stops: TGradientStops; out Color: TColor): Boolean;
var
  Index: LongInt;
begin
  Color := ColorTransparent;
  if Length(Stops) = 0 then
    Exit(True);
  Color := Stops[0].Color;
  for Index := 1 to High(Stops) do
    if Stops[Index].Color <> Color then
      Exit(False);
  Result := True;
end;

{ Colour First to Second by Weight (0 to 1), every channel on its own
  (alpha not premultiplied). }
function InterpolateUnpremultipliedColors(First, Second: TColor; Weight: Double): TColor;
begin
  Result := ArgbColor(Round(AlphaOf(First) + (AlphaOf(Second) - AlphaOf(First)) * Weight),
    Round(RedOf(First) + (RedOf(Second) - RedOf(First)) * Weight),
    Round(GreenOf(First) + (GreenOf(Second) - GreenOf(First)) * Weight),
    Round(BlueOf(First) + (BlueOf(Second) - BlueOf(First)) * Weight));
end;

{ Colour First to Second by Weight (0 to 1), premultiplied. }
function InterpolateColors(First, Second: TColor; Weight: Double): TColor;
var
  FirstAlpha, SecondAlpha, Alpha: Double;
  Red, Green, Blue: Double;
begin
  FirstAlpha := AlphaOf(First) / 255;
  SecondAlpha := AlphaOf(Second) / 255;
  Alpha := FirstAlpha + (SecondAlpha - FirstAlpha) * Weight;
  if Alpha <= 0 then
    Exit(ColorTransparent);
  Red := (RedOf(First) * FirstAlpha * (1 - Weight) + RedOf(Second) * SecondAlpha * Weight) / Alpha;
  Green := (GreenOf(First) * FirstAlpha * (1 - Weight) + GreenOf(Second) * SecondAlpha * Weight) / Alpha;
  Blue := (BlueOf(First) * FirstAlpha * (1 - Weight) + BlueOf(Second) * SecondAlpha * Weight) / Alpha;
  Result := ArgbColor(Round(Alpha * 255), Min(255, Round(Red)), Min(255, Round(Green)), Min(255, Round(Blue)));
end;

procedure PreparePaint(var Paint: TPaint);
var
  Entry: LongInt;
  Offset: Double;
  StopIndex: LongInt;
  Count: LongInt;
  Span: Double;
begin
  if not (Paint.Kind in [PaintLinearGradient, PaintRadialGradient, PaintConicGradient]) then
    Exit;
  Paint.Ramp := nil;
  SetLength(Paint.Ramp, RampSize);
  Count := Length(Paint.Stops);
  if Count = 0 then
  begin
    for Entry := 0 to RampSize - 1 do
      Paint.Ramp[Entry] := ColorTransparent;
    Exit;
  end;
  StopIndex := 0;
  for Entry := 0 to RampSize - 1 do
  begin
    Offset := Entry / (RampSize - 1);
    while (StopIndex < Count - 1) and (Paint.Stops[StopIndex + 1].Offset < Offset) do
      Inc(StopIndex);
    if Offset <= Paint.Stops[0].Offset then
      Paint.Ramp[Entry] := Paint.Stops[0].Color
    else if Offset >= Paint.Stops[Count - 1].Offset then
      Paint.Ramp[Entry] := Paint.Stops[Count - 1].Color
    else
    begin
      Span := Paint.Stops[StopIndex + 1].Offset - Paint.Stops[StopIndex].Offset;
      if Span <= 0 then
        Paint.Ramp[Entry] := Paint.Stops[StopIndex + 1].Color
      else if Paint.InterpolateUnpremultiplied then
        Paint.Ramp[Entry] := InterpolateUnpremultipliedColors(Paint.Stops[StopIndex].Color,
          Paint.Stops[StopIndex + 1].Color, (Offset - Paint.Stops[StopIndex].Offset) / Span)
      else
        Paint.Ramp[Entry] := InterpolateColors(Paint.Stops[StopIndex].Color, Paint.Stops[StopIndex + 1].Color,
          (Offset - Paint.Stops[StopIndex].Offset) / Span);
    end;
  end;
end;

function SpreadOffset(T: Double; Spread: TSpreadMethod): Double;
begin
  case Spread of
    SpreadRepeat:
      Result := T - Floor(T);
    SpreadReflect:
      begin
        Result := Abs(T);
        Result := Result - 2 * Floor(Result / 2);
        if Result > 1 then
          Result := 2 - Result;
      end;
    else
      Result := T;
  end;
  if Result < 0 then
    Result := 0;
  if Result > 1 then
    Result := 1;
end;

function RampColor(const Paint: TPaint; T: Double): TColor; inline;
begin
  Result := Paint.Ramp[Round(SpreadOffset(T, Paint.Spread) * (RampSize - 1))];
end;

{ Where on a two-circle gradient (X, Y) is: the largest T whose circle
  (centre and radius moving from the focal circle at 0 to the end one
  at 1) goes through the point with a radius not below zero. False when
  no circle does. }
function RadialOffset(const Paint: TPaint; X, Y: Double; out T: Double): Boolean;
var
  CentreDX, CentreDY, RadiusD: Double;
  PointDX, PointDY: Double;
  A, B, C: Double;
  Discriminant: Double;
  Root, T1, T2: Double;
begin
  CentreDX := Paint.CentreX - Paint.FocusX;
  CentreDY := Paint.CentreY - Paint.FocusY;
  RadiusD := Paint.Radius - Paint.FocusRadius;
  PointDX := X - Paint.FocusX;
  PointDY := Y - Paint.FocusY;
  A := CentreDX * CentreDX + CentreDY * CentreDY - RadiusD * RadiusD;
  B := PointDX * CentreDX + PointDY * CentreDY + Paint.FocusRadius * RadiusD;
  C := PointDX * PointDX + PointDY * PointDY - Paint.FocusRadius * Paint.FocusRadius;
  if Abs(A) < 1E-9 then
  begin
    { The focal circle touches the end circle: one root. }
    if Abs(B) < 1E-12 then
      Exit(False);
    T := C / (2 * B);
    Result := Paint.FocusRadius + T * RadiusD >= 0;
    Exit;
  end;
  Discriminant := B * B - A * C;
  if Discriminant < 0 then
    Exit(False);
  Root := Sqrt(Discriminant);
  T1 := (B + Root) / A;
  T2 := (B - Root) / A;
  if T1 < T2 then
  begin
    Root := T1;
    T1 := T2;
    T2 := Root;
  end;
  if Paint.FocusRadius + T1 * RadiusD >= 0 then
  begin
    T := T1;
    Exit(True);
  end;
  if Paint.FocusRadius + T2 * RadiusD >= 0 then
  begin
    T := T2;
    Exit(True);
  end;
  Result := False;
end;

procedure PaintSpan(const Paint: TPaint; Y, Left, Count: LongInt; var Colors: array of TColor);
var
  Index: LongInt;
  SampleX, SampleY: Double;
  PaintX, PaintY: Double;
  StepX, StepY: Double;
  DX, DY, LengthSquare: Double;
  T: Double;
begin
  case Paint.Kind of
    PaintSolid:
      for Index := 0 to Count - 1 do
        Colors[Index] := Paint.Color;
    PaintLinearGradient, PaintRadialGradient, PaintPattern, PaintConicGradient:
      begin
        SampleX := Left + 0.5;
        SampleY := Y + 0.5;
        PaintX := Paint.ToPaintSpace.A * SampleX + Paint.ToPaintSpace.C * SampleY + Paint.ToPaintSpace.E;
        PaintY := Paint.ToPaintSpace.B * SampleX + Paint.ToPaintSpace.D * SampleY + Paint.ToPaintSpace.F;
        StepX := Paint.ToPaintSpace.A;
        StepY := Paint.ToPaintSpace.B;
        case Paint.Kind of
          PaintLinearGradient:
            begin
              DX := Paint.X2 - Paint.X1;
              DY := Paint.Y2 - Paint.Y1;
              LengthSquare := DX * DX + DY * DY;
              for Index := 0 to Count - 1 do
              begin
                if LengthSquare <= 0 then
                  Colors[Index] := Paint.Ramp[RampSize - 1]
                else
                  Colors[Index] := RampColor(Paint, ((PaintX - Paint.X1) * DX + (PaintY - Paint.Y1) * DY) /
                    LengthSquare);
                PaintX := PaintX + StepX;
                PaintY := PaintY + StepY;
              end;
            end;
          PaintRadialGradient:
            for Index := 0 to Count - 1 do
            begin
              if RadialOffset(Paint, PaintX, PaintY, T) then
                Colors[Index] := RampColor(Paint, T)
              else
                Colors[Index] := ColorTransparent;
              PaintX := PaintX + StepX;
              PaintY := PaintY + StepY;
            end;
          PaintConicGradient:
            for Index := 0 to Count - 1 do
            begin
              DX := PaintX - Paint.CentreX;
              DY := PaintY - Paint.CentreY;
              T := (ArcTan2(DY, DX) - Paint.StartAngle) / (2 * Pi);
              T := T - Floor(T);
              Colors[Index] := RampColor(Paint, T);
              PaintX := PaintX + StepX;
              PaintY := PaintY + StepY;
            end;
          PaintPattern:
            for Index := 0 to Count - 1 do
            begin
              if (Paint.Tile.Width <= 0) or (Paint.Tile.Height <= 0) or (Abs(PaintX) > 1E9) or
                 (Abs(PaintY) > 1E9) then
                Colors[Index] := ColorTransparent
              else
                Colors[Index] := SampleTile(Paint, PaintX, PaintY);
              PaintX := PaintX + StepX;
              PaintY := PaintY + StepY;
            end;
        end;
      end;
  end;
end;

end.
