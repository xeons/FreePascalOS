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
  VP8 macroblock modes (RFC 6386 sections 11, 16 and 17): for every
  macroblock of a frame, before any residual data, its segment, whether
  it has coefficients, its intra modes or its reference picture and
  motion vectors.

  Motion vectors are predicted from the macroblocks above, to the left
  and above-left (the "near" vectors), in eighth pixels; split
  macroblocks have one vector per 4x4 block. The macroblock array has a
  border row above and a border column to the left (intra, no motion),
  so that every macroblock has those three neighbours.
}
unit Vp8.Modes;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.BoolDecoder, Vp8.FrameHeader;

type
  TVp8MotionVector = record
    Row, Col: SmallInt;
  end;

  TVp8MacroblockInfo = record
    YMode: Byte;
    UvMode: Byte;
    Reference: Byte;
    Segment: Byte;
    { No coefficients (read, or found after the residual data). }
    Skip: Boolean;
    { A motion vector may point too far outside the picture. }
    NeedsClamping: Boolean;
    { Luma predicted 4x4 at a time: no second order block. }
    HasSubblocks: Boolean;
    Mv: TVp8MotionVector;
    SubblockModes: array[0..15] of Byte;
    SubblockMvs: array[0..15] of TVp8MotionVector;
  end;
  PVp8MacroblockInfo = ^TVp8MacroblockInfo;

  { The macroblocks of a frame with their border: Stride = columns + 1,
    and the first real macroblock is at Stride + 1. }
  TVp8ModeInfoGrid = record
    Items: array of TVp8MacroblockInfo;
    Stride: LongInt;
    Columns, Rows: LongInt;
  end;

{ Makes a grid for Columns x Rows macroblocks, all intra and still. }
procedure AllocateModeGrid(var Grid: TVp8ModeInfoGrid; Columns, Rows: LongInt);
{ The macroblock at (Row, Column). }
function MacroblockAt(var Grid: TVp8ModeInfoGrid; Row, Column: LongInt): PVp8MacroblockInfo; inline;

{ Reads every macroblock's modes from the first partition. }
procedure ReadFrameModes(var Decoder: TBoolDecoder; constref Header: TVp8FrameHeader;
  constref State: TVp8StreamState; var Grid: TVp8ModeInfoGrid);

implementation

uses
  Vp8.Tables;

const
  LeftTopMargin = 16 shl 3;
  RightBottomMargin = 16 shl 3;

type
  TEdges = record
    ToLeft, ToRight, ToTop, ToBottom: LongInt;
  end;

procedure AllocateModeGrid(var Grid: TVp8ModeInfoGrid; Columns, Rows: LongInt);
begin
  Grid.Columns := Columns;
  Grid.Rows := Rows;
  Grid.Stride := Columns + 1;
  Grid.Items := nil;
  SetLength(Grid.Items, Grid.Stride * (Rows + 1) + 1);
end;

function MacroblockAt(var Grid: TVp8ModeInfoGrid; Row, Column: LongInt): PVp8MacroblockInfo; inline;
begin
  Result := @Grid.Items[(Row + 1) * Grid.Stride + Column + 1];
end;

function IsZero(constref Mv: TVp8MotionVector): Boolean; inline;
begin
  Result := (Mv.Row = 0) and (Mv.Col = 0);
end;

function SameVector(constref A, B: TVp8MotionVector): Boolean; inline;
begin
  Result := (A.Row = B.Row) and (A.Col = B.Col);
end;

{ The implied 4x4 mode of a neighbour for key frame contexts. }
function ImpliedSubblockMode(Info: PVp8MacroblockInfo; Block: LongInt): LongInt;
begin
  case Info^.YMode of
    ModeBlocks: Result := Info^.SubblockModes[Block];
    ModeDc: Result := BlockModeDc;
    ModeVertical: Result := BlockModeVertical;
    ModeHorizontal: Result := BlockModeHorizontal;
    ModeTrueMotion: Result := BlockModeTrueMotion;
  else
    Result := BlockModeDc;
  end;
end;

procedure ReadKeyFrameModes(var Decoder: TBoolDecoder; Info: PVp8MacroblockInfo; Stride: LongInt);
var
  Block, Above, Left: LongInt;
begin
  Info^.Reference := ReferenceIntra;
  Info^.YMode := Decoder.ReadTree(@KeyFrameYModeTree[0], @KeyFrameYModeProbabilities[0]);
  if Info^.YMode = ModeBlocks then
  begin
    Info^.HasSubblocks := True;
    for Block := 0 to 15 do
    begin
      if Block < 4 then
        Above := ImpliedSubblockMode(Info - Stride, Block + 12)
      else
        Above := Info^.SubblockModes[Block - 4];
      if (Block and 3) = 0 then
        Left := ImpliedSubblockMode(Info - 1, Block + 3)
      else
        Left := Info^.SubblockModes[Block - 1];
      Info^.SubblockModes[Block] := Decoder.ReadTree(@BlockModeTree[0],
        @KeyFrameBlockModeProbabilities[Above, Left, 0]);
    end;
  end;
  Info^.UvMode := Decoder.ReadTree(@UvModeTree[0], @KeyFrameUvModeProbabilities[0]);
end;

function ReadMvComponent(var Decoder: TBoolDecoder; P: PByte): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  if Decoder.ReadBool(P[MvIsShort]) <> 0 then
  begin
    for Index := 0 to 2 do
      Inc(Result, Decoder.ReadBool(P[MvLongBits + Index]) shl Index);
    Index := MvLongWidth - 1;
    while Index > 3 do
    begin
      Inc(Result, Decoder.ReadBool(P[MvLongBits + Index]) shl Index);
      Dec(Index);
    end;
    if ((Result and $FFF0) = 0) or (Decoder.ReadBool(P[MvLongBits + 3]) <> 0) then
      Inc(Result, 8);
  end
  else
    Result := Decoder.ReadTree(@SmallMvTree[0], P + MvShortTree);
  if (Result <> 0) and (Decoder.ReadBool(P[MvSign]) <> 0) then
    Result := -Result;
end;

procedure ReadMv(var Decoder: TBoolDecoder; constref State: TVp8StreamState; out Mv: TVp8MotionVector);
begin
  Mv.Row := SmallInt(ReadMvComponent(Decoder, @State.Entropy.MotionVectors[0, 0]) * 2);
  Mv.Col := SmallInt(ReadMvComponent(Decoder, @State.Entropy.MotionVectors[1, 0]) * 2);
end;

procedure ClampToMargins(var Mv: TVp8MotionVector; constref Edges: TEdges);
begin
  if Mv.Col < Edges.ToLeft - LeftTopMargin then
    Mv.Col := Edges.ToLeft - LeftTopMargin
  else if Mv.Col > Edges.ToRight + RightBottomMargin then
    Mv.Col := Edges.ToRight + RightBottomMargin;
  if Mv.Row < Edges.ToTop - LeftTopMargin then
    Mv.Row := Edges.ToTop - LeftTopMargin
  else if Mv.Row > Edges.ToBottom + RightBottomMargin then
    Mv.Row := Edges.ToBottom + RightBottomMargin;
end;

function OutsideMargins(constref Mv: TVp8MotionVector; constref Edges: TEdges): Boolean;
begin
  Result := (Mv.Col < Edges.ToLeft - LeftTopMargin) or (Mv.Col > Edges.ToRight + RightBottomMargin) or
    (Mv.Row < Edges.ToTop - LeftTopMargin) or (Mv.Row > Edges.ToBottom + RightBottomMargin);
end;

procedure ApplySignBias(NeighbourBias: Boolean; Reference: LongInt; constref State: TVp8StreamState;
  var Mv: TVp8MotionVector);
begin
  if NeighbourBias <> State.SignBias[Reference] then
  begin
    Mv.Row := -Mv.Row;
    Mv.Col := -Mv.Col;
  end;
end;

procedure ReadSplitMvs(var Decoder: TBoolDecoder; Info: PVp8MacroblockInfo; Stride: LongInt;
  constref Best: TVp8MotionVector; constref State: TVp8StreamState; constref Edges: TEdges);
var
  Split, PartCount, Part, First, Fill: LongInt;
  LeftMv, AboveMv, BlockMv: TVp8MotionVector;
  LeftInfo, AboveInfo: PVp8MacroblockInfo;
  P: PByte;
begin
  Split := 3;
  PartCount := 16;
  if Decoder.ReadBool(110) <> 0 then
  begin
    Split := 2;
    PartCount := 4;
    if Decoder.ReadBool(111) <> 0 then
    begin
      Split := Decoder.ReadBool(150);
      PartCount := 2;
    end;
  end;
  LeftInfo := Info - 1;
  AboveInfo := Info - Stride;
  for Part := 0 to PartCount - 1 do
  begin
    First := SplitFirstBlocks[Split, Part];
    if (First and 3) = 0 then
    begin
      if LeftInfo^.YMode <> ModeSplit then
        LeftMv := LeftInfo^.Mv
      else
        LeftMv := LeftInfo^.SubblockMvs[First + 3];
    end
    else
      LeftMv := Info^.SubblockMvs[First - 1];
    if (First shr 2) = 0 then
    begin
      if AboveInfo^.YMode <> ModeSplit then
        AboveMv := AboveInfo^.Mv
      else
        AboveMv := AboveInfo^.SubblockMvs[First + 12];
    end
    else
      AboveMv := Info^.SubblockMvs[First - 4];
    P := @SubMvReferenceProbabilities[(Ord(IsZero(AboveMv)) shl 2) or (Ord(IsZero(LeftMv)) shl 1) or
      Ord(SameVector(LeftMv, AboveMv)), 0];
    if Decoder.ReadBool(P[0]) <> 0 then
    begin
      if Decoder.ReadBool(P[1]) <> 0 then
      begin
        BlockMv.Row := 0;
        BlockMv.Col := 0;
        if Decoder.ReadBool(P[2]) <> 0 then
        begin
          BlockMv.Row := SmallInt(ReadMvComponent(Decoder, @State.Entropy.MotionVectors[0, 0]) * 2 + Best.Row);
          BlockMv.Col := SmallInt(ReadMvComponent(Decoder, @State.Entropy.MotionVectors[1, 0]) * 2 + Best.Col);
        end;
      end
      else
        BlockMv := AboveMv;
    end
    else
      BlockMv := LeftMv;
    if OutsideMargins(BlockMv, Edges) then
      Info^.NeedsClamping := True;
    for Fill := 0 to SplitFillCount[Split] - 1 do
      Info^.SubblockMvs[SplitFillOrder[Split, Part * SplitFillCount[Split] + Fill]] := BlockMv;
  end;
end;

procedure ReadInterModes(var Decoder: TBoolDecoder; Info: PVp8MacroblockInfo; Stride: LongInt;
  constref Header: TVp8FrameHeader; constref State: TVp8StreamState; constref Edges: TEdges);
const
  CountIntra = 0;
  CountNearest = 1;
  CountNear = 2;
  CountSplit = 3;
var
  Counts: array[0..3] of LongInt;
  NearMvs: array[0..3] of TVp8MotionVector;
  Last, Temp: LongInt;
  TempMv, ThisMv: TVp8MotionVector;
  Above, Left, AboveLeft: PVp8MacroblockInfo;
  BestIndex, Block: LongInt;
begin
  Info^.NeedsClamping := False;
  Info^.Reference := Decoder.ReadBool(Header.IntraProbability);
  if Info^.Reference <> ReferenceIntra then
  begin
    if Decoder.ReadBool(Header.LastProbability) <> 0 then
      Info^.Reference := 2 + Decoder.ReadBool(Header.GoldenProbability);
    Above := Info - Stride;
    Left := Info - 1;
    AboveLeft := Above - 1;
    FillChar(NearMvs, SizeOf(NearMvs), 0);
    FillChar(Counts, SizeOf(Counts), 0);
    Last := 0;
    if Above^.Reference <> ReferenceIntra then
    begin
      if not IsZero(Above^.Mv) then
      begin
        Inc(Last);
        NearMvs[Last] := Above^.Mv;
        ApplySignBias(State.SignBias[Above^.Reference], Info^.Reference, State, NearMvs[Last]);
      end;
      Inc(Counts[Last], 2);
    end;
    if Left^.Reference <> ReferenceIntra then
    begin
      if not IsZero(Left^.Mv) then
      begin
        ThisMv := Left^.Mv;
        ApplySignBias(State.SignBias[Left^.Reference], Info^.Reference, State, ThisMv);
        if not SameVector(ThisMv, NearMvs[Last]) then
        begin
          Inc(Last);
          NearMvs[Last] := ThisMv;
        end;
        Inc(Counts[Last], 2);
      end
      else
        Inc(Counts[CountIntra], 2);
    end;
    if AboveLeft^.Reference <> ReferenceIntra then
    begin
      if not IsZero(AboveLeft^.Mv) then
      begin
        ThisMv := AboveLeft^.Mv;
        ApplySignBias(State.SignBias[AboveLeft^.Reference], Info^.Reference, State, ThisMv);
        if not SameVector(ThisMv, NearMvs[Last]) then
        begin
          Inc(Last);
          NearMvs[Last] := ThisMv;
        end;
        Inc(Counts[Last], 1);
      end
      else
        Inc(Counts[CountIntra], 1);
    end;
    if Decoder.ReadBool(ModeContexts[Counts[CountIntra], 0]) <> 0 then
    begin
      if (Counts[CountSplit] > 0) and SameVector(NearMvs[Last], NearMvs[CountNearest]) then
        Inc(Counts[CountNearest]);
      if Counts[CountNear] > Counts[CountNearest] then
      begin
        Temp := Counts[CountNearest];
        Counts[CountNearest] := Counts[CountNear];
        Counts[CountNear] := Temp;
        TempMv := NearMvs[CountNearest];
        NearMvs[CountNearest] := NearMvs[CountNear];
        NearMvs[CountNear] := TempMv;
      end;
      if Decoder.ReadBool(ModeContexts[Counts[CountNearest], 1]) <> 0 then
      begin
        if Decoder.ReadBool(ModeContexts[Counts[CountNear], 2]) <> 0 then
        begin
          BestIndex := CountIntra + Ord(Counts[CountNearest] >= Counts[CountIntra]);
          ClampToMargins(NearMvs[BestIndex], Edges);
          Counts[CountSplit] := (Ord(Above^.YMode = ModeSplit) + Ord(Left^.YMode = ModeSplit)) * 2 +
            Ord(AboveLeft^.YMode = ModeSplit);
          if Decoder.ReadBool(ModeContexts[Counts[CountSplit], 3]) <> 0 then
          begin
            ReadSplitMvs(Decoder, Info, Stride, NearMvs[BestIndex], State, Edges);
            Info^.Mv := Info^.SubblockMvs[15];
            Info^.YMode := ModeSplit;
            Info^.HasSubblocks := True;
          end
          else
          begin
            ReadMv(Decoder, State, Info^.Mv);
            Info^.Mv.Row := SmallInt(Info^.Mv.Row + NearMvs[BestIndex].Row);
            Info^.Mv.Col := SmallInt(Info^.Mv.Col + NearMvs[BestIndex].Col);
            Info^.NeedsClamping := OutsideMargins(Info^.Mv, Edges);
            Info^.YMode := ModeNew;
          end;
        end
        else
        begin
          Info^.YMode := ModeNear;
          Info^.Mv := NearMvs[CountNear];
          ClampToMargins(Info^.Mv, Edges);
        end;
      end
      else
      begin
        Info^.YMode := ModeNearest;
        Info^.Mv := NearMvs[CountNearest];
        ClampToMargins(Info^.Mv, Edges);
      end;
    end
    else
    begin
      Info^.YMode := ModeZero;
      Info^.Mv.Row := 0;
      Info^.Mv.Col := 0;
    end;
    if Info^.YMode <> ModeSplit then
      for Block := 0 to 15 do
        Info^.SubblockMvs[Block] := Info^.Mv;
  end
  else
  begin
    Info^.Mv.Row := 0;
    Info^.Mv.Col := 0;
    Info^.YMode := Decoder.ReadTree(@YModeTree[0], @State.Entropy.YModes[0]);
    if Info^.YMode = ModeBlocks then
    begin
      Info^.HasSubblocks := True;
      for Block := 0 to 15 do
        Info^.SubblockModes[Block] := Decoder.ReadTree(@BlockModeTree[0], @DefaultBlockModeProbabilities[0]);
    end;
    Info^.UvMode := Decoder.ReadTree(@UvModeTree[0], @State.Entropy.UvModes[0]);
  end;
end;

procedure ReadFrameModes(var Decoder: TBoolDecoder; constref Header: TVp8FrameHeader;
  constref State: TVp8StreamState; var Grid: TVp8ModeInfoGrid);
var
  Row, Column: LongInt;
  Info: PVp8MacroblockInfo;
  Edges: TEdges;
begin
  for Row := 0 to Grid.Rows - 1 do
  begin
    Edges.ToTop := -((Row * 16) shl 3);
    Edges.ToBottom := ((Grid.Rows - 1 - Row) * 16) shl 3;
    for Column := 0 to Grid.Columns - 1 do
    begin
      Edges.ToLeft := -((Column * 16) shl 3);
      Edges.ToRight := ((Grid.Columns - 1 - Column) * 16) shl 3;
      Info := MacroblockAt(Grid, Row, Column);
      if State.Segmentation.UpdateMap then
      begin
        if Decoder.ReadBool(State.Segmentation.TreeProbabilities[0]) <> 0 then
          Info^.Segment := 2 + Decoder.ReadBool(State.Segmentation.TreeProbabilities[2])
        else
          Info^.Segment := Decoder.ReadBool(State.Segmentation.TreeProbabilities[1]);
      end
      else if Header.KeyFrame then
        Info^.Segment := 0;
      if Header.SkipEnabled then
        Info^.Skip := Decoder.ReadBool(Header.SkipFalseProbability) <> 0
      else
        Info^.Skip := False;
      Info^.HasSubblocks := False;
      if Header.KeyFrame then
        ReadKeyFrameModes(Decoder, Info, Grid.Stride)
      else
        ReadInterModes(Decoder, Info, Grid.Stride, Header, State, Edges);
    end;
  end;
end;

end.
