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
  The intra prediction process (specification section 7.11.2):
  predict_intra prepares AboveRow and LeftCol from the reconstructed
  samples around the transform block and writes the prediction (filter
  intra, directional, smooth, DC or Paeth) straight into CurrFrame.
}
unit Av1.IntraPrediction;

{$mode objfpc}

interface

uses
  Av1.TileContext;

{ predict_intra( plane, x, y, haveLeft, haveAbove, haveAboveRt,
  haveBelowLft, mode, log2W, log2H ). }
procedure PredictIntra(Tile: TTileContext; Plane, X, Y: Integer; HaveLeft, HaveAbove, HaveAboveRt,
  HaveBelowLft: Boolean; Mode, Log2W, Log2H: Integer);

implementation

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.Picture, Av1.IntraEdges;

type
  TPredictionTarget = record
    First: PWord;          { CurrFrame[ plane ][ y ][ x ] }
    Stride: Integer;
    W, H: Integer;
    MaxValue: Integer;     { ( 1 << BitDepth ) - 1 }
  end;

function ClipSample(const Target: TPredictionTarget; Value: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > Target.MaxValue then
    Result := Target.MaxValue
  else
    Result := Value;
end;

function SmoothWeights(Log2Size: Integer): PByte;
begin
  case Log2Size of
    2: Result := @Sm_Weights_Tx_4x4[0];
    3: Result := @Sm_Weights_Tx_8x8[0];
    4: Result := @Sm_Weights_Tx_16x16[0];
    5: Result := @Sm_Weights_Tx_32x32[0];
  else
    Result := @Sm_Weights_Tx_64x64[0];
  end;
end;

procedure FillValue(const Target: TPredictionTarget; Value: Integer);
var
  Row, Col: Integer;
  Line: PWord;
begin
  for Row := 0 to Target.H - 1 do
  begin
    Line := Target.First + Row * Target.Stride;
    for Col := 0 to Target.W - 1 do
      Line[Col] := Value;
  end;
end;

{ The basic intra prediction process (Paeth). }
procedure PredictPaeth(const Target: TPredictionTarget; Above, Left: TEdgePointer);
var
  Row, Col, Base, PLeft, PTop, PTopLeft, TopLeft: Integer;
  Line: PWord;
begin
  TopLeft := Above[-1];
  for Row := 0 to Target.H - 1 do
  begin
    Line := Target.First + Row * Target.Stride;
    for Col := 0 to Target.W - 1 do
    begin
      Base := Above[Col] + Left[Row] - TopLeft;
      PLeft := Abs(Base - Left[Row]);
      PTop := Abs(Base - Above[Col]);
      PTopLeft := Abs(Base - TopLeft);
      if (PLeft <= PTop) and (PLeft <= PTopLeft) then
        Line[Col] := Left[Row]
      else if PTop <= PTopLeft then
        Line[Col] := Above[Col]
      else
        Line[Col] := TopLeft;
    end;
  end;
end;

{ The recursive intra prediction process (filter intra). Earlier rows and
  columns of pred are read back from CurrFrame. }
procedure PredictRecursive(const Target: TPredictionTarget; Above, Left: TEdgePointer; FilterMode: Integer);
var
  Neighbours: array[0..6] of Integer;
  W4, H2, Row2, Col4, Index, Row1, Col1, Sum: Integer;
  Line: PWord;
begin
  W4 := Target.W shr 2;
  H2 := Target.H shr 1;
  for Row2 := 0 to H2 - 1 do
    for Col4 := 0 to W4 - 1 do
    begin
      for Index := 0 to 6 do
      begin
        if Index < 5 then
        begin
          if Row2 = 0 then
            Neighbours[Index] := Above[(Col4 shl 2) + Index - 1]
          else if (Col4 = 0) and (Index = 0) then
            Neighbours[Index] := Left[(Row2 shl 1) - 1]
          else
            Neighbours[Index] := (Target.First + ((Row2 shl 1) - 1) * Target.Stride)[(Col4 shl 2) + Index - 1];
        end
        else if Col4 = 0 then
          Neighbours[Index] := Left[(Row2 shl 1) + Index - 5]
        else
          Neighbours[Index] := (Target.First + ((Row2 shl 1) + Index - 5) * Target.Stride)[(Col4 shl 2) - 1];
      end;
      for Row1 := 0 to 1 do
      begin
        Line := Target.First + ((Row2 shl 1) + Row1) * Target.Stride;
        for Col1 := 0 to 3 do
        begin
          Sum := 0;
          for Index := 0 to 6 do
            Inc(Sum, Intra_Filter_Taps[FilterMode, (Row1 shl 2) + Col1, Index] * Neighbours[Index]);
          Line[(Col4 shl 2) + Col1] := ClipSample(Target, Round2Signed(Sum, INTRA_FILTER_SCALE_BITS));
        end;
      end;
    end;
end;

{ The DC intra prediction process. }
procedure PredictDc(const Target: TPredictionTarget; Above, Left: TEdgePointer; HaveLeft, HaveAbove: Boolean;
  Log2W, Log2H, BitDepth: Integer);
var
  Sum, Index: Integer;
begin
  Sum := 0;
  if HaveLeft and HaveAbove then
  begin
    for Index := 0 to Target.H - 1 do
      Inc(Sum, Left[Index]);
    for Index := 0 to Target.W - 1 do
      Inc(Sum, Above[Index]);
    Inc(Sum, (Target.W + Target.H) shr 1);
    FillValue(Target, Sum div (Target.W + Target.H));
  end
  else if HaveLeft then
  begin
    for Index := 0 to Target.H - 1 do
      Inc(Sum, Left[Index]);
    FillValue(Target, ClipSample(Target, (Sum + (Target.H shr 1)) shr Log2H));
  end
  else if HaveAbove then
  begin
    for Index := 0 to Target.W - 1 do
      Inc(Sum, Above[Index]);
    FillValue(Target, ClipSample(Target, (Sum + (Target.W shr 1)) shr Log2W));
  end
  else
    FillValue(Target, 1 shl (BitDepth - 1));
end;

{ The smooth intra prediction process. }
procedure PredictSmooth(const Target: TPredictionTarget; Above, Left: TEdgePointer; Mode, Log2W, Log2H: Integer);
var
  WeightsX, WeightsY: PByte;
  Row, Col, BottomLeft, TopRight, Value: Integer;
  Line: PWord;
begin
  WeightsX := SmoothWeights(Log2W);
  WeightsY := SmoothWeights(Log2H);
  BottomLeft := Left[Target.H - 1];
  TopRight := Above[Target.W - 1];
  for Row := 0 to Target.H - 1 do
  begin
    Line := Target.First + Row * Target.Stride;
    for Col := 0 to Target.W - 1 do
    begin
      if Mode = SMOOTH_PRED then
      begin
        Value := WeightsY[Row] * Above[Col] + (256 - WeightsY[Row]) * BottomLeft +
          WeightsX[Col] * Left[Row] + (256 - WeightsX[Col]) * TopRight;
        Line[Col] := (Value + 256) shr 9;
      end
      else if Mode = SMOOTH_V_PRED then
      begin
        Value := WeightsY[Row] * Above[Col] + (256 - WeightsY[Row]) * BottomLeft;
        Line[Col] := (Value + 128) shr 8;
      end
      else
      begin
        Value := WeightsX[Col] * Left[Row] + (256 - WeightsX[Col]) * TopRight;
        Line[Col] := (Value + 128) shr 8;
      end;
    end;
  end;
end;

{ The directional intra prediction process. }
procedure PredictDirectional(Tile: TTileContext; const Target: TPredictionTarget; Above, Left: TEdgePointer;
  Plane, X, Y: Integer; HaveLeft, HaveAbove: Boolean; Mode, MaxX, MaxY: Integer);
var
  AngleDelta, PAngle, UpsampleAbove, UpsampleLeft, FilterType, Strength, NumPx: Integer;
  Dx, Dy, Row, Col, Index, Base, Shift, MaxBaseX, Corner, W, H, BitDepth: Integer;
  Line: PWord;
begin
  W := Target.W;
  H := Target.H;
  BitDepth := Tile.Sequence^.BitDepth;
  if Plane = 0 then
    AngleDelta := Tile.AngleDeltaY
  else
    AngleDelta := Tile.AngleDeltaUV;
  PAngle := Mode_To_Angle[Mode] + AngleDelta * ANGLE_STEP;
  UpsampleAbove := 0;
  UpsampleLeft := 0;
  if Tile.Sequence^.enable_intra_edge_filter then
  begin
    FilterType := GetFilterType(Tile, Plane);
    if (PAngle <> 90) and (PAngle <> 180) then
    begin
      if (PAngle > 90) and (PAngle < 180) and (W + H >= 24) then
      begin
        Corner := FilterCorner(Above, Left);
        Left[-1] := Corner;
        Above[-1] := Corner;
      end;
      if HaveAbove then
      begin
        Strength := EdgeFilterStrength(W, H, FilterType, PAngle - 90);
        NumPx := Min(W, MaxX - X + 1) + 1;
        if PAngle < 90 then
          Inc(NumPx, H);
        FilterEdge(Above, NumPx, Strength);
      end;
      if HaveLeft then
      begin
        Strength := EdgeFilterStrength(W, H, FilterType, PAngle - 180);
        NumPx := Min(H, MaxY - Y + 1) + 1;
        if PAngle > 180 then
          Inc(NumPx, W);
        FilterEdge(Left, NumPx, Strength);
      end;
    end;
    if UseEdgeUpsample(W, H, FilterType, PAngle - 90) then
    begin
      UpsampleAbove := 1;
      NumPx := W;
      if PAngle < 90 then
        Inc(NumPx, H);
      UpsampleEdge(Above, NumPx, BitDepth);
    end;
    if UseEdgeUpsample(W, H, FilterType, PAngle - 180) then
    begin
      UpsampleLeft := 1;
      NumPx := H;
      if PAngle > 180 then
        Inc(NumPx, W);
      UpsampleEdge(Left, NumPx, BitDepth);
    end;
  end;
  Dx := 0;
  Dy := 0;
  if PAngle < 90 then
    Dx := Dr_Intra_Derivative[PAngle]
  else if (PAngle > 90) and (PAngle < 180) then
    Dx := Dr_Intra_Derivative[180 - PAngle];
  if (PAngle > 90) and (PAngle < 180) then
    Dy := Dr_Intra_Derivative[PAngle - 90]
  else if PAngle > 180 then
    Dy := Dr_Intra_Derivative[270 - PAngle];

  if PAngle < 90 then
  begin
    MaxBaseX := (W + H - 1) shl UpsampleAbove;
    for Row := 0 to H - 1 do
    begin
      Line := Target.First + Row * Target.Stride;
      Index := (Row + 1) * Dx;
      Shift := ((Index shl UpsampleAbove) shr 1) and $1F;
      for Col := 0 to W - 1 do
      begin
        Base := (Index shr (6 - UpsampleAbove)) + (Col shl UpsampleAbove);
        if Base < MaxBaseX then
          Line[Col] := (Above[Base] * (32 - Shift) + Above[Base + 1] * Shift + 16) shr 5
        else
          Line[Col] := Above[MaxBaseX];
      end;
    end;
  end
  else if (PAngle > 90) and (PAngle < 180) then
  begin
    for Row := 0 to H - 1 do
    begin
      Line := Target.First + Row * Target.Stride;
      for Col := 0 to W - 1 do
      begin
        Index := (Col shl 6) - (Row + 1) * Dx;
        Base := SarLongint(Index, 6 - UpsampleAbove);
        if Base >= -(1 shl UpsampleAbove) then
        begin
          Shift := SarLongint(Index * (1 shl UpsampleAbove), 1) and $1F;
          Line[Col] := (Above[Base] * (32 - Shift) + Above[Base + 1] * Shift + 16) shr 5;
        end
        else
        begin
          Index := (Row shl 6) - (Col + 1) * Dy;
          Base := SarLongint(Index, 6 - UpsampleLeft);
          Shift := SarLongint(Index * (1 shl UpsampleLeft), 1) and $1F;
          Line[Col] := (Left[Base] * (32 - Shift) + Left[Base + 1] * Shift + 16) shr 5;
        end;
      end;
    end;
  end
  else if PAngle > 180 then
  begin
    for Col := 0 to W - 1 do
    begin
      Index := (Col + 1) * Dy;
      Shift := ((Index shl UpsampleLeft) shr 1) and $1F;
      for Row := 0 to H - 1 do
      begin
        Base := (Index shr (6 - UpsampleLeft)) + (Row shl UpsampleLeft);
        (Target.First + Row * Target.Stride)[Col] :=
          (Left[Base] * (32 - Shift) + Left[Base + 1] * Shift + 16) shr 5;
      end;
    end;
  end
  else if PAngle = 90 then
  begin
    for Row := 0 to H - 1 do
    begin
      Line := Target.First + Row * Target.Stride;
      for Col := 0 to W - 1 do
        Line[Col] := Above[Col];
    end;
  end
  else
  begin
    for Row := 0 to H - 1 do
    begin
      Line := Target.First + Row * Target.Stride;
      for Col := 0 to W - 1 do
        Line[Col] := Left[Row];
    end;
  end;
end;

procedure PredictIntra(Tile: TTileContext; Plane, X, Y: Integer; HaveLeft, HaveAbove, HaveAboveRt,
  HaveBelowLft: Boolean; Mode, Log2W, Log2H: Integer);
var
  W, H, MaxX, MaxY, BitDepth, Index, Limit, Stride, Corner: Integer;
  Above, Left: TEdgePointer;
  Samples: PWord;
  PlaneInfo: PPlane;
  Target: TPredictionTarget;
begin
  W := 1 shl Log2W;
  H := 1 shl Log2H;
  BitDepth := Tile.Sequence^.BitDepth;
  MaxX := ((Tile.Header^.MiCols * MI_SIZE) shr Tile.SubsamplingX(Plane)) - 1;
  MaxY := ((Tile.Header^.MiRows * MI_SIZE) shr Tile.SubsamplingY(Plane)) - 1;
  PlaneInfo := @Tile.Frame.CurrFrame.Planes[Plane];
  Stride := PlaneInfo^.Stride;
  Samples := @PlaneInfo^.Samples[0];
  Above := @Tile.IntraAboveRow[IntraEdgeOrigin];
  Left := @Tile.IntraLeftCol[IntraEdgeOrigin];

  if (not HaveAbove) and HaveLeft then
  begin
    for Index := 0 to W + H - 1 do
      Above[Index] := Samples[Y * Stride + X - 1];
  end
  else if (not HaveAbove) and (not HaveLeft) then
  begin
    for Index := 0 to W + H - 1 do
      Above[Index] := (1 shl (BitDepth - 1)) - 1;
  end
  else
  begin
    if HaveAboveRt then
      Limit := Min(MaxX, X + 2 * W - 1)
    else
      Limit := Min(MaxX, X + W - 1);
    for Index := 0 to W + H - 1 do
      Above[Index] := Samples[(Y - 1) * Stride + Min(Limit, X + Index)];
  end;

  if (not HaveLeft) and HaveAbove then
  begin
    for Index := 0 to W + H - 1 do
      Left[Index] := Samples[(Y - 1) * Stride + X];
  end
  else if (not HaveLeft) and (not HaveAbove) then
  begin
    for Index := 0 to W + H - 1 do
      Left[Index] := (1 shl (BitDepth - 1)) + 1;
  end
  else
  begin
    if HaveBelowLft then
      Limit := Min(MaxY, Y + 2 * H - 1)
    else
      Limit := Min(MaxY, Y + H - 1);
    for Index := 0 to W + H - 1 do
      Left[Index] := Samples[Min(Limit, Y + Index) * Stride + X - 1];
  end;

  if HaveAbove and HaveLeft then
    Corner := Samples[(Y - 1) * Stride + X - 1]
  else if HaveAbove then
    Corner := Samples[(Y - 1) * Stride + X]
  else if HaveLeft then
    Corner := Samples[Y * Stride + X - 1]
  else
    Corner := 1 shl (BitDepth - 1);
  Above[-1] := Corner;
  Left[-1] := Corner;

  Target.First := Samples + Y * Stride + X;
  Target.Stride := Stride;
  Target.W := W;
  Target.H := H;
  Target.MaxValue := (1 shl BitDepth) - 1;

  if (Plane = 0) and Tile.use_filter_intra then
    PredictRecursive(Target, Above, Left, Tile.filter_intra_mode)
  else if (Mode >= V_PRED) and (Mode <= D67_PRED) then
    PredictDirectional(Tile, Target, Above, Left, Plane, X, Y, HaveLeft, HaveAbove, Mode, MaxX, MaxY)
  else if (Mode = SMOOTH_PRED) or (Mode = SMOOTH_V_PRED) or (Mode = SMOOTH_H_PRED) then
    PredictSmooth(Target, Above, Left, Mode, Log2W, Log2H)
  else if Mode = DC_PRED then
    PredictDc(Target, Above, Left, HaveLeft, HaveAbove, Log2W, Log2H, BitDepth)
  else
    PredictPaeth(Target, Above, Left);
end;

end.
