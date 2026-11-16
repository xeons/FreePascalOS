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
  APNG's chunks: an animated PNG is a PNG whose viewers that know
  nothing of animation still show its default image (IDAT).

    acTL  (before IDAT) the number of frames and of plays (0 for ever)
    fcTL  a frame: sequence number, width, height, offset, delay as a
          fraction of a second (numerator, denominator; a denominator
          of 0 means hundredths), dispose op (0 none, 1 background,
          2 previous), blend op (0 source, 1 over)
    fdAT  a frame's data: a sequence number, then what IDAT would hold

  An fcTL before IDAT makes the default image the first frame (it must
  then cover the whole canvas); otherwise the default image is not part
  of the animation and the frames follow it, each an fcTL and its fdAT
  chunks. fcTL and fdAT chunks share one run of sequence numbers from
  0. A first frame that asks for the canvas back as before it had
  nothing before it, so is cleared instead.

  ReadFrameControl checks a frame against the canvas; DelayMilliseconds
  turns the fraction into the model's milliseconds.
}
unit Image.Png.Animation;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Frames,
  Image.Png.Chunks;

const
  ApngDisposeNone = 0;
  ApngDisposeBackground = 1;
  ApngDisposePrevious = 2;
  ApngBlendSource = 0;
  ApngBlendOver = 1;

  AnimationControlLength = 8;
  FrameControlLength = 26;

type
  TPngAnimationControl = record
    Present: Boolean;
    FrameCount: LongWord;
    PlayCount: LongWord;
  end;

  TPngFrameControl = record
    SequenceNumber: LongWord;
    Width: LongInt;
    Height: LongInt;
    Left: LongInt;
    Top: LongInt;
    DelayNumerator: LongWord;
    DelayDenominator: LongWord;
    DisposeOp: Byte;
    BlendOp: Byte;
  end;

{ acTL; ImageErrorMalformed for a wrong length or no frames. }
procedure ReadAnimationControl(const Data: TBytes; constref Chunk: TPngChunk; out Control: TPngAnimationControl);
{ fcTL of a canvas CanvasWidth x CanvasHeight; ImageErrorMalformed for
  a frame not inside it or ops that do not exist. }
procedure ReadFrameControl(const Data: TBytes; constref Chunk: TPngChunk; CanvasWidth, CanvasHeight: LongInt;
  out Control: TPngFrameControl);
{ The sequence number at the start of an fdAT chunk. }
function FrameDataSequence(const Data: TBytes; constref Chunk: TPngChunk): LongWord;

function DelayMilliseconds(Numerator, Denominator: LongWord): LongInt;
function FrameDisposalOf(DisposeOp: Byte; FirstFrame: Boolean): TFrameDisposal;
function FrameBlendOf(BlendOp: Byte): TFrameBlend;

implementation

procedure ReadAnimationControl(const Data: TBytes; constref Chunk: TPngChunk; out Control: TPngAnimationControl);
begin
  Control := Default(TPngAnimationControl);
  if Chunk.DataLength <> AnimationControlLength then
    RaiseImageError(ImageErrorMalformed, 'acTL chunk');
  Control.FrameCount := ChunkLong(Data, Chunk, 0);
  Control.PlayCount := ChunkLong(Data, Chunk, 4);
  if (Control.FrameCount = 0) or (Control.FrameCount > PngLargestChunkLength) or
    (Control.PlayCount > PngLargestChunkLength) then
    RaiseImageError(ImageErrorMalformed, 'acTL chunk');
  Control.Present := True;
end;

procedure ReadFrameControl(const Data: TBytes; constref Chunk: TPngChunk; CanvasWidth, CanvasHeight: LongInt;
  out Control: TPngFrameControl);
var
  Width: LongWord;
  Height: LongWord;
  Left: LongWord;
  Top: LongWord;
begin
  Control := Default(TPngFrameControl);
  if Chunk.DataLength <> FrameControlLength then
    RaiseImageError(ImageErrorMalformed, 'fcTL chunk');
  Control.SequenceNumber := ChunkLong(Data, Chunk, 0);
  Width := ChunkLong(Data, Chunk, 4);
  Height := ChunkLong(Data, Chunk, 8);
  Left := ChunkLong(Data, Chunk, 12);
  Top := ChunkLong(Data, Chunk, 16);
  if (Width = 0) or (Height = 0) or (Int64(Left) + Width > CanvasWidth) or (Int64(Top) + Height > CanvasHeight) then
    RaiseImageError(ImageErrorMalformed, 'APNG frame outside the canvas');
  Control.Width := Width;
  Control.Height := Height;
  Control.Left := Left;
  Control.Top := Top;
  Control.DelayNumerator := ChunkWord(Data, Chunk, 20);
  Control.DelayDenominator := ChunkWord(Data, Chunk, 22);
  Control.DisposeOp := ChunkByte(Data, Chunk, 24);
  Control.BlendOp := ChunkByte(Data, Chunk, 25);
  if (Control.DisposeOp > ApngDisposePrevious) or (Control.BlendOp > ApngBlendOver) then
    RaiseImageError(ImageErrorMalformed, 'APNG dispose or blend op');
end;

function FrameDataSequence(const Data: TBytes; constref Chunk: TPngChunk): LongWord;
begin
  Result := ChunkLong(Data, Chunk, 0);
end;

function DelayMilliseconds(Numerator, Denominator: LongWord): LongInt;
begin
  if Denominator = 0 then
    Denominator := 100;
  Result := (Int64(Numerator) * 1000 + Denominator div 2) div Denominator;
end;

function FrameDisposalOf(DisposeOp: Byte; FirstFrame: Boolean): TFrameDisposal;
begin
  case DisposeOp of
    ApngDisposeBackground:
      Result := FrameDisposalBackground;
    ApngDisposePrevious:
      if FirstFrame then
        Result := FrameDisposalBackground
      else
        Result := FrameDisposalPrevious;
  else
    Result := FrameDisposalNone;
  end;
end;

function FrameBlendOf(BlendOp: Byte): TFrameBlend;
begin
  if BlendOp = ApngBlendOver then
    Result := FrameBlendOver
  else
    Result := FrameBlendSource;
end;

end.
