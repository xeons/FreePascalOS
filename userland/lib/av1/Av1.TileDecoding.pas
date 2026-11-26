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
  One tile (specification sections 5.11.1 to 5.11.3, 5.11.57 and
  5.11.58 with the symbol decoder's initialization and exit): the
  contexts cleared, the superblocks in raster order with their CDEF and
  loop restoration syntax, and the CDFs saved at the end when this is
  the tile whose CDFs the next frames inherit.
}
unit Av1.TileDecoding;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.CdfContext, Av1.DefaultCdfs, Av1.SymbolDecoder,
  Av1.FrameContext, Av1.TileContext;

{ decode_tile( ) for tile TileNum over Size bytes at Data, after
  init_symbol; then exit_symbol (the CDFs saved into Frame.SavedCdfs
  when TileNum is context_update_tile_id). }
procedure DecodeTile(Tile: TTileContext; TileNum: Integer; Data: PByte; Size: Integer);
{ count_units_in_frame( unitSize, frameSize ). }
function CountUnitsInFrame(UnitSize, FrameSize: Integer): Integer;

implementation

uses
  Av1.BlockDecoding;

function CountUnitsInFrame(UnitSize, FrameSize: Integer): Integer;
begin
  Result := Max((FrameSize + (UnitSize shr 1)) div UnitSize, 1);
end;

procedure ClearAboveContext(Tile: TTileContext);
var
  Plane: Integer;
begin
  for Plane := 0 to 2 do
  begin
    FillChar(Tile.AboveLevelContext[Plane][0], Length(Tile.AboveLevelContext[Plane]) * SizeOf(Integer), 0);
    FillChar(Tile.AboveDcContext[Plane][0], Length(Tile.AboveDcContext[Plane]) * SizeOf(Integer), 0);
  end;
  FillChar(Tile.AboveSegPredContext[0], Length(Tile.AboveSegPredContext) * SizeOf(Integer), 0);
end;

procedure ClearLeftContext(Tile: TTileContext);
var
  Plane: Integer;
begin
  for Plane := 0 to 2 do
  begin
    FillChar(Tile.LeftLevelContext[Plane][0], Length(Tile.LeftLevelContext[Plane]) * SizeOf(Integer), 0);
    FillChar(Tile.LeftDcContext[Plane][0], Length(Tile.LeftDcContext[Plane]) * SizeOf(Integer), 0);
  end;
  FillChar(Tile.LeftSegPredContext[0], Length(Tile.LeftSegPredContext) * SizeOf(Integer), 0);
end;

procedure ClearBlockDecodedFlags(Tile: TTileContext; R, C, SbSize4: Integer);
var
  Plane, SubX, SubY, SbWidth4, SbHeight4, X, Y: Integer;
begin
  for Plane := 0 to Tile.Sequence^.NumPlanes - 1 do
  begin
    SubX := Tile.SubsamplingX(Plane);
    SubY := Tile.SubsamplingY(Plane);
    SbWidth4 := (Tile.MiColEnd - C) shr SubX;
    SbHeight4 := (Tile.MiRowEnd - R) shr SubY;
    for Y := -1 to SbSize4 shr SubY do
      for X := -1 to SbSize4 shr SubX do
      begin
        if (Y < 0) and (X < SbWidth4) then
          Tile.SetBlockDecoded(Plane, Y, X, True)
        else if (X < 0) and (Y < SbHeight4) then
          Tile.SetBlockDecoded(Plane, Y, X, True)
        else
          Tile.SetBlockDecoded(Plane, Y, X, False);
      end;
    Tile.SetBlockDecoded(Plane, SbSize4 shr SubY, -1, False);
  end;
end;

procedure ClearCdef(Tile: TTileContext; R, C: Integer);
var
  Frame: TFrameContext;
  CdefSize4: Integer;
begin
  Frame := Tile.Frame;
  Frame.CdefIdx[Frame.MiIndex(R, C)] := -1;
  if Tile.Sequence^.use_128x128_superblock then
  begin
    CdefSize4 := Num_4x4_Blocks_Wide[BLOCK_64X64];
    Frame.CdefIdx[Frame.MiIndex(R, C + CdefSize4)] := -1;
    Frame.CdefIdx[Frame.MiIndex(R + CdefSize4, C)] := -1;
    Frame.CdefIdx[Frame.MiIndex(R + CdefSize4, C + CdefSize4)] := -1;
  end;
end;

function InverseRecenter(R, V: Integer): Integer;
begin
  if V > 2 * R then
    Result := V
  else if (V and 1) <> 0 then
    Result := R - ((V + 1) shr 1)
  else
    Result := R + (V shr 1);
end;

function DecodeSubexpBool(Tile: TTileContext; NumSyms, K: Integer): Integer;
var
  Index, Mk, B2, A: Integer;
begin
  Index := 0;
  Mk := 0;
  while True do
  begin
    if Index <> 0 then
      B2 := K + Index - 1
    else
      B2 := K;
    A := 1 shl B2;
    if NumSyms <= Mk + 3 * A then
      Exit(ReadUniform(Tile.Symbols, NumSyms - Mk) + Mk)
    else if ReadLiteral(Tile.Symbols, 1) <> 0 then
    begin
      Inc(Index);
      Inc(Mk, A);
    end
    else
      Exit(ReadLiteral(Tile.Symbols, B2) + Mk);
  end;
end;

function DecodeSignedSubexpWithRefBool(Tile: TTileContext; Low, High, K, R: Integer): Integer;
var
  Mx, V: Integer;
begin
  Mx := High - Low;
  R := R - Low;
  V := DecodeSubexpBool(Tile, Mx, K);
  if (R shl 1) <= Mx then
    Result := InverseRecenter(R, V)
  else
    Result := Mx - 1 - InverseRecenter(Mx - 1 - R, V);
  Inc(Result, Low);
end;

const
  Wiener_Taps_Min: array[0..2] of Integer = (-5, -23, -17);
  Wiener_Taps_Max: array[0..2] of Integer = (10, 8, 46);
  Wiener_Taps_K: array[0..2] of Integer = (1, 2, 3);
  Sgrproj_Xqd_Min: array[0..1] of Integer = (-96, -32);
  Sgrproj_Xqd_Max: array[0..1] of Integer = (31, 95);

procedure ReadLrUnit(Tile: TTileContext; Plane, UnitRow, UnitCol: Integer);
var
  Frame: TFrameContext;
  RestorationUnit: PRestorationUnit;
  RestorationType, Pass, FirstCoeff, J, I, Radius, V, LrSgrSet: Integer;
begin
  Frame := Tile.Frame;
  RestorationUnit := @Frame.LrUnits[Plane][UnitRow * Frame.LrUnitCols[Plane] + UnitCol];
  case Tile.Header^.FrameRestorationType[Plane] of
    RESTORE_WIENER:
      if ReadSymbol(Tile.Symbols, @Tile.Cdf.UseWienerCdf, 2) <> 0 then
        RestorationType := RESTORE_WIENER
      else
        RestorationType := RESTORE_NONE;
    RESTORE_SGRPROJ:
      if ReadSymbol(Tile.Symbols, @Tile.Cdf.UseSgrprojCdf, 2) <> 0 then
        RestorationType := RESTORE_SGRPROJ
      else
        RestorationType := RESTORE_NONE;
  else
    RestorationType := ReadSymbol(Tile.Symbols, @Tile.Cdf.RestorationTypeCdf, RESTORE_SWITCHABLE);
  end;
  RestorationUnit^.RestorationType := RestorationType;
  if RestorationType = RESTORE_WIENER then
  begin
    for Pass := 0 to 1 do
    begin
      if Plane <> 0 then
      begin
        FirstCoeff := 1;
        RestorationUnit^.Wiener[Pass, 0] := 0;
      end
      else
        FirstCoeff := 0;
      for J := FirstCoeff to 2 do
      begin
        V := DecodeSignedSubexpWithRefBool(Tile, Wiener_Taps_Min[J], Wiener_Taps_Max[J] + 1, Wiener_Taps_K[J],
          Tile.RefLrWiener[Plane, Pass, J]);
        RestorationUnit^.Wiener[Pass, J] := V;
        Tile.RefLrWiener[Plane, Pass, J] := V;
      end;
    end;
  end
  else if RestorationType = RESTORE_SGRPROJ then
  begin
    LrSgrSet := ReadLiteral(Tile.Symbols, SGRPROJ_PARAMS_BITS);
    RestorationUnit^.SgrSet := LrSgrSet;
    for I := 0 to 1 do
    begin
      Radius := Sgr_Params[LrSgrSet, I * 2];
      if Radius <> 0 then
        V := DecodeSignedSubexpWithRefBool(Tile, Sgrproj_Xqd_Min[I], Sgrproj_Xqd_Max[I] + 1, SGRPROJ_PRJ_SUBEXP_K,
          Tile.RefSgrXqd[Plane, I])
      else
      begin
        V := 0;
        if I = 1 then
          V := Clip3(Sgrproj_Xqd_Min[I], Sgrproj_Xqd_Max[I], (1 shl SGRPROJ_PRJ_BITS) - Tile.RefSgrXqd[Plane, 0]);
      end;
      RestorationUnit^.SgrXqd[I] := V;
      Tile.RefSgrXqd[Plane, I] := V;
    end;
  end;
end;

procedure ReadLr(Tile: TTileContext; R, C, BSize: Integer);
var
  W, H, Plane, SubX, SubY, UnitSize, UnitRows, UnitCols, UnitRowStart, UnitRowEnd: Integer;
  Numerator, Denominator, UnitColStart, UnitColEnd, UnitRow, UnitCol: Integer;
begin
  if Tile.Header^.allow_intrabc then
    Exit;
  W := Num_4x4_Blocks_Wide[BSize];
  H := Num_4x4_Blocks_High[BSize];
  for Plane := 0 to Tile.Sequence^.NumPlanes - 1 do
    if Tile.Header^.FrameRestorationType[Plane] <> RESTORE_NONE then
    begin
      SubX := Tile.SubsamplingX(Plane);
      SubY := Tile.SubsamplingY(Plane);
      UnitSize := Tile.Header^.LoopRestorationSize[Plane];
      UnitRows := CountUnitsInFrame(UnitSize, Round2(Tile.Header^.FrameHeight, SubY));
      UnitCols := CountUnitsInFrame(UnitSize, Round2(Tile.Header^.UpscaledWidth, SubX));
      UnitRowStart := (R * (MI_SIZE shr SubY) + UnitSize - 1) div UnitSize;
      UnitRowEnd := Min(UnitRows, ((R + H) * (MI_SIZE shr SubY) + UnitSize - 1) div UnitSize);
      if Tile.Header^.use_superres then
      begin
        Numerator := (MI_SIZE shr SubX) * Tile.Header^.SuperresDenom;
        Denominator := UnitSize * SUPERRES_NUM;
      end
      else
      begin
        Numerator := MI_SIZE shr SubX;
        Denominator := UnitSize;
      end;
      UnitColStart := (C * Numerator + Denominator - 1) div Denominator;
      UnitColEnd := Min(UnitCols, ((C + W) * Numerator + Denominator - 1) div Denominator);
      for UnitRow := UnitRowStart to UnitRowEnd - 1 do
        for UnitCol := UnitColStart to UnitColEnd - 1 do
          ReadLrUnit(Tile, Plane, UnitRow, UnitCol);
    end;
end;

procedure DecodeTile(Tile: TTileContext; TileNum: Integer; Data: PByte; Size: Integer);
var
  Frame: TFrameContext;
  TileRow, TileCol, Plane, Pass, Index, SbSize, SbSize4, R, C: Integer;
begin
  Frame := Tile.Frame;
  Tile.TileNum := TileNum;
  TileRow := TileNum div Tile.Header^.TileCols;
  TileCol := TileNum mod Tile.Header^.TileCols;
  Tile.MiRowStart := Tile.Header^.MiRowStarts[TileRow];
  Tile.MiRowEnd := Tile.Header^.MiRowStarts[TileRow + 1];
  Tile.MiColStart := Tile.Header^.MiColStarts[TileCol];
  Tile.MiColEnd := Tile.Header^.MiColStarts[TileCol + 1];
  Tile.CurrentQIndex := Tile.Header^.base_q_idx;
  { init_symbol( sz ) }
  InitializeSymbolDecoder(Tile.Symbols, Data, Size, Tile.Header^.disable_cdf_update);
  Move(Default_Intra_Frame_Y_Mode_Cdf, Tile.IntraFrameYModeCdf, SizeOf(Tile.IntraFrameYModeCdf));
  Tile.Cdf := Frame.Cdfs;
  { decode_tile( ) }
  ClearAboveContext(Tile);
  for Index := 0 to FRAME_LF_COUNT - 1 do
    Tile.DeltaLF[Index] := 0;
  for Plane := 0 to Tile.Sequence^.NumPlanes - 1 do
    for Pass := 0 to 1 do
    begin
      Tile.RefSgrXqd[Plane, Pass] := Sgrproj_Xqd_Mid[Pass];
      for Index := 0 to WIENER_COEFFS - 1 do
        Tile.RefLrWiener[Plane, Pass, Index] := Wiener_Taps_Mid[Index];
    end;
  if Tile.Sequence^.use_128x128_superblock then
    SbSize := BLOCK_128X128
  else
    SbSize := BLOCK_64X64;
  SbSize4 := Num_4x4_Blocks_Wide[SbSize];
  R := Tile.MiRowStart;
  while R < Tile.MiRowEnd do
  begin
    ClearLeftContext(Tile);
    C := Tile.MiColStart;
    while C < Tile.MiColEnd do
    begin
      Tile.ReadDeltas := Tile.Header^.delta_q_present;
      ClearCdef(Tile, R, C);
      ClearBlockDecodedFlags(Tile, R, C, SbSize4);
      ReadLr(Tile, R, C, SbSize);
      DecodePartition(Tile, R, C, SbSize);
      Inc(C, SbSize4);
    end;
    Inc(R, SbSize4);
  end;
  { exit_symbol( ) }
  if (not Tile.Header^.disable_frame_end_update_cdf) and (TileNum = Tile.Header^.context_update_tile_id) then
    Frame.SavedCdfs := Tile.Cdf;
end;

end.
