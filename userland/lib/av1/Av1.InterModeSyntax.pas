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
  The prediction of an inter block (specification sections 5.11.23 and
  5.11.27 to 5.11.30: inter_block_mode_info, read_motion_mode,
  read_interintra_mode, read_compound_type) with their contexts.
}
unit Av1.InterModeSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

procedure ReadInterBlockModeInfo(Tile: TTileContext);

implementation

uses
  Av1.ReferenceFrameSyntax, Av1.MotionVectorSyntax, Av1.MvPrediction, Av1.MotionVectorScaling;

const
  Compound_Mode_Ctx_Map: array[0..2, 0..COMP_NEWMV_CTXS - 1] of Integer =
    ((0, 1, 1, 1, 1), (1, 2, 3, 4, 4), (4, 4, 5, 6, 7));

function HasNearMv(Tile: TTileContext): Boolean;
begin
  Result := (Tile.YMode = NEARMV) or (Tile.YMode = NEAR_NEARMV) or (Tile.YMode = NEAR_NEWMV) or
    (Tile.YMode = NEW_NEARMV);
end;

function NeedsInterpFilter(Tile: TTileContext): Boolean;
var
  Large: Boolean;
begin
  Large := Min(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)) >= 8;
  if Tile.skip_mode or (Tile.motion_mode = LOCALWARP) then
    Result := False
  else if Large and (Tile.YMode = GLOBALMV) then
    Result := Tile.Header^.GmType[Tile.RefFrame[0]] = TRANSLATION
  else if Large and (Tile.YMode = GLOBAL_GLOBALMV) then
    Result := (Tile.Header^.GmType[Tile.RefFrame[0]] = TRANSLATION) or
      (Tile.Header^.GmType[Tile.RefFrame[1]] = TRANSLATION)
  else
    Result := True;
end;

procedure ReadYMode(Tile: TTileContext; IsCompound: Boolean);
var
  Context: Integer;
begin
  if Tile.skip_mode then
    Tile.YMode := NEAREST_NEARESTMV
  else if Tile.SegmentFeatureActive(SEG_LVL_SKIP) or Tile.SegmentFeatureActive(SEG_LVL_GLOBALMV) then
    Tile.YMode := GLOBALMV
  else if IsCompound then
  begin
    Context := Compound_Mode_Ctx_Map[Tile.RefMvContext shr 1, Min(Tile.NewMvContext, COMP_NEWMV_CTXS - 1)];
    Tile.YMode := NEAREST_NEARESTMV + ReadSymbol(Tile.Symbols, @Tile.Cdf.CompoundModeCdf[Context], COMPOUND_MODES);
  end
  else if ReadSymbol(Tile.Symbols, @Tile.Cdf.NewMvCdf[Tile.NewMvContext], 2) = 0 then
    Tile.YMode := NEWMV
  else if ReadSymbol(Tile.Symbols, @Tile.Cdf.ZeroMvCdf[Tile.ZeroMvContext], 2) = 0 then
    Tile.YMode := GLOBALMV
  else if ReadSymbol(Tile.Symbols, @Tile.Cdf.RefMvCdf[Tile.RefMvContext], 2) = 0 then
    Tile.YMode := NEARESTMV
  else
    Tile.YMode := NEARMV;
end;

procedure ReadRefMvIdx(Tile: TTileContext);
var
  Index: Integer;
begin
  Tile.RefMvIdx := 0;
  if (Tile.YMode = NEWMV) or (Tile.YMode = NEW_NEWMV) then
  begin
    for Index := 0 to 1 do
      if Tile.NumMvFound > Index + 1 then
      begin
        if ReadSymbol(Tile.Symbols, @Tile.Cdf.DrlModeCdf[Tile.DrlCtxStack[Index]], 2) = 0 then
        begin
          Tile.RefMvIdx := Index;
          Break;
        end;
        Tile.RefMvIdx := Index + 1;
      end;
  end
  else if HasNearMv(Tile) then
  begin
    Tile.RefMvIdx := 1;
    for Index := 1 to 2 do
      if Tile.NumMvFound > Index + 1 then
      begin
        if ReadSymbol(Tile.Symbols, @Tile.Cdf.DrlModeCdf[Tile.DrlCtxStack[Index]], 2) = 0 then
        begin
          Tile.RefMvIdx := Index;
          Break;
        end;
        Tile.RefMvIdx := Index + 1;
      end;
  end;
end;

procedure ReadInterIntraMode(Tile: TTileContext; IsCompound: Boolean);
var
  Context: Integer;
begin
  if (not Tile.skip_mode) and Tile.Sequence^.enable_interintra_compound and (not IsCompound) and
    (Tile.MiSize >= BLOCK_8X8) and (Tile.MiSize <= BLOCK_32X32) then
  begin
    Context := Size_Group[Tile.MiSize] - 1;
    Tile.interintra := ReadSymbol(Tile.Symbols, @Tile.Cdf.InterIntraCdf[Context], 2) <> 0;
    if Tile.interintra then
    begin
      Tile.interintra_mode := ReadSymbol(Tile.Symbols, @Tile.Cdf.InterIntraModeCdf[Context], INTERINTRA_MODES);
      Tile.RefFrame[1] := INTRA_FRAME;
      Tile.AngleDeltaY := 0;
      Tile.AngleDeltaUV := 0;
      Tile.use_filter_intra := False;
      Tile.wedge_interintra := ReadSymbol(Tile.Symbols, @Tile.Cdf.WedgeInterIntraCdf[Tile.MiSize], 2) <> 0;
      if Tile.wedge_interintra then
      begin
        Tile.wedge_index := ReadSymbol(Tile.Symbols, @Tile.Cdf.WedgeIndexCdf[Tile.MiSize], 16);
        Tile.wedge_sign := 0;
      end;
    end;
  end
  else
    Tile.interintra := False;
end;

procedure ReadMotionMode(Tile: TTileContext; IsCompound: Boolean);
begin
  Tile.motion_mode := SIMPLE;
  if Tile.skip_mode then
    Exit;
  if not Tile.Header^.is_motion_mode_switchable then
    Exit;
  if Min(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)) < 8 then
    Exit;
  if (Tile.Header^.force_integer_mv = 0) and ((Tile.YMode = GLOBALMV) or (Tile.YMode = GLOBAL_GLOBALMV)) then
    if Tile.Header^.GmType[Tile.RefFrame[0]] > TRANSLATION then
      Exit;
  if IsCompound or (Tile.RefFrame[1] = INTRA_FRAME) or not HasOverlappableCandidates(Tile) then
    Exit;
  FindWarpSamples(Tile);
  if (Tile.Header^.force_integer_mv <> 0) or (Tile.NumSamples = 0) or (not Tile.Header^.allow_warped_motion) or
    IsScaled(Tile, Tile.RefFrame[0]) then
  begin
    if ReadSymbol(Tile.Symbols, @Tile.Cdf.UseObmcCdf[Tile.MiSize], 2) <> 0 then
      Tile.motion_mode := OBMC;
  end
  else
    Tile.motion_mode := ReadSymbol(Tile.Symbols, @Tile.Cdf.MotionModeCdf[Tile.MiSize], MOTION_MODES);
end;

function CompGroupIdxContext(Tile: TTileContext): Integer;
var
  Frame: TFrameContext;
begin
  Frame := Tile.Frame;
  Result := 0;
  if Tile.AvailU then
  begin
    if not Tile.AboveSingle then
      Inc(Result, Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.CompGroupIdx)
    else if Tile.AboveRefFrame[0] = ALTREF_FRAME then
      Inc(Result, 3);
  end;
  if Tile.AvailL then
  begin
    if not Tile.LeftSingle then
      Inc(Result, Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.CompGroupIdx)
    else if Tile.LeftRefFrame[0] = ALTREF_FRAME then
      Inc(Result, 3);
  end;
  Result := Min(5, Result);
end;

function CompoundIdxContext(Tile: TTileContext): Integer;
var
  Frame: TFrameContext;
  Forward, Backward: Integer;
begin
  Frame := Tile.Frame;
  Forward := Abs(Frame.GetRelativeDist(Tile.Header^.OrderHints[Tile.RefFrame[0]], Tile.Header^.OrderHint));
  Backward := Abs(Frame.GetRelativeDist(Tile.Header^.OrderHints[Tile.RefFrame[1]], Tile.Header^.OrderHint));
  if Forward = Backward then
    Result := 3
  else
    Result := 0;
  if Tile.AvailU then
  begin
    if not Tile.AboveSingle then
      Inc(Result, Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.CompoundIdx)
    else if Tile.AboveRefFrame[0] = ALTREF_FRAME then
      Inc(Result);
  end;
  if Tile.AvailL then
  begin
    if not Tile.LeftSingle then
      Inc(Result, Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.CompoundIdx)
    else if Tile.LeftRefFrame[0] = ALTREF_FRAME then
      Inc(Result);
  end;
end;

procedure ReadCompoundType(Tile: TTileContext; IsCompound: Boolean);
var
  N: Integer;
begin
  Tile.comp_group_idx := 0;
  Tile.compound_idx := 1;
  if Tile.skip_mode then
  begin
    Tile.compound_type := COMPOUND_AVERAGE;
    Exit;
  end;
  if IsCompound then
  begin
    N := Wedge_Bits[Tile.MiSize];
    if Tile.Sequence^.enable_masked_compound then
      Tile.comp_group_idx := ReadSymbol(Tile.Symbols, @Tile.Cdf.CompGroupIdxCdf[CompGroupIdxContext(Tile)], 2);
    if Tile.comp_group_idx = 0 then
    begin
      if Tile.Sequence^.enable_jnt_comp then
      begin
        Tile.compound_idx := ReadSymbol(Tile.Symbols, @Tile.Cdf.CompoundIdxCdf[CompoundIdxContext(Tile)], 2);
        if Tile.compound_idx <> 0 then
          Tile.compound_type := COMPOUND_AVERAGE
        else
          Tile.compound_type := COMPOUND_DISTANCE;
      end
      else
        Tile.compound_type := COMPOUND_AVERAGE;
    end
    else if N = 0 then
      Tile.compound_type := COMPOUND_DIFFWTD
    else
      Tile.compound_type := ReadSymbol(Tile.Symbols, @Tile.Cdf.CompoundTypeCdf[Tile.MiSize], COMPOUND_TYPES);
    if Tile.compound_type = COMPOUND_WEDGE then
    begin
      Tile.wedge_index := ReadSymbol(Tile.Symbols, @Tile.Cdf.WedgeIndexCdf[Tile.MiSize], 16);
      Tile.wedge_sign := ReadLiteral(Tile.Symbols, 1);
    end
    else if Tile.compound_type = COMPOUND_DIFFWTD then
      Tile.mask_type := ReadLiteral(Tile.Symbols, 1);
  end
  else if Tile.interintra then
  begin
    if Tile.wedge_interintra then
      Tile.compound_type := COMPOUND_WEDGE
    else
      Tile.compound_type := COMPOUND_INTRA;
  end
  else
    Tile.compound_type := COMPOUND_AVERAGE;
end;

function InterpFilterContext(Tile: TTileContext; Direction: Integer): Integer;
var
  Frame: TFrameContext;
  LeftType, AboveType: Integer;
  Neighbour: PBlockInfo;
begin
  Frame := Tile.Frame;
  Result := ((Direction and 1) * 2 + Ord(Tile.RefFrame[1] > INTRA_FRAME)) * 4;
  LeftType := 3;
  AboveType := 3;
  if Tile.AvailL then
  begin
    Neighbour := Frame.Block(Tile.MiRow, Tile.MiCol - 1);
    if (Neighbour^.RefFrame[0] = Tile.RefFrame[0]) or (Neighbour^.RefFrame[1] = Tile.RefFrame[0]) then
      LeftType := Neighbour^.InterpFilter[Direction];
  end;
  if Tile.AvailU then
  begin
    Neighbour := Frame.Block(Tile.MiRow - 1, Tile.MiCol);
    if (Neighbour^.RefFrame[0] = Tile.RefFrame[0]) or (Neighbour^.RefFrame[1] = Tile.RefFrame[0]) then
      AboveType := Neighbour^.InterpFilter[Direction];
  end;
  if LeftType = AboveType then
    Inc(Result, LeftType)
  else if LeftType = 3 then
    Inc(Result, AboveType)
  else if AboveType = 3 then
    Inc(Result, LeftType)
  else
    Inc(Result, 3);
end;

procedure ReadInterpFilters(Tile: TTileContext);
var
  Direction, Directions: Integer;
begin
  if Tile.Header^.interpolation_filter = SWITCHABLE then
  begin
    if Tile.Sequence^.enable_dual_filter then
      Directions := 2
    else
      Directions := 1;
    for Direction := 0 to Directions - 1 do
      if NeedsInterpFilter(Tile) then
        Tile.interp_filter[Direction] := ReadSymbol(Tile.Symbols,
          @Tile.Cdf.InterpFilterCdf[InterpFilterContext(Tile, Direction)], INTERP_FILTERS)
      else
        Tile.interp_filter[Direction] := EIGHTTAP;
    if not Tile.Sequence^.enable_dual_filter then
      Tile.interp_filter[1] := Tile.interp_filter[0];
  end
  else
  begin
    Tile.interp_filter[0] := Tile.Header^.interpolation_filter;
    Tile.interp_filter[1] := Tile.Header^.interpolation_filter;
  end;
end;

procedure ReadInterBlockModeInfo(Tile: TTileContext);
var
  IsCompound: Boolean;
begin
  Tile.PaletteSizeY := 0;
  Tile.PaletteSizeUV := 0;
  ReadRefFrames(Tile);
  IsCompound := Tile.RefFrame[1] > INTRA_FRAME;
  FindMvStack(Tile, IsCompound);
  ReadYMode(Tile, IsCompound);
  ReadRefMvIdx(Tile);
  AssignMv(Tile, IsCompound);
  ReadInterIntraMode(Tile, IsCompound);
  ReadMotionMode(Tile, IsCompound);
  ReadCompoundType(Tile, IsCompound);
  ReadInterpFilters(Tile);
end;

end.
