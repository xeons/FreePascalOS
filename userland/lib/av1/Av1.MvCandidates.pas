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
  The candidate gathering of the find MV stack process (specification
  sections 7.10.2.1 to 7.10.2.10): the global motion vector of the
  block, the scans of the rows above, the columns to the left, single
  points and the motion field, and how each candidate is added to the
  stack (RefStackMv, WeightStack, NumMvFound, NewMvCount of the tile).

  TMvSearch carries what the specification keeps between the steps of
  one search (FoundMatch, isCompound) so that nothing is global.
}
unit Av1.MvCandidates;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.References, Av1.FrameContext, Av1.TileContext;

type
  TGlobalParamsRow = array[0..5] of Integer;

  TMvSearch = record
    Tile: TTileContext;
    IsCompound: Boolean;
    FoundMatch: Boolean;
  end;

{ The lower precision process (7.10.2.10). }
procedure LowerMvPrecision(Tile: TTileContext; var Candidate: TMotionVector);
{ The setup global MV process (7.10.2.1) for RefFrame[ RefList ]. }
function SetupGlobalMv(Tile: TTileContext; RefList: Integer): TMotionVector;
{ True when RefFrames[ Row ][ Col ][ 0 ] has been written for this frame:
  the position is in the tile and already decoded. }
function CandidateDecoded(Tile: TTileContext; Row, Col: Integer): Boolean;
procedure ScanRow(var Search: TMvSearch; DeltaRow: Integer);
procedure ScanCol(var Search: TMvSearch; DeltaCol: Integer);
procedure ScanPoint(var Search: TMvSearch; DeltaRow, DeltaCol: Integer);
procedure TemporalScan(var Search: TMvSearch);

implementation

procedure LowerMvPrecision(Tile: TTileContext; var Candidate: TMotionVector);
var
  Component, Magnitude, Whole: Integer;
begin
  if Tile.Header^.allow_high_precision_mv then
    Exit;
  for Component := 0 to 1 do
  begin
    if Tile.Header^.force_integer_mv <> 0 then
    begin
      Magnitude := Abs(Candidate[Component]);
      Whole := (Magnitude + 3) shr 3;
      if Candidate[Component] > 0 then
        Candidate[Component] := Whole shl 3
      else
        Candidate[Component] := -(Whole shl 3);
    end
    else if (Candidate[Component] and 1) <> 0 then
    begin
      if Candidate[Component] > 0 then
        Dec(Candidate[Component])
      else
        Inc(Candidate[Component]);
    end;
  end;
end;

function SetupGlobalMv(Tile: TTileContext; RefList: Integer): TMotionVector;
var
  Reference, MotionType, X, Y: Integer;
  XCenter, YCenter: Int64;
  Params: ^TGlobalParamsRow;
begin
  Reference := Tile.RefFrame[RefList];
  MotionType := IDENTITY;
  if Reference <> INTRA_FRAME then
    MotionType := Tile.Header^.GmType[Reference];
  if (Reference = INTRA_FRAME) or (MotionType = IDENTITY) then
  begin
    Result[0] := 0;
    Result[1] := 0;
  end
  else
  begin
    Params := @Tile.Header^.gm_params[Reference];
    if MotionType = TRANSLATION then
    begin
      Result[0] := ShiftRight(Params^[0], WARPEDMODEL_PREC_BITS - 3);
      Result[1] := ShiftRight(Params^[1], WARPEDMODEL_PREC_BITS - 3);
    end
    else
    begin
      X := Tile.MiCol * MI_SIZE + Block_Width(Tile.MiSize) div 2 - 1;
      Y := Tile.MiRow * MI_SIZE + Block_Height(Tile.MiSize) div 2 - 1;
      XCenter := Int64(Params^[2] - (1 shl WARPEDMODEL_PREC_BITS)) * X + Int64(Params^[3]) * Y + Params^[0];
      YCenter := Int64(Params^[4]) * X + Int64(Params^[5] - (1 shl WARPEDMODEL_PREC_BITS)) * Y + Params^[1];
      if Tile.Header^.allow_high_precision_mv then
      begin
        Result[0] := Round2SignedInt64(YCenter, WARPEDMODEL_PREC_BITS - 3);
        Result[1] := Round2SignedInt64(XCenter, WARPEDMODEL_PREC_BITS - 3);
      end
      else
      begin
        Result[0] := Round2SignedInt64(YCenter, WARPEDMODEL_PREC_BITS - 2) * 2;
        Result[1] := Round2SignedInt64(XCenter, WARPEDMODEL_PREC_BITS - 2) * 2;
      end;
    end;
  end;
  LowerMvPrecision(Tile, Result);
end;

function CandidateDecoded(Tile: TTileContext; Row, Col: Integer): Boolean;
var
  SuperblockMask: Integer;
begin
  if not Tile.IsInside(Row, Col) then
    Exit(False);
  { Every position above or to the left of the block's superblock row and
    column is decoded; within the superblock, BlockDecoded (luma) records
    which 4x4 blocks are. Candidates lie at most one row above and one
    column left of the block, so they are within BlockDecoded's range. }
  if Tile.Sequence^.use_128x128_superblock then
    SuperblockMask := 31
  else
    SuperblockMask := 15;
  Result := Tile.BlockDecoded(0, (Row - (Tile.MiRow and not SuperblockMask)),
    (Col - (Tile.MiCol and not SuperblockMask)));
end;

function HasNewMv(Mode: Integer): Boolean; inline;
begin
  Result := (Mode = NEWMV) or (Mode = NEW_NEWMV) or (Mode = NEAR_NEWMV) or (Mode = NEW_NEARMV) or
    (Mode = NEAREST_NEWMV) or (Mode = NEW_NEARESTMV);
end;

function SameMv(const A, B: TMotionVector): Boolean; inline;
begin
  Result := (A[0] = B[0]) and (A[1] = B[1]);
end;

function GlobalTypeAboveTranslation(Tile: TTileContext; Reference: Integer): Boolean; inline;
begin
  Result := (Reference > INTRA_FRAME) and (Tile.Header^.GmType[Reference] > TRANSLATION);
end;

{ The search stack process (7.10.2.8). }
procedure SearchStack(var Search: TMvSearch; MvRow, MvCol, CandList, Weight: Integer);
var
  Tile: TTileContext;
  Candidate: PBlockInfo;
  CandMode, CandSize, Index: Integer;
  Large: Boolean;
  CandMv: TMotionVector;
begin
  Tile := Search.Tile;
  Candidate := Tile.Frame.Block(MvRow, MvCol);
  CandMode := Candidate^.YMode;
  CandSize := Candidate^.MiSize;
  Large := Min(Block_Width(CandSize), Block_Height(CandSize)) >= 8;
  if ((CandMode = GLOBALMV) or (CandMode = GLOBAL_GLOBALMV)) and
    GlobalTypeAboveTranslation(Tile, Tile.RefFrame[0]) and Large then
    CandMv := Tile.GlobalMvs[0]
  else
    CandMv := Candidate^.Mv[CandList];
  LowerMvPrecision(Tile, CandMv);
  if HasNewMv(CandMode) then
    Inc(Tile.NewMvCount);
  Search.FoundMatch := True;
  for Index := 0 to Tile.NumMvFound - 1 do
    if SameMv(CandMv, Tile.RefStackMv[Index, 0]) then
    begin
      Inc(Tile.WeightStack[Index], Weight);
      Exit;
    end;
  if Tile.NumMvFound < MAX_REF_MV_STACK_SIZE then
  begin
    Tile.RefStackMv[Tile.NumMvFound, 0] := CandMv;
    Tile.WeightStack[Tile.NumMvFound] := Weight;
    Inc(Tile.NumMvFound);
  end;
end;

{ The compound search stack process (7.10.2.9). }
procedure CompoundSearchStack(var Search: TMvSearch; MvRow, MvCol, Weight: Integer);
var
  Tile: TTileContext;
  Candidate: PBlockInfo;
  CandMode, RefList, Index: Integer;
  CandMvs: array[0..1] of TMotionVector;
begin
  Tile := Search.Tile;
  Candidate := Tile.Frame.Block(MvRow, MvCol);
  CandMvs[0] := Candidate^.Mv[0];
  CandMvs[1] := Candidate^.Mv[1];
  CandMode := Candidate^.YMode;
  if CandMode = GLOBAL_GLOBALMV then
    for RefList := 0 to 1 do
      if GlobalTypeAboveTranslation(Tile, Tile.RefFrame[RefList]) then
        CandMvs[RefList] := Tile.GlobalMvs[RefList];
  LowerMvPrecision(Tile, CandMvs[0]);
  LowerMvPrecision(Tile, CandMvs[1]);
  Search.FoundMatch := True;
  Index := 0;
  while Index < Tile.NumMvFound do
  begin
    if SameMv(CandMvs[0], Tile.RefStackMv[Index, 0]) and SameMv(CandMvs[1], Tile.RefStackMv[Index, 1]) then
      Break;
    Inc(Index);
  end;
  if Index < Tile.NumMvFound then
    Inc(Tile.WeightStack[Index], Weight)
  else if Tile.NumMvFound < MAX_REF_MV_STACK_SIZE then
  begin
    Tile.RefStackMv[Tile.NumMvFound, 0] := CandMvs[0];
    Tile.RefStackMv[Tile.NumMvFound, 1] := CandMvs[1];
    Tile.WeightStack[Tile.NumMvFound] := Weight;
    Inc(Tile.NumMvFound);
  end;
  if HasNewMv(CandMode) then
    Inc(Tile.NewMvCount);
end;

{ The add reference motion vector process (7.10.2.7). }
procedure AddRefMvCandidate(var Search: TMvSearch; MvRow, MvCol, Weight: Integer);
var
  Tile: TTileContext;
  Candidate: PBlockInfo;
  CandList: Integer;
begin
  Tile := Search.Tile;
  Candidate := Tile.Frame.Block(MvRow, MvCol);
  if not Candidate^.IsInter then
    Exit;
  if not Search.IsCompound then
  begin
    for CandList := 0 to 1 do
      if Candidate^.RefFrame[CandList] = Tile.RefFrame[0] then
        SearchStack(Search, MvRow, MvCol, CandList, Weight);
  end
  else if (Candidate^.RefFrame[0] = Tile.RefFrame[0]) and (Candidate^.RefFrame[1] = Tile.RefFrame[1]) then
    CompoundSearchStack(Search, MvRow, MvCol, Weight);
end;

procedure ScanRow(var Search: TMvSearch; DeltaRow: Integer);
var
  Tile: TTileContext;
  BlockWidth4, End4, DeltaCol, Index, MvRow, MvCol, Length4: Integer;
  UseStep16: Boolean;
begin
  Tile := Search.Tile;
  BlockWidth4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  End4 := Min(Min(BlockWidth4, Tile.Header^.MiCols - Tile.MiCol), 16);
  DeltaCol := 0;
  UseStep16 := BlockWidth4 >= 16;
  if Abs(DeltaRow) > 1 then
  begin
    Inc(DeltaRow, Tile.MiRow and 1);
    DeltaCol := 1 - (Tile.MiCol and 1);
  end;
  Index := 0;
  while Index < End4 do
  begin
    MvRow := Tile.MiRow + DeltaRow;
    MvCol := Tile.MiCol + DeltaCol + Index;
    if not Tile.IsInside(MvRow, MvCol) then
      Break;
    Length4 := Min(BlockWidth4, Num_4x4_Blocks_Wide[Tile.Frame.Block(MvRow, MvCol)^.MiSize]);
    if Abs(DeltaRow) > 1 then
      Length4 := Max(2, Length4);
    if UseStep16 then
      Length4 := Max(4, Length4);
    AddRefMvCandidate(Search, MvRow, MvCol, Length4 * 2);
    Inc(Index, Length4);
  end;
end;

procedure ScanCol(var Search: TMvSearch; DeltaCol: Integer);
var
  Tile: TTileContext;
  BlockHeight4, End4, DeltaRow, Index, MvRow, MvCol, Length4: Integer;
  UseStep16: Boolean;
begin
  Tile := Search.Tile;
  BlockHeight4 := Num_4x4_Blocks_High[Tile.MiSize];
  End4 := Min(Min(BlockHeight4, Tile.Header^.MiRows - Tile.MiRow), 16);
  DeltaRow := 0;
  UseStep16 := BlockHeight4 >= 16;
  if Abs(DeltaCol) > 1 then
  begin
    DeltaRow := 1 - (Tile.MiRow and 1);
    Inc(DeltaCol, Tile.MiCol and 1);
  end;
  Index := 0;
  while Index < End4 do
  begin
    MvRow := Tile.MiRow + DeltaRow + Index;
    MvCol := Tile.MiCol + DeltaCol;
    if not Tile.IsInside(MvRow, MvCol) then
      Break;
    Length4 := Min(BlockHeight4, Num_4x4_Blocks_High[Tile.Frame.Block(MvRow, MvCol)^.MiSize]);
    if Abs(DeltaCol) > 1 then
      Length4 := Max(2, Length4);
    if UseStep16 then
      Length4 := Max(4, Length4);
    AddRefMvCandidate(Search, MvRow, MvCol, Length4 * 2);
    Inc(Index, Length4);
  end;
end;

procedure ScanPoint(var Search: TMvSearch; DeltaRow, DeltaCol: Integer);
var
  MvRow, MvCol: Integer;
begin
  MvRow := Search.Tile.MiRow + DeltaRow;
  MvCol := Search.Tile.MiCol + DeltaCol;
  if CandidateDecoded(Search.Tile, MvRow, MvCol) then
    AddRefMvCandidate(Search, MvRow, MvCol, 4);
end;

function FarFromGlobal(const Candidate, Global: TMotionVector): Boolean; inline;
begin
  Result := (Abs(Candidate[0] - Global[0]) >= 16) or (Abs(Candidate[1] - Global[1]) >= 16);
end;

{ The temporal sample process (7.10.2.6). }
procedure AddTemporalCandidate(var Search: TMvSearch; DeltaRow, DeltaCol: Integer);
var
  Tile: TTileContext;
  Frame: TFrameContext;
  MvRow, MvCol, FieldIndex, Index: Integer;
  AtOrigin: Boolean;
  CandMv0, CandMv1: TMotionVector;
begin
  Tile := Search.Tile;
  Frame := Tile.Frame;
  MvRow := (Tile.MiRow + DeltaRow) or 1;
  MvCol := (Tile.MiCol + DeltaCol) or 1;
  if not Tile.IsInside(MvRow, MvCol) then
    Exit;
  FieldIndex := (MvRow shr 1) * Frame.MotionFieldStride + (MvCol shr 1);
  AtOrigin := (DeltaRow = 0) and (DeltaCol = 0);
  if AtOrigin then
    Tile.ZeroMvContext := 1;
  if not Search.IsCompound then
  begin
    CandMv0 := Frame.MotionFieldMvs[Tile.RefFrame[0]][FieldIndex];
    if CandMv0[0] = InvalidMotionVector then
      Exit;
    LowerMvPrecision(Tile, CandMv0);
    if AtOrigin then
      Tile.ZeroMvContext := Ord(FarFromGlobal(CandMv0, Tile.GlobalMvs[0]));
    Index := 0;
    while Index < Tile.NumMvFound do
    begin
      if SameMv(CandMv0, Tile.RefStackMv[Index, 0]) then
        Break;
      Inc(Index);
    end;
    if Index < Tile.NumMvFound then
      Inc(Tile.WeightStack[Index], 2)
    else if Tile.NumMvFound < MAX_REF_MV_STACK_SIZE then
    begin
      Tile.RefStackMv[Tile.NumMvFound, 0] := CandMv0;
      Tile.WeightStack[Tile.NumMvFound] := 2;
      Inc(Tile.NumMvFound);
    end;
  end
  else
  begin
    CandMv0 := Frame.MotionFieldMvs[Tile.RefFrame[0]][FieldIndex];
    if CandMv0[0] = InvalidMotionVector then
      Exit;
    CandMv1 := Frame.MotionFieldMvs[Tile.RefFrame[1]][FieldIndex];
    if CandMv1[0] = InvalidMotionVector then
      Exit;
    LowerMvPrecision(Tile, CandMv0);
    LowerMvPrecision(Tile, CandMv1);
    if AtOrigin then
      Tile.ZeroMvContext := Ord(FarFromGlobal(CandMv0, Tile.GlobalMvs[0]) or
        FarFromGlobal(CandMv1, Tile.GlobalMvs[1]));
    Index := 0;
    while Index < Tile.NumMvFound do
    begin
      if SameMv(CandMv0, Tile.RefStackMv[Index, 0]) and SameMv(CandMv1, Tile.RefStackMv[Index, 1]) then
        Break;
      Inc(Index);
    end;
    if Index < Tile.NumMvFound then
      Inc(Tile.WeightStack[Index], 2)
    else if Tile.NumMvFound < MAX_REF_MV_STACK_SIZE then
    begin
      Tile.RefStackMv[Tile.NumMvFound, 0] := CandMv0;
      Tile.RefStackMv[Tile.NumMvFound, 1] := CandMv1;
      Tile.WeightStack[Tile.NumMvFound] := 2;
      Inc(Tile.NumMvFound);
    end;
  end;
end;

function InsideSuperblock64(Tile: TTileContext; DeltaRow, DeltaCol: Integer): Boolean;
var
  Row, Col: Integer;
begin
  Row := (Tile.MiRow and 15) + DeltaRow;
  Col := (Tile.MiCol and 15) + DeltaCol;
  Result := (Row >= 0) and (Row < 16) and (Col >= 0) and (Col < 16);
end;

procedure TemporalScan(var Search: TMvSearch);
var
  Tile: TTileContext;
  BlockWidth4, BlockHeight4, StepWidth4, StepHeight4, DeltaRow, DeltaCol, Index: Integer;
  SamplePositions: array[0..2, 0..1] of Integer;
begin
  Tile := Search.Tile;
  BlockWidth4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  BlockHeight4 := Num_4x4_Blocks_High[Tile.MiSize];
  if BlockWidth4 >= 16 then
    StepWidth4 := 4
  else
    StepWidth4 := 2;
  if BlockHeight4 >= 16 then
    StepHeight4 := 4
  else
    StepHeight4 := 2;
  DeltaRow := 0;
  while DeltaRow < Min(BlockHeight4, 16) do
  begin
    DeltaCol := 0;
    while DeltaCol < Min(BlockWidth4, 16) do
    begin
      AddTemporalCandidate(Search, DeltaRow, DeltaCol);
      Inc(DeltaCol, StepWidth4);
    end;
    Inc(DeltaRow, StepHeight4);
  end;
  if (BlockHeight4 >= Num_4x4_Blocks_High[BLOCK_8X8]) and (BlockHeight4 < Num_4x4_Blocks_High[BLOCK_64X64]) and
    (BlockWidth4 >= Num_4x4_Blocks_Wide[BLOCK_8X8]) and (BlockWidth4 < Num_4x4_Blocks_Wide[BLOCK_64X64]) then
  begin
    SamplePositions[0, 0] := BlockHeight4;
    SamplePositions[0, 1] := -2;
    SamplePositions[1, 0] := BlockHeight4;
    SamplePositions[1, 1] := BlockWidth4;
    SamplePositions[2, 0] := BlockHeight4 - 2;
    SamplePositions[2, 1] := BlockWidth4;
    for Index := 0 to 2 do
      if InsideSuperblock64(Tile, SamplePositions[Index, 0], SamplePositions[Index, 1]) then
        AddTemporalCandidate(Search, SamplePositions[Index, 0], SamplePositions[Index, 1]);
  end;
end;

end.
