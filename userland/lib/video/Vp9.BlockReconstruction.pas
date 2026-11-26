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
  Reconstructing a VP9 block: an intra block transform block by
  transform block (predict, read the tokens, add the inverse transform,
  so that the next transform block predicts from this one), an inter
  block predicted whole from its references then its residual added
  transform block by transform block. Transform blocks wholly outside
  the frame are left out.
}
unit Vp9.BlockReconstruction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Vp9.FrameState, Vp9.TileState;

{ Reconstructs the intra block at Position. }
procedure ReconstructIntraBlock(Tile: TVp9TileState; constref Position: TVp9BlockPosition);
{ Predicts the inter block at Position from its references. }
procedure PredictInterBlock(Tile: TVp9TileState; constref Position: TVp9BlockPosition);
{ Adds the inter block's residual; returns the number of coefficients'
  positions read (0: none). }
function AddInterResidual(Tile: TVp9TileState; constref Position: TVp9BlockPosition): LongInt;
{ Clears the contexts of a block without coefficients. }
procedure ResetSkipContexts(Tile: TVp9TileState; constref Position: TVp9BlockPosition);

implementation

uses
  Vp9.Tables, Vp9.ScanTables, Vp9.ModeInfo, Vp9.Pictures, Vp9.FilterTables, Vp9.Residuals,
  Vp9.Transforms, Vp9.IntraPrediction, Vp9.InterPrediction;

type
  TPlaneGeometry = record
    SubsamplingX, SubsamplingY: LongInt;
    Width4x4, Height4x4: LongInt;      { the block's size in 4x4 units }
    WidthLog2: LongInt;                { the block's width in 4x4 units, log 2 }
    MaxBlocksWide, MaxBlocksHigh: LongInt;  { 0: no limit }
    Columns, Rows: LongInt;            { 4x4 units to visit }
    TransformSize: LongInt;
  end;

procedure PlaneGeometry(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition; Plane: LongInt;
  out Geometry: TPlaneGeometry);
var
  WidthUnits8, HeightUnits8, WidthLog2, Info: LongInt;
begin
  if Plane = 0 then
  begin
    Geometry.SubsamplingX := 0;
    Geometry.SubsamplingY := 0;
  end
  else
  begin
    Geometry.SubsamplingX := Frame.SubsamplingX;
    Geometry.SubsamplingY := Frame.SubsamplingY;
  end;
  { The block's size in 8x8 units (1 for blocks smaller than 8x8). }
  WidthUnits8 := BlockWidth8x8[Position.BlockSize];
  HeightUnits8 := BlockHeight8x8[Position.BlockSize];
  WidthLog2 := BlockWidthLog2[Position.BlockSize];
  if Position.BlockSize < Block8x8 then
    WidthLog2 := 1;
  Geometry.Width4x4 := (WidthUnits8 shl 1) shr Geometry.SubsamplingX;
  Geometry.Height4x4 := (HeightUnits8 shl 1) shr Geometry.SubsamplingY;
  Geometry.WidthLog2 := WidthLog2 - Geometry.SubsamplingX;
  if Position.ToRight >= 0 then
  begin
    Geometry.MaxBlocksWide := 0;
    Geometry.Columns := Geometry.Width4x4;
  end
  else
  begin
    Geometry.Columns := Geometry.Width4x4 + SarLongint(Position.ToRight, 5 + Geometry.SubsamplingX);
    Geometry.MaxBlocksWide := Geometry.Columns;
  end;
  if Position.ToBottom >= 0 then
  begin
    Geometry.MaxBlocksHigh := 0;
    Geometry.Rows := Geometry.Height4x4;
  end
  else
  begin
    Geometry.Rows := Geometry.Height4x4 + SarLongint(Position.ToBottom, 5 + Geometry.SubsamplingY);
    Geometry.MaxBlocksHigh := Geometry.Rows;
  end;
  Info := Position.Info^.TransformSize;
  if Plane = 0 then
    Geometry.TransformSize := Info
  else
    Geometry.TransformSize := ChromaTransformSizes[Position.BlockSize, Info, Geometry.SubsamplingX,
      Geometry.SubsamplingY];
end;

function PlaneTarget(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition; Plane: LongInt;
  constref Geometry: TPlaneGeometry; Column, Row: LongInt; out Stride: LongInt): PWord;
var
  P: PVp9Plane;
begin
  P := @Frame.Picture.Planes[Plane];
  Stride := P^.Stride;
  Result := P^.Origin + PtrInt(((Position.MiRow * 8) shr Geometry.SubsamplingY) + 4 * Row) * Stride +
    ((Position.MiColumn * 8) shr Geometry.SubsamplingX) + 4 * Column;
end;

procedure SelectScan(TransformSize, TransformType: LongInt; out Scan, Neighbors: PSmallInt);
begin
  case TransformSize of
    0:
      case TransformType of
        TypeAdstDct: begin Scan := @RowScan4x4[0]; Neighbors := @RowNeighbors4x4[0]; end;
        TypeDctAdst: begin Scan := @ColScan4x4[0]; Neighbors := @ColNeighbors4x4[0]; end;
      else
        begin Scan := @DefaultScan4x4[0]; Neighbors := @DefaultNeighbors4x4[0]; end;
      end;
    1:
      case TransformType of
        TypeAdstDct: begin Scan := @RowScan8x8[0]; Neighbors := @RowNeighbors8x8[0]; end;
        TypeDctAdst: begin Scan := @ColScan8x8[0]; Neighbors := @ColNeighbors8x8[0]; end;
      else
        begin Scan := @DefaultScan8x8[0]; Neighbors := @DefaultNeighbors8x8[0]; end;
      end;
    2:
      case TransformType of
        TypeAdstDct: begin Scan := @RowScan16x16[0]; Neighbors := @RowNeighbors16x16[0]; end;
        TypeDctAdst: begin Scan := @ColScan16x16[0]; Neighbors := @ColNeighbors16x16[0]; end;
      else
        begin Scan := @DefaultScan16x16[0]; Neighbors := @DefaultNeighbors16x16[0]; end;
      end;
  else
    begin Scan := @DefaultScan32x32[0]; Neighbors := @DefaultNeighbors32x32[0]; end;
  end;
end;

{ Reads a transform block's tokens into Tile.Coefficients and updates
  the contexts; returns its end of block. }
function ReadTransformBlock(Tile: TVp9TileState; constref Position: TVp9BlockPosition; Plane: LongInt;
  constref Geometry: TPlaneGeometry; Column, Row: LongInt; Scan, Neighbors: PSmallInt): LongInt;
var
  Frame: PVp9FrameState;
  Block: TVp9TokenBlock;
  Above, Left: PByte;
  Size4x4, Index, Context, AboveCount, LeftCount, Reference, PlaneType: LongInt;
  Dequantizer: TVp9Dequantizer;
  Value: Byte;
begin
  Frame := Tile.Frame;
  Above := @Tile.Above^.Coefficients[Plane][((Position.MiColumn * 2) shr Geometry.SubsamplingX) + Column];
  Left := @Tile.LeftCoefficients[Plane, (((Position.MiRow * 2) and 15) shr Geometry.SubsamplingY) + Row];
  Size4x4 := 1 shl Geometry.TransformSize;
  Context := 0;
  for Index := 0 to Size4x4 - 1 do
    if Above[Index] <> 0 then
    begin
      Context := 1;
      Break;
    end;
  for Index := 0 to Size4x4 - 1 do
    if Left[Index] <> 0 then
    begin
      Inc(Context);
      Break;
    end;
  Reference := Ord(IsInter(Position.Info));
  PlaneType := Ord(Plane > 0);
  Dequantizer := Frame^.Dequantizers[Position.Info^.Segment];
  Block.Probabilities := @Frame^.Probabilities^.Coefficients[Geometry.TransformSize][PlaneType, Reference];
  if Tile.CountsPointer <> nil then
  begin
    Block.Counts := @Tile.Counts.Coefficients[Geometry.TransformSize][PlaneType, Reference];
    Block.EndCounts := @Tile.Counts.EndOfBlockBranches[Geometry.TransformSize][PlaneType, Reference];
  end
  else
  begin
    Block.Counts := nil;
    Block.EndCounts := nil;
  end;
  Block.TransformSize := Geometry.TransformSize;
  if Plane = 0 then
  begin
    Block.DcStep := Dequantizer.LumaDc;
    Block.AcStep := Dequantizer.LumaAc;
  end
  else
  begin
    Block.DcStep := Dequantizer.ChromaDc;
    Block.AcStep := Dequantizer.ChromaAc;
  end;
  Block.Context := Context;
  Block.Scan := Scan;
  Block.Neighbors := Neighbors;
  Block.BitDepth := Frame^.BitDepth;
  Result := DecodeCoefficients(Tile.Decoder, Block, @Tile.Coefficients[0]);
  Value := Ord(Result > 0);
  if Geometry.TransformSize = 0 then
  begin
    Above[0] := Value;
    Left[0] := Value;
  end
  else
  begin
    AboveCount := Size4x4;
    if (Geometry.MaxBlocksWide <> 0) and (Size4x4 + Column > Geometry.MaxBlocksWide) then
      AboveCount := Geometry.MaxBlocksWide - Column;
    LeftCount := Size4x4;
    if (Geometry.MaxBlocksHigh <> 0) and (Size4x4 + Row > Geometry.MaxBlocksHigh) then
      LeftCount := Geometry.MaxBlocksHigh - Row;
    for Index := 0 to Size4x4 - 1 do
    begin
      if Index < AboveCount then
        Above[Index] := Value
      else
        Above[Index] := 0;
      if Index < LeftCount then
        Left[Index] := Value
      else
        Left[Index] := 0;
    end;
  end;
end;

procedure ClearCoefficients(Tile: TVp9TileState; Scan: PSmallInt; EndOfBlock: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to EndOfBlock - 1 do
    Tile.Coefficients[Scan[Index]] := 0;
end;

procedure ReconstructIntraBlock(Tile: TVp9TileState; constref Position: TVp9BlockPosition);
var
  Frame: PVp9FrameState;
  Plane, Row, Column, Step, Mode, TransformType, EndOfBlock, Stride: LongInt;
  Geometry: TPlaneGeometry;
  Edges: TVp9IntraEdges;
  Target: PWord;
  Scan, Neighbors: PSmallInt;
  Info: PVp9ModeInfo;
begin
  Frame := Tile.Frame;
  Info := Position.Info;
  for Plane := 0 to 2 do
  begin
    PlaneGeometry(Frame^, Position, Plane, Geometry);
    Step := 1 shl Geometry.TransformSize;
    Edges.FrameWidth := Frame^.Picture.Planes[Plane].AlignedWidth;
    Edges.FrameHeight := Frame^.Picture.Planes[Plane].AlignedHeight;
    Edges.PastRight := Position.ToRight < 0;
    Edges.PastBottom := Position.ToBottom < 0;
    Edges.BitDepth := Frame^.BitDepth;
    Row := 0;
    while Row < Geometry.Rows do
    begin
      Column := 0;
      while Column < Geometry.Columns do
      begin
        if Plane = 0 then
        begin
          Mode := Info^.Mode;
          if Info^.BlockSize < Block8x8 then
            Mode := Info^.Subblocks[(Row shl 1) + Column].Mode;
        end
        else
          Mode := Info^.UvMode;
        Target := PlaneTarget(Frame^, Position, Plane, Geometry, Column, Row, Stride);
        Edges.X := SarLongint(-Position.ToLeft, 3 + Geometry.SubsamplingX) + 4 * Column;
        Edges.Y := SarLongint(-Position.ToTop, 3 + Geometry.SubsamplingY) + 4 * Row;
        Edges.HaveAbove := (Row > 0) or (Position.Above <> nil);
        Edges.HaveLeft := (Column > 0) or (Position.Left <> nil);
        Edges.HaveRight := Column + Step < (1 shl Geometry.WidthLog2);
        PredictIntra(Mode, Geometry.TransformSize, Target, Stride, Edges);
        if not Info^.Skip then
        begin
          if (Plane > 0) or Frame^.Lossless then
            TransformType := TypeDctDct
          else
            TransformType := IntraModeTransformTypes[Mode];
          if Frame^.Lossless then
            SelectScan(Geometry.TransformSize, TypeDctDct, Scan, Neighbors)
          else
            SelectScan(Geometry.TransformSize, TransformType, Scan, Neighbors);
          EndOfBlock := ReadTransformBlock(Tile, Position, Plane, Geometry, Column, Row, Scan, Neighbors);
          if EndOfBlock > 0 then
          begin
            AddInverseTransform(@Tile.Coefficients[0], Geometry.TransformSize, TransformType, Frame^.Lossless,
              Target, Stride, Frame^.BitDepth);
            ClearCoefficients(Tile, Scan, EndOfBlock);
          end;
        end;
        Inc(Column, Step);
      end;
      Inc(Row, Step);
    end;
  end;
end;

function AddInterResidual(Tile: TVp9TileState; constref Position: TVp9BlockPosition): LongInt;
var
  Frame: PVp9FrameState;
  Plane, Row, Column, Step, EndOfBlock, Stride: LongInt;
  Geometry: TPlaneGeometry;
  Target: PWord;
  Scan, Neighbors: PSmallInt;
begin
  Result := 0;
  Frame := Tile.Frame;
  for Plane := 0 to 2 do
  begin
    PlaneGeometry(Frame^, Position, Plane, Geometry);
    Step := 1 shl Geometry.TransformSize;
    SelectScan(Geometry.TransformSize, TypeDctDct, Scan, Neighbors);
    Row := 0;
    while Row < Geometry.Rows do
    begin
      Column := 0;
      while Column < Geometry.Columns do
      begin
        EndOfBlock := ReadTransformBlock(Tile, Position, Plane, Geometry, Column, Row, Scan, Neighbors);
        if EndOfBlock > 0 then
        begin
          Target := PlaneTarget(Frame^, Position, Plane, Geometry, Column, Row, Stride);
          AddInverseTransform(@Tile.Coefficients[0], Geometry.TransformSize, TypeDctDct, Frame^.Lossless,
            Target, Stride, Frame^.BitDepth);
          ClearCoefficients(Tile, Scan, EndOfBlock);
        end;
        Inc(Result, EndOfBlock);
        Inc(Column, Step);
      end;
      Inc(Row, Step);
    end;
  end;
end;

procedure ResetSkipContexts(Tile: TVp9TileState; constref Position: TVp9BlockPosition);
var
  Plane: LongInt;
  Geometry: TPlaneGeometry;
begin
  for Plane := 0 to 2 do
  begin
    PlaneGeometry(Tile.Frame^, Position, Plane, Geometry);
    FillChar(Tile.Above^.Coefficients[Plane][(Position.MiColumn * 2) shr Geometry.SubsamplingX],
      Geometry.Width4x4, 0);
    FillChar(Tile.LeftCoefficients[Plane, ((Position.MiRow * 2) and 15) shr Geometry.SubsamplingY],
      Geometry.Height4x4, 0);
  end;
end;

function KernelOf(Filter: LongInt): PVp9Kernel;
begin
  case Filter of
    FilterSmooth: Result := PVp9Kernel(@SmoothFilters);
    FilterSharp: Result := PVp9Kernel(@SharpFilters);
    FilterBilinear: Result := PVp9Kernel(@BilinearFilters);
  else
    Result := PVp9Kernel(@RegularFilters);
  end;
end;

function RoundQ4(Value: LongInt): LongInt; inline;
begin
  if Value < 0 then
    Result := (Value - 2) div 4
  else
    Result := (Value + 2) div 4;
end;

function RoundQ2(Value: LongInt): LongInt; inline;
begin
  if Value < 0 then
    Result := (Value - 1) div 2
  else
    Result := (Value + 1) div 2;
end;

function AverageSplitMvs(Info: PVp9ModeInfo; SubsamplingX, SubsamplingY, Reference, Block: LongInt): TVp9Mv;
begin
  case (Ord(SubsamplingX > 0) shl 1) or Ord(SubsamplingY > 0) of
    0: Result := Info^.Subblocks[Block].Mv[Reference];
    1:
      begin
        Result.Row := RoundQ2(Info^.Subblocks[Block].Mv[Reference].Row + Info^.Subblocks[Block + 2].Mv[Reference].Row);
        Result.Col := RoundQ2(Info^.Subblocks[Block].Mv[Reference].Col + Info^.Subblocks[Block + 2].Mv[Reference].Col);
      end;
    2:
      begin
        Result.Row := RoundQ2(Info^.Subblocks[Block].Mv[Reference].Row + Info^.Subblocks[Block + 1].Mv[Reference].Row);
        Result.Col := RoundQ2(Info^.Subblocks[Block].Mv[Reference].Col + Info^.Subblocks[Block + 1].Mv[Reference].Col);
      end;
  else
    begin
      Result.Row := RoundQ4(Info^.Subblocks[0].Mv[Reference].Row + Info^.Subblocks[1].Mv[Reference].Row +
        Info^.Subblocks[2].Mv[Reference].Row + Info^.Subblocks[3].Mv[Reference].Row);
      Result.Col := RoundQ4(Info^.Subblocks[0].Mv[Reference].Col + Info^.Subblocks[1].Mv[Reference].Col +
        Info^.Subblocks[2].Mv[Reference].Col + Info^.Subblocks[3].Mv[Reference].Col);
    end;
  end;
end;

procedure PredictInterBlock(Tile: TVp9TileState; constref Position: TVp9BlockPosition);
var
  Frame: PVp9FrameState;
  Info: PVp9ModeInfo;
  Reference, Plane, X, Y, Index, Stride: LongInt;
  Geometry: TPlaneGeometry;
  Block: TVp9InterBlock;
  Kernel: PVp9Kernel;
  Picture: TVp9Picture;
begin
  Frame := Tile.Frame;
  Info := Position.Info;
  Kernel := KernelOf(Info^.Filter);
  for Reference := 0 to Ord(HasSecondReference(Info)) do
  begin
    Picture := Frame^.References[Info^.Reference[Reference]].Picture;
    for Plane := 0 to 2 do
    begin
      PlaneGeometry(Frame^, Position, Plane, Geometry);
      Block.Plane := Plane;
      Block.SubsamplingX := Geometry.SubsamplingX;
      Block.SubsamplingY := Geometry.SubsamplingY;
      Block.BlockWidth := 4 * Geometry.Width4x4;
      Block.BlockHeight := 4 * Geometry.Height4x4;
      Block.LumaX := Position.MiColumn * 8;
      Block.LumaY := Position.MiRow * 8;
      Block.ToLeft := Position.ToLeft;
      Block.ToRight := Position.ToRight;
      Block.ToTop := Position.ToTop;
      Block.ToBottom := Position.ToBottom;
      Block.Target := PlaneTarget(Frame^, Position, Plane, Geometry, 0, 0, Stride);
      Block.TargetStride := Stride;
      Block.BitDepth := Frame^.BitDepth;
      if Info^.BlockSize < Block8x8 then
      begin
        Index := 0;
        for Y := 0 to Geometry.Height4x4 - 1 do
          for X := 0 to Geometry.Width4x4 - 1 do
          begin
            Block.X := 4 * X;
            Block.Y := 4 * Y;
            Block.Width := 4;
            Block.Height := 4;
            Block.Target := PlaneTarget(Frame^, Position, Plane, Geometry, X, Y, Stride);
            Vp9.InterPrediction.PredictInterBlock(Block, Picture, Frame^.References[Info^.Reference[Reference]].Scale,
              Kernel, AverageSplitMvs(Info, Geometry.SubsamplingX, Geometry.SubsamplingY, Reference, Index),
              Reference = 1, @Tile.Scratch);
            Inc(Index);
          end;
      end
      else
      begin
        Block.X := 0;
        Block.Y := 0;
        Block.Width := Block.BlockWidth;
        Block.Height := Block.BlockHeight;
        Vp9.InterPrediction.PredictInterBlock(Block, Picture, Frame^.References[Info^.Reference[Reference]].Scale,
          Kernel, Info^.Mv[Reference], Reference = 1, @Tile.Scratch);
      end;
    end;
  end;
end;

end.
