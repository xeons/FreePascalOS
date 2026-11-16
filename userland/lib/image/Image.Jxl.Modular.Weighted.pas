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
  JPEG XL's self-correcting weighted predictor (ISO/IEC 18181-1 annex
  H.5): four sub-predictors, each weighted by how wrong it was near the
  sample (above, above left and above right; the errors of the row
  being decoded are added to the row above as it goes, so the left
  neighbour counts too), all in fixed point with three extra bits. Its
  largest nearby error is also a property for the MA tree.

  The arithmetic is libjxl's to the bit: weights through a division
  table, arithmetic shifts of negative numbers, 32-bit error storage.
}
unit Image.Jxl.Modular.Weighted;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Jxl.BitReader;

type
  TJxlWeightedHeader = record
    P1C: Int64;
    P2C: Int64;
    P3Ca: Int64;
    P3Cb: Int64;
    P3Cc: Int64;
    P3Cd: Int64;
    P3Ce: Int64;
    W: array[0..3] of LongWord;
  end;

  TJxlWeightedPredictor = class
  private
    FHeader: TJxlWeightedHeader;
    FWidth: LongInt;
    FPredictions: array[0..3] of Int64;
    FPrediction: Int64;
    FSubErrors: array[0..3] of array of LongWord;
    FErrors: array of LongInt;
  public
    constructor Create(const Header: TJxlWeightedHeader; Width: LongInt);
    { The prediction for (X, Y) from the neighbours (edges already
      resolved); MaximumError receives the property. }
    function Predict(X, Y: LongInt; North, West, NorthEast, NorthWest, NorthNorth: Int64;
      out MaximumError: Int64): Int64;
    { Records the decoded value of (X, Y). }
    procedure Update(Value: Int64; X, Y: LongInt);
  end;

function DefaultJxlWeightedHeader: TJxlWeightedHeader;
function ReadJxlWeightedHeader(Reader: TJxlBitReader): TJxlWeightedHeader;

implementation

const
  PredictionExtraBits = 3;
  PredictionRound = ((1 shl PredictionExtraBits) shr 1) - 1;
  DivisionLookup: array[0..63] of LongWord = (
    16777216, 8388608, 5592405, 4194304, 3355443, 2796202, 2396745, 2097152,
    1864135, 1677721, 1525201, 1398101, 1290555, 1198372, 1118481, 1048576,
    986895, 932067, 883011, 838860, 798915, 762600, 729444, 699050,
    671088, 645277, 621378, 599186, 578524, 559240, 541200, 524288,
    508400, 493447, 479349, 466033, 453438, 441505, 430185, 419430,
    409200, 399457, 390167, 381300, 372827, 364722, 356962, 349525,
    342392, 335544, 328965, 322638, 316551, 310689, 305040, 299593,
    294337, 289262, 284359, 279620, 275036, 270600, 266305, 262144);

function DefaultJxlWeightedHeader: TJxlWeightedHeader;
begin
  Result.P1C := 16;
  Result.P2C := 10;
  Result.P3Ca := 7;
  Result.P3Cb := 7;
  Result.P3Cc := 7;
  Result.P3Cd := 0;
  Result.P3Ce := 0;
  Result.W[0] := $D;
  Result.W[1] := $C;
  Result.W[2] := $C;
  Result.W[3] := $C;
end;

function ReadJxlWeightedHeader(Reader: TJxlBitReader): TJxlWeightedHeader;
var
  Index: LongInt;
begin
  Result := DefaultJxlWeightedHeader;
  if Reader.ReadBool then
    Exit;
  Result.P1C := Reader.ReadBits(5);
  Result.P2C := Reader.ReadBits(5);
  Result.P3Ca := Reader.ReadBits(5);
  Result.P3Cb := Reader.ReadBits(5);
  Result.P3Cc := Reader.ReadBits(5);
  Result.P3Cd := Reader.ReadBits(5);
  Result.P3Ce := Reader.ReadBits(5);
  for Index := 0 to 3 do
    Result.W[Index] := Reader.ReadBits(4);
end;

function FloorLog2(Value: QWord): LongInt;
begin
  Result := -1;
  while Value <> 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

function ErrorWeight(Value: QWord; MaximumWeight: LongWord): LongWord;
var
  Shift: LongInt;
begin
  Shift := FloorLog2(Value + 1) - 5;
  if Shift < 0 then
    Shift := 0;
  Result := 4 + LongWord((QWord(MaximumWeight) * DivisionLookup[Value shr Shift]) shr Shift);
end;

constructor TJxlWeightedPredictor.Create(const Header: TJxlWeightedHeader; Width: LongInt);
var
  Index: LongInt;
begin
  inherited Create;
  FHeader := Header;
  FWidth := Width;
  for Index := 0 to 3 do
    SetLength(FSubErrors[Index], (Width + 2) * 2);
  SetLength(FErrors, (Width + 2) * 2);
end;

function TJxlWeightedPredictor.Predict(X, Y: LongInt; North, West, NorthEast, NorthWest, NorthNorth: Int64;
  out MaximumError: Int64): Int64;
var
  CurrentRow: LongInt;
  PreviousRow: LongInt;
  PositionNorth: LongInt;
  PositionNorthEast: LongInt;
  PositionNorthWest: LongInt;
  Weights: array[0..3] of LongWord;
  Index: LongInt;
  Sum32: LongWord;
  ErrorWest: Int64;
  ErrorNorth: Int64;
  ErrorNorthWest: Int64;
  ErrorNorthEast: Int64;
  SumWestNorth: Int64;
  WeightSum: LongWord;
  LogWeight: LongInt;
  Sum: Int64;
  Highest: Int64;
  Lowest: Int64;
begin
  if (Y and 1) <> 0 then
  begin
    CurrentRow := 0;
    PreviousRow := FWidth + 2;
  end
  else
  begin
    CurrentRow := FWidth + 2;
    PreviousRow := 0;
  end;
  PositionNorth := PreviousRow + X;
  if X < FWidth - 1 then
    PositionNorthEast := PositionNorth + 1
  else
    PositionNorthEast := PositionNorth;
  if X > 0 then
    PositionNorthWest := PositionNorth - 1
  else
    PositionNorthWest := PositionNorth;
  for Index := 0 to 3 do
  begin
    Sum32 := LongWord((QWord(FSubErrors[Index][PositionNorth]) + FSubErrors[Index][PositionNorthEast] +
      FSubErrors[Index][PositionNorthWest]) and $FFFFFFFF);
    Weights[Index] := ErrorWeight(Sum32, FHeader.W[Index]);
  end;
  North := North * 8;
  West := West * 8;
  NorthEast := NorthEast * 8;
  NorthWest := NorthWest * 8;
  NorthNorth := NorthNorth * 8;
  if X = 0 then
    ErrorWest := 0
  else
    ErrorWest := FErrors[CurrentRow + X - 1];
  ErrorNorth := FErrors[PositionNorth];
  ErrorNorthWest := FErrors[PositionNorthWest];
  ErrorNorthEast := FErrors[PositionNorthEast];
  SumWestNorth := ErrorNorth + ErrorWest;
  MaximumError := ErrorWest;
  if Abs(ErrorNorth) > Abs(MaximumError) then
    MaximumError := ErrorNorth;
  if Abs(ErrorNorthWest) > Abs(MaximumError) then
    MaximumError := ErrorNorthWest;
  if Abs(ErrorNorthEast) > Abs(MaximumError) then
    MaximumError := ErrorNorthEast;
  FPredictions[0] := West + NorthEast - North;
  FPredictions[1] := North - SarInt64((SumWestNorth + ErrorNorthEast) * FHeader.P1C, 5);
  FPredictions[2] := West - SarInt64((SumWestNorth + ErrorNorthWest) * FHeader.P2C, 5);
  FPredictions[3] := North - SarInt64(ErrorNorthWest * FHeader.P3Ca + ErrorNorth * FHeader.P3Cb +
    ErrorNorthEast * FHeader.P3Cc + (NorthNorth - North) * FHeader.P3Cd + (NorthWest - West) * FHeader.P3Ce, 5);
  { The weighted average. }
  WeightSum := 0;
  for Index := 0 to 3 do
    WeightSum := LongWord((QWord(WeightSum) + Weights[Index]) and $FFFFFFFF);
  LogWeight := FloorLog2(WeightSum);
  if LogWeight < 4 then
    LogWeight := 4;
  WeightSum := 0;
  for Index := 0 to 3 do
  begin
    Weights[Index] := Weights[Index] shr (LogWeight - 4);
    Inc(WeightSum, Weights[Index]);
  end;
  Sum := Int64(WeightSum shr 1) - 1;
  for Index := 0 to 3 do
    Sum := Sum + FPredictions[Index] * Int64(Weights[Index]);
  if WeightSum = 0 then
    WeightSum := 1;
  FPrediction := SarInt64(Sum * Int64(DivisionLookup[(WeightSum - 1) and 63]), 24);
  if ((ErrorNorth xor ErrorWest) or (ErrorNorth xor ErrorNorthWest)) > 0 then
    Exit(SarInt64(FPrediction + PredictionRound, PredictionExtraBits));
  Highest := West;
  if NorthEast > Highest then
    Highest := NorthEast;
  if North > Highest then
    Highest := North;
  Lowest := West;
  if NorthEast < Lowest then
    Lowest := NorthEast;
  if North < Lowest then
    Lowest := North;
  if FPrediction > Highest then
    FPrediction := Highest;
  if FPrediction < Lowest then
    FPrediction := Lowest;
  Result := SarInt64(FPrediction + PredictionRound, PredictionExtraBits);
end;

procedure TJxlWeightedPredictor.Update(Value: Int64; X, Y: LongInt);
var
  CurrentRow: LongInt;
  PreviousRow: LongInt;
  Index: LongInt;
  Error: Int64;
begin
  if (Y and 1) <> 0 then
  begin
    CurrentRow := 0;
    PreviousRow := FWidth + 2;
  end
  else
  begin
    CurrentRow := FWidth + 2;
    PreviousRow := 0;
  end;
  Value := Value * 8;
  FErrors[CurrentRow + X] := LongInt((FPrediction - Value) and $FFFFFFFF);
  for Index := 0 to 3 do
  begin
    Error := SarInt64(Abs(FPredictions[Index] - Value) + PredictionRound, PredictionExtraBits);
    FSubErrors[Index][CurrentRow + X] := LongWord(Error and $FFFFFFFF);
    FSubErrors[Index][PreviousRow + X + 1] := LongWord((QWord(FSubErrors[Index][PreviousRow + X + 1]) +
      QWord(Error and $FFFFFFFF)) and $FFFFFFFF);
  end;
end;

end.
