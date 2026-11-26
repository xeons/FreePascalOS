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
  VP8 motion compensation (RFC 6386 section 18): a block of a reference
  picture at a motion vector's whole pixel position, filtered to the
  vector's eighth pixel fraction with the six tap filters (version 0) or
  bilinearly (versions 1 to 3); horizontally first, then vertically,
  each pass rounded and clamped to 0..255.

  A pass whose fraction is 0 is the identity (its filter is 128 at the
  centre), so it is left out.
}
unit Vp8.InterPrediction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Predicts the Width x Height block at Target from Source (the
  reference's pixel at the vector's whole pixel position) with the
  fractions FractionX and FractionY (0..7). }
procedure PredictInterBlock(Source: PByte; SourceStride: LongInt;
  FractionX, FractionY: LongInt; Target: PByte; TargetStride: LongInt;
  Width, Height: LongInt; Bilinear: Boolean);

implementation

const
  SixTapFilters: array[0..7, 0..5] of LongInt = (
    (0, 0, 128, 0, 0, 0),
    (0, -6, 123, 12, -1, 0),
    (2, -11, 108, 36, -8, 1),
    (0, -9, 93, 50, -6, 0),
    (3, -16, 77, 77, -16, 3),
    (0, -6, 50, 93, -9, 0),
    (1, -8, 36, 108, -11, 2),
    (0, -1, 12, 123, -6, 0));
  BilinearFilters: array[0..7, 0..1] of LongInt = (
    (128, 0), (112, 16), (96, 32), (80, 48), (64, 64), (48, 80), (32, 96), (16, 112));

  { The largest block (16x16) with the rows the vertical pass needs. }
  TemporarySize = 16 * (16 + 5);

function ClampPixel(Value: LongInt): Byte; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

procedure CopyBlock(Source: PByte; SourceStride: LongInt; Target: PByte;
  TargetStride, Width, Height: LongInt);
var
  Row: LongInt;
begin
  for Row := 0 to Height - 1 do
    Move(Source[Row * SourceStride], Target[Row * TargetStride], Width);
end;

{ One six tap pass: Step is 1 (horizontal) or the stride (vertical). }
procedure SixTapPass(Source: PByte; SourceStride: LongInt; Step: LongInt;
  Target: PByte; TargetStride, Width, Height, Fraction: LongInt);
var
  Row, Column: LongInt;
  F0, F1, F2, F3, F4, F5: LongInt;
  S: PByte;
begin
  F0 := SixTapFilters[Fraction, 0];
  F1 := SixTapFilters[Fraction, 1];
  F2 := SixTapFilters[Fraction, 2];
  F3 := SixTapFilters[Fraction, 3];
  F4 := SixTapFilters[Fraction, 4];
  F5 := SixTapFilters[Fraction, 5];
  for Row := 0 to Height - 1 do
  begin
    S := Source + Row * SourceStride;
    for Column := 0 to Width - 1 do
    begin
      Target[Row * TargetStride + Column] := ClampPixel(SarLongint(
        S[Column - 2 * Step] * F0 + S[Column - Step] * F1 + S[Column] * F2 +
        S[Column + Step] * F3 + S[Column + 2 * Step] * F4 + S[Column + 3 * Step] * F5 + 64, 7));
    end;
  end;
end;

procedure BilinearPass(Source: PByte; SourceStride: LongInt; Step: LongInt;
  Target: PByte; TargetStride, Width, Height, Fraction: LongInt);
var
  Row, Column: LongInt;
  F0, F1: LongInt;
  S: PByte;
begin
  F0 := BilinearFilters[Fraction, 0];
  F1 := BilinearFilters[Fraction, 1];
  for Row := 0 to Height - 1 do
  begin
    S := Source + Row * SourceStride;
    for Column := 0 to Width - 1 do
      Target[Row * TargetStride + Column] := (S[Column] * F0 + S[Column + Step] * F1 + 64) shr 7;
  end;
end;

procedure PredictInterBlock(Source: PByte; SourceStride: LongInt;
  FractionX, FractionY: LongInt; Target: PByte; TargetStride: LongInt;
  Width, Height: LongInt; Bilinear: Boolean);
var
  Temporary: array[0..TemporarySize - 1] of Byte;
begin
  if (FractionX = 0) and (FractionY = 0) then
  begin
    CopyBlock(Source, SourceStride, Target, TargetStride, Width, Height);
    Exit;
  end;
  if Bilinear then
  begin
    if FractionY = 0 then
      BilinearPass(Source, SourceStride, 1, Target, TargetStride, Width, Height, FractionX)
    else if FractionX = 0 then
      BilinearPass(Source, SourceStride, SourceStride, Target, TargetStride, Width, Height, FractionY)
    else
    begin
      BilinearPass(Source, SourceStride, 1, @Temporary[0], Width, Width, Height + 1, FractionX);
      BilinearPass(@Temporary[0], Width, Width, Target, TargetStride, Width, Height, FractionY);
    end;
  end
  else
  begin
    if FractionY = 0 then
      SixTapPass(Source, SourceStride, 1, Target, TargetStride, Width, Height, FractionX)
    else if FractionX = 0 then
      SixTapPass(Source, SourceStride, SourceStride, Target, TargetStride, Width, Height, FractionY)
    else
    begin
      SixTapPass(Source - 2 * SourceStride, SourceStride, 1, @Temporary[0], Width, Width,
        Height + 5, FractionX);
      SixTapPass(@Temporary[2 * Width], Width, Width, Target, TargetStride, Width, Height, FractionY);
    end;
  end;
end;

end.
