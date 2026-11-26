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
  What the blocks of a VP9 frame are decoded with: the frame's header
  values, segmentation, dequantizers, probabilities, references, the
  mode info grid and the segment maps (TVp9FrameState, shared by the
  tiles, read only while they decode), and where a block is
  (TVp9BlockPosition).
}
unit Vp9.FrameState;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Vp9.ModeInfo, Vp9.Pictures, Vp9.Probabilities, Vp9.InterPrediction;

type
  TVp9Segmentation = record
    Enabled: Boolean;
    UpdateMap: Boolean;
    TemporalUpdate: Boolean;
    UpdateData: Boolean;
    AbsoluteValues: Boolean;
    TreeProbabilities: array[0..6] of Byte;
    PredictionProbabilities: array[0..2] of Byte;
    FeatureEnabled: array[0..7, 0..3] of Boolean;
    FeatureData: array[0..7, 0..3] of LongInt;
  end;

  TVp9Dequantizer = record
    LumaDc, LumaAc, ChromaDc, ChromaAc: LongInt;
  end;

  TVp9Reference = record
    Picture: TVp9Picture;
    Scale: TVp9ScaleFactors;
  end;

  TVp9FrameState = record
    IntraOnly: Boolean;          { a key frame or an intra-only frame }
    Width, Height: LongInt;
    MiRows, MiColumns: LongInt;
    SubsamplingX, SubsamplingY: LongInt;
    BitDepth: LongInt;
    Lossless: Boolean;
    TransformMode: LongInt;
    Filter: LongInt;
    ReferenceMode: LongInt;
    FixedReference: LongInt;
    VariableReferences: array[0..1] of LongInt;
    SignBias: array[0..3] of Boolean;
    AllowHighPrecisionMv: Boolean;
    Segmentation: TVp9Segmentation;
    Dequantizers: array[0..7] of TVp9Dequantizer;
    Probabilities: PVp9FrameContext;
    { Count what is decoded (for backward adaptation). }
    Counting: Boolean;
    UsePreviousMvs: Boolean;
    PreviousMvs: PVp9MvReference;
    CurrentSegmentMap: PByte;
    LastSegmentMap: PByte;
    Grid: TVp9ModeInfoGrid;
    Picture: TVp9Picture;
    { By reference frame (1..3). }
    References: array[1..3] of TVp9Reference;
  end;
  PVp9FrameState = ^TVp9FrameState;

  TVp9BlockPosition = record
    MiRow, MiColumn: LongInt;
    BlockSize: LongInt;
    { The block's units inside the frame. }
    WidthUnits, HeightUnits: LongInt;
    { Distances to the frame's edges, in eighth pixels. }
    ToLeft, ToRight, ToTop, ToBottom: LongInt;
    { The tile's columns. }
    TileColumnStart, TileColumnEnd: LongInt;
    Info: PVp9ModeInfo;
    Above, Left: PVp9ModeInfo;
    { The 4x4 blocks of a block smaller than 8x8, log 2. }
    SubblockWidthLog2, SubblockHeightLog2: LongInt;
  end;

function SegmentFeatureActive(constref Segmentation: TVp9Segmentation; Segment, Feature: LongInt): Boolean; inline;

implementation

function SegmentFeatureActive(constref Segmentation: TVp9Segmentation; Segment, Feature: LongInt): Boolean; inline;
begin
  Result := Segmentation.Enabled and Segmentation.FeatureEnabled[Segment, Feature];
end;

end.
