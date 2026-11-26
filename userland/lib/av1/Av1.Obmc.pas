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
  Overlapped block motion compensation (specification sections 7.11.3.9
  and 7.11.3.10): the block's prediction blended near its top and left
  edges with predictions made with the motion vectors of the inter
  blocks above and to the left.
}
unit Av1.Obmc;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.References, Av1.FrameContext, Av1.TileContext,
  Av1.MotionVectorScaling, Av1.BlockInterPrediction;

{ The overlapped motion compensation process for Plane of the block, W by H. }
procedure OverlappedMotionCompensation(Tile: TTileContext; Plane, W, H: Integer);

implementation

const
  ObmcStride = MAX_SB_SIZE;

function ObmcMask(Length: Integer): PByte;
begin
  case Length of
    2: Result := @Obmc_Mask_2[0];
    4: Result := @Obmc_Mask_4[0];
    8: Result := @Obmc_Mask_8[0];
    16: Result := @Obmc_Mask_16[0];
  else
    Result := @Obmc_Mask_32[0];
  end;
end;

{ predict_overlap( ) followed by the overlap blending process. }
procedure PredictOverlap(Tile: TTileContext; Plane, CandRow, CandCol, X4, Y4, PredW, PredH,
  Pass: Integer; Mask: PByte);
var
  Info: PBlockInfo;
  Reference: TReferenceFrame;
  SubX, SubY, PredX, PredY, StartX, StartY, StepX, StepY, LastX, LastY: Integer;
  I, J, M, MaximumSample, Stride: Integer;
  Prediction: PInteger;
  Row: PWord;
begin
  Info := Tile.Frame.Block(CandRow, CandCol);
  Reference := Tile.Frame.ReferenceFrames[Info^.RefFrame[0]];
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  PredX := (X4 * 4) shr SubX;
  PredY := (Y4 * 4) shr SubY;
  ScaleMotionVector(Tile, Plane, Reference.RefUpscaledWidth, Reference.RefFrameHeight, PredX, PredY,
    Info^.Mv[0], StartX, StartY, StepX, StepY);
  LastX := ((Reference.RefUpscaledWidth + SubX) shr SubX) - 1;
  LastY := ((Reference.RefFrameHeight + SubY) shr SubY) - 1;
  Prediction := @Tile.ObmcPred[0];
  PredictBlockInter(Tile, Plane, Reference.Picture, LastX, LastY, StartX, StartY, StepX, StepY,
    PredW, PredH, Info^.InterpFilter[1], Info^.InterpFilter[0], Prediction, ObmcStride);
  MaximumSample := (1 shl Tile.Sequence^.BitDepth) - 1;
  Stride := Tile.Frame.CurrFrame.Planes[Plane].Stride;
  for I := 0 to PredH - 1 do
  begin
    Row := @Tile.Frame.CurrFrame.Planes[Plane].Samples[(PredY + I) * Stride + PredX];
    for J := 0 to PredW - 1 do
    begin
      if Pass = 0 then
        M := Mask[I]
      else
        M := Mask[J];
      Row[J] := Round2(M * Row[J] + (64 - M) * Clip3(0, MaximumSample, Prediction[I * ObmcStride + J]), 6);
    end;
  end;
end;

procedure OverlappedMotionCompensation(Tile: TTileContext; Plane, W, H: Integer);
var
  SubX, SubY, W4, H4, X4, Y4, Count, Limit, CandRow, CandCol, CandSize, Step4: Integer;
  PredW, PredH: Integer;
begin
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  if Tile.AvailU and (Tile.GetPlaneResidualSize(Tile.MiSize, Plane) >= BLOCK_8X8) then
  begin
    W4 := Num_4x4_Blocks_Wide[Tile.MiSize];
    X4 := Tile.MiCol;
    Y4 := Tile.MiRow;
    Count := 0;
    Limit := Min(4, Mi_Width_Log2[Tile.MiSize]);
    while (Count < Limit) and (X4 < Min(Tile.Header^.MiCols, Tile.MiCol + W4)) do
    begin
      CandRow := Tile.MiRow - 1;
      CandCol := X4 or 1;
      CandSize := Tile.Frame.Block(CandRow, CandCol)^.MiSize;
      Step4 := Clip3(2, 16, Num_4x4_Blocks_Wide[CandSize]);
      if Tile.Frame.Block(CandRow, CandCol)^.RefFrame[0] > INTRA_FRAME then
      begin
        Inc(Count);
        PredW := Min(W, (Step4 * MI_SIZE) shr SubX);
        PredH := Min(H shr 1, 32 shr SubY);
        PredictOverlap(Tile, Plane, CandRow, CandCol, X4, Y4, PredW, PredH, 0, ObmcMask(PredH));
      end;
      Inc(X4, Step4);
    end;
  end;
  if Tile.AvailL then
  begin
    H4 := Num_4x4_Blocks_High[Tile.MiSize];
    X4 := Tile.MiCol;
    Y4 := Tile.MiRow;
    Count := 0;
    Limit := Min(4, Mi_Height_Log2[Tile.MiSize]);
    while (Count < Limit) and (Y4 < Min(Tile.Header^.MiRows, Tile.MiRow + H4)) do
    begin
      CandCol := Tile.MiCol - 1;
      CandRow := Y4 or 1;
      CandSize := Tile.Frame.Block(CandRow, CandCol)^.MiSize;
      Step4 := Clip3(2, 16, Num_4x4_Blocks_High[CandSize]);
      if Tile.Frame.Block(CandRow, CandCol)^.RefFrame[0] > INTRA_FRAME then
      begin
        Inc(Count);
        PredW := Min(W shr 1, 32 shr SubX);
        PredH := Min(H, (Step4 * MI_SIZE) shr SubY);
        PredictOverlap(Tile, Plane, CandRow, CandCol, X4, Y4, PredW, PredH, 1, ObmcMask(PredW));
      end;
      Inc(Y4, Step4);
    end;
  end;
end;

end.
