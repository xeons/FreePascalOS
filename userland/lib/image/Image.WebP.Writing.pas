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
  Writing WebP files, lossless (Image.WebP.LosslessEncoder).

  A picture without a profile, orientation or XMP is a simple file of
  one VP8L chunk; otherwise an extended one: VP8X, ICCP, the picture,
  EXIF (a TIFF structure holding the orientation) and XMP. A
  TAnimatedImage becomes ANIM (its background colour and loop count)
  and ANMF frames. WebP frames start at even offsets and cannot put the
  canvas back as it was, so when a frame starts at an odd offset or is
  disposed of that way, every frame is written whole as seen (the
  canvas, replacing what was there).
}
unit Image.WebP.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model;

function EncodeWebPImage(Image: TImage): TBytes;

implementation

uses
  Image.Metadata,
  Image.Frames,
  Image.Compositing,
  Image.ByteWriters,
  Image.WebP.Container,
  Image.WebP.Decoder,
  Image.WebP.LosslessEncoder;

const
  MaximumDuration = $FFFFFF;

procedure WriteChunk(Writer: TImageByteWriter; Tag: LongWord; const Payload: TBytes);
begin
  Writer.WriteLongLittle(Tag);
  Writer.WriteLongLittle(Length(Payload));
  Writer.WriteBytes(Payload);
  if Odd(Length(Payload)) then
    Writer.WriteByte(0);
end;

procedure WriteLong24(Writer: TImageByteWriter; Value: LongWord);
begin
  Writer.WriteByte(Value and $FF);
  Writer.WriteByte((Value shr 8) and $FF);
  Writer.WriteByte((Value shr 16) and $FF);
end;

{ A big-endian TIFF structure of one directory with one entry, the
  orientation. }
function ExifPayload(Orientation: TImageOrientation): TBytes;
begin
  Result := nil;
  SetLength(Result, 26);
  FillChar(Result[0], Length(Result), 0);
  Result[0] := Ord('M');
  Result[1] := Ord('M');
  Result[3] := 42;
  Result[7] := 8;
  Result[9] := 1;
  Result[10] := $01;
  Result[11] := $12;
  Result[13] := 3;
  Result[17] := 1;
  Result[19] := OrientationToExif(Orientation);
end;

function TextBytes(const Text: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

function ImageHasAlpha(Image: TImage): Boolean;
begin
  Result := not Image.IsOpaque;
end;

function LosslessChunk(Image: TImage): TBytes;
var
  Writer: TImageByteWriter;
begin
  Writer := TImageByteWriter.Create;
  try
    WriteChunk(Writer, ChunkTagLossless, EncodeLosslessStream(Image.Pixels, Image.Width, Image.Height));
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

function FramesNeedFlattening(Animation: TAnimatedImage): Boolean;
var
  Index: LongInt;
  Frame: TImageFrame;
begin
  for Index := 0 to Animation.FrameCount - 1 do
  begin
    Frame := Animation.Frames[Index];
    if Odd(Frame.Left) or Odd(Frame.Top) or (Frame.Left < 0) or (Frame.Top < 0) or
      (Frame.Disposal = FrameDisposalPrevious) or (Frame.Left + Frame.Image.Width > Animation.Width) or
      (Frame.Top + Frame.Image.Height > Animation.Height) then
      Exit(True);
  end;
  Result := False;
end;

function ClampDuration(Delay: LongInt): LongWord;
begin
  if Delay < 0 then
    Result := 0
  else if Delay > MaximumDuration then
    Result := MaximumDuration
  else
    Result := Delay;
end;

procedure WriteFrame(Writer: TImageByteWriter; Picture: TImage; Left, Top, Delay: LongInt; Disposal: TFrameDisposal;
  Blend: TFrameBlend);
var
  FrameWriter: TImageByteWriter;
  Flags: Byte;
begin
  FrameWriter := TImageByteWriter.Create;
  try
    WriteLong24(FrameWriter, Left div 2);
    WriteLong24(FrameWriter, Top div 2);
    WriteLong24(FrameWriter, Picture.Width - 1);
    WriteLong24(FrameWriter, Picture.Height - 1);
    WriteLong24(FrameWriter, ClampDuration(Delay));
    Flags := 0;
    if Disposal = FrameDisposalBackground then
      Flags := Flags or WebPFrameDisposeBackground;
    if Blend = FrameBlendSource then
      Flags := Flags or WebPFrameNoBlend;
    FrameWriter.WriteByte(Flags);
    FrameWriter.WriteBytes(LosslessChunk(Picture));
    WriteChunk(Writer, ChunkTagFrame, FrameWriter.ToBytes);
  finally
    FrameWriter.Free;
  end;
end;

{ ANIM and the frames; True in HasAlpha when some frame is not
  opaque. }
procedure WriteAnimation(Writer: TImageByteWriter; Animation: TAnimatedImage; out HasAlpha: Boolean);
var
  Header: TImageByteWriter;
  Index: LongInt;
  Frame: TImageFrame;
  Canvases: TImageList;
begin
  Header := TImageByteWriter.Create;
  try
    Header.WriteLongLittle(Animation.BackgroundColor);
    Header.WriteWordLittle(Word(Animation.LoopCount and $FFFF));
    WriteChunk(Writer, ChunkTagAnimation, Header.ToBytes);
  finally
    Header.Free;
  end;
  HasAlpha := False;
  if not FramesNeedFlattening(Animation) then
  begin
    for Index := 0 to Animation.FrameCount - 1 do
    begin
      Frame := Animation.Frames[Index];
      HasAlpha := HasAlpha or ImageHasAlpha(Frame.Image);
      WriteFrame(Writer, Frame.Image, Frame.Left, Frame.Top, Frame.Delay, Frame.Disposal, Frame.Blend);
    end;
    Exit;
  end;
  Canvases := CompositeFrames(Animation);
  try
    for Index := 0 to Canvases.Count - 1 do
    begin
      HasAlpha := HasAlpha or ImageHasAlpha(Canvases[Index]);
      WriteFrame(Writer, Canvases[Index], 0, 0, Animation.Frames[Index].Delay, FrameDisposalNone, FrameBlendSource);
    end;
  finally
    Canvases.Free;
  end;
end;

function EncodeWebPImage(Image: TImage): TBytes;
var
  Writer: TImageByteWriter;
  Body: TImageByteWriter;
  Animated: Boolean;
  HasAlpha: Boolean;
  Xmp: string;
  Flags: Byte;
  Extended: Boolean;
begin
  Animated := (Image is TAnimatedImage) and (TAnimatedImage(Image).FrameCount > 0);
  Xmp := Image.Metadata.GetValue(MetadataKeyXmp);
  Extended := Animated or (Length(Image.IccProfile) > 0) or (Image.Orientation <> OrientationNormal) or (Xmp <> '');
  Body := TImageByteWriter.Create;
  Writer := TImageByteWriter.Create;
  try
    if Animated then
      WriteAnimation(Body, TAnimatedImage(Image), HasAlpha)
    else
    begin
      HasAlpha := ImageHasAlpha(Image);
      Body.WriteBytes(LosslessChunk(Image));
    end;
    Writer.WriteText('RIFF');
    Writer.WriteLongLittle(0);
    Writer.WriteText('WEBP');
    if Extended then
    begin
      Flags := 0;
      if Animated then
        Flags := Flags or WebPFlagAnimation;
      if Xmp <> '' then
        Flags := Flags or WebPFlagXmp;
      if Image.Orientation <> OrientationNormal then
        Flags := Flags or WebPFlagExif;
      if HasAlpha then
        Flags := Flags or WebPFlagAlpha;
      if Length(Image.IccProfile) > 0 then
        Flags := Flags or WebPFlagIcc;
      Writer.WriteLongLittle(ChunkTagExtended);
      Writer.WriteLongLittle(ExtendedHeaderLength);
      Writer.WriteByte(Flags);
      Writer.WriteZeros(3);
      WriteLong24(Writer, Image.Width - 1);
      WriteLong24(Writer, Image.Height - 1);
      if Length(Image.IccProfile) > 0 then
        WriteChunk(Writer, ChunkTagIcc, Image.IccProfile);
    end;
    Writer.WriteBytes(Body.ToBytes);
    if Image.Orientation <> OrientationNormal then
      WriteChunk(Writer, ChunkTagExif, ExifPayload(Image.Orientation));
    if Xmp <> '' then
      WriteChunk(Writer, ChunkTagXmp, TextBytes(Xmp));
    Writer.PatchLongLittle(4, Writer.Size - 8);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
    Body.Free;
  end;
end;

end.
