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

  The two directions are applied one after the other: each source line
  is scaled across once into sums of weighted, premultiplied channels,
  and each destination line sums those of the lines it takes from, so
  a pixel costs the weights of one direction plus the other's, not
  their product. The sums are whole and exact, so the result is the
  same as weighting every source pixel by both at once.
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

uses
  Drawing.SpanBlending;

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

type
  { A source line scaled across, at one destination column: the sum of
    weight x alpha over the source pixels the column takes from, and of
    weight x alpha x each channel (premultiplied, so transparent pixels
    lend no colour). At most 255 x 255 x WeightUnit: they fit. }
  TAcrossSums = record
    Alpha: LongWord;
    Red: LongWord;
    Green: LongWord;
    Blue: LongWord;
  end;
  PAcrossSums = ^TAcrossSums;
  PPAcrossSums = ^PAcrossSums;

  { Source lines scaled across for one piece of the destination: Width
    columns from FirstColumn (of the destination line), for the last
    Capacity source lines asked for, a line in slot Line mod Capacity.
    The source lines a destination line takes from only move down the
    source as the destination lines do, and there are at most Capacity
    of them, so each source line is scaled across once. }
  TAcrossCache = record
    Sums: array of TAcrossSums;
    LineInSlot: array of LongInt;
    { The lines one destination line takes from (ScaleLineDown's). }
    LinesTaken: array of PAcrossSums;
    Capacity: LongInt;
    Width: LongInt;
    FirstColumn: LongInt;
  end;

{ The source lines the destination lines First to Last take from, at
  most, for any one of them. }
function MostLinesTaken(const Down: TAxisWeights; First, Last: LongInt): LongInt;
var
  Row: LongInt;
begin
  Result := 1;
  for Row := First to Last do
    if Down.Count[Row] > Result then
      Result := Down.Count[Row];
end;

procedure BeginAcrossCache(out Cache: TAcrossCache; Capacity, Width, FirstColumn: LongInt);
var
  Slot: LongInt;
begin
  Cache.Sums := nil;
  Cache.LineInSlot := nil;
  Cache.LinesTaken := nil;
  SetLength(Cache.Sums, Capacity * Width);
  SetLength(Cache.LineInSlot, Capacity);
  SetLength(Cache.LinesTaken, Capacity);
  for Slot := 0 to Capacity - 1 do
    Cache.LineInSlot[Slot] := -1;
  Cache.Capacity := Capacity;
  Cache.Width := Width;
  Cache.FirstColumn := FirstColumn;
end;

{ SourceLine (from the source rectangle's left) scaled across into Width
  sums, for the destination columns from FirstColumn. }
procedure ScaleLineAcross(SourceLine: PLongWord; const Across: TAxisWeights; FirstColumn, Width: LongInt;
  Sums: PAcrossSums);
var
  Index: LongInt;
  Column: LongInt;
  Taken: LongInt;
  Weights: PLongInt;
  Pixels: PLongWord;
  Pixel: LongWord;
  Weighted: LongWord;
  Total: TAcrossSums;
begin
  for Index := 0 to Width - 1 do
  begin
    Column := FirstColumn + Index;
    Weights := @Across.Weights[Across.Offset[Column]];
    Pixels := SourceLine + Across.First[Column];
    Total.Alpha := 0;
    Total.Red := 0;
    Total.Green := 0;
    Total.Blue := 0;
    for Taken := 0 to Across.Count[Column] - 1 do
    begin
      Pixel := Pixels[Taken];
      if Pixel <= $00FFFFFF then
        Continue;
      Weighted := LongWord(Weights[Taken]) * AlphaOf(Pixel);
      Inc(Total.Alpha, Weighted);
      Inc(Total.Red, Weighted * RedOf(Pixel));
      Inc(Total.Green, Weighted * GreenOf(Pixel));
      Inc(Total.Blue, Weighted * BlueOf(Pixel));
    end;
    Sums[Index] := Total;
  end;
end;

{ Source line Line (of the source rectangle) scaled across, from the
  cache or made now. }
function LineAcross(var Cache: TAcrossCache; const Source: TSurface; const From: TRectangle;
  const Across: TAxisWeights; Line: LongInt): PAcrossSums;
var
  Slot: LongInt;
begin
  Slot := Line mod Cache.Capacity;
  Result := @Cache.Sums[Slot * Cache.Width];
  if Cache.LineInSlot[Slot] <> Line then
  begin
    ScaleLineAcross(SurfaceLine(Source, From.Top + Line) + From.Left, Across, Cache.FirstColumn, Cache.Width,
      Result);
    Cache.LineInSlot[Slot] := Line;
  end;
end;

{ (Sum + Divisor div 2) div Divisor, both positive, from Reciprocal (1 /
  Divisor): the floating point quotient, put right by a step either way
  where its rounding lands on the wrong side, so the result is exact. }
function RoundedQuotient(Sum, Divisor: Int64; Reciprocal: Double): Int64; inline;
var
  Remainder: Int64;
begin
  Result := Trunc(Sum * Reciprocal + 0.5);
  Remainder := Sum + Divisor div 2 - Result * Divisor;
  if Remainder < 0 then
    Dec(Result)
  else if Remainder >= Divisor then
    Inc(Result);
end;

{ Sums over WeightUnit x WeightUnit of alpha and of alpha x a channel,
  back as a colour: the alpha rounded, each channel divided by its
  share of the alpha, rounded, with one division for all three. }
function UnpremultipliedColor(SumAlpha, SumRed, SumGreen, SumBlue: Int64): TColor; inline;
var
  Reciprocal: Double;
begin
  if SumAlpha = 0 then
    Exit(ColorTransparent);
  Reciprocal := 1 / SumAlpha;
  Result := (TColor((SumAlpha + WeightUnit * WeightUnit div 2) div (WeightUnit * WeightUnit)) shl 24) or
    (TColor(RoundedQuotient(SumRed, SumAlpha, Reciprocal)) shl 16) or
    (TColor(RoundedQuotient(SumGreen, SumAlpha, Reciprocal)) shl 8) or
    TColor(RoundedQuotient(SumBlue, SumAlpha, Reciprocal));
end;

{ Destination line Row (of the destination rectangle) for the cache's
  columns: the scaled-across source lines it takes from, weighted down
  and summed, into Output. }
procedure ScaleLineDown(var Cache: TAcrossCache; const Source: TSurface; const From: TRectangle; const Across,
  Down: TAxisWeights; Row: LongInt; Output: PLongWord);
var
  Lines: PPAcrossSums;
  Weights: PLongInt;
  Taken: LongInt;
  Index: LongInt;
  Weight: Int64;
  SumAlpha: Int64;
  SumRed: Int64;
  SumGreen: Int64;
  SumBlue: Int64;
begin
  Lines := @Cache.LinesTaken[0];
  for Taken := 0 to Down.Count[Row] - 1 do
    Lines[Taken] := LineAcross(Cache, Source, From, Across, Down.First[Row] + Taken);
  Weights := @Down.Weights[Down.Offset[Row]];
  for Index := 0 to Cache.Width - 1 do
  begin
    SumAlpha := 0;
    SumRed := 0;
    SumGreen := 0;
    SumBlue := 0;
    for Taken := 0 to Down.Count[Row] - 1 do
    begin
      Weight := Weights[Taken];
      SumAlpha := SumAlpha + Weight * Lines[Taken][Index].Alpha;
      SumRed := SumRed + Weight * Lines[Taken][Index].Red;
      SumGreen := SumGreen + Weight * Lines[Taken][Index].Green;
      SumBlue := SumBlue + Weight * Lines[Taken][Index].Blue;
    end;
    Output[Index] := UnpremultipliedColor(SumAlpha, SumRed, SumGreen, SumBlue);
  end;
end;

{ Piece (surface coordinates, within Target) of the scaled source drawn,
  line by line. }
procedure DrawScaledPiece(const Canvas: TCanvas; const Source: TSurface; const From, Target, Piece: TRectangle;
  const Across, Down: TAxisWeights; Blend: Boolean);
var
  Cache: TAcrossCache;
  Output: array of TColor;
  Width: LongInt;
  Row: LongInt;
  TargetLine: PLongWord;
begin
  Width := RectangleWidth(Piece);
  BeginAcrossCache(Cache, MostLinesTaken(Down, Piece.Top - Target.Top, Piece.Bottom - 1 - Target.Top), Width,
    Piece.Left - Target.Left);
  Output := nil;
  SetLength(Output, Width);
  for Row := Piece.Top to Piece.Bottom - 1 do
  begin
    ScaleLineDown(Cache, Source, From, Across, Down, Row - Target.Top, @Output[0]);
    TargetLine := SurfaceLine(Canvas.Surface, Row) + Piece.Left;
    if Blend then
      BlendPixelSpan(TargetLine, @Output[0], Width)
    else
      Move(Output[0], TargetLine^, Width * SizeOf(TColor));
  end;
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
begin
  if not IntersectRectangles(SourceRectangle, SurfaceBounds(Source), From) or RectangleIsEmpty(Destination) then
    Exit;
  Target := OffsetRectangle(Destination, Canvas.OriginX, Canvas.OriginY);
  BuildAxisWeights(RectangleWidth(From), RectangleWidth(Target), Across);
  BuildAxisWeights(RectangleHeight(From), RectangleHeight(Target), Down);
  for Index := 0 to Canvas.Clip.Count - 1 do
    if IntersectRectangles(Target, Canvas.Clip.Rectangles[Index], Piece) then
      DrawScaledPiece(Canvas, Source, From, Target, Piece, Across, Down, Blend);
end;

end.
