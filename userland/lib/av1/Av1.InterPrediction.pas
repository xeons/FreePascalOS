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
  The inter prediction process (specification section 7.11.3.1), the
  entry point compute_prediction calls as predict_inter: the rounding
  variables, local and global warp, motion vector scaling and block
  inter prediction for each reference, then the combination (a single
  prediction, the average, distance weights, or a mask blend for wedge,
  difference weighted and inter-intra prediction), and overlapped block
  motion compensation.
}
unit Av1.InterPrediction;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.Picture, Av1.References, Av1.FrameContext,
  Av1.TileContext, Av1.MotionVectorScaling, Av1.BlockInterPrediction, Av1.Warp,
  Av1.CompoundMasks, Av1.Obmc;

{ predict_inter( plane, x, y, w, h, candRow, candCol ). }
procedure PredictInter(Tile: TTileContext; Plane, BaseX, BaseY, W, H, CandRow, CandCol: Integer);

implementation

{ The rounding variables derivation process. }
procedure DeriveRoundingVariables(Tile: TTileContext; IsCompound: Boolean);
begin
  Tile.InterRound0 := 3;
  if IsCompound then
    Tile.InterRound1 := 7
  else
    Tile.InterRound1 := 11;
  if Tile.Sequence^.BitDepth = 12 then
  begin
    Tile.InterRound0 := Tile.InterRound0 + 2;
    if not IsCompound then
      Tile.InterRound1 := Tile.InterRound1 - 2;
  end;
  Tile.InterPostRound := 2 * FILTER_BITS - (Tile.InterRound0 + Tile.InterRound1);
end;

{ Steps 5 to 13 of the process: preds[ refList ]. }
procedure PredictFromReference(Tile: TTileContext; Plane, X, Y, W, H, CandRow, CandCol, RefList: Integer);
var
  Info: PBlockInfo;
  RefFrame, UseWarp, StartX, StartY, StepX, StepY, LastX, LastY, SubX, SubY, I8, J8: Integer;
  ScaleWidth, ScaleHeight, BlockWidth, BlockHeight: Integer;
  GlobalValid, IsGlobalMode: Boolean;
  Alpha, Beta, Gamma, Delta: Integer;
  Reference: TReferenceFrame;
  Picture: TPicture;
  Pred: PInteger;
begin
  Info := Tile.Frame.Block(CandRow, CandCol);
  RefFrame := Info^.RefFrame[RefList];
  IsGlobalMode := (Tile.YMode = GLOBALMV) or (Tile.YMode = GLOBAL_GLOBALMV);
  GlobalValid := False;
  if IsGlobalMode and (Tile.Header^.GmType[RefFrame] > TRANSLATION) then
    SetupShear(Tile.Header^.gm_params[RefFrame], GlobalValid, Alpha, Beta, Gamma, Delta);
  if (W < 8) or (H < 8) then
    UseWarp := 0
  else if Tile.Header^.force_integer_mv <> 0 then
    UseWarp := 0
  else if (Tile.motion_mode = LOCALWARP) and Tile.LocalValid then
    UseWarp := 1
  else if IsGlobalMode and (Tile.Header^.GmType[RefFrame] > TRANSLATION) and
    not IsScaled(Tile, RefFrame) and GlobalValid then
    UseWarp := 2
  else
    UseWarp := 0;
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  if Tile.use_intrabc then
  begin
    Reference := nil;
    Picture := Tile.Frame.CurrFrame;
    ScaleWidth := Tile.Header^.UpscaledWidth;
    ScaleHeight := Tile.Header^.FrameHeight;
    BlockWidth := Tile.Header^.MiCols * MI_SIZE;
    BlockHeight := Tile.Header^.MiRows * MI_SIZE;
  end
  else
  begin
    Reference := Tile.Frame.ReferenceFrames[RefFrame];
    Picture := Reference.Picture;
    ScaleWidth := Reference.RefUpscaledWidth;
    ScaleHeight := Reference.RefFrameHeight;
    BlockWidth := ScaleWidth;
    BlockHeight := ScaleHeight;
  end;
  LastX := ((BlockWidth + SubX) shr SubX) - 1;
  LastY := ((BlockHeight + SubY) shr SubY) - 1;
  Pred := @Tile.InterPreds[RefList, 0];
  if UseWarp <> 0 then
  begin
    for I8 := 0 to (H - 1) shr 3 do
      for J8 := 0 to (W - 1) shr 3 do
        if UseWarp = 1 then
          WarpBlock(Tile, Tile.LocalWarpParams, Plane, Picture, LastX, LastY, X, Y, I8, J8, W, H,
            Pred, PredictionStride)
        else
          WarpBlock(Tile, Tile.Header^.gm_params[RefFrame], Plane, Picture, LastX, LastY, X, Y, I8, J8,
            W, H, Pred, PredictionStride);
  end
  else
  begin
    ScaleMotionVector(Tile, Plane, ScaleWidth, ScaleHeight, X, Y, Info^.Mv[RefList], StartX, StartY,
      StepX, StepY);
    PredictBlockInter(Tile, Plane, Picture, LastX, LastY, StartX, StartY, StepX, StepY, W, H,
      Info^.InterpFilter[1], Info^.InterpFilter[0], Pred, PredictionStride);
  end;
end;

procedure WriteSinglePrediction(Tile: TTileContext; Plane, X, Y, W, H: Integer);
var
  I, J, MaximumSample, Stride: Integer;
  Row: PWord;
  Pred: PInteger;
begin
  MaximumSample := (1 shl Tile.Sequence^.BitDepth) - 1;
  Stride := Tile.Frame.CurrFrame.Planes[Plane].Stride;
  for I := 0 to H - 1 do
  begin
    Row := @Tile.Frame.CurrFrame.Planes[Plane].Samples[(Y + I) * Stride + X];
    Pred := @Tile.InterPreds[0, I * PredictionStride];
    for J := 0 to W - 1 do
      Row[J] := Clip3(0, MaximumSample, Pred[J]);
  end;
end;

procedure WriteAveragePrediction(Tile: TTileContext; Plane, X, Y, W, H: Integer);
var
  I, J, MaximumSample, Stride, Shift: Integer;
  Row: PWord;
  Pred0, Pred1: PInteger;
begin
  MaximumSample := (1 shl Tile.Sequence^.BitDepth) - 1;
  Stride := Tile.Frame.CurrFrame.Planes[Plane].Stride;
  Shift := 1 + Tile.InterPostRound;
  for I := 0 to H - 1 do
  begin
    Row := @Tile.Frame.CurrFrame.Planes[Plane].Samples[(Y + I) * Stride + X];
    Pred0 := @Tile.InterPreds[0, I * PredictionStride];
    Pred1 := @Tile.InterPreds[1, I * PredictionStride];
    for J := 0 to W - 1 do
      Row[J] := Clip3(0, MaximumSample, Round2(Pred0[J] + Pred1[J], Shift));
  end;
end;

procedure WriteDistancePrediction(Tile: TTileContext; Plane, X, Y, W, H: Integer);
var
  I, J, MaximumSample, Stride, Shift: Integer;
  Row: PWord;
  Pred0, Pred1: PInteger;
begin
  MaximumSample := (1 shl Tile.Sequence^.BitDepth) - 1;
  Stride := Tile.Frame.CurrFrame.Planes[Plane].Stride;
  Shift := 4 + Tile.InterPostRound;
  for I := 0 to H - 1 do
  begin
    Row := @Tile.Frame.CurrFrame.Planes[Plane].Samples[(Y + I) * Stride + X];
    Pred0 := @Tile.InterPreds[0, I * PredictionStride];
    Pred1 := @Tile.InterPreds[1, I * PredictionStride];
    for J := 0 to W - 1 do
      Row[J] := Clip3(0, MaximumSample,
        Round2(Tile.FwdWeight * Pred0[J] + Tile.BckWeight * Pred1[J], Shift));
  end;
end;

procedure PredictInter(Tile: TTileContext; Plane, BaseX, BaseY, W, H, CandRow, CandCol: Integer);
var
  IsCompound, Valid: Boolean;
  Alpha, Beta, Gamma, Delta: Integer;
begin
  IsCompound := Tile.Frame.Block(CandRow, CandCol)^.RefFrame[1] > INTRA_FRAME;
  DeriveRoundingVariables(Tile, IsCompound);
  if (Plane = 0) and (Tile.motion_mode = LOCALWARP) then
  begin
    EstimateWarp(Tile);
    if Tile.LocalValid then
    begin
      SetupShear(Tile.LocalWarpParams, Valid, Alpha, Beta, Gamma, Delta);
      Tile.LocalValid := Valid;
    end;
  end;
  PredictFromReference(Tile, Plane, BaseX, BaseY, W, H, CandRow, CandCol, 0);
  if IsCompound then
    PredictFromReference(Tile, Plane, BaseX, BaseY, W, H, CandRow, CandCol, 1);

  if (Tile.compound_type = COMPOUND_WEDGE) and (Plane = 0) then
    BuildWedgeMask(Tile, W, H)
  else if Tile.compound_type = COMPOUND_INTRA then
    BuildIntraVariantMask(Tile, W, H)
  else if (Tile.compound_type = COMPOUND_DIFFWTD) and (Plane = 0) then
    BuildDifferenceWeightMask(Tile, W, H);
  if Tile.compound_type = COMPOUND_DISTANCE then
    ComputeDistanceWeights(Tile, CandRow, CandCol);

  if (not IsCompound) and (not Tile.IsInterIntra) then
    WriteSinglePrediction(Tile, Plane, BaseX, BaseY, W, H)
  else if Tile.compound_type = COMPOUND_AVERAGE then
    WriteAveragePrediction(Tile, Plane, BaseX, BaseY, W, H)
  else if Tile.compound_type = COMPOUND_DISTANCE then
    WriteDistancePrediction(Tile, Plane, BaseX, BaseY, W, H)
  else
    BlendWithMask(Tile, Plane, BaseX, BaseY, W, H);

  if Tile.motion_mode = OBMC then
    OverlappedMotionCompensation(Tile, Plane, W, H);
end;

end.
