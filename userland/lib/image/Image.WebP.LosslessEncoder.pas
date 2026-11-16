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
  A simple VP8L encoder: green is subtracted from red and blue, then
  each 16x16 tile is predicted by whichever of the fourteen predictors
  leaves the smallest residuals, and the residuals (and the tiles'
  modes, a sub-image of their own) are written with LZ77 and one group
  of prefix codes. No colour cache, palette or colour transform: the
  files are larger than libwebp's, never wrong.
}
unit Image.WebP.LosslessEncoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors;

const
  MaximumLosslessSide = 16384;

{ The VP8L stream (a VP8L chunk's payload) of Width x Height ARGB
  pixels; sides above 16384 are unsupported. }
function EncodeLosslessStream(Pixels: PLongWord; Width, Height: LongInt): TBytes;

implementation

uses
  Image.WebP.LosslessBitWriter,
  Image.WebP.LosslessTransforms,
  Image.WebP.PrefixCodeWriting,
  Image.WebP.BackwardReferences;

const
  LosslessSignature = $2F;
  PredictorBits = 4;
  PredictorModes = 14;
  LiteralCodes = 256;
  LengthCodes = 24;
  DistanceCodes = 40;

type
  TPixelBuffer = array of LongWord;

{ How costly a residual is: the sum of its channels' distances from 0
  (as signed bytes). }
function ResidualCost(Residual: LongWord): LongInt; inline;
var
  Shift: LongInt;
  Value: LongInt;
begin
  Result := 0;
  Shift := 0;
  while Shift < 32 do
  begin
    Value := (Residual shr Shift) and $FF;
    if Value > 128 then
      Value := 256 - Value;
    Inc(Result, Value);
    Inc(Shift, 8);
  end;
end;

{ The prediction of the pixel at (X, Y) by Mode, with the decoder's
  rules for the first line and column. }
function Prediction(Pixels: PLongWord; Width, X, Y, Mode: LongInt): LongWord; inline;
var
  Line: PLongWord;
  Above: PLongWord;
begin
  if (X = 0) and (Y = 0) then
    Exit($FF000000);
  Line := Pixels + PtrInt(Y) * Width;
  if Y = 0 then
    Exit(Line[X - 1]);
  Above := Line - Width;
  if X = 0 then
    Exit(Above[0]);
  Result := PredictPixel(Mode, Line[X - 1], Above[X], Above[X - 1], Above[X + 1]);
end;

function BestTileMode(Pixels: PLongWord; Width, Height, TileX, TileY: LongInt): LongInt;
var
  Mode: LongInt;
  Cost: Int64;
  BestCost: Int64;
  X: LongInt;
  Y: LongInt;
  Left: LongInt;
  Top: LongInt;
  Right: LongInt;
  Bottom: LongInt;
begin
  Left := TileX shl PredictorBits;
  Top := TileY shl PredictorBits;
  Right := Left + (1 shl PredictorBits);
  Bottom := Top + (1 shl PredictorBits);
  if Right > Width then
    Right := Width;
  if Bottom > Height then
    Bottom := Height;
  Result := 1;
  BestCost := High(Int64);
  for Mode := 0 to PredictorModes - 1 do
  begin
    Cost := 0;
    for Y := Top to Bottom - 1 do
      for X := Left to Right - 1 do
        Inc(Cost, ResidualCost(SubtractPixels(Pixels[PtrInt(Y) * Width + X], Prediction(Pixels, Width, X, Y, Mode))));
    if Cost < BestCost then
    begin
      BestCost := Cost;
      Result := Mode;
    end;
  end;
end;

{ The tiles' modes (as sub-image pixels, the mode in green) and the
  residuals of Pixels. }
procedure ApplyPredictor(Pixels: PLongWord; Width, Height: LongInt; out Modes: TPixelBuffer;
  out Residuals: TPixelBuffer);
var
  TilesX: LongInt;
  TilesY: LongInt;
  TileX: LongInt;
  TileY: LongInt;
  X: LongInt;
  Y: LongInt;
  Mode: LongInt;
begin
  TilesX := SubsampledSize(Width, PredictorBits);
  TilesY := SubsampledSize(Height, PredictorBits);
  Modes := nil;
  Residuals := nil;
  SetLength(Modes, TilesX * TilesY);
  SetLength(Residuals, PtrInt(Width) * Height);
  for TileY := 0 to TilesY - 1 do
    for TileX := 0 to TilesX - 1 do
      Modes[TileY * TilesX + TileX] := $FF000000 or
        (LongWord(BestTileMode(Pixels, Width, Height, TileX, TileY)) shl 8);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      Mode := (Modes[(Y shr PredictorBits) * TilesX + (X shr PredictorBits)] shr 8) and $F;
      Residuals[PtrInt(Y) * Width + X] := SubtractPixels(Pixels[PtrInt(Y) * Width + X],
        Prediction(Pixels, Width, X, Y, Mode));
    end;
end;

{ An entropy coded image: no colour cache, (for the main image) no meta
  codes, one group of five prefix codes. }
procedure WriteEntropyImage(Writer: TLosslessBitWriter; Pixels: PLongWord; Width, Height: LongInt;
  IsMainImage: Boolean);
var
  Tokens: TPixelTokens;
  TokenCount: LongInt;
  GreenHistogram: array[0..LiteralCodes + LengthCodes - 1] of LongWord;
  RedHistogram: array[0..LiteralCodes - 1] of LongWord;
  BlueHistogram: array[0..LiteralCodes - 1] of LongWord;
  AlphaHistogram: array[0..LiteralCodes - 1] of LongWord;
  DistanceHistogram: array[0..DistanceCodes - 1] of LongWord;
  Green: TPrefixCodeTable;
  Red: TPrefixCodeTable;
  Blue: TPrefixCodeTable;
  Alpha: TPrefixCodeTable;
  Distance: TPrefixCodeTable;
  Index: LongInt;
  Color: LongWord;
  Symbol: LongInt;
  ExtraBits: LongInt;
  ExtraValue: LongInt;
begin
  Writer.WriteBits(0, 1);
  if IsMainImage then
    Writer.WriteBits(0, 1);
  Tokens := FindBackwardReferences(Pixels, Width, Height, TokenCount);
  FillChar(GreenHistogram, SizeOf(GreenHistogram), 0);
  FillChar(RedHistogram, SizeOf(RedHistogram), 0);
  FillChar(BlueHistogram, SizeOf(BlueHistogram), 0);
  FillChar(AlphaHistogram, SizeOf(AlphaHistogram), 0);
  FillChar(DistanceHistogram, SizeOf(DistanceHistogram), 0);
  for Index := 0 to TokenCount - 1 do
    if Tokens[Index].Length = 0 then
    begin
      Color := Tokens[Index].Value;
      Inc(GreenHistogram[(Color shr 8) and $FF]);
      Inc(RedHistogram[(Color shr 16) and $FF]);
      Inc(BlueHistogram[Color and $FF]);
      Inc(AlphaHistogram[Color shr 24]);
    end
    else
    begin
      PrefixEncode(Tokens[Index].Length, Symbol, ExtraBits, ExtraValue);
      Inc(GreenHistogram[LiteralCodes + Symbol]);
      PrefixEncode(Tokens[Index].Value, Symbol, ExtraBits, ExtraValue);
      Inc(DistanceHistogram[Symbol]);
    end;
  BuildPrefixCodeTable(GreenHistogram, Length(GreenHistogram), Green);
  BuildPrefixCodeTable(RedHistogram, Length(RedHistogram), Red);
  BuildPrefixCodeTable(BlueHistogram, Length(BlueHistogram), Blue);
  BuildPrefixCodeTable(AlphaHistogram, Length(AlphaHistogram), Alpha);
  BuildPrefixCodeTable(DistanceHistogram, Length(DistanceHistogram), Distance);
  StorePrefixCode(Writer, Green);
  StorePrefixCode(Writer, Red);
  StorePrefixCode(Writer, Blue);
  StorePrefixCode(Writer, Alpha);
  StorePrefixCode(Writer, Distance);
  for Index := 0 to TokenCount - 1 do
    if Tokens[Index].Length = 0 then
    begin
      Color := Tokens[Index].Value;
      WriteSymbol(Writer, Green, (Color shr 8) and $FF);
      WriteSymbol(Writer, Red, (Color shr 16) and $FF);
      WriteSymbol(Writer, Blue, Color and $FF);
      WriteSymbol(Writer, Alpha, Color shr 24);
    end
    else
    begin
      PrefixEncode(Tokens[Index].Length, Symbol, ExtraBits, ExtraValue);
      WriteSymbol(Writer, Green, LiteralCodes + Symbol);
      Writer.WriteBits(ExtraValue, ExtraBits);
      PrefixEncode(Tokens[Index].Value, Symbol, ExtraBits, ExtraValue);
      WriteSymbol(Writer, Distance, Symbol);
      Writer.WriteBits(ExtraValue, ExtraBits);
    end;
end;

function EncodeLosslessStream(Pixels: PLongWord; Width, Height: LongInt): TBytes;
var
  Writer: TLosslessBitWriter;
  Work: TPixelBuffer;
  Modes: TPixelBuffer;
  Residuals: TPixelBuffer;
  Count: PtrInt;
  Index: PtrInt;
  AlphaUsed: Boolean;
  Pixel: LongWord;
  Green: LongWord;
begin
  if (Width > MaximumLosslessSide) or (Height > MaximumLosslessSide) then
    RaiseImageError(ImageErrorUnsupported, 'WebP pictures are at most 16384 pixels a side');
  Count := PtrInt(Width) * Height;
  Work := nil;
  SetLength(Work, Count);
  AlphaUsed := False;
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    if (Pixel shr 24) <> $FF then
      AlphaUsed := True;
    Green := (Pixel shr 8) and $FF;
    Work[Index] := SubtractPixels(Pixel, (Green shl 16) or Green);
  end;
  ApplyPredictor(@Work[0], Width, Height, Modes, Residuals);
  Writer := TLosslessBitWriter.Create;
  try
    Writer.WriteBits(LosslessSignature, 8);
    Writer.WriteBits(Width - 1, 14);
    Writer.WriteBits(Height - 1, 14);
    Writer.WriteBits(Ord(AlphaUsed), 1);
    Writer.WriteBits(0, 3);
    Writer.WriteBits(1, 1);
    Writer.WriteBits(TransformSubtractGreen, 2);
    Writer.WriteBits(1, 1);
    Writer.WriteBits(TransformPredictor, 2);
    Writer.WriteBits(PredictorBits - 2, 3);
    WriteEntropyImage(Writer, @Modes[0], SubsampledSize(Width, PredictorBits), SubsampledSize(Height, PredictorBits),
      False);
    Writer.WriteBits(0, 1);
    WriteEntropyImage(Writer, @Residuals[0], Width, Height, True);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

end.
