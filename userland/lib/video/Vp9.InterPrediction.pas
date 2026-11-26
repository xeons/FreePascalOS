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
  VP9 motion compensation (section 8.5.2 of the VP9 specification): a
  block of a reference picture at a motion vector's position, filtered
  to the vector's sixteenth of a pixel with 8-tap kernels, horizontally
  into an intermediate block then vertically; from a reference of
  another size, scaled with fixed point steps. A compound block averages
  the predictions from two references.

  Where the block (with the filter's taps) reaches outside the
  reference, the reference's edge pixels are repeated into a scratch
  block first. The positions and the scratch block are computed exactly
  as the reference decoder (libvpx) computes them.
}
unit Vp9.InterPrediction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Vp9.FilterTables, Vp9.ModeInfo, Vp9.Pictures;

const
  ReferenceScaleShift = 14;
  NoScale = 1 shl ReferenceScaleShift;
  ScratchSize = 160 * 160;

type
  TVp9ScaleFactors = record
    XScale, YScale: LongInt;
    XStep, YStep: LongInt;
    Valid: Boolean;
    Scaled: Boolean;
  end;

  { Per-thread room for motion compensation. }
  TVp9PredictionScratch = record
    Border: array[0..ScratchSize - 1] of Word;
    Intermediate: array[0..64 * 135 - 1] of Word;
    Average: array[0..64 * 64 - 1] of Word;
  end;
  PVp9PredictionScratch = ^TVp9PredictionScratch;

  { A block to predict in one plane. }
  TVp9InterBlock = record
    Plane: LongInt;
    SubsamplingX, SubsamplingY: LongInt;
    { The plane block's size in pixels (for the vector clamp). }
    BlockWidth, BlockHeight: LongInt;
    { The part predicted: offset in the block and size. }
    X, Y, Width, Height: LongInt;
    { The block's luma position in pixels. }
    LumaX, LumaY: LongInt;
    { Distances to the frame's edges in eighth luma pixels. }
    ToLeft, ToRight, ToTop, ToBottom: LongInt;
    Target: PWord;
    TargetStride: LongInt;
    BitDepth: LongInt;
  end;

{ Scale factors from a reference of OtherWidth x OtherHeight to a frame
  of ThisWidth x ThisHeight. }
procedure SetupScaleFactors(out Scale: TVp9ScaleFactors; OtherWidth, OtherHeight, ThisWidth, ThisHeight: LongInt);

{ Predicts Block from Reference with motion vector Mv (eighth luma
  pixels), averaging with what Block.Target holds when Average. }
procedure PredictInterBlock(constref Block: TVp9InterBlock; Reference: TVp9Picture;
  constref Scale: TVp9ScaleFactors; Kernel: PVp9Kernel; Mv: TVp9Mv; Average: Boolean;
  Scratch: PVp9PredictionScratch);

implementation

const
  SubpelBits = 4;
  SubpelMask = 15;
  InterpolationExtend = 4;

function ScaledX(Value: LongInt; constref Scale: TVp9ScaleFactors): LongInt; inline;
begin
  Result := LongInt(SarInt64(Int64(Value) * Scale.XScale, ReferenceScaleShift));
end;

function ScaledY(Value: LongInt; constref Scale: TVp9ScaleFactors): LongInt; inline;
begin
  Result := LongInt(SarInt64(Int64(Value) * Scale.YScale, ReferenceScaleShift));
end;

procedure SetupScaleFactors(out Scale: TVp9ScaleFactors; OtherWidth, OtherHeight, ThisWidth, ThisHeight: LongInt);
begin
  Scale := Default(TVp9ScaleFactors);
  Scale.Valid := (2 * ThisWidth >= OtherWidth) and (2 * ThisHeight >= OtherHeight) and
    (ThisWidth <= 16 * OtherWidth) and (ThisHeight <= 16 * OtherHeight);
  if not Scale.Valid then
    Exit;
  Scale.XScale := (OtherWidth shl ReferenceScaleShift) div ThisWidth;
  Scale.YScale := (OtherHeight shl ReferenceScaleShift) div ThisHeight;
  Scale.XStep := ScaledX(16, Scale);
  Scale.YStep := ScaledY(16, Scale);
  Scale.Scaled := (Scale.XScale <> NoScale) or (Scale.YScale <> NoScale);
end;

function ClampValue(Value, Low, High: LongInt): LongInt; inline;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function ClampSample(Value, Maximum: LongInt): Word; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > Maximum then
    Result := Maximum
  else
    Result := Value;
end;

procedure ConvolveHorizontal(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride: LongInt;
  Kernel: PVp9Kernel; X0, XStep, Width, Height, Maximum: LongInt);
var
  Row, Column, Position, Tap, Sum: LongInt;
  S: PWord;
  F: PSmallInt;
begin
  Dec(Source, 3);
  for Row := 0 to Height - 1 do
  begin
    Position := X0;
    for Column := 0 to Width - 1 do
    begin
      S := Source + (Position shr SubpelBits);
      F := @Kernel^[Position and SubpelMask, 0];
      Sum := 0;
      for Tap := 0 to 7 do
        Inc(Sum, LongInt(S[Tap]) * F[Tap]);
      Target[Column] := ClampSample(SarLongint(Sum + 64, 7), Maximum);
      Inc(Position, XStep);
    end;
    Inc(Source, SourceStride);
    Inc(Target, TargetStride);
  end;
end;

procedure ConvolveVertical(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride: LongInt;
  Kernel: PVp9Kernel; Y0, YStep, Width, Height, Maximum: LongInt);
var
  Row, Column, Position, Tap, Sum: LongInt;
  S: PWord;
  F: PSmallInt;
begin
  Dec(Source, 3 * SourceStride);
  for Column := 0 to Width - 1 do
  begin
    Position := Y0;
    for Row := 0 to Height - 1 do
    begin
      S := Source + (Position shr SubpelBits) * SourceStride + Column;
      F := @Kernel^[Position and SubpelMask, 0];
      Sum := 0;
      for Tap := 0 to 7 do
        Inc(Sum, LongInt(S[Tap * SourceStride]) * F[Tap]);
      Target[Row * TargetStride + Column] := ClampSample(SarLongint(Sum + 64, 7), Maximum);
      Inc(Position, YStep);
    end;
  end;
end;

procedure CopyBlock(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride, Width, Height: LongInt);
var
  Row: LongInt;
begin
  for Row := 0 to Height - 1 do
    Move(Source[Row * SourceStride], Target[Row * TargetStride], Width * 2);
end;

procedure AverageInto(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride, Width, Height: LongInt);
var
  Row, Column: LongInt;
begin
  for Row := 0 to Height - 1 do
    for Column := 0 to Width - 1 do
      Target[Row * TargetStride + Column] :=
        (LongInt(Target[Row * TargetStride + Column]) + Source[Row * SourceStride + Column] + 1) shr 1;
end;

{ The prediction filter: horizontal when the position steps or has a
  fraction, vertical likewise, both through the intermediate block. }
procedure Convolve(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride: LongInt;
  Kernel: PVp9Kernel; X0, XStep, Y0, YStep, Width, Height, Maximum: LongInt; Average: Boolean;
  Scratch: PVp9PredictionScratch);
var
  Horizontal, Vertical: Boolean;
  Output: PWord;
  OutputStride, IntermediateHeight: LongInt;
begin
  Horizontal := (XStep <> 16) or (X0 <> 0);
  Vertical := (YStep <> 16) or (Y0 <> 0);
  if Average then
  begin
    Output := @Scratch^.Average[0];
    OutputStride := 64;
  end
  else
  begin
    Output := Target;
    OutputStride := TargetStride;
  end;
  if Horizontal and Vertical then
  begin
    IntermediateHeight := ((((Height - 1) * YStep + Y0) shr SubpelBits)) + 8;
    ConvolveHorizontal(Source - 3 * SourceStride, SourceStride, @Scratch^.Intermediate[0], 64, Kernel,
      X0, XStep, Width, IntermediateHeight, Maximum);
    ConvolveVertical(@Scratch^.Intermediate[3 * 64], 64, Output, OutputStride, Kernel, Y0, YStep,
      Width, Height, Maximum);
  end
  else if Horizontal then
    ConvolveHorizontal(Source, SourceStride, Output, OutputStride, Kernel, X0, XStep, Width, Height, Maximum)
  else if Vertical then
    ConvolveVertical(Source, SourceStride, Output, OutputStride, Kernel, Y0, YStep, Width, Height, Maximum)
  else if not Average then
    CopyBlock(Source, SourceStride, Target, TargetStride, Width, Height)
  else
  begin
    AverageInto(Source, SourceStride, Target, TargetStride, Width, Height);
    Exit;
  end;
  if Average then
    AverageInto(Output, OutputStride, Target, TargetStride, Width, Height);
end;

{ Copies the BorderWidth x BorderHeight block at (X, Y) of a plane of
  Width x Height into Target, repeating the edge pixels where the block
  is outside. }
procedure BuildBorder(Source: PWord; SourceStride: LongInt; Target: PWord; TargetStride: LongInt;
  X, Y, BorderWidth, BorderHeight, Width, Height: LongInt);
var
  Row: PWord;
  Left, Right, Copy, Line: LongInt;
begin
  Row := Source;
  if Y >= Height then
    Inc(Row, (Height - 1) * SourceStride)
  else if Y > 0 then
    Inc(Row, Y * SourceStride);
  for Line := 0 to BorderHeight - 1 do
  begin
    Right := 0;
    if X < 0 then
      Left := -X
    else
      Left := 0;
    if Left > BorderWidth then
      Left := BorderWidth;
    if X + BorderWidth > Width then
      Right := X + BorderWidth - Width;
    if Right > BorderWidth then
      Right := BorderWidth;
    Copy := BorderWidth - Left - Right;
    if Left > 0 then
      FillWord(Target^, Left, Row[0]);
    if Copy > 0 then
      Move(Row[X + Left], Target[Left], Copy * 2);
    if Right > 0 then
      FillWord(Target[Left + Copy], Right, Row[Width - 1]);
    Inc(Target, TargetStride);
    Inc(Y);
    if (Y > 0) and (Y < Height) then
      Inc(Row, SourceStride);
  end;
end;

procedure PredictInterBlock(constref Block: TVp9InterBlock; Reference: TVp9Picture;
  constref Scale: TVp9ScaleFactors; Kernel: PVp9Kernel; Mv: TVp9Mv; Average: Boolean;
  Scratch: PVp9PredictionScratch);
var
  Plane: PVp9Plane;
  FrameWidth, FrameHeight, Stride: LongInt;
  X0, Y0, X0_16, Y0_16, X1, Y1, XStart, YStart, XStep, YStep: LongInt;
  ScaledRow, ScaledCol, SubpelX, SubpelY: LongInt;
  ClampedRow, ClampedCol, SpelLeft, SpelRight, SpelTop, SpelBottom: LongInt;
  XOffset, YOffset: LongInt;
  XPad, YPad, BorderWidth, BorderHeight: LongInt;
  Source: PWord;
  Maximum: LongInt;
begin
  Plane := @Reference.Planes[Block.Plane];
  FrameWidth := Plane^.CropWidth;
  FrameHeight := Plane^.CropHeight;
  Stride := Plane^.Stride;
  Maximum := (1 shl Block.BitDepth) - 1;
  if Scale.Scaled then
  begin
    SpelLeft := (InterpolationExtend + Block.BlockWidth) shl SubpelBits;
    SpelRight := SpelLeft - 16;
    SpelTop := (InterpolationExtend + Block.BlockHeight) shl SubpelBits;
    SpelBottom := SpelTop - 16;
    ClampedRow := SmallInt(Mv.Row * (1 shl (1 - Block.SubsamplingY)));
    ClampedCol := SmallInt(Mv.Col * (1 shl (1 - Block.SubsamplingX)));
    ClampedCol := ClampValue(ClampedCol, Block.ToLeft * (1 shl (1 - Block.SubsamplingX)) - SpelLeft,
      Block.ToRight * (1 shl (1 - Block.SubsamplingX)) + SpelRight);
    ClampedRow := ClampValue(ClampedRow, Block.ToTop * (1 shl (1 - Block.SubsamplingY)) - SpelTop,
      Block.ToBottom * (1 shl (1 - Block.SubsamplingY)) + SpelBottom);
    XStart := SarLongint(-Block.ToLeft, 3 + Block.SubsamplingX);
    YStart := SarLongint(-Block.ToTop, 3 + Block.SubsamplingY);
    X0_16 := ScaledX((XStart + Block.X) shl SubpelBits, Scale);
    Y0_16 := ScaledY((YStart + Block.Y) shl SubpelBits, Scale);
    X0 := ScaledX(XStart + Block.X, Scale);
    Y0 := ScaledY(YStart + Block.Y, Scale);
    XOffset := ScaledX((Block.LumaX + Block.X) shl SubpelBits, Scale) and SubpelMask;
    YOffset := ScaledY((Block.LumaY + Block.Y) shl SubpelBits, Scale) and SubpelMask;
    ScaledRow := ScaledY(ClampedRow, Scale) + YOffset;
    ScaledCol := ScaledX(ClampedCol, Scale) + XOffset;
    XStep := Scale.XStep;
    YStep := Scale.YStep;
  end
  else
  begin
    X0 := SarLongint(-Block.ToLeft, 3 + Block.SubsamplingX) + Block.X;
    Y0 := SarLongint(-Block.ToTop, 3 + Block.SubsamplingY) + Block.Y;
    X0_16 := X0 shl SubpelBits;
    Y0_16 := Y0 shl SubpelBits;
    ScaledRow := Mv.Row * (1 shl (1 - Block.SubsamplingY));
    ScaledCol := Mv.Col * (1 shl (1 - Block.SubsamplingX));
    XStep := 16;
    YStep := 16;
  end;
  SubpelX := ScaledCol and SubpelMask;
  SubpelY := ScaledRow and SubpelMask;
  Inc(X0, SarLongint(ScaledCol, SubpelBits));
  Inc(Y0, SarLongint(ScaledRow, SubpelBits));
  Inc(X0_16, ScaledCol);
  Inc(Y0_16, ScaledRow);
  Source := Plane^.Origin + PtrInt(Y0) * Stride + X0;
  if Scale.Scaled or (ScaledCol <> 0) or (ScaledRow <> 0) or ((FrameWidth and 7) <> 0) or
    ((FrameHeight and 7) <> 0) then
  begin
    Y1 := SarLongint(Y0_16 + (Block.Height - 1) * YStep, SubpelBits) + 1;
    X1 := SarLongint(X0_16 + (Block.Width - 1) * XStep, SubpelBits) + 1;
    XPad := 0;
    YPad := 0;
    if (SubpelX <> 0) or (Scale.Scaled and (Scale.XStep <> 16)) then
    begin
      Dec(X0, InterpolationExtend - 1);
      Inc(X1, InterpolationExtend);
      XPad := 1;
    end;
    if (SubpelY <> 0) or (Scale.Scaled and (Scale.YStep <> 16)) then
    begin
      Dec(Y0, InterpolationExtend - 1);
      Inc(Y1, InterpolationExtend);
      YPad := 1;
    end;
    if (X0 < 0) or (X0 > FrameWidth - 1) or (X1 < 0) or (X1 > FrameWidth - 1) or
      (Y0 < 0) or (Y0 > FrameHeight - 1) or (Y1 < 0) or (Y1 > FrameHeight - 1) then
    begin
      BorderWidth := X1 - X0 + 1;
      BorderHeight := Y1 - Y0 + 1;
      if (BorderWidth > 160) or (BorderHeight > 160) or (BorderWidth * BorderHeight > ScratchSize) then
        Exit;
      BuildBorder(Plane^.Origin, Stride, @Scratch^.Border[0], BorderWidth, X0, Y0, BorderWidth, BorderHeight,
        FrameWidth, FrameHeight);
      Convolve(@Scratch^.Border[YPad * 3 * BorderWidth + XPad * 3], BorderWidth, Block.Target,
        Block.TargetStride, Kernel, SubpelX, XStep, SubpelY, YStep, Block.Width, Block.Height, Maximum,
        Average, Scratch);
      Exit;
    end;
  end;
  Convolve(Source, Stride, Block.Target, Block.TargetStride, Kernel, SubpelX, XStep, SubpelY, YStep,
    Block.Width, Block.Height, Maximum, Average, Scratch);
end;

end.
