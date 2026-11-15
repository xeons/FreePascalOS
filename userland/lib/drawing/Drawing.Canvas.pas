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
  Canvases: drawing onto a surface, clipped.

  A canvas is a surface, a clip region (only pixels in it are touched;
  at most the surface) and an origin added to every coordinate given
  (where a window's own (0, 0) is). Colours with alpha below 255 are
  blended over what is there; opaque ones replace it.

  Everything is drawn as horizontal spans through FillSpan, which does
  the clipping, so the shapes in the other units are clipped the same
  way. Spans and rectangles take surface coordinates once the origin is
  added; their right and bottom are just outside, as rectangles'.
}
unit Drawing.Canvas;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces;

type
  TCanvas = record
    Surface: TSurface;
    Clip: TRegion;
    OriginX: LongInt;
    OriginY: LongInt;
  end;

{ A canvas on Surface: everything of it, origin at its top left. }
procedure BeginCanvas(out Canvas: TCanvas; const Surface: TSurface);
{ Clip becomes Region (in canvas coordinates) within the surface. }
procedure SetCanvasClip(var Canvas: TCanvas; const Region: TRegion);
{ Clip becomes what it was within Rectangle (in canvas coordinates). }
procedure NarrowCanvasClip(var Canvas: TCanvas; const Rectangle: TRectangle);
procedure SetCanvasOrigin(var Canvas: TCanvas; X, Y: LongInt);

{ The pixels from Left to Right (just outside) on line Y, surface
  coordinates (no origin), clipped. }
procedure FillSpan(const Canvas: TCanvas; Y, Left, Right: LongInt; Color: TColor);

procedure DrawPixel(const Canvas: TCanvas; X, Y: LongInt; Color: TColor);
procedure FillRectangle(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);
{ A one pixel frame just inside Rectangle. }
procedure DrawRectangleOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);
procedure DrawHorizontalLine(const Canvas: TCanvas; Left, Right, Y: LongInt; Color: TColor);
procedure DrawVerticalLine(const Canvas: TCanvas; X, Top, Bottom: LongInt; Color: TColor);

{ Copies SourceRectangle of Source to (X, Y). With Blend the source's
  alpha is honoured (and Opacity, 0-255, applied to it); without, its
  pixels replace the canvas's. }
procedure DrawSurface(const Canvas: TCanvas; const Source: TSurface; const SourceRectangle: TRectangle;
  X, Y: LongInt; Blend: Boolean; Opacity: Byte);

{ From FromColor at the top (or left) to ToColor at the bottom (right). }
procedure FillVerticalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; FromColor, ToColor: TColor);
procedure FillHorizontalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; FromColor, ToColor: TColor);

implementation

procedure BeginCanvas(out Canvas: TCanvas; const Surface: TSurface);
begin
  Canvas.Surface := Surface;
  SetRegionToRectangle(Canvas.Clip, SurfaceBounds(Surface));
  Canvas.OriginX := 0;
  Canvas.OriginY := 0;
end;

procedure SetCanvasClip(var Canvas: TCanvas; const Region: TRegion);
begin
  CopyRegion(Region, Canvas.Clip);
  OffsetRegion(Canvas.Clip, Canvas.OriginX, Canvas.OriginY);
  IntersectRegionWithRectangle(Canvas.Clip, SurfaceBounds(Canvas.Surface));
end;

procedure NarrowCanvasClip(var Canvas: TCanvas; const Rectangle: TRectangle);
begin
  IntersectRegionWithRectangle(Canvas.Clip, OffsetRectangle(Rectangle, Canvas.OriginX, Canvas.OriginY));
end;

procedure SetCanvasOrigin(var Canvas: TCanvas; X, Y: LongInt);
begin
  Canvas.OriginX := X;
  Canvas.OriginY := Y;
end;

procedure FillSpan(const Canvas: TCanvas; Y, Left, Right: LongInt; Color: TColor);
var
  Index: LongInt;
  Piece: TRectangle;
  Start: LongInt;
  Finish: LongInt;
  Line: PLongWord;
  X: LongInt;
  Opaque: Boolean;
begin
  if (Left >= Right) or (AlphaOf(Color) = 0) then
    Exit;
  Opaque := AlphaOf(Color) = AlphaOpaque;
  Line := SurfaceLine(Canvas.Surface, Y);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    Piece := Canvas.Clip.Rectangles[Index];
    if (Y < Piece.Top) or (Y >= Piece.Bottom) then
      Continue;
    Start := Left;
    if Start < Piece.Left then
      Start := Piece.Left;
    Finish := Right;
    if Finish > Piece.Right then
      Finish := Piece.Right;
    if Opaque then
      for X := Start to Finish - 1 do
        Line[X] := Color
    else
      for X := Start to Finish - 1 do
        Line[X] := BlendColors(Line[X], Color);
  end;
end;

procedure DrawPixel(const Canvas: TCanvas; X, Y: LongInt; Color: TColor);
begin
  FillSpan(Canvas, Y + Canvas.OriginY, X + Canvas.OriginX, X + Canvas.OriginX + 1, Color);
end;

procedure FillRectangle(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);
var
  Target: TRectangle;
  Bounds: TRectangle;
  Y: LongInt;
begin
  Bounds := RegionBounds(Canvas.Clip);
  if not IntersectRectangles(OffsetRectangle(Rectangle, Canvas.OriginX, Canvas.OriginY), Bounds, Target) then
    Exit;
  for Y := Target.Top to Target.Bottom - 1 do
    FillSpan(Canvas, Y, Target.Left, Target.Right, Color);
end;

procedure DrawHorizontalLine(const Canvas: TCanvas; Left, Right, Y: LongInt; Color: TColor);
begin
  FillRectangle(Canvas, MakeRectangle(Left, Y, Right - Left, 1), Color);
end;

procedure DrawVerticalLine(const Canvas: TCanvas; X, Top, Bottom: LongInt; Color: TColor);
begin
  FillRectangle(Canvas, MakeRectangle(X, Top, 1, Bottom - Top), Color);
end;

procedure DrawRectangleOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  DrawHorizontalLine(Canvas, Rectangle.Left, Rectangle.Right, Rectangle.Top, Color);
  if RectangleHeight(Rectangle) > 1 then
    DrawHorizontalLine(Canvas, Rectangle.Left, Rectangle.Right, Rectangle.Bottom - 1, Color);
  if RectangleHeight(Rectangle) > 2 then
  begin
    DrawVerticalLine(Canvas, Rectangle.Left, Rectangle.Top + 1, Rectangle.Bottom - 1, Color);
    if RectangleWidth(Rectangle) > 1 then
      DrawVerticalLine(Canvas, Rectangle.Right - 1, Rectangle.Top + 1, Rectangle.Bottom - 1, Color);
  end;
end;

procedure DrawSurface(const Canvas: TCanvas; const Source: TSurface; const SourceRectangle: TRectangle;
  X, Y: LongInt; Blend: Boolean; Opacity: Byte);
var
  Visible: TRectangle;
  Destination: TRectangle;
  Piece: TRectangle;
  Index: LongInt;
  Row: LongInt;
  Column: LongInt;
  SourceLine: PLongWord;
  TargetLine: PLongWord;
  ShiftX: LongInt;
  ShiftY: LongInt;
begin
  if not IntersectRectangles(SourceRectangle, SurfaceBounds(Source), Visible) then
    Exit;
  { Where the visible part of the source lands on the surface. }
  ShiftX := X + Canvas.OriginX - SourceRectangle.Left;
  ShiftY := Y + Canvas.OriginY - SourceRectangle.Top;
  Destination := OffsetRectangle(Visible, ShiftX, ShiftY);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    if not IntersectRectangles(Destination, Canvas.Clip.Rectangles[Index], Piece) then
      Continue;
    for Row := Piece.Top to Piece.Bottom - 1 do
    begin
      SourceLine := SurfaceLine(Source, Row - ShiftY);
      TargetLine := SurfaceLine(Canvas.Surface, Row);
      if not Blend then
        Move(SourceLine[Piece.Left - ShiftX], TargetLine[Piece.Left], RectangleWidth(Piece) * SizeOf(LongWord))
      else if Opacity = AlphaOpaque then
        for Column := Piece.Left to Piece.Right - 1 do
          TargetLine[Column] := BlendColors(TargetLine[Column], SourceLine[Column - ShiftX])
      else
        for Column := Piece.Left to Piece.Right - 1 do
          TargetLine[Column] := BlendColors(TargetLine[Column], FadeColor(SourceLine[Column - ShiftX], Opacity));
    end;
  end;
end;

{ How far along Step is of Steps (0 at the first, 255 at the last). }
function GradientWeight(Step, Steps: LongInt): Byte;
begin
  if Steps <= 1 then
    Exit(0);
  Result := Byte((Step * 255 + (Steps - 1) div 2) div (Steps - 1));
end;

procedure FillVerticalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; FromColor, ToColor: TColor);
var
  Row: LongInt;
  Height: LongInt;
begin
  Height := RectangleHeight(Rectangle);
  for Row := 0 to Height - 1 do
    DrawHorizontalLine(Canvas, Rectangle.Left, Rectangle.Right, Rectangle.Top + Row,
      MixColors(FromColor, ToColor, GradientWeight(Row, Height)));
end;

procedure FillHorizontalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; FromColor, ToColor: TColor);
var
  Column: LongInt;
  Width: LongInt;
begin
  Width := RectangleWidth(Rectangle);
  for Column := 0 to Width - 1 do
    DrawVerticalLine(Canvas, Rectangle.Left + Column, Rectangle.Top, Rectangle.Bottom,
      MixColors(FromColor, ToColor, GradientWeight(Column, Width)));
end;

end.
