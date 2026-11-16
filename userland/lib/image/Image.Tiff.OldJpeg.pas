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
  Old-style JPEG in TIFF (compression 6, from TIFF 6.0, withdrawn by
  Technical Note 2), in the layouts that are common:

    - JPEGInterchangeFormat points at a whole JPEG stream of the page
      (start of image to its scan and end; the strips usually lie
      inside it): that stream is decoded as one picture;
    - JPEGInterchangeFormat points at tables only (no scan), or there is
      no such tag, and every strip or tile is a JPEG stream of its own
      starting with its start of image marker: each is decoded with the
      tables before it, as for new-style JPEG.

  A whole stream's colours are what the stream says (JFIF or Adobe
  markers; three components are YCbCr otherwise), as libtiff's
  old-style reader takes them; strips follow the photometric
  interpretation, as new-style JPEG's do.
  Files that keep their tables only in the JPEGQTables, JPEGDCTables and
  JPEGACTables tags, with bare entropy-coded strips, are refused
  (ImageErrorUnsupported).
}
unit Image.Tiff.OldJpeg;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Tiff.Pages;

procedure DecodeTiffOldJpeg(const Data: TBytes; constref Page: TTiffPage; Image: TImage);

implementation

uses
  Image.Jpeg.Decoder,
  Image.Tiff.Decompression,
  Image.Tiff.Jpeg;

const
  MarkerStartOfImage = $D8;
  MarkerEndOfImage = $D9;
  MarkerStartOfScan = $DA;

function StartsWithStartOfImage(const Bytes: TBytes): Boolean;
begin
  Result := (Length(Bytes) >= 2) and (Bytes[0] = $FF) and (Bytes[1] = MarkerStartOfImage);
end;

{ True if the stream's segments reach a start of scan. }
function HasScan(const Stream: TBytes): Boolean;
var
  Position: PtrInt;
  Marker: Byte;
begin
  Result := False;
  if not StartsWithStartOfImage(Stream) then
    Exit;
  Position := 2;
  while Position + 4 <= Length(Stream) do
  begin
    if Stream[Position] <> $FF then
      Exit;
    Marker := Stream[Position + 1];
    if Marker = $FF then
      Inc(Position)
    else if Marker = MarkerStartOfScan then
      Exit(True)
    else if Marker = MarkerEndOfImage then
      Exit
    else if (Marker = MarkerStartOfImage) or (Marker = $01) or ((Marker >= $D0) and (Marker <= $D7)) then
      Inc(Position, 2)
    else
      Inc(Position, 2 + ((PtrInt(Stream[Position + 2]) shl 8) or Stream[Position + 3]));
  end;
end;

function InterchangeStream(const Data: TBytes; constref Page: TTiffPage): TBytes;
var
  Count: Int64;
begin
  Result := nil;
  if (Page.JpegInterchangeOffset <= 0) or (Page.JpegInterchangeOffset >= Length(Data)) then
    Exit;
  Count := Page.JpegInterchangeLength;
  if (Count <= 0) or (Count > Length(Data) - Page.JpegInterchangeOffset) then
    Count := Length(Data) - Page.JpegInterchangeOffset;
  Result := Copy(Data, Page.JpegInterchangeOffset, Count);
  if not StartsWithStartOfImage(Result) then
    Result := nil;
end;

function EveryChunkIsAStream(const Data: TBytes; constref Page: TTiffPage): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to Page.ChunksAcross * Page.ChunksDown - 1 do
    if not StartsWithStartOfImage(TiffChunkBytes(Data, Page, Index)) then
      Exit(False);
  Result := True;
end;

procedure DecodeWholeStream(const Stream: TBytes; Image: TImage);
var
  Picture: TImage;
begin
  Picture := DecodeJpegImageWithTransform(Stream, JpegTransformAutomatic);
  try
    Image.Fill($FF808080);
    DrawTiffJpegChunk(Picture, Image, 0, 0);
  finally
    Picture.Free;
  end;
end;

procedure DecodeTiffOldJpeg(const Data: TBytes; constref Page: TTiffPage; Image: TImage);
var
  Stream: TBytes;
  StripPage: TTiffPage;
begin
  Stream := InterchangeStream(Data, Page);
  if HasScan(Stream) then
  begin
    DecodeWholeStream(Stream, Image);
    Exit;
  end;
  if not EveryChunkIsAStream(Data, Page) then
    RaiseImageError(ImageErrorUnsupported, 'old-style TIFF JPEG with its tables only in JPEGQTables and the like');
  StripPage := Page;
  if Length(Stream) > 0 then
    StripPage.JpegTables := Stream;
  DecodeTiffJpegChunks(Data, StripPage, Image);
end;

end.
