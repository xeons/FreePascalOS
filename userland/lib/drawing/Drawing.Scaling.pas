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
  Smooth scaling: a surface drawn larger or smaller with every pixel
  made from the source pixels it comes from, not just the nearest one
  (DrawSurfaceStretched), so an icon drawn for one size still looks
  right at another.

  Each direction is worked on its own. Growing, a pixel's centre falls
  between four source pixels and takes from each by how near it is
  (bilinear); at the source's edges the edge pixel goes on. Shrinking,
  a pixel stands for a stretch of source pixels and takes from each by
  how much of it lies in that stretch (area averaging), so thin lines
  fade rather than vanish. The same size is an exact copy.

  Weights are whole numbers (4096 to a direction, fine enough that
  rounding them never shows), and colours are mixed weighted by their alpha, so
  transparent pixels lend no colour to the edges of what is drawn.
}
unit Drawing.Scaling;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas;

{ SourceRectangle of Source scaled to fill Destination (canvas
  coordinates), clipped. With Blend the result is drawn over the canvas
  by its alpha; without, it replaces the canvas's pixels. }
procedure DrawSurfaceScaled(const Canvas: TCanvas; const Source: TSurface; const SourceRectangle,
  Destination: TRectangle; Blend: Boolean);

implementation

const
  WeightUnit = 4096;

type
  { For every pixel of a destination line: the source pixels it takes
    from (Count of them from First) and their weights, which start at
    Offset in Weights and add up to WeightUnit. }
  TAxisWeights = record
    First: array of LongInt;
    Count: array of LongInt;
    Offset: array of LongInt;
    Weights: array of LongInt;
    Used: LongInt;
  end;

procedure AddWeight(var Axis: TAxisWeights; Weight: LongInt);
begin
  if Axis.Used = Length(Axis.Weights) then
    SetLength(Axis.Weights, 2 * Axis.Used + 16);
  Axis.Weights[Axis.Used] := Weight;
  Inc(Axis.Used);
end;

function FloorOf(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Result > Value then
    Dec(Result);
end;

function CeilingOf(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Result < Value then
    Inc(Result);
end;

{ Shares (fractions adding up to one) as whole weights adding up to
  WeightUnit exactly: rounded, and what rounding lost or gained given
  to the largest. }
procedure AddShares(var Axis: TAxisWeights; const Shares: array of Double; Count: LongInt);
var
  Index: LongInt;
  Total: LongInt;
  Largest: LongInt;
  Start: LongInt;
begin
  Start := Axis.Used;
  Total := 0;
  Largest := Start;
  for Index := 0 to Count - 1 do
  begin
    AddWeight(Axis, Trunc(Shares[Index] * WeightUnit + 0.5));
    Total := Total + Axis.Weights[Axis.Used - 1];
    if Axis.Weights[Axis.Used - 1] > Axis.Weights[Largest] then
      Largest := Axis.Used - 1;
  end;
  Axis.Weights[Largest] := Axis.Weights[Largest] + WeightUnit - Total;
end;

{ The weights for scaling SourceLength pixels to TargetLength. }
procedure BuildAxisWeights(SourceLength, TargetLength: LongInt; out Axis: TAxisWeights);
var
  Target: LongInt;
  Scale: Double;
  Centre: Double;
  Lower: LongInt;
  Fraction: Double;
  Start: Double;
  Finish: Double;
  Pixel: LongInt;
  Overlap: Double;
  Shares: array of Double;
  Count: LongInt;
begin
  Axis.First := nil;
  Axis.Count := nil;
  Axis.Offset := nil;
  Axis.Weights := nil;
  Axis.Used := 0;
  SetLength(Axis.First, TargetLength);
  SetLength(Axis.Count, TargetLength);
  SetLength(Axis.Offset, TargetLength);
  Scale := SourceLength / TargetLength;
  Shares := nil;
  for Target := 0 to TargetLength - 1 do
  begin
    Axis.Offset[Target] := Axis.Used;
    if TargetLength >= SourceLength then
    begin
      { Growing (or the same size): between the two source pixels whose
        centres are either side of this pixel's centre. }
      Centre := (Target + 0.5) * Scale - 0.5;
      Lower := FloorOf(Centre);
      Fraction := Centre - Lower;
      if Lower < 0 then
      begin
        Lower := 0;
        Fraction := 0;
      end;
      if Lower >= SourceLength - 1 then
      begin
        Lower := SourceLength - 1;
        Fraction := 0;
      end;
      Axis.First[Target] := Lower;
      if Fraction = 0 then
      begin
        Axis.Count[Target] := 1;
        AddWeight(Axis, WeightUnit);
      end
      else
      begin
        SetLength(Shares, 2);
        Shares[0] := 1 - Fraction;
        Shares[1] := Fraction;
        Axis.Count[Target] := 2;
        AddShares(Axis, Shares, 2);
      end;
    end
    else
    begin
      { Shrinking: the source pixels under this one's stretch. }
      Start := Target * Scale;
      Finish := (Target + 1) * Scale;
      Axis.First[Target] := FloorOf(Start);
      Count := CeilingOf(Finish) - FloorOf(Start);
      if Axis.First[Target] + Count > SourceLength then
        Count := SourceLength - Axis.First[Target];
      SetLength(Shares, Count);
      for Pixel := 0 to Count - 1 do
      begin
        Overlap := Axis.First[Target] + Pixel + 1;
        if Overlap > Finish then
          Overlap := Finish;
        if Axis.First[Target] + Pixel > Start then
          Overlap := Overlap - (Axis.First[Target] + Pixel)
        else
          Overlap := Overlap - Start;
        if Overlap < 0 then
          Overlap := 0;
        Shares[Pixel] := Overlap / Scale;
      end;
      Axis.Count[Target] := Count;
      AddShares(Axis, Shares, Count);
    end;
  end;
end;

{ One destination pixel from the source pixels its weights name. }
function ScaledPixel(const Source: TSurface; const Across, Down: TAxisWeights; Column, Row, SourceLeft,
  SourceTop: LongInt): TColor;
var
  Vertical: LongInt;
  Horizontal: LongInt;
  Weight: Int64;
  Pixel: TColor;
  Alpha: Int64;
  SumAlpha: Int64;
  SumRed: Int64;
  SumGreen: Int64;
  SumBlue: Int64;
  Line: PLongWord;
begin
  SumAlpha := 0;
  SumRed := 0;
  SumGreen := 0;
  SumBlue := 0;
  for Vertical := 0 to Down.Count[Row] - 1 do
  begin
    Line := SurfaceLine(Source, SourceTop + Down.First[Row] + Vertical);
    for Horizontal := 0 to Across.Count[Column] - 1 do
    begin
      Weight := Int64(Down.Weights[Down.Offset[Row] + Vertical]) * Across.Weights[Across.Offset[Column] + Horizontal];
      if Weight = 0 then
        Continue;
      Pixel := Line[SourceLeft + Across.First[Column] + Horizontal];
      Alpha := AlphaOf(Pixel);
      SumAlpha := SumAlpha + Weight * Alpha;
      SumRed := SumRed + Weight * Alpha * RedOf(Pixel);
      SumGreen := SumGreen + Weight * Alpha * GreenOf(Pixel);
      SumBlue := SumBlue + Weight * Alpha * BlueOf(Pixel);
    end;
  end;
  if SumAlpha = 0 then
    Exit(ColorTransparent);
  Result := ArgbColor((SumAlpha + WeightUnit * WeightUnit div 2) div (WeightUnit * WeightUnit),
    (SumRed + SumAlpha div 2) div SumAlpha, (SumGreen + SumAlpha div 2) div SumAlpha,
    (SumBlue + SumAlpha div 2) div SumAlpha);
end;

procedure DrawSurfaceScaled(const Canvas: TCanvas; const Source: TSurface; const SourceRectangle,
  Destination: TRectangle; Blend: Boolean);
var
  From: TRectangle;
  Target: TRectangle;
  Piece: TRectangle;
  Across: TAxisWeights;
  Down: TAxisWeights;
  Index: LongInt;
  Row: LongInt;
  Column: LongInt;
  TargetLine: PLongWord;
  Pixel: TColor;
begin
  if not IntersectRectangles(SourceRectangle, SurfaceBounds(Source), From) or RectangleIsEmpty(Destination) then
    Exit;
  Target := OffsetRectangle(Destination, Canvas.OriginX, Canvas.OriginY);
  BuildAxisWeights(RectangleWidth(From), RectangleWidth(Target), Across);
  BuildAxisWeights(RectangleHeight(From), RectangleHeight(Target), Down);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    if not IntersectRectangles(Target, Canvas.Clip.Rectangles[Index], Piece) then
      Continue;
    for Row := Piece.Top to Piece.Bottom - 1 do
    begin
      TargetLine := SurfaceLine(Canvas.Surface, Row);
      for Column := Piece.Left to Piece.Right - 1 do
      begin
        Pixel := ScaledPixel(Source, Across, Down, Column - Target.Left, Row - Target.Top, From.Left, From.Top);
        if Blend then
          TargetLine[Column] := BlendColors(TargetLine[Column], Pixel)
        else
          TargetLine[Column] := Pixel;
      end;
    end;
  end;
end;

end.
