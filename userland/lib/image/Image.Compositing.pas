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
  Frames turned into what is seen: a TFrameCompositor keeps the canvas
  of an animation and draws its frames on it in turn, honouring each
  frame's offset, blend and disposal (Image.Frames), the way a picture
  box playing a GIF needs them.

  The canvas starts transparent. Before a frame is drawn the one before
  it is disposed of: left, its area cleared to transparent, or the
  canvas put back as it was before that frame (a copy kept only while a
  frame asks for it). A frame blended over the canvas leaves it where
  the frame is transparent and blends where it is translucent; a frame
  that is its source replaces the canvas's pixels. Frames that reach
  outside the canvas are cut at its sides.

  NextFrame plays forward, wrapping round after the last frame;
  RenderFrame goes to any frame (forward from where it is, or from the
  start). The canvas they return belongs to the compositor and changes
  with the next call. CompositeFrames gives every frame as an image of
  its own.
}
unit Image.Compositing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  fgl,
  Drawing.Colors,
  Image.Model,
  Image.Frames;

type
  TImageList = specialize TFPGObjectList<TImage>;

  TFrameCompositor = class
  private
    FAnimation: TAnimatedImage;
    FCanvas: TImage;
    FSaved: TImage;
    FLastIndex: LongInt;
    procedure DisposeFrame(Index: LongInt);
    procedure DrawFrame(Index: LongInt);
  public
    { The compositor reads Animation's frames (it does not own it). }
    constructor Create(Animation: TAnimatedImage);
    destructor Destroy; override;
    { Back to before the first frame: the canvas transparent. }
    procedure Restart;
    function NextFrame: TImage;
    function RenderFrame(Index: LongInt): TImage;
    { The frame last drawn, -1 before any. }
    property CurrentIndex: LongInt read FLastIndex;
    property Canvas: TImage read FCanvas;
  end;

{ Every frame of Animation as it is seen, each an image of its own. }
function CompositeFrames(Animation: TAnimatedImage): TImageList;

implementation

constructor TFrameCompositor.Create(Animation: TAnimatedImage);
begin
  inherited Create;
  FAnimation := Animation;
  FCanvas := TImage.Create(Animation.Width, Animation.Height);
  FSaved := nil;
  FLastIndex := -1;
end;

destructor TFrameCompositor.Destroy;
begin
  FSaved.Free;
  FCanvas.Free;
  inherited Destroy;
end;

procedure TFrameCompositor.Restart;
begin
  FCanvas.Fill(ColorTransparent);
  FreeAndNil(FSaved);
  FLastIndex := -1;
end;

procedure CopyPixels(Source, Destination: TImage);
begin
  Move(Source.Pixels^, Destination.Pixels^, PtrUInt(Source.Width) * PtrUInt(Source.Height) * SizeOf(LongWord));
end;

{ The part of a frame on the canvas, in canvas coordinates; False when
  none of it is. }
function FrameArea(Canvas: TImage; Frame: TImageFrame; out Left, Top, Right, Bottom: LongInt): Boolean;
begin
  Left := Frame.Left;
  Top := Frame.Top;
  Right := Frame.Left + Frame.Image.Width;
  Bottom := Frame.Top + Frame.Image.Height;
  if Left < 0 then
    Left := 0;
  if Top < 0 then
    Top := 0;
  if Right > Canvas.Width then
    Right := Canvas.Width;
  if Bottom > Canvas.Height then
    Bottom := Canvas.Height;
  Result := (Left < Right) and (Top < Bottom);
end;

procedure TFrameCompositor.DisposeFrame(Index: LongInt);
var
  Frame: TImageFrame;
  Left: LongInt;
  Top: LongInt;
  Right: LongInt;
  Bottom: LongInt;
  Y: LongInt;
begin
  Frame := FAnimation.Frames[Index];
  case Frame.Disposal of
    FrameDisposalBackground:
      if FrameArea(FCanvas, Frame, Left, Top, Right, Bottom) then
        for Y := Top to Bottom - 1 do
          FillDWord(FCanvas.Line(Y)[Left], Right - Left, ColorTransparent);
    FrameDisposalPrevious:
      if FSaved <> nil then
        CopyPixels(FSaved, FCanvas);
  end;
end;

procedure TFrameCompositor.DrawFrame(Index: LongInt);
var
  Frame: TImageFrame;
  Left: LongInt;
  Top: LongInt;
  Right: LongInt;
  Bottom: LongInt;
  X: LongInt;
  Y: LongInt;
  SourceLine: PLongWord;
  TargetLine: PLongWord;
  Pixel: LongWord;
  Alpha: LongWord;
begin
  if FLastIndex >= 0 then
    DisposeFrame(FLastIndex);
  Frame := FAnimation.Frames[Index];
  if Frame.Disposal = FrameDisposalPrevious then
  begin
    if FSaved = nil then
      FSaved := TImage.Create(FCanvas.Width, FCanvas.Height);
    CopyPixels(FCanvas, FSaved);
  end;
  FLastIndex := Index;
  if not FrameArea(FCanvas, Frame, Left, Top, Right, Bottom) then
    Exit;
  for Y := Top to Bottom - 1 do
  begin
    SourceLine := Frame.Image.Line(Y - Frame.Top) - Frame.Left;
    TargetLine := FCanvas.Line(Y);
    if Frame.Blend = FrameBlendSource then
      Move(SourceLine[Left], TargetLine[Left], PtrUInt(Right - Left) * SizeOf(LongWord))
    else
      for X := Left to Right - 1 do
      begin
        Pixel := SourceLine[X];
        Alpha := Pixel shr 24;
        if Alpha = AlphaOpaque then
          TargetLine[X] := Pixel
        else if Alpha <> 0 then
          TargetLine[X] := BlendColors(TargetLine[X], Pixel);
      end;
  end;
end;

function TFrameCompositor.NextFrame: TImage;
var
  Index: LongInt;
begin
  Result := FCanvas;
  if FAnimation.FrameCount = 0 then
    Exit;
  Index := FLastIndex + 1;
  if Index >= FAnimation.FrameCount then
  begin
    Restart;
    Index := 0;
  end;
  DrawFrame(Index);
end;

function TFrameCompositor.RenderFrame(Index: LongInt): TImage;
begin
  Result := FCanvas;
  if (Index < 0) or (Index >= FAnimation.FrameCount) then
    Exit;
  if Index < FLastIndex then
    Restart;
  while FLastIndex < Index do
    DrawFrame(FLastIndex + 1);
end;

function CompositeFrames(Animation: TAnimatedImage): TImageList;
var
  Compositor: TFrameCompositor;
  Index: LongInt;
begin
  Result := TImageList.Create(True);
  try
    Compositor := TFrameCompositor.Create(Animation);
    try
      for Index := 0 to Animation.FrameCount - 1 do
        Result.Add(Compositor.RenderFrame(Index).Clone);
    finally
      Compositor.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
