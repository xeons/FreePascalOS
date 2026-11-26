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
  VP9's loop filter (section 8.8 of the VP9 specification): after all
  the tiles of a frame are decoded, the edges of transform blocks and
  prediction blocks are smoothed, 64x64 superblock by superblock in
  raster order, each plane's vertical edges (left to right) then its
  horizontal edges (top to bottom). Edges get a 16, 8 or 4 wide filter
  by the transform size, at a level set by segment, reference and mode,
  and none inside skipped inter blocks.

  The edge selection follows the reference decoder's general path
  (libvpx's vp9_filter_block_plane_non420), which gives the same result
  as its bit mask paths for 4:2:0 and 4:4:4.

  Superblock rows can be filtered on several threads as long as each
  row stays two superblocks behind the one above (FilterSuperblockRow
  with a progress counter).
}
unit Vp9.LoopFilter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.WorkerPool, Vp9.ModeInfo, Vp9.Pictures;

type
  TVp9FilterThresholds = record
    Limit, BlockLimit, Threshold: LongInt;
  end;

  TVp9LoopFilterFrame = record
    Picture: TVp9Picture;
    Grid: TVp9ModeInfoGrid;
    MiRows, MiColumns: LongInt;
    { Levels by segment, reference and mode group (0: ZERO and intra,
      1: the other inter modes). }
    Levels: array[0..7, 0..3, 0..1] of Byte;
    Thresholds: array[0..63] of TVp9FilterThresholds;
  end;
  PVp9LoopFilterFrame = ^TVp9LoopFilterFrame;

  TVp9LoopFilterParameters = record
    FilterLevel: LongInt;
    Sharpness: LongInt;
    DeltasEnabled: Boolean;
    ReferenceDeltas: array[0..3] of LongInt;
    ModeDeltas: array[0..1] of LongInt;
  end;

  TVp9SegmentFilterLevels = record
    Enabled: array[0..7] of Boolean;
    Values: array[0..7] of LongInt;
    AbsoluteValues: Boolean;
  end;

{ Fills the levels and thresholds of Frame for the frame's parameters. }
procedure PrepareLoopFilter(var Frame: TVp9LoopFilterFrame; constref Parameters: TVp9LoopFilterParameters;
  constref Segments: TVp9SegmentFilterLevels);

{ Filters superblock row SuperblockRow; with Progress, waits for the row
  above to be two superblocks ahead and publishes its own progress. }
procedure FilterSuperblockRow(constref Frame: TVp9LoopFilterFrame; SuperblockRow: LongInt;
  Progress: TVideoProgress);

implementation

uses
  Vp9.Tables;

const
  ModeGroups: array[0..13] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1);

function Clamp63(Value: LongInt): LongInt; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 63 then
    Result := 63
  else
    Result := Value;
end;

procedure PrepareLoopFilter(var Frame: TVp9LoopFilterFrame; constref Parameters: TVp9LoopFilterParameters;
  constref Segments: TVp9SegmentFilterLevels);
var
  Scale, Segment, Reference, Mode, SegmentLevel, Level, Interior: LongInt;
begin
  for Level := 0 to 63 do
  begin
    Interior := Level shr (Ord(Parameters.Sharpness > 0) + Ord(Parameters.Sharpness > 4));
    if Parameters.Sharpness > 0 then
      if Interior > 9 - Parameters.Sharpness then
        Interior := 9 - Parameters.Sharpness;
    if Interior < 1 then
      Interior := 1;
    Frame.Thresholds[Level].Limit := Interior;
    Frame.Thresholds[Level].BlockLimit := 2 * (Level + 2) + Interior;
    Frame.Thresholds[Level].Threshold := Level shr 4;
  end;
  Scale := 1 shl (Parameters.FilterLevel shr 5);
  for Segment := 0 to 7 do
  begin
    SegmentLevel := Parameters.FilterLevel;
    if Segments.Enabled[Segment] then
    begin
      if Segments.AbsoluteValues then
        SegmentLevel := Clamp63(Segments.Values[Segment])
      else
        SegmentLevel := Clamp63(Parameters.FilterLevel + Segments.Values[Segment]);
    end;
    if not Parameters.DeltasEnabled then
    begin
      for Reference := 0 to 3 do
        for Mode := 0 to 1 do
          Frame.Levels[Segment, Reference, Mode] := SegmentLevel;
      Continue;
    end;
    Frame.Levels[Segment, ReferenceIntra, 0] :=
      Clamp63(SegmentLevel + Parameters.ReferenceDeltas[ReferenceIntra] * Scale);
    Frame.Levels[Segment, ReferenceIntra, 1] := 0;
    for Reference := ReferenceLast to ReferenceAltRef do
      for Mode := 0 to 1 do
        Frame.Levels[Segment, Reference, Mode] := Clamp63(SegmentLevel +
          Parameters.ReferenceDeltas[Reference] * Scale + Parameters.ModeDeltas[Mode] * Scale);
  end;
end;

{ The filters, at one position across an edge: Step crosses it. }

function FilterMask(Limit, BlockLimit: LongInt; P: PWord; Step: PtrInt): Boolean; inline;
var
  P3, P2, P1, P0, Q0, Q1, Q2, Q3: LongInt;
begin
  P3 := P[-4 * Step]; P2 := P[-3 * Step]; P1 := P[-2 * Step]; P0 := P[-Step];
  Q0 := P[0]; Q1 := P[Step]; Q2 := P[2 * Step]; Q3 := P[3 * Step];
  Result := (Abs(P3 - P2) <= Limit) and (Abs(P2 - P1) <= Limit) and (Abs(P1 - P0) <= Limit) and
    (Abs(Q1 - Q0) <= Limit) and (Abs(Q2 - Q1) <= Limit) and (Abs(Q3 - Q2) <= Limit) and
    (Abs(P0 - Q0) * 2 + Abs(P1 - Q1) div 2 <= BlockLimit);
end;

function FlatMask4(Threshold: LongInt; P: PWord; Step: PtrInt): Boolean; inline;
var
  P0, Q0: LongInt;
begin
  P0 := P[-Step];
  Q0 := P[0];
  Result := (Abs(LongInt(P[-2 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[Step]) - Q0) <= Threshold) and
    (Abs(LongInt(P[-3 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[2 * Step]) - Q0) <= Threshold) and
    (Abs(LongInt(P[-4 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[3 * Step]) - Q0) <= Threshold);
end;

function FlatMask5(Threshold: LongInt; P: PWord; Step: PtrInt): Boolean; inline;
var
  P0, Q0: LongInt;
begin
  P0 := P[-Step];
  Q0 := P[0];
  Result := (Abs(LongInt(P[-5 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[4 * Step]) - Q0) <= Threshold) and
    (Abs(LongInt(P[-6 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[5 * Step]) - Q0) <= Threshold) and
    (Abs(LongInt(P[-7 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[6 * Step]) - Q0) <= Threshold) and
    (Abs(LongInt(P[-8 * Step]) - P0) <= Threshold) and (Abs(LongInt(P[7 * Step]) - Q0) <= Threshold);
end;

function SignedClamp(Value, Shift: LongInt): LongInt; inline;
var
  Low, High: LongInt;
begin
  Low := -(128 shl Shift);
  High := (128 shl Shift) - 1;
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

procedure Filter4(Threshold, Shift: LongInt; P: PWord; Step: PtrInt); inline;
var
  Offset, Ps1, Ps0, Qs0, Qs1, Filter, Filter1, Filter2: LongInt;
  HighVariance: Boolean;
begin
  Offset := $80 shl Shift;
  Ps1 := LongInt(P[-2 * Step]) - Offset;
  Ps0 := LongInt(P[-Step]) - Offset;
  Qs0 := LongInt(P[0]) - Offset;
  Qs1 := LongInt(P[Step]) - Offset;
  HighVariance := (Abs(LongInt(P[-2 * Step]) - P[-Step]) > Threshold) or
    (Abs(LongInt(P[Step]) - P[0]) > Threshold);
  if HighVariance then
    Filter := SignedClamp(Ps1 - Qs1, Shift)
  else
    Filter := 0;
  Filter := SignedClamp(Filter + 3 * (Qs0 - Ps0), Shift);
  Filter1 := SarLongint(SignedClamp(Filter + 4, Shift), 3);
  Filter2 := SarLongint(SignedClamp(Filter + 3, Shift), 3);
  P[0] := SignedClamp(Qs0 - Filter1, Shift) + Offset;
  P[-Step] := SignedClamp(Ps0 + Filter2, Shift) + Offset;
  if not HighVariance then
  begin
    Filter := SarLongint(Filter1 + 1, 1);
    P[Step] := SignedClamp(Qs1 - Filter, Shift) + Offset;
    P[-2 * Step] := SignedClamp(Ps1 + Filter, Shift) + Offset;
  end;
end;

procedure Filter8(P: PWord; Step: PtrInt); inline;
var
  P3, P2, P1, P0, Q0, Q1, Q2, Q3: LongInt;
begin
  P3 := P[-4 * Step]; P2 := P[-3 * Step]; P1 := P[-2 * Step]; P0 := P[-Step];
  Q0 := P[0]; Q1 := P[Step]; Q2 := P[2 * Step]; Q3 := P[3 * Step];
  P[-3 * Step] := (P3 + P3 + P3 + 2 * P2 + P1 + P0 + Q0 + 4) shr 3;
  P[-2 * Step] := (P3 + P3 + P2 + 2 * P1 + P0 + Q0 + Q1 + 4) shr 3;
  P[-Step] := (P3 + P2 + P1 + 2 * P0 + Q0 + Q1 + Q2 + 4) shr 3;
  P[0] := (P2 + P1 + P0 + 2 * Q0 + Q1 + Q2 + Q3 + 4) shr 3;
  P[Step] := (P1 + P0 + Q0 + 2 * Q1 + Q2 + Q3 + Q3 + 4) shr 3;
  P[2 * Step] := (P0 + Q0 + Q1 + 2 * Q2 + Q3 + Q3 + Q3 + 4) shr 3;
end;

procedure Filter16(P: PWord; Step: PtrInt); inline;
var
  P7, P6, P5, P4, P3, P2, P1, P0, Q0, Q1, Q2, Q3, Q4, Q5, Q6, Q7: LongInt;
begin
  P7 := P[-8 * Step]; P6 := P[-7 * Step]; P5 := P[-6 * Step]; P4 := P[-5 * Step];
  P3 := P[-4 * Step]; P2 := P[-3 * Step]; P1 := P[-2 * Step]; P0 := P[-Step];
  Q0 := P[0]; Q1 := P[Step]; Q2 := P[2 * Step]; Q3 := P[3 * Step];
  Q4 := P[4 * Step]; Q5 := P[5 * Step]; Q6 := P[6 * Step]; Q7 := P[7 * Step];
  P[-7 * Step] := (P7 * 7 + P6 * 2 + P5 + P4 + P3 + P2 + P1 + P0 + Q0 + 8) shr 4;
  P[-6 * Step] := (P7 * 6 + P6 + P5 * 2 + P4 + P3 + P2 + P1 + P0 + Q0 + Q1 + 8) shr 4;
  P[-5 * Step] := (P7 * 5 + P6 + P5 + P4 * 2 + P3 + P2 + P1 + P0 + Q0 + Q1 + Q2 + 8) shr 4;
  P[-4 * Step] := (P7 * 4 + P6 + P5 + P4 + P3 * 2 + P2 + P1 + P0 + Q0 + Q1 + Q2 + Q3 + 8) shr 4;
  P[-3 * Step] := (P7 * 3 + P6 + P5 + P4 + P3 + P2 * 2 + P1 + P0 + Q0 + Q1 + Q2 + Q3 + Q4 + 8) shr 4;
  P[-2 * Step] := (P7 * 2 + P6 + P5 + P4 + P3 + P2 + P1 * 2 + P0 + Q0 + Q1 + Q2 + Q3 + Q4 + Q5 + 8) shr 4;
  P[-Step] := (P7 + P6 + P5 + P4 + P3 + P2 + P1 + P0 * 2 + Q0 + Q1 + Q2 + Q3 + Q4 + Q5 + Q6 + 8) shr 4;
  P[0] := (P6 + P5 + P4 + P3 + P2 + P1 + P0 + Q0 * 2 + Q1 + Q2 + Q3 + Q4 + Q5 + Q6 + Q7 + 8) shr 4;
  P[Step] := (P5 + P4 + P3 + P2 + P1 + P0 + Q0 + Q1 * 2 + Q2 + Q3 + Q4 + Q5 + Q6 + Q7 * 2 + 8) shr 4;
  P[2 * Step] := (P4 + P3 + P2 + P1 + P0 + Q0 + Q1 + Q2 * 2 + Q3 + Q4 + Q5 + Q6 + Q7 * 3 + 8) shr 4;
  P[3 * Step] := (P3 + P2 + P1 + P0 + Q0 + Q1 + Q2 + Q3 * 2 + Q4 + Q5 + Q6 + Q7 * 4 + 8) shr 4;
  P[4 * Step] := (P2 + P1 + P0 + Q0 + Q1 + Q2 + Q3 + Q4 * 2 + Q5 + Q6 + Q7 * 5 + 8) shr 4;
  P[5 * Step] := (P1 + P0 + Q0 + Q1 + Q2 + Q3 + Q4 + Q5 * 2 + Q6 + Q7 * 6 + 8) shr 4;
  P[6 * Step] := (P0 + Q0 + Q1 + Q2 + Q3 + Q4 + Q5 + Q6 * 2 + Q7 * 7 + 8) shr 4;
end;

type
  TEdgeWidth = (Edge4, Edge8, Edge16);

{ Filters Count positions along an edge: Step crosses it, Along moves
  along it. }
procedure FilterEdge(P: PWord; Step, Along: PtrInt; Count: LongInt; Width: TEdgeWidth;
  constref Thresholds: TVp9FilterThresholds; BitDepth: LongInt);
var
  Index, Shift, Limit, BlockLimit, Threshold, Flat: LongInt;
begin
  Shift := BitDepth - 8;
  Limit := Thresholds.Limit shl Shift;
  BlockLimit := Thresholds.BlockLimit shl Shift;
  Threshold := Thresholds.Threshold shl Shift;
  Flat := 1 shl Shift;
  for Index := 0 to Count - 1 do
  begin
    if FilterMask(Limit, BlockLimit, P, Step) then
    begin
      case Width of
        Edge4:
          Filter4(Threshold, Shift, P, Step);
        Edge8:
          if FlatMask4(Flat, P, Step) then
            Filter8(P, Step)
          else
            Filter4(Threshold, Shift, P, Step);
        Edge16:
          if FlatMask4(Flat, P, Step) then
          begin
            if FlatMask5(Flat, P, Step) then
              Filter16(P, Step)
            else
              Filter8(P, Step);
          end
          else
            Filter4(Threshold, Shift, P, Step);
      end;
    end;
    Inc(P, Along);
  end;
end;

procedure FilterVerticalRow(S: PWord; Pitch: PtrInt; Mask16, Mask8, Mask4, Mask4Internal: LongWord;
  constref Frame: TVp9LoopFilterFrame; Levels: PByte; BitDepth: LongInt);
var
  Mask: LongWord;
begin
  Mask := Mask16 or Mask8 or Mask4 or Mask4Internal;
  while Mask <> 0 do
  begin
    if (Mask and 1) <> 0 then
    begin
      if (Mask16 and 1) <> 0 then
        FilterEdge(S, 1, Pitch, 8, Edge16, Frame.Thresholds[Levels^], BitDepth)
      else if (Mask8 and 1) <> 0 then
        FilterEdge(S, 1, Pitch, 8, Edge8, Frame.Thresholds[Levels^], BitDepth)
      else if (Mask4 and 1) <> 0 then
        FilterEdge(S, 1, Pitch, 8, Edge4, Frame.Thresholds[Levels^], BitDepth);
    end;
    if (Mask4Internal and 1) <> 0 then
      FilterEdge(S + 4, 1, Pitch, 8, Edge4, Frame.Thresholds[Levels^], BitDepth);
    Inc(S, 8);
    Inc(Levels);
    Mask16 := Mask16 shr 1;
    Mask8 := Mask8 shr 1;
    Mask4 := Mask4 shr 1;
    Mask4Internal := Mask4Internal shr 1;
    Mask := Mask shr 1;
  end;
end;

procedure FilterHorizontalRow(S: PWord; Pitch: PtrInt; Mask16, Mask8, Mask4, Mask4Internal: LongWord;
  constref Frame: TVp9LoopFilterFrame; Levels: PByte; BitDepth: LongInt);
var
  Mask: LongWord;
  Count: LongInt;
  Current, Next: LongInt;
begin
  Mask := Mask16 or Mask8 or Mask4 or Mask4Internal;
  while Mask <> 0 do
  begin
    Count := 1;
    if (Mask and 1) <> 0 then
    begin
      Current := Levels[0];
      Next := Levels[1];
      if (Mask16 and 1) <> 0 then
      begin
        { Two at a time with the first one's level, as the reference
          decoder does. }
        if (Mask16 and 3) = 3 then
        begin
          FilterEdge(S, Pitch, 1, 16, Edge16, Frame.Thresholds[Current], BitDepth);
          Count := 2;
        end
        else
          FilterEdge(S, Pitch, 1, 8, Edge16, Frame.Thresholds[Current], BitDepth);
      end
      else if (Mask8 and 1) <> 0 then
      begin
        if (Mask8 and 3) = 3 then
        begin
          FilterEdge(S, Pitch, 1, 8, Edge8, Frame.Thresholds[Current], BitDepth);
          FilterEdge(S + 8, Pitch, 1, 8, Edge8, Frame.Thresholds[Next], BitDepth);
          if (Mask4Internal and 3) = 3 then
          begin
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
            FilterEdge(S + 4 * Pitch + 8, Pitch, 1, 8, Edge4, Frame.Thresholds[Next], BitDepth);
          end
          else if (Mask4Internal and 1) <> 0 then
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth)
          else if (Mask4Internal and 2) <> 0 then
            FilterEdge(S + 8 + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Next], BitDepth);
          Count := 2;
        end
        else
        begin
          FilterEdge(S, Pitch, 1, 8, Edge8, Frame.Thresholds[Current], BitDepth);
          if (Mask4Internal and 1) <> 0 then
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
        end;
      end
      else if (Mask4 and 1) <> 0 then
      begin
        if (Mask4 and 3) = 3 then
        begin
          FilterEdge(S, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
          FilterEdge(S + 8, Pitch, 1, 8, Edge4, Frame.Thresholds[Next], BitDepth);
          if (Mask4Internal and 3) = 3 then
          begin
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
            FilterEdge(S + 4 * Pitch + 8, Pitch, 1, 8, Edge4, Frame.Thresholds[Next], BitDepth);
          end
          else if (Mask4Internal and 1) <> 0 then
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth)
          else if (Mask4Internal and 2) <> 0 then
            FilterEdge(S + 8 + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Next], BitDepth);
          Count := 2;
        end
        else
        begin
          FilterEdge(S, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
          if (Mask4Internal and 1) <> 0 then
            FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
        end;
      end
      else
        FilterEdge(S + 4 * Pitch, Pitch, 1, 8, Edge4, Frame.Thresholds[Current], BitDepth);
    end;
    Inc(S, 8 * Count);
    Inc(Levels, Count);
    Mask16 := Mask16 shr Count;
    Mask8 := Mask8 shr Count;
    Mask4 := Mask4 shr Count;
    Mask4Internal := Mask4Internal shr Count;
    Mask := Mask shr Count;
  end;
end;

function GetLevel(constref Frame: TVp9LoopFilterFrame; Info: PVp9ModeInfo): LongInt; inline;
begin
  Result := Frame.Levels[Info^.Segment, Info^.Reference[0], ModeGroups[Info^.Mode]];
end;

procedure FilterBlockPlane(constref Frame: TVp9LoopFilterFrame; PlaneIndex, MiRow, MiColumn: LongInt);
var
  Plane: PVp9Plane;
  SubsamplingX, SubsamplingY, RowStep, ColumnStep, Row, Column: LongInt;
  Mask16, Mask8, Mask4, Mask4Internal: array[0..7] of LongWord;
  Mask16Column, Mask8Column, Mask4Column, BorderMask, Bit: LongWord;
  Levels: array[0..63] of Byte;
  Info: PVp9ModeInfo;
  BlockSize, TransformSize, Level: LongInt;
  SkipThis, SkipThisColumn, SkipThisRow, EdgeLeft, EdgeAbove, SkipBorderColumn, SkipBorderRow: Boolean;
  Destination: PWord;
  Pitch: PtrInt;
  Mask16Row, Mask8Row, Mask4Row, Mask4InternalRow: LongWord;
begin
  Plane := @Frame.Picture.Planes[PlaneIndex];
  if PlaneIndex = 0 then
  begin
    SubsamplingX := 0;
    SubsamplingY := 0;
  end
  else
  begin
    SubsamplingX := Frame.Picture.SubsamplingX;
    SubsamplingY := Frame.Picture.SubsamplingY;
  end;
  RowStep := 1 shl SubsamplingY;
  ColumnStep := 1 shl SubsamplingX;
  Pitch := Plane^.Stride;
  Destination := Plane^.Origin + PtrInt((MiRow * 8) shr SubsamplingY) * Pitch + ((MiColumn * 8) shr SubsamplingX);
  FillChar(Mask16, SizeOf(Mask16), 0);
  FillChar(Mask8, SizeOf(Mask8), 0);
  FillChar(Mask4, SizeOf(Mask4), 0);
  FillChar(Mask4Internal, SizeOf(Mask4Internal), 0);
  FillChar(Levels, SizeOf(Levels), 0);
  Row := 0;
  while (Row < 8) and (MiRow + Row < Frame.MiRows) do
  begin
    Mask16Column := 0;
    Mask8Column := 0;
    Mask4Column := 0;
    Column := 0;
    while (Column < 8) and (MiColumn + Column < Frame.MiColumns) do
    begin
      Info := Frame.Grid.Cells[(MiRow + Row) * Frame.Grid.Columns + MiColumn + Column];
      BlockSize := Info^.BlockSize;
      SkipThis := Info^.Skip and IsInter(Info);
      if BlockWidth4x4[BlockSize] > 1 then
        EdgeLeft := (Column and (BlockWidth8x8[BlockSize] - 1)) = 0
      else
        EdgeLeft := True;
      SkipThisColumn := SkipThis and not EdgeLeft;
      if BlockHeight4x4[BlockSize] > 1 then
        EdgeAbove := (Row and (BlockHeight8x8[BlockSize] - 1)) = 0
      else
        EdgeAbove := True;
      SkipThisRow := SkipThis and not EdgeAbove;
      if PlaneIndex = 0 then
        TransformSize := Info^.TransformSize
      else
        TransformSize := ChromaTransformSizes[BlockSize, Info^.TransformSize, SubsamplingX, SubsamplingY];
      SkipBorderColumn := (SubsamplingX <> 0) and (MiColumn + Column = Frame.MiColumns - 1);
      SkipBorderRow := (SubsamplingY <> 0) and (MiRow + Row = Frame.MiRows - 1);
      Level := GetLevel(Frame, Info);
      Levels[(Row shl 3) + (Column shr SubsamplingX)] := Level;
      if Level <> 0 then
      begin
        Bit := LongWord(1) shl (Column shr SubsamplingX);
        if TransformSize = Transform32x32 then
        begin
          if (not SkipThisColumn) and (((Column shr SubsamplingX) and 3) = 0) then
          begin
            if not SkipBorderColumn then
              Mask16Column := Mask16Column or Bit
            else
              Mask8Column := Mask8Column or Bit;
          end;
          if (not SkipThisRow) and (((Row shr SubsamplingY) and 3) = 0) then
          begin
            if not SkipBorderRow then
              Mask16[Row] := Mask16[Row] or Bit
            else
              Mask8[Row] := Mask8[Row] or Bit;
          end;
        end
        else if TransformSize = Transform16x16 then
        begin
          if (not SkipThisColumn) and (((Column shr SubsamplingX) and 1) = 0) then
          begin
            if not SkipBorderColumn then
              Mask16Column := Mask16Column or Bit
            else
              Mask8Column := Mask8Column or Bit;
          end;
          if (not SkipThisRow) and (((Row shr SubsamplingY) and 1) = 0) then
          begin
            if not SkipBorderRow then
              Mask16[Row] := Mask16[Row] or Bit
            else
              Mask8[Row] := Mask8[Row] or Bit;
          end;
        end
        else
        begin
          if not SkipThisColumn then
          begin
            if (TransformSize = Transform8x8) or (((Column shr SubsamplingX) and 3) = 0) then
              Mask8Column := Mask8Column or Bit
            else
              Mask4Column := Mask4Column or Bit;
          end;
          if not SkipThisRow then
          begin
            if (TransformSize = Transform8x8) or (((Row shr SubsamplingY) and 3) = 0) then
              Mask8[Row] := Mask8[Row] or Bit
            else
              Mask4[Row] := Mask4[Row] or Bit;
          end;
          if (not SkipThis) and (TransformSize < Transform8x8) and (not SkipBorderColumn) then
            Mask4Internal[Row] := Mask4Internal[Row] or Bit;
        end;
      end;
      Inc(Column, ColumnStep);
    end;
    if MiColumn = 0 then
      BorderMask := $FFFFFFFE
    else
      BorderMask := $FFFFFFFF;
    FilterVerticalRow(Destination + PtrInt((Row shr SubsamplingY) * 8) * Pitch, Pitch,
      Mask16Column and BorderMask, Mask8Column and BorderMask, Mask4Column and BorderMask,
      Mask4Internal[Row], Frame, @Levels[Row shl 3], Frame.Picture.BitDepth);
    Inc(Row, RowStep);
  end;
  Row := 0;
  while (Row < 8) and (MiRow + Row < Frame.MiRows) do
  begin
    SkipBorderRow := (SubsamplingY <> 0) and (MiRow + Row = Frame.MiRows - 1);
    if SkipBorderRow then
      Mask4InternalRow := 0
    else
      Mask4InternalRow := Mask4Internal[Row];
    if MiRow + Row = 0 then
    begin
      Mask16Row := 0;
      Mask8Row := 0;
      Mask4Row := 0;
    end
    else
    begin
      Mask16Row := Mask16[Row];
      Mask8Row := Mask8[Row];
      Mask4Row := Mask4[Row];
    end;
    FilterHorizontalRow(Destination + PtrInt((Row shr SubsamplingY) * 8) * Pitch, Pitch, Mask16Row, Mask8Row,
      Mask4Row, Mask4InternalRow, Frame, @Levels[Row shl 3], Frame.Picture.BitDepth);
    Inc(Row, RowStep);
  end;
end;

procedure FilterSuperblockRow(constref Frame: TVp9LoopFilterFrame; SuperblockRow: LongInt;
  Progress: TVideoProgress);
var
  MiRow, MiColumn, SuperblockColumn, Plane, Columns: LongInt;
begin
  MiRow := SuperblockRow * 8;
  Columns := (Frame.MiColumns + 7) div 8;
  for SuperblockColumn := 0 to Columns - 1 do
  begin
    if (Progress <> nil) and (SuperblockRow > 0) then
    begin
      if SuperblockColumn + 2 < Columns then
        Progress.WaitFor(SuperblockRow - 1, SuperblockColumn + 2)
      else
        Progress.WaitFor(SuperblockRow - 1, Columns);
    end;
    MiColumn := SuperblockColumn * 8;
    for Plane := 0 to 2 do
      FilterBlockPlane(Frame, Plane, MiRow, MiColumn);
    if Progress <> nil then
      Progress.Publish(SuperblockRow, SuperblockColumn + 1);
  end;
end;

end.
