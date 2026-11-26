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
  The residual of a block (specification sections 5.11.34 to 5.11.36:
  residual, transform_block, transform_tree): the transform blocks of
  each plane in 64x64 chunks, the intra prediction of each one before
  its coefficients, then its reconstruction.
}
unit Av1.ResidualDecoding;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.TileContext;

procedure DecodeResidual(Tile: TTileContext);

implementation

uses
  Av1.TransformSyntax, Av1.CoefficientSyntax, Av1.IntraPrediction, Av1.PalettePrediction,
  Av1.ChromaFromLuma, Av1.Reconstruction;

function SuperblockMask(Tile: TTileContext): Integer; inline;
begin
  if Tile.Sequence^.use_128x128_superblock then
    Result := 31
  else
    Result := 15;
end;

procedure TransformBlock(Tile: TTileContext; Plane, BaseX, BaseY, TxSz, X, Y: Integer);
var
  StartX, StartY, SubX, SubY, Row, Col, SubBlockMiRow, SubBlockMiCol, StepX, StepY, MaxX, MaxY: Integer;
  Mode, Log2W, Log2H, Eob, I, J, LfIndex: Integer;
  IsCfl, HaveLeft, HaveAbove: Boolean;
  Frame: TFrameContext;
begin
  Frame := Tile.Frame;
  StartX := BaseX + 4 * X;
  StartY := BaseY + 4 * Y;
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  Row := (StartY shl SubY) shr MI_SIZE_LOG2;
  Col := (StartX shl SubX) shr MI_SIZE_LOG2;
  SubBlockMiRow := Row and SuperblockMask(Tile);
  SubBlockMiCol := Col and SuperblockMask(Tile);
  StepX := Tx_Width[TxSz] shr MI_SIZE_LOG2;
  StepY := Tx_Height[TxSz] shr MI_SIZE_LOG2;
  MaxX := (Tile.Header^.MiCols * MI_SIZE) shr SubX;
  MaxY := (Tile.Header^.MiRows * MI_SIZE) shr SubY;
  if (StartX >= MaxX) or (StartY >= MaxY) then
    Exit;
  if not Tile.is_inter then
  begin
    if ((Plane = 0) and (Tile.PaletteSizeY <> 0)) or ((Plane <> 0) and (Tile.PaletteSizeUV <> 0)) then
      PredictPalette(Tile, Plane, StartX, StartY, X, Y, TxSz)
    else
    begin
      IsCfl := (Plane > 0) and (Tile.UVMode = UV_CFL_PRED);
      if Plane = 0 then
        Mode := Tile.YMode
      else if IsCfl then
        Mode := DC_PRED
      else
        Mode := Tile.UVMode;
      Log2W := Tx_Width_Log2[TxSz];
      Log2H := Tx_Height_Log2[TxSz];
      if Plane = 0 then
      begin
        HaveLeft := Tile.AvailL;
        HaveAbove := Tile.AvailU;
      end
      else
      begin
        HaveLeft := Tile.AvailLChroma;
        HaveAbove := Tile.AvailUChroma;
      end;
      PredictIntra(Tile, Plane, StartX, StartY, HaveLeft or (X > 0), HaveAbove or (Y > 0),
        Tile.BlockDecoded(Plane, (SubBlockMiRow shr SubY) - 1, (SubBlockMiCol shr SubX) + StepX),
        Tile.BlockDecoded(Plane, (SubBlockMiRow shr SubY) + StepY, (SubBlockMiCol shr SubX) - 1),
        Mode, Log2W, Log2H);
      if IsCfl then
        PredictChromaFromLuma(Tile, Plane, StartX, StartY, TxSz);
    end;
    if Plane = 0 then
    begin
      Tile.MaxLumaW := StartX + StepX * 4;
      Tile.MaxLumaH := StartY + StepY * 4;
    end;
  end;
  if not Tile.skip then
  begin
    Eob := ReadCoefficients(Tile, Plane, StartX, StartY, TxSz);
    if Eob > 0 then
      Reconstruct(Tile, Plane, StartX, StartY, TxSz);
  end;
  for I := 0 to StepY - 1 do
  begin
    LfIndex := Frame.MiIndex((Row shr SubY) + I, (Col shr SubX));
    for J := 0 to StepX - 1 do
    begin
      Frame.LoopfilterTxSizes[Plane][LfIndex + J] := TxSz;
      Tile.SetBlockDecoded(Plane, (SubBlockMiRow shr SubY) + I, (SubBlockMiCol shr SubX) + J, True);
    end;
  end;
end;

procedure TransformTree(Tile: TTileContext; StartX, StartY, W, H: Integer);
var
  MaxX, MaxY, Row, Col, LumaTxSz, LumaW, LumaH: Integer;
begin
  MaxX := Tile.Header^.MiCols * MI_SIZE;
  MaxY := Tile.Header^.MiRows * MI_SIZE;
  if (StartX >= MaxX) or (StartY >= MaxY) then
    Exit;
  Row := StartY shr MI_SIZE_LOG2;
  Col := StartX shr MI_SIZE_LOG2;
  LumaTxSz := Tile.Frame.Block(Row, Col)^.InterTxSize;
  LumaW := Tx_Width[LumaTxSz];
  LumaH := Tx_Height[LumaTxSz];
  if (W <= LumaW) and (H <= LumaH) then
    TransformBlock(Tile, 0, StartX, StartY, FindTxSize(W, H), 0, 0)
  else if W > H then
  begin
    TransformTree(Tile, StartX, StartY, W div 2, H);
    TransformTree(Tile, StartX + W div 2, StartY, W div 2, H);
  end
  else if W < H then
  begin
    TransformTree(Tile, StartX, StartY, W, H div 2);
    TransformTree(Tile, StartX, StartY + H div 2, W, H div 2);
  end
  else
  begin
    TransformTree(Tile, StartX, StartY, W div 2, H div 2);
    TransformTree(Tile, StartX + W div 2, StartY, W div 2, H div 2);
    TransformTree(Tile, StartX, StartY + H div 2, W div 2, H div 2);
    TransformTree(Tile, StartX + W div 2, StartY + H div 2, W div 2, H div 2);
  end;
end;

procedure DecodeResidual(Tile: TTileContext);
var
  WidthChunks, HeightChunks, MiSizeChunk, ChunkX, ChunkY, MiRowChunk, MiColChunk: Integer;
  Plane, TxSz, StepX, StepY, PlaneSz, Num4x4W, Num4x4H, SubX, SubY, BaseX, BaseY: Integer;
  BaseXBlock, BaseYBlock, X, Y, PlaneCount: Integer;
begin
  WidthChunks := Max(1, Block_Width(Tile.MiSize) shr 6);
  HeightChunks := Max(1, Block_Height(Tile.MiSize) shr 6);
  if (WidthChunks > 1) or (HeightChunks > 1) then
    MiSizeChunk := BLOCK_64X64
  else
    MiSizeChunk := Tile.MiSize;
  PlaneCount := 1 + Ord(Tile.HasChroma) * 2;
  for ChunkY := 0 to HeightChunks - 1 do
    for ChunkX := 0 to WidthChunks - 1 do
    begin
      MiRowChunk := Tile.MiRow + (ChunkY shl 4);
      MiColChunk := Tile.MiCol + (ChunkX shl 4);
      for Plane := 0 to PlaneCount - 1 do
      begin
        if Tile.Lossless then
          TxSz := TX_4X4
        else
          TxSz := GetTxSize(Tile, Plane, Tile.TxSize);
        StepX := Tx_Width[TxSz] shr 2;
        StepY := Tx_Height[TxSz] shr 2;
        PlaneSz := Tile.GetPlaneResidualSize(MiSizeChunk, Plane);
        Num4x4W := Num_4x4_Blocks_Wide[PlaneSz];
        Num4x4H := Num_4x4_Blocks_High[PlaneSz];
        SubX := Tile.SubsamplingX(Plane);
        SubY := Tile.SubsamplingY(Plane);
        BaseX := (MiColChunk shr SubX) * MI_SIZE;
        BaseY := (MiRowChunk shr SubY) * MI_SIZE;
        if Tile.is_inter and (not Tile.Lossless) and (Plane = 0) then
          TransformTree(Tile, BaseX, BaseY, Num4x4W * 4, Num4x4H * 4)
        else
        begin
          BaseXBlock := (Tile.MiCol shr SubX) * MI_SIZE;
          BaseYBlock := (Tile.MiRow shr SubY) * MI_SIZE;
          Y := 0;
          while Y < Num4x4H do
          begin
            X := 0;
            while X < Num4x4W do
            begin
              TransformBlock(Tile, Plane, BaseXBlock, BaseYBlock, TxSz, X + ((ChunkX shl 4) shr SubX),
                Y + ((ChunkY shl 4) shr SubY));
              Inc(X, StepX);
            end;
            Inc(Y, StepY);
          end;
        end;
      end;
    end;
end;

end.
