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
  Filling shapes with paints, through masks.

  FillShapeWithPaint draws a shape (Drawing.Rasterizer, surface
  coordinates: the canvas's origin is not added) with any paint
  (Drawing.Paints) under either fill rule, every pixel blended at the
  paint's alpha times its coverage times Opacity, within the canvas's
  clip and, when given, a coverage mask.

  A coverage mask is a value from 0 to 255 for every pixel of a
  rectangle of the surface (0 outside it): what a clip path or a mask
  lets through. Masks multiply (IntersectMasks). DrawSurfaceMasked puts
  a layer (a surface drawn on its own, transparent where nothing was
  drawn) over the canvas through a mask and an opacity, for group
  opacity, clip paths and masks.
}
unit Drawing.PaintFilling;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.Paints;

type
  TCoverageMask = record
    Area: TRectangle;
    Values: TCoverageBytes;
  end;
  PCoverageMask = ^TCoverageMask;

{ The shape's coverage over Area as a mask. }
function MaskFromShape(const Shape: TCoverageShape; Rule: TFillRule; const Area: TRectangle): TCoverageMask;
{ A mask over Area, every value Value. }
function UniformMask(const Area: TRectangle; Value: Byte): TCoverageMask;
{ Mask's values times Other's (Other is 0 outside its area). }
procedure IntersectMasks(var Mask: TCoverageMask; const Other: TCoverageMask);
function MaskValue(const Mask: TCoverageMask; X, Y: LongInt): Byte; inline;

{ Mask may be nil. }
procedure FillShapeWithPaint(const Canvas: TCanvas; const Shape: TCoverageShape; Rule: TFillRule;
  const Paint: TPaint; Opacity: Byte; Mask: PCoverageMask);
{ Layer's pixels drawn over the canvas with their top left at (X, Y)
  (surface coordinates), faded by Opacity and by Mask (may be nil). }
procedure DrawSurfaceMasked(const Canvas: TCanvas; const Layer: TSurface; X, Y: LongInt; Opacity: Byte;
  Mask: PCoverageMask);

implementation

uses
  Math,
  Drawing.Regions;

function MaskFromShape(const Shape: TCoverageShape; Rule: TFillRule; const Area: TRectangle): TCoverageMask;
begin
  Result.Area := Area;
  Result.Values := ShapeCoverageBytes(Shape, Area, Rule);
end;

function UniformMask(const Area: TRectangle; Value: Byte): TCoverageMask;
var
  Index: LongInt;
begin
  Result.Area := Area;
  Result.Values := nil;
  if RectangleIsEmpty(Area) then
    Exit;
  SetLength(Result.Values, RectangleWidth(Area) * RectangleHeight(Area));
  for Index := 0 to High(Result.Values) do
    Result.Values[Index] := Value;
end;

function MaskValue(const Mask: TCoverageMask; X, Y: LongInt): Byte;
begin
  if (X < Mask.Area.Left) or (X >= Mask.Area.Right) or (Y < Mask.Area.Top) or (Y >= Mask.Area.Bottom) or
     (Mask.Values = nil) then
    Exit(0);
  Result := Mask.Values[(Y - Mask.Area.Top) * (Mask.Area.Right - Mask.Area.Left) + X - Mask.Area.Left];
end;

procedure IntersectMasks(var Mask: TCoverageMask; const Other: TCoverageMask);
var
  X, Y: LongInt;
  Index: LongInt;
begin
  Index := 0;
  for Y := Mask.Area.Top to Mask.Area.Bottom - 1 do
    for X := Mask.Area.Left to Mask.Area.Right - 1 do
    begin
      if Mask.Values[Index] <> 0 then
        Mask.Values[Index] := (LongWord(Mask.Values[Index]) * MaskValue(Other, X, Y) + 127) div 255;
      Inc(Index);
    end;
end;

{ Coverage times opacity times mask, 0 to 255. }
function CombinedWeight(Coverage, Opacity, MaskWeight: LongWord): LongWord; inline;
begin
  Result := (Coverage * Opacity + 127) div 255;
  Result := (Result * MaskWeight + 127) div 255;
end;

procedure FillShapeWithPaint(const Canvas: TCanvas; const Shape: TCoverageShape; Rule: TFillRule;
  const Paint: TPaint; Opacity: Byte; Mask: PCoverageMask);
var
  Area: TRectangle;
  Coverage: TCoverageBytes;
  Width: LongInt;
  Row: LongInt;
  Y: LongInt;
  Index: LongInt;
  Piece: TRectangle;
  Start, Finish: LongInt;
  X: LongInt;
  Colors: array of TColor;
  Line: PLongWord;
  Weight: LongWord;
  CoverageValue: Byte;
  MaskWeight: LongWord;
  Color: TColor;
begin
  if (Shape.Count = 0) or (Opacity = 0) then
    Exit;
  if (Paint.Kind = PaintSolid) and (AlphaOf(Paint.Color) = 0) then
    Exit;
  if not IntersectRectangles(ShapeSurfaceBounds(Shape, 0, 0), RegionBounds(Canvas.Clip), Area) then
    Exit;
  if Mask <> nil then
    if not IntersectRectangles(Area, Mask^.Area, Area) then
      Exit;
  Coverage := ShapeCoverageBytes(Shape, Area, Rule);
  Width := RectangleWidth(Area);
  Colors := nil;
  SetLength(Colors, Width);
  for Row := 0 to RectangleHeight(Area) - 1 do
  begin
    Y := Area.Top + Row;
    { Skip rows the shape does not touch. }
    Start := -1;
    for X := 0 to Width - 1 do
      if Coverage[Row * Width + X] <> 0 then
      begin
        Start := X;
        Break;
      end;
    if Start < 0 then
      Continue;
    Finish := Width;
    while (Finish > Start) and (Coverage[Row * Width + Finish - 1] = 0) do
      Dec(Finish);
    PaintSpan(Paint, Y, Area.Left + Start, Finish - Start, Colors);
    Line := SurfaceLine(Canvas.Surface, Y);
    for Index := 0 to Canvas.Clip.Count - 1 do
    begin
      Piece := Canvas.Clip.Rectangles[Index];
      if (Y < Piece.Top) or (Y >= Piece.Bottom) then
        Continue;
      for X := Max(Piece.Left, Area.Left + Start) to Min(Piece.Right, Area.Left + Finish) - 1 do
      begin
        CoverageValue := Coverage[Row * Width + X - Area.Left];
        if CoverageValue = 0 then
          Continue;
        if Mask <> nil then
          MaskWeight := MaskValue(Mask^, X, Y)
        else
          MaskWeight := 255;
        Weight := CombinedWeight(CoverageValue, Opacity, MaskWeight);
        if Weight = 0 then
          Continue;
        Color := Colors[X - Area.Left - Start];
        if Weight < 255 then
          Color := FadeColor(Color, Weight);
        Line[X] := BlendColors(Line[X], Color);
      end;
    end;
  end;
end;

procedure DrawSurfaceMasked(const Canvas: TCanvas; const Layer: TSurface; X, Y: LongInt; Opacity: Byte;
  Mask: PCoverageMask);
var
  Destination: TRectangle;
  Piece: TRectangle;
  Index: LongInt;
  Row, Column: LongInt;
  SourceLine, TargetLine: PLongWord;
  Weight: LongWord;
  Color: TColor;
begin
  if Opacity = 0 then
    Exit;
  Destination := MakeRectangle(X, Y, Layer.Width, Layer.Height);
  if Mask <> nil then
    if not IntersectRectangles(Destination, Mask^.Area, Destination) then
      Exit;
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    if not IntersectRectangles(Destination, Canvas.Clip.Rectangles[Index], Piece) then
      Continue;
    for Row := Piece.Top to Piece.Bottom - 1 do
    begin
      SourceLine := SurfaceLine(Layer, Row - Y);
      TargetLine := SurfaceLine(Canvas.Surface, Row);
      for Column := Piece.Left to Piece.Right - 1 do
      begin
        Color := SourceLine[Column - X];
        if AlphaOf(Color) = 0 then
          Continue;
        if Mask <> nil then
          Weight := (LongWord(Opacity) * MaskValue(Mask^, Column, Row) + 127) div 255
        else
          Weight := Opacity;
        if Weight = 0 then
          Continue;
        if Weight < 255 then
          Color := FadeColor(Color, Weight);
        TargetLine[Column] := BlendColors(TargetLine[Column], Color);
      end;
    end;
  end;
end;

end.
