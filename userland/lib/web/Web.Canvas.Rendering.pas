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
  The canvas drawing model (HTML Standard 4.12.5.1.21): what a fill,
  stroke, text or image operation makes is a layer of device pixels (a
  shape's coverage times its paint), then

    1. the filter is applied to it,
    2. its shadow is made from its alpha (offset, blurred by a Gaussian
       of standard deviation shadowBlur / 2, in the shadow colour),
    3. both are faded by globalAlpha,
    4. the shadow and then the layer are composited onto the bitmap by
       the compositing operator, within the clipping region (a coverage
       mask, so clip edges are anti-aliased).

  Operators that affect the destination where the source is transparent
  (copy, source-in, ...) composite over the whole bitmap, the layer
  being transparent outside its area. The bitmap's pixels are libimage's
  ($AARRGGBB, not premultiplied).
}
unit Web.Canvas.Rendering;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Rasterizer,
  Drawing.Paints,
  Drawing.Compositing,
  Image.Model,
  Web.Canvas.Filters;

type
  TCanvasLayer = record
    Area: TRectangle;
    { Area's width times its height, row by row. }
    Pixels: array of TColor;
  end;

  TCanvasShadow = record
    Color: TColor;
    OffsetX, OffsetY, Blur: Double;
  end;

  TCanvasDrawSettings = record
    Operation: TCompositeOperation;
    GlobalAlpha: Double;
    Shadow: TCanvasShadow;
    Filter: TCanvasFilter;
    { The clipping region's coverage of every bitmap pixel; nil when
      nothing is clipped. }
    Clip: TCoverageBytes;
  end;

function ShadowVisible(const Shadow: TCanvasShadow): Boolean;
{ The device area a layer is worth making over for a Width x Height
  bitmap: the bitmap, and what a shadow or filter could bring into it. }
function DrawingInterestArea(Width, Height: LongInt; const Settings: TCanvasDrawSettings): TRectangle;
{ The shape filled with Paint over Interest (empty when it covers
  nothing there). }
procedure MakeShapeLayer(const Shape: TCoverageShape; Rule: TFillRule; const Paint: TPaint;
  const Interest: TRectangle; out Layer: TCanvasLayer);
{ The layer drawn on Bitmap by the drawing model. }
procedure DrawLayer(Bitmap: TImage; var Layer: TCanvasLayer; const Settings: TCanvasDrawSettings);
{ The clipping region narrowed by a shape (Clip nil: the whole bitmap). }
function NarrowClip(const Clip: TCoverageBytes; const Shape: TCoverageShape; Rule: TFillRule;
  Width, Height: LongInt): TCoverageBytes;

implementation

uses
  Math,
  Drawing.Blurring;

function ShadowVisible(const Shadow: TCanvasShadow): Boolean;
begin
  Result := (AlphaOf(Shadow.Color) > 0) and ((Shadow.Blur > 0) or (Shadow.OffsetX <> 0) or (Shadow.OffsetY <> 0));
end;

function ShadowMargin(const Shadow: TCanvasShadow): LongInt;
begin
  Result := BlurMargin(Shadow.Blur / 2);
end;

function ClampedOffset(Value: Double): LongInt;
begin
  if Value > 100000 then
    Exit(100000);
  if Value < -100000 then
    Exit(-100000);
  Result := Round(Value);
end;

function DrawingInterestArea(Width, Height: LongInt; const Settings: TCanvasDrawSettings): TRectangle;
var
  Bitmap, Shifted: TRectangle;
  Margin: LongInt;
begin
  Bitmap := MakeRectangle(0, 0, Width, Height);
  Result := Bitmap;
  Margin := FilterMargin(Settings.Filter);
  if ShadowVisible(Settings.Shadow) then
  begin
    Shifted := OffsetRectangle(Bitmap, -ClampedOffset(Settings.Shadow.OffsetX),
      -ClampedOffset(Settings.Shadow.OffsetY));
    Result := BoundingRectangle(Result, InflateRectangle(Shifted, ShadowMargin(Settings.Shadow) + Margin));
  end;
  Result := InflateRectangle(Result, Margin);
end;

procedure MakeShapeLayer(const Shape: TCoverageShape; Rule: TFillRule; const Paint: TPaint;
  const Interest: TRectangle; out Layer: TCanvasLayer);
var
  Coverage: TCoverageBytes;
  Width, Row, X, Start, Finish: LongInt;
  Colors: array of TColor;
  Value: Byte;
begin
  Layer.Area := MakeRectangle(0, 0, 0, 0);
  Layer.Pixels := nil;
  if Shape.Count = 0 then
    Exit;
  if not IntersectRectangles(ShapeSurfaceBounds(Shape, 0, 0), Interest, Layer.Area) then
    Exit;
  Coverage := ShapeCoverageBytes(Shape, Layer.Area, Rule);
  Width := RectangleWidth(Layer.Area);
  SetLength(Layer.Pixels, Width * RectangleHeight(Layer.Area));
  Colors := nil;
  SetLength(Colors, Width);
  for Row := 0 to RectangleHeight(Layer.Area) - 1 do
  begin
    Start := 0;
    while (Start < Width) and (Coverage[Row * Width + Start] = 0) do
      Inc(Start);
    if Start >= Width then
      Continue;
    Finish := Width;
    while (Finish > Start) and (Coverage[Row * Width + Finish - 1] = 0) do
      Dec(Finish);
    PaintSpan(Paint, Layer.Area.Top + Row, Layer.Area.Left + Start, Finish - Start, Colors);
    for X := Start to Finish - 1 do
    begin
      Value := Coverage[Row * Width + X];
      if Value = 0 then
        Continue;
      if Value = 255 then
        Layer.Pixels[Row * Width + X] := Colors[X - Start]
      else
        Layer.Pixels[Row * Width + X] := FadeColor(Colors[X - Start], Value);
    end;
  end;
end;

{ The layer grown by Margin on every side (the new pixels transparent). }
procedure GrowLayer(var Layer: TCanvasLayer; Margin: LongInt);
var
  Grown: array of TColor;
  OldWidth, NewWidth, Row, X: LongInt;
begin
  if Margin <= 0 then
    Exit;
  OldWidth := RectangleWidth(Layer.Area);
  NewWidth := OldWidth + 2 * Margin;
  Grown := nil;
  SetLength(Grown, NewWidth * (RectangleHeight(Layer.Area) + 2 * Margin));
  for Row := 0 to RectangleHeight(Layer.Area) - 1 do
    for X := 0 to OldWidth - 1 do
      Grown[(Row + Margin) * NewWidth + X + Margin] := Layer.Pixels[Row * OldWidth + X];
  Layer.Pixels := Grown;
  Layer.Area := InflateRectangle(Layer.Area, Margin);
end;

procedure MakeShadowLayer(const Layer: TCanvasLayer; const Shadow: TCanvasShadow; out ShadowLayer: TCanvasLayer);
var
  Margin, Width, Height, LayerWidth, Row, X: LongInt;
  Plane: TBlurPlane;
  Alpha: LongWord;
begin
  Margin := ShadowMargin(Shadow);
  ShadowLayer.Area := InflateRectangle(OffsetRectangle(Layer.Area, ClampedOffset(Shadow.OffsetX),
    ClampedOffset(Shadow.OffsetY)), Margin);
  Width := RectangleWidth(ShadowLayer.Area);
  Height := RectangleHeight(ShadowLayer.Area);
  LayerWidth := RectangleWidth(Layer.Area);
  Plane := nil;
  SetLength(Plane, Width * Height);
  for Row := 0 to RectangleHeight(Layer.Area) - 1 do
    for X := 0 to LayerWidth - 1 do
      Plane[(Row + Margin) * Width + X + Margin] := AlphaOf(Layer.Pixels[Row * LayerWidth + X]);
  BlurPlane(Plane, Width, Height, Shadow.Blur / 2, Shadow.Blur / 2);
  ShadowLayer.Pixels := nil;
  SetLength(ShadowLayer.Pixels, Width * Height);
  for X := 0 to Width * Height - 1 do
    if Plane[X] <> 0 then
    begin
      Alpha := (LongWord(AlphaOf(Shadow.Color)) * Plane[X] + 127) div 255;
      ShadowLayer.Pixels[X] := WithAlpha(Shadow.Color, Alpha);
    end;
end;

procedure CompositeLayer(Bitmap: TImage; const Layer: TCanvasLayer; const Settings: TCanvasDrawSettings;
  Opacity: Byte);
var
  Region: TRectangle;
  Row, Y, X, Width, LayerWidth, Column: LongInt;
  Source: array of TColor;
  Weights: PByte;
  Color: TColor;
begin
  if CompositeOperationIsUnbounded(Settings.Operation) then
    Region := MakeRectangle(0, 0, Bitmap.Width, Bitmap.Height)
  else if not IntersectRectangles(Layer.Area, MakeRectangle(0, 0, Bitmap.Width, Bitmap.Height), Region) then
    Exit;
  Width := RectangleWidth(Region);
  if Width <= 0 then
    Exit;
  LayerWidth := RectangleWidth(Layer.Area);
  Source := nil;
  SetLength(Source, Width);
  for Row := 0 to RectangleHeight(Region) - 1 do
  begin
    Y := Region.Top + Row;
    for X := 0 to Width - 1 do
    begin
      Column := Region.Left + X;
      if (Y >= Layer.Area.Top) and (Y < Layer.Area.Bottom) and (Column >= Layer.Area.Left) and
         (Column < Layer.Area.Right) then
      begin
        Color := Layer.Pixels[(Y - Layer.Area.Top) * LayerWidth + Column - Layer.Area.Left];
        if Opacity < 255 then
          Color := FadeColor(Color, Opacity);
        Source[X] := Color;
      end
      else
        Source[X] := ColorTransparent;
    end;
    if Settings.Clip <> nil then
      Weights := @Settings.Clip[Y * Bitmap.Width + Region.Left]
    else
      Weights := nil;
    CompositeSpan(@Bitmap.Line(Y)[Region.Left], @Source[0], Weights, Width, Settings.Operation);
  end;
end;

procedure DrawLayer(Bitmap: TImage; var Layer: TCanvasLayer; const Settings: TCanvasDrawSettings);
var
  Opacity: Byte;
  ShadowLayer: TCanvasLayer;
  Empty: Boolean;
begin
  if (Bitmap = nil) or (Bitmap.Width = 0) or (Bitmap.Height = 0) then
    Exit;
  Empty := RectangleIsEmpty(Layer.Area);
  if Empty and not CompositeOperationIsUnbounded(Settings.Operation) then
    Exit;
  Opacity := Round(EnsureRange(Settings.GlobalAlpha, 0, 1) * 255);
  if not Empty and (Length(Settings.Filter) > 0) then
  begin
    GrowLayer(Layer, FilterMargin(Settings.Filter));
    ApplyCanvasFilter(Settings.Filter, Layer.Pixels, RectangleWidth(Layer.Area), RectangleHeight(Layer.Area));
  end;
  if not Empty and ShadowVisible(Settings.Shadow) then
  begin
    MakeShadowLayer(Layer, Settings.Shadow, ShadowLayer);
    CompositeLayer(Bitmap, ShadowLayer, Settings, Opacity);
  end;
  CompositeLayer(Bitmap, Layer, Settings, Opacity);
end;

function NarrowClip(const Clip: TCoverageBytes; const Shape: TCoverageShape; Rule: TFillRule;
  Width, Height: LongInt): TCoverageBytes;
var
  Index: LongInt;
begin
  if Shape.Count = 0 then
  begin
    Result := nil;
    SetLength(Result, Width * Height);
    Exit;
  end;
  Result := ShapeCoverageBytes(Shape, MakeRectangle(0, 0, Width, Height), Rule);
  if Clip <> nil then
    for Index := 0 to High(Result) do
      Result[Index] := (LongWord(Result[Index]) * Clip[Index] + 127) div 255;
end;

end.
