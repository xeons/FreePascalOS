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
  The deblocking loop filter (specification section 7.14): every
  vertical edge of a plane, then every horizontal one, filtered in
  CurrFrame where a transform edge lies, with strengths from the filter
  levels, segment features and deltas. LoopFilterRows filters the edges
  of a range of mode info rows, so that a pass can be split between
  threads (the edges may be filtered in any order within a pass).
}
unit Av1.LoopFilter;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.Picture, Av1.LoopFilterSamples;

{ The loop filter process over the whole frame (when a level is set). }
procedure ApplyLoopFilter(Frame: TFrameContext);
{ The edges of one plane and pass (0 vertical, 1 horizontal) whose mode
  info row lies in [ RowStart, RowEnd ). }
procedure LoopFilterRows(Frame: TFrameContext; Plane, Pass, RowStart, RowEnd: Integer);

implementation

{ The adaptive filter strength selection process (section 7.14.5). }
function FilterLevel(Frame: TFrameContext; Segment, Ref, ModeType, DeltaLF, Plane, Pass: Integer): Integer;
var
  I, BaseFilterLevel, LevelSegment, Feature, NShift: Integer;
begin
  if Plane = 0 then
    I := Pass
  else
    I := Plane + 1;
  BaseFilterLevel := DeltaLF + Frame.Header.loop_filter_level[I];
  if BaseFilterLevel < 0 then
    BaseFilterLevel := 0
  else if BaseFilterLevel > MAX_LOOP_FILTER then
    BaseFilterLevel := MAX_LOOP_FILTER;
  LevelSegment := BaseFilterLevel;
  Feature := SEG_LVL_ALT_LF_Y_V + I;
  if Frame.SegmentFeatureActiveIndex(Segment, Feature) then
  begin
    LevelSegment := Frame.Header.Segmentation.FeatureData[Segment, Feature] + LevelSegment;
    if LevelSegment < 0 then
      LevelSegment := 0
    else if LevelSegment > MAX_LOOP_FILTER then
      LevelSegment := MAX_LOOP_FILTER;
  end;
  if Frame.Header.loop_filter_delta_enabled then
  begin
    NShift := LevelSegment shr 5;
    if Ref = INTRA_FRAME then
      LevelSegment := LevelSegment + (Frame.Header.LoopFilterDeltas.loop_filter_ref_deltas[INTRA_FRAME] shl NShift)
    else
      LevelSegment := LevelSegment + (Frame.Header.LoopFilterDeltas.loop_filter_ref_deltas[Ref] shl NShift) +
        (Frame.Header.LoopFilterDeltas.loop_filter_mode_deltas[ModeType] shl NShift);
    if LevelSegment < 0 then
      LevelSegment := 0
    else if LevelSegment > MAX_LOOP_FILTER then
      LevelSegment := MAX_LOOP_FILTER;
  end;
  Result := LevelSegment;
end;

{ lvl of the adaptive filter strength process (section 7.14.4) for the block at Row, Col. }
function BlockFilterLevel(Frame: TFrameContext; Row, Col, Plane, Pass: Integer): Integer;
var
  Info: PBlockInfo;
  Mode, ModeType, DeltaLF: Integer;
begin
  Info := Frame.Block(Row, Col);
  Mode := Info^.YMode;
  if (Mode >= NEARESTMV) and (Mode <> GLOBALMV) and (Mode <> GLOBAL_GLOBALMV) then
    ModeType := 1
  else
    ModeType := 0;
  if not Frame.Header.delta_lf_multi then
    DeltaLF := Info^.DeltaLF[0]
  else if Plane = 0 then
    DeltaLF := Info^.DeltaLF[Pass]
  else
    DeltaLF := Info^.DeltaLF[Plane + 1];
  Result := FilterLevel(Frame, Frame.SegmentIds[Frame.MiIndex(Row, Col)], Info^.RefFrame[0], ModeType,
    DeltaLF, Plane, Pass);
end;

{ limit, blimit and thresh (section 7.14.4) for the level, scaled to the bit depth. }
procedure SetStrengths(Frame: TFrameContext; Level: Integer; var Strength: TEdgeFilterStrength);
var
  Shift, Limit, Sharpness, BitShift: Integer;
begin
  Sharpness := Frame.Header.loop_filter_sharpness;
  if Sharpness > 4 then
    Shift := 2
  else if Sharpness > 0 then
    Shift := 1
  else
    Shift := 0;
  Limit := Level shr Shift;
  if Sharpness > 0 then
  begin
    if Limit > 9 - Sharpness then
      Limit := 9 - Sharpness;
    if Limit < 1 then
      Limit := 1;
  end
  else if Limit < 1 then
    Limit := 1;
  BitShift := Strength.BitDepth - 8;
  Strength.LimitBd := Limit shl BitShift;
  Strength.BlimitBd := (2 * (Level + 2) + Limit) shl BitShift;
  Strength.ThreshBd := (Level shr 4) shl BitShift;
end;

{ The edge loop filter process (section 7.14.2). }
procedure FilterEdge(Frame: TFrameContext; PlanePicture: PPlane; Plane, Pass, Row, Col: Integer;
  var Strength: TEdgeFilterStrength);
var
  SubX, SubY, X, Y, XP, YP, PrevRow, PrevCol: Integer;
  MiSize, TxSz, PrevTxSz, PlaneSize, BaseSize, Level, I: Integer;
  Info: PBlockInfo;
  IsBlockEdge, IsTxEdge, IsIntra, ApplyFilter: Boolean;
  Step, Along, Center: Integer;
  TxSizes: PByte;
begin
  if Plane = 0 then
  begin
    SubX := 0;
    SubY := 0;
  end
  else
  begin
    SubX := Frame.Sequence.subsampling_x;
    SubY := Frame.Sequence.subsampling_y;
  end;
  X := Col * MI_SIZE;
  Y := Row * MI_SIZE;
  Row := Row or SubY;
  Col := Col or SubX;
  if (X >= Frame.Header.FrameWidth) or (Y >= Frame.Header.FrameHeight) then
    Exit;
  if (Pass = 0) and (X = 0) then
    Exit;
  if (Pass = 1) and (Y = 0) then
    Exit;
  XP := X shr SubX;
  YP := Y shr SubY;
  if Pass = 0 then
  begin
    PrevRow := Row;
    PrevCol := Col - (1 shl SubX);
  end
  else
  begin
    PrevRow := Row - (1 shl SubY);
    PrevCol := Col;
  end;
  Info := Frame.Block(Row, Col);
  MiSize := Info^.MiSize;
  TxSizes := @Frame.LoopfilterTxSizes[Plane][0];
  TxSz := TxSizes[Frame.MiIndex(Row shr SubY, Col shr SubX)];
  PlaneSize := Subsampled_Size[MiSize, SubX, SubY];
  IsIntra := Info^.RefFrame[0] <= INTRA_FRAME;
  PrevTxSz := TxSizes[Frame.MiIndex(PrevRow shr SubY, PrevCol shr SubX)];
  if Pass = 0 then
  begin
    IsBlockEdge := (XP mod Block_Width(PlaneSize)) = 0;
    IsTxEdge := (XP mod Tx_Width[TxSz]) = 0;
  end
  else
  begin
    IsBlockEdge := (YP mod Block_Height(PlaneSize)) = 0;
    IsTxEdge := (YP mod Tx_Height[TxSz]) = 0;
  end;
  if not IsTxEdge then
    ApplyFilter := False
  else
    ApplyFilter := IsBlockEdge or (not Info^.Skip) or IsIntra;
  if not ApplyFilter then
    Exit;
  { The filter size process (section 7.14.3). }
  if Pass = 0 then
  begin
    BaseSize := Tx_Width[PrevTxSz];
    if Tx_Width[TxSz] < BaseSize then
      BaseSize := Tx_Width[TxSz];
  end
  else
  begin
    BaseSize := Tx_Height[PrevTxSz];
    if Tx_Height[TxSz] < BaseSize then
      BaseSize := Tx_Height[TxSz];
  end;
  if Plane = 0 then
  begin
    if BaseSize > 16 then
      BaseSize := 16;
  end
  else if BaseSize > 8 then
    BaseSize := 8;
  Strength.FilterSize := BaseSize;
  Level := BlockFilterLevel(Frame, Row, Col, Plane, Pass);
  if Level = 0 then
    Level := BlockFilterLevel(Frame, PrevRow, PrevCol, Plane, Pass);
  if Level = 0 then
    Exit;
  SetStrengths(Frame, Level, Strength);
  if Pass = 0 then
  begin
    Step := 1;
    Along := PlanePicture^.Stride;
  end
  else
  begin
    Step := PlanePicture^.Stride;
    Along := 1;
  end;
  Center := YP * PlanePicture^.Stride + XP;
  for I := 0 to MI_SIZE - 1 do
    FilterEdgeSample(@PlanePicture^.Samples[0], Center + I * Along, Step, Strength);
end;

procedure LoopFilterRows(Frame: TFrameContext; Plane, Pass, RowStart, RowEnd: Integer);
var
  RowStep, ColStep, Row, Col: Integer;
  Strength: TEdgeFilterStrength;
  PlanePicture: PPlane;
begin
  if Plane = 0 then
  begin
    RowStep := 1;
    ColStep := 1;
  end
  else
  begin
    RowStep := 1 shl Frame.Sequence.subsampling_y;
    ColStep := 1 shl Frame.Sequence.subsampling_x;
  end;
  Strength.BitDepth := Frame.Sequence.BitDepth;
  Strength.FlatThresholdBd := 1 shl (Strength.BitDepth - 8);
  Strength.IsChroma := Plane > 0;
  PlanePicture := @Frame.CurrFrame.Planes[Plane];
  Row := RowStart;
  if (Row mod RowStep) <> 0 then
    Inc(Row, RowStep - Row mod RowStep);
  while (Row < RowEnd) and (Row < Frame.Header.MiRows) do
  begin
    Col := 0;
    while Col < Frame.Header.MiCols do
    begin
      FilterEdge(Frame, PlanePicture, Plane, Pass, Row, Col, Strength);
      Inc(Col, ColStep);
    end;
    Inc(Row, RowStep);
  end;
end;

procedure ApplyLoopFilter(Frame: TFrameContext);
var
  Plane, Pass: Integer;
begin
  for Plane := 0 to Frame.Sequence.NumPlanes - 1 do
    if (Plane = 0) or (Frame.Header.loop_filter_level[1 + Plane] <> 0) then
      for Pass := 0 to 1 do
        LoopFilterRows(Frame, Plane, Pass, 0, Frame.Header.MiRows);
end;

end.
