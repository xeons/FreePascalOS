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
  Unfiltered PNG lines turned into the model's colours.

  Samples are big-endian and packed from the high bits of a byte for
  depths under 8. They become 8-bit channels: a sample of 1, 2 or 4
  bits is multiplied out (1 bit times 255, 2 bits times 85, 4 bits
  times 17), so its brightest is 255; a 16-bit one is rounded,
  (V x 255 + 32767) div 65535, the nearest 8-bit value rather than
  the high byte.

  Transparency without an alpha channel comes from tRNS: for palette
  pictures an alpha for each of the first entries (the rest opaque);
  for grey and RGB one colour, at the picture's own depth, whose
  pixels are fully transparent. The colour is compared before any
  reduction, so a 16-bit key matches only its exact 16-bit colour. A
  palette index past the palette's end is opaque black, as libpng
  shows it.

  ConvertPngRow writes every Step-th pixel of a line of the image from
  a line of the data, so an interlaced pass goes straight to where its
  pixels belong.
}
unit Image.Png.Pixels;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Png.Header;

type
  TPngColorInfo = record
    Header: TPngHeader;
    { Colours of the palette, alpha from tRNS. }
    Palette: array[0..255] of TColor;
    PaletteCount: LongInt;
    { The tRNS colour of grey and RGB pictures, at their depth. }
    HasTransparentKey: Boolean;
    KeyGrey: LongWord;
    KeyRed: LongWord;
    KeyGreen: LongWord;
    KeyBlue: LongWord;
  end;

{ Count pixels of an unfiltered line Row into Output, Output[0],
  Output[Step], Output[2 x Step]... }
procedure ConvertPngRow(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
{ A 16-bit sample as the nearest 8-bit one. }
function ReduceSample16(Value: LongWord): LongWord; inline;
{ True when the picture can have pixels that are not opaque. }
function PngInfoHasAlpha(constref Info: TPngColorInfo): Boolean;

implementation

function ReduceSample16(Value: LongWord): LongWord;
begin
  Result := (Value * 255 + 32767) div 65535;
end;

function Argb(Alpha, Red, Green, Blue: LongWord): LongWord; inline;
begin
  Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

function PngInfoHasAlpha(constref Info: TPngColorInfo): Boolean;
var
  Index: LongInt;
begin
  case Info.Header.ColorType of
    PngColorGreyAlpha, PngColorRgbAlpha:
      Result := True;
    PngColorPalette:
      begin
        Result := False;
        for Index := 0 to Info.PaletteCount - 1 do
          if (Info.Palette[Index] shr 24) <> AlphaOpaque then
            Result := True;
      end;
  else
    Result := Info.HasTransparentKey;
  end;
end;

{ The sample of Depth bits (1, 2 or 4) at Index of a packed line. }
function PackedSample(Row: PByte; Index, Depth: LongInt): LongWord; inline;
var
  BitPosition: LongInt;
begin
  BitPosition := Index * Depth;
  Result := (Row[BitPosition shr 3] shr (8 - Depth - (BitPosition and 7))) and ((1 shl Depth) - 1);
end;

procedure ConvertGreyPacked(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Sample: LongWord;
  Scale: LongWord;
  Depth: LongInt;
  Grey: LongWord;
begin
  Depth := Info.Header.BitDepth;
  Scale := 255 div ((1 shl Depth) - 1);
  for Index := 0 to Count - 1 do
  begin
    Sample := PackedSample(Row, Index, Depth);
    Grey := Sample * Scale;
    if Info.HasTransparentKey and (Sample = Info.KeyGrey) then
      Output[Index * Step] := Argb(0, Grey, Grey, Grey)
    else
      Output[Index * Step] := Argb(AlphaOpaque, Grey, Grey, Grey);
  end;
end;

procedure ConvertGrey8(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Grey: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Grey := Row[Index];
    if Info.HasTransparentKey and (Grey = Info.KeyGrey) then
      Output[Index * Step] := Argb(0, Grey, Grey, Grey)
    else
      Output[Index * Step] := Argb(AlphaOpaque, Grey, Grey, Grey);
  end;
end;

procedure ConvertGrey16(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Sample: LongWord;
  Grey: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Sample := (LongWord(Row[2 * Index]) shl 8) or Row[2 * Index + 1];
    Grey := ReduceSample16(Sample);
    if Info.HasTransparentKey and (Sample = Info.KeyGrey) then
      Output[Index * Step] := Argb(0, Grey, Grey, Grey)
    else
      Output[Index * Step] := Argb(AlphaOpaque, Grey, Grey, Grey);
  end;
end;

procedure ConvertRgb8(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
  Alpha: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Red := Row[3 * Index];
    Green := Row[3 * Index + 1];
    Blue := Row[3 * Index + 2];
    Alpha := AlphaOpaque;
    if Info.HasTransparentKey and (Red = Info.KeyRed) and (Green = Info.KeyGreen) and (Blue = Info.KeyBlue) then
      Alpha := 0;
    Output[Index * Step] := Argb(Alpha, Red, Green, Blue);
  end;
end;

procedure ConvertRgb16(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
  Alpha: LongWord;
  Sample: PByte;
begin
  for Index := 0 to Count - 1 do
  begin
    Sample := Row + 6 * Index;
    Red := (LongWord(Sample[0]) shl 8) or Sample[1];
    Green := (LongWord(Sample[2]) shl 8) or Sample[3];
    Blue := (LongWord(Sample[4]) shl 8) or Sample[5];
    Alpha := AlphaOpaque;
    if Info.HasTransparentKey and (Red = Info.KeyRed) and (Green = Info.KeyGreen) and (Blue = Info.KeyBlue) then
      Alpha := 0;
    Output[Index * Step] := Argb(Alpha, ReduceSample16(Red), ReduceSample16(Green), ReduceSample16(Blue));
  end;
end;

procedure ConvertPalette(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Entry: LongWord;
  Depth: LongInt;
begin
  Depth := Info.Header.BitDepth;
  for Index := 0 to Count - 1 do
  begin
    if Depth = 8 then
      Entry := Row[Index]
    else
      Entry := PackedSample(Row, Index, Depth);
    if Entry < LongWord(Info.PaletteCount) then
      Output[Index * Step] := Info.Palette[Entry]
    else
      Output[Index * Step] := Argb(AlphaOpaque, 0, 0, 0);
  end;
end;

procedure ConvertGreyAlpha8(Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Grey: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Grey := Row[2 * Index];
    Output[Index * Step] := Argb(Row[2 * Index + 1], Grey, Grey, Grey);
  end;
end;

procedure ConvertGreyAlpha16(Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Grey: LongWord;
  Alpha: LongWord;
  Sample: PByte;
begin
  for Index := 0 to Count - 1 do
  begin
    Sample := Row + 4 * Index;
    Grey := ReduceSample16((LongWord(Sample[0]) shl 8) or Sample[1]);
    Alpha := ReduceSample16((LongWord(Sample[2]) shl 8) or Sample[3]);
    Output[Index * Step] := Argb(Alpha, Grey, Grey, Grey);
  end;
end;

procedure ConvertRgbAlpha8(Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Sample: PByte;
begin
  for Index := 0 to Count - 1 do
  begin
    Sample := Row + 4 * Index;
    Output[Index * Step] := Argb(Sample[3], Sample[0], Sample[1], Sample[2]);
  end;
end;

procedure ConvertRgbAlpha16(Row: PByte; Output: PLongWord; Count, Step: LongInt);
var
  Index: LongInt;
  Sample: PByte;
begin
  for Index := 0 to Count - 1 do
  begin
    Sample := Row + 8 * Index;
    Output[Index * Step] := Argb(ReduceSample16((LongWord(Sample[6]) shl 8) or Sample[7]),
      ReduceSample16((LongWord(Sample[0]) shl 8) or Sample[1]),
      ReduceSample16((LongWord(Sample[2]) shl 8) or Sample[3]),
      ReduceSample16((LongWord(Sample[4]) shl 8) or Sample[5]));
  end;
end;

procedure ConvertPngRow(constref Info: TPngColorInfo; Row: PByte; Output: PLongWord; Count, Step: LongInt);
begin
  case Info.Header.ColorType of
    PngColorGrey:
      case Info.Header.BitDepth of
        8: ConvertGrey8(Info, Row, Output, Count, Step);
        16: ConvertGrey16(Info, Row, Output, Count, Step);
      else
        ConvertGreyPacked(Info, Row, Output, Count, Step);
      end;
    PngColorRgb:
      if Info.Header.BitDepth = 8 then
        ConvertRgb8(Info, Row, Output, Count, Step)
      else
        ConvertRgb16(Info, Row, Output, Count, Step);
    PngColorPalette:
      ConvertPalette(Info, Row, Output, Count, Step);
    PngColorGreyAlpha:
      if Info.Header.BitDepth = 8 then
        ConvertGreyAlpha8(Row, Output, Count, Step)
      else
        ConvertGreyAlpha16(Row, Output, Count, Step);
    PngColorRgbAlpha:
      if Info.Header.BitDepth = 8 then
        ConvertRgbAlpha8(Row, Output, Count, Step)
      else
        ConvertRgbAlpha16(Row, Output, Count, Step);
  end;
end;

end.
