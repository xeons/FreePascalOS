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
  Partitions and blocks (specification sections 5.11.4 to 5.11.7,
  5.11.18 and 5.11.33): the partition tree of a superblock, and for each
  block its mode info, palette tokens and transform sizes, what it stores
  in the frame's arrays, its prediction and its residual.
}
unit Av1.BlockDecoding;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.References, Av1.FrameContext, Av1.TileContext;

procedure DecodePartition(Tile: TTileContext; R, C, BSize: Integer);

implementation

uses
  Av1.BlockFlagsSyntax, Av1.IntraModeSyntax, Av1.InterModeSyntax, Av1.PaletteSyntax, Av1.TransformSyntax,
  Av1.MotionVectorSyntax, Av1.MvPrediction, Av1.ResidualDecoding, Av1.IntraPrediction, Av1.InterPrediction,
  Av1.MotionVectorScaling, Av1.ToolStatistics;

procedure CountIntraTools(Tile: TTileContext);
begin
  if (Tile.YMode >= V_PRED) and (Tile.YMode <= D67_PRED) then
    CountTool(toolIntraDirectional);
  if (Tile.AngleDeltaY <> 0) or (Tile.AngleDeltaUV <> 0) then
    CountTool(toolAngleDelta);
  if (Tile.YMode >= SMOOTH_PRED) and (Tile.YMode <= SMOOTH_H_PRED) then
    CountTool(toolSmooth);
  if Tile.YMode = PAETH_PRED then
    CountTool(toolPaeth);
  if Tile.HasChroma and (Tile.UVMode = UV_CFL_PRED) then
    CountTool(toolChromaFromLuma);
  if Tile.use_filter_intra then
    CountTool(toolFilterIntra);
  if Tile.PaletteSizeY > 0 then
    CountTool(toolPaletteY);
  if Tile.PaletteSizeUV > 0 then
    CountTool(toolPaletteUv);
end;

procedure CountInterTools(Tile: TTileContext);
var
  Mode: Integer;
begin
  Mode := Tile.YMode;
  if Tile.RefFrame[1] > INTRA_FRAME then
  begin
    CountTool(toolCompoundReference);
    if (Tile.RefFrame[0] >= BWDREF_FRAME) = (Tile.RefFrame[1] >= BWDREF_FRAME) then
      CountTool(toolUnidirectionalCompound);
  end
  else
    CountTool(toolSingleReference);
  if Tile.skip_mode then
    CountTool(toolSkipMode);
  if (Mode = NEWMV) or (Mode = NEW_NEWMV) or (Mode = NEAREST_NEWMV) or (Mode = NEW_NEARESTMV) or
    (Mode = NEAR_NEWMV) or (Mode = NEW_NEARMV) then
    CountTool(toolNewMv);
  if (Mode = GLOBALMV) or (Mode = GLOBAL_GLOBALMV) then
  begin
    CountTool(toolGlobalMv);
    if Tile.Header^.GmType[Tile.RefFrame[0]] > TRANSLATION then
      CountTool(toolGlobalMotionWarp);
  end;
  if Tile.motion_mode = LOCALWARP then
    CountTool(toolLocalWarp)
  else if Tile.motion_mode = OBMC then
    CountTool(toolObmc);
  if Tile.interintra then
  begin
    CountTool(toolInterIntra);
    if Tile.wedge_interintra then
      CountTool(toolInterIntraWedge);
  end
  else if Tile.RefFrame[1] > INTRA_FRAME then
    case Tile.compound_type of
      COMPOUND_WEDGE: CountTool(toolCompoundWedge);
      COMPOUND_DIFFWTD: CountTool(toolCompoundDiffWeighted);
      COMPOUND_DISTANCE: CountTool(toolCompoundDistance);
    end;
  if Tile.interp_filter[0] <> Tile.interp_filter[1] then
    CountTool(toolDualFilter);
  if IsScaled(Tile, Tile.RefFrame[0]) or ((Tile.RefFrame[1] > INTRA_FRAME) and IsScaled(Tile, Tile.RefFrame[1])) then
    CountTool(toolScaledReference);
end;

procedure CountBlockTools(Tile: TTileContext);
begin
  if Tile.use_intrabc then
    CountTool(toolIntraBlockCopy)
  else if Tile.is_inter then
    CountInterTools(Tile)
  else
    CountIntraTools(Tile);
end;

procedure ReadIntraFrameModeInfo(Tile: TTileContext);
begin
  Tile.skip := False;
  if Tile.Header^.SegIdPreSkip then
    ReadIntraSegmentId(Tile);
  Tile.skip_mode := False;
  ReadSkip(Tile);
  if not Tile.Header^.SegIdPreSkip then
    ReadIntraSegmentId(Tile);
  ReadCdef(Tile);
  ReadDeltaQIndex(Tile);
  ReadDeltaLf(Tile);
  Tile.ReadDeltas := False;
  Tile.RefFrame[0] := INTRA_FRAME;
  Tile.RefFrame[1] := NONE;
  Tile.interintra := False;
  Tile.motion_mode := SIMPLE;
  Tile.compound_type := COMPOUND_AVERAGE;
  if Tile.Header^.allow_intrabc then
    Tile.use_intrabc := ReadSymbol(Tile.Symbols, @Tile.Cdf.IntrabcCdf, 2) <> 0
  else
    Tile.use_intrabc := False;
  if Tile.use_intrabc then
  begin
    Tile.is_inter := True;
    Tile.YMode := DC_PRED;
    Tile.UVMode := DC_PRED;
    Tile.motion_mode := SIMPLE;
    Tile.compound_type := COMPOUND_AVERAGE;
    Tile.PaletteSizeY := 0;
    Tile.PaletteSizeUV := 0;
    Tile.interp_filter[0] := BILINEAR;
    Tile.interp_filter[1] := BILINEAR;
    Tile.use_filter_intra := False;
    Tile.AngleDeltaY := 0;
    Tile.AngleDeltaUV := 0;
    FindMvStack(Tile, False);
    AssignMv(Tile, False);
  end
  else
  begin
    Tile.is_inter := False;
    ReadIntraModes(Tile, True);
  end;
end;

procedure ReadInterFrameModeInfo(Tile: TTileContext);
var
  Frame: TFrameContext;
  Neighbour: PBlockInfo;
begin
  Frame := Tile.Frame;
  Tile.use_intrabc := False;
  if Tile.AvailL then
  begin
    Neighbour := Frame.Block(Tile.MiRow, Tile.MiCol - 1);
    Tile.LeftRefFrame[0] := Neighbour^.RefFrame[0];
    Tile.LeftRefFrame[1] := Neighbour^.RefFrame[1];
  end
  else
  begin
    Tile.LeftRefFrame[0] := INTRA_FRAME;
    Tile.LeftRefFrame[1] := NONE;
  end;
  if Tile.AvailU then
  begin
    Neighbour := Frame.Block(Tile.MiRow - 1, Tile.MiCol);
    Tile.AboveRefFrame[0] := Neighbour^.RefFrame[0];
    Tile.AboveRefFrame[1] := Neighbour^.RefFrame[1];
  end
  else
  begin
    Tile.AboveRefFrame[0] := INTRA_FRAME;
    Tile.AboveRefFrame[1] := NONE;
  end;
  Tile.LeftIntra := Tile.LeftRefFrame[0] <= INTRA_FRAME;
  Tile.AboveIntra := Tile.AboveRefFrame[0] <= INTRA_FRAME;
  Tile.LeftSingle := Tile.LeftRefFrame[1] <= INTRA_FRAME;
  Tile.AboveSingle := Tile.AboveRefFrame[1] <= INTRA_FRAME;
  Tile.skip := False;
  ReadInterSegmentId(Tile, True);
  ReadSkipMode(Tile);
  if Tile.skip_mode then
    Tile.skip := True
  else
    ReadSkip(Tile);
  if not Tile.Header^.SegIdPreSkip then
    ReadInterSegmentId(Tile, False);
  Tile.Lossless := Tile.Header^.LosslessArray[Tile.segment_id];
  ReadCdef(Tile);
  ReadDeltaQIndex(Tile);
  ReadDeltaLf(Tile);
  Tile.ReadDeltas := False;
  ReadIsInter(Tile);
  Tile.interintra := False;
  Tile.motion_mode := SIMPLE;
  Tile.compound_type := COMPOUND_AVERAGE;
  if Tile.is_inter then
  begin
    Tile.use_filter_intra := False;
    Tile.AngleDeltaY := 0;
    Tile.AngleDeltaUV := 0;
    ReadInterBlockModeInfo(Tile);
  end
  else
  begin
    Tile.RefFrame[0] := INTRA_FRAME;
    Tile.RefFrame[1] := NONE;
    ReadIntraModes(Tile, False);
  end;
end;

procedure ResetBlockContext(Tile: TTileContext; Bw4, Bh4: Integer);
var
  Plane, SubX, SubY, Index: Integer;
begin
  for Plane := 0 to Ord(Tile.HasChroma) * 2 do
  begin
    SubX := Tile.SubsamplingX(Plane);
    SubY := Tile.SubsamplingY(Plane);
    for Index := Tile.MiCol shr SubX to ((Tile.MiCol + Bw4) shr SubX) - 1 do
    begin
      Tile.AboveLevelContext[Plane][Index] := 0;
      Tile.AboveDcContext[Plane][Index] := 0;
    end;
    for Index := Tile.MiRow shr SubY to ((Tile.MiRow + Bh4) shr SubY) - 1 do
    begin
      Tile.LeftLevelContext[Plane][Index] := 0;
      Tile.LeftDcContext[Plane][Index] := 0;
    end;
  end;
end;

procedure ComputePrediction(Tile: TTileContext);
var
  Frame: TFrameContext;
  SbMask, SubBlockMiRow, SubBlockMiCol, Plane, PlaneSz, Num4x4W, Num4x4H, Log2W, Log2H: Integer;
  SubX, SubY, BaseX, BaseY, CandRow, CandCol, Mode, PredW, PredH, R, C, X, Y: Integer;
  SomeUseIntra, HaveLeft, HaveAbove: Boolean;
begin
  Frame := Tile.Frame;
  if Tile.Sequence^.use_128x128_superblock then
    SbMask := 31
  else
    SbMask := 15;
  SubBlockMiRow := Tile.MiRow and SbMask;
  SubBlockMiCol := Tile.MiCol and SbMask;
  for Plane := 0 to Ord(Tile.HasChroma) * 2 do
  begin
    PlaneSz := Tile.GetPlaneResidualSize(Tile.MiSize, Plane);
    Num4x4W := Num_4x4_Blocks_Wide[PlaneSz];
    Num4x4H := Num_4x4_Blocks_High[PlaneSz];
    Log2W := MI_SIZE_LOG2 + Mi_Width_Log2[PlaneSz];
    Log2H := MI_SIZE_LOG2 + Mi_Height_Log2[PlaneSz];
    SubX := Tile.SubsamplingX(Plane);
    SubY := Tile.SubsamplingY(Plane);
    BaseX := (Tile.MiCol shr SubX) * MI_SIZE;
    BaseY := (Tile.MiRow shr SubY) * MI_SIZE;
    CandRow := (Tile.MiRow shr SubY) shl SubY;
    CandCol := (Tile.MiCol shr SubX) shl SubX;
    Tile.IsInterIntra := Tile.is_inter and (Tile.RefFrame[1] = INTRA_FRAME);
    if Tile.IsInterIntra then
    begin
      case Tile.interintra_mode of
        II_DC_PRED: Mode := DC_PRED;
        II_V_PRED: Mode := V_PRED;
        II_H_PRED: Mode := H_PRED;
      else
        Mode := SMOOTH_PRED;
      end;
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
      PredictIntra(Tile, Plane, BaseX, BaseY, HaveLeft, HaveAbove,
        Tile.BlockDecoded(Plane, (SubBlockMiRow shr SubY) - 1, (SubBlockMiCol shr SubX) + Num4x4W),
        Tile.BlockDecoded(Plane, (SubBlockMiRow shr SubY) + Num4x4H, (SubBlockMiCol shr SubX) - 1),
        Mode, Log2W, Log2H);
    end;
    if Tile.is_inter then
    begin
      PredW := Block_Width(Tile.MiSize) shr SubX;
      PredH := Block_Height(Tile.MiSize) shr SubY;
      SomeUseIntra := False;
      for R := 0 to (Num4x4H shl SubY) - 1 do
        for C := 0 to (Num4x4W shl SubX) - 1 do
          if Frame.Block(CandRow + R, CandCol + C)^.RefFrame[0] = INTRA_FRAME then
            SomeUseIntra := True;
      if SomeUseIntra then
      begin
        PredW := Num4x4W * 4;
        PredH := Num4x4H * 4;
        CandRow := Tile.MiRow;
        CandCol := Tile.MiCol;
      end;
      R := 0;
      Y := 0;
      while Y < Num4x4H * 4 do
      begin
        C := 0;
        X := 0;
        while X < Num4x4W * 4 do
        begin
          PredictInter(Tile, Plane, BaseX + X, BaseY + Y, PredW, PredH, CandRow + R, CandCol + C);
          Inc(X, PredW);
          Inc(C);
        end;
        Inc(Y, PredH);
        Inc(R);
      end;
    end;
  end;
end;

procedure DecodeBlock(Tile: TTileContext; R, C, SubSize: Integer);
var
  Frame: TFrameContext;
  Bw4, Bh4, X, Y, Index, BlockIndex: Integer;
  IsCompound: Boolean;
  Info: PBlockInfo;
begin
  Frame := Tile.Frame;
  Tile.MiRow := R;
  Tile.MiCol := C;
  Tile.MiSize := SubSize;
  Bw4 := Num_4x4_Blocks_Wide[SubSize];
  Bh4 := Num_4x4_Blocks_High[SubSize];
  if (Bh4 = 1) and (Tile.Sequence^.subsampling_y <> 0) and ((Tile.MiRow and 1) = 0) then
    Tile.HasChroma := False
  else if (Bw4 = 1) and (Tile.Sequence^.subsampling_x <> 0) and ((Tile.MiCol and 1) = 0) then
    Tile.HasChroma := False
  else
    Tile.HasChroma := Tile.Sequence^.NumPlanes > 1;
  Tile.AvailU := Tile.IsInside(R - 1, C);
  Tile.AvailL := Tile.IsInside(R, C - 1);
  Tile.AvailUChroma := Tile.AvailU;
  Tile.AvailLChroma := Tile.AvailL;
  if Tile.HasChroma then
  begin
    if (Tile.Sequence^.subsampling_y <> 0) and (Bh4 = 1) then
      Tile.AvailUChroma := Tile.IsInside(R - 2, C);
    if (Tile.Sequence^.subsampling_x <> 0) and (Bw4 = 1) then
      Tile.AvailLChroma := Tile.IsInside(R, C - 2);
  end
  else
  begin
    Tile.AvailUChroma := False;
    Tile.AvailLChroma := False;
  end;
  if Tile.Header^.FrameIsIntra then
    ReadIntraFrameModeInfo(Tile)
  else
    ReadInterFrameModeInfo(Tile);
  ReadPaletteTokens(Tile);
  ReadBlockTxSize(Tile);
{$ifdef AV1_TOOL_STATISTICS}
  CountBlockTools(Tile);
{$endif}
  if Tile.skip then
    ResetBlockContext(Tile, Bw4, Bh4);
  IsCompound := Tile.RefFrame[1] > INTRA_FRAME;
  for Y := 0 to Bh4 - 1 do
    for X := 0 to Bw4 - 1 do
    begin
      Info := Frame.Block(R + Y, C + X);
      Info^.YMode := Tile.YMode;
      if (Tile.RefFrame[0] = INTRA_FRAME) and Tile.HasChroma then
        Info^.UVMode := Tile.UVMode;
      Info^.RefFrame[0] := Tile.RefFrame[0];
      Info^.RefFrame[1] := Tile.RefFrame[1];
      if Tile.is_inter then
      begin
        if not Tile.use_intrabc then
        begin
          Info^.CompGroupIdx := Tile.comp_group_idx;
          Info^.CompoundIdx := Tile.compound_idx;
        end;
        Info^.InterpFilter[0] := Tile.interp_filter[0];
        Info^.InterpFilter[1] := Tile.interp_filter[1];
        Info^.Mv[0] := Tile.Mv[0];
        if IsCompound then
          Info^.Mv[1] := Tile.Mv[1];
      end;
    end;
  ComputePrediction(Tile);
  DecodeResidual(Tile);
  for Y := 0 to Bh4 - 1 do
    for X := 0 to Bw4 - 1 do
    begin
      BlockIndex := Frame.MiIndex(R + Y, C + X);
      Info := @Frame.Blocks[BlockIndex];
      Info^.IsInter := Tile.is_inter;
      Info^.SkipMode := Tile.skip_mode;
      Info^.Skip := Tile.skip;
      Info^.TxSize := Tile.TxSize;
      Info^.MiSize := Tile.MiSize;
      Frame.SegmentIds[BlockIndex] := Tile.segment_id;
      Info^.PaletteSize[0] := Tile.PaletteSizeY;
      Info^.PaletteSize[1] := Tile.PaletteSizeUV;
      for Index := 0 to Tile.PaletteSizeY - 1 do
        Frame.PaletteColors[BlockIndex * 16 + Index] := Tile.palette_colors_y[Index];
      for Index := 0 to Tile.PaletteSizeUV - 1 do
        Frame.PaletteColors[BlockIndex * 16 + 8 + Index] := Tile.palette_colors_u[Index];
      for Index := 0 to FRAME_LF_COUNT - 1 do
        Info^.DeltaLF[Index] := Tile.DeltaLF[Index];
    end;
end;

function PartitionCdf(Tile: TTileContext; Bsl, Context: Integer; out Symbols: Integer): PWord;
begin
  case Bsl of
    1:
      begin
        Result := @Tile.Cdf.PartitionW8Cdf[Context];
        Symbols := 4;
      end;
    2:
      begin
        Result := @Tile.Cdf.PartitionW16Cdf[Context];
        Symbols := 10;
      end;
    3:
      begin
        Result := @Tile.Cdf.PartitionW32Cdf[Context];
        Symbols := 10;
      end;
    4:
      begin
        Result := @Tile.Cdf.PartitionW64Cdf[Context];
        Symbols := 10;
      end;
  else
    Result := @Tile.Cdf.PartitionW128Cdf[Context];
    Symbols := 8;
  end;
end;

{ The probability of a partition symbol from its CDF. }
function SymbolProbability(Cdf: PWord; Symbol: Integer): Integer; inline;
begin
  if Symbol = 0 then
    Result := Cdf[0]
  else
    Result := Cdf[Symbol] - Cdf[Symbol - 1];
end;

{ split_or_horz / split_or_vert: a bool with the summed probabilities of
  the partitions that split the block that way. }
function ReadSplitOrDirection(Tile: TTileContext; PartitionCdfValues: PWord; BSize: Integer; Horizontal: Boolean): Boolean;
var
  PSum: Integer;
  Cdf: array[0..2] of Word;
begin
  if Horizontal then
  begin
    PSum := SymbolProbability(PartitionCdfValues, PARTITION_VERT) + SymbolProbability(PartitionCdfValues, PARTITION_SPLIT) +
      SymbolProbability(PartitionCdfValues, PARTITION_HORZ_A) + SymbolProbability(PartitionCdfValues, PARTITION_VERT_A) +
      SymbolProbability(PartitionCdfValues, PARTITION_VERT_B);
    if BSize <> BLOCK_128X128 then
      Inc(PSum, SymbolProbability(PartitionCdfValues, PARTITION_VERT_4));
  end
  else
  begin
    PSum := SymbolProbability(PartitionCdfValues, PARTITION_HORZ) + SymbolProbability(PartitionCdfValues, PARTITION_SPLIT) +
      SymbolProbability(PartitionCdfValues, PARTITION_HORZ_A) + SymbolProbability(PartitionCdfValues, PARTITION_HORZ_B) +
      SymbolProbability(PartitionCdfValues, PARTITION_VERT_A);
    if BSize <> BLOCK_128X128 then
      Inc(PSum, SymbolProbability(PartitionCdfValues, PARTITION_HORZ_4));
  end;
  { The spec's cdf[ 0 ] = ( 1 << 15 ) - psum, in this decoder's
    cumulative (not inverted) form; such a CDF is not adapted. }
  Cdf[0] := (1 shl 15) - PSum;
  Cdf[1] := 1 shl 15;
  Cdf[2] := 0;
  Result := ReadSymbolWithoutAdaptation(Tile.Symbols, @Cdf[0], 2) <> 0;
end;

procedure DecodePartition(Tile: TTileContext; R, C, BSize: Integer);
var
  Frame: TFrameContext;
  Num4x4, HalfBlock4x4, QuarterBlock4x4, Partition, SubSize, SplitSize, Bsl, Context, Symbols: Integer;
  HasRows, HasCols, Above, Left: Boolean;
  Cdf: PWord;
begin
  Frame := Tile.Frame;
  if (R >= Tile.Header^.MiRows) or (C >= Tile.Header^.MiCols) then
    Exit;
  Tile.AvailU := Tile.IsInside(R - 1, C);
  Tile.AvailL := Tile.IsInside(R, C - 1);
  Num4x4 := Num_4x4_Blocks_Wide[BSize];
  HalfBlock4x4 := Num4x4 shr 1;
  QuarterBlock4x4 := HalfBlock4x4 shr 1;
  HasRows := (R + HalfBlock4x4) < Tile.Header^.MiRows;
  HasCols := (C + HalfBlock4x4) < Tile.Header^.MiCols;
  if BSize < BLOCK_8X8 then
    Partition := PARTITION_NONE
  else
  begin
    Bsl := Mi_Width_Log2[BSize];
    Above := Tile.AvailU and (Mi_Width_Log2[Frame.Block(R - 1, C)^.MiSize] < Bsl);
    Left := Tile.AvailL and (Mi_Height_Log2[Frame.Block(R, C - 1)^.MiSize] < Bsl);
    Context := Ord(Left) * 2 + Ord(Above);
    Cdf := PartitionCdf(Tile, Bsl, Context, Symbols);
    if HasRows and HasCols then
      Partition := ReadSymbol(Tile.Symbols, Cdf, Symbols)
    else if HasCols then
    begin
      if ReadSplitOrDirection(Tile, Cdf, BSize, True) then
        Partition := PARTITION_SPLIT
      else
        Partition := PARTITION_HORZ;
    end
    else if HasRows then
    begin
      if ReadSplitOrDirection(Tile, Cdf, BSize, False) then
        Partition := PARTITION_SPLIT
      else
        Partition := PARTITION_VERT;
    end
    else
      Partition := PARTITION_SPLIT;
  end;
  SubSize := Partition_Subsize[Partition, BSize];
  SplitSize := Partition_Subsize[PARTITION_SPLIT, BSize];
  case Partition of
    PARTITION_NONE:
      DecodeBlock(Tile, R, C, SubSize);
    PARTITION_HORZ:
      begin
        DecodeBlock(Tile, R, C, SubSize);
        if HasRows then
          DecodeBlock(Tile, R + HalfBlock4x4, C, SubSize);
      end;
    PARTITION_VERT:
      begin
        DecodeBlock(Tile, R, C, SubSize);
        if HasCols then
          DecodeBlock(Tile, R, C + HalfBlock4x4, SubSize);
      end;
    PARTITION_SPLIT:
      begin
        DecodePartition(Tile, R, C, SubSize);
        DecodePartition(Tile, R, C + HalfBlock4x4, SubSize);
        DecodePartition(Tile, R + HalfBlock4x4, C, SubSize);
        DecodePartition(Tile, R + HalfBlock4x4, C + HalfBlock4x4, SubSize);
      end;
    PARTITION_HORZ_A:
      begin
        DecodeBlock(Tile, R, C, SplitSize);
        DecodeBlock(Tile, R, C + HalfBlock4x4, SplitSize);
        DecodeBlock(Tile, R + HalfBlock4x4, C, SubSize);
      end;
    PARTITION_HORZ_B:
      begin
        DecodeBlock(Tile, R, C, SubSize);
        DecodeBlock(Tile, R + HalfBlock4x4, C, SplitSize);
        DecodeBlock(Tile, R + HalfBlock4x4, C + HalfBlock4x4, SplitSize);
      end;
    PARTITION_VERT_A:
      begin
        DecodeBlock(Tile, R, C, SplitSize);
        DecodeBlock(Tile, R + HalfBlock4x4, C, SplitSize);
        DecodeBlock(Tile, R, C + HalfBlock4x4, SubSize);
      end;
    PARTITION_VERT_B:
      begin
        DecodeBlock(Tile, R, C, SubSize);
        DecodeBlock(Tile, R, C + HalfBlock4x4, SplitSize);
        DecodeBlock(Tile, R + HalfBlock4x4, C + HalfBlock4x4, SplitSize);
      end;
    PARTITION_HORZ_4:
      begin
        DecodeBlock(Tile, R + QuarterBlock4x4 * 0, C, SubSize);
        DecodeBlock(Tile, R + QuarterBlock4x4 * 1, C, SubSize);
        DecodeBlock(Tile, R + QuarterBlock4x4 * 2, C, SubSize);
        if R + QuarterBlock4x4 * 3 < Tile.Header^.MiRows then
          DecodeBlock(Tile, R + QuarterBlock4x4 * 3, C, SubSize);
      end;
  else
    DecodeBlock(Tile, R, C + QuarterBlock4x4 * 0, SubSize);
    DecodeBlock(Tile, R, C + QuarterBlock4x4 * 1, SubSize);
    DecodeBlock(Tile, R, C + QuarterBlock4x4 * 2, SubSize);
    if C + QuarterBlock4x4 * 3 < Tile.Header^.MiCols then
      DecodeBlock(Tile, R, C + QuarterBlock4x4 * 3, SubSize);
  end;
end;

end.
