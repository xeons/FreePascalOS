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
  The state of the frame being decoded: its headers, its pictures, and
  the specification's frame-wide arrays (what decode_block stores for
  every 4x4 block: YModes, RefFrames, Mvs, MiSizes, ...; the
  segmentation maps; the motion field; CDEF and loop restoration
  choices).

  The arrays are indexed by mode info position (rows and columns of
  4x4 luma blocks) with MiStride entries per row; they reach past
  MiRows and MiCols to the next 128-sample boundary (and one more
  superblock), because the specification stores whole blocks, including
  the parts outside the frame. Tiles write disjoint parts of them.
}
unit Av1.FrameContext;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.CdfContext, Av1.SequenceHeader, Av1.FrameHeader, Av1.Picture,
  Av1.References;

type
  { What decode_block stores for each 4x4 block (the arrays YModes,
    UVModes, RefFrames, Mvs, ... of the specification). }
  TBlockInfo = record
    RefFrame: array[0..1] of ShortInt;       { RefFrames }
    Mv: array[0..1] of TMotionVector;        { Mvs }
    YMode: Byte;                             { YModes (an inter mode for inter blocks) }
    UVMode: Byte;                            { UVModes }
    MiSize: Byte;                            { MiSizes }
    TxSize: Byte;                            { TxSizes }
    InterTxSize: Byte;                       { InterTxSizes }
    TxType: Byte;                            { TxTypes (luma) }
    Skip: Boolean;                           { Skips }
    SkipMode: Boolean;                       { SkipModes }
    IsInter: Boolean;                        { IsInters }
    CompGroupIdx: Byte;                      { CompGroupIdxs }
    CompoundIdx: Byte;                       { CompoundIdxs }
    InterpFilter: array[0..1] of Byte;       { InterpFilters }
    PaletteSize: array[0..1] of Byte;        { PaletteSizes }
    DeltaLF: array[0..FRAME_LF_COUNT - 1] of ShortInt;   { DeltaLFs }
  end;
  PBlockInfo = ^TBlockInfo;

  { One loop restoration unit's parameters (LrType, LrWiener, LrSgrSet,
    LrSgrXqd of the specification). }
  TRestorationUnit = record
    RestorationType: Integer;
    Wiener: array[0..1, 0..2] of Integer;    { [ pass ][ coefficient ] }
    SgrSet: Integer;
    SgrXqd: array[0..1] of Integer;
  end;
  PRestorationUnit = ^TRestorationUnit;

  { A motion vector of the motion field; Row = InvalidMotionVector marks none. }
const
  InvalidMotionVector = -32768;

type
  TFrameContext = class
  public
    Sequence: TSequenceHeader;
    Header: TFrameHeader;
    { The reference frames by RefFrame value (LAST_FRAME..ALTREF_FRAME);
      [ INTRA_FRAME ] is nil. }
    ReferenceFrames: array[0..TOTAL_REFS_PER_FRAME - 1] of TReferenceFrame;
    { CurrFrame: prediction and reconstruction write here. }
    CurrFrame: TPicture;
    { The frame's CDFs at its start, and the ones saved from the tile
      context_update_tile_id (Saved...Cdf). }
    Cdfs: TCdfContext;
    SavedCdfs: TCdfContext;

    MiStride: Integer;                       { entries per row of the mode info arrays }
    MiRowsAllocated: Integer;
    Blocks: array of TBlockInfo;
    SegmentIds: array of Byte;
    PrevSegmentIds: array of Byte;
    PaletteColors: array of Word;            { 16 per block: [ plane * 8 + index ] }
    { LoopfilterTxSizes[ plane ]: by 4x4 unit of the plane, MiStride per row. }
    LoopfilterTxSizes: array[0..2] of array of Byte;
    { cdef_idx, kept at each 4x4 block (meaningful at the top left of 64x64 units). }
    CdefIdx: array of ShortInt;
    { The motion field motion vector storage (section 7.19). }
    MfRefFrames: array of ShortInt;
    MfMvs: array of TMotionVector;
    { MotionFieldMvs[ ref ][ row >> 1 ][ col >> 1 ] of the motion field estimation;
      MotionFieldStride entries per row. }
    MotionFieldMvs: array[0..TOTAL_REFS_PER_FRAME - 1] of array of TMotionVector;
    MotionFieldStride: Integer;
    { Loop restoration units by plane: LrUnitRows[ plane ] by LrUnitCols[ plane ]. }
    LrUnits: array[0..2] of array of TRestorationUnit;
    LrUnitRows, LrUnitCols: array[0..2] of Integer;

{$I Av1.FrameContext.PostFilter.inc}

    destructor Destroy; override;
    { The arrays sized for the header's MiRows and MiCols, and a new CurrFrame. }
    procedure Allocate;
    function MiIndex(Row, Col: Integer): Integer; inline;
    function Block(Row, Col: Integer): PBlockInfo; inline;
    function SegmentFeatureActiveIndex(SegmentId, Feature: Integer): Boolean; inline;
    function GetRelativeDist(A, B: Integer): Integer;
    procedure ReleaseReferences;
  end;

implementation

destructor TFrameContext.Destroy;
begin
  ReleaseReferences;
  CurrFrame.Free;
  FreePostFilterPictures;
  inherited Destroy;
end;

procedure TFrameContext.ReleaseReferences;
var
  Index: Integer;
begin
  for Index := 0 to TOTAL_REFS_PER_FRAME - 1 do
  begin
    if ReferenceFrames[Index] <> nil then
      ReferenceFrames[Index].Release;
    ReferenceFrames[Index] := nil;
  end;
end;

procedure TFrameContext.Allocate;
var
  Count, Plane, Index, SuperblockMi: Integer;
begin
  SuperblockMi := 32;
  MiStride := AlignUp(Header.MiCols, SuperblockMi) + SuperblockMi;
  MiRowsAllocated := AlignUp(Header.MiRows, SuperblockMi) + SuperblockMi;
  Count := MiStride * MiRowsAllocated;
  Blocks := nil;
  SetLength(Blocks, Count);
  SegmentIds := nil;
  SetLength(SegmentIds, Count);
  if Length(PrevSegmentIds) <> Count then
  begin
    PrevSegmentIds := nil;
    SetLength(PrevSegmentIds, Count);
  end;
  PaletteColors := nil;
  SetLength(PaletteColors, Count * 16);
  for Plane := 0 to 2 do
  begin
    LoopfilterTxSizes[Plane] := nil;
    SetLength(LoopfilterTxSizes[Plane], Count);
  end;
  CdefIdx := nil;
  SetLength(CdefIdx, Count);
  MfRefFrames := nil;
  SetLength(MfRefFrames, Count);
  MfMvs := nil;
  SetLength(MfMvs, Count);
  MotionFieldStride := MiStride shr 1;
  for Index := 0 to TOTAL_REFS_PER_FRAME - 1 do
  begin
    MotionFieldMvs[Index] := nil;
    SetLength(MotionFieldMvs[Index], MotionFieldStride * (MiRowsAllocated shr 1));
  end;
  CurrFrame.Free;
  CurrFrame := TPicture.Create(Header.FrameWidth, Header.FrameHeight, Sequence.subsampling_x,
    Sequence.subsampling_y, Sequence.NumPlanes, Sequence.BitDepth, 256);
end;

function TFrameContext.MiIndex(Row, Col: Integer): Integer;
begin
  Result := Row * MiStride + Col;
end;

function TFrameContext.Block(Row, Col: Integer): PBlockInfo;
begin
  Result := @Blocks[Row * MiStride + Col];
end;

function TFrameContext.SegmentFeatureActiveIndex(SegmentId, Feature: Integer): Boolean;
begin
  Result := Header.segmentation_enabled and Header.Segmentation.FeatureEnabled[SegmentId, Feature];
end;

function TFrameContext.GetRelativeDist(A, B: Integer): Integer;
var
  Difference, M: Integer;
begin
  if not Sequence.enable_order_hint then
    Exit(0);
  Difference := A - B;
  M := 1 shl (Sequence.OrderHintBits - 1);
  Result := (Difference and (M - 1)) - (Difference and M);
end;

{$I Av1.FrameContext.PostFilterCode.inc}

end.
