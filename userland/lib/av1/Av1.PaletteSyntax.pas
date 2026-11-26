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
  Palettes (specification sections 5.11.46, 5.11.49 and 5.11.50): the
  palette colours of a block, coded with the colour cache from the
  blocks above and left, and the colour index maps, coded along
  anti-diagonals with a context from the neighbouring indices.
}
unit Av1.PaletteSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

procedure ReadPaletteModeInfo(Tile: TTileContext);
procedure ReadPaletteTokens(Tile: TTileContext);

implementation

type
  TPaletteCache = array[0..2 * PALETTE_COLORS - 1] of Integer;

function GetPaletteCache(Tile: TTileContext; Plane: Integer; out Cache: TPaletteCache): Integer;
var
  Frame: TFrameContext;
  AboveN, LeftN, AboveIdx, LeftIdx, AboveC, LeftC, Value, AboveBase, LeftBase: Integer;
begin
  Frame := Tile.Frame;
  AboveN := 0;
  if ((Tile.MiRow * MI_SIZE) mod 64) <> 0 then
    AboveN := Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.PaletteSize[Plane];
  LeftN := 0;
  if Tile.AvailL then
    LeftN := Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.PaletteSize[Plane];
  AboveBase := Frame.MiIndex(Tile.MiRow - 1, Tile.MiCol) * 16 + Plane * 8;
  LeftBase := Frame.MiIndex(Tile.MiRow, Tile.MiCol - 1) * 16 + Plane * 8;
  AboveIdx := 0;
  LeftIdx := 0;
  Result := 0;
  while (AboveIdx < AboveN) and (LeftIdx < LeftN) do
  begin
    AboveC := Frame.PaletteColors[AboveBase + AboveIdx];
    LeftC := Frame.PaletteColors[LeftBase + LeftIdx];
    if LeftC < AboveC then
    begin
      if (Result = 0) or (LeftC <> Cache[Result - 1]) then
      begin
        Cache[Result] := LeftC;
        Inc(Result);
      end;
      Inc(LeftIdx);
    end
    else
    begin
      if (Result = 0) or (AboveC <> Cache[Result - 1]) then
      begin
        Cache[Result] := AboveC;
        Inc(Result);
      end;
      Inc(AboveIdx);
      if LeftC = AboveC then
        Inc(LeftIdx);
    end;
  end;
  while AboveIdx < AboveN do
  begin
    Value := Frame.PaletteColors[AboveBase + AboveIdx];
    Inc(AboveIdx);
    if (Result = 0) or (Value <> Cache[Result - 1]) then
    begin
      Cache[Result] := Value;
      Inc(Result);
    end;
  end;
  while LeftIdx < LeftN do
  begin
    Value := Frame.PaletteColors[LeftBase + LeftIdx];
    Inc(LeftIdx);
    if (Result = 0) or (Value <> Cache[Result - 1]) then
    begin
      Cache[Result] := Value;
      Inc(Result);
    end;
  end;
end;

procedure SortColors(var Colors: TPaletteColors; Count: Integer);
var
  I, J, Value: Integer;
begin
  for I := 1 to Count - 1 do
  begin
    Value := Colors[I];
    J := I - 1;
    while (J >= 0) and (Colors[J] > Value) do
    begin
      Colors[J + 1] := Colors[J];
      Dec(J);
    end;
    Colors[J + 1] := Value;
  end;
end;

function Clip1(Value, BitDepth: Integer): Integer; inline;
begin
  Result := Clip3(0, (1 shl BitDepth) - 1, Value);
end;

{ The palette_colors_y or palette_colors_u part of palette_mode_info:
  cache flags, a first literal colour, then increasing deltas. }
procedure ReadAscendingColors(Tile: TTileContext; Plane, Size: Integer; var Colors: TPaletteColors; RangeAdjust: Integer);
var
  Cache: TPaletteCache;
  CacheN, Index, I, BitDepth, MinBits, PaletteBits, Delta, Range: Integer;
begin
  BitDepth := Tile.Sequence^.BitDepth;
  CacheN := GetPaletteCache(Tile, Plane, Cache);
  Index := 0;
  I := 0;
  while (I < CacheN) and (Index < Size) do
  begin
    if ReadLiteral(Tile.Symbols, 1) <> 0 then
    begin
      Colors[Index] := Cache[I];
      Inc(Index);
    end;
    Inc(I);
  end;
  if Index < Size then
  begin
    Colors[Index] := ReadLiteral(Tile.Symbols, BitDepth);
    Inc(Index);
  end;
  PaletteBits := 0;
  if Index < Size then
  begin
    MinBits := BitDepth - 3;
    PaletteBits := MinBits + ReadLiteral(Tile.Symbols, 2);
  end;
  while Index < Size do
  begin
    Delta := ReadLiteral(Tile.Symbols, PaletteBits);
    { Luma deltas are coded minus one; chroma U deltas are not. }
    Inc(Delta, RangeAdjust);
    Colors[Index] := Clip1(Colors[Index - 1] + Delta, BitDepth);
    Range := (1 shl BitDepth) - Colors[Index] - RangeAdjust;
    PaletteBits := Min(PaletteBits, CeilLog2(Range));
    Inc(Index);
  end;
  SortColors(Colors, Size);
end;

procedure ReadPaletteColorsV(Tile: TTileContext);
var
  BitDepth, MinBits, MaxVal, PaletteBits, Index, Delta, Value: Integer;
begin
  BitDepth := Tile.Sequence^.BitDepth;
  if ReadLiteral(Tile.Symbols, 1) <> 0 then
  begin
    MinBits := BitDepth - 4;
    MaxVal := 1 shl BitDepth;
    PaletteBits := MinBits + ReadLiteral(Tile.Symbols, 2);
    Tile.palette_colors_v[0] := ReadLiteral(Tile.Symbols, BitDepth);
    for Index := 1 to Tile.PaletteSizeUV - 1 do
    begin
      Delta := ReadLiteral(Tile.Symbols, PaletteBits);
      if Delta <> 0 then
        if ReadLiteral(Tile.Symbols, 1) <> 0 then
          Delta := -Delta;
      Value := Tile.palette_colors_v[Index - 1] + Delta;
      if Value < 0 then
        Inc(Value, MaxVal);
      if Value >= MaxVal then
        Dec(Value, MaxVal);
      Tile.palette_colors_v[Index] := Clip1(Value, BitDepth);
    end;
  end
  else
    for Index := 0 to Tile.PaletteSizeUV - 1 do
      Tile.palette_colors_v[Index] := ReadLiteral(Tile.Symbols, BitDepth);
end;

procedure ReadPaletteModeInfo(Tile: TTileContext);
var
  Frame: TFrameContext;
  BsizeCtx, Context: Integer;
begin
  Frame := Tile.Frame;
  BsizeCtx := Mi_Width_Log2[Tile.MiSize] + Mi_Height_Log2[Tile.MiSize] - 2;
  if Tile.YMode = DC_PRED then
  begin
    Context := 0;
    if Tile.AvailU and (Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.PaletteSize[0] > 0) then
      Inc(Context);
    if Tile.AvailL and (Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.PaletteSize[0] > 0) then
      Inc(Context);
    if ReadSymbol(Tile.Symbols, @Tile.Cdf.PaletteYModeCdf[BsizeCtx, Context], 2) <> 0 then
    begin
      Tile.PaletteSizeY := ReadSymbol(Tile.Symbols, @Tile.Cdf.PaletteYSizeCdf[BsizeCtx], PALETTE_SIZES) + 2;
      ReadAscendingColors(Tile, 0, Tile.PaletteSizeY, Tile.palette_colors_y, 1);
    end;
  end;
  if Tile.HasChroma and (Tile.UVMode = DC_PRED) then
  begin
    Context := Ord(Tile.PaletteSizeY > 0);
    if ReadSymbol(Tile.Symbols, @Tile.Cdf.PaletteUvModeCdf[Context], 2) <> 0 then
    begin
      Tile.PaletteSizeUV := ReadSymbol(Tile.Symbols, @Tile.Cdf.PaletteUvSizeCdf[BsizeCtx], PALETTE_SIZES) + 2;
      ReadAscendingColors(Tile, 1, Tile.PaletteSizeUV, Tile.palette_colors_u, 0);
      ReadPaletteColorsV(Tile);
    end;
  end;
end;

type
  TColorOrder = array[0..PALETTE_COLORS - 1] of Integer;

{ get_palette_color_context: the order of the colours by neighbour score,
  and the context from the scores' hash. }
function GetPaletteColorContext(const ColorMap: TColorMap; R, C, N: Integer; out ColorOrder: TColorOrder): Integer;
var
  Scores: array[0..PALETTE_COLORS - 1] of Integer;
  I, J, K, MaxScore, MaxIdx, MaxColorOrder, Hash: Integer;
begin
  for I := 0 to PALETTE_COLORS - 1 do
  begin
    Scores[I] := 0;
    ColorOrder[I] := I;
  end;
  if C > 0 then
    Inc(Scores[ColorMap[R, C - 1]], 2);
  if (R > 0) and (C > 0) then
    Inc(Scores[ColorMap[R - 1, C - 1]], 1);
  if R > 0 then
    Inc(Scores[ColorMap[R - 1, C]], 2);
  for I := 0 to PALETTE_NUM_NEIGHBORS - 1 do
  begin
    MaxScore := Scores[I];
    MaxIdx := I;
    for J := I + 1 to N - 1 do
      if Scores[J] > MaxScore then
      begin
        MaxScore := Scores[J];
        MaxIdx := J;
      end;
    if MaxIdx <> I then
    begin
      MaxScore := Scores[MaxIdx];
      MaxColorOrder := ColorOrder[MaxIdx];
      for K := MaxIdx downto I + 1 do
      begin
        Scores[K] := Scores[K - 1];
        ColorOrder[K] := ColorOrder[K - 1];
      end;
      Scores[I] := MaxScore;
      ColorOrder[I] := MaxColorOrder;
    end;
  end;
  Hash := 0;
  for I := 0 to PALETTE_NUM_NEIGHBORS - 1 do
    Inc(Hash, Scores[I] * Palette_Color_Hash_Multipliers[I]);
  Result := Palette_Color_Context[Hash];
end;

function ColorCdf(Tile: TTileContext; Luma: Boolean; Size, Context: Integer): PWord;
begin
  if Luma then
    case Size of
      2: Result := @Tile.Cdf.PaletteSize2YColorCdf[Context];
      3: Result := @Tile.Cdf.PaletteSize3YColorCdf[Context];
      4: Result := @Tile.Cdf.PaletteSize4YColorCdf[Context];
      5: Result := @Tile.Cdf.PaletteSize5YColorCdf[Context];
      6: Result := @Tile.Cdf.PaletteSize6YColorCdf[Context];
      7: Result := @Tile.Cdf.PaletteSize7YColorCdf[Context];
    else
      Result := @Tile.Cdf.PaletteSize8YColorCdf[Context];
    end
  else
    case Size of
      2: Result := @Tile.Cdf.PaletteSize2UvColorCdf[Context];
      3: Result := @Tile.Cdf.PaletteSize3UvColorCdf[Context];
      4: Result := @Tile.Cdf.PaletteSize4UvColorCdf[Context];
      5: Result := @Tile.Cdf.PaletteSize5UvColorCdf[Context];
      6: Result := @Tile.Cdf.PaletteSize6UvColorCdf[Context];
      7: Result := @Tile.Cdf.PaletteSize7UvColorCdf[Context];
    else
      Result := @Tile.Cdf.PaletteSize8UvColorCdf[Context];
    end;
end;

procedure ReadColorMap(Tile: TTileContext; var ColorMap: TColorMap; Luma: Boolean; Size,
  BlockWidth, BlockHeight, OnscreenWidth, OnscreenHeight: Integer);
var
  I, J, Context, Symbol: Integer;
  ColorOrder: TColorOrder;
begin
  ColorMap[0, 0] := ReadUniform(Tile.Symbols, Size);
  for I := 1 to OnscreenHeight + OnscreenWidth - 2 do
  begin
    J := Min(I, OnscreenWidth - 1);
    while J >= Max(0, I - OnscreenHeight + 1) do
    begin
      Context := GetPaletteColorContext(ColorMap, I - J, J, Size, ColorOrder);
      Symbol := ReadSymbol(Tile.Symbols, ColorCdf(Tile, Luma, Size, Context), Size);
      ColorMap[I - J, J] := ColorOrder[Symbol];
      Dec(J);
    end;
  end;
  for I := 0 to OnscreenHeight - 1 do
    for J := OnscreenWidth to BlockWidth - 1 do
      ColorMap[I, J] := ColorMap[I, OnscreenWidth - 1];
  for I := OnscreenHeight to BlockHeight - 1 do
    for J := 0 to BlockWidth - 1 do
      ColorMap[I, J] := ColorMap[OnscreenHeight - 1, J];
end;

procedure ReadPaletteTokens(Tile: TTileContext);
var
  BlockHeight, BlockWidth, OnscreenHeight, OnscreenWidth: Integer;
begin
  BlockHeight := Block_Height(Tile.MiSize);
  BlockWidth := Block_Width(Tile.MiSize);
  OnscreenHeight := Min(BlockHeight, (Tile.Header^.MiRows - Tile.MiRow) * MI_SIZE);
  OnscreenWidth := Min(BlockWidth, (Tile.Header^.MiCols - Tile.MiCol) * MI_SIZE);
  if Tile.PaletteSizeY <> 0 then
    ReadColorMap(Tile, Tile.ColorMapY, True, Tile.PaletteSizeY, BlockWidth, BlockHeight, OnscreenWidth, OnscreenHeight);
  if Tile.PaletteSizeUV <> 0 then
  begin
    BlockHeight := BlockHeight shr Tile.Sequence^.subsampling_y;
    BlockWidth := BlockWidth shr Tile.Sequence^.subsampling_x;
    OnscreenHeight := OnscreenHeight shr Tile.Sequence^.subsampling_y;
    OnscreenWidth := OnscreenWidth shr Tile.Sequence^.subsampling_x;
    if BlockWidth < 4 then
    begin
      Inc(BlockWidth, 2);
      Inc(OnscreenWidth, 2);
    end;
    if BlockHeight < 4 then
    begin
      Inc(BlockHeight, 2);
      Inc(OnscreenHeight, 2);
    end;
    ReadColorMap(Tile, Tile.ColorMapUV, False, Tile.PaletteSizeUV, BlockWidth, BlockHeight, OnscreenWidth, OnscreenHeight);
  end;
end;

end.
