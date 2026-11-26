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
  A 2D context's drawing state (HTML Standard 4.12.5.1.2): what save()
  pushes and restore() pops - the transform, the clipping region, and
  every style attribute - with the defaults reset() and a new context
  start from. The fill and stroke styles reference their gradients and
  patterns, so a copy retains them and a discarded state releases them;
  the clip is a coverage array that is never changed in place (clip()
  makes a new one), so states share it safely.
}
unit Web.Canvas.State;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Transforms,
  Drawing.Rasterizer,
  Drawing.Stroking,
  Drawing.Compositing,
  Web.Canvas.Styles,
  Web.Canvas.Fonts,
  Web.Canvas.Text,
  Web.Canvas.Filters;

type
  TImageSmoothingQuality = (SmoothingLow, SmoothingMedium, SmoothingHigh);

  TCanvasDrawingState = record
    Transform: TAffineTransform;
    FillStyle, StrokeStyle: TCanvasPaintStyle;
    GlobalAlpha: Double;
    Operation: TCompositeOperation;
    LineWidth, MiterLimit, LineDashOffset: Double;
    LineCap: TLineCap;
    LineJoin: TLineJoin;
    LineDash: array of Double;
    ShadowColor: TColor;
    ShadowOffsetX, ShadowOffsetY, ShadowBlur: Double;
    Text: TCanvasTextStyle;
    LetterSpacingText, WordSpacingText: string;
    FontKerning, FontStretch, FontVariantCaps, TextRendering: string;
    ImageSmoothingEnabled: Boolean;
    ImageSmoothingQuality: TImageSmoothingQuality;
    FilterText: string;
    Filter: TCanvasFilter;
    Clip: TCoverageBytes;
  end;
  PCanvasDrawingState = ^TCanvasDrawingState;

const
  LineCapNames: array[TLineCap] of string = ('butt', 'round', 'square');
  LineJoinNames: array[TLineJoin] of string = ('miter', 'round', 'bevel', 'miter-clip', 'arcs');
  SmoothingQualityNames: array[TImageSmoothingQuality] of string = ('low', 'medium', 'high');

function DefaultDrawingState: TCanvasDrawingState;
{ A copy holding its own references (save()). }
function CopyDrawingState(const State: TCanvasDrawingState): TCanvasDrawingState;
procedure ReleaseDrawingState(var State: TCanvasDrawingState);

implementation

function DefaultDrawingState: TCanvasDrawingState;
begin
  Result := Default(TCanvasDrawingState);
  Result.Transform := IdentityTransform;
  Result.FillStyle := ColorStyle(ColorBlack);
  Result.StrokeStyle := ColorStyle(ColorBlack);
  Result.GlobalAlpha := 1;
  Result.Operation := CompositeSourceOver;
  Result.LineWidth := 1;
  Result.MiterLimit := 10;
  Result.LineDashOffset := 0;
  Result.LineCap := LineCapButt;
  Result.LineJoin := LineJoinMiter;
  Result.LineDash := nil;
  Result.ShadowColor := ColorTransparent;
  Result.Text.Font := DefaultCanvasFont;
  Result.Text.Align := TextAlignStart;
  Result.Text.Baseline := TextBaselineAlphabetic;
  Result.Text.Direction := DirectionInherit;
  Result.LetterSpacingText := '0px';
  Result.WordSpacingText := '0px';
  Result.FontKerning := 'auto';
  Result.FontStretch := 'normal';
  Result.FontVariantCaps := 'normal';
  Result.TextRendering := 'auto';
  Result.ImageSmoothingEnabled := True;
  Result.ImageSmoothingQuality := SmoothingLow;
  Result.FilterText := 'none';
  Result.Filter := nil;
  Result.Clip := nil;
end;

function CopyDrawingState(const State: TCanvasDrawingState): TCanvasDrawingState;
begin
  Result := State;
  Result.LineDash := Copy(State.LineDash);
  RetainStyle(Result.FillStyle);
  RetainStyle(Result.StrokeStyle);
end;

procedure ReleaseDrawingState(var State: TCanvasDrawingState);
begin
  ReleaseStyle(State.FillStyle);
  ReleaseStyle(State.StrokeStyle);
  State.Clip := nil;
  State.Filter := nil;
  State.LineDash := nil;
end;

end.
