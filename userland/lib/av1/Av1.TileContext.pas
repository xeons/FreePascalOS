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
  The state of one tile being decoded: its symbol decoder and CDFs, the
  above and left contexts, and the variables the specification keeps
  for the block being decoded (MiRow, MiCol, MiSize, YMode, RefFrame,
  Mv, ...), with the specification's names. Each tile (each thread that
  decodes tiles) has its own TTileContext; they share the frame's
  TFrameContext.

  The parts that belong to the prediction, motion vector prediction and
  reconstruction processes are in the included files named after them.
}
unit Av1.TileContext;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.Tables, Av1.CdfContext, Av1.SymbolDecoder, Av1.FrameHeader,
  Av1.SequenceHeader, Av1.References, Av1.FrameContext, Av1.Picture;

const
  { Above contexts span the frame: MiCols plus a superblock of room. }
  MaxSuperblockMi = 32;

type
  TIntraFrameYModeCdf = array[0..INTRA_MODE_CONTEXTS - 1, 0..INTRA_MODE_CONTEXTS - 1, 0..INTRA_MODES] of Word;
  TPaletteColors = array[0..PALETTE_COLORS - 1] of Integer;
  { BlockDecoded[ plane ][ -1..32 ][ -1..32 ], stored from index 0. }
  TBlockDecodedFlags = array[0..2, 0..MaxSuperblockMi + 1, 0..MaxSuperblockMi + 1] of Boolean;
  { ColorMapY / ColorMapUV: up to 64 by 64 (chroma blocks under 4 wide get 2 more). }
  TColorMap = array[0..63, 0..67] of Byte;

  TTileContext = class
  public
    Frame: TFrameContext;
    Sequence: ^TSequenceHeader;
    Header: ^TFrameHeader;
    Symbols: TSymbolDecoder;
    Cdf: TCdfContext;                        { the Tile...Cdf arrays }
    IntraFrameYModeCdf: TIntraFrameYModeCdf; { TileIntraFrameYModeCdf }

    TileNum: Integer;
    MiRowStart, MiRowEnd, MiColStart, MiColEnd: Integer;
    CurrentQIndex: Integer;
    ReadDeltas: Boolean;
    DeltaLF: array[0..FRAME_LF_COUNT - 1] of Integer;
    RefSgrXqd: array[0..2, 0..1] of Integer;
    RefLrWiener: array[0..2, 0..1, 0..2] of Integer;

    { Above contexts indexed by 4x4 column of the plane (frame-wide), left
      contexts by 4x4 row of the plane (frame-wide). }
    AboveLevelContext, AboveDcContext: array[0..2] of array of Integer;
    LeftLevelContext, LeftDcContext: array[0..2] of array of Integer;
    AboveSegPredContext, LeftSegPredContext: array of Integer;

    BlockDecodedFlags: TBlockDecodedFlags;

    { The block being decoded. }
    MiRow, MiCol, MiSize: Integer;
    HasChroma: Boolean;
    AvailU, AvailL, AvailUChroma, AvailLChroma: Boolean;
    skip, skip_mode: Boolean;
    segment_id: Integer;
    Lossless: Boolean;
    is_inter: Boolean;
    use_intrabc: Boolean;
    YMode, UVMode: Integer;
    AngleDeltaY, AngleDeltaUV: Integer;
    CflAlphaU, CflAlphaV: Integer;
    use_filter_intra: Boolean;
    filter_intra_mode: Integer;
    PaletteSizeY, PaletteSizeUV: Integer;
    palette_colors_y, palette_colors_u, palette_colors_v: TPaletteColors;
    ColorMapY, ColorMapUV: TColorMap;
    RefFrame: array[0..1] of Integer;
    Mv: array[0..1] of TMotionVector;
    PredMv: array[0..1] of TMotionVector;
    RefMvIdx: Integer;
    interintra: Boolean;
    interintra_mode: Integer;
    wedge_interintra: Boolean;
    wedge_index: Integer;
    wedge_sign: Integer;
    mask_type: Integer;
    motion_mode: Integer;
    compound_type: Integer;
    comp_group_idx: Integer;
    compound_idx: Integer;
    interp_filter: array[0..1] of Integer;
    TxSize: Integer;
    MaxLumaW, MaxLumaH: Integer;
    LeftRefFrame, AboveRefFrame: array[0..1] of Integer;
    LeftIntra, AboveIntra, LeftSingle, AboveSingle: Boolean;
    IsInterIntra: Boolean;

    { Set by the motion vector prediction processes (Av1.MvPrediction). }
    NumMvFound, NewMvCount: Integer;
    RefStackMv: array[0..MAX_REF_MV_STACK_SIZE, 0..1] of TMotionVector;
    WeightStack: array[0..MAX_REF_MV_STACK_SIZE] of Integer;
    GlobalMvs: array[0..1] of TMotionVector;
    NewMvContext, RefMvContext, ZeroMvContext: Integer;
    DrlCtxStack: array[0..MAX_REF_MV_STACK_SIZE] of Integer;
    NumSamples, NumSamplesScanned: Integer;
    CandList: array[0..LEAST_SQUARES_SAMPLES_MAX - 1, 0..3] of Integer;

    { Coefficients of the transform block being decoded. }
    Quant: array[0..1023] of Integer;
    PlaneTxType: Integer;

{$I Av1.TileContext.MvPrediction.inc}
{$I Av1.TileContext.Intra.inc}
{$I Av1.TileContext.Inter.inc}
{$I Av1.TileContext.Reconstruction.inc}

    constructor Create(AFrame: TFrameContext);
    { BlockDecoded[ plane ][ y ][ x ] for y, x from -1. }
    function BlockDecoded(Plane, Y, X: Integer): Boolean; inline;
    procedure SetBlockDecoded(Plane, Y, X: Integer; Value: Boolean); inline;
    function SegmentFeatureActive(Feature: Integer): Boolean; inline;
    { get_qindex( ignoreDeltaQ, segmentId ) (section 7.12.2). }
    function GetQIndex(IgnoreDeltaQ: Boolean; SegmentId: Integer): Integer;
    function IsInside(CandidateRow, CandidateCol: Integer): Boolean; inline;
    function GetPlaneResidualSize(SubSize, Plane: Integer): Integer; inline;
    function SubsamplingX(Plane: Integer): Integer; inline;
    function SubsamplingY(Plane: Integer): Integer; inline;
  end;

implementation

constructor TTileContext.Create(AFrame: TFrameContext);
var
  Plane, Columns, Rows: Integer;
begin
  inherited Create;
  Frame := AFrame;
  Sequence := @Frame.Sequence;
  Header := @Frame.Header;
  Columns := Frame.MiStride;
  Rows := Frame.MiRowsAllocated;
  for Plane := 0 to 2 do
  begin
    SetLength(AboveLevelContext[Plane], Columns);
    SetLength(AboveDcContext[Plane], Columns);
    SetLength(LeftLevelContext[Plane], Rows);
    SetLength(LeftDcContext[Plane], Rows);
  end;
  SetLength(AboveSegPredContext, Columns);
  SetLength(LeftSegPredContext, Rows);
end;

function TTileContext.BlockDecoded(Plane, Y, X: Integer): Boolean;
begin
  Result := BlockDecodedFlags[Plane, Y + 1, X + 1];
end;

procedure TTileContext.SetBlockDecoded(Plane, Y, X: Integer; Value: Boolean);
begin
  BlockDecodedFlags[Plane, Y + 1, X + 1] := Value;
end;

function TTileContext.SegmentFeatureActive(Feature: Integer): Boolean;
begin
  Result := Frame.SegmentFeatureActiveIndex(segment_id, Feature);
end;

function TTileContext.GetQIndex(IgnoreDeltaQ: Boolean; SegmentId: Integer): Integer;
var
  Data, QIndex: Integer;
begin
  if Frame.SegmentFeatureActiveIndex(SegmentId, SEG_LVL_ALT_Q) then
  begin
    Data := Header^.Segmentation.FeatureData[SegmentId, SEG_LVL_ALT_Q];
    QIndex := Header^.base_q_idx + Data;
    if (not IgnoreDeltaQ) and Header^.delta_q_present then
      QIndex := CurrentQIndex + Data;
    if QIndex < 0 then
      QIndex := 0
    else if QIndex > 255 then
      QIndex := 255;
    Result := QIndex;
  end
  else if (not IgnoreDeltaQ) and Header^.delta_q_present then
    Result := CurrentQIndex
  else
    Result := Header^.base_q_idx;
end;

function TTileContext.IsInside(CandidateRow, CandidateCol: Integer): Boolean;
begin
  Result := (CandidateCol >= MiColStart) and (CandidateCol < MiColEnd) and
    (CandidateRow >= MiRowStart) and (CandidateRow < MiRowEnd);
end;

function TTileContext.GetPlaneResidualSize(SubSize, Plane: Integer): Integer;
begin
  Result := Subsampled_Size[SubSize, SubsamplingX(Plane), SubsamplingY(Plane)];
end;

function TTileContext.SubsamplingX(Plane: Integer): Integer;
begin
  if Plane > 0 then
    Result := Sequence^.subsampling_x
  else
    Result := 0;
end;

function TTileContext.SubsamplingY(Plane: Integer): Integer;
begin
  if Plane > 0 then
    Result := Sequence^.subsampling_y
  else
    Result := 0;
end;

end.
