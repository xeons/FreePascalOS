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
  Writing PNG and APNG files.

  The colour type is the smallest that keeps every pixel exactly
  (Image.Png.ColorTable counts them): 8-bit grey when the picture is
  grey and opaque; a palette of 1, 2, 4 or 8 bits (with tRNS for the
  colours that are not opaque) when it has no more than 256 colours;
  8-bit grey and alpha when it is grey; else 8-bit RGB when opaque and
  RGBA when not. BitsPerPixel 24 or 32 asks for RGB (alpha dropped) or
  RGBA whatever the picture.

  Every line of a picture in RGB, RGBA or grey is filtered all five
  ways and the one that looks cheapest kept (Image.Png.Filters);
  palette lines are not filtered, as libpng advises. The lines are
  compressed as they are made (Image.Png.DataWriter) at the zlib level
  asked for. The profile, resolution, orientation and text go in
  ancillary chunks (Image.Png.MetadataWriting).

  A TAnimatedImage is written as an APNG: one colour type for the
  default image and every frame, an acTL with its frame count and loop
  count, and each frame an fcTL (offset, delay in milliseconds,
  dispose and blend op) with its data in fdAT chunks. When the first
  frame covers the canvas at (0, 0) with the image's own pixels, it is
  the default image itself (its fcTL goes before IDAT); otherwise the
  image's pixels are a default image that is not part of the
  animation. A frame reaching outside the canvas is
  ImageErrorUnsupported.
}
unit Image.Png.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model;

type
  TPngWriteOptions = record
    { zlib's 0 to 9. }
    Level: Integer;
    { 0 for the smallest colour type, 24 for RGB, 32 for RGBA. }
    BitsPerPixel: LongInt;
  end;

function DefaultPngWriteOptions: TPngWriteOptions;
{ Image as a PNG file (an APNG for a TAnimatedImage with frames). }
function EncodePngImage(Image: TImage; constref Options: TPngWriteOptions): TBytes;

implementation

uses
  Drawing.Colors,
  Image.Frames,
  Image.ByteWriters,
  Image.Png.Chunks,
  Image.Png.Header,
  Image.Png.Filters,
  Image.Png.ColorTable,
  Image.Png.DataWriter,
  Image.Png.MetadataWriting,
  Image.Png.Animation;

type
  TPngLayout = record
    Header: TPngHeader;
    Colors: TPngColorTable;
    Level: Integer;
  end;

  { The line buffers of one picture: the line before filtering, the
    one above it, and a candidate for each filter, each with room for
    the filter byte in front. }
  TFilterBuffers = record
    RowBytes: PtrInt;
    Raw: TBytes;
    Above: TBytes;
    Candidates: array[0..PngFilterCount - 1] of TBytes;
  end;

function DefaultPngWriteOptions: TPngWriteOptions;
begin
  Result.Level := 6;
  Result.BitsPerPixel := 0;
end;

function PaletteDepth(Count: LongInt): LongInt;
begin
  if Count <= 2 then
    Result := 1
  else if Count <= 4 then
    Result := 2
  else if Count <= 16 then
    Result := 4
  else
    Result := 8;
end;

procedure ChooseColorType(var Layout: TPngLayout; BitsPerPixel: LongInt);
var
  Colors: TPngColorTable;
begin
  Colors := Layout.Colors;
  Layout.Header.BitDepth := 8;
  if BitsPerPixel = 24 then
    Layout.Header.ColorType := PngColorRgb
  else if BitsPerPixel = 32 then
    Layout.Header.ColorType := PngColorRgbAlpha
  else if Colors.Grey and Colors.Opaque then
    Layout.Header.ColorType := PngColorGrey
  else if Colors.Fits then
  begin
    Layout.Header.ColorType := PngColorPalette;
    Layout.Header.BitDepth := PaletteDepth(Colors.Count);
  end
  else if Colors.Grey then
    Layout.Header.ColorType := PngColorGreyAlpha
  else if Colors.Opaque then
    Layout.Header.ColorType := PngColorRgb
  else
    Layout.Header.ColorType := PngColorRgbAlpha;
  CompletePngHeader(Layout.Header);
end;

procedure PutLongBig(Target: PByte; Value: LongWord);
begin
  Target[0] := Value shr 24;
  Target[1] := (Value shr 16) and $FF;
  Target[2] := (Value shr 8) and $FF;
  Target[3] := Value and $FF;
end;

procedure PutWordBig(Target: PByte; Value: LongWord);
begin
  Target[0] := (Value shr 8) and $FF;
  Target[1] := Value and $FF;
end;

procedure WriteHeader(Writer: TImageByteWriter; constref Layout: TPngLayout);
var
  Payload: array[0..PngHeaderLength - 1] of Byte;
begin
  FillChar(Payload, SizeOf(Payload), 0);
  PutLongBig(@Payload[0], Layout.Header.Width);
  PutLongBig(@Payload[4], Layout.Header.Height);
  Payload[8] := Layout.Header.BitDepth;
  Payload[9] := Layout.Header.ColorType;
  WritePngChunk(Writer, PngChunkHeader, @Payload[0], PngHeaderLength);
end;

procedure WritePalette(Writer: TImageByteWriter; constref Layout: TPngLayout);
var
  Payload: TBytes;
  Index: LongInt;
  Color: TColor;
begin
  Payload := nil;
  SetLength(Payload, 3 * Layout.Colors.Count);
  for Index := 0 to Layout.Colors.Count - 1 do
  begin
    Color := Layout.Colors.GetColor(Index);
    Payload[3 * Index] := RedOf(Color);
    Payload[3 * Index + 1] := GreenOf(Color);
    Payload[3 * Index + 2] := BlueOf(Color);
  end;
  WritePngChunkBytes(Writer, PngChunkPalette, Payload);
  if Layout.Colors.TranslucentCount = 0 then
    Exit;
  SetLength(Payload, Layout.Colors.TranslucentCount);
  for Index := 0 to Layout.Colors.TranslucentCount - 1 do
    Payload[Index] := AlphaOf(Layout.Colors.GetColor(Index));
  WritePngChunkBytes(Writer, PngChunkTransparency, Payload);
end;

{ A line of the picture in the file's samples. }
procedure PackRow(constref Layout: TPngLayout; Line: PLongWord; Width: LongInt; Output: PByte);
var
  X: LongInt;
  Color: TColor;
  Depth: LongInt;
  BitPosition: LongInt;
begin
  case Layout.Header.ColorType of
    PngColorGrey:
      for X := 0 to Width - 1 do
        Output[X] := BlueOf(Line[X]);
    PngColorGreyAlpha:
      for X := 0 to Width - 1 do
      begin
        Output[2 * X] := BlueOf(Line[X]);
        Output[2 * X + 1] := AlphaOf(Line[X]);
      end;
    PngColorRgb:
      for X := 0 to Width - 1 do
      begin
        Color := Line[X];
        Output[3 * X] := RedOf(Color);
        Output[3 * X + 1] := GreenOf(Color);
        Output[3 * X + 2] := BlueOf(Color);
      end;
    PngColorRgbAlpha:
      for X := 0 to Width - 1 do
      begin
        Color := Line[X];
        Output[4 * X] := RedOf(Color);
        Output[4 * X + 1] := GreenOf(Color);
        Output[4 * X + 2] := BlueOf(Color);
        Output[4 * X + 3] := AlphaOf(Color);
      end;
    PngColorPalette:
      begin
        Depth := Layout.Header.BitDepth;
        FillChar(Output^, PngRowBytes(Layout.Header, Width), 0);
        for X := 0 to Width - 1 do
        begin
          BitPosition := X * Depth;
          Output[BitPosition shr 3] := Output[BitPosition shr 3] or
            (Layout.Colors.IndexOf(Line[X]) shl (8 - Depth - (BitPosition and 7)));
        end;
      end;
  end;
end;

procedure PrepareBuffers(out Buffers: TFilterBuffers; RowBytes: PtrInt);
var
  Index: LongInt;
begin
  Buffers.RowBytes := RowBytes;
  Buffers.Raw := nil;
  Buffers.Above := nil;
  SetLength(Buffers.Raw, RowBytes);
  SetLength(Buffers.Above, RowBytes);
  FillChar(Buffers.Above[0], RowBytes, 0);
  for Index := 0 to PngFilterCount - 1 do
  begin
    Buffers.Candidates[Index] := nil;
    SetLength(Buffers.Candidates[Index], RowBytes + 1);
    Buffers.Candidates[Index][0] := Index;
  end;
end;

{ The filtered line (filter byte first) to write for the line in
  Buffers.Raw. }
function FilterLine(var Buffers: TFilterBuffers; AllFilters: Boolean; Stride: LongInt): PByte;
var
  FilterType: LongInt;
  Cost: PtrUInt;
  BestCost: PtrUInt;
  Best: LongInt;
begin
  if not AllFilters then
  begin
    Move(Buffers.Raw[0], Buffers.Candidates[PngFilterNone][1], Buffers.RowBytes);
    Exit(@Buffers.Candidates[PngFilterNone][0]);
  end;
  Best := PngFilterNone;
  BestCost := High(PtrUInt);
  for FilterType := 0 to PngFilterCount - 1 do
  begin
    FilterRow(FilterType, @Buffers.Raw[0], @Buffers.Above[0], @Buffers.Candidates[FilterType][1],
      Buffers.RowBytes, Stride);
    Cost := FilteredRowCost(@Buffers.Candidates[FilterType][1], Buffers.RowBytes);
    if Cost < BestCost then
    begin
      BestCost := Cost;
      Best := FilterType;
    end;
  end;
  Result := @Buffers.Candidates[Best][0];
end;

{ Picture's lines, filtered and compressed, as chunks of ChunkType. }
procedure WritePicture(Writer: TImageByteWriter; constref Layout: TPngLayout; Picture: TImage; ChunkType: LongWord;
  Sequence: PLongWord);
var
  Buffers: TFilterBuffers;
  DataWriter: TPngDataWriter;
  AllFilters: Boolean;
  Y: LongInt;
  Swap: TBytes;
begin
  PrepareBuffers(Buffers, PngRowBytes(Layout.Header, Picture.Width));
  AllFilters := (Layout.Header.ColorType <> PngColorPalette) and (Layout.Header.BitDepth >= 8);
  DataWriter := TPngDataWriter.Create(Writer, Layout.Level, ChunkType, Sequence);
  try
    for Y := 0 to Picture.Height - 1 do
    begin
      PackRow(Layout, Picture.Line(Y), Picture.Width, @Buffers.Raw[0]);
      DataWriter.Write(FilterLine(Buffers, AllFilters, Layout.Header.FilterStride), Buffers.RowBytes + 1);
      Swap := Buffers.Above;
      Buffers.Above := Buffers.Raw;
      Buffers.Raw := Swap;
    end;
    DataWriter.Finish;
  finally
    DataWriter.Free;
  end;
end;

{ --- APNG ----------------------------------------------------------- }

function AnimationOf(Image: TImage): TAnimatedImage;
begin
  Result := nil;
  if (Image is TAnimatedImage) and (TAnimatedImage(Image).FrameCount > 0) then
    Result := TAnimatedImage(Image);
end;

function FirstFrameIsDefault(Animation: TAnimatedImage): Boolean;
var
  Frame: TImageFrame;
begin
  Frame := Animation.Frames[0];
  Result := (Frame.Left = 0) and (Frame.Top = 0) and (Frame.Image.Width = Animation.Width) and
    (Frame.Image.Height = Animation.Height) and
    CompareMem(Frame.Image.Pixels, Animation.Pixels, PtrUInt(Animation.Width) * PtrUInt(Animation.Height) *
      SizeOf(LongWord));
end;

procedure CheckFrames(Animation: TAnimatedImage);
var
  Index: LongInt;
  Frame: TImageFrame;
begin
  for Index := 0 to Animation.FrameCount - 1 do
  begin
    Frame := Animation.Frames[Index];
    if (Frame.Left < 0) or (Frame.Top < 0) or (Int64(Frame.Left) + Frame.Image.Width > Animation.Width) or
      (Int64(Frame.Top) + Frame.Image.Height > Animation.Height) then
      RaiseImageError(ImageErrorUnsupported, 'an APNG frame outside the canvas');
  end;
end;

procedure WriteAnimationControl(Writer: TImageByteWriter; Animation: TAnimatedImage);
var
  Payload: array[0..AnimationControlLength - 1] of Byte;
begin
  PutLongBig(@Payload[0], Animation.FrameCount);
  PutLongBig(@Payload[4], Animation.LoopCount);
  WritePngChunk(Writer, PngChunkAnimationControl, @Payload[0], AnimationControlLength);
end;

procedure WriteFrameControl(Writer: TImageByteWriter; Frame: TImageFrame; var Sequence: LongWord);
var
  Payload: array[0..FrameControlLength - 1] of Byte;
  Numerator: LongWord;
  Denominator: LongWord;
begin
  if Frame.Delay <= 0 then
  begin
    Numerator := 0;
    Denominator := 1000;
  end
  else if Frame.Delay <= High(Word) then
  begin
    Numerator := Frame.Delay;
    Denominator := 1000;
  end
  else
  begin
    Numerator := Frame.Delay div 10;
    if Numerator > High(Word) then
      Numerator := High(Word);
    Denominator := 100;
  end;
  PutLongBig(@Payload[0], Sequence);
  Inc(Sequence);
  PutLongBig(@Payload[4], Frame.Image.Width);
  PutLongBig(@Payload[8], Frame.Image.Height);
  PutLongBig(@Payload[12], Frame.Left);
  PutLongBig(@Payload[16], Frame.Top);
  PutWordBig(@Payload[20], Numerator);
  PutWordBig(@Payload[22], Denominator);
  case Frame.Disposal of
    FrameDisposalBackground: Payload[24] := ApngDisposeBackground;
    FrameDisposalPrevious: Payload[24] := ApngDisposePrevious;
  else
    Payload[24] := ApngDisposeNone;
  end;
  if Frame.Blend = FrameBlendOver then
    Payload[25] := ApngBlendOver
  else
    Payload[25] := ApngBlendSource;
  WritePngChunk(Writer, PngChunkFrameControl, @Payload[0], FrameControlLength);
end;

procedure WriteAnimation(Writer: TImageByteWriter; constref Layout: TPngLayout; Animation: TAnimatedImage);
var
  Sequence: LongWord;
  FirstIsDefault: Boolean;
  Index: LongInt;
  First: LongInt;
begin
  Sequence := 0;
  FirstIsDefault := FirstFrameIsDefault(Animation);
  First := 0;
  if FirstIsDefault then
  begin
    WriteFrameControl(Writer, Animation.Frames[0], Sequence);
    First := 1;
  end;
  WritePicture(Writer, Layout, Animation, PngChunkImageData, nil);
  for Index := First to Animation.FrameCount - 1 do
  begin
    WriteFrameControl(Writer, Animation.Frames[Index], Sequence);
    WritePicture(Writer, Layout, Animation.Frames[Index].Image, PngChunkFrameData, @Sequence);
  end;
end;

function EncodePngImage(Image: TImage; constref Options: TPngWriteOptions): TBytes;
var
  Layout: TPngLayout;
  Writer: TImageByteWriter;
  Animation: TAnimatedImage;
  Index: LongInt;
begin
  Animation := AnimationOf(Image);
  if Animation <> nil then
    CheckFrames(Animation);
  Layout := Default(TPngLayout);
  Layout.Header.Width := Image.Width;
  Layout.Header.Height := Image.Height;
  Layout.Level := Options.Level;
  Writer := nil;
  Layout.Colors := TPngColorTable.Create;
  try
    Layout.Colors.AddImage(Image);
    if Animation <> nil then
      for Index := 0 to Animation.FrameCount - 1 do
        Layout.Colors.AddImage(Animation.Frames[Index].Image);
    Layout.Colors.Finish;
    ChooseColorType(Layout, Options.BitsPerPixel);
    Writer := TImageByteWriter.Create(PtrInt(Image.Width) * Image.Height + 1024);
    WritePngSignature(Writer);
    WriteHeader(Writer, Layout);
    if Animation <> nil then
      WriteAnimationControl(Writer, Animation);
    WriteMetadataChunks(Writer, Image);
    if Layout.Header.ColorType = PngColorPalette then
      WritePalette(Writer, Layout);
    if Animation <> nil then
      WriteAnimation(Writer, Layout, Animation)
    else
      WritePicture(Writer, Layout, Image, PngChunkImageData, nil);
    WritePngChunk(Writer, PngChunkEnd, nil, 0);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
    Layout.Colors.Free;
  end;
end;

end.
