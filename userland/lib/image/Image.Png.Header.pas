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
  A PNG's header (IHDR, the first chunk): width, height, bit depth,
  colour type, and the compression, filter and interlace methods.

  The colour types and the depths each allows:

    0  grey               1, 2, 4, 8, 16
    2  RGB                8, 16
    3  palette indices    1, 2, 4, 8
    4  grey and alpha     8, 16
    6  RGB and alpha      8, 16

  Compression and filtering have one method each (0: deflate, the five
  filters); interlacing is none (0) or Adam7 (1). Anything else is
  ImageErrorMalformed; a size the model refuses is ImageErrorTooLarge.

  A line of N pixels takes (N x bits per pixel + 7) div 8 bytes; the
  filters work on whole pixels of FilterStride bytes (1 for depths
  under 8).
}
unit Image.Png.Header;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Png.Chunks;

const
  PngColorGrey = 0;
  PngColorRgb = 2;
  PngColorPalette = 3;
  PngColorGreyAlpha = 4;
  PngColorRgbAlpha = 6;

  PngHeaderLength = 13;

type
  TPngHeader = record
    Width: LongInt;
    Height: LongInt;
    BitDepth: LongInt;
    ColorType: LongInt;
    Interlaced: Boolean;
    { Samples a pixel has (1 to 4). }
    Channels: LongInt;
    BitsPerPixel: LongInt;
    { Bytes the filters reach back: a whole pixel, at least 1. }
    FilterStride: LongInt;
  end;

procedure ReadPngHeader(const Data: TBytes; constref Chunk: TPngChunk; out Header: TPngHeader);
{ The header's colour type and depth with Channels, BitsPerPixel and
  FilterStride worked out; False for a combination PNG does not allow. }
function CompletePngHeader(var Header: TPngHeader): Boolean;
{ The bytes a line of Width pixels takes (without its filter byte). }
function PngRowBytes(constref Header: TPngHeader; Width: LongInt): PtrInt;

implementation

function ChannelsOf(ColorType: LongInt): LongInt;
begin
  case ColorType of
    PngColorGrey, PngColorPalette: Result := 1;
    PngColorRgb: Result := 3;
    PngColorGreyAlpha: Result := 2;
    PngColorRgbAlpha: Result := 4;
  else
    Result := 0;
  end;
end;

function DepthAllowed(ColorType, BitDepth: LongInt): Boolean;
begin
  case ColorType of
    PngColorGrey: Result := BitDepth in [1, 2, 4, 8, 16];
    PngColorPalette: Result := BitDepth in [1, 2, 4, 8];
    PngColorRgb, PngColorGreyAlpha, PngColorRgbAlpha: Result := BitDepth in [8, 16];
  else
    Result := False;
  end;
end;

function CompletePngHeader(var Header: TPngHeader): Boolean;
begin
  Result := DepthAllowed(Header.ColorType, Header.BitDepth);
  if not Result then
    Exit;
  Header.Channels := ChannelsOf(Header.ColorType);
  Header.BitsPerPixel := Header.Channels * Header.BitDepth;
  Header.FilterStride := Header.BitsPerPixel div 8;
  if Header.FilterStride < 1 then
    Header.FilterStride := 1;
end;

procedure ReadPngHeader(const Data: TBytes; constref Chunk: TPngChunk; out Header: TPngHeader);
var
  Width: LongWord;
  Height: LongWord;
begin
  Header := Default(TPngHeader);
  if (Chunk.ChunkType <> PngChunkHeader) or (Chunk.DataLength <> PngHeaderLength) then
    RaiseImageError(ImageErrorMalformed, 'PNG header');
  Width := ChunkLong(Data, Chunk, 0);
  Height := ChunkLong(Data, Chunk, 4);
  if (Width = 0) or (Height = 0) or (Width > PngLargestChunkLength) or (Height > PngLargestChunkLength) then
    RaiseImageError(ImageErrorMalformed, 'PNG size');
  CheckImageSize(Width, Height);
  Header.Width := Width;
  Header.Height := Height;
  Header.BitDepth := ChunkByte(Data, Chunk, 8);
  Header.ColorType := ChunkByte(Data, Chunk, 9);
  if not CompletePngHeader(Header) then
    RaiseImageError(ImageErrorMalformed, Format('colour type %d with %d bits', [Header.ColorType, Header.BitDepth]));
  if ChunkByte(Data, Chunk, 10) <> 0 then
    RaiseImageError(ImageErrorMalformed, 'PNG compression method');
  if ChunkByte(Data, Chunk, 11) <> 0 then
    RaiseImageError(ImageErrorMalformed, 'PNG filter method');
  case ChunkByte(Data, Chunk, 12) of
    0: Header.Interlaced := False;
    1: Header.Interlaced := True;
  else
    RaiseImageError(ImageErrorMalformed, 'PNG interlace method');
  end;
end;

function PngRowBytes(constref Header: TPngHeader; Width: LongInt): PtrInt;
begin
  Result := (PtrInt(Width) * Header.BitsPerPixel + 7) div 8;
end;

end.
