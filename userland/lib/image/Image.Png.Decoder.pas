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
  Decoding a PNG or APNG file, start to end.

  The chunks are listed (Image.Png.Chunks, every CRC checked), the
  header read, and the chunks before the image data gone through: the
  palette, tRNS, acTL and an fcTL, and what Image.Png.Ancillary knows
  (text, resolution, profile, gamma...). A critical chunk the decoder
  does not know is ImageErrorUnsupported; a palette picture with no
  PLTE, or a file with no IDAT, ImageErrorMalformed. The default image
  is decoded from its IDAT chunks as they follow one another
  (Image.Png.Reading); the chunks after it may carry more text, and
  in an APNG the frames.

  An APNG gives a TAnimatedImage whose own pixels are the default
  image, what a viewer that knows nothing of animation shows: when the
  default image is the first frame that is also the first frame as
  seen; when it is not part of the animation the frames all come after
  it. Frames whose chunks are missing, out of sequence or broken end
  the animation there: the frames before them are kept (as for a GIF
  cut short), and an animation left with no frames is a still picture.
}
unit Image.Png.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model;

{ Data's PNG file as an image (a TAnimatedImage for an APNG). }
function DecodePngImage(const Data: TBytes): TImage;

implementation

uses
  Drawing.Colors,
  Image.Frames,
  Image.Codecs,
  Image.Png.Chunks,
  Image.Png.Header,
  Image.Png.Pixels,
  Image.Png.DataStream,
  Image.Png.Reading,
  Image.Png.Ancillary,
  Image.Png.Animation;

type
  TPngDecoding = record
    Data: TBytes;
    List: TPngChunkList;
    Info: TPngColorInfo;
    PaletteSeen: Boolean;
    TransparencyChunk: LongInt;
    Animation: TPngAnimationControl;
    { The default image is the first frame. }
    DefaultIsFrame: Boolean;
    DefaultFrameControl: TPngFrameControl;
    FirstImageData: LongInt;
    { An image holding what the chunks say beside the pixels. }
    Properties: TImage;
  end;

procedure ReadPalette(var Decoding: TPngDecoding; constref Chunk: TPngChunk);
var
  Index: LongInt;
  Offset: PtrInt;
  Count: LongInt;
begin
  if Decoding.PaletteSeen then
    RaiseImageError(ImageErrorMalformed, 'a second PLTE chunk');
  if (Chunk.DataLength mod 3 <> 0) or (Chunk.DataLength = 0) or (Chunk.DataLength > 3 * 256) then
    RaiseImageError(ImageErrorMalformed, 'PLTE chunk');
  Decoding.PaletteSeen := True;
  { Grey pictures may not have one; RGB ones may, as a suggestion. }
  if Decoding.Info.Header.ColorType in [PngColorGrey, PngColorGreyAlpha] then
    RaiseImageError(ImageErrorMalformed, 'PLTE chunk in a grey picture');
  if Decoding.Info.Header.ColorType <> PngColorPalette then
    Exit;
  Count := Chunk.DataLength div 3;
  if Count > (1 shl Decoding.Info.Header.BitDepth) then
    RaiseImageError(ImageErrorMalformed, 'PLTE chunk longer than the depth allows');
  for Index := 0 to Count - 1 do
  begin
    Offset := Chunk.DataOffset + 3 * Index;
    Decoding.Info.Palette[Index] := ArgbColor(AlphaOpaque, Decoding.Data[Offset], Decoding.Data[Offset + 1],
      Decoding.Data[Offset + 2]);
  end;
  Decoding.Info.PaletteCount := Count;
end;

procedure ApplyTransparency(var Decoding: TPngDecoding);
var
  Chunk: TPngChunk;
  Index: LongInt;
  Count: LongInt;
begin
  if Decoding.TransparencyChunk < 0 then
    Exit;
  Chunk := Decoding.List.Chunks[Decoding.TransparencyChunk];
  case Decoding.Info.Header.ColorType of
    PngColorPalette:
      begin
        Count := Chunk.DataLength;
        if Count > Decoding.Info.PaletteCount then
          Count := Decoding.Info.PaletteCount;
        for Index := 0 to Count - 1 do
          Decoding.Info.Palette[Index] := WithAlpha(Decoding.Info.Palette[Index],
            Decoding.Data[Chunk.DataOffset + Index]);
      end;
    PngColorGrey:
      if Chunk.DataLength >= 2 then
      begin
        Decoding.Info.HasTransparentKey := True;
        Decoding.Info.KeyGrey := ChunkWord(Decoding.Data, Chunk, 0);
      end;
    PngColorRgb:
      if Chunk.DataLength >= 6 then
      begin
        Decoding.Info.HasTransparentKey := True;
        Decoding.Info.KeyRed := ChunkWord(Decoding.Data, Chunk, 0);
        Decoding.Info.KeyGreen := ChunkWord(Decoding.Data, Chunk, 2);
        Decoding.Info.KeyBlue := ChunkWord(Decoding.Data, Chunk, 4);
      end;
  end;
end;

{ The chunks between the header and the first IDAT. }
procedure ReadChunksBeforeData(var Decoding: TPngDecoding);
var
  Index: LongInt;
  Chunk: TPngChunk;
begin
  Decoding.FirstImageData := -1;
  Index := 1;
  while Index < Decoding.List.Count do
  begin
    Chunk := Decoding.List.Chunks[Index];
    case Chunk.ChunkType of
      PngChunkImageData:
        begin
          Decoding.FirstImageData := Index;
          Exit;
        end;
      PngChunkHeader:
        RaiseImageError(ImageErrorMalformed, 'a second IHDR chunk');
      PngChunkEnd:
        Break;
      PngChunkPalette:
        ReadPalette(Decoding, Chunk);
      PngChunkTransparency:
        if Decoding.TransparencyChunk < 0 then
          Decoding.TransparencyChunk := Index;
      PngChunkAnimationControl:
        if not Decoding.Animation.Present then
          ReadAnimationControl(Decoding.Data, Chunk, Decoding.Animation);
      PngChunkFrameControl:
        if Decoding.Animation.Present and not Decoding.DefaultIsFrame then
        begin
          ReadFrameControl(Decoding.Data, Chunk, Decoding.Info.Header.Width, Decoding.Info.Header.Height,
            Decoding.DefaultFrameControl);
          Decoding.DefaultIsFrame := True;
        end;
    else
      if not ReadAncillaryChunk(Decoding.Data, Chunk, Decoding.Properties) and IsCriticalChunk(Chunk.ChunkType) then
        RaiseImageError(ImageErrorUnsupported, 'PNG chunk ' + PngChunkName(Chunk.ChunkType));
    end;
    Inc(Index);
  end;
  if Decoding.List.Truncated then
    RaiseImageError(ImageErrorTruncated, 'no image data');
  RaiseImageError(ImageErrorMalformed, 'no image data');
end;

{ False when the default image cannot be the first frame as its fcTL
  says (it must cover the canvas, sequence number 0). }
function DefaultFrameFits(constref Decoding: TPngDecoding): Boolean;
begin
  with Decoding.DefaultFrameControl do
    Result := (SequenceNumber = 0) and (Left = 0) and (Top = 0) and (Width = Decoding.Info.Header.Width) and
      (Height = Decoding.Info.Header.Height);
end;

function NewFrame(Image: TImage; constref Control: TPngFrameControl; FirstFrame: Boolean): TImageFrame;
begin
  Result := TImageFrame.Create(Image);
  Result.Left := Control.Left;
  Result.Top := Control.Top;
  Result.Delay := DelayMilliseconds(Control.DelayNumerator, Control.DelayDenominator);
  Result.Disposal := FrameDisposalOf(Control.DisposeOp, FirstFrame);
  Result.Blend := FrameBlendOf(Control.BlendOp);
end;

{ The frame whose fcTL is chunk Index, decoded from the fdAT chunks
  after it; Sequence is the number the fcTL must have, and becomes the
  one after its last fdAT. }
function DecodeFrame(var Decoding: TPngDecoding; Index: LongInt; var Sequence: LongWord; FirstFrame: Boolean;
  out NextIndex: LongInt): TImageFrame;
var
  Control: TPngFrameControl;
  Data: TBytes;
  DataIndex: LongInt;
  Stream: TPngDataStream;
  Picture: TImage;
begin
  Data := Decoding.Data;
  ReadFrameControl(Data, Decoding.List.Chunks[Index], Decoding.Info.Header.Width, Decoding.Info.Header.Height, Control);
  if Control.SequenceNumber <> Sequence then
    RaiseImageError(ImageErrorMalformed, 'APNG sequence');
  Inc(Sequence);
  DataIndex := Index + 1;
  while (DataIndex < Decoding.List.Count) and (Decoding.List.Chunks[DataIndex].ChunkType = PngChunkFrameData) do
  begin
    if FrameDataSequence(Data, Decoding.List.Chunks[DataIndex]) <> Sequence then
      RaiseImageError(ImageErrorMalformed, 'APNG sequence');
    Inc(Sequence);
    Inc(DataIndex);
  end;
  if DataIndex = Index + 1 then
    RaiseImageError(ImageErrorTruncated, 'APNG frame data');
  Stream := TPngDataStream.Create(Data, Decoding.List, Index + 1, PngChunkFrameData);
  try
    Picture := DecodePngPicture(Decoding.Info, Control.Width, Control.Height, Stream);
  finally
    Stream.Free;
  end;
  Result := NewFrame(Picture, Control, FirstFrame);
  NextIndex := DataIndex;
end;

{ The chunks after the default image's data: text and the like, and
  the frames of an animation (added to Frames). }
procedure ReadChunksAfterData(var Decoding: TPngDecoding; Index: LongInt; Frames: TImageFrameList;
  Sequence: LongWord);
var
  Chunk: TPngChunk;
  AnimationGoesOn: Boolean;
  NextIndex: LongInt;
begin
  AnimationGoesOn := Decoding.Animation.Present;
  while Index < Decoding.List.Count do
  begin
    Chunk := Decoding.List.Chunks[Index];
    if Chunk.ChunkType = PngChunkEnd then
      Exit;
    if (Chunk.ChunkType = PngChunkFrameControl) and AnimationGoesOn then
    begin
      if LongWord(Frames.Count) >= Decoding.Animation.FrameCount then
        AnimationGoesOn := False
      else
        try
          Frames.Add(DecodeFrame(Decoding, Index, Sequence, Frames.Count = 0, NextIndex));
          Index := NextIndex;
          Continue;
        except
          on EImageError do
            AnimationGoesOn := False;
        end;
    end
    else
      ReadAncillaryChunk(Decoding.Data, Chunk, Decoding.Properties);
    Inc(Index);
  end;
end;

procedure SetSourceProperties(constref Decoding: TPngDecoding; Image: TImage);
begin
  Image.CopyPropertiesFrom(Decoding.Properties);
  Image.SourceFormatName := ImageFormatName(ImageFormatPng);
  Image.SourceBitsPerPixel := Decoding.Info.Header.BitsPerPixel;
  Image.SourceHasAlpha := PngInfoHasAlpha(Decoding.Info);
end;

function BuildAnimation(var Decoding: TPngDecoding; DefaultImage: TImage; Frames: TImageFrameList): TAnimatedImage;
begin
  Result := TAnimatedImage.Create(DefaultImage.Width, DefaultImage.Height);
  try
    Move(DefaultImage.Pixels^, Result.Pixels^, PtrUInt(DefaultImage.Width) * PtrUInt(DefaultImage.Height) *
      SizeOf(LongWord));
    Frames.FreeObjects := False;
    while Frames.Count > 0 do
    begin
      Result.AddFrame(Frames[0]);
      Frames.Delete(0);
    end;
    Result.LoopCount := Decoding.Animation.PlayCount;
    Result.BackgroundColor := ColorTransparent;
  except
    Result.Free;
    raise;
  end;
end;

function DecodeFrames(var Decoding: TPngDecoding; DefaultImage: TImage; AfterData: LongInt): TImage;
var
  Frames: TImageFrameList;
  Sequence: LongWord;
begin
  Frames := TImageFrameList.Create(True);
  try
    Sequence := 0;
    if Decoding.DefaultIsFrame then
    begin
      Frames.Add(NewFrame(DefaultImage.Clone, Decoding.DefaultFrameControl, True));
      { The default image's fcTL took sequence number 0. }
      Sequence := 1;
    end;
    ReadChunksAfterData(Decoding, AfterData, Frames, Sequence);
    if Frames.Count = 0 then
      Exit(DefaultImage);
    Result := BuildAnimation(Decoding, DefaultImage, Frames);
    DefaultImage.Free;
  finally
    Frames.FreeObjects := True;
    Frames.Free;
  end;
end;

function DecodePngImage(const Data: TBytes): TImage;
var
  Decoding: TPngDecoding;
  Stream: TPngDataStream;
  DefaultImage: TImage;
  AfterData: LongInt;
begin
  Decoding := Default(TPngDecoding);
  Decoding.Data := Data;
  Decoding.TransparencyChunk := -1;
  Decoding.List := ReadPngChunks(Data);
  if Decoding.List.Count = 0 then
    RaiseImageError(ImageErrorTruncated, 'no PNG header');
  ReadPngHeader(Data, Decoding.List.Chunks[0], Decoding.Info.Header);
  Decoding.Properties := TImage.Create(1, 1);
  try
    ReadChunksBeforeData(Decoding);
    if (Decoding.Info.Header.ColorType = PngColorPalette) and (Decoding.Info.PaletteCount = 0) then
      RaiseImageError(ImageErrorMalformed, 'a palette picture with no PLTE chunk');
    ApplyTransparency(Decoding);
    if Decoding.DefaultIsFrame and not DefaultFrameFits(Decoding) then
      Decoding.Animation.Present := False;
    Stream := TPngDataStream.Create(Data, Decoding.List, Decoding.FirstImageData, PngChunkImageData);
    try
      DefaultImage := DecodePngPicture(Decoding.Info, Decoding.Info.Header.Width, Decoding.Info.Header.Height, Stream);
      AfterData := Stream.NextChunk;
    finally
      Stream.Free;
    end;
    try
      if Decoding.Animation.Present then
        Result := DecodeFrames(Decoding, DefaultImage, AfterData)
      else
      begin
        ReadChunksAfterData(Decoding, AfterData, nil, 0);
        Result := DefaultImage;
      end;
    except
      DefaultImage.Free;
      raise;
    end;
    SetSourceProperties(Decoding, Result);
  finally
    Decoding.Properties.Free;
  end;
end;

end.
