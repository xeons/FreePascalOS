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
  A WebP file into an image: a simple file's one picture; an extended
  file's picture (whose size must be the canvas's) or its animation, a
  TAnimatedImage whose frames are the ANMF frames (offset, duration,
  disposal to transparent or none, blending by alpha or not) with
  ANIM's loop count and background colour, its own pixels the first
  frame as seen. A frame that is broken or cut short ends the
  animation there, keeping the frames before it.

  ICCP becomes the colour profile, EXIF's orientation the orientation,
  XMP the metadata key XML:com.adobe.xmp (PNG's keyword for it), and
  whether the pictures are lossy or lossless the metadata key
  Compression.
}
unit Image.WebP.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Frames;

const
  MetadataKeyXmp = 'XML:com.adobe.xmp';
  WebPCompressionLossy = 'lossy';
  WebPCompressionLossless = 'lossless';
  WebPCompressionMixed = 'lossy and lossless';

function DecodeWebPImage(const Data: TBytes): TImage;

implementation

uses
  Image.Metadata,
  Image.Compositing,
  Image.Jpeg.Exif,
  Image.WebP.Container,
  Image.WebP.LosslessDecoder,
  Image.WebP.LossyDecoder,
  Image.WebP.YuvConversion,
  Image.WebP.Alpha;

type
  TPictureFacts = record
    Lossless: Boolean;
    HasAlpha: Boolean;
  end;

function ChunkPointer(const Data: TBytes; constref Chunk: TWebPChunk): PByte;
begin
  if Chunk.Size <= 0 then
    RaiseImageError(ImageErrorTruncated, 'empty WebP chunk');
  Result := PByte(Data) + Chunk.Start;
end;

function DecodePicture(const Data: TBytes; constref Picture: TWebPPictureChunks; out Facts: TPictureFacts): TImage;
var
  Planes: TLossyPlanes;
  Alpha: TBytes;
  Header: TLosslessHeader;
begin
  Facts.Lossless := Picture.Lossless;
  Facts.HasAlpha := False;
  if Picture.Lossless then
  begin
    if ReadLosslessHeader(ChunkPointer(Data, Picture.Image), Picture.Image.Size, Header) then
      Facts.HasAlpha := Header.AlphaUsed;
    Exit(DecodeLosslessImage(ChunkPointer(Data, Picture.Image), Picture.Image.Size));
  end;
  Planes := DecodeLossyPlanes(ChunkPointer(Data, Picture.Image), Picture.Image.Size);
  if Picture.HasAlpha then
  begin
    Alpha := DecodeAlphaPlane(ChunkPointer(Data, Picture.Alpha), Picture.Alpha.Size, Planes.Width, Planes.Height);
    Facts.HasAlpha := True;
    Result := LossyPlanesToImage(Planes, @Alpha[0]);
  end
  else
    Result := LossyPlanesToImage(Planes, nil);
end;

function HasPictureChunk(const Chunks: TWebPChunkList): Boolean;
begin
  Result := (FindChunk(Chunks, ChunkTagLossy) >= 0) or (FindChunk(Chunks, ChunkTagLossless) >= 0);
end;

procedure NoteCompression(var Compression: string; Lossless: Boolean);
var
  Kind: string;
begin
  if Lossless then
    Kind := WebPCompressionLossless
  else
    Kind := WebPCompressionLossy;
  if Compression = '' then
    Compression := Kind
  else if Compression <> Kind then
    Compression := WebPCompressionMixed;
end;

function ExifOrientation(const Data: TBytes; constref Chunk: TWebPChunk): LongInt;
var
  Start: PtrInt;
  Count: PtrInt;
begin
  Start := Chunk.Start;
  Count := Chunk.Size;
  { Some writers keep JPEG's "Exif" and two zeros before the TIFF
    structure. }
  if (Count >= 6) and (Data[Start] = Ord('E')) and (Data[Start + 1] = Ord('x')) and (Data[Start + 2] = Ord('i')) and
    (Data[Start + 3] = Ord('f')) and (Data[Start + 4] = 0) and (Data[Start + 5] = 0) then
  begin
    Inc(Start, 6);
    Dec(Count, 6);
  end;
  Result := ReadTiffOrientation(Data, Start, Count);
end;

procedure ReadMetadataChunks(const Data: TBytes; const Chunks: TWebPChunkList; Image: TImage);
var
  Index: LongInt;
  Text: string;
  Orientation: LongInt;
begin
  Index := FindChunk(Chunks, ChunkTagIcc);
  if (Index >= 0) and (Chunks[Index].Size > 0) then
    Image.IccProfile := Copy(Data, Chunks[Index].Start, Chunks[Index].Size);
  Index := FindChunk(Chunks, ChunkTagExif);
  if Index >= 0 then
  begin
    Orientation := ExifOrientation(Data, Chunks[Index]);
    if Orientation > 0 then
      Image.Orientation := OrientationFromExif(Orientation);
  end;
  Index := FindChunk(Chunks, ChunkTagXmp);
  if (Index >= 0) and (Chunks[Index].Size > 0) then
  begin
    Text := '';
    SetLength(Text, Chunks[Index].Size);
    Move(Data[Chunks[Index].Start], Text[1], Chunks[Index].Size);
    Image.Metadata.SetValue(MetadataKeyXmp, Text);
  end;
end;

procedure SetSource(Image: TImage; HasAlpha: Boolean; const Compression: string);
begin
  Image.SourceFormatName := 'WebP';
  Image.SourceHasAlpha := HasAlpha;
  if HasAlpha then
    Image.SourceBitsPerPixel := 32
  else
    Image.SourceBitsPerPixel := 24;
  Image.Metadata.SetValue(MetadataKeyCompression, Compression);
end;

function DecodeFrame(const Data: TBytes; constref Chunk: TWebPChunk; CanvasWidth, CanvasHeight: LongInt;
  var Compression: string; var HasAlpha: Boolean): TImageFrame;
var
  Header: TWebPFrameHeader;
  Picture: TWebPPictureChunks;
  Facts: TPictureFacts;
  Image: TImage;
  Truncated: Boolean;
begin
  ReadFrameHeader(Data, Chunk, Header);
  if (Header.Left + Header.Width > CanvasWidth) or (Header.Top + Header.Height > CanvasHeight) then
    RaiseImageError(ImageErrorMalformed, 'WebP frame outside the canvas');
  Picture := FindPictureChunks(ListChunksIn(Data, Chunk.Start + FrameHeaderLength, Chunk.Size - FrameHeaderLength,
    Truncated));
  Image := DecodePicture(Data, Picture, Facts);
  if (Image.Width <> Header.Width) or (Image.Height <> Header.Height) then
  begin
    Image.Free;
    RaiseImageError(ImageErrorMalformed, 'WebP frame of another size than its header');
  end;
  NoteCompression(Compression, Facts.Lossless);
  HasAlpha := HasAlpha or Facts.HasAlpha;
  Result := TImageFrame.Create(Image);
  Result.Left := Header.Left;
  Result.Top := Header.Top;
  Result.Delay := Header.Duration;
  if (Header.Flags and WebPFrameDisposeBackground) <> 0 then
    Result.Disposal := FrameDisposalBackground
  else
    Result.Disposal := FrameDisposalNone;
  if (Header.Flags and WebPFrameNoBlend) <> 0 then
    Result.Blend := FrameBlendSource
  else
    Result.Blend := FrameBlendOver;
end;

function DecodeAnimation(const Data: TBytes; const Chunks: TWebPChunkList; Truncated: Boolean;
  constref Extended: TWebPExtendedHeader): TAnimatedImage;
var
  AnimationIndex: LongInt;
  Header: TWebPAnimationHeader;
  Index: LongInt;
  Compression: string;
  HasAlpha: Boolean;
  Frame: TImageFrame;
  Compositor: TFrameCompositor;
  First: TImage;
begin
  AnimationIndex := FindChunk(Chunks, ChunkTagAnimation);
  if AnimationIndex < 0 then
    RaiseImageError(ImageErrorMalformed, 'WebP animation without ANIM');
  ReadAnimationHeader(Data, Chunks[AnimationIndex], Header);
  Result := TAnimatedImage.Create(Extended.CanvasWidth, Extended.CanvasHeight);
  try
    Result.LoopCount := Header.LoopCount;
    Result.BackgroundColor := Header.BackgroundColor;
    Compression := '';
    HasAlpha := (Extended.Flags and WebPFlagAlpha) <> 0;
    for Index := 0 to High(Chunks) do
    begin
      if Chunks[Index].Tag <> ChunkTagFrame then
        Continue;
      try
        Frame := DecodeFrame(Data, Chunks[Index], Extended.CanvasWidth, Extended.CanvasHeight, Compression, HasAlpha);
      except
        on EImageError do
        begin
          if Result.FrameCount = 0 then
            raise;
          Break;
        end;
      end;
      Result.AddFrame(Frame);
    end;
    if (Result.FrameCount = 0) and Truncated then
      RaiseImageError(ImageErrorTruncated, 'WebP animation');
    if Result.FrameCount = 0 then
      RaiseImageError(ImageErrorMalformed, 'WebP animation without frames');
    SetSource(Result, HasAlpha, Compression);
    Compositor := TFrameCompositor.Create(Result);
    try
      First := Compositor.RenderFrame(0);
      Move(First.Pixels^, Result.Pixels^, PtrUInt(Result.Width) * PtrUInt(Result.Height) * SizeOf(LongWord));
    finally
      Compositor.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function DecodeStill(const Data: TBytes; const Chunks: TWebPChunkList; Truncated, Extended: Boolean;
  constref Header: TWebPExtendedHeader): TImage;
var
  Picture: TWebPPictureChunks;
  Facts: TPictureFacts;
  Compression: string;
begin
  if Truncated and not HasPictureChunk(Chunks) then
    RaiseImageError(ImageErrorTruncated, 'WebP picture');
  Picture := FindPictureChunks(Chunks);
  Result := DecodePicture(Data, Picture, Facts);
  try
    if Extended and ((Result.Width <> Header.CanvasWidth) or (Result.Height <> Header.CanvasHeight)) then
      RaiseImageError(ImageErrorMalformed, 'WebP picture of another size than its canvas');
    Compression := '';
    NoteCompression(Compression, Facts.Lossless);
    SetSource(Result, Facts.HasAlpha or (Extended and ((Header.Flags and WebPFlagAlpha) <> 0)), Compression);
  except
    Result.Free;
    raise;
  end;
end;

function DecodeWebPImage(const Data: TBytes): TImage;
var
  Chunks: TWebPChunkList;
  Header: TWebPExtendedHeader;
  Truncated: Boolean;
begin
  Chunks := ListWebPChunks(Data, Truncated);
  if Chunks[0].Tag = ChunkTagExtended then
  begin
    ReadExtendedHeader(Data, Chunks[0], Header);
    CheckImageSize(Header.CanvasWidth, Header.CanvasHeight);
    if (Header.Flags and WebPFlagAnimation) <> 0 then
      Result := DecodeAnimation(Data, Chunks, Truncated, Header)
    else
      Result := DecodeStill(Data, Chunks, Truncated, True, Header);
  end
  else if (Chunks[0].Tag = ChunkTagLossy) or (Chunks[0].Tag = ChunkTagLossless) then
  begin
    Header := Default(TWebPExtendedHeader);
    Result := DecodeStill(Data, Copy(Chunks, 0, 1), Truncated, False, Header);
  end
  else
    RaiseImageError(ImageErrorMalformed, 'WebP file starting with ' + ChunkTagName(Chunks[0].Tag));
  try
    ReadMetadataChunks(Data, Chunks, Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
