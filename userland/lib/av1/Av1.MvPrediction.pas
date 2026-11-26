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
  The motion vector prediction processes (specification section 7.10):
  find_mv_stack, which builds the tile's RefStackMv / WeightStack /
  NumMvFound and the contexts NewMvContext, RefMvContext, ZeroMvContext
  and DrlCtxStack for the block being decoded; has_overlappable_candidates;
  and find_warp_samples (in Av1.WarpSamples, re-exported here).
}
unit Av1.MvPrediction;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.References, Av1.FrameContext, Av1.TileContext,
  Av1.MvCandidates, Av1.WarpSamples;

procedure FindMvStack(Tile: TTileContext; IsCompound: Boolean);
function HasOverlappableCandidates(Tile: TTileContext): Boolean;
{ The find warp samples process (7.10.4): NumSamples, NumSamplesScanned, CandList. }
procedure FindWarpSamples(Tile: TTileContext);

implementation

procedure FindWarpSamples(Tile: TTileContext);
begin
  Av1.WarpSamples.FindWarpSamples(Tile);
end;

{ The sorting process (7.10.2.11): a stable bubble sort by weight. }
procedure SortStack(Tile: TTileContext; Start, Finish: Integer; IsCompound: Boolean);
var
  NewFinish, Index, List, Weight: Integer;
  Swapped: TMotionVector;
begin
  while Finish > Start do
  begin
    NewFinish := Start;
    for Index := Start + 1 to Finish - 1 do
      if Tile.WeightStack[Index - 1] < Tile.WeightStack[Index] then
      begin
        Weight := Tile.WeightStack[Index - 1];
        Tile.WeightStack[Index - 1] := Tile.WeightStack[Index];
        Tile.WeightStack[Index] := Weight;
        for List := 0 to Ord(IsCompound) do
        begin
          Swapped := Tile.RefStackMv[Index - 1, List];
          Tile.RefStackMv[Index - 1, List] := Tile.RefStackMv[Index, List];
          Tile.RefStackMv[Index, List] := Swapped;
        end;
        NewFinish := Index;
      end;
    Finish := NewFinish;
  end;
end;

type
  TRefSignBias = array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;

  { RefIdMvs, RefDiffMvs and their counts of the extra search process. }
  TExtraCandidates = record
    RefIdCount, RefDiffCount: array[0..1] of Integer;
    RefIdMvs, RefDiffMvs: array[0..1, 0..1] of TMotionVector;
  end;

procedure NegateMv(var Vector: TMotionVector); inline;
begin
  Vector[0] := -Vector[0];
  Vector[1] := -Vector[1];
end;

{ The add extra MV candidate process (7.10.2.13). }
procedure AddExtraMvCandidate(Tile: TTileContext; var Extra: TExtraCandidates; MvRow, MvCol: Integer;
  IsCompound: Boolean);
var
  Candidate: PBlockInfo;
  CandList, CandRef, List, Index: Integer;
  CandMv: TMotionVector;
  SignBias: ^TRefSignBias;
begin
  Candidate := Tile.Frame.Block(MvRow, MvCol);
  SignBias := @Tile.Header^.RefFrameSignBias;
  for CandList := 0 to 1 do
  begin
    CandRef := Candidate^.RefFrame[CandList];
    if CandRef <= INTRA_FRAME then
      Continue;
    if IsCompound then
    begin
      for List := 0 to 1 do
      begin
        CandMv := Candidate^.Mv[CandList];
        if (CandRef = Tile.RefFrame[List]) and (Extra.RefIdCount[List] < 2) then
        begin
          Extra.RefIdMvs[List, Extra.RefIdCount[List]] := CandMv;
          Inc(Extra.RefIdCount[List]);
        end
        else if Extra.RefDiffCount[List] < 2 then
        begin
          if SignBias^[CandRef] <> SignBias^[Tile.RefFrame[List]] then
            NegateMv(CandMv);
          Extra.RefDiffMvs[List, Extra.RefDiffCount[List]] := CandMv;
          Inc(Extra.RefDiffCount[List]);
        end;
      end;
    end
    else
    begin
      CandMv := Candidate^.Mv[CandList];
      if SignBias^[CandRef] <> SignBias^[Tile.RefFrame[0]] then
        NegateMv(CandMv);
      Index := 0;
      while Index < Tile.NumMvFound do
      begin
        if (CandMv[0] = Tile.RefStackMv[Index, 0][0]) and (CandMv[1] = Tile.RefStackMv[Index, 0][1]) then
          Break;
        Inc(Index);
      end;
      if Index = Tile.NumMvFound then
      begin
        Tile.RefStackMv[Index, 0] := CandMv;
        Tile.WeightStack[Index] := 2;
        Inc(Tile.NumMvFound);
      end;
    end;
  end;
end;

{ The extra search process (7.10.2.12). }
procedure ExtraSearch(Tile: TTileContext; IsCompound: Boolean);
var
  Extra: TExtraCandidates;
  Width4, Height4, Count4, Pass, Index, MvRow, MvCol, List, CompCount: Integer;
  CombinedMvs: array[0..1, 0..1] of TMotionVector;
begin
  FillChar(Extra, SizeOf(Extra), 0);
  Width4 := Min(16, Num_4x4_Blocks_Wide[Tile.MiSize]);
  Height4 := Min(16, Num_4x4_Blocks_High[Tile.MiSize]);
  Width4 := Min(Width4, Tile.Header^.MiCols - Tile.MiCol);
  Height4 := Min(Height4, Tile.Header^.MiRows - Tile.MiRow);
  Count4 := Min(Width4, Height4);
  for Pass := 0 to 1 do
  begin
    Index := 0;
    while (Index < Count4) and (Tile.NumMvFound < 2) do
    begin
      if Pass = 0 then
      begin
        MvRow := Tile.MiRow - 1;
        MvCol := Tile.MiCol + Index;
      end
      else
      begin
        MvRow := Tile.MiRow + Index;
        MvCol := Tile.MiCol - 1;
      end;
      if not Tile.IsInside(MvRow, MvCol) then
        Break;
      AddExtraMvCandidate(Tile, Extra, MvRow, MvCol, IsCompound);
      if Pass = 0 then
        Inc(Index, Num_4x4_Blocks_Wide[Tile.Frame.Block(MvRow, MvCol)^.MiSize])
      else
        Inc(Index, Num_4x4_Blocks_High[Tile.Frame.Block(MvRow, MvCol)^.MiSize]);
    end;
  end;
  if IsCompound then
  begin
    for List := 0 to 1 do
    begin
      CompCount := 0;
      for Index := 0 to Extra.RefIdCount[List] - 1 do
      begin
        CombinedMvs[CompCount, List] := Extra.RefIdMvs[List, Index];
        Inc(CompCount);
      end;
      Index := 0;
      while (Index < Extra.RefDiffCount[List]) and (CompCount < 2) do
      begin
        CombinedMvs[CompCount, List] := Extra.RefDiffMvs[List, Index];
        Inc(CompCount);
        Inc(Index);
      end;
      while CompCount < 2 do
      begin
        CombinedMvs[CompCount, List] := Tile.GlobalMvs[List];
        Inc(CompCount);
      end;
    end;
    if Tile.NumMvFound = 1 then
    begin
      if (CombinedMvs[0, 0][0] = Tile.RefStackMv[0, 0][0]) and (CombinedMvs[0, 0][1] = Tile.RefStackMv[0, 0][1]) and
        (CombinedMvs[0, 1][0] = Tile.RefStackMv[0, 1][0]) and (CombinedMvs[0, 1][1] = Tile.RefStackMv[0, 1][1]) then
      begin
        Tile.RefStackMv[Tile.NumMvFound, 0] := CombinedMvs[1, 0];
        Tile.RefStackMv[Tile.NumMvFound, 1] := CombinedMvs[1, 1];
      end
      else
      begin
        Tile.RefStackMv[Tile.NumMvFound, 0] := CombinedMvs[0, 0];
        Tile.RefStackMv[Tile.NumMvFound, 1] := CombinedMvs[0, 1];
      end;
      Tile.WeightStack[Tile.NumMvFound] := 2;
      Inc(Tile.NumMvFound);
    end
    else
      for Index := 0 to 1 do
      begin
        Tile.RefStackMv[Tile.NumMvFound, 0] := CombinedMvs[Index, 0];
        Tile.RefStackMv[Tile.NumMvFound, 1] := CombinedMvs[Index, 1];
        Tile.WeightStack[Tile.NumMvFound] := 2;
        Inc(Tile.NumMvFound);
      end;
  end
  else
    for Index := Tile.NumMvFound to 1 do
      Tile.RefStackMv[Index, 0] := Tile.GlobalMvs[0];
end;

function ClampMvRow(Tile: TTileContext; Value, Border: Integer): Integer;
var
  ToTopEdge, ToBottomEdge: Integer;
begin
  ToTopEdge := -((Tile.MiRow * MI_SIZE) * 8);
  ToBottomEdge := ((Tile.Header^.MiRows - Num_4x4_Blocks_High[Tile.MiSize] - Tile.MiRow) * MI_SIZE) * 8;
  Result := Clip3(ToTopEdge - Border, ToBottomEdge + Border, Value);
end;

function ClampMvCol(Tile: TTileContext; Value, Border: Integer): Integer;
var
  ToLeftEdge, ToRightEdge: Integer;
begin
  ToLeftEdge := -((Tile.MiCol * MI_SIZE) * 8);
  ToRightEdge := ((Tile.Header^.MiCols - Num_4x4_Blocks_Wide[Tile.MiSize] - Tile.MiCol) * MI_SIZE) * 8;
  Result := Clip3(ToLeftEdge - Border, ToRightEdge + Border, Value);
end;

{ The context and clamping process (7.10.2.14). }
procedure SetContextsAndClamp(Tile: TTileContext; IsCompound: Boolean; NumNew, CloseMatches,
  TotalMatches: Integer);
var
  Index, Context, List: Integer;
begin
  for Index := 0 to Tile.NumMvFound - 1 do
  begin
    Context := 0;
    if Index + 1 < Tile.NumMvFound then
    begin
      if Tile.WeightStack[Index] >= REF_CAT_LEVEL then
      begin
        if Tile.WeightStack[Index + 1] < REF_CAT_LEVEL then
          Context := 1;
      end
      else
        Context := 2;
    end;
    Tile.DrlCtxStack[Index] := Context;
  end;
  for List := 0 to Ord(IsCompound) do
    for Index := 0 to Tile.NumMvFound - 1 do
    begin
      Tile.RefStackMv[Index, List][0] := ClampMvRow(Tile, Tile.RefStackMv[Index, List][0],
        MV_BORDER + Block_Height(Tile.MiSize) * 8);
      Tile.RefStackMv[Index, List][1] := ClampMvCol(Tile, Tile.RefStackMv[Index, List][1],
        MV_BORDER + Block_Width(Tile.MiSize) * 8);
    end;
  if CloseMatches = 0 then
  begin
    Tile.NewMvContext := Min(TotalMatches, 1);
    Tile.RefMvContext := TotalMatches;
  end
  else if CloseMatches = 1 then
  begin
    Tile.NewMvContext := 3 - Min(NumNew, 1);
    Tile.RefMvContext := 2 + TotalMatches;
  end
  else
  begin
    Tile.NewMvContext := 5 - Min(NumNew, 1);
    Tile.RefMvContext := 5;
  end;
end;

procedure FindMvStack(Tile: TTileContext; IsCompound: Boolean);
var
  Search: TMvSearch;
  BlockWidth4, BlockHeight4, Index, NumNearest, NumNew, CloseMatches, TotalMatches: Integer;
  FoundAboveMatch, FoundLeftMatch: Boolean;
begin
  BlockWidth4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  BlockHeight4 := Num_4x4_Blocks_High[Tile.MiSize];
  Search.Tile := Tile;
  Search.IsCompound := IsCompound;
  Tile.NumMvFound := 0;
  Tile.NewMvCount := 0;
  Tile.GlobalMvs[0] := SetupGlobalMv(Tile, 0);
  if IsCompound then
    Tile.GlobalMvs[1] := SetupGlobalMv(Tile, 1);
  Search.FoundMatch := False;
  ScanRow(Search, -1);
  FoundAboveMatch := Search.FoundMatch;
  Search.FoundMatch := False;
  ScanCol(Search, -1);
  FoundLeftMatch := Search.FoundMatch;
  Search.FoundMatch := False;
  if Max(BlockWidth4, BlockHeight4) <= 16 then
    ScanPoint(Search, -1, BlockWidth4);
  if Search.FoundMatch then
    FoundAboveMatch := True;
  CloseMatches := Ord(FoundAboveMatch) + Ord(FoundLeftMatch);
  NumNearest := Tile.NumMvFound;
  NumNew := Tile.NewMvCount;
  for Index := 0 to NumNearest - 1 do
    Inc(Tile.WeightStack[Index], REF_CAT_LEVEL);
  Tile.ZeroMvContext := 0;
  if Tile.Header^.use_ref_frame_mvs then
    TemporalScan(Search);
  ScanPoint(Search, -1, -1);
  if Search.FoundMatch then
    FoundAboveMatch := True;
  Search.FoundMatch := False;
  ScanRow(Search, -3);
  if Search.FoundMatch then
    FoundAboveMatch := True;
  Search.FoundMatch := False;
  ScanCol(Search, -3);
  if Search.FoundMatch then
    FoundLeftMatch := True;
  Search.FoundMatch := False;
  if BlockHeight4 > 1 then
    ScanRow(Search, -5);
  if Search.FoundMatch then
    FoundAboveMatch := True;
  Search.FoundMatch := False;
  if BlockWidth4 > 1 then
    ScanCol(Search, -5);
  if Search.FoundMatch then
    FoundLeftMatch := True;
  TotalMatches := Ord(FoundAboveMatch) + Ord(FoundLeftMatch);
  SortStack(Tile, 0, NumNearest, IsCompound);
  SortStack(Tile, NumNearest, Tile.NumMvFound, IsCompound);
  if Tile.NumMvFound < 2 then
    ExtraSearch(Tile, IsCompound);
  SetContextsAndClamp(Tile, IsCompound, NumNew, CloseMatches, TotalMatches);
end;

function HasOverlappableCandidates(Tile: TTileContext): Boolean;
var
  Position, Limit: Integer;
begin
  if Tile.AvailU then
  begin
    Limit := Min(Tile.Header^.MiCols, Tile.MiCol + Num_4x4_Blocks_Wide[Tile.MiSize]);
    Position := Tile.MiCol;
    while Position < Limit do
    begin
      if Tile.Frame.Block(Tile.MiRow - 1, Position or 1)^.RefFrame[0] > INTRA_FRAME then
        Exit(True);
      Inc(Position, 2);
    end;
  end;
  if Tile.AvailL then
  begin
    Limit := Min(Tile.Header^.MiRows, Tile.MiRow + Num_4x4_Blocks_High[Tile.MiSize]);
    Position := Tile.MiRow;
    while Position < Limit do
    begin
      if Tile.Frame.Block(Position or 1, Tile.MiCol - 1)^.RefFrame[0] > INTRA_FRAME then
        Exit(True);
      Inc(Position, 2);
    end;
  end;
  Result := False;
end;

end.
