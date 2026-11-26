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
  VP9 block modes (section 9.3 of the VP9 specification; libvpx's
  vp9_decodemv.c): a block's segment, skip flag, transform size, and
  either its intra modes or its references, inter mode, interpolation
  filter and motion vectors, each with probabilities chosen by the
  blocks above and to the left.

  Motion vectors are predicted from up to 8 neighbouring positions
  (inside the tile), then the previous frame's vector at the block,
  then neighbours using other references (sign corrected).
}
unit Vp9.Modes;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Video.BoolDecoder, Vp9.ModeInfo, Vp9.Probabilities, Vp9.FrameState;

type
  EVp9ModeError = class(Exception);

{ Reads the mode info of the block at Position (whose Info record has
  its BlockSize set); Counts is nil when nothing is counted. }
procedure ReadModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  var Position: TVp9BlockPosition; Counts: PVp9Counts);

implementation

uses
  Vp9.Tables;

type
  TPosition = record
    Row, Col: LongInt;
  end;

const
  MvBorder = 16 shl 3;
  MvLow = -(1 shl 14);
  MvHigh = 1 shl 14;
  CompandedMvReferenceThreshold = 8;

  ModeToCounter: array[0..13] of Byte = (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 0, 0, 3, 1);
  CounterToContext: array[0..18] of Byte = (2, 3, 4, 1, 3, 9, 0, 9, 9, 5, 5, 9, 5, 9, 9, 9, 9, 9, 6);

  ReferenceBlocks: array[0..12, 0..7] of TPosition = (
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: -1), (Row: -2; Col: 0),
     (Row: 0; Col: -2), (Row: -2; Col: -1), (Row: -1; Col: -2), (Row: -2; Col: -2)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: -1), (Row: -2; Col: 0),
     (Row: 0; Col: -2), (Row: -2; Col: -1), (Row: -1; Col: -2), (Row: -2; Col: -2)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: -1), (Row: -2; Col: 0),
     (Row: 0; Col: -2), (Row: -2; Col: -1), (Row: -1; Col: -2), (Row: -2; Col: -2)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: -1), (Row: -2; Col: 0),
     (Row: 0; Col: -2), (Row: -2; Col: -1), (Row: -1; Col: -2), (Row: -2; Col: -2)),
    ((Row: 0; Col: -1), (Row: -1; Col: 0), (Row: 1; Col: -1), (Row: -1; Col: -1),
     (Row: 0; Col: -2), (Row: -2; Col: 0), (Row: -2; Col: -1), (Row: -1; Col: -2)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: 1), (Row: -1; Col: -1),
     (Row: -2; Col: 0), (Row: 0; Col: -2), (Row: -1; Col: -2), (Row: -2; Col: -1)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: 1), (Row: 1; Col: -1),
     (Row: -1; Col: -1), (Row: -3; Col: 0), (Row: 0; Col: -3), (Row: -3; Col: -3)),
    ((Row: 0; Col: -1), (Row: -1; Col: 0), (Row: 2; Col: -1), (Row: -1; Col: -1),
     (Row: -1; Col: 1), (Row: 0; Col: -3), (Row: -3; Col: 0), (Row: -3; Col: -3)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: 2), (Row: -1; Col: -1),
     (Row: 1; Col: -1), (Row: -3; Col: 0), (Row: 0; Col: -3), (Row: -3; Col: -3)),
    ((Row: -1; Col: 1), (Row: 1; Col: -1), (Row: -1; Col: 2), (Row: 2; Col: -1),
     (Row: -1; Col: -1), (Row: -3; Col: 0), (Row: 0; Col: -3), (Row: -3; Col: -3)),
    ((Row: 0; Col: -1), (Row: -1; Col: 0), (Row: 4; Col: -1), (Row: -1; Col: 2),
     (Row: -1; Col: -1), (Row: 0; Col: -3), (Row: -3; Col: 0), (Row: 2; Col: -1)),
    ((Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: 4), (Row: 2; Col: -1),
     (Row: -1; Col: -1), (Row: -3; Col: 0), (Row: 0; Col: -3), (Row: -1; Col: 2)),
    ((Row: -1; Col: 3), (Row: 3; Col: -1), (Row: -1; Col: 4), (Row: 4; Col: -1),
     (Row: -1; Col: -1), (Row: -1; Col: 0), (Row: 0; Col: -1), (Row: -1; Col: 6)));

  { The 4x4 block of a candidate smaller than 8x8 next to block 0..3:
    [block, candidate is in the column to the left]. }
  ColumnToSubblock: array[0..3, 0..1] of Byte = ((1, 2), (1, 3), (3, 2), (3, 3));

type
  TMvList = array[0..1] of TVp9Mv;

function ZeroMv: TVp9Mv; inline;
begin
  Result.Row := 0;
  Result.Col := 0;
end;

function IsInside(constref Position: TVp9BlockPosition; constref Frame: TVp9FrameState;
  constref Offset: TPosition): Boolean; inline;
begin
  Result := not ((Position.MiRow + Offset.Row < 0) or (Position.MiColumn + Offset.Col < Position.TileColumnStart) or
    (Position.MiRow + Offset.Row >= Frame.MiRows) or (Position.MiColumn + Offset.Col >= Position.TileColumnEnd));
end;

function CandidateAt(constref Position: TVp9BlockPosition; constref Frame: TVp9FrameState;
  constref Offset: TPosition): PVp9ModeInfo; inline;
begin
  Result := Frame.Grid.Cells[(Position.MiRow + Offset.Row) * Frame.Grid.Columns + Position.MiColumn + Offset.Col];
end;

{ Segments. }

function ReadSegmentId(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState): LongInt; inline;
begin
  Result := Decoder.ReadTree(@SegmentTree[0], @Frame.Segmentation.TreeProbabilities[0]);
end;

procedure SetSegmentId(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition; Segment: LongInt);
var
  X, Y, Offset: LongInt;
begin
  Offset := Position.MiRow * Frame.MiColumns + Position.MiColumn;
  for Y := 0 to Position.HeightUnits - 1 do
    for X := 0 to Position.WidthUnits - 1 do
      Frame.CurrentSegmentMap[Offset + Y * Frame.MiColumns + X] := Segment;
end;

procedure CopySegmentId(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition);
var
  X, Y, Offset, Index: LongInt;
begin
  Offset := Position.MiRow * Frame.MiColumns + Position.MiColumn;
  for Y := 0 to Position.HeightUnits - 1 do
    for X := 0 to Position.WidthUnits - 1 do
    begin
      Index := Offset + Y * Frame.MiColumns + X;
      Frame.CurrentSegmentMap[Index] := Frame.LastSegmentMap[Index];
    end;
end;

function PredictedSegmentId(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition): LongInt;
var
  X, Y, Offset: LongInt;
begin
  Result := 255;
  Offset := Position.MiRow * Frame.MiColumns + Position.MiColumn;
  for Y := 0 to Position.HeightUnits - 1 do
    for X := 0 to Position.WidthUnits - 1 do
      if Frame.LastSegmentMap[Offset + Y * Frame.MiColumns + X] < Result then
        Result := Frame.LastSegmentMap[Offset + Y * Frame.MiColumns + X];
end;

function ReadIntraSegmentId(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition): LongInt;
begin
  Result := 0;
  if not Frame.Segmentation.Enabled then
    Exit;
  if not Frame.Segmentation.UpdateMap then
  begin
    CopySegmentId(Frame, Position);
    Exit;
  end;
  Result := ReadSegmentId(Decoder, Frame);
  SetSegmentId(Frame, Position, Result);
end;

function ReadInterSegmentId(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition): LongInt;
var
  Predicted, Context: LongInt;
begin
  Result := 0;
  if not Frame.Segmentation.Enabled then
    Exit;
  Predicted := PredictedSegmentId(Frame, Position);
  if not Frame.Segmentation.UpdateMap then
  begin
    CopySegmentId(Frame, Position);
    Exit(Predicted);
  end;
  if Frame.Segmentation.TemporalUpdate then
  begin
    Context := 0;
    if Position.Above <> nil then
      Inc(Context, Position.Above^.SegmentPredicted);
    if Position.Left <> nil then
      Inc(Context, Position.Left^.SegmentPredicted);
    Position.Info^.SegmentPredicted := Decoder.ReadBool(Frame.Segmentation.PredictionProbabilities[Context]);
    if Position.Info^.SegmentPredicted <> 0 then
      Result := Predicted
    else
      Result := ReadSegmentId(Decoder, Frame);
  end
  else
    Result := ReadSegmentId(Decoder, Frame);
  SetSegmentId(Frame, Position, Result);
end;

{ Skip and transform size. }

function ReadSkip(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition;
  Segment: LongInt; Counts: PVp9Counts): Boolean;
var
  Context, Bit: LongInt;
begin
  if SegmentFeatureActive(Frame.Segmentation, Segment, SegmentFeatureSkip) then
    Exit(True);
  Context := 0;
  if (Position.Above <> nil) and Position.Above^.Skip then
    Inc(Context);
  if (Position.Left <> nil) and Position.Left^.Skip then
    Inc(Context);
  Bit := Decoder.ReadBool(Frame.Probabilities^.Skip[Context]);
  if Counts <> nil then
    Inc(Counts^.Skip[Context, Bit]);
  Result := Bit <> 0;
end;

function ReadTransformSize(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition; AllowSelect: Boolean; Counts: PVp9Counts): LongInt;
var
  Largest, AboveContext, LeftContext, Context: LongInt;
  P: PByte;
begin
  Largest := LargestTransform[Position.BlockSize];
  if AllowSelect and (Frame.TransformMode = TransformModeSelect) and (Position.BlockSize >= Block8x8) then
  begin
    if (Position.Above <> nil) and not Position.Above^.Skip then
      AboveContext := Position.Above^.TransformSize
    else
      AboveContext := Largest;
    if (Position.Left <> nil) and not Position.Left^.Skip then
      LeftContext := Position.Left^.TransformSize
    else
      LeftContext := Largest;
    if Position.Left = nil then
      LeftContext := AboveContext;
    if Position.Above = nil then
      AboveContext := LeftContext;
    Context := Ord(AboveContext + LeftContext > Largest);
    case Largest of
      Transform8x8: P := @Frame.Probabilities^.Transform8x8[Context, 0];
      Transform16x16: P := @Frame.Probabilities^.Transform16x16[Context, 0];
    else
      P := @Frame.Probabilities^.Transform32x32[Context, 0];
    end;
    Result := Decoder.ReadBool(P[0]);
    if (Result <> Transform4x4) and (Largest >= Transform16x16) then
    begin
      Inc(Result, Decoder.ReadBool(P[1]));
      if (Result <> Transform8x8) and (Largest >= Transform32x32) then
        Inc(Result, Decoder.ReadBool(P[2]));
    end;
    if Counts <> nil then
      case Largest of
        Transform8x8: Inc(Counts^.Transform8x8[Context, Result]);
        Transform16x16: Inc(Counts^.Transform16x16[Context, Result]);
      else
        Inc(Counts^.Transform32x32[Context, Result]);
      end;
  end
  else
  begin
    Result := TransformModeLargest[Frame.TransformMode];
    if Largest < Result then
      Result := Largest;
  end;
end;

{ Intra frames. }

function SubblockMode(Info: PVp9ModeInfo; Block: LongInt): LongInt; inline;
begin
  if Info^.BlockSize < Block8x8 then
    Result := Info^.Subblocks[Block].Mode
  else
    Result := Info^.Mode;
end;

function AboveMode(Info, Above: PVp9ModeInfo; Block: LongInt): LongInt;
begin
  if (Block = 0) or (Block = 1) then
  begin
    if (Above = nil) or IsInter(Above) then
      Exit(ModeDc);
    Result := SubblockMode(Above, Block + 2);
  end
  else
    Result := Info^.Subblocks[Block - 2].Mode;
end;

function LeftMode(Info, Left: PVp9ModeInfo; Block: LongInt): LongInt;
begin
  if (Block = 0) or (Block = 2) then
  begin
    if (Left = nil) or IsInter(Left) then
      Exit(ModeDc);
    Result := SubblockMode(Left, Block + 1);
  end
  else
    Result := Info^.Subblocks[Block - 1].Mode;
end;

function ReadKeyFrameYMode(var Decoder: TBoolDecoder; constref Position: TVp9BlockPosition; Block: LongInt): LongInt;
begin
  Result := Decoder.ReadTree(@IntraModeTree[0], @KeyFrameYModeProbabilities[
    AboveMode(Position.Info, Position.Above, Block), LeftMode(Position.Info, Position.Left, Block), 0]);
end;

procedure ReadIntraFrameModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  var Position: TVp9BlockPosition; Counts: PVp9Counts);
var
  Info: PVp9ModeInfo;
  Block, Mode: LongInt;
begin
  Info := Position.Info;
  Info^.Segment := ReadIntraSegmentId(Decoder, Frame, Position);
  Info^.Skip := ReadSkip(Decoder, Frame, Position, Info^.Segment, Counts);
  Info^.TransformSize := ReadTransformSize(Decoder, Frame, Position, True, Counts);
  Info^.Reference[0] := ReferenceIntra;
  Info^.Reference[1] := ReferenceNone;
  case Info^.BlockSize of
    Block4x4:
      begin
        for Block := 0 to 3 do
          Info^.Subblocks[Block].Mode := ReadKeyFrameYMode(Decoder, Position, Block);
        Info^.Mode := Info^.Subblocks[3].Mode;
      end;
    Block4x8:
      begin
        Mode := ReadKeyFrameYMode(Decoder, Position, 0);
        Info^.Subblocks[0].Mode := Mode;
        Info^.Subblocks[2].Mode := Mode;
        Mode := ReadKeyFrameYMode(Decoder, Position, 1);
        Info^.Subblocks[1].Mode := Mode;
        Info^.Subblocks[3].Mode := Mode;
        Info^.Mode := Mode;
      end;
    Block8x4:
      begin
        Mode := ReadKeyFrameYMode(Decoder, Position, 0);
        Info^.Subblocks[0].Mode := Mode;
        Info^.Subblocks[1].Mode := Mode;
        Mode := ReadKeyFrameYMode(Decoder, Position, 2);
        Info^.Subblocks[2].Mode := Mode;
        Info^.Subblocks[3].Mode := Mode;
        Info^.Mode := Mode;
      end;
  else
    Info^.Mode := ReadKeyFrameYMode(Decoder, Position, 0);
  end;
  Info^.UvMode := Decoder.ReadTree(@IntraModeTree[0], @KeyFrameUvModeProbabilities[Info^.Mode, 0]);
end;

{ Intra blocks of inter frames. }

function ReadYMode(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; Group: LongInt;
  Counts: PVp9Counts): LongInt;
begin
  Result := Decoder.ReadTree(@IntraModeTree[0], @Frame.Probabilities^.YModes[Group, 0]);
  if Counts <> nil then
    Inc(Counts^.YModes[Group, Result]);
end;

procedure ReadIntraBlockModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition; Counts: PVp9Counts);
var
  Info: PVp9ModeInfo;
  Block, Mode: LongInt;
begin
  Info := Position.Info;
  case Info^.BlockSize of
    Block4x4:
      begin
        for Block := 0 to 3 do
          Info^.Subblocks[Block].Mode := ReadYMode(Decoder, Frame, 0, Counts);
        Info^.Mode := Info^.Subblocks[3].Mode;
      end;
    Block4x8:
      begin
        Mode := ReadYMode(Decoder, Frame, 0, Counts);
        Info^.Subblocks[0].Mode := Mode;
        Info^.Subblocks[2].Mode := Mode;
        Mode := ReadYMode(Decoder, Frame, 0, Counts);
        Info^.Subblocks[1].Mode := Mode;
        Info^.Subblocks[3].Mode := Mode;
        Info^.Mode := Mode;
      end;
    Block8x4:
      begin
        Mode := ReadYMode(Decoder, Frame, 0, Counts);
        Info^.Subblocks[0].Mode := Mode;
        Info^.Subblocks[1].Mode := Mode;
        Mode := ReadYMode(Decoder, Frame, 0, Counts);
        Info^.Subblocks[2].Mode := Mode;
        Info^.Subblocks[3].Mode := Mode;
        Info^.Mode := Mode;
      end;
  else
    Info^.Mode := ReadYMode(Decoder, Frame, SizeGroups[Info^.BlockSize], Counts);
  end;
  Info^.UvMode := Decoder.ReadTree(@IntraModeTree[0], @Frame.Probabilities^.UvModes[Info^.Mode, 0]);
  if Counts <> nil then
    Inc(Counts^.UvModes[Info^.Mode, Info^.UvMode]);
  { Intra blocks count as no filter for the filter contexts. }
  Info^.Filter := SwitchableFilterCount;
  Info^.Reference[0] := ReferenceIntra;
  Info^.Reference[1] := ReferenceNone;
end;

{ References. }

function ReferenceModeContext(constref Frame: TVp9FrameState; Above, Left: PVp9ModeInfo): LongInt;
var
  Edge: PVp9ModeInfo;
begin
  if (Above <> nil) and (Left <> nil) then
  begin
    if (not HasSecondReference(Above)) and (not HasSecondReference(Left)) then
      Result := Ord(Above^.Reference[0] = Frame.FixedReference) xor Ord(Left^.Reference[0] = Frame.FixedReference)
    else if not HasSecondReference(Above) then
      Result := 2 + Ord((Above^.Reference[0] = Frame.FixedReference) or not IsInter(Above))
    else if not HasSecondReference(Left) then
      Result := 2 + Ord((Left^.Reference[0] = Frame.FixedReference) or not IsInter(Left))
    else
      Result := 4;
  end
  else if (Above <> nil) or (Left <> nil) then
  begin
    if Above <> nil then
      Edge := Above
    else
      Edge := Left;
    if not HasSecondReference(Edge) then
      Result := Ord(Edge^.Reference[0] = Frame.FixedReference)
    else
      Result := 3;
  end
  else
    Result := 1;
end;

function CompoundReferenceContext(constref Frame: TVp9FrameState; Above, Left: PVp9ModeInfo): LongInt;
var
  FixedIndex, VariableIndex: LongInt;
  AboveIntra, LeftIntra, LeftSingle, AboveSingle: Boolean;
  Edge: PVp9ModeInfo;
  VariableAbove, VariableLeft, VariableCompound, SingleReference: LongInt;
begin
  FixedIndex := Ord(Frame.SignBias[Frame.FixedReference]);
  VariableIndex := 1 - FixedIndex;
  if (Above <> nil) and (Left <> nil) then
  begin
    AboveIntra := not IsInter(Above);
    LeftIntra := not IsInter(Left);
    if AboveIntra and LeftIntra then
      Result := 2
    else if AboveIntra or LeftIntra then
    begin
      if AboveIntra then
        Edge := Left
      else
        Edge := Above;
      if not HasSecondReference(Edge) then
        Result := 1 + 2 * Ord(Edge^.Reference[0] <> Frame.VariableReferences[1])
      else
        Result := 1 + 2 * Ord(Edge^.Reference[VariableIndex] <> Frame.VariableReferences[1]);
    end
    else
    begin
      LeftSingle := not HasSecondReference(Left);
      AboveSingle := not HasSecondReference(Above);
      if AboveSingle then
        VariableAbove := Above^.Reference[0]
      else
        VariableAbove := Above^.Reference[VariableIndex];
      if LeftSingle then
        VariableLeft := Left^.Reference[0]
      else
        VariableLeft := Left^.Reference[VariableIndex];
      if (VariableAbove = VariableLeft) and (Frame.VariableReferences[1] = VariableAbove) then
        Result := 0
      else if LeftSingle and AboveSingle then
      begin
        if ((VariableAbove = Frame.FixedReference) and (VariableLeft = Frame.VariableReferences[0])) or
          ((VariableLeft = Frame.FixedReference) and (VariableAbove = Frame.VariableReferences[0])) then
          Result := 4
        else if VariableAbove = VariableLeft then
          Result := 3
        else
          Result := 1;
      end
      else if LeftSingle or AboveSingle then
      begin
        if LeftSingle then
          VariableCompound := VariableAbove
        else
          VariableCompound := VariableLeft;
        if AboveSingle then
          SingleReference := VariableAbove
        else
          SingleReference := VariableLeft;
        if (VariableCompound = Frame.VariableReferences[1]) and (SingleReference <> Frame.VariableReferences[1]) then
          Result := 1
        else if (SingleReference = Frame.VariableReferences[1]) and
          (VariableCompound <> Frame.VariableReferences[1]) then
          Result := 2
        else
          Result := 4;
      end
      else if VariableAbove = VariableLeft then
        Result := 4
      else
        Result := 2;
    end;
  end
  else if (Above <> nil) or (Left <> nil) then
  begin
    if Above <> nil then
      Edge := Above
    else
      Edge := Left;
    if not IsInter(Edge) then
      Result := 2
    else if HasSecondReference(Edge) then
      Result := 4 * Ord(Edge^.Reference[VariableIndex] <> Frame.VariableReferences[1])
    else
      Result := 3 * Ord(Edge^.Reference[0] <> Frame.VariableReferences[1]);
  end
  else
    Result := 2;
end;

function SingleReferenceContext1(Above, Left: PVp9ModeInfo): LongInt;
var
  AboveIntra, LeftIntra, AboveSecond, LeftSecond: Boolean;
  Edge: PVp9ModeInfo;
  Above0, Above1, Left0, Left1, SingleReference, Compound1, Compound2: LongInt;
begin
  if (Above <> nil) and (Left <> nil) then
  begin
    AboveIntra := not IsInter(Above);
    LeftIntra := not IsInter(Left);
    if AboveIntra and LeftIntra then
      Result := 2
    else if AboveIntra or LeftIntra then
    begin
      if AboveIntra then
        Edge := Left
      else
        Edge := Above;
      if not HasSecondReference(Edge) then
        Result := 4 * Ord(Edge^.Reference[0] = ReferenceLast)
      else
        Result := 1 + Ord((Edge^.Reference[0] = ReferenceLast) or (Edge^.Reference[1] = ReferenceLast));
    end
    else
    begin
      AboveSecond := HasSecondReference(Above);
      LeftSecond := HasSecondReference(Left);
      Above0 := Above^.Reference[0];
      Above1 := Above^.Reference[1];
      Left0 := Left^.Reference[0];
      Left1 := Left^.Reference[1];
      if AboveSecond and LeftSecond then
        Result := 1 + Ord((Above0 = ReferenceLast) or (Above1 = ReferenceLast) or (Left0 = ReferenceLast) or
          (Left1 = ReferenceLast))
      else if AboveSecond or LeftSecond then
      begin
        if not AboveSecond then
          SingleReference := Above0
        else
          SingleReference := Left0;
        if AboveSecond then
        begin
          Compound1 := Above0;
          Compound2 := Above1;
        end
        else
        begin
          Compound1 := Left0;
          Compound2 := Left1;
        end;
        if SingleReference = ReferenceLast then
          Result := 3 + Ord((Compound1 = ReferenceLast) or (Compound2 = ReferenceLast))
        else
          Result := Ord((Compound1 = ReferenceLast) or (Compound2 = ReferenceLast));
      end
      else
        Result := 2 * Ord(Above0 = ReferenceLast) + 2 * Ord(Left0 = ReferenceLast);
    end;
  end
  else if (Above <> nil) or (Left <> nil) then
  begin
    if Above <> nil then
      Edge := Above
    else
      Edge := Left;
    if not IsInter(Edge) then
      Result := 2
    else if not HasSecondReference(Edge) then
      Result := 4 * Ord(Edge^.Reference[0] = ReferenceLast)
    else
      Result := 1 + Ord((Edge^.Reference[0] = ReferenceLast) or (Edge^.Reference[1] = ReferenceLast));
  end
  else
    Result := 2;
end;

function SingleReferenceContext2(Above, Left: PVp9ModeInfo): LongInt;
var
  AboveIntra, LeftIntra, AboveSecond, LeftSecond: Boolean;
  Edge: PVp9ModeInfo;
  Above0, Above1, Left0, Left1, SingleReference, Compound1, Compound2, Edge0: LongInt;
begin
  if (Above <> nil) and (Left <> nil) then
  begin
    AboveIntra := not IsInter(Above);
    LeftIntra := not IsInter(Left);
    if AboveIntra and LeftIntra then
      Result := 2
    else if AboveIntra or LeftIntra then
    begin
      if AboveIntra then
        Edge := Left
      else
        Edge := Above;
      if not HasSecondReference(Edge) then
      begin
        if Edge^.Reference[0] = ReferenceLast then
          Result := 3
        else
          Result := 4 * Ord(Edge^.Reference[0] = ReferenceGolden);
      end
      else
        Result := 1 + 2 * Ord((Edge^.Reference[0] = ReferenceGolden) or (Edge^.Reference[1] = ReferenceGolden));
    end
    else
    begin
      AboveSecond := HasSecondReference(Above);
      LeftSecond := HasSecondReference(Left);
      Above0 := Above^.Reference[0];
      Above1 := Above^.Reference[1];
      Left0 := Left^.Reference[0];
      Left1 := Left^.Reference[1];
      if AboveSecond and LeftSecond then
      begin
        if (Above0 = Left0) and (Above1 = Left1) then
          Result := 3 * Ord((Above0 = ReferenceGolden) or (Above1 = ReferenceGolden) or (Left0 = ReferenceGolden) or
            (Left1 = ReferenceGolden))
        else
          Result := 2;
      end
      else if AboveSecond or LeftSecond then
      begin
        if not AboveSecond then
          SingleReference := Above0
        else
          SingleReference := Left0;
        if AboveSecond then
        begin
          Compound1 := Above0;
          Compound2 := Above1;
        end
        else
        begin
          Compound1 := Left0;
          Compound2 := Left1;
        end;
        if SingleReference = ReferenceGolden then
          Result := 3 + Ord((Compound1 = ReferenceGolden) or (Compound2 = ReferenceGolden))
        else if SingleReference = ReferenceAltRef then
          Result := Ord((Compound1 = ReferenceGolden) or (Compound2 = ReferenceGolden))
        else
          Result := 1 + 2 * Ord((Compound1 = ReferenceGolden) or (Compound2 = ReferenceGolden));
      end
      else
      begin
        if (Above0 = ReferenceLast) and (Left0 = ReferenceLast) then
          Result := 3
        else if (Above0 = ReferenceLast) or (Left0 = ReferenceLast) then
        begin
          if Above0 = ReferenceLast then
            Edge0 := Left0
          else
            Edge0 := Above0;
          Result := 4 * Ord(Edge0 = ReferenceGolden);
        end
        else
          Result := 2 * Ord(Above0 = ReferenceGolden) + 2 * Ord(Left0 = ReferenceGolden);
      end;
    end;
  end
  else if (Above <> nil) or (Left <> nil) then
  begin
    if Above <> nil then
      Edge := Above
    else
      Edge := Left;
    if (not IsInter(Edge)) or ((Edge^.Reference[0] = ReferenceLast) and not HasSecondReference(Edge)) then
      Result := 2
    else if not HasSecondReference(Edge) then
      Result := 4 * Ord(Edge^.Reference[0] = ReferenceGolden)
    else
      Result := 3 * Ord((Edge^.Reference[0] = ReferenceGolden) or (Edge^.Reference[1] = ReferenceGolden));
  end
  else
    Result := 2;
end;

procedure ReadReferenceFrames(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition; Segment: LongInt; Counts: PVp9Counts);
var
  Info: PVp9ModeInfo;
  Mode, Context, Bit, Index: LongInt;
begin
  Info := Position.Info;
  if SegmentFeatureActive(Frame.Segmentation, Segment, SegmentFeatureReference) then
  begin
    Info^.Reference[0] := Frame.Segmentation.FeatureData[Segment, SegmentFeatureReference];
    Info^.Reference[1] := ReferenceNone;
    Exit;
  end;
  if Frame.ReferenceMode = ReferenceModeSelect then
  begin
    Context := ReferenceModeContext(Frame, Position.Above, Position.Left);
    Mode := Decoder.ReadBool(Frame.Probabilities^.CompoundInter[Context]);
    if Counts <> nil then
      Inc(Counts^.CompoundInter[Context, Mode]);
  end
  else
    Mode := Frame.ReferenceMode;
  if Mode = ReferenceModeCompound then
  begin
    Index := Ord(Frame.SignBias[Frame.FixedReference]);
    Context := CompoundReferenceContext(Frame, Position.Above, Position.Left);
    Bit := Decoder.ReadBool(Frame.Probabilities^.CompoundReference[Context]);
    if Counts <> nil then
      Inc(Counts^.CompoundReference[Context, Bit]);
    Info^.Reference[Index] := Frame.FixedReference;
    Info^.Reference[1 - Index] := Frame.VariableReferences[Bit];
  end
  else
  begin
    Context := SingleReferenceContext1(Position.Above, Position.Left);
    Bit := Decoder.ReadBool(Frame.Probabilities^.SingleReference[Context, 0]);
    if Counts <> nil then
      Inc(Counts^.SingleReference[Context, 0, Bit]);
    if Bit <> 0 then
    begin
      Context := SingleReferenceContext2(Position.Above, Position.Left);
      Bit := Decoder.ReadBool(Frame.Probabilities^.SingleReference[Context, 1]);
      if Counts <> nil then
        Inc(Counts^.SingleReference[Context, 1, Bit]);
      if Bit <> 0 then
        Info^.Reference[0] := ReferenceAltRef
      else
        Info^.Reference[0] := ReferenceGolden;
    end
    else
      Info^.Reference[0] := ReferenceLast;
    Info^.Reference[1] := ReferenceNone;
  end;
end;

function ReadInterMode(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; Context: LongInt;
  Counts: PVp9Counts): LongInt;
var
  Mode: LongInt;
begin
  Mode := Decoder.ReadTree(@InterModeTree[0], @Frame.Probabilities^.InterModes[Context, 0]);
  if Counts <> nil then
    Inc(Counts^.InterModes[Context, Mode]);
  Result := ModeNearest + Mode;
end;

function ReadSwitchableFilter(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition; Counts: PVp9Counts): LongInt;
var
  LeftType, AboveType, Context: LongInt;
begin
  if Position.Left <> nil then
    LeftType := Position.Left^.Filter
  else
    LeftType := SwitchableFilterCount;
  if Position.Above <> nil then
    AboveType := Position.Above^.Filter
  else
    AboveType := SwitchableFilterCount;
  if LeftType = AboveType then
    Context := LeftType
  else if LeftType = SwitchableFilterCount then
    Context := AboveType
  else if AboveType = SwitchableFilterCount then
    Context := LeftType
  else
    Context := SwitchableFilterCount;
  Result := Decoder.ReadTree(@SwitchableFilterTree[0], @Frame.Probabilities^.SwitchableFilters[Context, 0]);
  if Counts <> nil then
    Inc(Counts^.SwitchableFilters[Context, Result]);
end;

{ Motion vectors. }

function UseMvHighPrecision(constref Mv: TVp9Mv): Boolean; inline;
begin
  Result := ((Abs(Mv.Row) shr 3) < CompandedMvReferenceThreshold) and
    ((Abs(Mv.Col) shr 3) < CompandedMvReferenceThreshold);
end;

procedure LowerMvPrecision(var Mv: TVp9Mv; AllowHighPrecision: Boolean);
begin
  if not (AllowHighPrecision and UseMvHighPrecision(Mv)) then
  begin
    if (Mv.Row and 1) <> 0 then
      if Mv.Row > 0 then
        Dec(Mv.Row)
      else
        Inc(Mv.Row);
    if (Mv.Col and 1) <> 0 then
      if Mv.Col > 0 then
        Dec(Mv.Col)
      else
        Inc(Mv.Col);
  end;
end;

function ClampComponent(Value, Low, High: LongInt): SmallInt; inline;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

procedure ClampMvReference(var Mv: TVp9Mv; constref Position: TVp9BlockPosition);
begin
  Mv.Col := ClampComponent(Mv.Col, Position.ToLeft - MvBorder, Position.ToRight + MvBorder);
  Mv.Row := ClampComponent(Mv.Row, Position.ToTop - MvBorder, Position.ToBottom + MvBorder);
end;

function ScaleMv(Info: PVp9ModeInfo; Which, Reference: LongInt; constref Frame: TVp9FrameState): TVp9Mv;
begin
  Result := Info^.Mv[Which];
  if Frame.SignBias[Info^.Reference[Which]] <> Frame.SignBias[Reference] then
  begin
    Result.Row := -Result.Row;
    Result.Col := -Result.Col;
  end;
end;

function SubblockMv(Candidate: PVp9ModeInfo; Which, SearchColumn, Block: LongInt): TVp9Mv; inline;
begin
  if (Block >= 0) and (Candidate^.BlockSize < Block8x8) then
    Result := Candidate^.Subblocks[ColumnToSubblock[Block, Ord(SearchColumn = 0)]].Mv[Which]
  else
    Result := Candidate^.Mv[Which];
end;

type
  { The candidate list being built: AddMv returns True when the search
    is done. }
  TMvSearch = record
    List: TMvList;
    Count: LongInt;
    EarlyBreak: Boolean;
  end;

function AddMv(var Search: TMvSearch; constref Mv: TVp9Mv): Boolean; inline;
begin
  Result := False;
  if Search.Count > 0 then
  begin
    if not SameMv(Mv, Search.List[0]) then
    begin
      Search.List[Search.Count] := Mv;
      Inc(Search.Count);
      Result := True;
    end;
  end
  else
  begin
    Search.List[0] := Mv;
    Search.Count := 1;
    Result := Search.EarlyBreak;
  end;
end;

function AddDifferentReferenceMvs(var Search: TMvSearch; Candidate: PVp9ModeInfo; Reference: LongInt;
  constref Frame: TVp9FrameState): Boolean;
begin
  Result := False;
  if not IsInter(Candidate) then
    Exit;
  if Candidate^.Reference[0] <> Reference then
    if AddMv(Search, ScaleMv(Candidate, 0, Reference, Frame)) then
      Exit(True);
  if HasSecondReference(Candidate) and (Candidate^.Reference[1] <> Reference) and
    not SameMv(Candidate^.Mv[1], Candidate^.Mv[0]) then
    if AddMv(Search, ScaleMv(Candidate, 1, Reference, Frame)) then
      Exit(True);
end;

{ Fills List with up to 2 candidate vectors for Reference; returns how
  many are meaningful (1 except for NEAR). }
function FindMvReferences(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition; Mode: LongInt;
  Reference: LongInt; Block: LongInt; out List: TMvList): LongInt;
var
  Search: TMvSearch;
  Index: LongInt;
  DifferentFound, Done: Boolean;
  Offset: TPosition;
  Candidate: PVp9ModeInfo;
  Previous: PVp9MvReference;
  Mv: TVp9Mv;
begin
  Search.List[0] := ZeroMv;
  Search.List[1] := ZeroMv;
  Search.Count := 0;
  Search.EarlyBreak := Mode <> ModeNear;
  DifferentFound := False;
  Done := False;
  if Frame.UsePreviousMvs then
    Previous := Frame.PreviousMvs + Position.MiRow * Frame.MiColumns + Position.MiColumn
  else
    Previous := nil;
  Index := 0;
  if Block >= 0 then
    while (Index < 2) and not Done do
    begin
      Offset := ReferenceBlocks[Position.BlockSize, Index];
      if IsInside(Position, Frame, Offset) then
      begin
        Candidate := CandidateAt(Position, Frame, Offset);
        DifferentFound := True;
        if Candidate^.Reference[0] = Reference then
          Done := AddMv(Search, SubblockMv(Candidate, 0, Offset.Col, Block))
        else if Candidate^.Reference[1] = Reference then
          Done := AddMv(Search, SubblockMv(Candidate, 1, Offset.Col, Block));
      end;
      Inc(Index);
    end;
  while (Index < 8) and not Done do
  begin
    Offset := ReferenceBlocks[Position.BlockSize, Index];
    if IsInside(Position, Frame, Offset) then
    begin
      Candidate := CandidateAt(Position, Frame, Offset);
      DifferentFound := True;
      if Candidate^.Reference[0] = Reference then
        Done := AddMv(Search, Candidate^.Mv[0])
      else if Candidate^.Reference[1] = Reference then
        Done := AddMv(Search, Candidate^.Mv[1]);
    end;
    Inc(Index);
  end;
  if (not Done) and (Previous <> nil) then
  begin
    if Previous^.Reference[0] = Reference then
      Done := AddMv(Search, Previous^.Mv[0])
    else if Previous^.Reference[1] = Reference then
      Done := AddMv(Search, Previous^.Mv[1]);
  end;
  if (not Done) and DifferentFound then
  begin
    Index := 0;
    while (Index < 8) and not Done do
    begin
      Offset := ReferenceBlocks[Position.BlockSize, Index];
      if IsInside(Position, Frame, Offset) then
        Done := AddDifferentReferenceMvs(Search, CandidateAt(Position, Frame, Offset), Reference, Frame);
      Inc(Index);
    end;
  end;
  if (not Done) and (Previous <> nil) then
  begin
    if (Previous^.Reference[0] <> Reference) and (Previous^.Reference[0] > ReferenceIntra) then
    begin
      Mv := Previous^.Mv[0];
      if Frame.SignBias[Previous^.Reference[0]] <> Frame.SignBias[Reference] then
      begin
        Mv.Row := -Mv.Row;
        Mv.Col := -Mv.Col;
      end;
      Done := AddMv(Search, Mv);
    end;
    if (not Done) and (Previous^.Reference[1] > ReferenceIntra) and (Previous^.Reference[1] <> Reference) and
      not SameMv(Previous^.Mv[1], Previous^.Mv[0]) then
    begin
      Mv := Previous^.Mv[1];
      if Frame.SignBias[Previous^.Reference[1]] <> Frame.SignBias[Reference] then
      begin
        Mv.Row := -Mv.Row;
        Mv.Col := -Mv.Col;
      end;
      Done := AddMv(Search, Mv);
    end;
  end;
  if not Done then
  begin
    if Mode = ModeNear then
      Search.Count := 2
    else
      Search.Count := 1;
  end;
  for Index := 0 to Search.Count - 1 do
    ClampMvReference(Search.List[Index], Position);
  List := Search.List;
  Result := Search.Count;
end;

procedure AppendSubblockMvs(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition; Mode: LongInt;
  Block, ReferenceIndex: LongInt; out Best: TVp9Mv);
var
  List: TMvList;
  Count, Index: LongInt;
  Info: PVp9ModeInfo;
  Reference: LongInt;
begin
  Info := Position.Info;
  Reference := Info^.Reference[ReferenceIndex];
  case Block of
    0:
      begin
        Count := FindMvReferences(Frame, Position, Mode, Reference, Block, List);
        Best := List[Count - 1];
      end;
    1, 2:
      if Mode = ModeNearest then
        Best := Info^.Subblocks[0].Mv[ReferenceIndex]
      else
      begin
        FindMvReferences(Frame, Position, Mode, Reference, Block, List);
        Best := ZeroMv;
        for Index := 0 to 1 do
          if not SameMv(Info^.Subblocks[0].Mv[ReferenceIndex], List[Index]) then
          begin
            Best := List[Index];
            Break;
          end;
      end;
  else
    if Mode = ModeNearest then
      Best := Info^.Subblocks[2].Mv[ReferenceIndex]
    else
    begin
      Best := ZeroMv;
      if not SameMv(Info^.Subblocks[2].Mv[ReferenceIndex], Info^.Subblocks[1].Mv[ReferenceIndex]) then
      begin
        Best := Info^.Subblocks[1].Mv[ReferenceIndex];
        Exit;
      end;
      if not SameMv(Info^.Subblocks[2].Mv[ReferenceIndex], Info^.Subblocks[0].Mv[ReferenceIndex]) then
      begin
        Best := Info^.Subblocks[0].Mv[ReferenceIndex];
        Exit;
      end;
      FindMvReferences(Frame, Position, Mode, Reference, Block, List);
      for Index := 0 to 1 do
        if not SameMv(Info^.Subblocks[2].Mv[ReferenceIndex], List[Index]) then
        begin
          Best := List[Index];
          Break;
        end;
    end;
  end;
end;

function MvClass(Magnitude: LongInt; out Offset: LongInt): LongInt;
var
  Value: LongInt;
begin
  if Magnitude >= 2 * 4096 then
    Result := 10
  else
  begin
    Value := Magnitude shr 3;
    Result := 0;
    while Value > 1 do
    begin
      Value := Value shr 1;
      Inc(Result);
    end;
  end;
  if Result = 0 then
    Offset := Magnitude
  else
    Offset := Magnitude - (2 shl (Result + 2));
end;

procedure CountMvComponent(Value: LongInt; var Counts: TVp9MvComponentCounts);
var
  Sign, Magnitude, MvClassValue, Offset, IntegerPart, Fraction, HighPrecision, Index: LongInt;
begin
  Sign := Ord(Value < 0);
  Inc(Counts.Sign[Sign]);
  Magnitude := Abs(Value) - 1;
  MvClassValue := MvClass(Magnitude, Offset);
  Inc(Counts.Classes[MvClassValue]);
  IntegerPart := Offset shr 3;
  Fraction := (Offset shr 1) and 3;
  HighPrecision := Offset and 1;
  if MvClassValue = 0 then
  begin
    Inc(Counts.Class0[IntegerPart]);
    Inc(Counts.Class0Fraction[IntegerPart, Fraction]);
    Inc(Counts.Class0HighPrecision[HighPrecision]);
  end
  else
  begin
    for Index := 0 to MvClassValue - 1 do
      Inc(Counts.Bits[Index, (IntegerPart shr Index) and 1]);
    Inc(Counts.Fraction[Fraction]);
    Inc(Counts.HighPrecision[HighPrecision]);
  end;
end;

function ReadMvComponent(var Decoder: TBoolDecoder; constref Probabilities: TVp9MvComponentProbabilities;
  UseHighPrecision: Boolean): LongInt;
var
  Sign, ClassValue, IntegerPart, Magnitude, Fraction, HighPrecision, Index: LongInt;
begin
  Sign := Decoder.ReadBool(Probabilities.Sign);
  ClassValue := Decoder.ReadTree(@MvClassTree[0], @Probabilities.Classes[0]);
  if ClassValue = 0 then
  begin
    IntegerPart := Decoder.ReadBool(Probabilities.Class0[0]);
    Magnitude := 0;
    Fraction := Decoder.ReadTree(@MvFractionTree[0], @Probabilities.Class0Fraction[IntegerPart, 0]);
  end
  else
  begin
    IntegerPart := 0;
    for Index := 0 to ClassValue - 1 do
      IntegerPart := IntegerPart or (Decoder.ReadBool(Probabilities.Bits[Index]) shl Index);
    Magnitude := 2 shl (ClassValue + 2);
    Fraction := Decoder.ReadTree(@MvFractionTree[0], @Probabilities.Fraction[0]);
  end;
  if UseHighPrecision then
  begin
    if ClassValue = 0 then
      HighPrecision := Decoder.ReadBool(Probabilities.Class0HighPrecision)
    else
      HighPrecision := Decoder.ReadBool(Probabilities.HighPrecision);
  end
  else
    HighPrecision := 1;
  Inc(Magnitude, ((IntegerPart shl 3) or (Fraction shl 1) or HighPrecision) + 1);
  if Sign <> 0 then
    Result := -Magnitude
  else
    Result := Magnitude;
end;

function ReadMv(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; constref Reference: TVp9Mv;
  Counts: PVp9Counts; out Mv: TVp9Mv): Boolean;
var
  Joint, Row, Col: LongInt;
  UseHighPrecision: Boolean;
begin
  Joint := Decoder.ReadTree(@MvJointTree[0], @Frame.Probabilities^.MvJoints[0]);
  UseHighPrecision := Frame.AllowHighPrecisionMv and UseMvHighPrecision(Reference);
  Row := 0;
  Col := 0;
  if (Joint = 2) or (Joint = 3) then
    Row := ReadMvComponent(Decoder, Frame.Probabilities^.MvComponents[0], UseHighPrecision);
  if (Joint = 1) or (Joint = 3) then
    Col := ReadMvComponent(Decoder, Frame.Probabilities^.MvComponents[1], UseHighPrecision);
  if Counts <> nil then
  begin
    Inc(Counts^.MvJoints[Joint]);
    if (Joint = 2) or (Joint = 3) then
      CountMvComponent(Row, Counts^.MvComponents[0]);
    if (Joint = 1) or (Joint = 3) then
      CountMvComponent(Col, Counts^.MvComponents[1]);
  end;
  Mv.Row := SmallInt(Reference.Row + Row);
  Mv.Col := SmallInt(Reference.Col + Col);
  Result := (Mv.Row > MvLow) and (Mv.Row < MvHigh) and (Mv.Col > MvLow) and (Mv.Col < MvHigh);
end;

{ Sets Mvs for Mode; False when a new vector is out of range. }
function AssignMv(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; Mode: LongInt; var Mvs: TMvList;
  constref ReferenceMvs, NearMvs: TMvList; Compound: Boolean; Counts: PVp9Counts): Boolean;
var
  Index: LongInt;
begin
  Result := True;
  case Mode of
    ModeNew:
      for Index := 0 to Ord(Compound) do
        if not ReadMv(Decoder, Frame, ReferenceMvs[Index], Counts, Mvs[Index]) then
          Result := False;
    ModeNear, ModeNearest:
      begin
        Mvs[0] := NearMvs[0];
        Mvs[1] := NearMvs[1];
      end;
    ModeZero:
      begin
        Mvs[0] := ZeroMv;
        Mvs[1] := ZeroMv;
      end;
  else
    Result := False;
  end;
end;

function ModeContext(constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition): LongInt;
var
  Index, Counter: LongInt;
  Offset: TPosition;
begin
  Counter := 0;
  for Index := 0 to 1 do
  begin
    Offset := ReferenceBlocks[Position.BlockSize, Index];
    if IsInside(Position, Frame, Offset) then
      Inc(Counter, ModeToCounter[CandidateAt(Position, Frame, Offset)^.Mode]);
  end;
  Result := CounterToContext[Counter];
end;

procedure ReadInterBlockModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  constref Position: TVp9BlockPosition; Counts: PVp9Counts);
var
  Info: PVp9ModeInfo;
  BestReferenceMvs, BestSubblock, List, Mvs: TMvList;
  Compound, GotNewReferences: Boolean;
  Context, Reference, Count, SubblockWidth, SubblockHeight, X, Y, J, BlockMode: LongInt;
begin
  Info := Position.Info;
  BestReferenceMvs[0] := ZeroMv;
  BestReferenceMvs[1] := ZeroMv;
  ReadReferenceFrames(Decoder, Frame, Position, Info^.Segment, Counts);
  Compound := HasSecondReference(Info);
  Context := ModeContext(Frame, Position);
  if SegmentFeatureActive(Frame.Segmentation, Info^.Segment, SegmentFeatureSkip) then
  begin
    Info^.Mode := ModeZero;
    if Info^.BlockSize < Block8x8 then
      raise EVp9ModeError.Create('VP9: invalid use of the skip segment feature on small blocks');
  end
  else if Info^.BlockSize >= Block8x8 then
    Info^.Mode := ReadInterMode(Decoder, Frame, Context, Counts);
  if Frame.Filter = FilterSwitchable then
    Info^.Filter := ReadSwitchableFilter(Decoder, Frame, Position, Counts)
  else
    Info^.Filter := Frame.Filter;
  if Info^.BlockSize < Block8x8 then
  begin
    SubblockWidth := 1 shl Position.SubblockWidthLog2;
    SubblockHeight := 1 shl Position.SubblockHeightLog2;
    GotNewReferences := False;
    BestSubblock[1].Row := -32768;
    BestSubblock[1].Col := -32768;
    BlockMode := ModeZero;
    Y := 0;
    while Y < 2 do
    begin
      X := 0;
      while X < 2 do
      begin
        J := Y * 2 + X;
        BlockMode := ReadInterMode(Decoder, Frame, Context, Counts);
        if (BlockMode = ModeNearest) or (BlockMode = ModeNear) then
        begin
          for Reference := 0 to Ord(Compound) do
            AppendSubblockMvs(Frame, Position, BlockMode, J, Reference, BestSubblock[Reference]);
        end
        else if (BlockMode = ModeNew) and not GotNewReferences then
        begin
          for Reference := 0 to Ord(Compound) do
          begin
            FindMvReferences(Frame, Position, ModeNew, Info^.Reference[Reference], -1, List);
            LowerMvPrecision(List[0], Frame.AllowHighPrecisionMv);
            BestReferenceMvs[Reference] := List[0];
            GotNewReferences := True;
          end;
        end;
        Mvs := Info^.Subblocks[J].Mv;
        if not AssignMv(Decoder, Frame, BlockMode, Mvs, BestReferenceMvs, BestSubblock, Compound, Counts) then
          raise EVp9ModeError.Create('VP9: invalid motion vector');
        Info^.Subblocks[J].Mv := Mvs;
        if SubblockHeight = 2 then
          Info^.Subblocks[J + 2] := Info^.Subblocks[J];
        if SubblockWidth = 2 then
          Info^.Subblocks[J + 1] := Info^.Subblocks[J];
        Inc(X, SubblockWidth);
      end;
      Inc(Y, SubblockHeight);
    end;
    Info^.Mode := BlockMode;
    Info^.Mv := Info^.Subblocks[3].Mv;
  end
  else
  begin
    if Info^.Mode <> ModeZero then
      for Reference := 0 to Ord(Compound) do
      begin
        Count := FindMvReferences(Frame, Position, Info^.Mode, Info^.Reference[Reference], -1, List);
        LowerMvPrecision(List[Count - 1], Frame.AllowHighPrecisionMv);
        BestReferenceMvs[Reference] := List[Count - 1];
      end;
    Mvs := Info^.Mv;
    if not AssignMv(Decoder, Frame, Info^.Mode, Mvs, BestReferenceMvs, BestReferenceMvs, Compound, Counts) then
      raise EVp9ModeError.Create('VP9: invalid motion vector');
    Info^.Mv := Mvs;
  end;
end;

function ReadIsInter(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState; constref Position: TVp9BlockPosition;
  Segment: LongInt; Counts: PVp9Counts): Boolean;
var
  Context, Bit: LongInt;
  AboveIntra, LeftIntra: Boolean;
begin
  if SegmentFeatureActive(Frame.Segmentation, Segment, SegmentFeatureReference) then
    Exit(Frame.Segmentation.FeatureData[Segment, SegmentFeatureReference] <> ReferenceIntra);
  if (Position.Above <> nil) and (Position.Left <> nil) then
  begin
    AboveIntra := not IsInter(Position.Above);
    LeftIntra := not IsInter(Position.Left);
    if AboveIntra and LeftIntra then
      Context := 3
    else
      Context := Ord(AboveIntra or LeftIntra);
  end
  else if Position.Above <> nil then
    Context := 2 * Ord(not IsInter(Position.Above))
  else if Position.Left <> nil then
    Context := 2 * Ord(not IsInter(Position.Left))
  else
    Context := 0;
  Bit := Decoder.ReadBool(Frame.Probabilities^.IntraInter[Context]);
  if Counts <> nil then
    Inc(Counts^.IntraInter[Context, Bit]);
  Result := Bit <> 0;
end;

procedure ReadInterFrameModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  var Position: TVp9BlockPosition; Counts: PVp9Counts);
var
  Info: PVp9ModeInfo;
  Inter: Boolean;
  X, Y: LongInt;
  Target: PVp9MvReference;
begin
  Info := Position.Info;
  Info^.Segment := ReadInterSegmentId(Decoder, Frame, Position);
  Info^.Skip := ReadSkip(Decoder, Frame, Position, Info^.Segment, Counts);
  Inter := ReadIsInter(Decoder, Frame, Position, Info^.Segment, Counts);
  Info^.TransformSize := ReadTransformSize(Decoder, Frame, Position, (not Info^.Skip) or (not Inter), Counts);
  if Inter then
    ReadInterBlockModeInfo(Decoder, Frame, Position, Counts)
  else
    ReadIntraBlockModeInfo(Decoder, Frame, Position, Counts);
  for Y := 0 to Position.HeightUnits - 1 do
  begin
    Target := @Frame.Picture.MvReferences[(Position.MiRow + Y) * Frame.MiColumns + Position.MiColumn];
    for X := 0 to Position.WidthUnits - 1 do
    begin
      Target^.Reference[0] := Info^.Reference[0];
      Target^.Reference[1] := Info^.Reference[1];
      Target^.Mv[0] := Info^.Mv[0];
      Target^.Mv[1] := Info^.Mv[1];
      Inc(Target);
    end;
  end;
end;

procedure ReadModeInfo(var Decoder: TBoolDecoder; constref Frame: TVp9FrameState;
  var Position: TVp9BlockPosition; Counts: PVp9Counts);
begin
  if Frame.IntraOnly then
    ReadIntraFrameModeInfo(Decoder, Frame, Position, Counts)
  else
    ReadInterFrameModeInfo(Decoder, Frame, Position, Counts);
end;

end.
