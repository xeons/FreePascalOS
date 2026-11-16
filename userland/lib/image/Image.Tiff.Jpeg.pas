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
  TIFF's JPEG compression (7, "new-style", TIFF Technical Note 2): each
  strip or tile is a JPEG stream of its own, the size of the chunk,
  usually without its tables, which are in the JPEGTables tag (a stream
  of only tables: SOI, DQT and DHT segments, EOI).

  A chunk is decoded by libimage's JPEG decoder (Image.Jpeg.Decoder)
  from the tables (without their EOI) followed by the chunk (without
  its SOI), and drawn at its place, cut at the picture's sides. The
  photometric interpretation says what the components are, not the
  stream: RGB is three components with no colour transform, YCbCr three
  with it (and any subsampling the stream's frame gives), BlackIsZero
  and WhiteIsZero one, Separated four CMYK inks, not inverted.
  Old-style JPEG (compression 6) is not supported.
}
unit Image.Tiff.Jpeg;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Tiff.Pages;

{ Image's pixels from Page's JPEG chunks. }
procedure DecodeTiffJpegChunks(const Data: TBytes; constref Page: TTiffPage; Image: TImage);

implementation

uses
  Image.Jpeg.Decoder,
  Image.Tiff.Tags,
  Image.Tiff.Decompression;

{ The tables, without their end marker, and then the chunk without its
  start marker. }
function JoinTablesAndChunk(const Tables, Chunk: TBytes): TBytes;
var
  TablesCount: PtrInt;
  ChunkStart: PtrInt;
begin
  TablesCount := Length(Tables);
  if (TablesCount >= 4) and (Tables[TablesCount - 2] = $FF) and (Tables[TablesCount - 1] = $D9) then
    Dec(TablesCount, 2);
  if TablesCount < 2 then
    Exit(Chunk);
  ChunkStart := 0;
  if (Length(Chunk) >= 2) and (Chunk[0] = $FF) and (Chunk[1] = $D8) then
    ChunkStart := 2;
  Result := nil;
  SetLength(Result, TablesCount + Length(Chunk) - ChunkStart);
  Move(Tables[0], Result[0], TablesCount);
  if Length(Chunk) > ChunkStart then
    Move(Chunk[ChunkStart], Result[TablesCount], Length(Chunk) - ChunkStart);
end;

function ChooseTransform(constref Page: TTiffPage): TJpegColorTransform;
begin
  case Page.Photometric of
    TiffPhotometricRgb:
      Result := JpegTransformNone;
    TiffPhotometricYCbCr:
      Result := JpegTransformYCbCr;
  else
    Result := JpegTransformAutomatic;
  end;
end;

procedure CheckJpegPage(constref Page: TTiffPage);
begin
  if Page.BitsPerSample <> 8 then
    RaiseImageError(ImageErrorUnsupported, 'TIFF JPEG of other than 8 bits');
  if Page.PlanarConfiguration <> TiffPlanarChunky then
    RaiseImageError(ImageErrorUnsupported, 'TIFF JPEG in separate planes');
  if (Page.Photometric <> TiffPhotometricWhiteIsZero) and (Page.Photometric <> TiffPhotometricBlackIsZero) and
    (Page.Photometric <> TiffPhotometricRgb) and (Page.Photometric <> TiffPhotometricYCbCr) and
    (Page.Photometric <> TiffPhotometricSeparated) then
    RaiseImageError(ImageErrorUnsupported, 'TIFF JPEG photometric interpretation');
end;

procedure InvertGrey(Image: TImage);
var
  Index: PtrInt;
  Pixels: PLongWord;
begin
  Pixels := Image.Pixels;
  for Index := 0 to PtrInt(Image.Width) * Image.Height - 1 do
    Pixels[Index] := Pixels[Index] xor $00FFFFFF;
end;

procedure DrawChunk(Chunk, Image: TImage; Left, Top: LongInt);
var
  Width: LongInt;
  Height: LongInt;
  Row: LongInt;
begin
  Width := Chunk.Width;
  if Width > Image.Width - Left then
    Width := Image.Width - Left;
  Height := Chunk.Height;
  if Height > Image.Height - Top then
    Height := Image.Height - Top;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  for Row := 0 to Height - 1 do
    Move(Chunk.Line(Row)^, Image.Line(Top + Row)[Left], PtrUInt(Width) * SizeOf(LongWord));
end;

procedure DecodeTiffJpegChunks(const Data: TBytes; constref Page: TTiffPage; Image: TImage);
var
  Index: LongInt;
  ChunkCount: LongInt;
  Stream: TBytes;
  Chunk: TImage;
  Left: LongInt;
  Top: LongInt;
  Transform: TJpegColorTransform;
begin
  CheckJpegPage(Page);
  Transform := ChooseTransform(Page);
  Image.Fill($FF808080);
  ChunkCount := Page.ChunksAcross * Page.ChunksDown;
  for Index := 0 to ChunkCount - 1 do
  begin
    Stream := JoinTablesAndChunk(Page.JpegTables, TiffChunkBytes(Data, Page, Index));
    Chunk := DecodeJpegImageWithTransform(Stream, Transform);
    try
      if Page.Photometric = TiffPhotometricWhiteIsZero then
        InvertGrey(Chunk);
      Left := (Index mod Page.ChunksAcross) * Page.ChunkWidth;
      Top := (Index div Page.ChunksAcross) * Page.ChunkHeight;
      DrawChunk(Chunk, Image, Left, Top);
    finally
      Chunk.Free;
    end;
  end;
end;

end.
