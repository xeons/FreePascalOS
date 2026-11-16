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
  Decoding a GIF (87a or 89a) into an animation: every image in the
  file is a frame (Image.Frames), with the graphic control extension
  before it giving its delay (hundredths of a second, kept as
  milliseconds; players usually stretch very short delays, which is
  theirs to do), its disposal (0 and 1 leave it, 2 clears it, 3 puts
  back what was before) and its transparent index. Frames are drawn
  over the canvas. The local colour table is used when the image has
  one, else the global one, else a grey ramp; an index outside the
  table is black. Interlaced images (lines 0, 8, 16... then 4, 12...
  then 2, 6... then the odd ones) are put in order.

  The canvas is the logical screen, or what the frames cover when the
  screen says 0. The animation's own pixels are its first frame as seen.
  The loop count comes from NETSCAPE2.0 (or ANIMEXTS1.0); without one
  the animation plays once (LoopCount 1). Comments go into the metadata.

  A file cut short gives the frames decoded until then, the last one
  as far as its data went; a file with no frame at all is an error.
  Frames together may have at most twice MaximumImagePixels pixels.
}
unit Image.Gif.Reading;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Frames,
  Image.Compositing,
  Image.ByteReaders,
  Image.Gif.Blocks,
  Image.Gif.Lzw;

function DecodeGif(const Data: TBytes): TAnimatedImage;

implementation

type
  TGifDecoding = record
    Reader: TImageByteReader;
    Screen: TGifScreen;
    Control: TGifGraphicControl;
    Frames: TImageFrameList;
    LoopCount: LongInt;
    HasLoopCount: Boolean;
    Comment: string;
    Truncated: Boolean;
    Corrupt: Boolean;
    PixelsUsed: Int64;
    LargestPaletteBits: LongInt;
    UsesTransparency: Boolean;
    LzwData: TBytes;
  end;

function GreyPalette: TGifPalette;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, 256);
  for Index := 0 to 255 do
    Result[Index] := RgbColor(Index, Index, Index);
end;

{ The line the Row-th stored line of an image of Height lines goes to. }
function InterlacedLine(Row, Height: LongInt): LongInt;
var
  Pass1: LongInt;
  Pass2: LongInt;
  Pass3: LongInt;
begin
  Pass1 := (Height + 7) div 8;
  Pass2 := (Height + 3) div 8;
  Pass3 := (Height + 1) div 4;
  if Row < Pass1 then
    Exit(Row * 8);
  Dec(Row, Pass1);
  if Row < Pass2 then
    Exit(Row * 8 + 4);
  Dec(Row, Pass2);
  if Row < Pass3 then
    Exit(Row * 4 + 2);
  Dec(Row, Pass3);
  Result := Row * 2 + 1;
end;

function FrameDisposal(GifDisposal: LongInt): TFrameDisposal;
begin
  case GifDisposal of
    2: Result := FrameDisposalBackground;
    3: Result := FrameDisposalPrevious;
  else
    Result := FrameDisposalNone;
  end;
end;

procedure PaintIndices(Image: TImage; Indices: PByte; Count: PtrInt; const Palette: TGifPalette;
  TransparentIndex: LongInt; Interlaced: Boolean);
var
  Row: LongInt;
  Y: LongInt;
  X: LongInt;
  Position: PtrInt;
  PaletteIndex: LongInt;
  Line: PLongWord;
begin
  Position := 0;
  Row := 0;
  while (Position < Count) and (Row < Image.Height) do
  begin
    if Interlaced then
      Y := InterlacedLine(Row, Image.Height)
    else
      Y := Row;
    Line := Image.Line(Y);
    X := 0;
    while (X < Image.Width) and (Position < Count) do
    begin
      PaletteIndex := Indices[Position];
      if PaletteIndex = TransparentIndex then
        Line[X] := ColorTransparent
      else if PaletteIndex < Length(Palette) then
        Line[X] := Palette[PaletteIndex]
      else
        Line[X] := ColorBlack;
      Inc(X);
      Inc(Position);
    end;
    Inc(Row);
  end;
end;

procedure ReadFrame(var Decoding: TGifDecoding);
var
  Descriptor: TGifImageDescriptor;
  Palette: TGifPalette;
  MinimumCodeSize: LongInt;
  DataLength: PtrInt;
  Complete: Boolean;
  Indices: TBytes;
  PixelCount: PtrInt;
  Decoded: PtrInt;
  Image: TImage;
  Frame: TImageFrame;
  Control: TGifGraphicControl;
begin
  Control := Decoding.Control;
  Decoding.Control := Default(TGifGraphicControl);
  Decoding.Control.TransparentIndex := -1;
  ReadGifImageDescriptor(Decoding.Reader, Descriptor);
  if Length(Descriptor.LocalPalette) > 0 then
  begin
    Palette := Descriptor.LocalPalette;
    if Descriptor.PaletteBits > Decoding.LargestPaletteBits then
      Decoding.LargestPaletteBits := Descriptor.PaletteBits;
  end
  else if Length(Decoding.Screen.GlobalPalette) > 0 then
    Palette := Decoding.Screen.GlobalPalette
  else
    Palette := GreyPalette;
  MinimumCodeSize := Decoding.Reader.ReadByte;
  DataLength := ReadSubBlocks(Decoding.Reader, Decoding.LzwData, Complete);
  if not Complete then
    Decoding.Truncated := True;
  if (Descriptor.Width = 0) or (Descriptor.Height = 0) then
    Exit;
  CheckImageSize(Descriptor.Width, Descriptor.Height);
  PixelCount := PtrInt(Descriptor.Width) * Descriptor.Height;
  if Decoding.PixelsUsed + PixelCount > 2 * Int64(MaximumImagePixels) then
    RaiseImageError(ImageErrorTooLarge, 'frames');
  Inc(Decoding.PixelsUsed, PixelCount);
  Indices := nil;
  SetLength(Indices, PixelCount);
  Decoded := DecodeGifLzw(Decoding.LzwData, DataLength, MinimumCodeSize, @Indices[0], PixelCount);
  if Decoded < 0 then
  begin
    Decoding.Corrupt := True;
    Exit;
  end;
  if (Decoded = 0) and not Complete then
    Exit;
  Image := TImage.Create(Descriptor.Width, Descriptor.Height);
  PaintIndices(Image, @Indices[0], Decoded, Palette, Control.TransparentIndex, Descriptor.Interlaced);
  Frame := TImageFrame.Create(Image);
  Frame.Left := Descriptor.Left;
  Frame.Top := Descriptor.Top;
  Frame.Delay := Control.DelayHundredths * 10;
  Frame.Disposal := FrameDisposal(Control.Disposal);
  Frame.Blend := FrameBlendOver;
  Decoding.Frames.Add(Frame);
  if (Control.TransparentIndex >= 0) or (Decoded < PixelCount) then
    Decoding.UsesTransparency := True;
end;

procedure ReadExtension(var Decoding: TGifDecoding);
var
  ExtensionLabel: Byte;
begin
  ExtensionLabel := Decoding.Reader.ReadByte;
  case ExtensionLabel of
    GifGraphicControlLabel:
      ReadGraphicControl(Decoding.Reader, Decoding.Control);
    GifApplicationLabel:
      ReadApplicationExtension(Decoding.Reader, Decoding.LoopCount, Decoding.HasLoopCount);
    GifCommentLabel:
      Decoding.Comment := Decoding.Comment + ReadCommentExtension(Decoding.Reader);
  else
    SkipSubBlocks(Decoding.Reader);
  end;
end;

procedure ReadBlocks(var Decoding: TGifDecoding);
var
  BlockType: Byte;
begin
  try
    while not Decoding.Truncated and not Decoding.Corrupt do
    begin
      if not Decoding.Reader.HasBytes(1) then
      begin
        Decoding.Truncated := True;
        Break;
      end;
      BlockType := Decoding.Reader.ReadByte;
      case BlockType of
        GifExtensionIntroducer: ReadExtension(Decoding);
        GifImageSeparator: ReadFrame(Decoding);
        GifTrailer: Break;
      else
        { Anything else ends the file as far as it can be read. }
        Decoding.Corrupt := True;
      end;
    end;
  except
    on Error: EImageError do
      if Error.Reason = ImageErrorTruncated then
        Decoding.Truncated := True
      else
        raise;
  end;
end;

{ The canvas: the logical screen, or what the frames cover. }
procedure CanvasSize(const Decoding: TGifDecoding; out Width, Height: LongInt);
var
  Index: LongInt;
  Frame: TImageFrame;
begin
  Width := Decoding.Screen.Width;
  Height := Decoding.Screen.Height;
  if (Width > 0) and (Height > 0) then
    Exit;
  Width := 0;
  Height := 0;
  for Index := 0 to Decoding.Frames.Count - 1 do
  begin
    Frame := Decoding.Frames[Index];
    if Frame.Left + Frame.Image.Width > Width then
      Width := Frame.Left + Frame.Image.Width;
    if Frame.Top + Frame.Image.Height > Height then
      Height := Frame.Top + Frame.Image.Height;
  end;
end;

function BuildAnimation(var Decoding: TGifDecoding): TAnimatedImage;
var
  Width: LongInt;
  Height: LongInt;
  Compositor: TFrameCompositor;
  First: TImage;
begin
  CanvasSize(Decoding, Width, Height);
  Result := TAnimatedImage.Create(Width, Height);
  try
    Decoding.Frames.FreeObjects := False;
    while Decoding.Frames.Count > 0 do
    begin
      Result.AddFrame(Decoding.Frames[0]);
      Decoding.Frames.Delete(0);
    end;
    if Decoding.HasLoopCount then
      Result.LoopCount := Decoding.LoopCount
    else
      Result.LoopCount := 1;
    if (Decoding.Screen.BackgroundIndex < Length(Decoding.Screen.GlobalPalette)) then
      Result.BackgroundColor := Decoding.Screen.GlobalPalette[Decoding.Screen.BackgroundIndex];
    if Decoding.Comment <> '' then
      Result.Metadata.SetValue(MetadataKeyComment, Decoding.Comment);
    Result.SourceFormatName := 'GIF';
    Result.SourceBitsPerPixel := Decoding.LargestPaletteBits;
    Result.SourceHasAlpha := Decoding.UsesTransparency;
    Compositor := TFrameCompositor.Create(Result);
    try
      First := Compositor.RenderFrame(0);
      Move(First.Pixels^, Result.Pixels^, PtrUInt(Width) * PtrUInt(Height) * SizeOf(LongWord));
    finally
      Compositor.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function DecodeGif(const Data: TBytes): TAnimatedImage;
var
  Decoding: TGifDecoding;
begin
  Decoding := Default(TGifDecoding);
  Decoding.Control.TransparentIndex := -1;
  Decoding.Reader := TImageByteReader.Create(Data);
  Decoding.Frames := TImageFrameList.Create(True);
  try
    ReadGifScreen(Decoding.Reader, Decoding.Screen);
    Decoding.LargestPaletteBits := Decoding.Screen.PaletteBits;
    ReadBlocks(Decoding);
    if Decoding.Frames.Count = 0 then
    begin
      if Decoding.Truncated then
        RaiseImageError(ImageErrorTruncated, 'no frame');
      RaiseImageError(ImageErrorMalformed, 'no frame');
    end;
    Result := BuildAnimation(Decoding);
  finally
    Decoding.Frames.FreeObjects := True;
    Decoding.Frames.Free;
    Decoding.Reader.Free;
  end;
end;

end.
