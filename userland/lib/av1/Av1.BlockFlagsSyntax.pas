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
  The per block syntax elements read before the prediction modes
  (specification sections 5.11.8 to 5.11.20): segment ids, skip and
  skip mode, the CDEF index, the quantizer and loop filter deltas, and
  is_inter, with the contexts of section 8.3.2.
}
unit Av1.BlockFlagsSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

procedure ReadIntraSegmentId(Tile: TTileContext);
procedure ReadInterSegmentId(Tile: TTileContext; PreSkip: Boolean);
procedure ReadSkip(Tile: TTileContext);
procedure ReadSkipMode(Tile: TTileContext);
procedure ReadCdef(Tile: TTileContext);
procedure ReadDeltaQIndex(Tile: TTileContext);
procedure ReadDeltaLf(Tile: TTileContext);
procedure ReadIsInter(Tile: TTileContext);

implementation

function NegDeinterleave(Diff, Reference, MaxValue: Integer): Integer;
begin
  if Reference = 0 then
    Exit(Diff);
  if Reference >= MaxValue - 1 then
    Exit(MaxValue - Diff - 1);
  if 2 * Reference < MaxValue then
  begin
    if Diff <= 2 * Reference then
    begin
      if (Diff and 1) <> 0 then
        Exit(Reference + ((Diff + 1) shr 1))
      else
        Exit(Reference - (Diff shr 1));
    end;
    Exit(Diff);
  end
  else
  begin
    if Diff <= 2 * (MaxValue - Reference - 1) then
    begin
      if (Diff and 1) <> 0 then
        Exit(Reference + ((Diff + 1) shr 1))
      else
        Exit(Reference - (Diff shr 1));
    end;
    Exit(MaxValue - (Diff + 1));
  end;
end;

procedure ReadSegmentId(Tile: TTileContext);
var
  Frame: TFrameContext;
  PrevUL, PrevU, PrevL, Pred, Context, Value: Integer;
begin
  Frame := Tile.Frame;
  if Tile.AvailU and Tile.AvailL then
    PrevUL := Frame.SegmentIds[Frame.MiIndex(Tile.MiRow - 1, Tile.MiCol - 1)]
  else
    PrevUL := -1;
  if Tile.AvailU then
    PrevU := Frame.SegmentIds[Frame.MiIndex(Tile.MiRow - 1, Tile.MiCol)]
  else
    PrevU := -1;
  if Tile.AvailL then
    PrevL := Frame.SegmentIds[Frame.MiIndex(Tile.MiRow, Tile.MiCol - 1)]
  else
    PrevL := -1;
  if PrevU = -1 then
  begin
    if PrevL = -1 then
      Pred := 0
    else
      Pred := PrevL;
  end
  else if PrevL = -1 then
    Pred := PrevU
  else if PrevUL = PrevU then
    Pred := PrevU
  else
    Pred := PrevL;
  if Tile.skip then
    Tile.segment_id := Pred
  else
  begin
    if PrevUL < 0 then
      Context := 0
    else if (PrevUL = PrevU) and (PrevUL = PrevL) then
      Context := 2
    else if (PrevUL = PrevU) or (PrevUL = PrevL) or (PrevU = PrevL) then
      Context := 1
    else
      Context := 0;
    Value := ReadSymbol(Tile.Symbols, @Tile.Cdf.SegmentIdCdf[Context], MAX_SEGMENTS);
    Tile.segment_id := NegDeinterleave(Value, Pred, Tile.Header^.LastActiveSegId + 1);
  end;
end;

procedure ReadIntraSegmentId(Tile: TTileContext);
begin
  if Tile.Header^.segmentation_enabled then
    ReadSegmentId(Tile)
  else
    Tile.segment_id := 0;
  Tile.Lossless := Tile.Header^.LosslessArray[Tile.segment_id];
end;

function GetSegmentId(Tile: TTileContext): Integer;
var
  Frame: TFrameContext;
  Bw4, Bh4, XMis, YMis, X, Y: Integer;
begin
  Frame := Tile.Frame;
  Bw4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  Bh4 := Num_4x4_Blocks_High[Tile.MiSize];
  XMis := Min(Tile.Header^.MiCols - Tile.MiCol, Bw4);
  YMis := Min(Tile.Header^.MiRows - Tile.MiRow, Bh4);
  Result := 7;
  for Y := 0 to YMis - 1 do
    for X := 0 to XMis - 1 do
      Result := Min(Result, Frame.PrevSegmentIds[Frame.MiIndex(Tile.MiRow + Y, Tile.MiCol + X)]);
end;

procedure SetSegmentPredictionContexts(Tile: TTileContext; Value: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Num_4x4_Blocks_Wide[Tile.MiSize] - 1 do
    Tile.AboveSegPredContext[Tile.MiCol + Index] := Value;
  for Index := 0 to Num_4x4_Blocks_High[Tile.MiSize] - 1 do
    Tile.LeftSegPredContext[Tile.MiRow + Index] := Value;
end;

procedure ReadInterSegmentId(Tile: TTileContext; PreSkip: Boolean);
var
  PredictedSegmentId, Context, SegIdPredicted: Integer;
begin
  if not Tile.Header^.segmentation_enabled then
  begin
    Tile.segment_id := 0;
    Exit;
  end;
  PredictedSegmentId := GetSegmentId(Tile);
  if Tile.Header^.segmentation_update_map then
  begin
    if PreSkip and not Tile.Header^.SegIdPreSkip then
    begin
      Tile.segment_id := 0;
      Exit;
    end;
    if not PreSkip then
      if Tile.skip then
      begin
        SetSegmentPredictionContexts(Tile, 0);
        ReadSegmentId(Tile);
        Exit;
      end;
    if Tile.Header^.segmentation_temporal_update then
    begin
      Context := Tile.LeftSegPredContext[Tile.MiRow] + Tile.AboveSegPredContext[Tile.MiCol];
      SegIdPredicted := ReadSymbol(Tile.Symbols, @Tile.Cdf.SegmentIdPredictedCdf[Context], 2);
      if SegIdPredicted <> 0 then
        Tile.segment_id := PredictedSegmentId
      else
        ReadSegmentId(Tile);
      SetSegmentPredictionContexts(Tile, SegIdPredicted);
    end
    else
      ReadSegmentId(Tile);
  end
  else
    Tile.segment_id := PredictedSegmentId;
end;

procedure ReadSkip(Tile: TTileContext);
var
  Context: Integer;
  Frame: TFrameContext;
begin
  if Tile.Header^.SegIdPreSkip and Tile.SegmentFeatureActive(SEG_LVL_SKIP) then
    Tile.skip := True
  else
  begin
    Frame := Tile.Frame;
    Context := 0;
    if Tile.AvailU then
      Inc(Context, Ord(Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.Skip));
    if Tile.AvailL then
      Inc(Context, Ord(Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.Skip));
    Tile.skip := ReadSymbol(Tile.Symbols, @Tile.Cdf.SkipCdf[Context], 2) <> 0;
  end;
end;

procedure ReadSkipMode(Tile: TTileContext);
var
  Context: Integer;
  Frame: TFrameContext;
begin
  if Tile.SegmentFeatureActive(SEG_LVL_SKIP) or Tile.SegmentFeatureActive(SEG_LVL_REF_FRAME) or
    Tile.SegmentFeatureActive(SEG_LVL_GLOBALMV) or (not Tile.Header^.skip_mode_present) or
    (Block_Width(Tile.MiSize) < 8) or (Block_Height(Tile.MiSize) < 8) then
    Tile.skip_mode := False
  else
  begin
    Frame := Tile.Frame;
    Context := 0;
    if Tile.AvailU then
      Inc(Context, Ord(Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.SkipMode));
    if Tile.AvailL then
      Inc(Context, Ord(Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.SkipMode));
    Tile.skip_mode := ReadSymbol(Tile.Symbols, @Tile.Cdf.SkipModeCdf[Context], 2) <> 0;
  end;
end;

procedure ReadCdef(Tile: TTileContext);
var
  Frame: TFrameContext;
  CdefSize4, CdefMask4, R, C, W4, H4, I, J, Value: Integer;
begin
  Frame := Tile.Frame;
  if Tile.skip or Tile.Header^.CodedLossless or (not Tile.Sequence^.enable_cdef) or Tile.Header^.allow_intrabc then
    Exit;
  CdefSize4 := Num_4x4_Blocks_Wide[BLOCK_64X64];
  CdefMask4 := not (CdefSize4 - 1);
  R := Tile.MiRow and CdefMask4;
  C := Tile.MiCol and CdefMask4;
  if Frame.CdefIdx[Frame.MiIndex(R, C)] = -1 then
  begin
    Value := ReadLiteral(Tile.Symbols, Tile.Header^.cdef_bits);
    Frame.CdefIdx[Frame.MiIndex(R, C)] := Value;
    W4 := Num_4x4_Blocks_Wide[Tile.MiSize];
    H4 := Num_4x4_Blocks_High[Tile.MiSize];
    I := R;
    while I < R + H4 do
    begin
      J := C;
      while J < C + W4 do
      begin
        Frame.CdefIdx[Frame.MiIndex(I, J)] := Value;
        Inc(J, CdefSize4);
      end;
      Inc(I, CdefSize4);
    end;
  end;
end;

function SuperblockSize(Tile: TTileContext): Integer; inline;
begin
  if Tile.Sequence^.use_128x128_superblock then
    Result := BLOCK_128X128
  else
    Result := BLOCK_64X64;
end;

procedure ReadDeltaQIndex(Tile: TTileContext);
var
  DeltaQAbs, RemBits, ReducedDeltaQIndex: Integer;
begin
  if (Tile.MiSize = SuperblockSize(Tile)) and Tile.skip then
    Exit;
  if Tile.ReadDeltas then
  begin
    DeltaQAbs := ReadSymbol(Tile.Symbols, @Tile.Cdf.DeltaQCdf, DELTA_Q_SMALL + 1);
    if DeltaQAbs = DELTA_Q_SMALL then
    begin
      RemBits := ReadLiteral(Tile.Symbols, 3) + 1;
      DeltaQAbs := ReadLiteral(Tile.Symbols, RemBits) + (1 shl RemBits) + 1;
    end;
    if DeltaQAbs <> 0 then
    begin
      if ReadLiteral(Tile.Symbols, 1) <> 0 then
        ReducedDeltaQIndex := -DeltaQAbs
      else
        ReducedDeltaQIndex := DeltaQAbs;
      Tile.CurrentQIndex := Clip3(1, 255, Tile.CurrentQIndex + (ReducedDeltaQIndex shl Tile.Header^.delta_q_res));
    end;
  end;
end;

procedure ReadDeltaLf(Tile: TTileContext);
var
  FrameLfCount, Index, DeltaLfAbs, N, ReducedDeltaLfLevel: Integer;
  Cdf: PWord;
begin
  if (Tile.MiSize = SuperblockSize(Tile)) and Tile.skip then
    Exit;
  if Tile.ReadDeltas and Tile.Header^.delta_lf_present then
  begin
    FrameLfCount := 1;
    if Tile.Header^.delta_lf_multi then
    begin
      if Tile.Sequence^.NumPlanes > 1 then
        FrameLfCount := FRAME_LF_COUNT
      else
        FrameLfCount := FRAME_LF_COUNT - 2;
    end;
    for Index := 0 to FrameLfCount - 1 do
    begin
      if Tile.Header^.delta_lf_multi then
        Cdf := @Tile.Cdf.DeltaLfMultiCdf[Index]
      else
        Cdf := @Tile.Cdf.DeltaLfCdf;
      DeltaLfAbs := ReadSymbol(Tile.Symbols, Cdf, DELTA_LF_SMALL + 1);
      if DeltaLfAbs = DELTA_LF_SMALL then
      begin
        N := ReadLiteral(Tile.Symbols, 3) + 1;
        DeltaLfAbs := ReadLiteral(Tile.Symbols, N) + (1 shl N) + 1;
      end;
      if DeltaLfAbs <> 0 then
      begin
        if ReadLiteral(Tile.Symbols, 1) <> 0 then
          ReducedDeltaLfLevel := -DeltaLfAbs
        else
          ReducedDeltaLfLevel := DeltaLfAbs;
        Tile.DeltaLF[Index] := Clip3(-MAX_LOOP_FILTER, MAX_LOOP_FILTER,
          Tile.DeltaLF[Index] + (ReducedDeltaLfLevel shl Tile.Header^.delta_lf_res));
      end;
    end;
  end;
end;

procedure ReadIsInter(Tile: TTileContext);
var
  Context: Integer;
begin
  if Tile.skip_mode then
    Tile.is_inter := True
  else if Tile.SegmentFeatureActive(SEG_LVL_REF_FRAME) then
    Tile.is_inter := Tile.Header^.Segmentation.FeatureData[Tile.segment_id, SEG_LVL_REF_FRAME] <> INTRA_FRAME
  else if Tile.SegmentFeatureActive(SEG_LVL_GLOBALMV) then
    Tile.is_inter := True
  else
  begin
    if Tile.AvailU and Tile.AvailL then
    begin
      if Tile.LeftIntra and Tile.AboveIntra then
        Context := 3
      else
        Context := Ord(Tile.LeftIntra or Tile.AboveIntra);
    end
    else if Tile.AvailU or Tile.AvailL then
    begin
      if Tile.AvailU then
        Context := 2 * Ord(Tile.AboveIntra)
      else
        Context := 2 * Ord(Tile.LeftIntra);
    end
    else
      Context := 0;
    Tile.is_inter := ReadSymbol(Tile.Symbols, @Tile.Cdf.IsInterCdf[Context], 2) <> 0;
  end;
end;

end.
