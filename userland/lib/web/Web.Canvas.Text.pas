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
  Canvas text (HTML Standard 4.12.5.1.5, the text preparation
  algorithm): white space becomes spaces, the glyphs are placed by
  libweb's text fonts (fallback faces, kerning) with letterSpacing and
  wordSpacing added, the run is anchored by textAlign (start and end
  following direction) and textBaseline, and squeezed horizontally to
  maxWidth when it is wider. The glyphs' outlines (TrueType and CFF,
  from libfont) become a path in the user space of the call, which the
  context transforms and fills or strokes like any other; synthetic
  italics slant it. TextMetrics come from the same placement: the
  advance, the ink's box from the outlines, and the font's and the em
  square's extents, all relative to the baseline asked for.
}
unit Web.Canvas.Text;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Transforms,
  Drawing.Paths,
  Web.Canvas.Fonts;

type
  TCanvasTextAlign = (TextAlignStart, TextAlignEnd, TextAlignLeft, TextAlignRight, TextAlignCenter);
  TCanvasTextBaseline = (TextBaselineTop, TextBaselineHanging, TextBaselineMiddle, TextBaselineAlphabetic,
    TextBaselineIdeographic, TextBaselineBottom);
  TCanvasDirection = (DirectionLtr, DirectionRtl, DirectionInherit);

  TCanvasTextStyle = record
    Font: TCanvasFont;
    Align: TCanvasTextAlign;
    Baseline: TCanvasTextBaseline;
    Direction: TCanvasDirection;
    LetterSpacing, WordSpacing: Double;
  end;

  TCanvasTextMeasure = record
    Width: Double;
    ActualLeft, ActualRight: Double;
    FontAscent, FontDescent: Double;
    ActualAscent, ActualDescent: Double;
    EmAscent, EmDescent: Double;
    HangingBaseline, AlphabeticBaseline, IdeographicBaseline: Double;
  end;

const
  TextAlignNames: array[TCanvasTextAlign] of string = ('start', 'end', 'left', 'right', 'center');
  TextBaselineNames: array[TCanvasTextBaseline] of string = ('top', 'hanging', 'middle', 'alphabetic',
    'ideographic', 'bottom');
  DirectionNames: array[TCanvasDirection] of string = ('ltr', 'rtl', 'inherit');

{ The glyphs of Text as a path through Transform, the run anchored at
  (X, Y) of its own space; MaxWidth < 0: no limit. }
procedure CanvasTextPath(const Text: string; const Style: TCanvasTextStyle; X, Y, MaxWidth: Double;
  const Transform: TAffineTransform; var Path: TPath);
function MeasureCanvasText(const Text: string; const Style: TCanvasTextStyle): TCanvasTextMeasure;

implementation

uses
  Math,
  Drawing.Rasterizer,
  Font.Outlines,
  Web.Text.Fonts,
  Web.Text.FontInstances;

type
  TPlacedRun = record
    Glyphs: TPlacedGlyphArray;
    Count: Integer;
    Width: Double;
  end;

function PreparedText(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in [#9, #10, #12, #13] then
      Result[Index] := ' ';
end;

function PlaceRun(const Text: string; const Style: TCanvasTextStyle): TPlacedRun;
var
  Index: Integer;
  Extra: Double;
begin
  Result.Glyphs := nil;
  Result.Count := 0;
  Result.Width := 0;
  if (Style.Font.Font = nil) or (Text = '') then
    Exit;
  Result.Width := Style.Font.Font.PlaceGlyphs(Text, 1, Length(Text), Result.Glyphs, Result.Count);
  if (Style.LetterSpacing = 0) and (Style.WordSpacing = 0) then
    Exit;
  Extra := 0;
  for Index := 0 to Result.Count - 1 do
  begin
    Result.Glyphs[Index].X := Result.Glyphs[Index].X + Extra;
    Extra := Extra + Style.LetterSpacing;
    if Result.Glyphs[Index].CodePoint = 32 then
      Extra := Extra + Style.WordSpacing;
  end;
  Result.Width := Result.Width + Extra;
end;

function IsRightToLeft(const Style: TCanvasTextStyle): Boolean;
begin
  Result := Style.Direction = DirectionRtl;
end;

{ How far the run's left edge is from the anchor (negative: left). }
function AlignShift(const Style: TCanvasTextStyle; Width: Double): Double;
var
  Align: TCanvasTextAlign;
begin
  Align := Style.Align;
  if Align = TextAlignStart then
  begin
    if IsRightToLeft(Style) then
      Align := TextAlignRight
    else
      Align := TextAlignLeft;
  end
  else if Align = TextAlignEnd then
  begin
    if IsRightToLeft(Style) then
      Align := TextAlignLeft
    else
      Align := TextAlignRight;
  end;
  case Align of
    TextAlignRight: Result := -Width;
    TextAlignCenter: Result := -Width / 2;
  else
    Result := 0;
  end;
end;

procedure EmExtents(const Style: TCanvasTextStyle; out Ascent, Descent: Double);
var
  Font: TTextFont;
  Total: Double;
begin
  Font := Style.Font.Font;
  Ascent := Style.Font.Size * 0.8;
  Descent := Style.Font.Size * 0.2;
  if Font = nil then
    Exit;
  Total := Font.Ascent + Font.Descent;
  if Total > 0 then
  begin
    Ascent := Style.Font.Size * Font.Ascent / Total;
    Descent := Style.Font.Size - Ascent;
  end;
end;

function FontAscentOf(const Style: TCanvasTextStyle): Double;
begin
  if Style.Font.Font <> nil then
    Result := Style.Font.Font.Ascent
  else
    Result := Style.Font.Size * 0.8;
end;

function FontDescentOf(const Style: TCanvasTextStyle): Double;
begin
  if Style.Font.Font <> nil then
    Result := Style.Font.Font.Descent
  else
    Result := Style.Font.Size * 0.2;
end;

{ How far below the anchor the alphabetic baseline is. }
function BaselineShift(const Style: TCanvasTextStyle): Double;
var
  EmAscent, EmDescent: Double;
begin
  EmExtents(Style, EmAscent, EmDescent);
  case Style.Baseline of
    TextBaselineTop: Result := EmAscent;
    TextBaselineHanging: Result := FontAscentOf(Style) * 0.8;
    TextBaselineMiddle: Result := (EmAscent - EmDescent) / 2;
    TextBaselineIdeographic: Result := -FontDescentOf(Style);
    TextBaselineBottom: Result := -EmDescent;
  else
    Result := 0;
  end;
end;

{ One glyph's contours into Path: font units through Scale (y up) to
  the run's space at (OriginX, OriginY), slanted by Slant, squeezed by
  SqueezeX about AnchorX, then through Transform. }
procedure AddGlyphOutline(var Path: TPath; const Outline: TGlyphOutline; Scale, OriginX, OriginY, Slant: Double;
  const Placement: TAffineTransform);
var
  Contour, First, Last, Count, Index, Step, Steps, Skip: LongInt;
  StartX, StartY, ControlX, ControlY, FirstCubicX, FirstCubicY: Double;
  HasControl: Boolean;
  CubicControls: Integer;
  Point: TOutlinePoint;

  function Mapped(FontX, FontY: Double): TPrecisePoint;
  var
    LocalX, LocalY: Double;
  begin
    LocalX := OriginX + FontX * Scale + FontY * Scale * Slant;
    LocalY := OriginY - FontY * Scale;
    Result := TransformPoint(Placement, LocalX, LocalY);
  end;

  procedure GoTo_(FontX, FontY: Double);
  var
    Target, Control, Second: TPrecisePoint;
  begin
    Target := Mapped(FontX, FontY);
    if CubicControls = 2 then
    begin
      Control := Mapped(FirstCubicX, FirstCubicY);
      Second := Mapped(ControlX, ControlY);
      PathCubicTo(Path, Control.X, Control.Y, Second.X, Second.Y, Target.X, Target.Y);
    end
    else if HasControl then
    begin
      Control := Mapped(ControlX, ControlY);
      PathQuadraticTo(Path, Control.X, Control.Y, Target.X, Target.Y);
    end
    else
      PathLineTo(Path, Target.X, Target.Y);
    HasControl := False;
    CubicControls := 0;
  end;

var
  Start: TPrecisePoint;
begin
  First := 0;
  for Contour := 0 to Outline.ContourCount - 1 do
  begin
    Last := Outline.ContourEnds[Contour];
    Count := Last - First + 1;
    if Count >= 2 then
    begin
      if Outline.Points[First].OnCurve then
      begin
        StartX := Outline.Points[First].X;
        StartY := Outline.Points[First].Y;
        Skip := First;
        Steps := Count - 1;
      end
      else if Outline.Points[Last].OnCurve then
      begin
        StartX := Outline.Points[Last].X;
        StartY := Outline.Points[Last].Y;
        Skip := Last;
        Steps := Count - 1;
      end
      else
      begin
        StartX := 0.5 * (Outline.Points[First].X + Outline.Points[Last].X);
        StartY := 0.5 * (Outline.Points[First].Y + Outline.Points[Last].Y);
        Skip := -1;
        Steps := Count;
      end;
      Start := Mapped(StartX, StartY);
      PathMoveTo(Path, Start.X, Start.Y);
      HasControl := False;
      CubicControls := 0;
      ControlX := 0;
      ControlY := 0;
      FirstCubicX := 0;
      FirstCubicY := 0;
      if Skip = First then
        Index := First + 1
      else
        Index := First;
      for Step := 1 to Steps do
      begin
        if Index = Skip then
          Inc(Index);
        if Index > Last then
          Index := First;
        Point := Outline.Points[Index];
        if Point.OnCurve then
          GoTo_(Point.X, Point.Y)
        else if Point.Cubic then
        begin
          if CubicControls = 0 then
          begin
            FirstCubicX := Point.X;
            FirstCubicY := Point.Y;
            CubicControls := 1;
          end
          else
          begin
            ControlX := Point.X;
            ControlY := Point.Y;
            CubicControls := 2;
          end;
        end
        else
        begin
          if HasControl then
            GoTo_(0.5 * (ControlX + Point.X), 0.5 * (ControlY + Point.Y));
          ControlX := Point.X;
          ControlY := Point.Y;
          HasControl := True;
        end;
        Inc(Index);
      end;
      GoTo_(StartX, StartY);
      PathClose(Path);
    end;
    First := Last + 1;
  end;
end;

function SlantOf(const Style: TCanvasTextStyle): Double;
begin
  Result := 0;
  if (Style.Font.Font <> nil) and Style.Font.Font.SyntheticItalic then
    Result := 0.2;
end;

procedure CanvasTextPath(const Text: string; const Style: TCanvasTextStyle; X, Y, MaxWidth: Double;
  const Transform: TAffineTransform; var Path: TPath);
var
  Run: TPlacedRun;
  Index: Integer;
  Squeeze, Left, Baseline, Scale, Slant: Double;
  Placement: TAffineTransform;
  Face: TOutlineFont;
  Outline: TGlyphOutline;
begin
  Run := PlaceRun(PreparedText(Text), Style);
  if Run.Count = 0 then
    Exit;
  Squeeze := 1;
  if (MaxWidth >= 0) and (Run.Width > MaxWidth) then
  begin
    if MaxWidth <= 0 then
      Exit;
    Squeeze := MaxWidth / Run.Width;
  end;
  Left := X + AlignShift(Style, Run.Width * Squeeze);
  Baseline := Y + BaselineShift(Style);
  { The run's space (left edge at 0, baseline at 0) squeezed and put at
    (Left, Baseline), then the context's transform. }
  Placement := CombineTransforms(Transform, MakeTransform(Squeeze, 0, 0, 1, Left, Baseline));
  Slant := SlantOf(Style);
  for Index := 0 to Run.Count - 1 do
  begin
    if Run.Glyphs[Index].Face = nil then
      Continue;
    Face := Run.Glyphs[Index].Face.Font;
    if (Face = nil) or (Face.UnitsPerEm <= 0) then
      Continue;
    if not Face.LoadOutline(Run.Glyphs[Index].Glyph, Outline) or (Outline.PointCount = 0) then
      Continue;
    Scale := Style.Font.Size / Face.UnitsPerEm;
    AddGlyphOutline(Path, Outline, Scale, Run.Glyphs[Index].X, 0, Slant, Placement);
  end;
end;

function MeasureCanvasText(const Text: string; const Style: TCanvasTextStyle): TCanvasTextMeasure;
var
  Run: TPlacedRun;
  Path: TPath;
  Bounds: TPathBounds;
  Shift, AnchorShift, EmAscent, EmDescent: Double;
  Index: Integer;
  Face: TOutlineFont;
  Outline: TGlyphOutline;
begin
  Result := Default(TCanvasTextMeasure);
  Run := PlaceRun(PreparedText(Text), Style);
  Result.Width := Run.Width;
  Shift := BaselineShift(Style);
  AnchorShift := AlignShift(Style, Run.Width);
  EmExtents(Style, EmAscent, EmDescent);
  Result.FontAscent := FontAscentOf(Style) - Shift;
  Result.FontDescent := FontDescentOf(Style) + Shift;
  Result.EmAscent := EmAscent - Shift;
  Result.EmDescent := EmDescent + Shift;
  Result.HangingBaseline := FontAscentOf(Style) * 0.8 - Shift;
  Result.AlphabeticBaseline := -Shift;
  Result.IdeographicBaseline := -FontDescentOf(Style) - Shift;
  { The ink: the outlines' box in the run's space (y down, baseline 0). }
  BeginPath(Path);
  for Index := 0 to Run.Count - 1 do
  begin
    if Run.Glyphs[Index].Face = nil then
      Continue;
    Face := Run.Glyphs[Index].Face.Font;
    if (Face = nil) or (Face.UnitsPerEm <= 0) then
      Continue;
    if Face.LoadOutline(Run.Glyphs[Index].Glyph, Outline) and (Outline.PointCount > 0) then
      AddGlyphOutline(Path, Outline, Style.Font.Size / Face.UnitsPerEm, Run.Glyphs[Index].X, 0, SlantOf(Style),
        IdentityTransform);
  end;
  Bounds := PathTightBounds(Path, IdentityTransform);
  if Bounds.Empty then
  begin
    Result.ActualLeft := -AnchorShift;
    Result.ActualRight := AnchorShift;
    Result.ActualAscent := -Shift;
    Result.ActualDescent := Shift;
    Exit;
  end;
  Result.ActualLeft := -(AnchorShift + Bounds.Left);
  Result.ActualRight := AnchorShift + Bounds.Right;
  Result.ActualAscent := -Bounds.Top - Shift;
  Result.ActualDescent := Bounds.Bottom + Shift;
end;

end.
