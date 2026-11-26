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
  The intra prediction modes of a block (specification sections
  5.11.7, 5.11.22, 5.11.24, 5.11.42 to 5.11.45): the luma and chroma
  modes, angle deltas, chroma from luma alphas and filter intra, for
  blocks of intra frames and intra blocks of inter frames.
}
unit Av1.IntraModeSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

{ intra_frame_y_mode, or y_mode in inter frames, then the rest of the
  intra modes (intra_angle_info_y, uv_mode, CfL alphas, angle info uv,
  palette_mode_info, filter_intra_mode_info). }
procedure ReadIntraModes(Tile: TTileContext; IntraFrame: Boolean);
function IsDirectionalMode(Mode: Integer): Boolean; inline;

implementation

uses
  Av1.PaletteSyntax;

const
  Intra_Mode_Context: array[0..INTRA_MODES - 1] of Integer = (0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0);

function IsDirectionalMode(Mode: Integer): Boolean;
begin
  Result := (Mode >= V_PRED) and (Mode <= D67_PRED);
end;

procedure ReadIntraAngleInfoY(Tile: TTileContext);
begin
  Tile.AngleDeltaY := 0;
  if (Tile.MiSize >= BLOCK_8X8) and IsDirectionalMode(Tile.YMode) then
    Tile.AngleDeltaY := ReadSymbol(Tile.Symbols, @Tile.Cdf.AngleDeltaCdf[Tile.YMode - V_PRED],
      2 * MAX_ANGLE_DELTA + 1) - MAX_ANGLE_DELTA;
end;

procedure ReadIntraAngleInfoUv(Tile: TTileContext);
begin
  Tile.AngleDeltaUV := 0;
  if (Tile.MiSize >= BLOCK_8X8) and IsDirectionalMode(Tile.UVMode) then
    Tile.AngleDeltaUV := ReadSymbol(Tile.Symbols, @Tile.Cdf.AngleDeltaCdf[Tile.UVMode - V_PRED],
      2 * MAX_ANGLE_DELTA + 1) - MAX_ANGLE_DELTA;
end;

procedure ReadCflAlphas(Tile: TTileContext);
var
  Signs, SignU, SignV: Integer;
begin
  Signs := ReadSymbol(Tile.Symbols, @Tile.Cdf.CflSignCdf, CFL_JOINT_SIGNS);
  SignU := (Signs + 1) div 3;
  SignV := (Signs + 1) mod 3;
  if SignU <> CFL_SIGN_ZERO then
  begin
    Tile.CflAlphaU := 1 + ReadSymbol(Tile.Symbols, @Tile.Cdf.CflAlphaCdf[(SignU - 1) * 3 + SignV], CFL_ALPHABET_SIZE);
    if SignU = CFL_SIGN_NEG then
      Tile.CflAlphaU := -Tile.CflAlphaU;
  end
  else
    Tile.CflAlphaU := 0;
  if SignV <> CFL_SIGN_ZERO then
  begin
    Tile.CflAlphaV := 1 + ReadSymbol(Tile.Symbols, @Tile.Cdf.CflAlphaCdf[(SignV - 1) * 3 + SignU], CFL_ALPHABET_SIZE);
    if SignV = CFL_SIGN_NEG then
      Tile.CflAlphaV := -Tile.CflAlphaV;
  end
  else
    Tile.CflAlphaV := 0;
end;

procedure ReadUvMode(Tile: TTileContext);
var
  CflAllowed: Boolean;
begin
  if Tile.Lossless and (Tile.GetPlaneResidualSize(Tile.MiSize, 1) = BLOCK_4X4) then
    CflAllowed := True
  else if (not Tile.Lossless) and (Max(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)) <= 32) then
    CflAllowed := True
  else
    CflAllowed := False;
  if CflAllowed then
    Tile.UVMode := ReadSymbol(Tile.Symbols, @Tile.Cdf.UvModeCflAllowedCdf[Tile.YMode], UV_INTRA_MODES_CFL_ALLOWED)
  else
    Tile.UVMode := ReadSymbol(Tile.Symbols, @Tile.Cdf.UvModeCflNotAllowedCdf[Tile.YMode], UV_INTRA_MODES_CFL_NOT_ALLOWED);
end;

procedure ReadFilterIntraModeInfo(Tile: TTileContext);
begin
  Tile.use_filter_intra := False;
  if Tile.Sequence^.enable_filter_intra and (Tile.YMode = DC_PRED) and (Tile.PaletteSizeY = 0) and
    (Max(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)) <= 32) then
  begin
    Tile.use_filter_intra := ReadSymbol(Tile.Symbols, @Tile.Cdf.FilterIntraCdf[Tile.MiSize], 2) <> 0;
    if Tile.use_filter_intra then
      Tile.filter_intra_mode := ReadSymbol(Tile.Symbols, @Tile.Cdf.FilterIntraModeCdf, 5);
  end;
end;

procedure ReadIntraModes(Tile: TTileContext; IntraFrame: Boolean);
var
  AboveMode, LeftMode: Integer;
  Frame: TFrameContext;
begin
  Frame := Tile.Frame;
  if IntraFrame then
  begin
    if Tile.AvailU then
      AboveMode := Intra_Mode_Context[Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.YMode]
    else
      AboveMode := Intra_Mode_Context[DC_PRED];
    if Tile.AvailL then
      LeftMode := Intra_Mode_Context[Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.YMode]
    else
      LeftMode := Intra_Mode_Context[DC_PRED];
    Tile.YMode := ReadSymbol(Tile.Symbols, @Tile.IntraFrameYModeCdf[AboveMode, LeftMode], INTRA_MODES);
  end
  else
    Tile.YMode := ReadSymbol(Tile.Symbols, @Tile.Cdf.YModeCdf[Size_Group[Tile.MiSize]], INTRA_MODES);
  ReadIntraAngleInfoY(Tile);
  if Tile.HasChroma then
  begin
    ReadUvMode(Tile);
    if Tile.UVMode = UV_CFL_PRED then
      ReadCflAlphas(Tile);
    ReadIntraAngleInfoUv(Tile);
  end;
  Tile.PaletteSizeY := 0;
  Tile.PaletteSizeUV := 0;
  if (Tile.MiSize >= BLOCK_8X8) and (Block_Width(Tile.MiSize) <= 64) and (Block_Height(Tile.MiSize) <= 64) and
    (Tile.Header^.allow_screen_content_tools <> 0) then
    ReadPaletteModeInfo(Tile);
  ReadFilterIntraModeInfo(Tile);
end;

end.
