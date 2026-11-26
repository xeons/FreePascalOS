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
  Reading the uncompressed header (specification section 5.9) into a
  TFrameHeader, with what the header reading itself depends on from the
  reference slots: their order hints and sizes, and the values
  load_previous( ) brings in (global motion, loop filter deltas,
  segmentation features) or setup_past_independence( ) resets. The
  processes the header only names (loading CDFs, the previous
  segmentation map, motion field estimation) are left to the decoder,
  which runs them after the header has been read.
}
unit Av1.FrameHeaderParsing;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Av1.Common, Av1.Constants, Av1.Tables, Av1.BitReader, Av1.SequenceHeader,
  Av1.FrameHeader, Av1.References;

type
  { What the header reading keeps from one frame to the next. }
  THeaderState = record
    current_frame_id: Integer;
  end;

{ uncompressed_header( ). TemporalId and SpatialId come from the OBU
  extension header. Slots is updated as the header says (RefValid and
  RefOrderHint reset by a shown key frame, ref_order_hint checks). }
procedure ParseUncompressedHeader(var Reader: TBitReader; const Sequence: TSequenceHeader;
  var Slots: TReferenceSlots; var State: THeaderState; TemporalId, SpatialId: Integer;
  out Header: TFrameHeader);
{ load_grain_params( idx ). }
procedure LoadGrainParams(const Slots: TReferenceSlots; Index: Integer; var Params: TFilmGrainParams);

implementation

procedure RequireReference(const Slots: TReferenceSlots; Index: Integer);
begin
  if Slots.Frames[Index] = nil then
    RaiseAv1Error('a frame refers to reference slot ' + IntToStr(Index) + ', which holds no frame');
end;

procedure LoadGrainParams(const Slots: TReferenceSlots; Index: Integer; var Params: TFilmGrainParams);
begin
  RequireReference(Slots, Index);
  Params := Slots.Frames[Index].SavedFilmGrain;
end;

function GetRelativeDist(const Sequence: TSequenceHeader; A, B: Integer): Integer;
var
  Difference, M: Integer;
begin
  if not Sequence.enable_order_hint then
    Exit(0);
  Difference := A - B;
  M := 1 shl (Sequence.OrderHintBits - 1);
  Result := (Difference and (M - 1)) - (Difference and M);
end;

procedure ResetGlobalMotion(var Params: TGlobalMotionParams);
var
  Ref, Index: Integer;
begin
  for Ref := 0 to TOTAL_REFS_PER_FRAME - 1 do
    for Index := 0 to 5 do
      if Index mod 3 = 2 then
        Params[Ref, Index] := 1 shl WARPEDMODEL_PREC_BITS
      else
        Params[Ref, Index] := 0;
end;

procedure ResetLoopFilterDeltas(var Deltas: TLoopFilterDeltas);
begin
  Deltas.loop_filter_ref_deltas[INTRA_FRAME] := 1;
  Deltas.loop_filter_ref_deltas[LAST_FRAME] := 0;
  Deltas.loop_filter_ref_deltas[LAST2_FRAME] := 0;
  Deltas.loop_filter_ref_deltas[LAST3_FRAME] := 0;
  Deltas.loop_filter_ref_deltas[BWDREF_FRAME] := 0;
  Deltas.loop_filter_ref_deltas[GOLDEN_FRAME] := -1;
  Deltas.loop_filter_ref_deltas[ALTREF_FRAME] := -1;
  Deltas.loop_filter_ref_deltas[ALTREF2_FRAME] := -1;
  Deltas.loop_filter_mode_deltas[0] := 0;
  Deltas.loop_filter_mode_deltas[1] := 0;
end;

{ superres_params( ) and compute_image_size( ). }
procedure ParseSuperresParams(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
begin
  if Sequence.enable_superres then
    Header.use_superres := ReadFlag(Reader)
  else
    Header.use_superres := False;
  if Header.use_superres then
    Header.SuperresDenom := Integer(ReadBits(Reader, SUPERRES_DENOM_BITS)) + SUPERRES_DENOM_MIN
  else
    Header.SuperresDenom := SUPERRES_NUM;
  Header.UpscaledWidth := Header.FrameWidth;
  Header.FrameWidth := (Header.UpscaledWidth * SUPERRES_NUM + (Header.SuperresDenom div 2)) div Header.SuperresDenom;
  Header.MiCols := 2 * ((Header.FrameWidth + 7) shr 3);
  Header.MiRows := 2 * ((Header.FrameHeight + 7) shr 3);
end;

procedure ParseFrameSize(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
begin
  if Header.frame_size_override_flag then
  begin
    Header.FrameWidth := Integer(ReadBits(Reader, Sequence.frame_width_bits_minus_1 + 1)) + 1;
    Header.FrameHeight := Integer(ReadBits(Reader, Sequence.frame_height_bits_minus_1 + 1)) + 1;
  end
  else
  begin
    Header.FrameWidth := Sequence.max_frame_width_minus_1 + 1;
    Header.FrameHeight := Sequence.max_frame_height_minus_1 + 1;
  end;
  ParseSuperresParams(Reader, Sequence, Header);
end;

procedure ParseRenderSize(var Reader: TBitReader; var Header: TFrameHeader);
begin
  if ReadFlag(Reader) then
  begin
    Header.RenderWidth := Integer(ReadBits(Reader, 16)) + 1;
    Header.RenderHeight := Integer(ReadBits(Reader, 16)) + 1;
  end
  else
  begin
    Header.RenderWidth := Header.UpscaledWidth;
    Header.RenderHeight := Header.FrameHeight;
  end;
end;

procedure ParseFrameSizeWithRefs(var Reader: TBitReader; const Sequence: TSequenceHeader;
  const Slots: TReferenceSlots; var Header: TFrameHeader);
var
  Index: Integer;
  FoundRef: Boolean;
  Reference: TReferenceFrame;
begin
  FoundRef := False;
  for Index := 0 to REFS_PER_FRAME - 1 do
  begin
    FoundRef := ReadFlag(Reader);
    if FoundRef then
    begin
      RequireReference(Slots, Header.ref_frame_idx[Index]);
      Reference := Slots.Frames[Header.ref_frame_idx[Index]];
      Header.UpscaledWidth := Reference.RefUpscaledWidth;
      Header.FrameWidth := Header.UpscaledWidth;
      Header.FrameHeight := Reference.RefFrameHeight;
      Header.RenderWidth := Reference.RefRenderWidth;
      Header.RenderHeight := Reference.RefRenderHeight;
      Break;
    end;
  end;
  if not FoundRef then
  begin
    ParseFrameSize(Reader, Sequence, Header);
    ParseRenderSize(Reader, Header);
  end
  else
    ParseSuperresParams(Reader, Sequence, Header);
end;

{ set_frame_refs( ) (section 7.8). }
procedure SetFrameRefs(const Sequence: TSequenceHeader; const Slots: TReferenceSlots; var Header: TFrameHeader;
  LastFrameIdx, GoldFrameIdx: Integer);
const
  Ref_Frame_List: array[0..REFS_PER_FRAME - 3] of Integer =
    (LAST2_FRAME, LAST3_FRAME, BWDREF_FRAME, ALTREF2_FRAME, ALTREF_FRAME);
var
  UsedFrame: array[0..NUM_REF_FRAMES - 1] of Boolean;
  ShiftedOrderHints: array[0..NUM_REF_FRAMES - 1] of Integer;
  Index, CurFrameHint, Ref, Hint, BestHint, RefFrame: Integer;

  function FindLatestBackward: Integer;
  var
    Candidate: Integer;
  begin
    Result := -1;
    for Candidate := 0 to NUM_REF_FRAMES - 1 do
    begin
      Hint := ShiftedOrderHints[Candidate];
      if (not UsedFrame[Candidate]) and (Hint >= CurFrameHint) and ((Result < 0) or (Hint >= BestHint)) then
      begin
        Result := Candidate;
        BestHint := Hint;
      end;
    end;
  end;

  function FindEarliestBackward: Integer;
  var
    Candidate: Integer;
  begin
    Result := -1;
    for Candidate := 0 to NUM_REF_FRAMES - 1 do
    begin
      Hint := ShiftedOrderHints[Candidate];
      if (not UsedFrame[Candidate]) and (Hint >= CurFrameHint) and ((Result < 0) or (Hint < BestHint)) then
      begin
        Result := Candidate;
        BestHint := Hint;
      end;
    end;
  end;

  function FindLatestForward: Integer;
  var
    Candidate: Integer;
  begin
    Result := -1;
    for Candidate := 0 to NUM_REF_FRAMES - 1 do
    begin
      Hint := ShiftedOrderHints[Candidate];
      if (not UsedFrame[Candidate]) and (Hint < CurFrameHint) and ((Result < 0) or (Hint >= BestHint)) then
      begin
        Result := Candidate;
        BestHint := Hint;
      end;
    end;
  end;

begin
  BestHint := 0;
  for Index := 0 to REFS_PER_FRAME - 1 do
    Header.ref_frame_idx[Index] := -1;
  Header.ref_frame_idx[LAST_FRAME - LAST_FRAME] := LastFrameIdx;
  Header.ref_frame_idx[GOLDEN_FRAME - LAST_FRAME] := GoldFrameIdx;
  for Index := 0 to NUM_REF_FRAMES - 1 do
    UsedFrame[Index] := False;
  UsedFrame[LastFrameIdx] := True;
  UsedFrame[GoldFrameIdx] := True;
  CurFrameHint := 1 shl (Sequence.OrderHintBits - 1);
  for Index := 0 to NUM_REF_FRAMES - 1 do
    ShiftedOrderHints[Index] := CurFrameHint + GetRelativeDist(Sequence, Slots.RefOrderHint[Index], Header.OrderHint);
  Ref := FindLatestBackward;
  if Ref >= 0 then
  begin
    Header.ref_frame_idx[ALTREF_FRAME - LAST_FRAME] := Ref;
    UsedFrame[Ref] := True;
  end;
  Ref := FindEarliestBackward;
  if Ref >= 0 then
  begin
    Header.ref_frame_idx[BWDREF_FRAME - LAST_FRAME] := Ref;
    UsedFrame[Ref] := True;
  end;
  Ref := FindEarliestBackward;
  if Ref >= 0 then
  begin
    Header.ref_frame_idx[ALTREF2_FRAME - LAST_FRAME] := Ref;
    UsedFrame[Ref] := True;
  end;
  for Index := 0 to REFS_PER_FRAME - 3 do
  begin
    RefFrame := Ref_Frame_List[Index];
    if Header.ref_frame_idx[RefFrame - LAST_FRAME] < 0 then
    begin
      Ref := FindLatestForward;
      if Ref >= 0 then
      begin
        Header.ref_frame_idx[RefFrame - LAST_FRAME] := Ref;
        UsedFrame[Ref] := True;
      end;
    end;
  end;
  Ref := -1;
  for Index := 0 to NUM_REF_FRAMES - 1 do
  begin
    Hint := ShiftedOrderHints[Index];
    if (Ref < 0) or (Hint < BestHint) then
    begin
      Ref := Index;
      BestHint := Hint;
    end;
  end;
  for Index := 0 to REFS_PER_FRAME - 1 do
    if Header.ref_frame_idx[Index] < 0 then
      Header.ref_frame_idx[Index] := Ref;
end;

function TileLog2(BlockSize, Target: Integer): Integer;
begin
  Result := 0;
  while (BlockSize shl Result) < Target do
    Inc(Result);
end;

procedure ParseTileInfo(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
var
  SbCols, SbRows, SbShift, SbSize, MaxTileWidthSb, MaxTileAreaSb: Integer;
  MinLog2TileCols, MaxLog2TileCols, MaxLog2TileRows, MinLog2Tiles, MinLog2TileRows: Integer;
  TileWidthSb, TileHeightSb, StartSb, Index, WidestTileSb, MaxWidth, MaxHeight, SizeSb, MaxTileHeightSb: Integer;
begin
  if Sequence.use_128x128_superblock then
  begin
    SbCols := (Header.MiCols + 31) shr 5;
    SbRows := (Header.MiRows + 31) shr 5;
    SbShift := 5;
  end
  else
  begin
    SbCols := (Header.MiCols + 15) shr 4;
    SbRows := (Header.MiRows + 15) shr 4;
    SbShift := 4;
  end;
  SbSize := SbShift + 2;
  MaxTileWidthSb := MAX_TILE_WIDTH shr SbSize;
  MaxTileAreaSb := MAX_TILE_AREA shr (2 * SbSize);
  MinLog2TileCols := TileLog2(MaxTileWidthSb, SbCols);
  MaxLog2TileCols := TileLog2(1, Min(SbCols, MAX_TILE_COLS));
  MaxLog2TileRows := TileLog2(1, Min(SbRows, MAX_TILE_ROWS));
  MinLog2Tiles := Max(MinLog2TileCols, TileLog2(MaxTileAreaSb, SbRows * SbCols));
  if ReadFlag(Reader) then
  begin
    Header.TileColsLog2 := MinLog2TileCols;
    while Header.TileColsLog2 < MaxLog2TileCols do
    begin
      if ReadFlag(Reader) then
        Inc(Header.TileColsLog2)
      else
        Break;
    end;
    TileWidthSb := (SbCols + (1 shl Header.TileColsLog2) - 1) shr Header.TileColsLog2;
    Index := 0;
    StartSb := 0;
    while StartSb < SbCols do
    begin
      Header.MiColStarts[Index] := StartSb shl SbShift;
      Inc(Index);
      Inc(StartSb, TileWidthSb);
    end;
    Header.MiColStarts[Index] := Header.MiCols;
    Header.TileCols := Index;
    MinLog2TileRows := Max(MinLog2Tiles - Header.TileColsLog2, 0);
    Header.TileRowsLog2 := MinLog2TileRows;
    while Header.TileRowsLog2 < MaxLog2TileRows do
    begin
      if ReadFlag(Reader) then
        Inc(Header.TileRowsLog2)
      else
        Break;
    end;
    TileHeightSb := (SbRows + (1 shl Header.TileRowsLog2) - 1) shr Header.TileRowsLog2;
    Index := 0;
    StartSb := 0;
    while StartSb < SbRows do
    begin
      Header.MiRowStarts[Index] := StartSb shl SbShift;
      Inc(Index);
      Inc(StartSb, TileHeightSb);
    end;
    Header.MiRowStarts[Index] := Header.MiRows;
    Header.TileRows := Index;
  end
  else
  begin
    WidestTileSb := 0;
    StartSb := 0;
    Index := 0;
    while StartSb < SbCols do
    begin
      if Index >= MAX_TILE_COLS then
        RaiseAv1Error('too many tile columns');
      Header.MiColStarts[Index] := StartSb shl SbShift;
      MaxWidth := Min(SbCols - StartSb, MaxTileWidthSb);
      SizeSb := Integer(ReadNonSymmetric(Reader, MaxWidth)) + 1;
      WidestTileSb := Max(SizeSb, WidestTileSb);
      Inc(StartSb, SizeSb);
      Inc(Index);
    end;
    Header.MiColStarts[Index] := Header.MiCols;
    Header.TileCols := Index;
    Header.TileColsLog2 := TileLog2(1, Header.TileCols);
    if MinLog2Tiles > 0 then
      MaxTileAreaSb := (SbRows * SbCols) shr (MinLog2Tiles + 1)
    else
      MaxTileAreaSb := SbRows * SbCols;
    MaxTileHeightSb := Max(MaxTileAreaSb div WidestTileSb, 1);
    StartSb := 0;
    Index := 0;
    while StartSb < SbRows do
    begin
      if Index >= MAX_TILE_ROWS then
        RaiseAv1Error('too many tile rows');
      Header.MiRowStarts[Index] := StartSb shl SbShift;
      MaxHeight := Min(SbRows - StartSb, MaxTileHeightSb);
      SizeSb := Integer(ReadNonSymmetric(Reader, MaxHeight)) + 1;
      Inc(StartSb, SizeSb);
      Inc(Index);
    end;
    Header.MiRowStarts[Index] := Header.MiRows;
    Header.TileRows := Index;
    Header.TileRowsLog2 := TileLog2(1, Header.TileRows);
  end;
  if (Header.TileColsLog2 > 0) or (Header.TileRowsLog2 > 0) then
  begin
    Header.context_update_tile_id := ReadBits(Reader, Header.TileRowsLog2 + Header.TileColsLog2);
    Header.TileSizeBytes := Integer(ReadBits(Reader, 2)) + 1;
  end
  else
    Header.context_update_tile_id := 0;
end;

function ReadDeltaQ(var Reader: TBitReader): Integer;
begin
  if ReadFlag(Reader) then
    Result := ReadSigned(Reader, 1 + 6)
  else
    Result := 0;
end;

procedure ParseQuantizationParams(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
var
  DiffUvDelta: Boolean;
begin
  Header.base_q_idx := ReadBits(Reader, 8);
  Header.DeltaQYDc := ReadDeltaQ(Reader);
  if Sequence.NumPlanes > 1 then
  begin
    if Sequence.separate_uv_delta_q then
      DiffUvDelta := ReadFlag(Reader)
    else
      DiffUvDelta := False;
    Header.DeltaQUDc := ReadDeltaQ(Reader);
    Header.DeltaQUAc := ReadDeltaQ(Reader);
    if DiffUvDelta then
    begin
      Header.DeltaQVDc := ReadDeltaQ(Reader);
      Header.DeltaQVAc := ReadDeltaQ(Reader);
    end
    else
    begin
      Header.DeltaQVDc := Header.DeltaQUDc;
      Header.DeltaQVAc := Header.DeltaQUAc;
    end;
  end
  else
  begin
    Header.DeltaQUDc := 0;
    Header.DeltaQUAc := 0;
    Header.DeltaQVDc := 0;
    Header.DeltaQVAc := 0;
  end;
  Header.using_qmatrix := ReadFlag(Reader);
  if Header.using_qmatrix then
  begin
    Header.qm_y := ReadBits(Reader, 4);
    Header.qm_u := ReadBits(Reader, 4);
    if not Sequence.separate_uv_delta_q then
      Header.qm_v := Header.qm_u
    else
      Header.qm_v := ReadBits(Reader, 4);
  end;
end;

procedure ParseSegmentationParams(var Reader: TBitReader; var Header: TFrameHeader);
var
  Segment, Feature, BitsToRead, Limit, ClippedValue, FeatureValue: Integer;
  Enabled: Boolean;
begin
  Header.segmentation_enabled := ReadFlag(Reader);
  if Header.segmentation_enabled then
  begin
    if Header.primary_ref_frame = PRIMARY_REF_NONE then
    begin
      Header.segmentation_update_map := True;
      Header.segmentation_temporal_update := False;
      Header.segmentation_update_data := True;
    end
    else
    begin
      Header.segmentation_update_map := ReadFlag(Reader);
      if Header.segmentation_update_map then
        Header.segmentation_temporal_update := ReadFlag(Reader)
      else
        Header.segmentation_temporal_update := False;
      Header.segmentation_update_data := ReadFlag(Reader);
    end;
    if Header.segmentation_update_data then
      for Segment := 0 to MAX_SEGMENTS - 1 do
        for Feature := 0 to SEG_LVL_MAX - 1 do
        begin
          Enabled := ReadFlag(Reader);
          Header.Segmentation.FeatureEnabled[Segment, Feature] := Enabled;
          ClippedValue := 0;
          if Enabled then
          begin
            BitsToRead := Segmentation_Feature_Bits[Feature];
            Limit := Segmentation_Feature_Max[Feature];
            if Segmentation_Feature_Signed[Feature] = 1 then
            begin
              FeatureValue := ReadSigned(Reader, 1 + BitsToRead);
              ClippedValue := Clip3(-Limit, Limit, FeatureValue);
            end
            else
            begin
              FeatureValue := ReadBits(Reader, BitsToRead);
              ClippedValue := Clip3(0, Limit, FeatureValue);
            end;
          end;
          Header.Segmentation.FeatureData[Segment, Feature] := ClippedValue;
        end;
  end
  else
  begin
    Header.segmentation_update_map := False;
    Header.segmentation_temporal_update := False;
    Header.segmentation_update_data := False;
    FillChar(Header.Segmentation, SizeOf(Header.Segmentation), 0);
  end;
  Header.SegIdPreSkip := False;
  Header.LastActiveSegId := 0;
  for Segment := 0 to MAX_SEGMENTS - 1 do
    for Feature := 0 to SEG_LVL_MAX - 1 do
      if Header.Segmentation.FeatureEnabled[Segment, Feature] then
      begin
        Header.LastActiveSegId := Segment;
        if Feature >= SEG_LVL_REF_FRAME then
          Header.SegIdPreSkip := True;
      end;
end;

procedure ParseDeltaParams(var Reader: TBitReader; var Header: TFrameHeader);
begin
  Header.delta_q_res := 0;
  Header.delta_q_present := False;
  if Header.base_q_idx > 0 then
    Header.delta_q_present := ReadFlag(Reader);
  if Header.delta_q_present then
    Header.delta_q_res := ReadBits(Reader, 2);
  Header.delta_lf_present := False;
  Header.delta_lf_res := 0;
  Header.delta_lf_multi := False;
  if Header.delta_q_present then
  begin
    if not Header.allow_intrabc then
      Header.delta_lf_present := ReadFlag(Reader);
    if Header.delta_lf_present then
    begin
      Header.delta_lf_res := ReadBits(Reader, 2);
      Header.delta_lf_multi := ReadFlag(Reader);
    end;
  end;
end;

{ The segment's qindex ignoring delta q (get_qindex( 1, segmentId )). }
function SegmentQIndex(const Header: TFrameHeader; SegmentId: Integer): Integer;
begin
  if Header.segmentation_enabled and Header.Segmentation.FeatureEnabled[SegmentId, SEG_LVL_ALT_Q] then
    Result := Clip3(0, 255, Header.base_q_idx + Header.Segmentation.FeatureData[SegmentId, SEG_LVL_ALT_Q])
  else
    Result := Header.base_q_idx;
end;

procedure ComputeLossless(var Header: TFrameHeader);
var
  SegmentId, QIndex: Integer;
begin
  Header.CodedLossless := True;
  for SegmentId := 0 to MAX_SEGMENTS - 1 do
  begin
    QIndex := SegmentQIndex(Header, SegmentId);
    Header.LosslessArray[SegmentId] := (QIndex = 0) and (Header.DeltaQYDc = 0) and (Header.DeltaQUAc = 0)
      and (Header.DeltaQUDc = 0) and (Header.DeltaQVAc = 0) and (Header.DeltaQVDc = 0);
    if not Header.LosslessArray[SegmentId] then
      Header.CodedLossless := False;
    if Header.using_qmatrix then
    begin
      if Header.LosslessArray[SegmentId] then
      begin
        Header.SegQMLevel[0, SegmentId] := 15;
        Header.SegQMLevel[1, SegmentId] := 15;
        Header.SegQMLevel[2, SegmentId] := 15;
      end
      else
      begin
        Header.SegQMLevel[0, SegmentId] := Header.qm_y;
        Header.SegQMLevel[1, SegmentId] := Header.qm_u;
        Header.SegQMLevel[2, SegmentId] := Header.qm_v;
      end;
    end;
  end;
  Header.AllLossless := Header.CodedLossless and (Header.FrameWidth = Header.UpscaledWidth);
end;

procedure ParseLoopFilterParams(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
var
  Index: Integer;
begin
  if Header.CodedLossless or Header.allow_intrabc then
  begin
    Header.loop_filter_level[0] := 0;
    Header.loop_filter_level[1] := 0;
    ResetLoopFilterDeltas(Header.LoopFilterDeltas);
    Exit;
  end;
  Header.loop_filter_level[0] := ReadBits(Reader, 6);
  Header.loop_filter_level[1] := ReadBits(Reader, 6);
  if Sequence.NumPlanes > 1 then
    if (Header.loop_filter_level[0] <> 0) or (Header.loop_filter_level[1] <> 0) then
    begin
      Header.loop_filter_level[2] := ReadBits(Reader, 6);
      Header.loop_filter_level[3] := ReadBits(Reader, 6);
    end;
  Header.loop_filter_sharpness := ReadBits(Reader, 3);
  Header.loop_filter_delta_enabled := ReadFlag(Reader);
  if Header.loop_filter_delta_enabled then
    if ReadFlag(Reader) then
    begin
      for Index := 0 to TOTAL_REFS_PER_FRAME - 1 do
        if ReadFlag(Reader) then
          Header.LoopFilterDeltas.loop_filter_ref_deltas[Index] := ReadSigned(Reader, 1 + 6);
      for Index := 0 to 1 do
        if ReadFlag(Reader) then
          Header.LoopFilterDeltas.loop_filter_mode_deltas[Index] := ReadSigned(Reader, 1 + 6);
    end;
end;

procedure ParseCdefParams(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
var
  Index: Integer;
begin
  if Header.CodedLossless or Header.allow_intrabc or not Sequence.enable_cdef then
  begin
    Header.cdef_bits := 0;
    Header.cdef_y_pri_strength[0] := 0;
    Header.cdef_y_sec_strength[0] := 0;
    Header.cdef_uv_pri_strength[0] := 0;
    Header.cdef_uv_sec_strength[0] := 0;
    Header.CdefDamping := 3;
    Exit;
  end;
  Header.CdefDamping := Integer(ReadBits(Reader, 2)) + 3;
  Header.cdef_bits := ReadBits(Reader, 2);
  for Index := 0 to (1 shl Header.cdef_bits) - 1 do
  begin
    Header.cdef_y_pri_strength[Index] := ReadBits(Reader, 4);
    Header.cdef_y_sec_strength[Index] := ReadBits(Reader, 2);
    if Header.cdef_y_sec_strength[Index] = 3 then
      Inc(Header.cdef_y_sec_strength[Index]);
    if Sequence.NumPlanes > 1 then
    begin
      Header.cdef_uv_pri_strength[Index] := ReadBits(Reader, 4);
      Header.cdef_uv_sec_strength[Index] := ReadBits(Reader, 2);
      if Header.cdef_uv_sec_strength[Index] = 3 then
        Inc(Header.cdef_uv_sec_strength[Index]);
    end;
  end;
end;

procedure ParseLrParams(var Reader: TBitReader; const Sequence: TSequenceHeader; var Header: TFrameHeader);
var
  Plane, LrUnitShift, LrUvShift: Integer;
  UsesChromaLr: Boolean;
begin
  if Header.AllLossless or Header.allow_intrabc or not Sequence.enable_restoration then
  begin
    Header.FrameRestorationType[0] := RESTORE_NONE;
    Header.FrameRestorationType[1] := RESTORE_NONE;
    Header.FrameRestorationType[2] := RESTORE_NONE;
    Header.UsesLr := False;
    Exit;
  end;
  Header.UsesLr := False;
  UsesChromaLr := False;
  for Plane := 0 to Sequence.NumPlanes - 1 do
  begin
    Header.FrameRestorationType[Plane] := Remap_Lr_Type[ReadBits(Reader, 2)];
    if Header.FrameRestorationType[Plane] <> RESTORE_NONE then
    begin
      Header.UsesLr := True;
      if Plane > 0 then
        UsesChromaLr := True;
    end;
  end;
  if Header.UsesLr then
  begin
    if Sequence.use_128x128_superblock then
      LrUnitShift := Integer(ReadBits(Reader, 1)) + 1
    else
    begin
      LrUnitShift := ReadBits(Reader, 1);
      if LrUnitShift <> 0 then
        Inc(LrUnitShift, ReadBits(Reader, 1));
    end;
    Header.LoopRestorationSize[0] := RESTORATION_TILESIZE_MAX shr (2 - LrUnitShift);
    if (Sequence.subsampling_x <> 0) and (Sequence.subsampling_y <> 0) and UsesChromaLr then
      LrUvShift := ReadBits(Reader, 1)
    else
      LrUvShift := 0;
    Header.LoopRestorationSize[1] := Header.LoopRestorationSize[0] shr LrUvShift;
    Header.LoopRestorationSize[2] := Header.LoopRestorationSize[0] shr LrUvShift;
  end;
end;

procedure ParseSkipModeParams(var Reader: TBitReader; const Sequence: TSequenceHeader; const Slots: TReferenceSlots;
  var Header: TFrameHeader);
var
  ForwardIdx, BackwardIdx, SecondForwardIdx, Index, RefHint: Integer;
  ForwardHint, BackwardHint, SecondForwardHint: Integer;
  SkipModeAllowed: Boolean;
begin
  ForwardHint := 0;
  BackwardHint := 0;
  SecondForwardHint := 0;
  if Header.FrameIsIntra or not Header.reference_select or not Sequence.enable_order_hint then
    SkipModeAllowed := False
  else
  begin
    ForwardIdx := -1;
    BackwardIdx := -1;
    for Index := 0 to REFS_PER_FRAME - 1 do
    begin
      RefHint := Slots.RefOrderHint[Header.ref_frame_idx[Index]];
      if GetRelativeDist(Sequence, RefHint, Header.OrderHint) < 0 then
      begin
        if (ForwardIdx < 0) or (GetRelativeDist(Sequence, RefHint, ForwardHint) > 0) then
        begin
          ForwardIdx := Index;
          ForwardHint := RefHint;
        end;
      end
      else if GetRelativeDist(Sequence, RefHint, Header.OrderHint) > 0 then
      begin
        if (BackwardIdx < 0) or (GetRelativeDist(Sequence, RefHint, BackwardHint) < 0) then
        begin
          BackwardIdx := Index;
          BackwardHint := RefHint;
        end;
      end;
    end;
    if ForwardIdx < 0 then
      SkipModeAllowed := False
    else if BackwardIdx >= 0 then
    begin
      SkipModeAllowed := True;
      Header.SkipModeFrame[0] := LAST_FRAME + Min(ForwardIdx, BackwardIdx);
      Header.SkipModeFrame[1] := LAST_FRAME + Max(ForwardIdx, BackwardIdx);
    end
    else
    begin
      SecondForwardIdx := -1;
      for Index := 0 to REFS_PER_FRAME - 1 do
      begin
        RefHint := Slots.RefOrderHint[Header.ref_frame_idx[Index]];
        if GetRelativeDist(Sequence, RefHint, ForwardHint) < 0 then
          if (SecondForwardIdx < 0) or (GetRelativeDist(Sequence, RefHint, SecondForwardHint) > 0) then
          begin
            SecondForwardIdx := Index;
            SecondForwardHint := RefHint;
          end;
      end;
      if SecondForwardIdx < 0 then
        SkipModeAllowed := False
      else
      begin
        SkipModeAllowed := True;
        Header.SkipModeFrame[0] := LAST_FRAME + Min(ForwardIdx, SecondForwardIdx);
        Header.SkipModeFrame[1] := LAST_FRAME + Max(ForwardIdx, SecondForwardIdx);
      end;
    end;
  end;
  if SkipModeAllowed then
    Header.skip_mode_present := ReadFlag(Reader)
  else
    Header.skip_mode_present := False;
end;

function DecodeSubexp(var Reader: TBitReader; NumSyms: Integer): Integer;
var
  Index, Mk, K, B2, A: Integer;
begin
  Index := 0;
  Mk := 0;
  K := 3;
  while True do
  begin
    if Index <> 0 then
      B2 := K + Index - 1
    else
      B2 := K;
    A := 1 shl B2;
    if NumSyms <= Mk + 3 * A then
      Exit(Integer(ReadNonSymmetric(Reader, NumSyms - Mk)) + Mk)
    else if ReadFlag(Reader) then
    begin
      Inc(Index);
      Inc(Mk, A);
    end
    else
      Exit(Integer(ReadBits(Reader, B2)) + Mk);
  end;
end;

function InverseRecenter(R, V: Integer): Integer;
begin
  if V > 2 * R then
    Result := V
  else if (V and 1) <> 0 then
    Result := R - ((V + 1) shr 1)
  else
    Result := R + (V shr 1);
end;

function DecodeUnsignedSubexpWithRef(var Reader: TBitReader; Mx, R: Integer): Integer;
var
  V: Integer;
begin
  V := DecodeSubexp(Reader, Mx);
  if (R shl 1) <= Mx then
    Result := InverseRecenter(R, V)
  else
    Result := Mx - 1 - InverseRecenter(Mx - 1 - R, V);
end;

function DecodeSignedSubexpWithRef(var Reader: TBitReader; Low, High, R: Integer): Integer;
begin
  Result := DecodeUnsignedSubexpWithRef(Reader, High - Low, R - Low) + Low;
end;

procedure ReadGlobalParam(var Reader: TBitReader; var Header: TFrameHeader; GmTypeValue, Ref, Index: Integer);
var
  AbsBits, PrecBits, PrecDiff, RoundValue, Sub, Mx, R: Integer;
begin
  AbsBits := GM_ABS_ALPHA_BITS;
  PrecBits := GM_ALPHA_PREC_BITS;
  if Index < 2 then
  begin
    if GmTypeValue = TRANSLATION then
    begin
      AbsBits := GM_ABS_TRANS_ONLY_BITS - Ord(not Header.allow_high_precision_mv);
      PrecBits := GM_TRANS_ONLY_PREC_BITS - Ord(not Header.allow_high_precision_mv);
    end
    else
    begin
      AbsBits := GM_ABS_TRANS_BITS;
      PrecBits := GM_TRANS_PREC_BITS;
    end;
  end;
  PrecDiff := WARPEDMODEL_PREC_BITS - PrecBits;
  if Index mod 3 = 2 then
  begin
    RoundValue := 1 shl WARPEDMODEL_PREC_BITS;
    Sub := 1 shl PrecBits;
  end
  else
  begin
    RoundValue := 0;
    Sub := 0;
  end;
  Mx := 1 shl AbsBits;
  R := SarLongint(Header.PrevGmParams[Ref, Index], PrecDiff) - Sub;
  Header.gm_params[Ref, Index] := (DecodeSignedSubexpWithRef(Reader, -Mx, Mx + 1, R) shl PrecDiff) + RoundValue;
end;

procedure ParseGlobalMotionParams(var Reader: TBitReader; var Header: TFrameHeader);
var
  Ref, GmTypeValue: Integer;
begin
  for Ref := LAST_FRAME to ALTREF_FRAME do
    Header.GmType[Ref] := IDENTITY;
  ResetGlobalMotion(Header.gm_params);
  if Header.FrameIsIntra then
    Exit;
  for Ref := LAST_FRAME to ALTREF_FRAME do
  begin
    if ReadFlag(Reader) then
    begin
      if ReadFlag(Reader) then
        GmTypeValue := ROTZOOM
      else if ReadFlag(Reader) then
        GmTypeValue := TRANSLATION
      else
        GmTypeValue := AFFINE;
    end
    else
      GmTypeValue := IDENTITY;
    Header.GmType[Ref] := GmTypeValue;
    if GmTypeValue >= ROTZOOM then
    begin
      ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 2);
      ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 3);
      if GmTypeValue = AFFINE then
      begin
        ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 4);
        ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 5);
      end
      else
      begin
        Header.gm_params[Ref, 4] := -Header.gm_params[Ref, 3];
        Header.gm_params[Ref, 5] := Header.gm_params[Ref, 2];
      end;
    end;
    if GmTypeValue >= TRANSLATION then
    begin
      ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 0);
      ReadGlobalParam(Reader, Header, GmTypeValue, Ref, 1);
    end;
  end;
end;

procedure ResetGrainParams(var Params: TFilmGrainParams);
begin
  FillChar(Params, SizeOf(Params), 0);
end;

procedure ParseFilmGrainParams(var Reader: TBitReader; const Sequence: TSequenceHeader; const Slots: TReferenceSlots;
  var Header: TFrameHeader);
var
  Params: ^TFilmGrainParams;
  Index, NumPosLuma, NumPosChroma, TempGrainSeed, RefIndex: Integer;
begin
  Params := @Header.FilmGrain;
  if (not Sequence.film_grain_params_present) or ((not Header.show_frame) and (not Header.showable_frame)) then
  begin
    ResetGrainParams(Params^);
    Exit;
  end;
  Params^.apply_grain := ReadFlag(Reader);
  if not Params^.apply_grain then
  begin
    ResetGrainParams(Params^);
    Exit;
  end;
  Params^.grain_seed := ReadBits(Reader, 16);
  if Header.frame_type = INTER_FRAME then
    Params^.update_grain := ReadFlag(Reader)
  else
    Params^.update_grain := True;
  if not Params^.update_grain then
  begin
    RefIndex := ReadBits(Reader, 3);
    TempGrainSeed := Params^.grain_seed;
    LoadGrainParams(Slots, RefIndex, Params^);
    Params^.grain_seed := TempGrainSeed;
    Exit;
  end;
  Params^.num_y_points := ReadBits(Reader, 4);
  if Params^.num_y_points > 14 then
    RaiseAv1Error('too many film grain luma points');
  for Index := 0 to Params^.num_y_points - 1 do
  begin
    Params^.point_y_value[Index] := ReadBits(Reader, 8);
    Params^.point_y_scaling[Index] := ReadBits(Reader, 8);
  end;
  if Sequence.mono_chrome then
    Params^.chroma_scaling_from_luma := False
  else
    Params^.chroma_scaling_from_luma := ReadFlag(Reader);
  if Sequence.mono_chrome or Params^.chroma_scaling_from_luma or
    ((Sequence.subsampling_x = 1) and (Sequence.subsampling_y = 1) and (Params^.num_y_points = 0)) then
  begin
    Params^.num_cb_points := 0;
    Params^.num_cr_points := 0;
  end
  else
  begin
    Params^.num_cb_points := ReadBits(Reader, 4);
    if Params^.num_cb_points > 10 then
      RaiseAv1Error('too many film grain cb points');
    for Index := 0 to Params^.num_cb_points - 1 do
    begin
      Params^.point_cb_value[Index] := ReadBits(Reader, 8);
      Params^.point_cb_scaling[Index] := ReadBits(Reader, 8);
    end;
    Params^.num_cr_points := ReadBits(Reader, 4);
    if Params^.num_cr_points > 10 then
      RaiseAv1Error('too many film grain cr points');
    for Index := 0 to Params^.num_cr_points - 1 do
    begin
      Params^.point_cr_value[Index] := ReadBits(Reader, 8);
      Params^.point_cr_scaling[Index] := ReadBits(Reader, 8);
    end;
  end;
  Params^.grain_scaling_minus_8 := ReadBits(Reader, 2);
  Params^.ar_coeff_lag := ReadBits(Reader, 2);
  NumPosLuma := 2 * Params^.ar_coeff_lag * (Params^.ar_coeff_lag + 1);
  if Params^.num_y_points <> 0 then
  begin
    NumPosChroma := NumPosLuma + 1;
    for Index := 0 to NumPosLuma - 1 do
      Params^.ar_coeffs_y_plus_128[Index] := ReadBits(Reader, 8);
  end
  else
    NumPosChroma := NumPosLuma;
  if Params^.chroma_scaling_from_luma or (Params^.num_cb_points <> 0) then
    for Index := 0 to NumPosChroma - 1 do
      Params^.ar_coeffs_cb_plus_128[Index] := ReadBits(Reader, 8);
  if Params^.chroma_scaling_from_luma or (Params^.num_cr_points <> 0) then
    for Index := 0 to NumPosChroma - 1 do
      Params^.ar_coeffs_cr_plus_128[Index] := ReadBits(Reader, 8);
  Params^.ar_coeff_shift_minus_6 := ReadBits(Reader, 2);
  Params^.grain_scale_shift := ReadBits(Reader, 2);
  if Params^.num_cb_points <> 0 then
  begin
    Params^.cb_mult := ReadBits(Reader, 8);
    Params^.cb_luma_mult := ReadBits(Reader, 8);
    Params^.cb_offset := ReadBits(Reader, 9);
  end;
  if Params^.num_cr_points <> 0 then
  begin
    Params^.cr_mult := ReadBits(Reader, 8);
    Params^.cr_luma_mult := ReadBits(Reader, 8);
    Params^.cr_offset := ReadBits(Reader, 9);
  end;
  Params^.overlap_flag := ReadFlag(Reader);
  Params^.clip_to_restricted_range := ReadFlag(Reader);
end;

procedure ReadTemporalPointInfo(var Reader: TBitReader; const Sequence: TSequenceHeader);
begin
  ReadBits(Reader, Sequence.frame_presentation_time_length_minus_1 + 1);
end;

{ mark_ref_frames( idLen ). }
procedure MarkRefFrames(const Sequence: TSequenceHeader; var Slots: TReferenceSlots; CurrentFrameId, IdLen: Integer);
var
  DiffLen, Index: Integer;
begin
  DiffLen := Sequence.delta_frame_id_length_minus_2 + 2;
  for Index := 0 to NUM_REF_FRAMES - 1 do
  begin
    if CurrentFrameId > (1 shl DiffLen) then
    begin
      if (Slots.RefFrameId[Index] > CurrentFrameId) or (Slots.RefFrameId[Index] < (CurrentFrameId - (1 shl DiffLen))) then
        Slots.RefValid[Index] := False;
    end
    else if (Slots.RefFrameId[Index] > CurrentFrameId) and
      (Slots.RefFrameId[Index] < ((1 shl IdLen) + CurrentFrameId - (1 shl DiffLen))) then
      Slots.RefValid[Index] := False;
  end;
end;

procedure ParseUncompressedHeader(var Reader: TBitReader; const Sequence: TSequenceHeader;
  var Slots: TReferenceSlots; var State: THeaderState; TemporalId, SpatialId: Integer;
  out Header: TFrameHeader);
var
  IdLen, AllFrames, Index, OpNum, OpPtIdc, RefFrame, Hint, PrevFrame: Integer;
  RefOrderHintValue, LastFrameIdx, GoldFrameIdx: Integer;
  FrameRefsShortSignaling, InTemporalLayer, InSpatialLayer: Boolean;
  Previous: TReferenceFrame;
begin
  FillChar(Header, SizeOf(Header), 0);
  Header.temporal_id := TemporalId;
  Header.spatial_id := SpatialId;
  IdLen := 0;
  if Sequence.frame_id_numbers_present_flag then
    IdLen := Sequence.additional_frame_id_length_minus_1 + Sequence.delta_frame_id_length_minus_2 + 3;
  AllFrames := (1 shl NUM_REF_FRAMES) - 1;
  if Sequence.reduced_still_picture_header then
  begin
    Header.show_existing_frame := False;
    Header.frame_type := KEY_FRAME;
    Header.FrameIsIntra := True;
    Header.show_frame := True;
    Header.showable_frame := False;
    Header.error_resilient_mode := True;
  end
  else
  begin
    Header.show_existing_frame := ReadFlag(Reader);
    if Header.show_existing_frame then
    begin
      Header.frame_to_show_map_idx := ReadBits(Reader, 3);
      if Sequence.decoder_model_info_present_flag and not Sequence.equal_picture_interval then
        ReadTemporalPointInfo(Reader, Sequence);
      Header.refresh_frame_flags := 0;
      if Sequence.frame_id_numbers_present_flag then
        ReadBits(Reader, IdLen);
      RequireReference(Slots, Header.frame_to_show_map_idx);
      Header.frame_type := Slots.Frames[Header.frame_to_show_map_idx].RefFrameType;
      if Header.frame_type = KEY_FRAME then
        Header.refresh_frame_flags := AllFrames;
      if Sequence.film_grain_params_present then
        LoadGrainParams(Slots, Header.frame_to_show_map_idx, Header.FilmGrain);
      Exit;
    end;
    Header.frame_type := ReadBits(Reader, 2);
    Header.FrameIsIntra := (Header.frame_type = INTRA_ONLY_FRAME) or (Header.frame_type = KEY_FRAME);
    Header.show_frame := ReadFlag(Reader);
    if Header.show_frame and Sequence.decoder_model_info_present_flag and not Sequence.equal_picture_interval then
      ReadTemporalPointInfo(Reader, Sequence);
    if Header.show_frame then
      Header.showable_frame := Header.frame_type <> KEY_FRAME
    else
      Header.showable_frame := ReadFlag(Reader);
    if (Header.frame_type = SWITCH_FRAME) or ((Header.frame_type = KEY_FRAME) and Header.show_frame) then
      Header.error_resilient_mode := True
    else
      Header.error_resilient_mode := ReadFlag(Reader);
  end;
  if (Header.frame_type = KEY_FRAME) and Header.show_frame then
  begin
    for Index := 0 to NUM_REF_FRAMES - 1 do
    begin
      Slots.RefValid[Index] := False;
      Slots.RefOrderHint[Index] := 0;
    end;
    for Index := 0 to REFS_PER_FRAME - 1 do
      Header.OrderHints[LAST_FRAME + Index] := 0;
  end;
  Header.disable_cdf_update := ReadFlag(Reader);
  if Sequence.seq_force_screen_content_tools = SELECT_SCREEN_CONTENT_TOOLS then
    Header.allow_screen_content_tools := ReadBit(Reader)
  else
    Header.allow_screen_content_tools := Sequence.seq_force_screen_content_tools;
  if Header.allow_screen_content_tools <> 0 then
  begin
    if Sequence.seq_force_integer_mv = SELECT_INTEGER_MV then
      Header.force_integer_mv := ReadBit(Reader)
    else
      Header.force_integer_mv := Sequence.seq_force_integer_mv;
  end
  else
    Header.force_integer_mv := 0;
  if Header.FrameIsIntra then
    Header.force_integer_mv := 1;
  if Sequence.frame_id_numbers_present_flag then
  begin
    Header.current_frame_id := ReadBits(Reader, IdLen);
    MarkRefFrames(Sequence, Slots, Header.current_frame_id, IdLen);
  end
  else
    Header.current_frame_id := 0;
  State.current_frame_id := Header.current_frame_id;
  if Header.frame_type = SWITCH_FRAME then
    Header.frame_size_override_flag := True
  else if Sequence.reduced_still_picture_header then
    Header.frame_size_override_flag := False
  else
    Header.frame_size_override_flag := ReadFlag(Reader);
  Header.OrderHint := ReadBits(Reader, Sequence.OrderHintBits);
  if Header.FrameIsIntra or Header.error_resilient_mode then
    Header.primary_ref_frame := PRIMARY_REF_NONE
  else
    Header.primary_ref_frame := ReadBits(Reader, 3);
  if Sequence.decoder_model_info_present_flag then
    if ReadFlag(Reader) then
      for OpNum := 0 to Sequence.operating_points_cnt_minus_1 do
        if Sequence.decoder_model_present_for_this_op[OpNum] then
        begin
          OpPtIdc := Sequence.operating_point_idc[OpNum];
          InTemporalLayer := ((OpPtIdc shr TemporalId) and 1) <> 0;
          InSpatialLayer := ((OpPtIdc shr (SpatialId + 8)) and 1) <> 0;
          if (OpPtIdc = 0) or (InTemporalLayer and InSpatialLayer) then
            ReadBits(Reader, Sequence.buffer_removal_time_length_minus_1 + 1);
        end;
  Header.allow_high_precision_mv := False;
  Header.use_ref_frame_mvs := False;
  Header.allow_intrabc := False;
  if (Header.frame_type = SWITCH_FRAME) or ((Header.frame_type = KEY_FRAME) and Header.show_frame) then
    Header.refresh_frame_flags := AllFrames
  else
    Header.refresh_frame_flags := ReadBits(Reader, 8);
  if (not Header.FrameIsIntra) or (Header.refresh_frame_flags <> AllFrames) then
    if Header.error_resilient_mode and Sequence.enable_order_hint then
      for Index := 0 to NUM_REF_FRAMES - 1 do
      begin
        RefOrderHintValue := ReadBits(Reader, Sequence.OrderHintBits);
        if RefOrderHintValue <> Slots.RefOrderHint[Index] then
          Slots.RefValid[Index] := False;
      end;
  if Header.FrameIsIntra then
  begin
    ParseFrameSize(Reader, Sequence, Header);
    ParseRenderSize(Reader, Header);
    if (Header.allow_screen_content_tools <> 0) and (Header.UpscaledWidth = Header.FrameWidth) then
      Header.allow_intrabc := ReadFlag(Reader);
  end
  else
  begin
    if not Sequence.enable_order_hint then
      FrameRefsShortSignaling := False
    else
    begin
      FrameRefsShortSignaling := ReadFlag(Reader);
      if FrameRefsShortSignaling then
      begin
        LastFrameIdx := ReadBits(Reader, 3);
        GoldFrameIdx := ReadBits(Reader, 3);
        SetFrameRefs(Sequence, Slots, Header, LastFrameIdx, GoldFrameIdx);
      end;
    end;
    Header.frame_refs_short_signaling := FrameRefsShortSignaling;
    for Index := 0 to REFS_PER_FRAME - 1 do
    begin
      if not FrameRefsShortSignaling then
        Header.ref_frame_idx[Index] := ReadBits(Reader, 3);
      if Sequence.frame_id_numbers_present_flag then
        ReadBits(Reader, Sequence.delta_frame_id_length_minus_2 + 2);
    end;
    for Index := 0 to REFS_PER_FRAME - 1 do
      RequireReference(Slots, Header.ref_frame_idx[Index]);
    if Header.frame_size_override_flag and not Header.error_resilient_mode then
      ParseFrameSizeWithRefs(Reader, Sequence, Slots, Header)
    else
    begin
      ParseFrameSize(Reader, Sequence, Header);
      ParseRenderSize(Reader, Header);
    end;
    if Header.force_integer_mv <> 0 then
      Header.allow_high_precision_mv := False
    else
      Header.allow_high_precision_mv := ReadFlag(Reader);
    if ReadFlag(Reader) then
      Header.interpolation_filter := SWITCHABLE
    else
      Header.interpolation_filter := ReadBits(Reader, 2);
    Header.is_motion_mode_switchable := ReadFlag(Reader);
    if Header.error_resilient_mode or not Sequence.enable_ref_frame_mvs then
      Header.use_ref_frame_mvs := False
    else
      Header.use_ref_frame_mvs := ReadFlag(Reader);
    for Index := 0 to REFS_PER_FRAME - 1 do
    begin
      RefFrame := LAST_FRAME + Index;
      Hint := Slots.RefOrderHint[Header.ref_frame_idx[Index]];
      Header.OrderHints[RefFrame] := Hint;
      if not Sequence.enable_order_hint then
        Header.RefFrameSignBias[RefFrame] := 0
      else
        Header.RefFrameSignBias[RefFrame] := Ord(GetRelativeDist(Sequence, Hint, Header.OrderHint) > 0);
    end;
  end;
  if Sequence.reduced_still_picture_header or Header.disable_cdf_update then
    Header.disable_frame_end_update_cdf := True
  else
    Header.disable_frame_end_update_cdf := ReadFlag(Reader);
  { setup_past_independence( ) or load_previous( ), as far as the header uses them. }
  if Header.primary_ref_frame = PRIMARY_REF_NONE then
  begin
    FillChar(Header.Segmentation, SizeOf(Header.Segmentation), 0);
    ResetGlobalMotion(Header.PrevGmParams);
    Header.loop_filter_delta_enabled := True;
    ResetLoopFilterDeltas(Header.LoopFilterDeltas);
  end
  else
  begin
    PrevFrame := Header.ref_frame_idx[Header.primary_ref_frame];
    RequireReference(Slots, PrevFrame);
    Previous := Slots.Frames[PrevFrame];
    Header.PrevGmParams := Previous.SavedGmParams;
    Header.LoopFilterDeltas := Previous.SavedLoopFilterDeltas;
    Header.Segmentation := Previous.SavedSegmentation;
  end;
  ParseTileInfo(Reader, Sequence, Header);
  ParseQuantizationParams(Reader, Sequence, Header);
  ParseSegmentationParams(Reader, Header);
  ParseDeltaParams(Reader, Header);
  ComputeLossless(Header);
  ParseLoopFilterParams(Reader, Sequence, Header);
  ParseCdefParams(Reader, Sequence, Header);
  ParseLrParams(Reader, Sequence, Header);
  if Header.CodedLossless then
    Header.TxMode := ONLY_4X4
  else if ReadFlag(Reader) then
    Header.TxMode := TX_MODE_SELECT
  else
    Header.TxMode := TX_MODE_LARGEST;
  if Header.FrameIsIntra then
    Header.reference_select := False
  else
    Header.reference_select := ReadFlag(Reader);
  ParseSkipModeParams(Reader, Sequence, Slots, Header);
  if Header.FrameIsIntra or Header.error_resilient_mode or not Sequence.enable_warped_motion then
    Header.allow_warped_motion := False
  else
    Header.allow_warped_motion := ReadFlag(Reader);
  Header.reduced_tx_set := ReadFlag(Reader);
  ParseGlobalMotionParams(Reader, Header);
  ParseFilmGrainParams(Reader, Sequence, Slots, Header);
end;

end.
