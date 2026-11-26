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
  The masks that blend two predictions (specification sections 7.11.3.11
  to 7.11.3.15): the wedge masks (WedgeMasks, built once when the unit
  is initialized, from the master masks), the difference weight mask,
  the intra mode variant mask, the mask blend process and the distance
  weights of COMPOUND_DISTANCE.

  The mask lives in TTileContext.InterMask, MAX_SB_SIZE entries per row;
  the luma plane's mask is kept for the chroma planes of the block.
}
unit Av1.CompoundMasks;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.TileContext;

const
  MaskStride = MAX_SB_SIZE;
  PredictionStride = MAX_SB_SIZE;

{ The wedge mask process for a W by H luma block. }
procedure BuildWedgeMask(Tile: TTileContext; W, H: Integer);
{ The difference weight mask process from Tile.InterPreds. }
procedure BuildDifferenceWeightMask(Tile: TTileContext; W, H: Integer);
{ The intra mode variant mask process. }
procedure BuildIntraVariantMask(Tile: TTileContext; W, H: Integer);
{ The mask blend process into CurrFrame at (DestinationX, DestinationY) of Plane. }
procedure BlendWithMask(Tile: TTileContext; Plane, DestinationX, DestinationY, W, H: Integer);
{ The distance weights process: Tile.FwdWeight and Tile.BckWeight. }
procedure ComputeDistanceWeights(Tile: TTileContext; CandRow, CandCol: Integer);

implementation

var
  { WedgeMasks[ bsize ][ flipSign ][ wedge ] as Block_Width by Block_Height
    bytes at WedgeMaskOffsets[ bsize, flipSign, wedge ] in WedgeMaskData. }
  WedgeMaskData: array of Byte;
  WedgeMaskOffsets: array[0..BLOCK_SIZES - 1, 0..1, 0..WEDGE_TYPES - 1] of Integer;

function BlockShape(BlockSize: Integer): Integer;
var
  W4, H4: Integer;
begin
  W4 := Num_4x4_Blocks_Wide[BlockSize];
  H4 := Num_4x4_Blocks_High[BlockSize];
  if H4 > W4 then
    Result := 0
  else if H4 < W4 then
    Result := 1
  else
    Result := 2;
end;

procedure InitializeWedgeMasks;
var
  MasterMask: array[0..5, 0..MASK_MASTER_SIZE - 1, 0..MASK_MASTER_SIZE - 1] of Byte;
  I, J, Shift, W, H, Mask, BlockSize, Wedge, Direction, XOffset, YOffset, Sum, Average: Integer;
  FlipSign, Total, Offset: Integer;
begin
  W := MASK_MASTER_SIZE;
  H := MASK_MASTER_SIZE;
  for J := 0 to W - 1 do
  begin
    Shift := MASK_MASTER_SIZE div 4;
    I := 0;
    while I < H do
    begin
      MasterMask[WEDGE_OBLIQUE63, I, J] := Wedge_Master_Oblique_Even[Clip3(0, MASK_MASTER_SIZE - 1, J - Shift)];
      Dec(Shift);
      MasterMask[WEDGE_OBLIQUE63, I + 1, J] := Wedge_Master_Oblique_Odd[Clip3(0, MASK_MASTER_SIZE - 1, J - Shift)];
      MasterMask[WEDGE_VERTICAL, I, J] := Wedge_Master_Vertical[J];
      MasterMask[WEDGE_VERTICAL, I + 1, J] := Wedge_Master_Vertical[J];
      Inc(I, 2);
    end;
  end;
  for I := 0 to H - 1 do
    for J := 0 to W - 1 do
    begin
      Mask := MasterMask[WEDGE_OBLIQUE63, I, J];
      MasterMask[WEDGE_OBLIQUE27, J, I] := Mask;
      MasterMask[WEDGE_OBLIQUE117, I, W - 1 - J] := 64 - Mask;
      MasterMask[WEDGE_OBLIQUE153, W - 1 - J, I] := 64 - Mask;
      MasterMask[WEDGE_HORIZONTAL, J, I] := MasterMask[WEDGE_VERTICAL, I, J];
    end;
  Total := 0;
  for BlockSize := BLOCK_8X8 to BLOCK_SIZES - 1 do
    if Wedge_Bits[BlockSize] > 0 then
      Inc(Total, Block_Width(BlockSize) * Block_Height(BlockSize) * 2 * WEDGE_TYPES);
  SetLength(WedgeMaskData, Total);
  Offset := 0;
  for BlockSize := BLOCK_8X8 to BLOCK_SIZES - 1 do
  begin
    if Wedge_Bits[BlockSize] = 0 then
      Continue;
    W := Block_Width(BlockSize);
    H := Block_Height(BlockSize);
    for Wedge := 0 to WEDGE_TYPES - 1 do
    begin
      Direction := Wedge_Codebook[BlockShape(BlockSize), Wedge, 0];
      XOffset := MASK_MASTER_SIZE div 2 - ((Wedge_Codebook[BlockShape(BlockSize), Wedge, 1] * W) shr 3);
      YOffset := MASK_MASTER_SIZE div 2 - ((Wedge_Codebook[BlockShape(BlockSize), Wedge, 2] * H) shr 3);
      Sum := 0;
      for I := 0 to W - 1 do
        Inc(Sum, MasterMask[Direction, YOffset, XOffset + I]);
      for I := 1 to H - 1 do
        Inc(Sum, MasterMask[Direction, YOffset + I, XOffset]);
      Average := (Sum + (W + H - 1) div 2) div (W + H - 1);
      FlipSign := Ord(Average < 32);
      WedgeMaskOffsets[BlockSize, FlipSign, Wedge] := Offset;
      WedgeMaskOffsets[BlockSize, 1 - FlipSign, Wedge] := Offset + W * H;
      for I := 0 to H - 1 do
        for J := 0 to W - 1 do
        begin
          WedgeMaskData[Offset + I * W + J] := MasterMask[Direction, YOffset + I, XOffset + J];
          WedgeMaskData[Offset + W * H + I * W + J] := 64 - MasterMask[Direction, YOffset + I, XOffset + J];
        end;
      Inc(Offset, 2 * W * H);
    end;
  end;
end;

procedure BuildWedgeMask(Tile: TTileContext; W, H: Integer);
var
  I, J, BlockWidth: Integer;
  Source: PByte;
begin
  BlockWidth := Block_Width(Tile.MiSize);
  Source := @WedgeMaskData[WedgeMaskOffsets[Tile.MiSize, Tile.wedge_sign, Tile.wedge_index]];
  for I := 0 to H - 1 do
    for J := 0 to W - 1 do
      Tile.InterMask[I * MaskStride + J] := Source[I * BlockWidth + J];
end;

procedure BuildDifferenceWeightMask(Tile: TTileContext; W, H: Integer);
var
  I, J, Difference, Mask, Shift: Integer;
begin
  Shift := (Tile.Sequence^.BitDepth - 8) + Tile.InterPostRound;
  for I := 0 to H - 1 do
    for J := 0 to W - 1 do
    begin
      Difference := Abs(Tile.InterPreds[0, I * PredictionStride + J] - Tile.InterPreds[1, I * PredictionStride + J]);
      Difference := Round2(Difference, Shift);
      Mask := Clip3(0, 64, 38 + Difference div 16);
      if Tile.mask_type <> 0 then
        Tile.InterMask[I * MaskStride + J] := 64 - Mask
      else
        Tile.InterMask[I * MaskStride + J] := Mask;
    end;
end;

procedure BuildIntraVariantMask(Tile: TTileContext; W, H: Integer);
var
  I, J, SizeScale, Mask: Integer;
begin
  SizeScale := MAX_SB_SIZE div Max(H, W);
  for I := 0 to H - 1 do
    for J := 0 to W - 1 do
    begin
      case Tile.interintra_mode of
        II_V_PRED:
          Mask := Ii_Weights_1d[I * SizeScale];
        II_H_PRED:
          Mask := Ii_Weights_1d[J * SizeScale];
        II_SMOOTH_PRED:
          Mask := Ii_Weights_1d[Min(I, J) * SizeScale];
      else
        Mask := 32;
      end;
      Tile.InterMask[I * MaskStride + J] := Mask;
    end;
end;

procedure BlendWithMask(Tile: TTileContext; Plane, DestinationX, DestinationY, W, H: Integer);
var
  X, Y, SubX, SubY, M, Pred0, Pred1, MaximumSample, PostRound: Integer;
  OwnMask: Boolean;
  Mask: PByte;
  Row: PWord;
  Stride: Integer;
begin
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  OwnMask := ((SubX = 0) and (SubY = 0)) or (Tile.interintra and not Tile.wedge_interintra);
  MaximumSample := (1 shl Tile.Sequence^.BitDepth) - 1;
  PostRound := Tile.InterPostRound;
  Mask := @Tile.InterMask[0];
  Stride := Tile.Frame.CurrFrame.Planes[Plane].Stride;
  for Y := 0 to H - 1 do
  begin
    Row := @Tile.Frame.CurrFrame.Planes[Plane].Samples[(Y + DestinationY) * Stride + DestinationX];
    for X := 0 to W - 1 do
    begin
      if OwnMask then
        M := Mask[Y * MaskStride + X]
      else if (SubX <> 0) and (SubY = 0) then
        M := Round2(Mask[Y * MaskStride + 2 * X] + Mask[Y * MaskStride + 2 * X + 1], 1)
      else
        M := Round2(Mask[2 * Y * MaskStride + 2 * X] + Mask[2 * Y * MaskStride + 2 * X + 1] +
          Mask[(2 * Y + 1) * MaskStride + 2 * X] + Mask[(2 * Y + 1) * MaskStride + 2 * X + 1], 2);
      if Tile.interintra then
      begin
        Pred0 := Clip3(0, MaximumSample, Round2(Tile.InterPreds[0, Y * PredictionStride + X], PostRound));
        Pred1 := Row[X];
        Row[X] := Round2(M * Pred1 + (64 - M) * Pred0, 6);
      end
      else
      begin
        Pred0 := Tile.InterPreds[0, Y * PredictionStride + X];
        Pred1 := Tile.InterPreds[1, Y * PredictionStride + X];
        Row[X] := Clip3(0, MaximumSample, Round2(M * Pred0 + (64 - M) * Pred1, 6 + PostRound));
      end;
    end;
  end;
end;

procedure ComputeDistanceWeights(Tile: TTileContext; CandRow, CandCol: Integer);
var
  Distance: array[0..1] of Integer;
  RefList, Hint, D0, D1, Order, Index, C0, C1: Integer;
  Info: PBlockInfo;
begin
  Info := Tile.Frame.Block(CandRow, CandCol);
  for RefList := 0 to 1 do
  begin
    Hint := Tile.Header^.OrderHints[Info^.RefFrame[RefList]];
    Distance[RefList] := Clip3(0, MAX_FRAME_DISTANCE, Abs(Tile.Frame.GetRelativeDist(Hint, Tile.Header^.OrderHint)));
  end;
  D0 := Distance[1];
  D1 := Distance[0];
  Order := Ord(D0 <= D1);
  if (D0 = 0) or (D1 = 0) then
  begin
    Tile.FwdWeight := Quant_Dist_Lookup[3, Order];
    Tile.BckWeight := Quant_Dist_Lookup[3, 1 - Order];
    Exit;
  end;
  Index := 0;
  while Index < 3 do
  begin
    C0 := Quant_Dist_Weight[Index, Order];
    C1 := Quant_Dist_Weight[Index, 1 - Order];
    if Order <> 0 then
    begin
      if D0 * C0 > D1 * C1 then
        Break;
    end
    else if D0 * C0 < D1 * C1 then
      Break;
    Inc(Index);
  end;
  Tile.FwdWeight := Quant_Dist_Lookup[Index, Order];
  Tile.BckWeight := Quant_Dist_Lookup[Index, 1 - Order];
end;

initialization
  InitializeWedgeMasks;
end.
