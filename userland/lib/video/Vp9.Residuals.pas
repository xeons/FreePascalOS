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
  VP9 residual tokens (section 9.3 of the VP9 specification): one
  transform block's coefficients in scan order, each token's
  probabilities chosen by its band and by the tokens of two earlier
  neighbours, the large values from the Pareto model's tail and extra
  bits, dequantized as they are read (libvpx's decode_coefs).
}
unit Vp9.Residuals;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.BoolDecoder, Vp9.Probabilities;

type
  { The probabilities of one transform size, plane type and reference:
    band, context, the 3 modelled nodes. }
  TVp9BandProbabilities = array[0..5, 0..5, 0..2] of Byte;
  PVp9BandProbabilities = ^TVp9BandProbabilities;
  TVp9BandCounts = array[0..5, 0..5, 0..3] of LongWord;
  PVp9BandCounts = ^TVp9BandCounts;
  TVp9BandEndCounts = array[0..5, 0..5] of LongWord;
  PVp9BandEndCounts = ^TVp9BandEndCounts;

  TVp9TokenBlock = record
    Probabilities: PVp9BandProbabilities;
    { nil when the frame does not adapt its probabilities. }
    Counts: PVp9BandCounts;
    EndCounts: PVp9BandEndCounts;
    TransformSize: LongInt;
    DcStep, AcStep: LongInt;
    Context: LongInt;
    Scan: PSmallInt;
    Neighbors: PSmallInt;
    BitDepth: LongInt;
  end;

{ Reads one transform block's tokens into Output (dequantized, at their
  positions, which must be zero); returns the end of block (the number
  of scan positions read). }
function DecodeCoefficients(var Decoder: TBoolDecoder; constref Block: TVp9TokenBlock; Output: PLongInt): LongInt;

implementation

uses
  Vp9.Tables, Vp9.ScanTables;

function ReadCoefficientBits(var Decoder: TBoolDecoder; Probabilities: PByte; Count: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := (Result shl 1) or Decoder.ReadBool(Probabilities[Index]);
end;

function DecodeCoefficients(var Decoder: TBoolDecoder; constref Block: TVp9TokenBlock; Output: PLongInt): LongInt;
var
  MaxEnd, Position, Band, Context, Value, Step, Shift, Category6Bits: LongInt;
  TokenCache: array[0..1023] of Byte;
  Bands: PByte;
  P, Pareto, Category6: PByte;
  Counting: Boolean;
  Magnitude: Int64;
  ScanPosition: LongInt;
begin
  MaxEnd := 16 shl (Block.TransformSize shl 1);
  if Block.TransformSize = 0 then
    Bands := @CoefficientBands4x4[0]
  else
    Bands := @CoefficientBands8x8Plus[0];
  if Block.TransformSize = 3 then
    Shift := 1
  else
    Shift := 0;
  case Block.BitDepth of
    12: begin Category6 := @Category6Probabilities[0]; Category6Bits := 18; end;
    10: begin Category6 := @Category6Probabilities[2]; Category6Bits := 16; end;
  else
    begin Category6 := @Category6Probabilities[4]; Category6Bits := 14; end;
  end;
  Counting := Block.Counts <> nil;
  Context := Block.Context;
  Step := Block.DcStep;
  Position := 0;
  while Position < MaxEnd do
  begin
    Band := Bands[Position];
    P := @Block.Probabilities^[Band, Context, 0];
    if Counting then
      Inc(Block.EndCounts^[Band, Context]);
    if Decoder.ReadBool(P[0]) = 0 then
    begin
      if Counting then
        Inc(Block.Counts^[Band, Context, 3]);
      Break;
    end;
    while Decoder.ReadBool(P[1]) = 0 do
    begin
      if Counting then
        Inc(Block.Counts^[Band, Context, 0]);
      Step := Block.AcStep;
      TokenCache[Block.Scan[Position]] := 0;
      Inc(Position);
      if Position >= MaxEnd then
        Exit(Position);
      Context := (1 + TokenCache[Block.Neighbors[2 * Position]] + TokenCache[Block.Neighbors[2 * Position + 1]]) shr 1;
      Band := Bands[Position];
      P := @Block.Probabilities^[Band, Context, 0];
    end;
    ScanPosition := Block.Scan[Position];
    if Decoder.ReadBool(P[2]) <> 0 then
    begin
      Pareto := @ParetoProbabilities[P[2] - 1, 0];
      if Counting then
        Inc(Block.Counts^[Band, Context, 2]);
      if Decoder.ReadBool(Pareto[0]) <> 0 then
      begin
        if Decoder.ReadBool(Pareto[3]) <> 0 then
        begin
          TokenCache[ScanPosition] := 5;
          if Decoder.ReadBool(Pareto[5]) <> 0 then
          begin
            if Decoder.ReadBool(Pareto[7]) <> 0 then
              Value := 67 + ReadCoefficientBits(Decoder, Category6, Category6Bits)
            else
              Value := 35 + ReadCoefficientBits(Decoder, @Category5Probabilities[0], 5);
          end
          else if Decoder.ReadBool(Pareto[6]) <> 0 then
            Value := 19 + ReadCoefficientBits(Decoder, @Category4Probabilities[0], 4)
          else
            Value := 11 + ReadCoefficientBits(Decoder, @Category3Probabilities[0], 3);
        end
        else
        begin
          TokenCache[ScanPosition] := 4;
          if Decoder.ReadBool(Pareto[4]) <> 0 then
            Value := 7 + ReadCoefficientBits(Decoder, @Category2Probabilities[0], 2)
          else
            Value := 5 + ReadCoefficientBits(Decoder, @Category1Probabilities[0], 1);
        end;
      end
      else if Decoder.ReadBool(Pareto[1]) <> 0 then
      begin
        TokenCache[ScanPosition] := 3;
        Value := 3 + Decoder.ReadBool(Pareto[2]);
      end
      else
      begin
        TokenCache[ScanPosition] := 2;
        Value := 2;
      end;
    end
    else
    begin
      if Counting then
        Inc(Block.Counts^[Band, Context, 1]);
      TokenCache[ScanPosition] := 1;
      Value := 1;
    end;
    Magnitude := SarInt64(Int64(Value) * Step, Shift);
    if Decoder.ReadBit <> 0 then
      Output[ScanPosition] := LongInt(-Magnitude)
    else
      Output[ScanPosition] := LongInt(Magnitude);
    Inc(Position);
    if Position < MaxEnd then
      Context := (1 + TokenCache[Block.Neighbors[2 * Position]] + TokenCache[Block.Neighbors[2 * Position + 1]]) shr 1;
    Step := Block.AcStep;
  end;
  Result := Position;
end;

end.
