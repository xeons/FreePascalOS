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
  Drawing.Compositing, Drawing.Blurring and the paints canvas added:
  the Porter-Duff operators and blend modes on colours worked out by
  hand (Compositing and Blending Level 1's formulas), weights mixing a
  result with the destination, the names; a blur keeping the total and
  spreading as far as BlurMargin says; conic gradients, one-axis
  patterns and gradients mixed without premultiplying.
}
unit DrawingTest.Compositing;

{$mode objfpc}
{$H+}

interface

procedure TestCompositing;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Transforms,
  Drawing.Paints,
  Drawing.Compositing,
  Drawing.Blurring,
  DrawingTest.Checks;

function CloseTo(Got, Expected: TColor; Tolerance: Integer): Boolean;
begin
  Result := (Abs(AlphaOf(Got) - AlphaOf(Expected)) <= Tolerance) and (Abs(RedOf(Got) - RedOf(Expected)) <= Tolerance) and
    (Abs(GreenOf(Got) - GreenOf(Expected)) <= Tolerance) and (Abs(BlueOf(Got) - BlueOf(Expected)) <= Tolerance);
end;

procedure CheckComposite(const Name: string; Destination, Source: TColor; Operation: TCompositeOperation;
  Expected: TColor);
var
  Got: TColor;
begin
  Got := CompositeColors(Destination, Source, Operation);
  Check('composite ' + Name + ' (' + ColorText(Got) + ')', CloseTo(Got, Expected, 1));
end;

procedure TestOperators;
const
  Red = $FFFF0000;
  Blue = $FF0000FF;
  HalfBlue = $800000FF;
var
  Operation, Found: TCompositeOperation;
  Named: Boolean;
begin
  CheckComposite('source-over opaque', Red, Blue, CompositeSourceOver, Blue);
  CheckComposite('source-over half', Red, HalfBlue, CompositeSourceOver, $FF7F0080);
  CheckComposite('copy', Red, HalfBlue, CompositeCopy, HalfBlue);
  CheckComposite('source-in on nothing', ColorTransparent, Blue, CompositeSourceIn, ColorTransparent);
  CheckComposite('source-in', Red, HalfBlue, CompositeSourceIn, HalfBlue);
  CheckComposite('source-out', Red, Blue, CompositeSourceOut, ColorTransparent);
  CheckComposite('source-out on nothing', ColorTransparent, Blue, CompositeSourceOut, Blue);
  CheckComposite('source-atop', Red, HalfBlue, CompositeSourceAtop, $FF7F0080);
  CheckComposite('destination-over', HalfBlue, Red, CompositeDestinationOver, $FF7F0080);
  CheckComposite('destination-in', Red, HalfBlue, CompositeDestinationIn, $80FF0000);
  CheckComposite('destination-out', Red, HalfBlue, CompositeDestinationOut, $7FFF0000);
  CheckComposite('destination-atop', HalfBlue, Red, CompositeDestinationAtop, $FF7F0080);
  CheckComposite('xor of opaque colours', Red, Blue, CompositeXor, ColorTransparent);
  CheckComposite('lighter', Red, Blue, CompositeLighter, $FFFF00FF);
  CheckComposite('lighter clamps', $FF808080, $FF808080, CompositeLighter, $FFFFFFFF);
  CheckComposite('multiply', $FFFF8000, $FF808080, CompositeMultiply, $FF804000);
  CheckComposite('screen', $FF000000, $FFFFFFFF, CompositeScreen, $FFFFFFFF);
  CheckComposite('screen of black', $FFFFFFFF, $FF000000, CompositeScreen, $FFFFFFFF);
  CheckComposite('darken', $FF4080C0, $FF8080FF, CompositeDarken, $FF4080C0);
  CheckComposite('lighten', $FF4080C0, $FF8080FF, CompositeLighten, $FF8080FF);
  CheckComposite('difference', $FFFFFFFF, $FFFF0000, CompositeDifference, $FF00FFFF);
  CheckComposite('exclusion', $FFFFFFFF, $FF808080, CompositeExclusion, $FF7F7F7F);
  CheckComposite('overlay', $FF000000, $FFFFFFFF, CompositeOverlay, $FF000000);
  CheckComposite('hard-light', $FF000000, $FFFFFFFF, CompositeHardLight, $FFFFFFFF);
  CheckComposite('color-dodge of black', $FF000000, $FF808080, CompositeColorDodge, $FF000000);
  CheckComposite('color-burn of white', $FFFFFFFF, $FF808080, CompositeColorBurn, $FFFFFFFF);
  CheckComposite('soft-light of mid grey', $FF808080, $FF808080, CompositeSoftLight, $FF808080);
  CheckComposite('luminosity', $FFFF0000, $FFFFFFFF, CompositeLuminosity, $FFFFFFFF);
  CheckComposite('color keeps the luminosity', $FF000000, $FFFF0000, CompositeColor, $FF000000);
  CheckComposite('saturation of a grey backdrop stays grey', $FF808080, $FFFF0000, CompositeSaturation, $FF808080);
  CheckComposite('hue of grey stays grey', $FF808080, $FFFF0000, CompositeHue, $FF808080);
  CheckComposite('a blend mode over nothing is the source', ColorTransparent, HalfBlue, CompositeMultiply, HalfBlue);
  Named := True;
  for Operation := Low(TCompositeOperation) to High(TCompositeOperation) do
    if not CompositeOperationFromName(CompositeOperationNames[Operation], Found) or (Found <> Operation) then
      Named := False;
  Check('composite: every operation by its name', Named and not CompositeOperationFromName('clear', Found));
  Check('composite: the unbounded operations', CompositeOperationIsUnbounded(CompositeCopy) and
    CompositeOperationIsUnbounded(CompositeDestinationIn) and not CompositeOperationIsUnbounded(CompositeXor));
end;

procedure TestSpans;
var
  Destination, Source: array[0..2] of TColor;
  Weights: array[0..2] of Byte;
begin
  Destination[0] := $FFFF0000; Destination[1] := $FFFF0000; Destination[2] := $FFFF0000;
  Source[0] := $FF0000FF; Source[1] := $FF0000FF; Source[2] := ColorTransparent;
  Weights[0] := 255; Weights[1] := 128; Weights[2] := 255;
  CompositeSpan(@Destination[0], @Source[0], @Weights[0], 3, CompositeCopy);
  Check('composite span: copy at full weight', CloseTo(Destination[0], $FF0000FF, 0));
  Check('composite span: half weight mixes with the destination (' + ColorText(Destination[1]) + ')',
    CloseTo(Destination[1], $FF7F0080, 1));
  Check('composite span: copy of transparent clears', AlphaOf(Destination[2]) = 0);
end;

procedure TestBlur;
var
  Plane: TBlurPlane;
  Index, Total, Margin: Integer;
  Pixels: array[0..24] of TColor;
begin
  Plane := nil;
  SetLength(Plane, 41 * 41);
  Plane[20 * 41 + 20] := 255;
  Plane[20 * 41 + 21] := 255;
  Plane[21 * 41 + 20] := 255;
  Plane[21 * 41 + 21] := 255;
  BlurPlane(Plane, 41, 41, 3, 3);
  Total := 0;
  for Index := 0 to High(Plane) do
    Inc(Total, Plane[Index]);
  Check('blur keeps the total (' + IntToStr(Total) + ')', Abs(Total - 4 * 255) < 4 * 255 div 10);
  Margin := BlurMargin(3);
  Check('blur spreads within its margin', (Plane[20 * 41 + 20 + Margin + 1] = 0) and (Plane[20 * 41 + 23] > 0));
  Check('blur is symmetric', Abs(Plane[20 * 41 + 17] - Plane[21 * 41 + 24]) <= 1);
  for Index := 0 to High(Pixels) do
    Pixels[Index] := ColorTransparent;
  Pixels[12] := $FFFF0000;
  BlurColors(@Pixels[0], 5, 5, 1);
  Check('blurred colours keep their colour', (AlphaOf(Pixels[11]) > 0) and (RedOf(Pixels[11]) = 255) and
    (GreenOf(Pixels[11]) = 0));
end;

procedure TestPaints;
var
  Stops: TGradientStops;
  Paint: TPaint;
  Colors: array[0..3] of TColor;
  Tile: TSurface;
begin
  Stops := nil;
  SetLength(Stops, 2);
  Stops[0].Offset := 0;
  Stops[0].Color := $FFFF0000;
  Stops[1].Offset := 1;
  Stops[1].Color := $FF0000FF;
  Paint := ConicGradientPaint(50, 50, 0, Stops, IdentityTransform);
  PaintSpan(Paint, 50, 90, 1, Colors);
  Check('conic gradient starts at the start angle (' + ColorText(Colors[0]) + ')', RedOf(Colors[0]) > 240);
  PaintSpan(Paint, 50, 10, 1, Colors);
  Check('conic gradient half way round (' + ColorText(Colors[0]) + ')', Abs(RedOf(Colors[0]) - BlueOf(Colors[0])) < 8);
  PaintSpan(Paint, 90, 50, 1, Colors);
  Check('conic gradient a quarter turn on, clockwise (' + ColorText(Colors[0]) + ')',
    (RedOf(Colors[0]) > BlueOf(Colors[0])) and (BlueOf(Colors[0]) > 40));
  Stops[1].Color := $000000FF;
  Paint := LinearGradientPaint(0, 0, 100, 0, Stops, SpreadPad, IdentityTransform);
  Paint.InterpolateUnpremultiplied := True;
  PreparePaint(Paint);
  PaintSpan(Paint, 0, 50, 1, Colors);
  Check('unpremultiplied gradients mix every channel (' + ColorText(Colors[0]) + ')',
    (Abs(RedOf(Colors[0]) - 127) < 6) and (Abs(BlueOf(Colors[0]) - 127) < 6) and (Abs(AlphaOf(Colors[0]) - 127) < 6));
  Tile := NewSurface(2, 2, $FF00FF00);
  try
    Paint := PatternPaint(Tile, IdentityTransform);
    Paint.NoRepeatY := True;
    PaintSpan(Paint, 1, 4, 1, Colors);
    Check('a repeat-x pattern repeats across', Colors[0] = $FF00FF00);
    PaintSpan(Paint, 4, 1, 1, Colors);
    Check('a repeat-x pattern does not repeat down', AlphaOf(Colors[0]) = 0);
  finally
    FreeSurface(Tile);
  end;
end;

procedure TestCompositing;
begin
  TestOperators;
  TestSpans;
  TestBlur;
  TestPaints;
end;

end.
