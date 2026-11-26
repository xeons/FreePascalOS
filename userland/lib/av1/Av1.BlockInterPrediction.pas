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

procedure FilterHorizontallyUnclamped(Tile: TTileContext; Source: PWord; SourceStride: Integer;
  X, W, Rows, Filter: Integer; Intermediate: PInteger);
var
  Row, Column, Tap, Sum, Round0, Fraction, Scale: Integer;
  Taps: PSmallInt;
  SourceRow, Samples: PWord;
  Output: PInteger;
begin
  Round0 := Tile.InterRound0;
  Fraction := ShiftRight(X, 6) and SUBPEL_MASK;
  Taps := @Subpel_Filters[Filter, Fraction, 0];
  SourceRow := Source;
  for Row := 0 to Rows - 1 do
  begin
    Output := Intermediate + Row * IntermediateStride;
    if Fraction = 0 then
    begin
      Scale := 128 shr Round0;
      Samples := SourceRow + 3;
      for Column := 0 to W - 1 do
        Output[Column] := Samples[Column] * Scale;
    end
    else
      for Column := 0 to W - 1 do
      begin
        Samples := SourceRow + Column;
        Sum := 0;
        for Tap := 0 to 7 do
          Sum := Sum + Taps[Tap] * Samples[Tap];
        Output[Column] := SarLongint(Sum + (1 shl (Round0 - 1)), Round0);
      end;
    Inc(SourceRow, SourceStride);
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
  if (StepX = 1 shl SCALE_SUBPEL_BITS) and (FirstRow >= 0) and (FirstColumn >= 0) and
    (FirstRow + IntermediateHeight - 1 <= LastY) and (LastColumn <= LastX) then
    FilterHorizontallyUnclamped(Tile, Source + FirstRow * SourceStride + FirstColumn, SourceStride,
      X, W, IntermediateHeight, FilterHorizontal, Intermediate)
  else
    FilterHorizontallyClamped(Tile, Source, SourceStride, LastX, LastY, X, Y, StepX, W,
      IntermediateHeight, FilterHorizontal, Intermediate);
  FilterVertically(Tile, Intermediate, Y, StepY, W, H, FilterVertical, Pred, PredStride);
end;

end.
