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
  The motion vectors of a block (specification sections 5.11.26,
  5.11.31 and 5.11.32: assign_mv, read_mv, read_mv_component): taken
  from the candidate stack, global motion, or the stack plus a coded
  difference.
}
unit Av1.MotionVectorSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.TileContext;

{ get_mode( refList ): the single reference mode of a list of the block's YMode. }
function GetMode(Tile: TTileContext; RefList: Integer): Integer;
procedure AssignMv(Tile: TTileContext; IsCompound: Boolean);

implementation

function GetMode(Tile: TTileContext; RefList: Integer): Integer;
var
  Mode: Integer;
begin
  Mode := Tile.YMode;
  if RefList = 0 then
  begin
    if Mode < NEAREST_NEARESTMV then
      Result := Mode
    else if (Mode = NEW_NEWMV) or (Mode = NEW_NEARESTMV) or (Mode = NEW_NEARMV) then
      Result := NEWMV
    else if (Mode = NEAREST_NEARESTMV) or (Mode = NEAREST_NEWMV) then
      Result := NEARESTMV
    else if (Mode = NEAR_NEARMV) or (Mode = NEAR_NEWMV) then
      Result := NEARMV
    else
      Result := GLOBALMV;
  end
  else
  begin
    if (Mode = NEW_NEWMV) or (Mode = NEAREST_NEWMV) or (Mode = NEAR_NEWMV) then
      Result := NEWMV
    else if (Mode = NEAREST_NEARESTMV) or (Mode = NEW_NEARESTMV) then
      Result := NEARESTMV
    else if (Mode = NEAR_NEARMV) or (Mode = NEW_NEARMV) then
      Result := NEARMV
    else
      Result := GLOBALMV;
  end;
end;

function ReadMvComponent(Tile: TTileContext; MvCtx, Comp: Integer): Integer;
var
  Sign, MvClass, Class0Bit, Fraction, HighPrecision, Magnitude, D, Index: Integer;
begin
  Sign := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvSignCdf[MvCtx, Comp], 2);
  MvClass := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvClassCdf[MvCtx, Comp], MV_CLASSES);
  if MvClass = MV_CLASS_0 then
  begin
    Class0Bit := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvClass0BitCdf[MvCtx, Comp], 2);
    if Tile.Header^.force_integer_mv <> 0 then
      Fraction := 3
    else
      Fraction := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvClass0FrCdf[MvCtx, Comp, Class0Bit], MV_JOINTS);
    if Tile.Header^.allow_high_precision_mv then
      HighPrecision := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvClass0HpCdf[MvCtx, Comp], 2)
    else
      HighPrecision := 1;
    Magnitude := ((Class0Bit shl 3) or (Fraction shl 1) or HighPrecision) + 1;
  end
  else
  begin
    D := 0;
    for Index := 0 to MvClass - 1 do
      D := D or (ReadSymbol(Tile.Symbols, @Tile.Cdf.MvBitCdf[MvCtx, Comp, Index], 2) shl Index);
    Magnitude := CLASS0_SIZE shl (MvClass + 2);
    if Tile.Header^.force_integer_mv <> 0 then
      Fraction := 3
    else
      Fraction := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvFrCdf[MvCtx, Comp], MV_JOINTS);
    if Tile.Header^.allow_high_precision_mv then
      HighPrecision := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvHpCdf[MvCtx, Comp], 2)
    else
      HighPrecision := 1;
    Inc(Magnitude, ((D shl 3) or (Fraction shl 1) or HighPrecision) + 1);
  end;
  if Sign <> 0 then
    Result := -Magnitude
  else
    Result := Magnitude;
end;

procedure ReadMv(Tile: TTileContext; Ref: Integer);
var
  MvCtx, MvJoint: Integer;
  DiffMv: array[0..1] of Integer;
begin
  DiffMv[0] := 0;
  DiffMv[1] := 0;
  if Tile.use_intrabc then
    MvCtx := MV_INTRABC_CONTEXT
  else
    MvCtx := 0;
  MvJoint := ReadSymbol(Tile.Symbols, @Tile.Cdf.MvJointCdf[MvCtx], MV_JOINTS);
  if (MvJoint = MV_JOINT_HZVNZ) or (MvJoint = MV_JOINT_HNZVNZ) then
    DiffMv[0] := ReadMvComponent(Tile, MvCtx, 0);
  if (MvJoint = MV_JOINT_HNZVZ) or (MvJoint = MV_JOINT_HNZVNZ) then
    DiffMv[1] := ReadMvComponent(Tile, MvCtx, 1);
  Tile.Mv[Ref][0] := Tile.PredMv[Ref][0] + DiffMv[0];
  Tile.Mv[Ref][1] := Tile.PredMv[Ref][1] + DiffMv[1];
end;

procedure AssignMv(Tile: TTileContext; IsCompound: Boolean);
var
  Index, CompMode, Position, SbSize4: Integer;
begin
  for Index := 0 to Ord(IsCompound) do
  begin
    if Tile.use_intrabc then
      CompMode := NEWMV
    else
      CompMode := GetMode(Tile, Index);
    if Tile.use_intrabc then
    begin
      Tile.PredMv[0] := Tile.RefStackMv[0, 0];
      if (Tile.PredMv[0][0] = 0) and (Tile.PredMv[0][1] = 0) then
        Tile.PredMv[0] := Tile.RefStackMv[1, 0];
      if (Tile.PredMv[0][0] = 0) and (Tile.PredMv[0][1] = 0) then
      begin
        if Tile.Sequence^.use_128x128_superblock then
          SbSize4 := Num_4x4_Blocks_High[BLOCK_128X128]
        else
          SbSize4 := Num_4x4_Blocks_High[BLOCK_64X64];
        if Tile.MiRow - SbSize4 < Tile.MiRowStart then
        begin
          Tile.PredMv[0][0] := 0;
          Tile.PredMv[0][1] := -(SbSize4 * MI_SIZE + INTRABC_DELAY_PIXELS) * 8;
        end
        else
        begin
          Tile.PredMv[0][0] := -(SbSize4 * MI_SIZE * 8);
          Tile.PredMv[0][1] := 0;
        end;
      end;
    end
    else if CompMode = GLOBALMV then
      Tile.PredMv[Index] := Tile.GlobalMvs[Index]
    else
    begin
      if CompMode = NEARESTMV then
        Position := 0
      else
        Position := Tile.RefMvIdx;
      if (CompMode = NEWMV) and (Tile.NumMvFound <= 1) then
        Position := 0;
      Tile.PredMv[Index] := Tile.RefStackMv[Position, Index];
    end;
    if CompMode = NEWMV then
      ReadMv(Tile, Index)
    else
      Tile.Mv[Index] := Tile.PredMv[Index];
  end;
end;

end.
