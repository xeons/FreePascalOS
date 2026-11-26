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
  The block inter prediction process (specification section 7.11.3.4):
  sub-sample interpolation of a reference plane with the Subpel_Filters,
  a horizontal pass into an intermediate array and a vertical pass from
  it, rounded by InterRound0 and InterRound1.

  When the reference is not scaled and every sample read lies inside
  the reference plane, the samples are read without clamping each
  coordinate; otherwise each coordinate is clamped as the specification
  writes it. Both give the same results.
}
unit Av1.BlockInterPrediction;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.Picture, Av1.TileContext;

{ X and Y in 1/1024 samples, StepX and StepY too. FilterHorizontal is
  InterpFilters[ candRow ][ candCol ][ 1 ], FilterVertical [ 0 ]. Pred
  receives H rows of W values, PredStride apart. }
procedure PredictBlockInter(Tile: TTileContext; Plane: Integer; Reference: TPicture; LastX, LastY,
  X, Y, StepX, StepY, W, H, FilterHorizontal, FilterVertical: Integer; Pred: PInteger;
  PredStride: Integer);

implementation

const
  IntermediateStride = MAX_SB_SIZE;

function SmallBlockFilter(Filter, Size: Integer): Integer; inline;
begin
  Result := Filter;
  if Size <= 4 then
  begin
    if (Filter = EIGHTTAP) or (Filter = EIGHTTAP_SHARP) then
      Result := 4
    else if Filter = EIGHTTAP_SMOOTH then
      Result := 5;
  end;
end;

{ The 8-tap sum of eight samples Step apart. }
function TapSum(Taps: PSmallInt; Samples: PWord; Step: Integer): Integer; inline;
begin
  Result := Taps[0] * Samples[0] + Taps[1] * Samples[Step] + Taps[2] * Samples[2 * Step] +
    Taps[3] * Samples[3 * Step] + Taps[4] * Samples[4 * Step] + Taps[5] * Samples[5 * Step] +
    Taps[6] * Samples[6 * Step] + Taps[7] * Samples[7 * Step];
end;

function IntermediateTapSum(Taps: PSmallInt; Values: PInteger): Integer; inline;
begin
  Result := Taps[0] * Values[0] + Taps[1] * Values[IntermediateStride] + Taps[2] * Values[2 * IntermediateStride] +
    Taps[3] * Values[3 * IntermediateStride] + Taps[4] * Values[4 * IntermediateStride] +
    Taps[5] * Values[5 * IntermediateStride] + Taps[6] * Values[6 * IntermediateStride] +
    Taps[7] * Values[7 * IntermediateStride];
end;

{ The block inter prediction process for an unscaled block whose samples
  are all inside the reference: the same sums as the specification, with
  the passes that a zero fraction makes a plain scaling done as one. Source
  points at the sample 3 rows above and 3 columns left of the block. }
procedure PredictUnscaledInside(Tile: TTileContext; Source: PWord; SourceStride, X, Y, W, H,
  FilterHorizontal, FilterVertical: Integer; Intermediate, Pred: PInteger; PredStride: Integer);
var
  Round0, Round1, FractionX, FractionY, Row, Column, Shift, Rounding0, Rounding1: Integer;
  HorizontalTaps, VerticalTaps: PSmallInt;
  SourceRow: PWord;
  Output, Input: PInteger;
begin
  Round0 := Tile.InterRound0;
  Round1 := Tile.InterRound1;
  Rounding0 := 1 shl (Round0 - 1);
  Rounding1 := 1 shl (Round1 - 1);
  FractionX := (X shr 6) and SUBPEL_MASK;
  FractionY := (Y shr 6) and SUBPEL_MASK;
  HorizontalTaps := @Subpel_Filters[FilterHorizontal, FractionX, 0];
  VerticalTaps := @Subpel_Filters[FilterVertical, FractionY, 0];
  if FractionY = 0 then
  begin
    { The vertical pass multiplies by 128: Round2( value << 7, Round1 ). }
    for Row := 0 to H - 1 do
    begin
      SourceRow := Source + (Row + 3) * SourceStride;
      Output := Pred + Row * PredStride;
      if FractionX = 0 then
      begin
        Shift := 14 - Round0;
        for Column := 0 to W - 1 do
          Output[Column] := ((SourceRow[Column + 3] shl Shift) + Rounding1) shr Round1;
      end
      else
        for Column := 0 to W - 1 do
          Output[Column] := SarLongint((SarLongint(TapSum(HorizontalTaps, SourceRow + Column, 1) + Rounding0, Round0)
            shl 7) + Rounding1, Round1);
    end;
    Exit;
  end;
  for Row := 0 to H + 6 do
  begin
    SourceRow := Source + Row * SourceStride;
    Output := Intermediate + Row * IntermediateStride;
    if FractionX = 0 then
    begin
      Shift := 7 - Round0;
      for Column := 0 to W - 1 do
        Output[Column] := SourceRow[Column + 3] shl Shift;
    end
    else
      for Column := 0 to W - 1 do
        Output[Column] := SarLongint(TapSum(HorizontalTaps, SourceRow + Column, 1) + Rounding0, Round0);
  end;
  for Row := 0 to H - 1 do
  begin
    Input := Intermediate + Row * IntermediateStride;
    Output := Pred + Row * PredStride;
    for Column := 0 to W - 1 do
      Output[Column] := SarLongint(IntermediateTapSum(VerticalTaps, Input + Column) + Rounding1, Round1);
  end;
end;

procedure FilterHorizontallyClamped(Tile: TTileContext; Source: PWord; SourceStride, LastX, LastY,
  X, Y, StepX, W, Rows, Filter: Integer; Intermediate: PInteger);
var
  Row, Column, Tap, Sum, Round0, Position, SampleRow, BaseColumn: Integer;
  Taps: PSmallInt;
  SourceRow: PWord;
  Output: PInteger;
begin
  Round0 := Tile.InterRound0;
  for Row := 0 to Rows - 1 do
  begin
    SampleRow := Clip3(0, LastY, ShiftRight(Y, 10) + Row - 3);
    SourceRow := Source + SampleRow * SourceStride;
    Output := Intermediate + Row * IntermediateStride;
    for Column := 0 to W - 1 do
    begin
      Position := X + StepX * Column;
      Taps := @Subpel_Filters[Filter, ShiftRight(Position, 6) and SUBPEL_MASK, 0];
      BaseColumn := ShiftRight(Position, 10) - 3;
      Sum := 0;
      for Tap := 0 to 7 do
        Sum := Sum + Taps[Tap] * SourceRow[Clip3(0, LastX, BaseColumn + Tap)];
      Output[Column] := SarLongint(Sum + (1 shl (Round0 - 1)), Round0);
    end;
  end;
end;

procedure FilterVertically(Tile: TTileContext; Intermediate: PInteger; Y, StepY, W, H, Filter: Integer;
  Pred: PInteger; PredStride: Integer);
var
  Row, Column, Tap, Sum, Round1, Position, Rounding: Integer;
  Taps: PSmallInt;
  Input, Output: PInteger;
begin
  Round1 := Tile.InterRound1;
  Rounding := 1 shl (Round1 - 1);
  for Row := 0 to H - 1 do
  begin
    Position := (Y and 1023) + StepY * Row;
    Taps := @Subpel_Filters[Filter, (Position shr 6) and SUBPEL_MASK, 0];
    Input := Intermediate + (Position shr 10) * IntermediateStride;
    Output := Pred + Row * PredStride;
    for Column := 0 to W - 1 do
    begin
      Sum := 0;
      for Tap := 0 to 7 do
        Sum := Sum + Taps[Tap] * Input[Tap * IntermediateStride + Column];
      Output[Column] := SarLongint(Sum + Rounding, Round1);
    end;
  end;
end;

procedure PredictBlockInter(Tile: TTileContext; Plane: Integer; Reference: TPicture; LastX, LastY,
  X, Y, StepX, StepY, W, H, FilterHorizontal, FilterVertical: Integer; Pred: PInteger;
  PredStride: Integer);
var
  IntermediateHeight, FirstRow, FirstColumn, LastColumn: Integer;
  Source: PWord;
  SourceStride: Integer;
  Intermediate: PInteger;
begin
  IntermediateHeight := ((((H - 1) * StepY + (1 shl SCALE_SUBPEL_BITS) - 1)) shr SCALE_SUBPEL_BITS) + 8;
  FilterHorizontal := SmallBlockFilter(FilterHorizontal, W);
  FilterVertical := SmallBlockFilter(FilterVertical, H);
  Source := @Reference.Planes[Plane].Samples[0];
  SourceStride := Reference.Planes[Plane].Stride;
  Intermediate := @Tile.InterIntermediate[0];
  FirstRow := ShiftRight(Y, 10) - 3;
  FirstColumn := ShiftRight(X, 10) - 3;
  LastColumn := ShiftRight(X + StepX * (W - 1), 10) + 4;
  if (StepX = 1 shl SCALE_SUBPEL_BITS) and (StepY = 1 shl SCALE_SUBPEL_BITS) and (FirstRow >= 0) and
    (FirstColumn >= 0) and (FirstRow + IntermediateHeight - 1 <= LastY) and (LastColumn <= LastX) then
  begin
    PredictUnscaledInside(Tile, Source + FirstRow * SourceStride + FirstColumn, SourceStride, X, Y, W, H,
      FilterHorizontal, FilterVertical, Intermediate, Pred, PredStride);
    Exit;
  end;
  FilterHorizontallyClamped(Tile, Source, SourceStride, LastX, LastY, X, Y, StepX, W,
    IntermediateHeight, FilterHorizontal, Intermediate);
  FilterVertically(Tile, Intermediate, Y, StepY, W, H, FilterVertical, Pred, PredStride);
end;

end.
